// main.swift — iBalance 入口 + AppDelegate（菜单栏 UI / 定时器 / 编排）
// macOS 菜单栏常驻应用（NSStatusItem），实时汇总多平台余额/积分。
// 不依赖 Python/rumps，编译为单个 .app，内存占用 ~10MB。
// 配置和缓存存放在 ~/Library/Application Support/com.local.ibalance，App 可自由移动或更新。

import Cocoa
import UserNotifications

// MARK: - 辅助工具

/// 简单的 leading debouncer + 延迟 coalescing：窗口内最后一次调用延迟 window 后执行。
/// 用于把刷新过程中 10+ 次 updateTitle() 合并为 1~2 次标题渲染，消除主线程位图烘焙卡顿。
@MainActor
final class TitleDebouncer {
    private let window: TimeInterval
    private var workItem: DispatchWorkItem?
    private var leadingDone = false
    private let queue = DispatchQueue.main

    init(window: TimeInterval) { self.window = window }

    /// 调度任务：首次立即执行（leading），之后 window 内的调用合并为最后一次，
    /// 在静默 window 秒后再执行（trailing）。
    func dispatch(_ tag: String, @_implicitSelfCapture block: @escaping @MainActor () -> Void) {
        workItem?.cancel()
        if !leadingDone {
            leadingDone = true
            // 首次（leading）：立即执行，但把 leading 锁在 window 内
            block()
            let item = DispatchWorkItem { [weak self] in self?.leadingDone = false }
            workItem = item
            queue.asyncAfter(deadline: .now() + window, execute: item)
            return
        }
        // 非首次：trailing coalescing
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { block() }
            self?.leadingDone = false
        }
        workItem = item
        queue.asyncAfter(deadline: .now() + window, execute: item)
    }

    /// 立刻执行一次（取消待 coalesce 的 trailing）；用于刷新收尾保证最终状态已绘。
    func flush(@_implicitSelfCapture block: @escaping @MainActor () -> Void) {
        workItem?.cancel()
        workItem = nil
        leadingDone = false
        block()
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private let statusBar = NSStatusBar.system
    private var statusItem: NSStatusItem!
    var autoCheckinMenuItem: NSMenuItem!
    private var refreshIntervalMenuItem: NSMenuItem!
    private var refreshIntervalOptions: [NSMenuItem] = []

    private var timer: Timer?
    var checkinTimer: Timer?
    var wbOauthMenuItem: NSMenuItem!
    var wbOauthInProgress = false
    var wbOauthCancelled = false
    var traeCollectMenuItem: NSMenuItem!
    var traeCollectInProgress = false
    // 手动签到进行中标记：防重复触发
    var manualCheckinInProgress = false
    // NSPopover 详情面板（左键打开；设置菜单保留给右键/齿轮）
    var popoverController: NSPopover?
    var panelView: BalancePanelView?
    // 最近一次面板关闭所在事件的时间戳（transient 面板外点击会先关闭面板，
    // 随后同一 click 的 mouseUp 才触发 status item action → 用于识别「本次点击已关闭面板」）
    private var lastCloseEventTime: TimeInterval = 0
    /// 面板打开期间锁定的锚（X + 顶边 Y）：菜单栏 title 更新导致 button 宽度变化、
    /// popover 自动 reposition 时，用 KVO 同步把 window 拉回原位（无动画，避免跳动）。
    /// 锚定顶边而非 origin（左下角）：区块折叠/展开改变高度时底边伸缩，
    /// 顶边保持贴住菜单栏不动（origin 锚会在高度变化时把顶边拽下来）。
    private var panelAnchorX: CGFloat = 0
    private var panelAnchorTopY: CGFloat = 0
    private var panelAnchored = false
    /// popover window 的 frame KVO 观察令牌：面板打开期间生效，关闭时移除。
    private var panelFrameObserver: NSKeyValueObservation?
    /// 置顶浮动窗（pin 开启时承载面板内容，复用实例避免反复建窗）
    var floatingPanel: NSPanel?
    /// 浮窗会话期间的 VC 强引用（浮窗用纯 contentView 挂载，不经
    /// contentViewController，需手动持有防释放；关闭浮窗时置 nil）
    var floatingPanelVC: BalancePanelViewController?
    /// pin 时预建的下一轮面板（unpin/重开面板时由 showPanel 恢复为 panelView）
    var prebuiltPanelView: BalancePanelView?
    /// 内容转移中标志：popover 关闭由 pin 转移引发，popoverDidClose 跳过
    /// 「记录事件时间戳 + NSApp.hide」（hide 会连浮动窗一起隐藏）
    var isTransferringPanel = false
    private var settingsMenu: NSMenu!
    /// 面板最近一次释放拖拽后的平台顺序；面板未拖拽前回退到 UserDefaults。
    private var menuBarPlatformOrder: [String]?
    private var lastUpdatedAt = ""
    /// 上次余额刷新完成时间：打开面板时若距此 <1分钟则跳过自动刷新，避免频繁请求
    private var lastRefreshTime = Date.distantPast

    /// 进行中的刷新任务：onRefresh 触发时先取消旧任务，保证同一时刻只有一个刷新在跑
    private var refreshTask: Task<Void, Never>?
    /// 刷新序号（递增）：日志中关联 onRefresh / performRefresh / refreshOne*
    var refreshSeq: Int64 = 0
    /// updateTitle 去抖：180ms 窗口内多次调用合并为一次，避免刷新过程中每账号回调
    /// 都重建 attributed string + 烘焙位图导致主线程卡顿。
    private var titleDebouncer: TitleDebouncer!
    /// updateTitle 调用计数：诊断刷新触发了多少次标题重建。
    private var updateTitleCallCount: Int64 = 0
    private var updateTitleRenderCount: Int64 = 0

    /// 本轮刷新获取失败的服务名集合（footer 展示「xx 刷新失败」）：
    /// 只统计「有凭据/账号却获取失败」的服务，未配置（空 key/ticket、无账号）不计入；
    /// 成功一轮即移除。与下面的额度缓存同线程约定（仅在主线程变更）。
    private var failedServices: Set<String> = []

    var config = AppConfig()
    /// 调试用量样例缓存：开启时只在切换开关时重新随机，避免面板普通刷新时图表跳动。
    private var debugUsageRows: [UsageRowSnapshot] = []
    // 缓存原始数据，切换小数位时即时重绘（仅在主线程变更）
    private var cacheDs: (symbol: String, totalRaw: String, total: Double)?
    var cacheWb: (remain: Double, total: Double)?
    /// WorkBuddy 多账号额度缓存：uid → (remain, total)，用于面板显示每号余额卡片
    private var cacheWbAccounts: [String: (remain: Double, total: Double)] = [:]
    /// WB 裂变包重置日（uid → 周期结束时间，副标题显示用）；拉取按小时节流
    private var cacheWbFission: [String: Date] = [:]
    private var wbFissionFetchedAt: Date?
    var cacheTrae: (limit: Double, used: Double)?
    /// TRAE 多账号额度缓存：uid → (limit, used)
    var cacheTraeAccounts: [String: (limit: Double, used: Double)] = [:]
    /// ZCode 多账号额度缓存：uid → (remain, total, planEndsAt)，remain/total 为 token 数，planEndsAt 为免费套餐到期戳（0=无）
    private var cacheZcodeAccounts: [String: (remain: Double, total: Double, planEndsAt: TimeInterval)] = [:]
    /// Codex usage 缓存：uid → (usedPercent, resetAt)
    private var cacheCodexAccounts: [String: (usedPercent: Double, resetAt: TimeInterval)] = [:]
    // 点阵脉冲状态：仅由真实数据刷新（refreshOne*）更新，面板开关 syncPanel 只读不写
    // 规则：usedRatio 上升（额度被消耗）→ pulsing=true；稳定或回升 → pulsing=false
    private var traePulsingTracker = PulsingTracker()
    private var wbPulsingTracker = PulsingTracker()
    private var zcodePulsingTracker = PulsingTracker()
    private var dsPulsingTracker = PulsingTracker()
    private var codexPulsingTracker = PulsingTracker()

    /// 点阵脉冲状态机（全平台共用）：跟踪 usedRatio 的上次值，上升 → pulsing=true（被消耗），
    /// 稳定或回升 → pulsing=false；首轮（无 prev 记录）不触发。每平台一个实例，多号平台按 uid 分键。
    private struct PulsingTracker {
        private var prev: [String: Double] = [:]   // -1 = 首轮哨兵
        private var pulsing: [String: Bool] = [:]

        /// 记录新比率并更新脉冲态，返回更新后的 pulsing 值
        mutating func observe(_ key: String, ratio: Double) -> Bool {
            let p = prev[key] ?? -1
            let on = p >= 0 && ratio > p
            prev[key] = ratio
            pulsing[key] = on
            return on
        }

        /// 当前脉冲态（快照构建时读取）
        func isPulsing(_ key: String) -> Bool { pulsing[key] ?? false }

        /// 重置单键状态（首轮哨兵 + 停脉冲），如 DS 日常额度清零后
        mutating func reset(_ key: String = "") {
            prev[key] = -1
            pulsing[key] = false
        }
    }
    // 离线标记：网络不可达时菜单栏显示离线提示并暂停刷新
    private var isOffline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 调试锚点：任何启动方式下都用 stderr 打一条，用于确认「入口确实被调用」。
        // 背景：之前 GUI 会话下 applicationDidFinishLaunching 一直不被触发的嫌疑最大。
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        let pidInfo = "pid=\(ProcessInfo.processInfo.processIdentifier), tty=\(ProcessInfo.processInfo.environment["TERM"] ?? "none")"
        fputs("[iBalance][LIFECYCLE] applicationDidFinishLaunching: build=\(buildVersion), \(pidInfo)\n", stderr)
        fflush(stderr)

        // 隐藏 Dock 图标（与 Info.plist LSUIElement 双保险）
        NSApp.setActivationPolicy(.accessory)
        titleDebouncer = TitleDebouncer(window: 0.18)
        Logger.log(.refresh, "=== iBalance launched (build=\(buildVersion)) ===")

        // 安装主菜单：菜单栏 App 虽不显示菜单条，但 Edit 菜单的快捷键
        // （Cmd+C/V/X/A）会分发给弹窗内 NSTextField 的 field editor，
        // 从而原生支持复制/粘贴/剪切/全选 + 右键菜单。
        setupMainMenu()

        // 布局自动测试：启动后自动弹出面板 → pin 成浮窗 → 拖高窗口 → 折叠/展开各区块，
        // 每步把层级高度打点到 /tmp/iBalance_layout.log（诊断 pin 态余额卡片被拉伸问题；
        // 平时不开启无副作用）
        if UserDefaults.standard.bool(forKey: "IBLayoutAutoTest") {
            func step(_ s: Double, _ label: String, _ f: @escaping () -> Void) {
                DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                    Logger.log(.layout, "═══ [\(label)] ═══")
                    f()
                }
            }
            step(2.5, "open popover") { self.showPanel() }
            // 强制滚动场景：保存的浮窗尺寸(650) < 内容自然高(691)，
            // pin 动画 760→650，验证视觉顶部锚定补偿（origin 应 0→41=顶部）
            step(4.1, "set small saved size") {
                self.config.floatingPanelHeight = 650
                self.config.floatingPanelWidth = 260
            }
            step(4.2, "pin") { self.togglePanelPin() }
            step(4.4, "pin+0.2") { self.floatingPanelVC?.layoutProbe("pin+0.2", force: true) }
            step(4.8, "pin+0.6") { self.floatingPanelVC?.layoutProbe("pin+0.6", force: true) }
            step(5.6, "T1 pin settled") { self.floatingPanelVC?.layoutProbe("T1-pin-open", force: true) }
            // 模拟用户把浮窗再拖矮 40pt（滚动模式连续 resize，验证逐帧校正）
            step(6.2, "shrink -40") {
                guard let fp = self.floatingPanel else { return }
                var f = fp.frame
                f.size.height -= 40
                f.origin.y += 40
                fp.setFrame(f, display: true)
            }
            step(6.9, "T1b shrunk") { self.floatingPanelVC?.layoutProbe("T1b-shrunk", force: true) }
            // 模拟用户把浮窗拖高 220pt（触发 syncDocumentSizeToViewport 拉伸 document）
            step(7.5, "resize +220") {
                guard let fp = self.floatingPanel else { return }
                var f = fp.frame
                f.origin.y -= 220
                f.size.height += 220
                fp.setFrame(f, display: true)
            }
            step(8.2, "T2 window tall") { self.floatingPanelVC?.layoutProbe("T2-window-tall", force: true) }
            step(8.8, "collapse settings") { self.panelView?.toggleSectionForAutoTest("settings") }
            step(10.4, "T3 after collapse") { self.floatingPanelVC?.layoutProbe("T3-after-collapse", force: true) }
            step(11.0, "expand settings") { self.panelView?.toggleSectionForAutoTest("settings") }
            step(12.6, "T4 after expand") { self.floatingPanelVC?.layoutProbe("T4-after-expand", force: true) }
            step(13.2, "collapse actions") { self.panelView?.toggleSectionForAutoTest("actions") }
            step(14.8, "T5 after collapse actions") { self.floatingPanelVC?.layoutProbe("T5-after-collapse-actions", force: true) }
        }

        config = ConfigStore.load()
        // Codex 登录态来自本机 auth.json；启动时自动纳入账号列表，按钮仍可手动重新导入/更新凭据。
        if case .success(let account) = CodexService.importCurrentAccount(),
           !config.codexAccounts.contains(where: { $0.uid == account.uid }) {
            config.codexAccounts.append(account)
            ConfigStore.save(config)
        }

        // 菜单栏 status item（标题整体渲染为位图 template，见 updateTitle）
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        // 启动缓存回灌（cache-then-refresh）：立即显示上次会话的数值，
        // 网络刷新返回后照常覆盖；无缓存文件时维持占位符行为不变
        restoreBalanceCache()

        // 下拉菜单
        let menu = NSMenu()

        let openCockpitMenuItem = NSMenuItem(title: "打开 Cockpit", action: #selector(onOpenCockpit), keyEquivalent: "")
        openCockpitMenuItem.target = self
        menu.addItem(openCockpitMenuItem)

        menu.addItem(NSMenuItem.separator())

        autoCheckinMenuItem = NSMenuItem(title: "自动签到", action: #selector(onToggleAutoCheckin), keyEquivalent: "")
        autoCheckinMenuItem.target = self
        autoCheckinMenuItem.state = (config.traeAutoCheckin || config.workbuddyAutoCheckin) ? .on : .off
        menu.addItem(autoCheckinMenuItem)
        updateAutoCheckinMenuTitle()

        wbOauthMenuItem = NSMenuItem(title: "添加 WorkBuddy 账号…", action: #selector(onAddWbAccount), keyEquivalent: "")
        wbOauthMenuItem.target = self
        menu.addItem(wbOauthMenuItem)

        traeCollectMenuItem = NSMenuItem(title: "采集 TRAE 当前账号…", action: #selector(onCollectTraeAccount), keyEquivalent: "")
        traeCollectMenuItem.target = self
        menu.addItem(traeCollectMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 刷新时间子菜单：1 / 3 / 5 分钟单选
        let intervalSubmenu = NSMenu()
        for minutes in [1, 3, 5] {
            let item = NSMenuItem(title: "\(minutes)分钟", action: #selector(onToggleRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes * 60
            item.state = (config.refreshInterval == TimeInterval(minutes * 60)) ? .on : .off
            intervalSubmenu.addItem(item)
            refreshIntervalOptions.append(item)
        }
        refreshIntervalMenuItem = NSMenuItem(title: "刷新时间", action: nil, keyEquivalent: "")
        refreshIntervalMenuItem.submenu = intervalSubmenu
        menu.addItem(refreshIntervalMenuItem)
        updateRefreshIntervalMenuTitle()

        menu.addItem(NSMenuItem.separator())

        let apiKeyMenuItem = NSMenuItem(title: "DeepSeek 设置…", action: #selector(onSetApiKey), keyEquivalent: "")
        apiKeyMenuItem.target = self
        menu.addItem(apiKeyMenuItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "关于 iBalance", action: #selector(onAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // 左键点击 status item → 弹出详情面板。
        // ⚠️ 不能给 statusItem.menu 赋值：menu 非 nil 时左键会被系统直接弹菜单，
        // button 的 action 根本不触发。故 menu 置 nil，右键在 action 里手动 popUp。
        settingsMenu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(onStatusItemClicked)
        statusItem.menu = nil

        // 菜单栏前景色随屏幕聚焦状态变化；macOS 27 不总会主动重绘，手动监听刷新
        observeFocusChanges()

        // 启动时预构建详情面板（一次性），高频点击菜单栏时复用，消除每次弹窗的视图重建/SVG 加载延迟
        buildPanelOnce()

        // 首次使用：API Key 为空时弹窗让用户填写
        if config.deepseekApiKey.isEmpty {
            if let key = promptForApiKey() {
                config.deepseekApiKey = key
                ConfigStore.save(config)
            }
        }

        // 请求通知权限（失败仍可运行）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // 网络状态监听：离线暂停刷新、恢复立即刷新
        NetworkMonitor.shared.onChange = { [weak self] online in
            guard let self else { return }
            self.isOffline = !online
            if online { self.onRefresh() }
            else { self.updateTitle() }
        }
        NetworkMonitor.shared.start()

        // 定时刷新
        timer = Timer.scheduledTimer(timeInterval: config.refreshInterval,
                                     target: self,
                                     selector: #selector(onRefresh),
                                     userInfo: nil,
                                     repeats: true)

        // 启动后立即刷新一次（spin-demo 模式下跳过，避免刷新完成回调停掉演示动效）
        if !CommandLine.arguments.contains("--spin-demo") {
            onRefresh()
        }

        // 隐藏调试/演示开关：--show-panel 启动后自动弹出详情面板；--spin-demo 保持「刷新中…」状态（截图调试用）
        let spinDemo = CommandLine.arguments.contains("--spin-demo")
        if CommandLine.arguments.contains("--show-panel") || spinDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showPanel()
                if spinDemo { self?.panelView?.setRefreshing(true) }
            }
        }

        // 自动签到：启动时检查 + 每小时轮询（本地日期守卫，每天最多一次网络请求）
        startCheckinTimer()
        if config.traeAutoCheckin {
            Task { await traeAutoCheckinIfNeeded() }
        }
        if config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }
    }

    // MARK: - 菜单栏图标/标题渲染（整条标题烘焙为单张位图 template，赋给 button.image）
    // 只有 button.image 的 template 走系统状态栏自适应管线：
    // 深浅模式（按屏幕）、聚焦变淡、透明菜单栏、菜单打开高亮反色，全部由系统处理；
    // attributedTitle 里的 NSTextAttachment 原样绘制、不进 template 管线（无论是否设 isTemplate），
    // 因此把「主图标 + 平台图标 + 文字」整体画进一张黑形位图再交给系统，是唯一能全状态自适应的做法

    /// 图标形状缓存（iconName → 黑形位图）
    private var menuBarIconShapes: [String: NSImage] = [:]

    /// 获取菜单栏图标形状（惰性加载并缓存）：
    /// PDF/SVG 栅格化为黑形位图（矢量直接设 isTemplate 不生效，会渲染成黑色）；PNG 品牌色原样（烘焙进 template 后只取其 alpha 形状）
    private func menuBarIconShape(named name: String, size: CGFloat) -> NSImage? {
        if let cached = menuBarIconShapes[name] { return cached }
        for ext in ["pdf", "svg"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let img = NSImage(contentsOf: url) {
                let shape = rasterizeShape(img, size: size)
                menuBarIconShapes[name] = shape
                return shape
            }
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: size, height: size)
            menuBarIconShapes[name] = img
            return img
        }
        return nil
    }

    /// 矢量图栅格化为黑形位图（黑形 + alpha 通道），供烘焙进模板标题图
    private func rasterizeShape(_ source: NSImage, size: CGFloat) -> NSImage {
        let scale: CGFloat = 3  // 3x 栅格化，菜单栏小尺寸下保持边缘锐利
        let px = max(1, Int(size * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return source }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // 按源图纵横比等比缩放居中，避免非正方形页面被拉伸
        var rect = NSRect(x: 0, y: 0, width: size, height: size)
        let src = source.size
        if src.width > 0, src.height > 0 {
            let fit = min(size / src.width, size / src.height)
            let w = src.width * fit, h = src.height * fit
            rect = NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)
        }
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage()
        img.addRepresentation(rep)
        img.size = NSSize(width: size, height: size)
        return img
    }

    /// 把标题 attributed string 整体渲染为单张位图 template（黑形 + alpha）：
    /// 赋给 button.image 后由系统状态栏管线统一着色，深浅/聚焦/透明菜单栏/高亮全自动适配
    private func renderTemplateTitleImage(_ attr: NSAttributedString) -> NSImage? {
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = attr.boundingRect(with: NSSize(width: 10000, height: 100), options: opts)
        let w = ceil(bounds.width), h = ceil(bounds.height)
        guard w > 0, h > 0, w < 2000 else { return nil }
        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: max(1, Int(w * scale)),
                                         pixelsHigh: max(1, Int(h * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        attr.draw(with: NSRect(origin: .zero, size: NSSize(width: w, height: h)), options: opts)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage()
        img.addRepresentation(rep)
        img.isTemplate = true
        return img
    }

    // MARK: - 菜单栏前景色适配（屏幕聚焦状态）

    private func observeFocusChanges() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSApplication.didResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
    }

    /// 强制 status item 重绘。通知可能在非主线程投递，统一回主线程更新 UI。
    /// 标题为单张位图 template，聚焦/深浅变化由系统渲染管线自动着色，这里仅触发重绘。
    @objc private func refreshStatusItemAppearance() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusItem.button?.needsDisplay = true
        }
    }

    /// 千分位格式化器（复用实例，按调用调整小数位；仅主线程调用）
    private static let commaFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f
    }()

    /// 千分位格式化（每 k 加逗号）
    private func fmtAmountCommas(_ value: Any, decimals: Int) -> String {
        guard let dv = anyToDouble(value) else { return "\(value)" }
        Self.commaFormatter.maximumFractionDigits = decimals
        Self.commaFormatter.minimumFractionDigits = decimals
        return Self.commaFormatter.string(from: NSNumber(value: dv)) ?? String(format: "%.\(decimals)f", dv)
    }

    /// 按服务器回传的原始小数位格式化（不截断不补零），千分位美化
    private func fmtAmountRaw(_ raw: String) -> String {
        let frac = raw.contains(".") ? raw.split(separator: ".", maxSplits: 1)[1].count : 0
        return fmtAmountCommas(raw, decimals: min(frac, 8))
    }

    // MARK: - 详情面板（NSPopover）

    /// 左键点击 → 切换详情面板；右键 → 手动弹出设置菜单。
    @objc private func onStatusItemClicked(_ sender: Any?) {
        // 置顶浮动窗打开时：点击图标 = 关闭浮窗并复位 pin（与点击关闭 popover 语义一致），
        // 关闭后归还焦点（同 popoverDidClose）
        if let fp = floatingPanel, fp.isVisible {
            fp.orderOut(nil)
            fp.contentView = nil
            floatingPanelVC = nil
            panelView?.resetPin()
            NSApp.hide(nil)
            return
        }
        if NSApp.currentEvent?.type == .rightMouseDown {
            settingsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: statusItem.button)
            return
        }
        if popoverController?.isShown == true {
            popoverController?.performClose(nil)
            return
        }
        // 点击图标时若面板刚被同一 click 的「面板外点击」(transient) 关闭，则不再重新弹出，
        // 否则会出现「点一下关、紧接着又立刻弹开」的抖动。用事件时间戳识别同一 click。
        let t = NSApp.currentEvent?.timestamp ?? 0
        if t > 0, lastCloseEventTime > 0, t - lastCloseEventTime < 0.5 {
            return
        }
        // 延迟到本次点击事件结束再 show：.transient 会把触发点击的 mouseUp
        // 当作"面板外点击"立即关闭面板（经典菜单栏 popover 陷阱）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.showPanel()
        }
    }

    /// 懒加载面板（首次打开时构建），锚定在 status item 按钮下方。
    /// 面板同时承载原右键菜单的全部选项，回调复用现有处理函数。
    /// 构建详情面板 + popover 一次，之后 showPanel 复用，避免高频点击时重复重建视图层级/SVG I/O。
    /// 在 applicationDidFinishLaunching 末尾调用。
    func buildPanelOnce() {
        guard statusItem?.button != nil else { return }
        let panel = BalancePanelView()
        panel.onOpenCockpit = { [weak self] in self?.onOpenCockpit() }
        panel.onToggleAutoCheckin = { [weak self] in self?.onToggleAutoCheckin() }
        panel.onAddWbAccount = { [weak self] in self?.onAddWbAccount() }
        panel.onAddZcodeAccount = { [weak self] in self?.onAddZcodeAccount() }
        panel.onAddCodexAccount = { [weak self] in self?.onAddCodexAccount() }
        panel.onSetInterval = { [weak self] in self?.applyRefreshInterval(TimeInterval($0)) }
        panel.onManualRefresh = { [weak self] in self?.onRefresh() }
        panel.onSetApiKey = { [weak self] in self?.onSetApiKey() }
        panel.onTogglePanelGradient = { [weak self] in self?.onTogglePanelGradient() }
        panel.onToggleMonoFont = { [weak self] in self?.onToggleMonoFont() }
        panel.onToggleInterFont = { [weak self] in self?.onToggleInterFont() }
        panel.onToggleDebugUsage = { [weak self] in self?.onToggleDebugUsage() }
        panel.onAbout = { [weak self] in self?.onAbout() }
        panel.onManagePlatformToggles = { [weak self] in self?.onManagePlatformToggles() }
        panel.onManualCheckin = { [weak self] in self?.onManualCheckin() }
        panel.onShowCheckinHistory = { [weak self] in self?.onShowCheckinHistory() }
        panel.onQuit = { [weak self] in self?.onQuit() }
        // 右上角 pin：置顶常驻——内容转移至无边框 NSPanel 浮动窗口（无箭头、
        // 浮层层级、背景原生拖动）；取消置顶时浮窗直接关闭
        panel.onTogglePin = { [weak self] in self?.togglePanelPin() }
        // 余额卡片点击：DeepSeek 打开浏览器，TRAE / WorkBuddy / ZCode 启动应用
        panel.onClickDeepSeek = {
            NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
        }
        panel.onClickTrae = { [weak self] in
            guard let self = self else { return }
            self.openApp(bundleId: "cn.trae.solo.app", missingTitle: "未找到 TRAE 应用",
                         missingMsg: "未找到 Bundle ID 为 cn.trae.solo.app 的应用，请确认 TRAE 已安装。")
            // 打开应用即重读登录态重绘菜单栏：用户可能在平台 App 内自行切过号，
            // 上轮刷新后菜单栏的「当前账号」可能已过期
            self.ensureCurrentAccountInMenuBar(prefix: MenuBarPrefix.trae,
                                               currentUid: TraeService.readAuthInfo(storagePath: self.config.traeStoragePath)?.uid)
            self.updateTitle(immediate: true, tag: "card-open-trae")
        }
        panel.onClickWorkBuddy = { [weak self] in
            guard let self = self else { return }
            self.openApp(bundleId: "com.workbuddy.workbuddy", missingTitle: "未找到 WorkBuddy 应用",
                         missingMsg: "未找到 Bundle ID 为 com.workbuddy.workbuddy 的应用，请确认 WorkBuddy 已安装。")
            self.ensureCurrentAccountInMenuBar(prefix: MenuBarPrefix.wb,
                                               currentUid: WorkBuddyService.authInfo()?.uid)
            self.updateTitle(immediate: true, tag: "card-open-wb")
        }
        panel.onSwitchWbAccount = { [weak self] uid in
            self?.switchWbAccount(uid: uid)
        }
        panel.onCollectTraeAccount = { [weak self] in self?.onCollectTraeAccount() }
        panel.onSwitchTraeAccount = { [weak self] uid in
            self?.switchTraeAccount(uid: uid)
        }
        panel.onClickZcode = { [weak self] in
            guard let self = self else { return }
            self.openApp(bundleId: "dev.zcode.app", missingTitle: "未找到 ZCode 应用",
                         missingMsg: "未找到 Bundle ID 为 dev.zcode.app 的应用，请确认 ZCode 已安装。")
            self.ensureCurrentAccountInMenuBar(prefix: MenuBarPrefix.zcode,
                                               currentUid: ZcodeService.currentUid())
            self.updateTitle(immediate: true, tag: "card-open-zcode")
        }
        panel.onClickCodex = { [weak self] in
            guard let self = self else { return }
            self.openApp(bundleId: "com.openai.codex", missingTitle: "未找到 Codex 应用",
                         missingMsg: "未找到 Codex 应用，请确认 ChatGPT/Codex 已安装。")
            self.ensureCurrentAccountInMenuBar(prefix: MenuBarPrefix.codex,
                                               currentUid: CodexService.currentUid())
            self.updateTitle(immediate: true, tag: "card-open-codex")
        }
        panel.onSwitchCodexAccount = { [weak self] uid in
            self?.switchCodexAccount(uid: uid)
        }
        panel.onSwitchZcodeAccount = { [weak self] uid in
            self?.switchZcodeAccount(uid: uid)
        }
        panel.onRightClickCard = { [weak self] itemId, event in
            self?.toggleMenuBarVisibility(itemId: itemId, event: event)
        }
        panel.onPlatformOrderChanged = { [weak self] order in
            self?.menuBarPlatformOrder = order
            self?.updateTitle()
        }
        let popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        // 固定深色外观：面板背景是深色纯色，强制 darkAqua 保证 labelColor 等动态颜色
        // 在浅色系统外观下也渲染为深色模式取值（否则深色底配黑字不可读），且不受焦点影响
        popover.appearance = NSAppearance(named: .darkAqua)
        // 注：曾用 hasFullSizeContent=true 让背景延伸盖住箭头实现「箭头同色」，
        // 但该模式会放大 AppKit resize 的重新锚定噪声（折叠/展开时面板左右抖动），已回滚。
        let panelVC = BalancePanelViewController(panel: panel)
        panelVC.fadeHintParams = Self.fadeHintParams(from: config)
        // 浮窗 resize 拖动结束：持久化尺寸到 config.json，下次 pin 时恢复
        panelVC.onFloatingSizeChanged = { [weak self] size in
            guard let self else { return }
            self.config.floatingPanelWidth = size.width
            self.config.floatingPanelHeight = size.height
            ConfigStore.save(self.config)
        }
        popover.contentViewController = panelVC
        // 面板自带 320 内在宽度，直接按约束解出真实高度，避免零尺寸 popover
        popover.contentSize = panel.fittingSize
        popoverController = popover
        panelView = panel
    }

    /// 复用已构建的 popover/panel 展示，不再重建视图层级（消除高频点击延迟）。
    private func showPanel() {
        // pin 期间预建的面板在此接管（置顶期间 panelView 指向浮窗面板以保证数据刷新）
        if let pre = prebuiltPanelView {
            panelView = pre
            prebuiltPanelView = nil
        }
        guard let button = statusItem.button else { return }
        if popoverController == nil { buildPanelOnce() }   // 兜底：未预构建时按需构建一次
        guard let popover = popoverController, let panel = panelView else { return }
        // 先展示缓存数据（即时响应），再触发自动刷新拿最新
        panel.update(makePanelSnapshot())
        // 1分钟内已刷新过则跳过，避免频繁开关面板触发大量 API 请求
        if Date().timeIntervalSince(lastRefreshTime) >= 60 {
            onRefresh()
        }
        // 面板内容过高时让内部滚动，而不是让 NSPopover 为适应屏幕横向挪动并改变箭头锚点。
        if let panelController = popover.contentViewController as? BalancePanelViewController {
            panelController.setMaximumHeight(maximumPopoverHeight(for: button))
            _ = panelController.view // 兼容 macOS 12：访问 view 会触发一次懒加载
            popover.contentSize = panelController.preferredContentSize
        }
        // ⚠️ 必须在 show 之前激活 App：LSUIElement 应用默认不活跃，popover 首帧会按
        // 「非活跃」渲染（玻璃材质整体偏暗），激活后才呈现正常色调（官方推荐姿势）。
        NSApp.activate(ignoringOtherApps: true)
        // 使用 status item button 的完整 bounds，让 NSPopover 以菜单栏内容中心对齐。
        // 不使用 cell/imageRect，避免 macOS 27 下传入不稳定定位矩形触发 AppKit 断言。
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // popover 窗口默认不是 key window：.transient 只在 key window 状态下
        // 才会响应「面板外点击」关闭，且非 key 时玻璃材质同样偏暗 → 强制置 key。
        popover.contentViewController?.view.window?.makeKey()
        // 锁定面板原始 origin，并用 KVO 监听 popover window frame 变化：
        // 菜单栏 title 更新导致 button 宽度变化、popover 自动 reposition 时，
        // 立即（无动画）把 window 拉回原位，避免面板跳动后归位的视觉抖动。
        startPanelOriginLock()
    }

    /// 启用面板位置锁定：记录顶边锚点，KVO 监听 window frame，顶边偏离时立即无动画拉回。
    private func startPanelOriginLock() {
        guard let w = popoverController?.contentViewController?.view.window else { return }
        panelAnchorX = w.frame.minX
        panelAnchorTopY = w.frame.maxY
        panelAnchored = true
        // 移除旧观察（若有），再重新添加
        panelFrameObserver?.invalidate()
        panelFrameObserver = w.observe(\.frame, options: [.new]) { [weak self] win, _ in
            guard let self = self, self.panelAnchored else { return }
            // 期望 origin = 顶边贴住锚点（高度变化时 y 随高度下移，顶边恒定）
            let expected = NSPoint(x: self.panelAnchorX, y: self.panelAnchorTopY - win.frame.height)
            // 仅当偏离时才校正（避免无谓的 setFrameOrigin 循环）
            if win.frame.origin != expected {
                // 禁用动画：直接 setFrameOrigin 会触发默认动画，需包裹 NSAnimationContext
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                win.setFrameOrigin(expected)
                NSAnimationContext.endGrouping()
            }
        }
    }

    /// 计算 status item 下方到屏幕可见区域底部的高度，popover 超出后由内容滚动承载。
    /// 面板最大高度硬上限：屏幕空间再大也不超过 760pt，超出部分由内部滚动承载
    private let panelHeightCap: CGFloat = 760

    private func maximumPopoverHeight(for button: NSView) -> CGFloat {
        guard let screen = button.window?.screen ?? NSScreen.main else { return 640 }
        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 8
        // 额外留出 popover 箭头、阴影和系统边距，确保 NSPopover 不会为了避让屏幕
        // 自动改到侧边弹出；超出的内容由 NSScrollView 滚动承载。
        // safeHeight 同时受 750pt 硬上限约束（两个返回分支都经过它）。
        let safeHeight = min(max(1, visibleFrame.height - 48), panelHeightCap)

        if let window = button.window {
            let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let available = buttonRect.minY - visibleFrame.minY - margin
            if available > 0 { return min(available, safeHeight) }
        }

        // 状态栏坐标暂不可用时，仍限制在屏幕可见区域内，避免首次展示触发 popover 重定位。
        return safeHeight
    }

    // MARK: - NSPopoverDelegate

    /// 模态弹窗（NSAlert 等）运行期间临时把 popover 行为切为 applicationDefined：
    /// .transient 会把「与弹窗交互」误判为「点击面板外」而关闭面板，
    /// 导致点「操作」区的 API Key / 关于 等选项时面板先消失。
    /// block 结束后恢复 .transient（恢复「点击面板外自动关闭」）。
    /// 注意：仅包裹同步模态；异步长流程（如 OAuth 打开浏览器）不要用，否则面板会一直浮在最前。
    func keepPanelAliveDuring<T>(_ block: () -> T) -> T {
        guard let popover = popoverController, popover.isShown else { return block() }
        popover.behavior = .applicationDefined
        // 恢复时尊重 pin 置顶态（置顶期间本就是 applicationDefined，不能被重置回 transient）
        defer { popover.behavior = popover.contentViewController?.view.window?.level == .floating
                ? .applicationDefined : .transient }
        return block()
    }

    /// popover 关闭后归还焦点（隐藏 App），让之前活跃的应用恢复前台，
    /// 避免菜单栏小工具霸占焦点。
    func popoverDidClose(_ notification: Notification) {
        // 移除面板位置锁定：停用 KVO + 清空顶边锚点
        panelFrameObserver?.invalidate()
        panelFrameObserver = nil
        panelAnchored = false
        // pin 转移触发的关闭：不记事件时间戳、不 hide（hide 会连浮动窗一起隐藏）
        if isTransferringPanel { return }
        // 记录关闭时正在处理的事件时间戳：transient「面板外点击」关闭时，
        // currentEvent 即该 click（onStatusItemClicked 用它识别同一 click，避免抖动重弹）
        lastCloseEventTime = NSApp.currentEvent?.timestamp ?? 0
        NSApp.hide(nil)
    }

    /// 弹出动画完成后无需额外处理。面板位置锁定见 startPanelOriginLock。
    /// 历史（防「菜单栏内容变化导致面板移动/闪动」的方案演进，拦截类全部失败）：
    /// ① didMove 拉回：通知路径不可靠，未生效；② 异步拉回：中间态上屏，偶发闪动；
    /// ③ KVO 拉回但裸调 setFrameOrigin：隐式移动动画与系统定位器互搏，仍闪动；
    /// ④ 冻结按钮画布宽度：透明区永久占位、推挤左邻图标，更差。
    /// 最终回归早期 origin 锁定方案（顶边锚 + KVO + duration=0 无动画拉回）：
    /// 拉回必须禁动画是关键，锚顶边让折叠/展开的高度动画自洽。
    func popoverDidShow(_ notification: Notification) {}

    /// 从当前缓存构建面板数据快照（离线横幅 / 四服务 / 设置状态 / 更新时间）
    private func makePanelSnapshot() -> PanelSnapshot {
        var s = PanelSnapshot()
        s.offline = isOffline
        s.updatedAt = lastUpdatedAt
        // 面板余额卡片显示设置（由平台开关弹窗维护，未记录的平台默认 true）
        s.panelCardVisible = config.panelCardVisible
        // 面板用量行显示设置（由平台开关弹窗维护，未记录的平台默认 true）
        s.panelUsageVisible = config.panelUsageVisible
        // 刷新失败标记：按固定顺序列出本轮获取失败的服务（footer 展示，成功即自动清除）
        if !failedServices.isEmpty {
            let order = ["DeepSeek", "WorkBuddy", "TRAE", "ZCode", "Codex"]
            let names = order.filter { failedServices.contains($0) }
            if !names.isEmpty { s.failedText = names.joined(separator: "、") + " 刷新失败" }
        }
        // DeepSeek 卡片：多号管线单元素（uid 恒 "ds"，无昵称/签到）
        var dsSnap = AccountCardSnapshot(uid: "ds", nickname: "", isCurrent: true)
        if let ds = cacheDs {
            dsSnap.value = "\(ds.symbol)\(fmtAmountRaw(ds.totalRaw))"
            if config.deepseekCommonQuota > 0 {
                let used = max(0, config.deepseekCommonQuota - ds.total)
                dsSnap.usedRatio = min(1, used / config.deepseekCommonQuota)
            }
            dsSnap.pulsing = dsPulsingTracker.isPulsing("main")
            // 与 orderedMenuBarEntries 同口径：有缓存数据且未被右键隐藏 → 菜单栏有条目
            dsSnap.inMenuBar = isMenuBarVisible(id: MenuBarPrefix.ds, isCurrent: true)
        }
        // 未配置日常额度（usedRatio=0）时隐藏点阵
        dsSnap.hideDots = dsSnap.usedRatio <= 0
        // 复用 expireText 作为第二行纯文本副标题（无图标）
        dsSnap.expireText = config.deepseekCommonQuota > 0
            ? "日常额度 ¥\(Int(config.deepseekCommonQuota))"
            : "打开官网 usage 页面"
        s.dsAccounts = [dsSnap]
        let today = Self.todayString()
        // TRAE 多账号余额卡片：当前账号排最上
        let traeMainUid = TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? ""
        let traeAccountsList = traeCheckinAccounts().sorted { a, b in
            if a.uid == traeMainUid { return true }
            if b.uid == traeMainUid { return false }
            return false
        }
        for ac in traeAccountsList {
            let isCurrent = ac.uid == traeMainUid
            let cached = cacheTraeAccounts[ac.uid]
            var snap = AccountCardSnapshot(uid: ac.uid, nickname: ac.username, isCurrent: isCurrent)
            if let c = cached {
                snap.value = fmtAmountCommas(c.limit - c.used, decimals: 0)
                if c.limit > 0 {
                    snap.usedRatio = c.used / c.limit
                }
                // 与 orderedMenuBarEntries 同口径：有缓存数据且未被右键隐藏 → 菜单栏有条目
                snap.inMenuBar = isMenuBarVisible(id: MenuBarPrefix.trae + ac.uid, isCurrent: isCurrent)
            }
            snap.checkinDone = UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(ac.uid)) == today
            // 签到已关闭的平台不显示失败角标（当日失败标记仍保留，重新开启后可见）；
            // 风控（9074/操作太频繁）也显示角标，但颜色为橙黄（checkinRisk）
            let traeRiskToday = UserDefaults.standard.string(forKey: UDKey.traeCheckinRiskDate(ac.uid)) == today
            snap.checkinFailed = config.traeAutoCheckin
                && (UserDefaults.standard.string(forKey: UDKey.traeCheckinFailDate(ac.uid)) == today || traeRiskToday)
            snap.checkinRisk = config.traeAutoCheckin && traeRiskToday
            snap.streak = UserDefaults.standard.integer(forKey: UDKey.traeCheckinStreak(ac.uid))
            snap.reward = UserDefaults.standard.integer(forKey: UDKey.traeCheckinReward(ac.uid))
            snap.pulsing = traePulsingTracker.isPulsing(ac.uid)
            s.traeAccounts.append(snap)
        }
        // WorkBuddy 多账号余额卡片：当前账号排最上
        let mainUid = WorkBuddyService.authInfo()?.uid ?? ""
        let accounts = wbCheckinAccounts().sorted { a, b in
            if a.uid == mainUid { return true }
            if b.uid == mainUid { return false }
            return false
        }
        for ac in accounts {
            let isCurrent = ac.uid == mainUid
            let cached = cacheWbAccounts[ac.uid]
            var snap = AccountCardSnapshot(uid: ac.uid, nickname: ac.nickname, isCurrent: isCurrent)
            if let c = cached {
                snap.value = fmtAmountCommas(c.remain, decimals: 0)
                if c.total > 0 {
                    snap.usedRatio = (c.total - c.remain) / c.total
                }
                snap.inMenuBar = isMenuBarVisible(id: MenuBarPrefix.wb + ac.uid, isCurrent: isCurrent)
            }
            snap.checkinDone = UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(ac.uid)) == today
            // 签到已关闭的平台不显示失败角标（当日失败标记仍保留，重新开启后可见）
            snap.checkinFailed = config.workbuddyAutoCheckin
                && UserDefaults.standard.string(forKey: UDKey.wbCheckinFailDate(ac.uid)) == today
            snap.streak = UserDefaults.standard.integer(forKey: UDKey.wbCheckinStreak(ac.uid))
            snap.reward = UserDefaults.standard.integer(forKey: UDKey.wbCheckinReward(ac.uid))
            snap.pulsing = wbPulsingTracker.isPulsing(ac.uid)
            // 裂变包重置日副标题（仅当前账号显示）：「裂变包 M-d 重置」
            if isCurrent, let resetAt = cacheWbFission[ac.uid] {
                snap.expireText = Self.expireCountdownText(endsAt: resetAt.timeIntervalSince1970)
            }
            s.wbAccounts.append(snap)
        }
        // ZCode 多账号余额卡片：当前登录账号（config.json token 对应 uid）排最上
        let zcodeMainUid = ZcodeService.currentUid() ?? ""
        let zcodeAccountsList = config.zcodeAccounts.sorted { a, b in
            if a.uid == zcodeMainUid { return true }
            if b.uid == zcodeMainUid { return false }
            return false
        }
        for ac in zcodeAccountsList {
            let isCurrent = ac.uid == zcodeMainUid
            let cached = cacheZcodeAccounts[ac.uid]
            var snap = AccountCardSnapshot(uid: ac.uid, nickname: ac.displayName, isCurrent: isCurrent)
            if let c = cached, c.total > 0 {
                snap.value = fmtAmountCommas(c.remain / c.total * 100, decimals: 1) + "%"
                snap.usedRatio = (c.total - c.remain) / c.total
                snap.inMenuBar = isMenuBarVisible(id: MenuBarPrefix.zcode + ac.uid, isCurrent: isCurrent)
                // 到期副标题：仅当前账号 + 有免费套餐（Start Plan）时显示，剩余时长 HH:mm（小时可超 24）
                if isCurrent, c.planEndsAt > 0 {
                    if let text = Self.expireCountdownText(endsAt: c.planEndsAt) {
                        snap.expireText = text
                    } else {
                        // Start Plan 已到期：卡片显示"套餐已到期"红色提示，且不再参与定时刷新
                        snap.expired = true
                        snap.expireText = "套餐已到期"
                    }
                }
            }
            snap.pulsing = zcodePulsingTracker.isPulsing(ac.uid)
            s.zcodeAccounts.append(snap)
        }
        // Codex 多账号 usage 卡片：当前 auth.json 对应账号排首位，昵称固定显示邮箱。
        let codexMainUid = CodexService.currentUid() ?? ""
        let codexAccountsList = config.codexAccounts.sorted { a, b in
            if a.uid == codexMainUid { return true }
            if b.uid == codexMainUid { return false }
            return false
        }
        for ac in codexAccountsList {
            let isCurrent = ac.uid == codexMainUid
            let cached = cacheCodexAccounts[ac.uid]
            var snap = AccountCardSnapshot(uid: ac.uid, nickname: ac.email, isCurrent: isCurrent)
            if let c = cached {
                snap.value = fmtAmountCommas(100 - c.usedPercent, decimals: 0) + "%"
                snap.usedRatio = c.usedPercent / 100
                snap.inMenuBar = isMenuBarVisible(id: MenuBarPrefix.codex + ac.uid, isCurrent: isCurrent)
                // 到期副标题：仅当前账号显示，剩余时长格式同 ZCode（HH:mm，小时可超 24）
                if isCurrent, c.resetAt > 0 {
                    snap.expireText = Self.expireCountdownText(endsAt: c.resetAt) ?? "已到期"
                }
            }
            snap.pulsing = codexPulsingTracker.isPulsing(ac.uid)
            s.codexAccounts.append(snap)
        }
        // ── 日/周用量（本地差值基线，见 UsageStore；平台行 = 全部账号用量加总）──
        func fmtUsage(_ v: Double, percent: Bool, decimals: Int) -> String {
            percent ? String(format: "%.1f%%", v) : fmtAmountCommas(v, decimals: decimals)
        }
        func usageRow(icon: String, name: String, platform: String,
                      accounts: [(uid: String, current: Double)], increasing: Bool, decimals: Int,
                      percent: Bool, prefix: String = "") -> UsageRowSnapshot? {
            guard let u = UsageStore.usage(platform: platform, accounts: accounts, increasing: increasing) else { return nil }
            let daily = UsageStore.weeklyUsage(platform: platform, uids: accounts.map(\.uid))
            let hour = UsageStore.hourlyUsage(platform: platform, accounts: accounts, increasing: increasing)
            return UsageRowSnapshot(platform: platform, icon: icon, name: name,
                                    hourText: prefix + fmtUsage(hour, percent: percent, decimals: decimals),
                                    todayText: prefix + fmtUsage(u.today, percent: percent, decimals: decimals),
                                    weekText: prefix + fmtUsage(u.week, percent: percent, decimals: decimals),
                                    dailyUsage: daily,
                                    dailyUsageTexts: daily.map { prefix + fmtUsage($0, percent: percent, decimals: decimals) })
        }
        if let ds = cacheDs,
           let row = usageRow(icon: "deepseek", name: "DeepSeek", platform: "ds",
                              accounts: [(uid: "main", current: ds.total)], increasing: false,
                              decimals: 2, percent: false, prefix: ds.symbol) {
            s.usageRows.append(row)
        }
        if let row = usageRow(icon: "workbuddy", name: "WorkBuddy", platform: "wb",
                              accounts: cacheWbAccounts.map { (uid: $0.key, current: $0.value.remain) },
                              increasing: false, decimals: config.workbuddyDecimals, percent: false) {
            s.usageRows.append(row)
        }
        if let row = usageRow(icon: "trae-color", name: "TRAE", platform: "trae",
                              accounts: cacheTraeAccounts.map { (uid: $0.key, current: $0.value.used) },
                              increasing: true, decimals: config.traeDecimals, percent: false) {
            s.usageRows.append(row)
        }
        if let row = usageRow(icon: "zhipu", name: "ZCode", platform: "zcode",
                              accounts: cacheZcodeAccounts.compactMap {
                                  $0.value.total > 0 ? (uid: $0.key, current: $0.value.remain / $0.value.total * 100) : nil
                              },
                              increasing: false, decimals: 1, percent: true) {
            s.usageRows.append(row)
        }
        if let row = usageRow(icon: "codex", name: "Codex", platform: "codex",
                              accounts: cacheCodexAccounts.map { (uid: $0.key, current: $0.value.usedPercent) },
                              increasing: true, decimals: 1, percent: true) {
            s.usageRows.append(row)
        }
        // 调试模式始终提供完整的七日样例，即使本机尚未配置任何平台账号，方便直接观察面积图。
        s.debugUsageEnabled = config.debugUsageEnabled
        if config.debugUsageEnabled {
            if debugUsageRows.isEmpty { debugUsageRows = makeDebugUsageRows() }
            s.usageRows = debugUsageRows
        }
        // 平台开关「用量」列：用户可单独隐藏某平台的用量行（未记录的平台默认显示）。
        // 无观测记录的平台本就无行（usageRow 返回 nil），此过滤只对已有行裁剪。
        s.usageRows = s.usageRows.filter { config.panelUsageVisible[$0.platform] ?? true }
        // ── 设置/操作状态 ──
        s.traeAutoCheckin = config.traeAutoCheckin
        s.wbAutoCheckin = config.workbuddyAutoCheckin
        // 自动签到副标题：今日签到统计「M-d x成功 x失败 x风控」（手动一键签到写同一套标记，自然计入；
        // 失败/风控按各自 date==today 口径，昨日残留不计；风控 = TRAE claim 返回 9074/操作太频繁，
        // 单独计数不再计入失败，无风控时保持原「x成功 x失败」格式）
        var okCount = 0
        var failCount = 0
        var riskCount = 0
        for ac in traeAccountsList {
            if UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(ac.uid)) == today { okCount += 1 }
            if UserDefaults.standard.string(forKey: UDKey.traeCheckinFailDate(ac.uid)) == today { failCount += 1 }
            if UserDefaults.standard.string(forKey: UDKey.traeCheckinRiskDate(ac.uid)) == today { riskCount += 1 }
        }
        for ac in accounts {
            if UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(ac.uid)) == today { okCount += 1 }
            if UserDefaults.standard.string(forKey: UDKey.wbCheckinFailDate(ac.uid)) == today { failCount += 1 }
        }
        if okCount + failCount + riskCount > 0 {
            var text = "\(Self.dfMonthDay.string(from: Date())) \(okCount)成功"
            if failCount > 0 { text += " \(failCount)失败" }
            if riskCount > 0 { text += " \(riskCount)风控" }
            s.lastCheckinTime = text
        }
        s.wbOauthInProgress = wbOauthInProgress
        s.traeCollectInProgress = traeCollectInProgress
        s.checkinInProgress = manualCheckinInProgress
        s.refreshIntervalSeconds = Int(config.refreshInterval)
        s.panelGradientEnabled = config.panelGradientEnabled
        s.monoFontEnabled = config.monoFontEnabled
        s.interFontEnabled = config.interFontEnabled
        return s
    }

    /// 生成调试用量：七天随机样例只保存在内存，不写入 UsageStore / usage.json。
    /// 非百分比平台的「本周」为七日合计；百分比平台取本周峰值，避免合计超过 100%。
    private func makeDebugUsageRows() -> [UsageRowSnapshot] {
        let definitions: [(platform: String, icon: String, name: String,
                           percent: Bool, prefix: String, decimals: Int,
                           lower: Double, upper: Double)] = [
            ("ds", "deepseek", "DeepSeek", false, "¥", 2, 0.08, 3.80),
            ("wb", "workbuddy", "WorkBuddy", false, "", config.workbuddyDecimals, 30, 480),
            ("trae", "trae-color", "TRAE", false, "", config.traeDecimals, 8, 120),
            ("zcode", "zhipu", "ZCode", true, "", 1, 8, 92),
            ("codex", "codex", "Codex", true, "", 1, 12, 96),
        ]

        return definitions.map { item in
            var daily = (0..<7).map { _ in
                Double.random(in: item.lower...item.upper)
            }
            // 给图表制造一个清晰的局部峰值，让面积图的平滑转角更容易观察。
            if let peakIndex = daily.indices.randomElement() {
                daily[peakIndex] = min(item.upper, daily[peakIndex] * (item.percent ? 1.12 : 1.45))
            }
            let dailyTexts = daily.map {
                item.percent
                    ? String(format: "%.1f%%", $0)
                    : item.prefix + fmtAmountCommas($0, decimals: item.decimals)
            }
            let today = daily.last ?? 0
            let week = item.percent ? (daily.max() ?? 0) : daily.reduce(0, +)
            // 近 1 小时样例：今日值的 1/4 上下随机，量级贴近真实小时消耗
            let hour = today * Double.random(in: 0.1...0.4)
            let hourText = item.percent
                ? String(format: "%.1f%%", hour)
                : item.prefix + fmtAmountCommas(hour, decimals: item.decimals)
            let todayText = item.percent
                ? String(format: "%.1f%%", today)
                : item.prefix + fmtAmountCommas(today, decimals: item.decimals)
            let weekText = item.percent
                ? String(format: "%.1f%%", week)
                : item.prefix + fmtAmountCommas(week, decimals: item.decimals)
            return UsageRowSnapshot(platform: item.platform, icon: item.icon, name: item.name,
                                    hourText: hourText, todayText: todayText, weekText: weekText,
                                    dailyUsage: daily, dailyUsageTexts: dailyTexts)
        }
    }

    /// 判断当前 seq 是否"拥有"写 UI 权限：未被取消 + 仍是最新 seq。
    /// 背景：onRefresh 的取消是合作式的，URLSession 不会因 cancel() 立刻中断，
    /// 旧 seq 的 refreshOne* 仍可能跑完并尝试写 failedServices / cache / syncPanel，
    /// 从而覆盖掉新 seq 的「刷新中…」动效与失败统计。本 guard 作为统一闸门。
    private func ownsRefresh(_ seq: Int64) -> Bool {
        !Task.isCancelled && refreshSeq == seq
    }

    /// 数据变化时同步刷新面板（面板打开时才重绘；置顶浮窗显示中也算「打开」）
    func syncPanel(file: StaticString = #file, line: Int = #line) {
        guard let panel = panelView else { return }
        let shown = popoverController?.isShown == true || floatingPanel?.isVisible == true
        Logger.log(.refresh, "syncPanel [\(line)] shown=\(shown) updatedAt=\(lastUpdatedAt) isRefreshing=\(panel.isRefreshing) failed=\(failedServices.sorted())")
        guard shown else { return }
        panel.update(makePanelSnapshot())
    }

    /// 无条件刷新一次 panel 文本（用于 performRefresh 收尾：setRefreshing(false) 之后
    /// 必须把 updatedLabel 从"刷新中…"改回真实"更新于 XX"，即便 popover 此时是关着的
    /// —— 否则下次开面板时第一帧会短暂显示"刷新中…"再被 showPanel 的 update() 修正）。
    private func forceUpdatePanelFooter() {
        guard let panel = panelView else {
            Logger.log(.refresh, "forceUpdatePanelFooter: panelView == nil, skip")
            return
        }
        let s = makePanelSnapshot()
        Logger.log(.refresh, "forceUpdatePanelFooter: calling panel.update(updatedAt=\(s.updatedAt), failed=\(s.failedText ?? "nil"), isRefreshing=\(panel.isRefreshing))")
        panel.update(s, force: true)
    }

    // MARK: - 菜单回调

    @objc func onRefresh() {
        refreshSeq &+= 1
        let seq = refreshSeq
        let cancelledOld = refreshTask != nil
        // 每轮刷新独立统计失败：上一轮被取消的服务不会把"历史未移除失败"带到本轮 footer。
        failedServices.removeAll()
        panelView?.setRefreshing(true)   // 面板显示「刷新中…」脉冲提示
        Logger.log(.refresh, "[\(seq)] onRefresh triggered (cancelledOld=\(cancelledOld)): refreshing=YES set")
        // 取消进行中的旧刷新再起新任务：定时器/网络恢复/开面板/手动可并发触发，
        // 不取消会导致旧任务慢响应覆盖新缓存，且重复请求有触发风控的风险
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let t0 = Date()
            await self?.performRefresh(seq: seq)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Logger.log(.refresh, "[\(seq)] refreshTask scope END (elapsed=\(ms)ms, cancelled=\(Task.isCancelled))")
        }
    }

    /// 子菜单单选切换刷新间隔（tag = 秒数：60 / 180 / 300）
    @objc private func onToggleRefreshInterval(_ sender: NSMenuItem) {
        applyRefreshInterval(TimeInterval(sender.tag))
    }

    /// 应用刷新间隔（菜单与面板共用）：写配置、同步菜单勾选、重启 Timer
    private func applyRefreshInterval(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        config.refreshInterval = interval
        refreshIntervalOptions.forEach { $0.state = (TimeInterval($0.tag) == interval) ? .on : .off }
        updateRefreshIntervalMenuTitle()
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: config.refreshInterval,
                                     target: self,
                                     selector: #selector(onRefresh),
                                     userInfo: nil,
                                     repeats: true)
        ConfigStore.save(config)
        syncPanel()
    }

    /// 主菜单项标题显示当前选中的刷新间隔
    private func updateRefreshIntervalMenuTitle() {
        let minutes = Int(config.refreshInterval) / 60
        refreshIntervalMenuItem.title = "刷新时间（\(minutes)分钟）"
    }

    /// 面板渐变背景：切换后立即保存并刷新面板（VC 经快照同步后重绘遮罩）
    @objc private func onTogglePanelGradient() {
        config.panelGradientEnabled = !config.panelGradientEnabled
        ConfigStore.save(config)
        syncPanel()
    }

    /// Mono 字体：余额卡片与用量列表切换 JetBrainsMono（中文回退系统字体），
    /// 保存后经快照同步，面板对已注册 label 就地换字体（不重建卡片）
    @objc private func onToggleMonoFont() {
        config.monoFontEnabled = !config.monoFontEnabled
        ConfigStore.save(config)
        syncPanel()
    }

    /// Inter 字体：面板文本切换 Inter（中文回退系统字体），优先级 Mono 风格 > Inter。
    /// 保存后经快照同步，面板对已注册 label 就地换字体（不重建卡片）
    @objc private func onToggleInterFont() {
        config.interFontEnabled = !config.interFontEnabled
        ConfigStore.save(config)
        syncPanel()
    }

    /// 调试用量：切换开启时生成一组新的随机七日样例，关闭后恢复真实用量。
    @objc private func onToggleDebugUsage() {
        config.debugUsageEnabled.toggle()
        debugUsageRows = config.debugUsageEnabled ? makeDebugUsageRows() : []
        ConfigStore.save(config)
        syncPanel()
    }

    /// 打开平台开关弹窗：保存后同步右键菜单、自动签到定时器和面板状态。
    @objc private func onManagePlatformToggles() {
        let oldConfig = config
        let dialog = PlatformAutomationSettingsDialog(config: oldConfig)
        guard let updated = keepPanelAliveDuring({ dialog.present() }) else { return }

        config = updated
        ConfigStore.save(config)
        autoCheckinMenuItem.state = (config.traeAutoCheckin || config.workbuddyAutoCheckin) ? .on : .off

        if config.traeAutoCheckin || config.workbuddyAutoCheckin {
            startCheckinTimer()
            if !oldConfig.traeAutoCheckin && config.traeAutoCheckin {
                Task { await traeAutoCheckinIfNeeded() }
            }
            if !oldConfig.workbuddyAutoCheckin && config.workbuddyAutoCheckin {
                Task { await wbAutoCheckinIfNeeded() }
            }
        } else {
            stopCheckinTimer()
        }
        syncPanel()
    }

    @objc private func onQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - 滚动提示层参数

    private static func fadeHintParams(from c: AppConfig) -> FadeHintParams {
        var p = FadeHintParams()
        p.bandHeight = c.fadeHintBandHeight
        p.highlightAlpha = c.fadeHintHighlightAlpha
        p.maskMidAlpha = c.fadeHintMaskMidAlpha
        p.arrowAlpha = c.fadeHintArrowAlpha
        p.bobAmplitude = c.fadeHintBobAmplitude
        return p
    }

    @objc private func onAbout() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let shell = DialogShell()
        shell.addIcon(NSApp.applicationIconImage)
        shell.addTitle("关于 iBalance")
        // 长文阅读类弹窗：内容宽 +8 抵消 sidePadding 增量，再 +20 加宽正文行宽
        shell.contentWidth = DialogMetrics.width + 8 + 20
        shell.addInfo("菜单栏常驻小工具，实时聚合多平台账户余额与积分。\n\n"
            + "• DeepSeek 余额（API Key 查询）\n• WorkBuddy 积分（多号 OAuth，自动签到）\n• TRAE 积分（本地解密，自动签到）\n• ZCode 额度（JSON 导入，多号切换）\n• 刷新间隔 1 / 3 / 5 分钟\n\n"
            + "配置存于 ~/Library/Application Support/com.local.ibalance\n版本 v\(build)")
        shell.addButton("知道了", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }
    }

    @objc private func onSetApiKey() {
        guard let result = keepPanelAliveDuring({
            DeepSeekSettingsDialog(apiKey: config.deepseekApiKey,
                                   quota: config.deepseekCommonQuota).present()
        }) else { return }
        if let apiKey = result.apiKey { config.deepseekApiKey = apiKey }
        config.deepseekCommonQuota = max(0, result.quota)
        ConfigStore.save(config)
        onRefresh()
    }

    // MARK: - 菜单栏条目显示控制

    /// 菜单栏条目 id 前缀
    enum MenuBarPrefix {
        static let ds = "ds"
        static let trae = "trae:"
        static let wb = "wb:"
        static let zcode = "zcode:"
        static let codex = "codex:"
    }

    /// 判断某条目在菜单栏是否可见
    /// 显式配置优先；无记录时使用默认值：DS/Trae主/Wb主 默认可见；ZCode主默认隐藏（保持旧版行为）；非主账号默认隐藏
    private func isMenuBarVisible(id: String, isCurrent: Bool) -> Bool {
        if let v = config.menuBarVisible[id] { return v }
        // 默认值
        if id == MenuBarPrefix.ds { return true }
        if isCurrent {
            // 主账号：Trae/Wb 默认显示，ZCode 默认隐藏
            if id.hasPrefix(MenuBarPrefix.zcode) || id.hasPrefix(MenuBarPrefix.codex) { return false }
            return true
        }
        return false
    }

    /// 右键点击余额卡片时直接切换该条目在菜单栏的显示/隐藏
    private func toggleMenuBarVisibility(itemId: String, event: NSEvent) {
        // 判断是否为当前账号（用于默认值判定）
        var isCurrent = false
        var entryFound = false
        for entry in orderedMenuBarEntries() where entry.id == itemId {
            isCurrent = entry.isCurrent
            entryFound = true
            break
        }
        if !entryFound {
            isCurrent = (itemId == MenuBarPrefix.ds)
                || itemId.hasPrefix(MenuBarPrefix.trae) && itemId.hasSuffix(TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? "")
                || itemId.hasPrefix(MenuBarPrefix.wb) && itemId.hasSuffix(WorkBuddyService.authInfo()?.uid ?? "")
                || itemId.hasPrefix(MenuBarPrefix.zcode) && itemId.hasSuffix(ZcodeService.currentUid() ?? "")
                || itemId.hasPrefix(MenuBarPrefix.codex) && itemId.hasSuffix(CodexService.currentUid() ?? "")
        }
        let currentlyVisible = isMenuBarVisible(id: itemId, isCurrent: isCurrent)
        config.menuBarVisible[itemId] = !currentlyVisible
        ConfigStore.save(config)
        // 用户主动操作：立即渲染并立即应用位图（菜单栏瞬间反馈），面板由 KVO 钉住
        updateTitle(immediate: true)
        syncPanel()
    }

    /// 打开当前账号卡片（启动平台 App）时确保该平台当前账号在菜单栏显示：
    /// 用户可能在平台 App 内自行切号，新当前账号可能带有历史右键隐藏记录
    /// （ZCode/Codex 当前账号还默认隐藏），这里追加为可见，其余条目显隐不变。
    private func ensureCurrentAccountInMenuBar(prefix: String, currentUid: String?) {
        guard let uid = currentUid, !uid.isEmpty else { return }
        let itemId = prefix + uid
        guard !isMenuBarVisible(id: itemId, isCurrent: true) else { return }
        config.menuBarVisible[itemId] = true
        ConfigStore.save(config)
    }

    /// 读取面板保存的平台顺序；未知/新增平台自动追加到末尾。
    private func balancePlatformOrder() -> [String] {
        let saved = menuBarPlatformOrder
            ?? UserDefaults.standard.stringArray(forKey: UDKey.balancePlatformOrder)
            ?? []
        return BalancePlatform.normalizedOrder(from: saved)
    }

    /// 按面板余额卡片顺序构建要显示在菜单栏的条目（id, symbol, value, icon）。
    /// 平台组顺序与余额面板共用 UserDefaults，组内仍保持当前账号优先。
    private func orderedMenuBarEntries() -> [(id: String, symbol: String, value: String, isCurrent: Bool, icon: String)] {
        var entries: [(id: String, symbol: String, value: String, isCurrent: Bool, icon: String)] = []

        // 1. DeepSeek（icon 前缀 + 货币符号 + 金额）
        if let ds = cacheDs {
            entries.append((id: MenuBarPrefix.ds, symbol: ds.symbol, value: fmtAmountRaw(ds.totalRaw), isCurrent: true, icon: "deepseek"))
        }

        // 2. ZCode 账号（当前账号优先）
        let zcodeMainUid = ZcodeService.currentUid() ?? ""
        let zcodeList = config.zcodeAccounts.sorted { a, b in
            if a.uid == zcodeMainUid { return true }
            if b.uid == zcodeMainUid { return false }
            return false
        }
        for ac in zcodeList {
            guard let c = cacheZcodeAccounts[ac.uid], c.total > 0 else { continue }
            let pct = fmtAmountCommas(c.remain / c.total * 100, decimals: 1) + "%"
            entries.append((id: MenuBarPrefix.zcode + ac.uid, symbol: "", value: pct, isCurrent: ac.uid == zcodeMainUid, icon: "zhipu"))
        }

        // 3. Codex 账号（当前账号优先）
        let codexMainUid = CodexService.currentUid() ?? ""
        let codexList = config.codexAccounts.sorted { a, b in
            if a.uid == codexMainUid { return true }
            if b.uid == codexMainUid { return false }
            return false
        }
        for ac in codexList {
            guard let c = cacheCodexAccounts[ac.uid] else { continue }
            let pct = fmtAmountCommas(100 - c.usedPercent, decimals: 0) + "%"
            entries.append((id: MenuBarPrefix.codex + ac.uid, symbol: "", value: pct,
                            isCurrent: ac.uid == codexMainUid, icon: "codex"))
        }

        // 4. TRAE 账号（当前账号优先）
        let traeMainUid = TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? ""
        let traeList = traeCheckinAccounts().sorted { a, b in
            if a.uid == traeMainUid { return true }
            if b.uid == traeMainUid { return false }
            return false
        }
        for ac in traeList {
            guard let c = cacheTraeAccounts[ac.uid] else { continue }
            let remaining = c.limit - c.used
            entries.append((id: MenuBarPrefix.trae + ac.uid, symbol: "", value: fmtAmountCommas(remaining, decimals: 0), isCurrent: ac.uid == traeMainUid, icon: "trae-color"))
        }

        // 4. WorkBuddy 账号（当前账号优先）
        let wbMainUid = WorkBuddyService.authInfo()?.uid ?? ""
        let wbList = wbCheckinAccounts().sorted { a, b in
            if a.uid == wbMainUid { return true }
            if b.uid == wbMainUid { return false }
            return false
        }
        for ac in wbList {
            guard let c = cacheWbAccounts[ac.uid] else { continue }
            entries.append((id: MenuBarPrefix.wb + ac.uid, symbol: "", value: fmtAmountCommas(c.remain, decimals: 0), isCurrent: ac.uid == wbMainUid, icon: "workbuddy"))
        }

        // 余额面板拖拽只改变平台组顺序；这里按平台前缀重排，保持每组内部账号顺序不变。
        return balancePlatformOrder().flatMap { platformID in
            switch platformID {
            case "ds":
                return entries.filter { $0.id == MenuBarPrefix.ds }
            case "zcode":
                return entries.filter { $0.id.hasPrefix(MenuBarPrefix.zcode) }
            case "codex":
                return entries.filter { $0.id.hasPrefix(MenuBarPrefix.codex) }
            case "trae":
                return entries.filter { $0.id.hasPrefix(MenuBarPrefix.trae) }
            case "wb":
                return entries.filter { $0.id.hasPrefix(MenuBarPrefix.wb) }
            default:
                return []
            }
        }
    }

    // MARK: - 统一格式化标题（用缓存 + 当前小数位）

    /// 对外入口：走 TitleDebouncer，180ms 窗口内多次调用合并为 1~2 次渲染。
    /// 诊断日志：打印每次「请求刷新」次数与真正「位图烘焙」次数，刷新结束后
    /// 用 `call-render=N/M` 判断主线程是否被高频 updateTitle 冲击。
    func updateTitle(tag: String = #function) {
        updateTitleCallCount &+= 1
        let callNo = updateTitleCallCount
        titleDebouncer.dispatch("updateTitle@\(callNo)#\(tag)") { [weak self] in
            self?.updateTitleImpl(tag: "debounced@\(callNo)#\(tag)")
        }
    }

    /// 用户主动操作（右键切换显隐等）的立即通道：跳过去抖当场渲染并应用位图
    /// （菜单栏瞬间反馈），面板位置由 startPanelOriginLock 的 KVO 锁定接管。
    func updateTitle(immediate: Bool, tag: String = #function) {
        guard immediate else { updateTitle(tag: tag); return }
        updateTitleCallCount &+= 1
        let callNo = updateTitleCallCount
        titleDebouncer.flush { [weak self] in
            self?.updateTitleImpl(tag: "immediate@\(callNo)#\(tag)")
        }
    }

    /// 实际绘制：构建 attributed string → 烘焙 3x 位图 template → 赋给 button.image。
    /// 每次都会打印耗时，便于定位「菜单栏位图烘焙太重导致主线程卡顿」。
    /// 上次赋值的内容指纹：相同则跳过烘焙/赋值——每次赋值都会触发系统
    /// NSStatusItem replicant 快照重建（macOS 26 该路径有系统级偶发崩溃，
    /// 见 2026-08-23 11:04 崩溃报告：栈全为 AppKit 内部帧），顺带省烘焙成本。
    private var lastTitleFingerprint: String?

    private func updateTitleImpl(tag: String) {
        let t0 = Date()
        updateTitleRenderCount &+= 1
        let fingerprint = (isOffline ? "offline" : orderedMenuBarEntries()
            .filter { isMenuBarVisible(id: $0.id, isCurrent: $0.isCurrent) }
            .map { "\($0.id):\($0.value)" }
            .joined(separator: "|"))
            + "|size:\(NSFont.menuBarFont(ofSize: 0).pointSize)"
        if fingerprint == lastTitleFingerprint, statusItem.button?.image != nil {
            Logger.log(.refresh, "updateTitleImpl[\(updateTitleRenderCount)] \(tag): unchanged, skip")
            // 面板照常同步（面板内容比菜单栏多，不能因标题未变而漏同步）
            syncPanel()
            return
        }
        lastTitleFingerprint = fingerprint
        // 菜单栏字号 = 系统默认
        let menuSize = NSFont.menuBarFont(ofSize: 0).pointSize
        let baseFont = NSFont.systemFont(ofSize: menuSize, weight: .regular)
        let boldFont = NSFont.systemFont(ofSize: menuSize, weight: .bold)

        // 标题最终整体渲染为单张位图 template 赋给 button.image（见 renderTemplateTitleImage），
        // 因此这里全部用黑色内容构建，着色交给系统状态栏管线
        func makeAttr() -> NSMutableAttributedString {
            NSMutableAttributedString()
        }
        var attr = makeAttr()
        func append(_ s: String, bold: Bool = false) {
            attr.append(NSAttributedString(string: s, attributes: [.font: bold ? boldFont : baseFont, .kern: -0.2]))
        }
        // 货币符号：字号缩小 + 与数值基线对齐（底对齐），样式更精致
        func appendCurrency(_ s: String) {
            let symFont = NSFont.systemFont(ofSize: menuSize * 0.72, weight: .regular)
            attr.append(NSAttributedString(string: s, attributes: [.font: symFont, .kern: -0.2]))
        }
        func attachIcon(named name: String, size: CGFloat, spacing: String = " ") {
            guard let shape = menuBarIconShape(named: name, size: size) else { return }
            let attachment = NSTextAttachment()
            attachment.image = shape
            let y = (baseFont.ascender + baseFont.descender - size) / 2
            attachment.bounds = NSRect(x: 0, y: y, width: size, height: size)
            attr.append(NSAttributedString(attachment: attachment))
            append(spacing)
        }

        // 离线标记：网络不可达时菜单栏只显示离线提示
        if isOffline {
            append("⚠︎ 离线")
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.image = renderTemplateTitleImage(attr)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Logger.log(.refresh, "updateTitleImpl[\(updateTitleRenderCount)] \(tag): offline, \(ms)ms")
            // 面板打开时同步重绘
            syncPanel()
            return
        }

        // 平台图标尺寸 = 菜单栏字号 + 3pt（略大于文本行高）
        let iconSize = menuSize + 3

        var hasContent = false
        for entry in orderedMenuBarEntries() {
            guard isMenuBarVisible(id: entry.id, isCurrent: entry.isCurrent) else { continue }
            if hasContent { append("  \u{2009}") }

            // 平台品牌图标（黑形，随整条标题烘焙进 template 位图）；TRAE 缩小 6%，ZCode 缩小 13%
            let iconScale: CGFloat
            switch entry.icon {
            case "trae-color": iconScale = 0.94
            case "zhipu": iconScale = 0.87
            case "codex": iconScale = 0.90
            default: iconScale = 1.0
            }
            // DeepSeek 图标后用细空格（后面紧跟 ¥ 符号），其余平台保持普通空格
            attachIcon(named: entry.icon, size: iconSize * iconScale, spacing: entry.symbol.isEmpty ? " " : "\u{2009}")

            // 货币符号（仅 DeepSeek 有）：小字号 + 底对齐
            if !entry.symbol.isEmpty { appendCurrency(entry.symbol) }
            append(entry.value, bold: true)
            hasContent = true
        }

        if !hasContent {
            attr = makeAttr()
            appendCurrency("¥")
            append("...", bold: true)
        }

        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.image = renderTemplateTitleImage(attr)

        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let slow = ms >= 10 ? " SLOW!" : ""
        Logger.log(.refresh, "updateTitleImpl[\(updateTitleRenderCount)] \(tag): call-render=\(updateTitleCallCount)/\(updateTitleRenderCount), attrLen=\(attr.length), \(ms)ms\(slow)")

        // 面板打开时同步重绘
        syncPanel()
        // 面板位置锁定由 startPanelOriginLock 的 KVO 接管：origin 偏离时立即无动画拉回
    }

    // MARK: - 请求编排（四服务并行，各自独立更新 UI）

    /// 主刷新流程：离线直接返回；在线则并行拉取四个服务，先到先显示。
    /// 任务被取消时（新刷新已发起）不再写时间戳/停动效，交由新任务收尾。
    /// `totalBudget` 是总超时：超过后先把刷新动效停掉（面板不再显示「刷新中…」），
    /// 避免单个慢接口让菜单栏和面板永远显示「在刷」。
    private func performRefresh(seq: Int64) async {
        let totalBudget: TimeInterval = 45
        let t0 = Date()
        Logger.log(.refresh, "[\(seq)] performRefresh start, isCancelled=\(Task.isCancelled), online=\(NetworkMonitor.shared.isOnline)")
        guard !Task.isCancelled else {
            Logger.log(.refresh, "[\(seq)] performRefresh aborted: already cancelled at entry")
            return
        }
        guard NetworkMonitor.shared.isOnline else {
            isOffline = true
            panelView?.setRefreshing(false)
            Logger.log(.refresh, "[\(seq)] performRefresh offline: stopping spinner")
            titleDebouncer.flush { self.updateTitleImpl(tag: "refresh-offline") }
            return
        }
        isOffline = false
        let cfg = config

        // 总超时守护：45s 后若仍在等待子请求，强制停动效并标记卡住。
        // 用 Task 而非 Task.sleep + cancel，因为取消子 async-let 可能仍挂在 URLSession 上，
        // 这里只保证 UI 不再假死（动效被停），实际网络请求由系统 timeout 自行收尾。
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(totalBudget * 1_000_000_000))
            if Task.isCancelled { return }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Logger.log(.refresh, "[\(seq)] WATCHDOG: refresh NOT finished after \(ms)ms > budget \(Int(totalBudget))s — forcing spinner OFF")
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // 只在「没有比我新的刷新任务启动」时才敢关停效；如果已有新 seq，它会管理动效。
                if self.refreshSeq == seq {
                    self.panelView?.setRefreshing(false)
                    self.titleDebouncer.flush { self.updateTitleImpl(tag: "watchdog-fallback") }
                    self.syncPanel()
                }
            }
        }
        defer { watchdog.cancel() }

        // 服务并行请求，先到先显示：每个服务返回后立即写缓存并重绘标题，互不等待
        async let a: Void = refreshOneDeepSeek(cfg, seq: seq)
        async let b: Void = refreshOneWorkBuddy(cfg, seq: seq)
        async let c: Void = refreshOneTrae(cfg, seq: seq)
        async let e: Void = refreshOneZcode(cfg, seq: seq)
        async let f: Void = refreshOneCodex(cfg, seq: seq)
        _ = await (a, b, c, e, f)

        let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
        Logger.log(.refresh, "[\(seq)] performRefresh all children joined in \(totalMs)ms")

        // 已被取消（被更新的刷新取代）→ 不写收尾状态，避免提前停掉新任务的刷新动效
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] performRefresh aborted: not owner after children joined (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq))")
            return
        }
        // 记录更新时间（面板底部展示）
        lastUpdatedAt = Self.dfClock.string(from: Date())
        lastRefreshTime = Date()  // 记录本次刷新完成时间，用于面板打开时节流
        saveBalanceCache()  // 数值快照落盘，供下次启动秒显
        // 各服务并行返回时已先行刷新菜单栏；这里 flush 一次，确保本轮所有账号最终一致。
        titleDebouncer.flush { self.updateTitleImpl(tag: "refresh-finalize-\(seq)") }
        // 停动效 + 立即恢复 footer 文字（不依赖后续 update 以免 same=true 被跳过）。
        // fallback=makePanelSnapshot() 保证首次刷新（lastSnapshot==nil）时也能写出时间。
        panelView?.setRefreshing(false, fallback: makePanelSnapshot())
        Logger.log(.refresh, "[\(seq)] performRefresh done: refreshing=OFF (total=\(totalMs)ms), updatedAt=\(lastUpdatedAt)")
        // 无论面板是否显示都要写一次 panel：保证 updatedLabel.stringValue 不再停留在"刷新中…"，
        // 同时 failedServices / lastUpdatedAt 直接写入 popover 内的视图，下次开面板的
        // 第一帧就是正确外观（不会先闪"刷新中…"再被 showPanel() 纠正）。
        forceUpdatePanelFooter()
    }

    /// 启动缓存回灌：把上次会话的数值缓存灌回内存并立即绘标题（cache-then-refresh）
    private func restoreBalanceCache() {
        guard let c = BalanceCacheStore.load() else { return }
        if let ds = c.ds { cacheDs = (ds.symbol, ds.totalRaw, ds.total) }
        if let wb = c.wb { cacheWb = (wb.remain, wb.total) }
        cacheWbAccounts = c.wbAccounts.mapValues { ($0.remain, $0.total) }
        cacheTraeAccounts = c.traeAccounts.mapValues { ($0.limit, $0.used) }
        cacheZcodeAccounts = c.zcodeAccounts.mapValues { ($0.remain, $0.total, $0.planEndsAt) }
        cacheCodexAccounts = c.codexAccounts.mapValues { ($0.usedPercent, $0.resetAt) }
        lastUpdatedAt = c.lastUpdatedAt
        if c.lastRefreshTime > 0 { lastRefreshTime = Date(timeIntervalSince1970: c.lastRefreshTime) }
        updateTitle()
    }

    /// 把当前内存数值快照写回磁盘（每轮刷新收尾一次，仅数值与时间，不含凭据）
    private func saveBalanceCache() {
        var c = BalanceCache()
        c.ds = cacheDs.map { .init(symbol: $0.symbol, totalRaw: $0.totalRaw, total: $0.total) }
        c.wb = cacheWb.map { .init(remain: $0.remain, total: $0.total) }
        c.wbAccounts = cacheWbAccounts.mapValues { .init(remain: $0.remain, total: $0.total) }
        c.traeAccounts = cacheTraeAccounts.mapValues { .init(limit: $0.limit, used: $0.used) }
        c.zcodeAccounts = cacheZcodeAccounts.mapValues { .init(remain: $0.remain, total: $0.total, planEndsAt: $0.planEndsAt) }
        c.codexAccounts = cacheCodexAccounts.mapValues { .init(usedPercent: $0.usedPercent, resetAt: $0.resetAt) }
        c.lastUpdatedAt = lastUpdatedAt
        c.lastRefreshTime = lastRefreshTime.timeIntervalSince1970
        BalanceCacheStore.save(c)
    }

    private func refreshOneDeepSeek(_ cfg: AppConfig, seq: Int64) async {
        let t0 = Date()
        guard cfg.deepseekRefreshEnabled else {
            Logger.log(.refresh, "[\(seq)] DeepSeek: disabled, skipped")
            if ownsRefresh(seq) { failedServices.remove("DeepSeek") }
            return
        }
        let ds = await Logger.measure("[\(seq)] DeepSeek.fetch") {
            await DeepSeekService.fetch(apiKey: cfg.deepseekApiKey)
        }
        // 已取消（被新刷新取代）/ 已不是 owner：不写缓存、不动失败标记、不刷 UI，
        // 避免旧结果覆盖新缓存/覆盖新 seq 的「刷新中…」动效。
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] DeepSeek: not owner after fetch (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip writeback")
            return
        }
        if let bal = ds.balance {
            let totalNum = Double(bal.totalRaw) ?? 0
            cacheDs = (bal.symbol, bal.totalRaw, totalNum)
            UsageStore.observe(platform: "ds", uid: "main", value: totalNum, increasing: false)
            if config.deepseekCommonQuota > 0 {
                let used = max(0, config.deepseekCommonQuota - totalNum)
                _ = dsPulsingTracker.observe("main", ratio: min(1, used / config.deepseekCommonQuota))
            } else {
                dsPulsingTracker.reset("main")
            }
            failedServices.remove("DeepSeek")
            Logger.log(.refresh, "[\(seq)] DeepSeek: OK value=\(bal.totalRaw) (elapsed=\(Int(Date().timeIntervalSince(t0)*1000))ms)")
        }
        if !ds.error.isEmpty {
            notify("DeepSeek 余额查询", ds.error)
            failedServices.insert("DeepSeek")
            Logger.log(.refresh, "[\(seq)] DeepSeek: ERROR \(ds.error)")
        }
        updateTitle(tag: "ds-\(seq)")
    }

    func refreshOneWorkBuddy(_ cfg: AppConfig, seq: Int64) async {
        let t0 = Date()
        guard cfg.workbuddyEnabled else {
            Logger.log(.refresh, "[\(seq)] WorkBuddy: disabled, skipped")
            if ownsRefresh(seq) { failedServices.remove("WorkBuddy") }
            return
        }
        // 主账号（当前登录）：用 authInfo 直接查询
        var wbFailed = false
        let mainStart = Date()
        let mainWb: (remain: Double, total: Double)? = await Logger.measure("[\(seq)] WB.main.fetchSummary") {
            await WorkBuddyService.fetchSummary()
        }
        if let wb = mainWb {
            guard ownsRefresh(seq) else {
                Logger.log(.refresh, "[\(seq)] WorkBuddy: not owner after main fetch (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip writeback")
                return
            }
            cacheWb = wb
            if let uid = WorkBuddyService.authInfo()?.uid {
                cacheWbAccounts[uid] = wb
                UsageStore.observe(platform: "wb", uid: uid, value: wb.remain, increasing: false)
                updatePulsingForWb(uid: uid, remain: wb.remain, total: wb.total)
            }
            // 裂变包重置日（副标题）：仅主账号、≥1h 拉一次（get-user-resource 全量包列表）
            if let auth = WorkBuddyService.authInfo(),
               wbFissionFetchedAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                wbFissionFetchedAt = Date()
                if let resetAt = await WorkBuddyService.fetchFissionReset(
                    token: auth.token, uid: auth.uid, domain: auth.domain), ownsRefresh(seq) {
                    cacheWbFission[auth.uid] = resetAt
                    Logger.log(.refresh, "[\(seq)] WB.fission: resetAt=\(resetAt)")
                }
            }
            Logger.log(.refresh, "[\(seq)] WB.main: OK remain=\(wb.remain) total=\(wb.total) (\(Int(Date().timeIntervalSince(mainStart)*1000))ms)")
            updateTitle(tag: "wb-main-\(seq)")
        } else if WorkBuddyService.authInfo() != nil {
            wbFailed = true  // 有登录态但获取失败（未登录则不计）
            Logger.log(.refresh, "[\(seq)] WB.main: fetchSummary returned nil (FAILED)")
        }
        // 多号：遍历其余账号，先刷新 token 再查额度
        let accounts = wbCheckinAccounts()
        Logger.log(.refresh, "[\(seq)] WB: total accounts=\(accounts.count), non-main=\(max(0,accounts.count-1))")
        for (i, ac) in accounts.enumerated() {
            if !ownsRefresh(seq) {
                Logger.log(.refresh, "[\(seq)] WB.sub[\(i)/\(accounts.count)]: not owner (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip remaining")
                return
            }
            if ac.uid == WorkBuddyService.authInfo()?.uid { continue } // 主账号已查
            let acctag = "[\(seq)] WB.sub[\(i)/\(accounts.count)] uid=\(ac.uid)"
            let refreshed = await Logger.measure("\(acctag).refreshToken") {
                await WorkBuddyService.refreshTokenIfNeeded(account: ac)
            }
            if refreshed != ac {
                Logger.log(.refresh, "\(acctag): token refreshed (new expiresAt=\(refreshed.expiresAt))")
                if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                    config.workbuddyAccounts[idx] = refreshed
                    ConfigStore.save(config)
                }
            }
            let fetchTag = "\(acctag).fetchSummary"
            let ft0 = Date()
            if let r = await Logger.measure(fetchTag, {
                await WorkBuddyService.fetchSummaryForAccount(token: refreshed.token, uid: refreshed.uid, domain: refreshed.domain)
            }) {
                guard ownsRefresh(seq) else {
                    Logger.log(.refresh, "\(acctag): not owner after fetch, skip writeback")
                    return
                }
                cacheWbAccounts[refreshed.uid] = r
                UsageStore.observe(platform: "wb", uid: refreshed.uid, value: r.remain, increasing: false)
                updatePulsingForWb(uid: refreshed.uid, remain: r.remain, total: r.total)
                Logger.log(.refresh, "\(acctag): OK remain=\(r.remain) total=\(r.total) (\(Int(Date().timeIntervalSince(ft0)*1000))ms)")
                updateTitle(tag: "wb-sub-\(i)-\(seq)")
            } else if ownsRefresh(seq) {
                wbFailed = true  // 该号 token 刷新或查询失败
                Logger.log(.refresh, "\(acctag): fetchSummaryForAccount returned nil (FAILED)")
            }
        }
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] WorkBuddy: not owner at tail (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip finalize")
            return
        }
        // 收口失败标记：取消 / 新 seq 已接管时走不到这里，避免把失败标记污染本轮
        if wbFailed { failedServices.insert("WorkBuddy") }
        else { failedServices.remove("WorkBuddy") }
        Logger.log(.refresh, "[\(seq)] WorkBuddy: done failed=\(wbFailed) total=\(Int(Date().timeIntervalSince(t0)*1000))ms")
        syncPanel()
        // 补全签到 streak/reward（auto-checkin 关闭时也能显示，与 TRAE 侧对齐）
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] WB.checkinStatus: not owner, skip")
            return
        }
        let cs0 = Date()
        await Logger.measure("[\(seq)] WB.checkinStatusFill") { await wbCheckinStatusFill() }
        Logger.log(.refresh, "[\(seq)] WB.checkinStatusFill done in \(Int(Date().timeIntervalSince(cs0)*1000))ms")
    }

    /// WB 脉冲计算：usedRatio = (total-remain)/total，上升 → pulsing=true（被消耗）；稳定/回升 → false
    private func updatePulsingForWb(uid: String, remain: Double, total: Double) {
        _ = wbPulsingTracker.observe(uid, ratio: total > 0 ? (total - remain) / total : 0)
    }

    // MARK: - ZCode（智谱 Coding Plan）余额刷新

    /// 遍历 config 中导入的 ZCode 账号，逐号查询 Coding Plan 用量（本平台无签到）
    private func refreshOneZcode(_ cfg: AppConfig, seq: Int64) async {
        let t0 = Date()
        guard cfg.zcodeRefreshEnabled else {
            Logger.log(.refresh, "[\(seq)] ZCode: disabled, skipped")
            if ownsRefresh(seq) { failedServices.remove("ZCode") }
            return
        }
        var zcodeFailed = false
        Logger.log(.refresh, "[\(seq)] ZCode: accounts=\(cfg.zcodeAccounts.count)")
        for (i, ac) in cfg.zcodeAccounts.enumerated() {
            if !ownsRefresh(seq) {
                Logger.log(.refresh, "[\(seq)] ZCode[\(i)/\(cfg.zcodeAccounts.count)]: not owner (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip remaining")
                return
            }
            let acctag = "[\(seq)] ZCode[\(i)/\(cfg.zcodeAccounts.count)] uid=\(ac.uid)"
            // 存量账号自动回填昵称（早期导入无 nickname）：credentials.json 可解出且 uid 匹配时写入一次
            if ac.nickname.isEmpty, let nick = ZcodeService.autoNickname(forUid: ac.uid),
               let idx = config.zcodeAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                config.zcodeAccounts[idx].nickname = nick
                ConfigStore.save(config)
            }
            // 到期跳过已移除（对齐 Cockpit）：套餐到期是服务端事实，本地缓存判定会在
            // 用户领取新套餐后永远卡在「已到期」（旧 planEndsAt 挡住新请求）；
            // 每轮真实请求，到期展示交给快照层按最新 planEndsAt 判断
            let r = await Logger.measure("\(acctag).fetchBalance") {
                await ZcodeService.fetchBalance(token: ac.token)
            }
            guard ownsRefresh(seq) else {
                Logger.log(.refresh, "\(acctag): not owner after fetch, skip writeback")
                return
            }
            guard let r = r else {
                zcodeFailed = true  // 请求层失败（token 失效或网络错误）
                Logger.log(.refresh, "\(acctag): request failed, marked failed")
                continue
            }
            guard r.total > 0 else {
                // 查询成功但无有效套餐（全部到期）：不判失败，保留旧缓存继续展示「套餐已到期」
                Logger.log(.refresh, "\(acctag): no active quota, keep last cache")
                zcodePulsingTracker.reset(ac.uid)
                continue
            }
            cacheZcodeAccounts[ac.uid] = r
            UsageStore.observe(platform: "zcode", uid: ac.uid, value: r.remain / r.total * 100, increasing: false)
            _ = zcodePulsingTracker.observe(ac.uid, ratio: (r.total - r.remain) / r.total)
            Logger.log(.refresh, "\(acctag): OK remain=\(r.remain) total=\(r.total)")
            // ZCode 没有主账号单独刷新路径，每个账号写入后立即更新菜单栏。
            updateTitle(tag: "zcode-\(i)-\(seq)")
        }
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] ZCode: not owner at tail, skip finalize")
            return
        }
        if zcodeFailed { failedServices.insert("ZCode") }
        else { failedServices.remove("ZCode") }
        Logger.log(.refresh, "[\(seq)] ZCode: done failed=\(zcodeFailed) total=\(Int(Date().timeIntervalSince(t0)*1000))ms")
        syncPanel()
    }

    // MARK: - Codex usage 刷新

    /// 读取本机 auth.json 后调用官方 usage 接口。Codex usage 返回 used_percent，卡片展示剩余百分比。
    private func refreshOneCodex(_ cfg: AppConfig, seq: Int64) async {
        let t0 = Date()
        guard cfg.codexRefreshEnabled else {
            Logger.log(.refresh, "[\(seq)] Codex: disabled, skipped")
            if ownsRefresh(seq) { failedServices.remove("Codex") }
            return
        }
        var accounts = cfg.codexAccounts
        // auth.json 是当前登录态的权威来源；登录切换后自动更新对应账号 token/email。
        if case .success(let current) = CodexService.importCurrentAccount() {
            if let idx = accounts.firstIndex(where: { $0.uid == current.uid }) {
                accounts[idx] = current
                if let configIdx = config.codexAccounts.firstIndex(where: { $0.uid == current.uid }) {
                    config.codexAccounts[configIdx] = current
                    ConfigStore.save(config)
                }
            } else {
                accounts.append(current)
                if !config.codexAccounts.contains(where: { $0.uid == current.uid }) {
                    config.codexAccounts.append(current)
                    ConfigStore.save(config)
                }
            }
        }
        guard !accounts.isEmpty else {
            Logger.log(.refresh, "[\(seq)] Codex: no accounts, skip")
            if ownsRefresh(seq) { failedServices.remove("Codex") }
            return
        }
        Logger.log(.refresh, "[\(seq)] Codex: accounts=\(accounts.count)")
        var failed = false
        for (i, account) in accounts.enumerated() {
            if !ownsRefresh(seq) {
                Logger.log(.refresh, "[\(seq)] Codex[\(i)/\(accounts.count)] uid=\(account.uid): not owner, skip remaining")
                return
            }
            let acctag = "[\(seq)] Codex[\(i)/\(accounts.count)] uid=\(account.uid)"
            guard let usage = await Logger.measure("\(acctag).fetchUsage", {
                await CodexService.fetchUsage(token: account.token,
                                              fallbackUid: account.uid,
                                              fallbackEmail: account.email)
            }) else {
                if ownsRefresh(seq) {   // 只在仍是 owner 时标记失败，避免污染新 seq
                    failed = true
                }
                Logger.log(.refresh, "\(acctag): fetchUsage returned nil (FAILED)")
                continue
            }
            guard ownsRefresh(seq) else {
                Logger.log(.refresh, "\(acctag): not owner after fetch, skip writeback")
                return
            }
            if let idx = config.codexAccounts.firstIndex(where: { $0.uid == account.uid }),
               !usage.email.isEmpty, config.codexAccounts[idx].email != usage.email {
                config.codexAccounts[idx].email = usage.email
                ConfigStore.save(config)
            }
            cacheCodexAccounts[account.uid] = (usage.usedPercent, usage.resetAt)
            UsageStore.observe(platform: "codex", uid: account.uid, value: usage.usedPercent, increasing: true)
            // usedPercent 上升（额度被消耗）→ 点阵脉冲，规则同其他四平台
            _ = codexPulsingTracker.observe(account.uid, ratio: usage.usedPercent)
            Logger.log(.refresh, "\(acctag): OK used=\(usage.usedPercent)%")
            updateTitle(tag: "codex-\(i)-\(seq)")
        }
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] Codex: not owner at tail, skip finalize")
            return
        }
        if failed { failedServices.insert("Codex") }
        else { failedServices.remove("Codex") }
        Logger.log(.refresh, "[\(seq)] Codex: done failed=\(failed) total=\(Int(Date().timeIntervalSince(t0)*1000))ms")
        syncPanel()
    }

    private func refreshOneTrae(_ cfg: AppConfig, seq: Int64) async {
        let t0 = Date()
        guard cfg.traeRefreshEnabled else {
            Logger.log(.refresh, "[\(seq)] TRAE: disabled, skipped")
            if ownsRefresh(seq) { failedServices.remove("TRAE") }
            return
        }
        // 主账号（当前登录）：从 storage.json 解密查询
        let mainUid = TraeService.readAuthInfo(storagePath: cfg.traeStoragePath)?.uid ?? ""
        var traeFailed = false
        let mainStart = Date()
        let mainTrae: (limit: Double, used: Double)? = await Logger.measure("[\(seq)] TRAE.main.fetchCredits") {
            await TraeService.fetchCredits(storagePath: cfg.traeStoragePath)
        }
        if let t = mainTrae {
            guard ownsRefresh(seq) else {
                Logger.log(.refresh, "[\(seq)] TRAE: not owner after main fetch (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip writeback")
                return
            }
            cacheTrae = t
            if !mainUid.isEmpty {
                cacheTraeAccounts[mainUid] = t
                UsageStore.observe(platform: "trae", uid: mainUid, value: t.used, increasing: true)
                updatePulsingForTrae(uid: mainUid, limit: t.limit, used: t.used)
            }
            Logger.log(.refresh, "[\(seq)] TRAE.main: OK limit=\(t.limit) used=\(t.used) (\(Int(Date().timeIntervalSince(mainStart)*1000))ms)")
            updateTitle(tag: "trae-main-\(seq)")
        } else if !mainUid.isEmpty {
            traeFailed = true  // 有登录态但获取失败（未登录则不计）
            Logger.log(.refresh, "[\(seq)] TRAE.main: fetchCredits returned nil (FAILED)")
        }
        // 多号：遍历 config 中预存的其他账号，用各自加密块解密 token 后查额度
        let subs = config.traeAccounts.filter { $0.uid != mainUid }
        Logger.log(.refresh, "[\(seq)] TRAE: total subs=\(subs.count)")
        for (i, ac) in subs.enumerated() {
            if !ownsRefresh(seq) {
                Logger.log(.refresh, "[\(seq)] TRAE.sub[\(i)/\(subs.count)]: not owner (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip remaining")
                return
            }
            let acctag = "[\(seq)] TRAE.sub[\(i)/\(subs.count)] uid=\(ac.uid)"
            let ft0 = Date()
            if let token = TraeService.getTokenFromEncrypted(ac.encryptedAuthInfo),
               let r = await Logger.measure("\(acctag).fetchCreditsForToken", {
                   await TraeService.fetchCreditsForToken(token)
               }) {
                guard ownsRefresh(seq) else {
                    Logger.log(.refresh, "\(acctag): not owner after fetch, skip writeback")
                    return
                }
                cacheTraeAccounts[ac.uid] = r
                UsageStore.observe(platform: "trae", uid: ac.uid, value: r.used, increasing: true)
                updatePulsingForTrae(uid: ac.uid, limit: r.limit, used: r.used)
                Logger.log(.refresh, "\(acctag): OK limit=\(r.limit) used=\(r.used) (\(Int(Date().timeIntervalSince(ft0)*1000))ms)")
                // 非当前账号也要立即同步菜单栏，不能只刷新面板。
                updateTitle(tag: "trae-sub-\(i)-\(seq)")
            } else if ownsRefresh(seq) {
                traeFailed = true  // 该号解密或获取失败
                Logger.log(.refresh, "\(acctag): FAILED (no token or nil response)")
            }
        }
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] TRAE: not owner at tail, skip finalize")
            return
        }
        if traeFailed { failedServices.insert("TRAE") }
        else { failedServices.remove("TRAE") }
        Logger.log(.refresh, "[\(seq)] TRAE: done failed=\(traeFailed) total=\(Int(Date().timeIntervalSince(t0)*1000))ms")
        syncPanel()
        // 补全签到 streak/reward（auto-checkin 关闭时也能显示）
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] TRAE.checkinStatus: not owner, skip")
            return
        }
        let cs0 = Date()
        await Logger.measure("[\(seq)] TRAE.checkinStatusFill") { await traeCheckinStatusFill() }
        Logger.log(.refresh, "[\(seq)] TRAE.checkinStatusFill done in \(Int(Date().timeIntervalSince(cs0)*1000))ms")
    }

    /// TRAE 脉冲计算：usedRatio = used/limit，上升 → pulsing=true（被消耗）；稳定/回升 → false
    private func updatePulsingForTrae(uid: String, limit: Double, used: Double) {
        _ = traePulsingTracker.observe(uid, ratio: limit > 0 ? used / limit : 0)
    }

    // MARK: - 主菜单（为弹窗输入框提供 Edit 菜单快捷键）

    /// 安装主菜单（App 菜单 + Edit 菜单）。
    /// 菜单栏 App（.accessory）不显示菜单条，但菜单项的 keyEquivalent 仍会被分发：
    /// Edit 菜单的 Cut/Copy/Paste/SelectAll 快捷键会沿响应链到达 NSTextField 的 field editor，
    /// 让弹窗输入框原生支持 Cmd+C/V/X/A、撤销/重做，以及右键菜单。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单（系统约定第一项）
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 iBalance", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 iBalance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Edit 菜单：标准文本编辑命令
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func promptForApiKey(prefill: String = "") -> String? {
        let dialog = InputDialog(title: "请输入 DeepSeek API Key",
                                 info: "在下方粘贴或输入你的 API Key：\n获取地址：",
                                 linkText: "platform.deepseek.com/api_keys",
                                 linkURL: URL(string: "https://platform.deepseek.com/api_keys")!,
                                 prefill: prefill, icon: makeDsBrandIcon())
        return dialog.present()
    }

    // MARK: - Cockpit

    @objc private func onOpenCockpit() {
        openApp(bundleId: config.cockpitAppId, missingTitle: "未找到 Cockpit App",
                missingMsg: "未找到 Bundle ID 为 \(config.cockpitAppId) 的应用，请确认 Cockpit 已安装。")
    }

    /// 通过 Bundle ID 启动应用，找不到时弹出 alert 提示并保持面板不关闭。
    private func openApp(bundleId: String, missingTitle: String, missingMsg: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            let shell = DialogShell()
            shell.addTitle(missingTitle)
            shell.addInfo(missingMsg)
            shell.addButton("好", keyEquivalent: "\r")
            _ = keepPanelAliveDuring { shell.present() }
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: - 工具

    /// 日期/数字格式化器缓存：Formatter 创建开销大，这些工具被每次刷新与签到轮询高频调用，
    /// 统一 static let 复用（DateFormatter macOS 10.9+ 线程安全，后台 Task 中也可用）
    static let dfDay = makeDateFormatter("yyyy-MM-dd")   // 日期（今日/签到日比较）
    private static let dfTime = makeDateFormatter("M-d HH:mm")   // 签到时间展示
    private static let dfClock = makeDateFormatter("HH:mm:ss")   // 面板「更新于」
    private static let dfMonthDay = makeDateFormatter("M-d")     // 签到统计前缀
    /// latestCheckinTime 专用解析器：defaultDate 取当年 1 月 1 日兜底缺失年份
    /// （跨年仅影响近似比较，创建时固定即可，避免共享实例被并发改写）
    private static let dfParseTime: DateFormatter = {
        let df = makeDateFormatter("M-d HH:mm")
        let comps = Calendar.current.dateComponents([.year], from: Date())
        df.defaultDate = Calendar.current.date(from: comps)
        return df
    }()

    private static func makeDateFormatter(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.dateFormat = format
        return df
    }

    static func todayString() -> String {
        dfDay.string(from: Date())
    }

    /// 自动签到错峰：返回账号「今日就绪时间戳」（秒）。key 为该账号的就绪标记 key（UDKey.wb/traeCheckinReady）。
    /// 当天首次遇到该账号时生成 now + 0~600s 随机偏移并持久化（UserDefaults 存 "日期|时间戳"），
    /// 同一天内恒定返回同一值、跨天自动重生成 → 多号在约 10 分钟窗口内随机错开签到，
    /// 避免同一轮询点批量请求触发服务端风控（仿 Cockpit Tools 的 per-account schedule）。
    static func checkinReadyTimestamp(key: String, today: String) -> TimeInterval {
        if let saved = UserDefaults.standard.string(forKey: key) {
            let parts = saved.split(separator: "|")
            if parts.count == 2, parts[0] == today, let ts = TimeInterval(parts[1]) {
                return ts
            }
        }
        let ts = Date().timeIntervalSince1970 + Double.random(in: 0...600)
        UserDefaults.standard.set("\(today)|\(Int(ts))", forKey: key)
        return ts
    }

    /// 风控日手动重试：每账号每天最多放行次数（手动签到对风控退避账号的请求额度）
    static let maxManualRiskRetriesPerDay = 3

    /// 读取风控日手动重试计数（"日期|次数"格式；日期不符自动归零）
    static func manualRetryCount(key: String, today: String) -> Int {
        guard let saved = UserDefaults.standard.string(forKey: key) else { return 0 }
        let parts = saved.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, parts[0] == today, let n = Int(parts[1]) else { return 0 }
        return n
    }

    static func nowTimeString() -> String {
        dfTime.string(from: Date())
    }

    /// 距明天 0 点的秒数（9074 风控拦截后当天不再重试 claim）
    static func secondsUntilTomorrow() -> TimeInterval {
        Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(86400)
            .timeIntervalSinceNow
    }

    /// 取 TRAE / WB 两个签到时间（M-d HH:mm）中较晚的那个；都为空返回 nil。
    /// 同年场景下按月日时分比较；跨年因格式不含年份仅作近似比较。
    static func latestCheckinTime(trae: String, wb: String) -> String? {
        var latest: Date?
        var latestStr: String?
        for str in [trae, wb] where !str.isEmpty {
            guard let d = dfParseTime.date(from: str) else { continue }
            if latest == nil || d > latest! {
                latest = d
                latestStr = str
            }
        }
        return latestStr
    }

    /// 计算签到连续天数：上次签到是昨天 → streak+1；今天已签 → 保持；否则重置为 1
    static func nextStreak(prevDate: String, prevStreak: Int, today: String) -> Int {
        guard !prevDate.isEmpty else { return 1 }
        guard let p = dfDay.date(from: prevDate), let t = dfDay.date(from: today) else { return 1 }
        let diff = Calendar.current.dateComponents([.day], from: p, to: t).day ?? 0
        if diff == 1 { return prevStreak + 1 }
        if diff == 0 { return max(prevStreak, 1) }
        return 1
    }

    /// 到期倒计时文案（ZCode/Codex 共用）：剩余 > 0 → "x天 HH:mm 后到期" / "HH:mm 后到期"（天与数字间细空格）；
    /// 已到期 → nil（由调用方给各自的红色提示文案）
    private static func expireCountdownText(endsAt: TimeInterval, suffix: String = "后重置") -> String? {
        let remainSec = endsAt - Date().timeIntervalSince1970
        guard remainSec > 0 else { return nil }
        let total = Int(remainSec)
        let days = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if days > 0 {
            return String(format: "\u{2009}%d天 %02d:%02d\u{2009}%@", days, h, m, suffix)
        }
        return String(format: "\u{2009}%02d:%02d\u{2009}%@", h, m, suffix)
    }

    /// 通用系统通知通道（余额查询失败 / 切号失败回滚等一次性事件共用）：
    /// title 同时用作请求标识（同标题后发替换先发）。服务级刷新失败走面板 footer 标记
    /// （每轮刷新都会失败，发通知会刷屏），不走这里。
    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ibalance_\(title)", content: content, trigger: nil)) }
    }
}

// MARK: - 入口

/// 显式入口：无 MainMenu.xib 的 App，@NSApplicationMain 不会自动关联 delegate，
/// 会导致 applicationDidFinishLaunching 不触发（菜单栏无任何显示）。
/// 因此手动创建 NSApplication、挂 delegate、设 activationPolicy 并运行。
@main
struct iBalanceMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // 隐藏 Dock（与 Info.plist LSUIElement 双保险）
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

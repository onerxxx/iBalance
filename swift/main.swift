// main.swift — iBalance 入口 + AppDelegate（菜单栏 UI / 定时器 / 编排）
// macOS 菜单栏常驻应用（NSStatusItem），实时汇总多平台余额/积分。
// 不依赖 Python/rumps，编译为单个 .app，内存占用 ~10MB。
// 配置和缓存存放在 ~/Library/Application Support/com.local.ibalance，App 可自由移动或更新。
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// AppDelegate 内部分节   grep "// MARK: -" 一次全列出（菜单栏标题渲染 / 详情面板 / 菜单回调 /
//                       App 自更新 / 请求编排 / ZCode·Codex 刷新 / Cockpit …）
// 面板快照组装           makePanelSnapshot()（消费方 panel.update(...)，快照类型在 Panel.swift）
// 刷新编排               performRefresh(seq:)（多服务并行，各自独立更新 UI）
// 菜单栏标题渲染         updateTitle(tag:) / updateTitle(immediate:tag:) + TitleDebouncer（去抖）
// AppDelegate 扩展       签到 CheckinManager.swift / 账号切换 AccountSwitcher.swift / pin 浮窗 PinWindow.swift
// 服务层（网络查询）      Services/：DeepSeek / BigModelService(智谱) / Qwen / WorkBuddy / Trae / Zcode / Codex
//
// ⚠️ 本文件 = 编排层（入口 + 菜单栏 + 定时器 + 请求调度）。
//    面板视图在 Panel.swift / PanelLayout.swift，控件在 Controls.swift，弹窗在 Dialogs.swift。

import Cocoa
import SettingsUI
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

    private var timer: Timer?
    var checkinTimer: Timer?
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
    /// 正在弹系统 NSAlert：popover 关闭由 alert 让路引发，popoverDidClose 跳过
    /// NSApp.hide（hide 会把刚弹出的 modal alert 一起藏掉 → 弹窗闪退；
    /// alert 结束后由 presentCheckResultAlert 自行归还焦点）
    var isPresentingSystemAlert = false
    private var settingsMenu: NSMenu!
    /// 菜单栏按钮原生右键菜单：仅保留刷新、退出（编译入口 2026-09-06 移除）
    private var statusContextMenu: NSMenu!
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
    // 缓存原始数据，切换小数位时即时重绘（仅在主线程变更）
    private var cacheDs: (symbol: String, totalRaw: String, total: Double)?
    /// ZhiPu（智谱 BigModel）可用余额缓存（元）
    private var cacheBigModelBalance: Double?
    /// ZhiPu 周期锚点：上次见到的累计入账（充值+赠送）、本周期开始时的入账与余额；
    /// 检测到入账跳涨（新充值）即重置锚点 → 点阵回到满格，随本次充值消耗逐步点亮
    private var cacheBigModelInflow: Double?
    private var cacheBigModelCycleStartInflow: Double?
    private var cacheBigModelCycleStartBalance: Double?
    /// 点阵已用比（-1 = 无数据）
    private var cacheBigModelUsedRatio: Double = -1
    /// Qwen（千问 Token Plan）周额度快照缓存（卡片值=周剩余百分比，副标题=到期倒计时）
    private var cacheQwen: QwenService.Quota?
    var cacheWb: (remain: Double, total: Double)?
    /// WorkBuddy 多账号额度缓存：uid → (remain, total)，用于面板显示每号余额卡片
    private var cacheWbAccounts: [String: (remain: Double, total: Double)] = [:]
    /// WB 裂变包重置日（uid → 周期结束时间，副标题显示用）；拉取按小时节流
    private var cacheWbFission: [String: Date] = [:]
    /// 裂变包最近拉取时刻（uid → 时间）：节流用（≥1h 拉一次）。
    /// ⚠️ 必须按 uid 记（同 TRAE 的 traeResetAtAdoptedAt）：单一全局时间戳会让「切号后的新
    /// 主账号」被上一个账号的节流挡住 —— 新账号 cacheWbFission 无值，副标题最长空 1 小时。
    private var wbFissionFetchedAt: [String: Date] = [:]
    var cacheTrae: (limit: Double, used: Double, resetAt: Double)?
    /// TRAE 多账号额度缓存：uid → (limit, used, resetAt)，resetAt 为订阅包重置戳（0=无订阅包）
    var cacheTraeAccounts: [String: (limit: Double, used: Double, resetAt: Double)] = [:]
    /// TRAE 套餐重置点最近采纳时刻（uid → 时间）：resetAt 节流用（≥1h 采纳一次）
    private var traeResetAtAdoptedAt: [String: Date] = [:]
    /// ZCode 多账号额度缓存：uid → (remain, total, planEndsAt)，remain/total 为 token 数，planEndsAt 为免费套餐到期戳（0=无）
    private var cacheZcodeAccounts: [String: (remain: Double, total: Double, planEndsAt: TimeInterval)] = [:]
    /// ZCode 账号级失效集合（token 过期/账号无套餐，业务码 401/500）：不判平台刷新失败，
    /// 仅在卡片悬浮气泡 ID 后挂黄色徽章；每轮刷新重建
    private var zcodeInvalidUids: Set<String> = []
    /// Codex usage 缓存：uid → (usedPercent, resetAt)
    private var cacheCodexAccounts: [String: (usedPercent: Double, resetAt: TimeInterval)] = [:]
    // 点阵脉冲状态：仅由真实数据刷新（refreshOne*）更新，面板开关 syncPanel 只读不写
    // 规则：usedRatio 上升（额度被消耗）→ pulsing=true；稳定或回升 → pulsing=false
    private var traePulsingTracker = PulsingTracker()
    private var wbPulsingTracker = PulsingTracker()
    private var zcodePulsingTracker = PulsingTracker()
    private var dsPulsingTracker = PulsingTracker()
    private var zhipuPulsingTracker = PulsingTracker()
    private var qwenPulsingTracker = PulsingTracker()
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
            step(9.2, "collapse usage") { self.panelView?.toggleSectionForAutoTest("usage") }
            step(10.8, "T3 after collapse") { self.floatingPanelVC?.layoutProbe("T3-after-collapse", force: true) }
            step(11.4, "expand usage") { self.panelView?.toggleSectionForAutoTest("usage") }
            step(13.0, "T4 after expand") { self.floatingPanelVC?.layoutProbe("T4-after-expand", force: true) }
        }

        config = ConfigStore.load()
        // 自建顶层窗口（模态壳 / 更新窗）的外观来源：必须在任何窗口弹出前与配置同步
        Palette.lightThemeActive = config.lightThemeEnabled
        // 主面板字体档运行镜像（Sharp Grotesk 开关）：与外观镜像同处落值 ——
        // `PanelFont` 是全局解析器，任何视图首次构建就要按它取字体，
        // 不能等到第一次 `panel.update` 才同步（否则首帧按系统字体构建）
        PanelFont.sharpGroteskActive = config.cardTitleSharpGrotesk
        // SG 随包字体：这里**无条件注册一次**（2026-09-17 用户「SG字体需要打包进App里」）——
        // `PanelFont.font()` 里那次是懒注册（开关 true 才走），但设置窗口的**预设图卡**按每枚预设
        // 自己记的 SG 开关画字，与主面板这个开关无关 ⇒ 主面板关着 SG 时图卡会命中不了字体。
        // 幂等，重复调用无成本。
        PanelFont.ensureSGRegistered()
        // 数值滚动的滑移时长 / 时间曲线两处镜像 2026-09-17 随「动效的参数固化」移除：
        // 定稿值就在 `RollingNumberView.slideTime()` 与 `rollEase(_:)` 里，不需要镜像落值
        // 副前景色的底色来源：同上，任何视图构建前必须先落值（首次绘制就要按它解算）
        Palette.panelBackgroundActive = config.panelBackgroundColor
        // 遮罩底端不透明度镜像：与底色镜像同处写入（containerColors 读它，各调用点不必传参）
        Palette.panelBackgroundBottomAlphaActive = config.panelBackgroundBottomAlpha
        // 次背景色的运行镜像（2026-09-15 由「点阵背景色」+「hover 背景色」合并为一个参数）：
        // 与底色同处落值 —— 任何视图首次绘制就要按它解算 dynamic color
        Palette.secondaryBackgroundActive = config.secondaryBackgroundColor
        // 主前景色的运行镜像（2026-09-17 随参数开放新增，nil = 内置两档）：任何视图首次绘制前落值
        Palette.foregroundActive = config.panelForegroundColor
        // Codex 登录态来自本机 auth.json；启动时自动纳入账号列表，按钮仍可手动重新导入/更新凭据。
        if case .success(let account) = CodexService.importCurrentAccount(),
           !config.codexAccounts.contains(where: { $0.uid == account.uid }) {
            config.codexAccounts.append(account)
            ConfigStore.save(config)
        }
        // ZCode 同理：credentials.json 为登录态权威来源，当前登录号未导入时自动纳入，
        // 恢复面板「当前账号」大卡片（否则全部卡片按非当前号渲染成小卡片）。
        if case .success(let account) = ZcodeService.importCurrentAccount(),
           !config.zcodeAccounts.contains(where: { $0.uid == account.uid }) {
            config.zcodeAccounts.append(account)
            ConfigStore.save(config)
        }

        // 菜单栏 status item（标题整体渲染为位图 template，见 updateTitle）
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        // WorkBuddy 桌面端凭据为 at-rest 加密（详见 WBAtRestCrypto.swift）：后台预热静态钥，
        // 取钥要走一次 native 探针（拉起 WorkBuddy 自带 Electron，~1s），别等到读 auth 文件时才同步等
        WBAtRestCrypto.warmUp()

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

        let addWbMenuItem = NSMenuItem(title: "添加 WorkBuddy 账号（读取本机登录）…", action: #selector(onAddWbAccount), keyEquivalent: "")
        addWbMenuItem.target = self
        menu.addItem(addWbMenuItem)

        traeCollectMenuItem = NSMenuItem(title: "采集 TRAE 当前账号…", action: #selector(onCollectTraeAccount), keyEquivalent: "")
        traeCollectMenuItem.target = self
        menu.addItem(traeCollectMenuItem)

        menu.addItem(NSMenuItem.separator())

        let apiKeyMenuItem = NSMenuItem(title: "Key / 额度设置…", action: #selector(onSetApiKey), keyEquivalent: "")
        apiKeyMenuItem.target = self
        menu.addItem(apiKeyMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 检查更新：手动入口，全程复用更新窗口（发现新版拉窗，无新版/失败走 NSAlert 终态）
        let checkUpdateItem = NSMenuItem(title: "检查更新…", action: #selector(onCheckForUpdate), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

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
        let contextMenu = NSMenu()
        func contextMenuItem(_ title: String, action: Selector) -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: "")
        }
        contextMenu.addItem(contextMenuItem("🔄  刷新", action: #selector(onRefresh)))
        contextMenu.addItem(contextMenuItem("🚪  退出", action: #selector(onQuit)))
        for item in contextMenu.items { item.target = self }
        statusContextMenu = contextMenu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(onStatusItemClicked)
        // 默认 NSStatusBarButton 只发送左键 action；显式开启右键抬起事件，
        // 让 onStatusItemClicked 能进入原生 context menu 分支。
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.menu = nil

        // 菜单栏平台图标任务状态光晕（MenuBarGlow.swift）：挂到 button 上，
        // 后续由 updateTitleImpl（图标 frame）与任务态轮询（状态变化）驱动同步
        if let btn = statusItem.button {
            menuBarGlow.attach(button: btn)
        }

        // 菜单栏前景色随屏幕聚焦状态变化；macOS 27 不总会主动重绘，手动监听刷新
        observeFocusChanges()

        // 启动时预构建详情面板（一次性），高频点击菜单栏时复用，消除每次弹窗的视图重建/SVG 加载延迟
        buildPanelOnce()

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

        // 隐藏调试/演示开关：--show-panel 启动后自动弹出详情面板；--spin-demo 保持「刷新中…」状态（截图调试用）；
        // --update-demo 循环演示更新窗口全流程 UI（发现新版→下载→校验→安装，不出网不真替换）
        let spinDemo = CommandLine.arguments.contains("--spin-demo")
        if CommandLine.arguments.contains("--show-panel") || spinDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showPanel()
                if spinDemo { self?.panelView?.setRefreshing(true) }
            }
        }
        if CommandLine.arguments.contains("--update-demo") {
            Logger.log(.refresh, "[update-demo] flag detected: \(CommandLine.arguments)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                Logger.log(.refresh, "[update-demo] firing runUpdateDemo")
                self?.runUpdateDemo()
            }
        }

        // Token 用量缓存预热：启动即触发后台构建（此后每 60s 自动重建），
        // 用户 hover 卡片时直接命中缓存，弹面板零等待。
        // 三仓齐预热（ZCode / WB / Codex）：Agent 标题 hover 聚合视图并发收集三仓，
        // 缺一仓缓存则聚合挂起等该仓后台 build 完成才出数——Codex 原先漏预热，
        // 首次 hover 聚合会延迟（甚至面板未开过时聚合卡住等 build）。
        //
        // ⚠️ 2026-09-17 补**到位即刷面板**：卡片副标题那格 tok/s 是从「已建好的缓存」同步只读
        //（`cachedSummary()`），缓存没好时是空的 —— 原先 completion 是空实现，那一格要等下一次
        // 面板刷新（或重开面板）才补上，观感就是「刚打开时 WB 卡片的 token 速度半天不出来」。
        // 现在每轮重建完成都回来刷一次（主线程），卡片那格最迟 60s 内一定跟上。
        ZcodeTokenStore.onRefresh { [weak self] _ in self?.syncPanel() }
        WBTokenStore.onRefresh { [weak self] _ in self?.syncPanel() }
        CodexTokenStore.onRefresh { [weak self] _ in self?.syncPanel() }
        ZcodeTokenStore.fetch { _ in }
        WBTokenStore.fetch { _ in }
        CodexTokenStore.fetch { _ in }

        // WB / ZCode / Codex 任务状态轮询（本机 SQLite/JSONL 单行采样，5s 一轮）：
        // 可见状态变化（含 10 分钟过期归零）时主线程回调同步面板
        AgentTaskStatusStore.startPolling { [weak self] in
            self?.syncPanel()
            // 仅换色无需重烘焙，直接刷新光晕层；圆点出现/消失由 sync 检测并
            // 经 onDotPresenceChanged 触发标题重烘焙（预留间距随存亡）
            self?.menuBarGlow.sync()
        }

        // 自动签到：启动时检查 + 每小时轮询（本地日期守卫，每天最多一次网络请求）
        startCheckinTimer()
        if config.traeAutoCheckin {
            Task { await traeAutoCheckinIfNeeded() }
        }
        if config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }

        // App 自更新：启动 20s 后静默检查 GitHub Releases（每日一次；失败静默）
        scheduleAutoUpdateCheck()
    }

    // MARK: - 菜单栏图标/标题渲染（整条标题烘焙为单张位图 template，赋给 button.image）
    // 只有 button.image 的 template 走系统状态栏自适应管线：
    // 深浅模式（按屏幕）、聚焦变淡、透明菜单栏、菜单打开高亮反色，全部由系统处理；
    // attributedTitle 里的 NSTextAttachment 原样绘制、不进 template 管线（无论是否设 isTemplate），
    // 因此把「平台图标 + 文字」整体画进一张黑形位图再交给系统，是唯一能全状态自适应的做法
    //（原先开头还挂一颗卡片主图标 `credit-card-filled`，后来菜单栏只剩平台条目，该图标与其 SVG 已移除）

    /// 图标形状缓存（iconName → 黑形位图）
    private var menuBarIconShapes: [String: NSImage] = [:]

    /// 菜单栏平台图标任务状态光晕（MenuBarGlow.swift）：WB/ZCode/Codex 有可见任务态时
    /// 对应菜单栏图标前状态圆点（常亮）+ 圆点呼吸光晕；状态映射用 MenuBarPrefix 前缀
    /// 平台条目当前的任务状态（nil = 无状态点）。标题烘焙与光晕层共用同一映射。
    private func menuBarGlowState(for id: String) -> AgentTaskState? {
        if id.hasPrefix(MenuBarPrefix.wb) { return AgentTaskStatusStore.workbuddyVisible }
        if id.hasPrefix(MenuBarPrefix.zcode) { return AgentTaskStatusStore.zcodeVisible }
        if id.hasPrefix(MenuBarPrefix.codex) { return AgentTaskStatusStore.codexVisible }
        return nil
    }

    /// 上次标题烘焙的条目 id 序列与各条目整段区间——排序变化检测 & 滑动动画旧位快照
    private var lastMenuBarIDs: [String] = []
    private var lastMenuBarSpans: [String: NSRect] = [:]

    /// 各条目整段横向区间（图标左缘-2pt → 下一条目内容左缘+2pt，末条目到行尾），
    /// 位图点空间。滑动动画按此区间从旧位图裁出「图标+数值」整段快照。
    private func entrySpans(attr: NSAttributedString,
                            iconInfos: [(rect: NSRect, leftFreeSpace: CGFloat?)],
                            entries: [(id: String, icon: String)]) -> [String: NSRect] {
        let totalW = attr.boundingRect(with: NSSize(width: 10000, height: 100),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        var result: [String: NSRect] = [:]
        for (i, e) in entries.enumerated() {
            guard i < iconInfos.count else { continue }
            let icon = iconInfos[i].rect
            let start = max(0, icon.minX - 2)
            let end: CGFloat
            if i + 1 < iconInfos.count {
                end = iconInfos[i + 1].rect.minX - (iconInfos[i + 1].leftFreeSpace ?? 0) + 2
            } else {
                end = totalW + 2
            }
            guard end > start + 1 else { continue }
            result[e.id] = NSRect(x: start, y: 0, width: end - start, height: 0)
        }
        return result
    }

    private lazy var menuBarGlow: MenuBarStatusGlowController = {
        let c = MenuBarStatusGlowController(stateProvider: { [weak self] in self?.menuBarGlowState(for: $0) })
        // 圆点出现/消失改变标题排版 → 重烘焙标题位图（状态点预留间距随存亡增删）
        c.onDotPresenceChanged = { [weak self] in self?.updateTitle(tag: "dotPresence") }
        // 小球弹跳参数 2026-09-17 起固化（原设置窗口「菜单栏」pane 已移除）：
        // 控制器自带 `MenuBarBounceSettings.fixed`，宿主不再注入
        return c
    }()

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

    /// 标题位图内附件（NSTextAttachment 平台图标）的精确 frame（容器坐标，top-down）。
    /// NSLayoutManager 与 NSString.draw(.usesLineFragmentOrigin) 同一套排版引擎，
    /// 比逐段测量累加 x 更准（kern/字形间距差异全被吸收）；仅在标题重烘焙时调用一次
    /// 解出标题位图内每个附件（平台图标）的 frame 与左侧可用空隙。
    /// leftFreeSpace = 图标前连续空白字形的总宽（即与前一内容的间隔）；nil = 位图最左、左侧无内容。
    private func attachmentRects(in attr: NSAttributedString) -> [(rect: NSRect, leftFreeSpace: CGFloat?)] {
        let ts = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        ts.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 10_000, height: 100))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: attr.length))
        let nsStr = attr.string as NSString
        var rects: [(rect: NSRect, leftFreeSpace: CGFloat?)] = []
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) {
            value, chrRange, _ in
            guard value is NSTextAttachment else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: chrRange, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            // 向前扫连续空白（半角空格 / 细空格），其宽度即图标与左侧内容的间隔
            var wsCount = 0
            while chrRange.location - wsCount - 1 >= 0 {
                let ch = nsStr.character(at: chrRange.location - wsCount - 1)
                if ch == 32 || ch == 0x2009 { wsCount += 1 } else { break }
            }
            let gLoc = glyphRange.location
            let leftFree: CGFloat?
            if chrRange.location == 0 {
                leftFree = nil
            } else if wsCount > 0 {
                let wsCharLoc = chrRange.location - wsCount
                let wsGlyphLoc = lm.glyphRange(forCharacterRange: NSRange(location: wsCharLoc, length: wsCount),
                                               actualCharacterRange: nil).location
                leftFree = lm.location(forGlyphAt: gLoc).x - lm.location(forGlyphAt: wsGlyphLoc).x
            } else {
                leftFree = 0
            }
            rects.append((rect: rect, leftFreeSpace: leftFree))
        }
        return rects
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
        // 主题预设的自动保存还有一条入口：硬币 pane 改的是内嵌 AppKit 面板（改一次落一次盘，
        // 不经过设置窗口模型的 setter），它的通知单独挂这里（见 onCoinSettingsLiveChange）
        nc.addObserver(self, selector: #selector(onCoinSettingsLiveChange),
                       name: .coinSettingsDidChange, object: nil)
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
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.type == .rightMouseDown {
            guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
            NSMenu.popUpContextMenu(statusContextMenu, with: event, for: button)
            return
        }
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
        panel.onQuit = { [weak self] in self?.onQuit() }
        panel.onOpenGitHub = {
            NSWorkspace.shared.open(URL(string: "https://github.com/onerxxx/iBalance")!)
        }
        // header 左上角设置按钮：打开 SwiftUI 设置窗口（侧栏 + 表单，系统设置式）
        panel.onOpenSettings = { [weak self] in self?.openSettingsWindow() }
        // header 平台开关按钮（2026-09-16 新增）：打开同一个设置窗口，直接落到「平台」pane
        panel.onOpenPlatformSettings = { [weak self] in self?.openSettingsWindow(pane: .platforms) }
        // 右上角 pin：置顶常驻——内容转移至无边框 NSPanel 浮动窗口（无箭头、
        // 浮层层级、背景原生拖动）；取消置顶时浮窗直接关闭
        panel.onTogglePin = { [weak self] in self?.togglePanelPin() }
        // 余额卡片点击：DeepSeek 打开浏览器，TRAE / WorkBuddy / ZCode 启动应用
        panel.onClickDeepSeek = {
            NSWorkspace.shared.open(URL(string: "http://127.0.0.1:3080/")!)
        }
        // ZhiPu 卡片点击：打开智谱财务中心（余额页）
        panel.onClickZhiPu = {
            NSWorkspace.shared.open(URL(string: "https://bigmodel.cn/finance-center/finance/overview")!)
        }
        // Qwen 卡片点击：打开千问 Token Plan 计费页
        panel.onClickQwen = {
            NSWorkspace.shared.open(URL(string: "https://platform.qianwenai.com/home/billing/subscription/token-plan-individual")!)
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
            self.openApp(bundleId: "com.tencent.workbuddy.mac", missingTitle: "未找到 WorkBuddy 应用",
                         missingMsg: "未找到 Bundle ID 为 com.tencent.workbuddy.mac 的应用，请确认 WorkBuddy 已安装。")
            self.ensureCurrentAccountInMenuBar(prefix: MenuBarPrefix.wb,
                                               currentUid: WorkBuddyService.authInfo()?.uid)
            self.updateTitle(immediate: true, tag: "card-open-wb")
        }
        panel.onSwitchWbAccount = { [weak self] uid in
            self?.switchWbAccount(uid: uid)
        }
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
        panel.onPlatformOrderChanged = { [weak self, weak panel] order in
            self?.menuBarPlatformOrder = order
            // 拖拽中即时跟手：每次跨行都重烘焙菜单栏并播放缩短版排序动画
            // （quickReorder 0.12s）。链式重入时上一场动画可能未结束，beginReorder
            // 内部会取其目标位图当旧图（按钮 image 是透明占位，不能用）。
            // 松手 endPlatformDrag 再回调一次，序已一致自动跳过。
            if let panel { self?.menuBarGlow.quickReorder = (panel.draggingPlatform != nil) }
            self?.updateTitle()
        }
        let popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        // 外观统一走 Palette.panelAppearance：浅色主题开=强制浅色（不受系统深色影响）；
        // 渐变开=固定深色（深色玻璃+浅色字）；都关=跟随系统外观，浅色主题下面板即原生
        // 浅色 Liquid Glass，文本走 Palette 动态色自动转黑灰
        popover.appearance = Palette.panelAppearance(lightTheme: config.lightThemeEnabled)
        // 满尺寸内容（macOS 14+）：内容视图铺满整个 popover 窗口，顶边伸进系统三角
        // 箭头区，header 的毛玻璃即可一直铺到三角里，箭头与 header 同色（否则箭头是
        // 系统玻璃、header 是自定义玻璃，交界处有色差）。
        // 代价：内容必须锚 safeAreaLayoutGuide（箭头带由 AppKit 写进 safeAreaInsets），
        // 且 preferredContentSize 要额外加回箭头带高度——两处都在 BalancePanelViewController。
        // 浮窗无箭头，safeAreaInsets 恒 0，同一套代码自动等价。
        popover.hasFullSizeContent = true
        let panelVC = BalancePanelViewController(panel: panel)
        // 浮窗 resize 拖动结束：持久化尺寸到 config.json，下次 pin 时恢复
        panelVC.onFloatingSizeChanged = { [weak self] size in
            guard let self else { return }
            self.config.floatingPanelWidth = size.width
            self.config.floatingPanelHeight = size.height
            ConfigStore.save(self.config)
        }
        popover.contentViewController = panelVC
        // 占位尺寸避免零尺寸 popover（宽 = 面板宽度唯一值）；
        // 正式尺寸由 showPanel 用 preferredContentSize（含箭头带高度）覆盖
        popover.contentSize = NSSize(width: BalancePanelViewController.panelWidth,
                                     height: panel.fittingSize.height)
        popoverController = popover
        panelView = panel
        // header 右上角刷新周期饼图：数据源直读自动刷新定时器（repeating Timer 的
        // fireDate 恒为下次触发时刻，本轮起点 = fireDate − 间隔）。手动刷新不重建
        // 定时器、饼图不跳变；applyRefreshInterval 重建定时器后自动跟随，无需另行推送。
        // （contentViewController 赋值已同步触发 loadView → build()，饼图按钮此时已就位）
        panel.onChangeRefreshInterval = { [weak self] seconds in
            self?.applyRefreshInterval(seconds)
        }
        panel.onManualRefresh = { [weak self] in self?.onRefresh() }
        panel.refreshPieButton?.cycleProvider = { [weak self] in
            let interval = self?.config.refreshInterval ?? 60
            guard let fireDate = self?.timer?.fireDate else { return (Date(), interval) }
            return (fireDate.addingTimeInterval(-interval), interval)
        }
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
        // 面板行为按当前态归位：SwiftUI 设置窗口在屏期间保持 applicationDefined
        //（点设置窗口不算「面板外」，面板保持可交互）；平时恢复 transient。
        // 覆盖「设置窗口开着时面板曾被关掉再重开」的窗口期——窗口关闭回调里的
        // endKeepPanelAlive 只对在屏面板生效。
        popover.behavior = SettingsWindowController.shared.isSessionActive
            ? .applicationDefined : .transient
        // 先展示缓存数据（即时响应），再触发自动刷新拿最新
        panel.update(makePanelSnapshot())
        // Token 板块跟随缓存即时上屏：缓存命中同步落位（打开即在）；
        // 冷缓存挂起待后台构建完成补发，数据一到立即显示，不再等 60s 定时器
        panel.refreshInlineTokens()
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
        // 每次打开面板：Token 板块大数字左边那枚小硬币自转一圈（用户 2026-09-11 指定）
        panel.spinInlineCoin()
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

    /// 面板保活（begin）：临时把 popover 行为切为 applicationDefined，防 .transient 把
    /// 「与弹窗交互」误判为「点击面板外」而关闭面板，导致同步模态里点按钮时面板先消失。
    /// 同步模态用 keepPanelAliveDuring 包裹；跨异步的生命周期用 begin/end 手动配对 ——
    /// begin 后必须在流程收口处 end。
    func beginKeepPanelAlive() {
        guard let popover = popoverController, popover.isShown else { return }
        popover.behavior = .applicationDefined
    }

    /// 面板保活收口（end）：恢复「点击面板外自动关闭」。尊重 pin 置顶态（置顶期间本就
    /// 是 applicationDefined，不能被重置回 transient）；SwiftUI 设置窗口在屏期间同样保持
    /// applicationDefined——其他模态（调色气泡、系统弹窗）的收口不得提前解除其保活。
    func endKeepPanelAlive() {
        guard let popover = popoverController, popover.isShown else { return }
        popover.behavior = (popover.contentViewController?.view.window?.level == .floating
                            || SettingsWindowController.shared.isSessionActive)
            ? .applicationDefined : .transient
    }

    /// 同步模态版保活：begin + block + end 三明治。
    /// 注意仅包裹同步模态；异步长流程不要用（如切号重启、浏览器交互），
    /// 否则面板会一直浮在最前。
    func keepPanelAliveDuring<T>(_ block: () -> T) -> T {
        beginKeepPanelAlive()
        defer { endKeepPanelAlive() }
        return block()
    }

    /// 调色盘可见时拒绝 popover 自动关闭：点击 NSColorWell 弹系统调色盘后，
    /// NSColorPanel 抢 key 会让 AppKit 询问 popover 是否关闭，默认返回 true
    /// 会关掉主面板，用户在调色盘里调色时无法看到主面板 hover 实时重染。
    /// 仅在调色盘（NSColorPanel.shared）可见时拒绝；调色盘关掉后即使气泡
    /// 还在也放行——避免用户主动关面板（点图标/切账号/弹 Alert）时被卡住。
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if NSColorPanel.shared.isVisible { return false }
        return true
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
        // 为系统 NSAlert 让路的关闭不 hide：hide 会把刚弹出的 modal alert 一起
        // 藏掉（弹窗一闪即逝的根因）；alert 结束后自行归还焦点
        if isPresentingSystemAlert { return }
        // 非模态更新窗口已打开（演示/手动更新在面板打开时触发 → 窗口成为 key →
        // popover 收起走到这里）：hide 会连它一起藏掉（同一「一闪即逝」根因），
        // 焦点已由该窗口接管，跳过归还
        if updateProgressWinRef?.isVisible ?? false { return }
        // SwiftUI 设置窗口开着（用户点菜单栏图标显式关面板等路径）：hide 会把设置
        // 窗口连坐藏掉（「窗口没消失，重开面板又出现」的根因），焦点由它接管，跳过
        if SettingsWindowController.shared.isSessionActive { return }
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
            let order = ["DeepSeek", "ZhiPu", "Qwen", "WorkBuddy", "TRAE", "ZCode", "Codex"]
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
        // 复用 expireSegments 作为第二行副标题（external-link 图标 + 文本）；
        // 日常额度不再显示，恒为引导文案
        dsSnap.expireSegments = ["打开Harness"]
        if let ds = cacheDs {
            let d = dayDeltaText(platform: "ds", accounts: [(uid: "main", current: ds.total)],
                                 increasing: false, percent: false, decimals: 2, prefix: ds.symbol)
            dsSnap.dayDeltaText = d.text
            dsSnap.dayDeltaDirection = d.direction
        }
        s.dsAccounts = [dsSnap]
        // ZhiPu 卡片：智谱 BigModel 可用余额（同多号管线单元素，uid 恒 "zhipu"，
        // 无前缀 menuBarId → 右键菜单 id 恰为 MenuBarPrefix.zhipu）
        var zpSnap = AccountCardSnapshot(uid: "zhipu", nickname: "", isCurrent: true)
        // 有已用比（周期或回退口径）且余额在 → 恒显点阵；余额超出周期顶点 → 满格绿
        zpSnap.hideDots = !(cacheBigModelUsedRatio >= 0 && cacheBigModelBalance != nil)
        if let bal = cacheBigModelBalance {
            zpSnap.value = "¥" + fmtAmountCommas(bal, decimals: 2)
            if cacheBigModelUsedRatio >= 0 {
                zpSnap.usedRatio = cacheBigModelUsedRatio
            }
            zpSnap.pulsing = zhipuPulsingTracker.isPulsing("main")
            zpSnap.inMenuBar = isMenuBarVisible(id: MenuBarPrefix.zhipu, isCurrent: true)
        }
        zpSnap.expireSegments = ["打开财务中心"]
        if let bal = cacheBigModelBalance {
            let d = dayDeltaText(platform: "zhipu", accounts: [(uid: "zhipu", current: bal)],
                                 increasing: false, percent: false, decimals: 2, prefix: "¥")
            zpSnap.dayDeltaText = d.text
            zpSnap.dayDeltaDirection = d.direction
        }
        s.zhipuAccounts = [zpSnap]
        // Qwen 卡片：千问 Token Plan 周剩余百分比（同多号管线单元素，uid 恒 "qwen"，
        // 无前缀 menuBarId → 右键菜单 id 恰为 MenuBarPrefix.qwen）；副标题为 7 天限额重置倒计时
        var qwSnap = AccountCardSnapshot(uid: "qwen", nickname: "", isCurrent: true)
        if let q = cacheQwen, q.weekLimit > 0 {
            let pct = q.weekRem / q.weekLimit * 100
            qwSnap.value = fmtAmountCommas(pct, decimals: 1) + "%"
            qwSnap.usedRatio = min(1, max(0, 1 - pct / 100))
            qwSnap.pulsing = qwenPulsingTracker.isPulsing("main")
            qwSnap.inMenuBar = isMenuBarVisible(id: MenuBarPrefix.qwen, isCurrent: true)
            // 副标题优先 = 7 天限额重置倒计时（同 WB/TRAE resetAt 口径）；
            // 旧缓存无该字段或重置时刻已过 → 回落原套餐到期倒计时
            if q.weekResetAt > 0, let text = Self.expireCountdownText(endsAt: q.weekResetAt) {
                qwSnap.expireSegments = text
            } else if q.expireAt > 0 {
                if let text = Self.expireCountdownText(endsAt: q.expireAt) {
                    qwSnap.expireSegments = text
                } else {
                    qwSnap.expired = true
                    qwSnap.expireSegments = ["套餐已到期"]
                }
            }
        }
        // Qwen 点阵恒显示：usedRatio=0 表示「本周一点没用」（满格全绿），有展示意义——
        // 与 DS 的「0=没配置额度」语义不同，不套用 DS 的未消耗隐藏口径
        if let q = cacheQwen, q.weekLimit > 0 {
            let d = dayDeltaText(platform: "qwen",
                                 accounts: [(uid: "qwen", current: q.weekRem / q.weekLimit * 100)],
                                 increasing: false, percent: true, decimals: 1)
            qwSnap.dayDeltaText = d.text
            qwSnap.dayDeltaDirection = d.direction
        }
        s.qwenAccounts = [qwSnap]
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
                // 套餐重置时间副标题（仅当前账号）：订阅包 next_billing_time 倒计时
                if isCurrent, c.resetAt > 0 {
                    snap.expireSegments = Self.expireCountdownText(endsAt: c.resetAt)
                }
            }
            snap.checkinDone = UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(ac.uid)) == today
            // TRAE 卡片不再显示任何签到角标（2026-09-10 用户定稿）：失败/风控标记仍照常
            // 写入 UserDefaults（菜单栏统计、签到历史口径不变），仅卡片快照不置位
            // checkinFailed/checkinRisk，角标（红失败/橙风控）随之隐藏
            snap.streak = UserDefaults.standard.integer(forKey: UDKey.traeCheckinStreak(ac.uid))
            snap.reward = UserDefaults.standard.integer(forKey: UDKey.traeCheckinReward(ac.uid))
            snap.pulsing = traePulsingTracker.isPulsing(ac.uid)
            // TRAE 无会话级 token 数据源 → speedText 恒 nil，副标题 meta 隐藏
            s.traeAccounts.append(snap)
        }
        // WorkBuddy 多账号余额卡片：当前账号排最上
        let mainUid = WorkBuddyService.authInfo()?.uid ?? ""
        let accounts = wbCheckinAccounts().sorted { a, b in
            if a.uid == mainUid { return true }
            if b.uid == mainUid { return false }
            return false
        }
        let wbSpeed = Self.tokSpeedText(WBTokenStore.cachedSummary()?.recentSessionSpeed)
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
            snap.speedText = wbSpeed
            // 任务状态光环（仅当前账号）：进行中=蓝 / 完成=绿 / 中断=橙红（完成与中断最多显示 5 分钟）
            if isCurrent {
                snap.taskState = AgentTaskStatusStore.workbuddyVisible
            }
            // 裂变包重置日副标题（仅当前账号显示）：「裂变包 M-d 重置」
            if isCurrent, let resetAt = cacheWbFission[ac.uid] {
                snap.expireSegments = Self.expireCountdownText(endsAt: resetAt.timeIntervalSince1970)
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
        let zcodeSpeed = Self.tokSpeedText(ZcodeTokenStore.cachedSummary()?.recentSessionSpeed)
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
                        snap.expireSegments = text
                    } else {
                        // Start Plan 已到期：卡片显示"套餐已到期"（中性灰，2026-08-27 取消红色提示），且不再参与定时刷新
                        snap.expired = true
                        snap.expireSegments = ["套餐已到期"]
                    }
                }
            } else {
                // 兜底（2026-09-22 用户指定）：取不到套餐与余额/积分（无缓存，或查询无有效套餐 /
                // 账号级失效且从未成功过一次）→ 余额固定 0%，当前账号副标题显示「当前无可用套餐」，
                // 不留「—」空白态。已有旧缓存的账号不受影响（上面分支按旧数据展示，本轮继续保留）。
                snap.value = "0%"
                snap.usedRatio = 1
                if isCurrent {
                    snap.expireSegments = ["无可用套餐"]
                }
            }
            snap.pulsing = zcodePulsingTracker.isPulsing(ac.uid)
            // 任务状态光环（仅当前账号）：进行中=蓝 / 完成=绿 / 中断=橙红（完成与中断最多显示 5 分钟）
            if isCurrent {
                snap.taskState = AgentTaskStatusStore.zcodeVisible
            }
            snap.tokenInvalid = zcodeInvalidUids.contains(ac.uid)
            snap.speedText = zcodeSpeed
            s.zcodeAccounts.append(snap)
        }
        // Codex 多账号 usage 卡片：当前 auth.json 对应账号排首位，昵称固定显示邮箱。
        let codexMainUid = CodexService.currentUid() ?? ""
        let codexAccountsList = config.codexAccounts.sorted { a, b in
            if a.uid == codexMainUid { return true }
            if b.uid == codexMainUid { return false }
            return false
        }
        let codexSpeed = Self.tokSpeedText(CodexTokenStore.cachedSummary()?.recentSessionSpeed)
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
                    snap.expireSegments = Self.expireCountdownText(endsAt: c.resetAt) ?? ["已到期"]
                }
            }
            snap.pulsing = codexPulsingTracker.isPulsing(ac.uid)
            snap.speedText = codexSpeed
            // Codex Desktop/CLI 的 rollout 事件流：仅当前账号挂接 Agent 三态光环。
            if isCurrent {
                snap.taskState = AgentTaskStatusStore.codexVisible
            }
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
            let uids = accounts.map(\.uid)
            // 周历史页：从本周回溯到该平台最早有记录的周（usage.json 保留 60 天 ≈ 最多 8 页）
            var cal = Calendar.current
            cal.firstWeekday = 2
            let currentWeekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
            var maxOffset = 0
            if let earliest = UsageStore.earliestUsageDate(platform: platform, uids: uids) {
                let firstWeekStart = cal.dateInterval(of: .weekOfYear, for: earliest)?.start ?? earliest
                let dayDiff = cal.dateComponents([.day], from: firstWeekStart, to: currentWeekStart).day ?? 0
                if dayDiff > 0 { maxOffset = min(8, Int(ceil(Double(dayDiff) / 7))) }
            }
            let rangeFmt = DateFormatter()
            rangeFmt.locale = Locale.current
            rangeFmt.dateFormat = "M/d"
            var weeks: [UsageWeekData] = []
            for offset in 0...maxOffset {
                let daily = UsageStore.weeklyUsage(platform: platform, uids: uids, weekOffset: offset)
                let texts = daily.map { prefix + fmtUsage($0, percent: percent, decimals: decimals) }
                if offset == 0 {
                    weeks.append(UsageWeekData(daily: daily, dailyTexts: texts,
                                               headerLabel: "本周累计用量",
                                               totalText: prefix + fmtUsage(u.week, percent: percent, decimals: decimals)))
                } else if let weekStart = cal.date(byAdding: .day, value: -7 * offset, to: currentWeekStart),
                          let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) {
                    // 历史周：右上角数值 = 每日快照加总，表头标签 =「8-25~8-31累计用量」
                    let total = daily.reduce(0, +)
                    weeks.append(UsageWeekData(daily: daily, dailyTexts: texts,
                                               headerLabel: "\(rangeFmt.string(from: weekStart))~\(rangeFmt.string(from: weekEnd))累计用量",
                                               totalText: prefix + fmtUsage(total, percent: percent, decimals: decimals)))
                }
            }
            return UsageRowSnapshot(platform: platform, icon: icon, name: name,
                                    todayText: prefix + fmtUsage(u.today, percent: percent, decimals: decimals),
                                    weekText: prefix + fmtUsage(u.week, percent: percent, decimals: decimals),
                                    historyWeeks: weeks)
        }
        // 卡片副标题右侧 meta（2026-09-13 用户改版）：过去 24h 的积分/余额**变化量**
        //（UsageStore.balanceChange24h，恒有值：无数据/无变化 = 0 → 右箭头 + 0，
        // 用户指定不再隐藏）。箭头方向 = 卡片显示值的变化：变多 up / 变少 down /
        // 平 flat——已用型平台（TRAE used/Codex usedPercent，increasing=true，
        // observe 的值随消耗上升）按取反翻成剩余口径。数值 = 变化量绝对值（方向由
        // 箭头表达），前缀/小数/百分比口径同用量行；flat 阈值 = 格式化后读作 0 的
        // 界限（百分比一位小数 0.05 / 两位小数 0.005），箭头图标与 2pt 固定间隔由
        // Panel 侧 stack 布局提供
        func dayDeltaText(platform: String, accounts: [(uid: String, current: Double)],
                          increasing: Bool, percent: Bool, decimals: Int, prefix: String = "") -> (text: String, direction: DayDeltaDirection) {
            let delta = UsageStore.balanceChange24h(platform: platform, accounts: accounts,
                                                    increasing: increasing)
            let cardDelta = increasing ? -delta : delta
            let direction: DayDeltaDirection
            if abs(cardDelta) < (percent ? 0.05 : 0.005) {
                direction = .flat
            } else {
                direction = cardDelta > 0 ? .up : .down
            }
            return (prefix + fmtUsage(abs(cardDelta), percent: percent, decimals: decimals), direction)
        }
        if let ds = cacheDs,
           let row = usageRow(icon: "deepseek", name: "DeepSeek", platform: "ds",
                              accounts: [(uid: "main", current: ds.total)], increasing: false,
                              decimals: 2, percent: false, prefix: ds.symbol) {
            s.usageRows.append(row)
        }
        if let bal = cacheBigModelBalance,
           let row = usageRow(icon: "zhipu", name: "ZhiPu", platform: "zhipu",
                              accounts: [(uid: "zhipu", current: bal)], increasing: false,
                              decimals: 2, percent: false, prefix: "¥") {
            s.usageRows.append(row)
        }
        // Qwen 用量行：周剩余额度百分比的消耗（百分点，同 ZCode 行口径）
        if let q = cacheQwen, q.weekLimit > 0,
           let row = usageRow(icon: "qwen", name: "Qwen", platform: "qwen",
                              accounts: [(uid: "qwen", current: q.weekRem / q.weekLimit * 100)],
                              increasing: false, decimals: 1, percent: true) {
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
        // 数值滚动预览开关状态（设置卡片开关：余额数值周期随机变化演示滚动）
        s.valueScrollPreviewEnabled = config.valueScrollPreviewEnabled
        // 自动检查更新开关状态（设置卡片开关：GitHub Releases 启动静默检查）
        s.updateAutoCheckEnabled = config.updateAutoCheck
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
        s.refreshIntervalSeconds = Int(config.refreshInterval)
        s.panelBackgroundColor = config.panelBackgroundColor
        s.panelBackgroundBottomAlpha = config.panelBackgroundBottomAlpha
        s.lightThemeEnabled = config.lightThemeEnabled
        s.cardTitleFontSize = config.cardTitleFontSize
        s.cardTitleSharpGrotesk = config.cardTitleSharpGrotesk
        s.longProgressCard = config.longProgressCard
        s.nativeRollingNumber = config.nativeRollingNumber
        s.iconThemeSwap = config.iconThemeSwap
        s.iconNoBorder = config.iconNoBorder
        // 数值滚动的滑移时长 / 时间曲线（2026-09-16 新增）2026-09-17 已固化：不再进快照
        return s
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
        // 任一来源的刷新（定时/手动/网络恢复/开面板）都把自动周期重置为
        // 「现在起再等一个间隔」：饼图锚定 timer.fireDate，重建定时器后走满
        // 一圈才到下次刷新，与「本轮已刷新」的直觉一致
        restartRefreshTimer()
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

    /// 应用刷新间隔（面板饼图按钮右键菜单）：写配置、重启 Timer
    private func applyRefreshInterval(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        config.refreshInterval = interval
        restartRefreshTimer()
        ConfigStore.save(config)
        syncPanel()
    }

    /// 重建自动刷新定时器（启动 / applyRefreshInterval 改档 / onRefresh 重置周期共用）
    private func restartRefreshTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: config.refreshInterval,
                                     target: self,
                                     selector: #selector(onRefresh),
                                     userInfo: nil,
                                     repeats: true)
    }

    // MARK: - SwiftUI 设置窗口（header 设置按钮）

    /// 装配设置窗口模型：动作全部转发既有 AppDelegate 回调（与设置行/状态栏菜单项同一条链路），
    /// 状态快照复用面板快照的设置段（单一事实源），然后打开窗口。
    /// `pane` 指定落点：右键「Key / 额度设置…」直接定位到该 pane（面板无对应入口）。
    private func openSettingsWindow(pane: SettingsSidebarItem = .appearance) {
        var actions = AppSettingsActions()
        actions.setRefreshInterval = { [weak self] in self?.applyRefreshInterval(TimeInterval($0)) }
        actions.toggleAutoCheckin = { [weak self] want in
            guard let self, want != (config.traeAutoCheckin || config.workbuddyAutoCheckin) else { return }
            onToggleAutoCheckin()
        }
        actions.toggleAutoUpdateCheck = { [weak self] want in
            guard let self, want != config.updateAutoCheck else { return }
            onToggleUpdateAutoCheck()
        }
        actions.checkForUpdate = { [weak self] in self?.onCheckForUpdate() }
        actions.runUpdateDemo = { [weak self] in self?.runUpdateDemo() }
        actions.addWbAccount = { [weak self] in self?.onAddWbAccount() }
        actions.addTraeAccount = { [weak self] in self?.onCollectTraeAccount() }
        actions.addZcodeAccount = { [weak self] in self?.onAddZcodeAccount() }
        actions.addCodexAccount = { [weak self] in self?.onAddCodexAccount() }
        actions.deleteAccount = { [weak self] platform, uid in
            self?.onDeleteAccount(platform: platform, uid: uid)
        }
        actions.saveKeyQuota = { [weak self] key, quota, zhipu, qwen in
            self?.applyKeyQuota(apiKey: key, quota: quota, zhipuToken: zhipu, qwenTicket: qwen)
        }
        actions.manualCheckin = { [weak self] in self?.onManualCheckin() }
        actions.showCheckinHistory = { [weak self] in self?.onShowCheckinHistory() }
        actions.shareWbHistory = { [weak self] in self?.onShareWbHistory() }
        // ── 「主题外观」pane：面板/卡片开关 + 底色色盘 ──
        // 开关沿用面板既有的翻转式实现（读 config 取反），传期望值时先比对再翻；
        // 点阵色相/饱和度直接落 Palette（UserDefaults 持久化）并对当前面板就地重绘
        actions.setPanelBackgroundColor = { [weak self] color in
            self?.applyPanelBackgroundColor(color)
        }
        // 底端不透明度滑杆（顶端即上面那个色盘/顶部滑杆的 alpha，两端各自独立）
        actions.setPanelBackgroundBottomAlpha = { [weak self] v in
            self?.applyPanelBackgroundBottomAlpha(v)
        }
        // 主前景色（2026-09-17 开放）：落盘 + 运行时镜像 + 面板就地重刷
        actions.setPanelForegroundColor = { [weak self] color in
            self?.applyPanelForegroundColor(color)
        }
        actions.setLightTheme = { [weak self] want in
            guard let self, want != config.lightThemeEnabled else { return }
            onToggleLightTheme()
        }
        actions.setIconThemeSwap = { [weak self] want in
            guard let self, want != config.iconThemeSwap else { return }
            onToggleIconThemeSwap()
        }
        actions.setIconNoBorder = { [weak self] want in
            guard let self, want != config.iconNoBorder else { return }
            onToggleIconNoBorder()
        }
        // ── 卡片主标题字体（字号滑杆 + Sharp Grotesk 开关）──
        // 直接写 config 即可：syncPanel → panel.update 快照比对到变化后就地重刷标题
        actions.setCardTitleFontSize = { [weak self] size in
            guard let self, size != config.cardTitleFontSize else { return }
            config.cardTitleFontSize = size
            ConfigStore.save(config)
            syncPanel()
        }
        actions.setCardTitleSharpGrotesk = { [weak self] on in
            guard let self, on != config.cardTitleSharpGrotesk else { return }
            config.cardTitleSharpGrotesk = on
            ConfigStore.save(config)
            syncPanel()
        }
        // 主副标题行距系数（系统字体 / SG 两档）2026-09-15 已**固化**：滑杆、config 键与
        // 两个 setter 一并移除，真值 = BalancePanelView.cardTitleGapScaleSFFixed / SGFixed
        //（面板侧只读常量，不再经快照同步）
        actions.setLongProgressCard = { [weak self] want in
            guard let self, want != config.longProgressCard else { return }
            onToggleLongProgressCard()
        }
        // 原生滚动数字（2026-09-20）：写 config + 落盘 + 镜像给数值视图；**不重建卡片** ——
        // 下一次数值变化就走新引擎（切换那一刻屏上的数字不动，语义与「无感换挡」一致）
        actions.setNativeRollingNumber = { [weak self] want in
            guard let self, want != config.nativeRollingNumber else { return }
            config.nativeRollingNumber = want
            ConfigStore.save(config)
            syncPanel()
        }
        // 数值滚动的滑移时长口径（`roll_slide_timing`）与时间曲线档位（`roll_curve`）
        // 2026-09-17 用户「动效的参数固化，移除参数开放」：两个 config 键、设置窗口「动效」整段、
        // 两个 setter 与静态镜像一并移除 —— 定稿值（跟随位移 / 从快到慢）写进
        // `RollingNumberView.slideTime()` 与 `rollEase(_:)`
        // 用量色（色盘拾色）：分解出的 HSB 三参一把落值 → 面板就地重绘点阵与卡片边框
        actions.setHeatColor = { [weak self] hue, saturation, brightness in
            self?.panelView?.applyHeatColor(hue: CGFloat(hue),
                                            saturation: CGFloat(saturation),
                                            brightness: CGFloat(brightness))
        }
        // 次背景色（2026-09-15 由「点阵背景色」+「hover 背景色」合并）：落盘 + 镜像 + 就地重绘
        actions.setSecondaryBackgroundColor = { [weak self] color in
            self?.applySecondaryBackgroundColor(color)
        }
        // 「主题预设」（2026-09-15 用户要求，「主题外观」页顶部）：新增 / 应用 / 改名 / 删除 ——
        // **内置那几枚的常量在代码里**（`ThemePreset.builtIns`，身份不可删不可改名），
        // 但**值可改**：改动会以「同 id 覆盖条目」落进 UserDefaults（ThemePresetStore），
        // 列表装配时用它盖掉常量（见 `themePresetList()`）；用户自建的也走 ThemePresetStore。
        // 「已修改」标记与本值另存 `ThemePresetEditStore`；应用见 applyThemePreset 的逐项落值说明
        actions.saveThemePreset = { [weak self] preset in self?.saveThemePreset(preset) }
        actions.applyThemePreset = { [weak self] preset in self?.applyThemePreset(preset) }
        // 「认下改动」（2026-09-22 起：改动本来就自动写回预设，这个按钮只剩「把当前外观
        // 认作本值」这一件事）
        actions.updateThemePreset = { [weak self] id in self?.updateThemePreset(id: id) }
        // 「重置」（2026-09-22）：把这枚预设连同当前外观恢复成它的本值 + 摘掉「已修改」
        actions.resetThemePreset = { [weak self] id in self?.resetThemePreset(id: id) }
        // 「恢复初始」（2026-09-22）：同样恢复 + 摘标记，但目标是 **App 初始默认参数**
        //（内置 = 出厂那套常量 / 自建 = 新建那一刻）—— 「认下」会把本值前移，认下过之后
        // 只有这一枚能回出厂，这正是用户要的「保存为默认值之后依然能重置为初始默认」
        actions.restoreInitialThemePreset = { [weak self] id in
            self?.restoreInitialThemePreset(id: id)
        }
        actions.deleteThemePreset = { [weak self] id in self?.deleteThemePreset(id: id) }
        actions.renameThemePreset = { [weak self] id, name in
            self?.renameThemePreset(id: id, name: name)
        }
        actions.about = { [weak self] in self?.onAbout() }
        // 「关于」pane 备份：导出打当前 config 全量；导入只走磁盘（覆盖写回后重启生效），
        // 不碰内存态 —— 重启后由 ConfigStore.load 统一装载
        actions.exportBackup = { [weak self] in
            guard let self else { return }
            BackupService.export(config: self.config)
        }
        actions.importBackup = { BackupService.importBackup() }
        // 设置窗口「平台」pane：定高表格，**勾选即生效**（保存链路见 applyPlatformConfig）
        SettingsWindowController.shared.platformConfig = { [weak self] in self?.config }
        SettingsWindowController.shared.applyPlatformConfig = { [weak self] in
            self?.applyPlatformConfig($0)
        }
        SettingsWindowController.shared.configure(
            actions: actions,
            snapshot: { [weak self] in
                guard let self else { return AppSettingsSnapshot() }
                // 「外观改动自动保存」的**唯一挂钩点**：设置窗口每次回读快照（= 每次改完某项
                // 参数后的 `sync()`）都在这里过一道 —— 命中「最后应用的那枚自建预设」且当前
                // 外观已与它不同，就把当前外观写回它 + 打上「已修改」标记（见该方法注释）。
                // 挂钩点选在回读而不是逐个 setter：外观落值路径有十来条（色盘 / 滑杆 / 开关 /
                // 硬币 pane），它们全都汇到这一次回读上
                // ⚠️ 顺序不能反：先写盘再建快照 —— 否则返回的这份里预设值 / 已修改集合还是
                // 上一刻的，图卡会慢一拍（写盘只在真有差异时发生，没差异就是白读一次）
                let live = self.makeSettingsSnapshot()
                if self.autoSaveAppearanceToAppliedPreset(live) {
                    return self.makeSettingsSnapshot()
                }
                return live
            },
            // 平台品牌图标：复用面板查表（<平台>.png = macOS27 ClearDark / ClearLight / 同名 SVG）。
            // 请求里带深浅档与「无边框」标志 —— 账号行固定 dark + 带边框，
            // 「主题预设」图卡按预设外观 + 两个图标开关解档
            iconProvider: { BalancePanelView.brandIcon($0) },
            // 「主题预设」图卡右下那枚币 = **真实 3D 硬币**离屏渲染（当前几何/工艺/姿态 +
            // 预设的视觉身份四项），每枚预设每种尺寸只算一次，见 CoinThumbnailRenderer
            coinThumbnail: { CoinThumbnailRenderer.image(identity: $0, box: $1) })
        // 2026-09-12 用户要求：关设置窗口时，主面板一并收起 —— 免得「面板 → 设置」这条路径
        // 走完留下一块只在保活态下才活着、又没人负责关的面板。
        // 顺序：先 endKeepPanelAlive（把 behavior 从 .applicationDefined 恢复），再 performClose；
        // 反过来会让 popoverDidClose 先跑完，endKeepPanelAlive 里的 `guard popover.isShown` 直接 return
        // （虽然下次 showPanel 会重设 behavior，但保持既有语义更稳）。
        SettingsWindowController.shared.onClose = { [weak self] in
            guard let self else { return }
            self.endKeepPanelAlive()
            if self.popoverController?.isShown == true {
                self.popoverController?.performClose(nil)
            }
        }
        // 保活先于上屏：设置窗口抢 key 瞬间若 popover 还是 .transient，会被判「面板外
        // 点击」关闭 → popoverDidClose 的 NSApp.hide 连坐藏掉设置窗口（「一开就没」根因）
        beginKeepPanelAlive()
        SettingsWindowController.shared.open(pane: pane)
    }

    /// 主菜单「文件 → 关闭窗口」（⌘W）落到这里：只关设置窗口，不碰当时的 key window。
    /// 真正关窗在 `SettingsWindowController.close()`（走标准 performClose 流程）。
    @objc private func onCloseSettingsWindow() {
        SettingsWindowController.shared.close()
    }

    /// 设置窗口状态快照：取自面板快照的设置段（与面板设置行同口径，含异常间隔归一 300）
    private func makeSettingsSnapshot() -> AppSettingsSnapshot {
        let s = makePanelSnapshot()
        let interval = s.refreshIntervalSeconds
        // 「已保存账号」逐平台分组（2026-09-13 用户要求）：空平台不出现。
        // name 取各平台展示名（ZCode 走 displayName = 昵称/uid 尾号，Codex 邮箱优先），
        // detail 统一给 uid 便于区分同名账号；iconKey 与面板卡片图标名同源
        let accountGroups = [
            SavedAccountGroup(id: "workbuddy", platform: "WorkBuddy", iconKey: "workbuddy",
                              accounts: config.workbuddyAccounts.map {
                                  .init(id: $0.uid, name: $0.nickname, detail: $0.uid) }),
            SavedAccountGroup(id: "trae", platform: "TRAE", iconKey: "trae-color",
                              accounts: config.traeAccounts.map {
                                  .init(id: $0.uid,
                                        name: $0.username.isEmpty ? $0.uid : $0.username,
                                        detail: $0.uid) }),
            SavedAccountGroup(id: "zcode", platform: "ZCode", iconKey: "zhipu",
                              accounts: config.zcodeAccounts.map {
                                  .init(id: $0.uid, name: $0.displayName, detail: $0.uid) }),
            SavedAccountGroup(id: "codex", platform: "Codex", iconKey: "codex",
                              accounts: config.codexAccounts.map {
                                  .init(id: $0.uid,
                                        name: $0.email.isEmpty ? $0.uid : $0.email,
                                        detail: $0.email.isEmpty ? "" : $0.uid) }),
        ].filter { !$0.accounts.isEmpty }
        // 3D 硬币的视觉身份四项（本页没有控件，只为「主题预设」代读，见 ThemePreset 注释）：
        // 取盘值而不是某处的内存副本 —— 弹窗 / 设置窗口两个调参入口都是「改一次落一次盘」，
        // 磁盘才是权威
        let coin = CoinSettings.load()
        return AppSettingsSnapshot(
            refreshInterval: [60, 180, 300].contains(interval) ? interval : 300,
            autoCheckin: s.traeAutoCheckin || s.wbAutoCheckin,
            autoCheckinSub: s.lastCheckinTime ?? "",
            autoUpdateCheck: s.updateAutoCheckEnabled,
            apiKey: config.deepseekApiKey,
            commonQuota: config.deepseekCommonQuota,
            zhipuToken: config.bigmodelTokenOverride,
            qwenTicket: config.qwenTicketOverride,
            savedAccountGroups: accountGroups,
            panelBackgroundColor: config.panelBackgroundColor,
            panelBackgroundBottomAlpha: config.panelBackgroundBottomAlpha,
            lightThemeEnabled: config.lightThemeEnabled,
            iconThemeSwap: config.iconThemeSwap,
            iconNoBorder: config.iconNoBorder,
            longProgressCard: config.longProgressCard,
            cardTitleFontSize: config.cardTitleFontSize,
            cardTitleSharpGrotesk: config.cardTitleSharpGrotesk,
            nativeRollingNumber: config.nativeRollingNumber,
            heatHue: Double(Palette.heatPeakHue),
            heatSaturation: Double(Palette.heatPeakSaturation),
            heatBrightness: Double(Palette.heatPeakBrightness),
            secondaryBackgroundColor: config.secondaryBackgroundColor,
            panelForegroundColor: config.panelForegroundColor,
            coinPreset: coin.preset.rawValue,
            coinAppearance: coin.appearance.rawValue,
            coinMaterialColor: coin.materialColor.hex,
            coinFieldColor: coin.fieldColor.hex,
            // 预设列表 = **内置（代码里）+ 用户自建（UserDefaults）**，内置恒在前面。
            // ⚠️ 内置那几枚**改过之后以存储里的覆盖条目为准**（见 themePresetList）
            themePresets: themePresetList(),
            // 「已修改」标记（粘性）+ 自动保存的目标（UserDefaults，见 `ThemePresetEditStore`）
            appliedPresetID: UserDefaults.standard.string(forKey: UDKey.appliedThemePresetID),
            modifiedPresetIDs: ThemePresetEditStore.load().modified,
            // 图卡动作栏的可见性：标记 ∪「现在 ≠ 初始值」—— 「认下」摘标记之后动作栏不能跟着消失
            //（否则「保存为默认值之后依然能恢复初始默认」这条就没入口了），见 `differingFromInitialPresetIDs`
            differingPresetIDs: differingFromInitialPresetIDs())
    }

    /// 面板「面板背景色」（设置窗口色盘拾色 / 顶部不透明度滑杆）：写配置并经快照同步重绘遮罩
    private func applyPanelBackgroundColor(_ color: PanelBackgroundColor) {
        config.panelBackgroundColor = color
        ConfigStore.save(config)
        // 副前景色（Palette.secondaryForeground）按底色解算对比度，镜像必须同步落值，
        // 否则面板已换底色、副文本还按旧底色解算
        Palette.panelBackgroundActive = color
        syncPanel()
    }

    /// 面板底色遮罩**底端**不透明度（设置窗口滑杆）：写配置 + 同步镜像 + 重绘遮罩
    private func applyPanelBackgroundBottomAlpha(_ v: Double) {
        config.panelBackgroundBottomAlpha = min(max(v, 0), 1)
        ConfigStore.save(config)
        Palette.panelBackgroundBottomAlphaActive = config.panelBackgroundBottomAlpha
        syncPanel()
    }

    /// **主前景色**（设置窗口色盘，2026-09-17 开放）：写配置 + 运行时镜像 + 面板就地重刷。
    /// 动态色（`Palette.cardForeground`）在重绘时经 provider 读 `Palette.foregroundActive` 重解算；
    /// 定格值（icon 着色 / 菜单栏圆点 layer）由 `refreshCardForeground` 显式重灌
    private func applyPanelForegroundColor(_ color: PanelBackgroundColor) {
        guard color != config.panelForegroundColor else { return }
        // 文字色不带透明度语义：色盘也不透出，这里再钳一道（写盘的值即所画的值）
        config.panelForegroundColor = color.withAlpha(1)
        ConfigStore.save(config)
        Palette.foregroundActive = config.panelForegroundColor
        syncPanel()
        panelView?.refreshCardForeground()
    }

    /// **次背景色**（设置窗口「面板 → 次背景色」色盘，2026-09-15 由「点阵背景色」+
    /// 「hover 背景色」合并而来）：写配置 + 同步镜像 + 就地重绘
    ///（无用量底点/轨道底/骨架行是自绘或烘色位图，卡片 hover 材质块是 .cgColor 落 layer 的，
    /// 都必须走 `refreshDotMatrixAndHoverMaterials` 清缓存 + 整树重绘）
    private func applySecondaryBackgroundColor(_ color: PanelBackgroundColor) {
        guard color != config.secondaryBackgroundColor else { return }
        config.secondaryBackgroundColor = color
        ConfigStore.save(config)
        Palette.secondaryBackgroundActive = color
        panelView?.refreshDotMatrixAndHoverMaterials()
    }

    // MARK: - 主题预设（设置窗口「主题外观」页顶部）

    /// 新增一组主题预设（图卡右上角「+」）：把「主题外观」页当前的全部参数固化成一枚，**追加**到列表末尾。
    /// 2026-09-17 用户改版后不再有「名称输入框」，名字由模型自动给「预设 N」，**也就不再做重名检查** ——
    /// 同名只是显示重了（id 才是身份），旧那套「覆盖确认」弹窗随输入框一起删除。
    ///
    /// 2026-09-22：新增即**认作当前生效的那枚**（`recordAppliedThemePreset`）—— 这枚预设就是
    /// 「当前外观」的照片，此后改外观自动写回它（本值 = 它自己，见 `ThemePresetEditStore`）
    private func saveThemePreset(_ preset: ThemePreset) {
        ThemePresetStore.save(ThemePresetStore.load() + [preset])
        recordAppliedThemePreset(preset.id)
    }

    /// 改名一枚主题预设（点图卡下方的名字就地改，模型侧 Enter 才调到这里）：
    /// 按 id 找到用户自建的那条、换名后整表写回；id 不在（内置 / 已被删）什么都不做
    private func renameThemePreset(id: String, name: String) {
        var list = ThemePresetStore.load()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = name
        ThemePresetStore.save(list)
    }

    /// 「认下改动」（2026-09-22 起语义收窄）：外观改动本来就**自动写回**预设，这个按钮只剩一件事 ——
    /// 把这枚预设的**当前值认作它的本值** + 摘掉「已修改」，此后「重置」回到这一刻。
    ///
    /// ⚠️ 刻意**不写「当前外观」**：这枚卡不一定是当前生效的那枚（点了别的预设后它照样亮着
    /// 「已修改」），那种时候「当前外观」是**别人**的值，写进去等于拿别人的外观砸掉这枚预设
    /// （自动保存只写「最后应用的那枚」，所以两边的值本来就是分开的）。
    /// 内置六枚没有「更新」入口（改不了代码里那枚常量，`ThemePresetStore` 里也没有它们的条目）
    private func updateThemePreset(id: String) {
        guard let current = themePresetValues(id: id) else { return }
        var state = ThemePresetEditStore.load()
        state.origins[id] = current
        state.modified.remove(id)
        ThemePresetEditStore.save(state)
    }

    /// 「重置」（2026-09-22）：把这枚预设**连同当前外观**恢复成它的本值 + 摘掉「已修改」——
    /// 唯一能摘掉标记的入口（改回原值、点别的预设卡都不摘）。
    ///
    /// 本值缺（这枚从没被应用过 / 编辑状态被清了）时什么都不做：没有「原本的值」可回。
    /// 落盘分两种：自建那枚把本值写回存储；**内置六枚**的本值就是出厂常量 ⇒ 把它在存储里的
    /// **覆盖条目删掉**（不留一份与常量逐字段相同的副本，与 `ThemePresetStore.load()` 的归一同一口径），
    /// 列表随即从常量取值
    private func resetThemePreset(id: String) {
        let state = ThemePresetEditStore.load()
        guard var restored = state.origins[id] else { return }
        restored.id = id
        var list = ThemePresetStore.load()
        if let index = list.firstIndex(where: { $0.id == id }) {
            restored.name = list[index].name     // 名字以当前为准：改名不该被回滚
            if ThemePreset.builtIns.contains(restored) {
                list.remove(at: index)           // 本值 = 出厂常量 → 覆盖条目直接删
            } else {
                list[index] = restored
            }
            ThemePresetStore.save(list)
        }
        applyThemePreset(restored)               // 逐项落值 + 记 appliedID（本值已存在，不会被覆盖）
        var after = ThemePresetEditStore.load()
        after.modified.remove(id)
        ThemePresetEditStore.save(after)
    }

    /// 「恢复初始」（2026-09-22 用户「把参数保存为默认值之后，依然可以重置为 app 的初始默认参数」）：
    /// 把这枚预设**连同当前外观**恢复成它的**初始值** —— 内置六枚 = 代码里出厂那套常量；
    /// 自建 = **新建那一刻**的快照（`ThemePresetEditStore.initials`，「认下」动不了它）。
    ///
    /// 与「重置」的唯一差别是目标：重置回**本值**（会随「认下」前移），这一枚回**初始**。
    /// 落盘口径同 `resetThemePreset`：内置写回的是出厂常量 ⇒ 把存储里的覆盖条目删掉；自建把那枚改回初始值。
    /// 顺手把**本值也归位**成初始值 —— 恢复初始之后这枚预设的状态与「刚建出来、没动过」逐项一致，
    /// 不留「当前值 = 初始值、本值却在别处」的悬挂状态
    private func restoreInitialThemePreset(id: String) {
        let state = ThemePresetEditStore.load()
        guard var restored = initialThemePreset(id: id, state: state) else { return }
        restored.id = id
        var list = ThemePresetStore.load()
        if let index = list.firstIndex(where: { $0.id == id }) {
            restored.name = list[index].name     // 名字以当前为准：改名不该被回滚
            if ThemePreset.builtIns.contains(restored) {
                list.remove(at: index)           // 初始值 = 出厂常量 → 覆盖条目直接删
            } else {
                list[index] = restored
            }
            ThemePresetStore.save(list)
        }
        applyThemePreset(restored)               // 逐项落值 + 记 appliedID（本值已存在，不会被覆盖）
        var after = ThemePresetEditStore.load()
        after.origins[id] = restored             // 本值归位（见方法注释）
        after.modified.remove(id)
        ThemePresetEditStore.save(after)
    }

    /// 记下「最后应用（/ 新建）的预设 id」，并给还没记过本值 / 初始值的预设补一份。
    ///
    /// **本值**（`origins`）= 应用它那一刻的样子，「重置」恢复的目标。
    /// **初始值**（`initials`）= 新建它那一刻的样子，「恢复初始」恢复的目标 —— 只管**自建**那几枚：
    /// 内置六枚的初始值就是代码里那枚常量（`ThemePreset.builtIns`），在存储里再记一份只会与常量漂移。
    /// ⚠️ 两者都**已记过就不改写**：外观改动会自动写回预设，若每次都拿「当前值」当本值，
    /// 「重置」就永远回到改完的样子 = 形同虚设
    private func recordAppliedThemePreset(_ id: String) {
        UserDefaults.standard.set(id, forKey: UDKey.appliedThemePresetID)
        var state = ThemePresetEditStore.load()
        let current = themePresetValues(id: id)
        var dirty = false
        if state.origins[id] == nil, let current {
            state.origins[id] = current
            dirty = true
        }
        if !ThemePreset.builtInIDs.contains(id), state.initials[id] == nil, let current {
            state.initials[id] = current
            dirty = true
        }
        if dirty { ThemePresetEditStore.save(state) }
    }

    /// 按 id 取一枚预设的**当前值**：先查存储（自建那枚 / 内置的**覆盖条目**），再落到代码里的
    /// 内置常量。都查不到 = nil（例如预设已被删）。
    /// ⚠️ 顺序不能反：内置被改过之后，存储里那份才是权威值
    private func themePresetValues(id: String) -> ThemePreset? {
        ThemePresetStore.load().first { $0.id == id } ?? ThemePreset.builtIns.first { $0.id == id }
    }

    /// 按 id 取一枚预设的**初始值**（= App 初始默认参数）：既是「恢复初始」的目标，也是「动作栏露不露」的基准。
    /// - 内置六枚：**代码里出厂那套常量**（故意不看存储 —— 存储里那份是被改过的覆盖条目）
    /// - 自建那几枚：`ThemePresetEditStore.initials`（新建那一刻的快照，认下动不了它）
    /// ⚠️ `state.origins[id]` 那一段是**老状态的迁移口**（本版之前建的预设没记初始值，只能拿本值顶一次），
    /// 不是常驻兜底 —— 记上 `initials` 之后就不会再被走到
    private func initialThemePreset(id: String, state: ThemePresetEditStore.State) -> ThemePreset? {
        ThemePreset.builtIns.first { $0.id == id } ?? state.initials[id] ?? state.origins[id]
    }

    /// **与初始值不同**的预设 id 集合（图卡动作栏的可见性判据，见 `AppSettingsSnapshot.differingPresetIDs`）。
    /// **现算不落盘**：初始值本身不会动，但「当前值」随自动保存一直在变 —— 存一份立刻就会过期
    private func differingFromInitialPresetIDs() -> Set<String> {
        let state = ThemePresetEditStore.load()
        var ids: Set<String> = []
        for preset in themePresetList() {
            guard let initial = initialThemePreset(id: preset.id, state: state) else { continue }
            if !preset.matches(initial) { ids.insert(preset.id) }
        }
        return ids
    }

    /// 「主题预设」列表（设置窗口「主题外观」页顶部）：内置六枚在前（保持出厂顺序）、用户自建在后。
    ///
    /// ⚠️ 内置那几枚**有覆盖条目就用覆盖那份** —— 改过内置预设之后值存在 `ThemePresetStore`
    /// 里（同 id），这里不换过来的话图卡画的还是出厂常量，用户看到的就是「改了没保存」
    ///（同 id 两条也不能一起丢进列表：`ForEach` 的 id 会撞）。
    private func themePresetList() -> [ThemePreset] {
        let stored = ThemePresetStore.load()
        let overrides = stored.filter { ThemePreset.builtInIDs.contains($0.id) }
        let userMade = stored.filter { !ThemePreset.builtInIDs.contains($0.id) }
        return ThemePreset.builtIns.map { builtin in
            overrides.first { $0.id == builtin.id } ?? builtin
        } + userMade
    }

    /// **外观改动的自动保存**（2026-09-22 用户要求「已修改状态需要自动保存，直到点击重置」）：
    /// 把当前外观写回**最后应用的那枚预设**，并给它打上「已修改」标记。返回是否动了盘。
    ///
    /// - 写回一律落到 `ThemePresetStore`：自建那枚直接覆盖；**内置六枚在存储里建一份同 id 的
    ///   覆盖条目**（常量写死在代码里改不得）—— 覆盖条目从此刻起就是这枚预设的权威值
    ///  （`themePresetValues` / `themePresetList` 都先查存储）。⚠️ 早先的版本对内置「只打标记
    ///   不写值」，结果内置预设改了跟没改一样（用户当天反馈「默认的六个主题，修改后数据没有正常保存」）
    /// - **标记是粘性的**：任何一次差异打上，之后改回原值 / 切到别的预设都不摘 ——
    ///   只在这里加，只在 `resetThemePreset` 摘
    /// - 本值（`origins`）只在**首次应用**那一刻记一次：自动保存会把改动写进预设，
    ///   不另存一份的话「重置」就无处可回
    /// - 调用点见设置窗口的 snapshot 闭包（每次回读快照过一道）与 `.coinSettingsDidChange`
    ///  （硬币 pane 是内嵌 AppKit，不走模型 sync）
    @discardableResult
    private func autoSaveAppearanceToAppliedPreset(_ live: AppSettingsSnapshot) -> Bool {
        guard let id = UserDefaults.standard.string(forKey: UDKey.appliedThemePresetID),
              let stored = themePresetValues(id: id),
              !stored.matches(live) else { return false }
        var state = ThemePresetEditStore.load()
        // 本值缺（老状态 / 手工清过）→ 以它此刻的值兜一份，别让「重置」无处可回
        if state.origins[id] == nil { state.origins[id] = stored }
        state.modified.insert(id)
        ThemePresetEditStore.save(state)
        // 写回：名字沿用当前那份（自建的可能被改过名；内置六枚没有改名入口）
        var list = ThemePresetStore.load()
        var updated = ThemePreset(name: stored.name, snapshot: live)
        updated.id = id
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index] = updated
        } else {
            list.append(updated)     // 内置六枚第一次被改：这里建覆盖条目
        }
        ThemePresetStore.save(list)
        return true
    }

    /// 「3D 硬币」pane 的实时改动（`CoinSettingsBox` 那条通知，19 个参数一个出口）：硬币的
    /// **视觉身份四项**（Preset / Style 档 + 币面色 + 色场色）属于预设内容，在硬币 pane 改它们
    /// 等于在改当前那枚预设。那条 pane 改一次直接落盘、不经过模型 setter，所以单独挂一次。
    /// 几何 / 工艺 / 运动那几项不在预设里 —— `matches` 比对不过，什么都不写
    /// ⚠️ 「应用预设」写那 4 个键时不发这条通知（见 `applyCoinIdentity`），成不了回头环
    @objc private func onCoinSettingsLiveChange() {
        guard SettingsWindowController.shared.isSessionActive else { return }
        autoSaveAppearanceToAppliedPreset(makeSettingsSnapshot())
    }

    /// 删除一组主题预设（按 id 命中；不存在时什么都不做）
    private func deleteThemePreset(id: String) {
        let list = ThemePresetStore.load()
        guard list.contains(where: { $0.id == id }) else { return }
        ThemePresetStore.save(list.filter { $0.id != id })
        // 编辑状态一并忘掉（本值 + 已修改），别在存储里留孤儿条目；
        // 删的正是「最后应用的那枚」时把指针也清掉 —— 否则下次改外观会去写一枚不存在的预设
        ThemePresetEditStore.forget(id: id)
        if UserDefaults.standard.string(forKey: UDKey.appliedThemePresetID) == id {
            UserDefaults.standard.removeObject(forKey: UDKey.appliedThemePresetID)
        }
    }

    /// 应用一组主题预设：**逐项按预设里的值原样落值，不走任何派生 / 翻转逻辑** ——
    /// 预设是「固化那一刻」的照片，应用必须精确还原。尤其「浅色主题」这一项：
    /// 走 `onToggleLightTheme` 会按「本就暗的才翻」规则改掉预设里的底色与次背景色，
    /// 所以这里直接写 config + 落盘，不碰翻转。
    private func applyThemePreset(_ preset: ThemePreset) {
        // 用量色：HSB 三参一把写（Palette 的 setter 自带 UserDefaults 持久化，
        // 与面板色盘 `applyHeatColor` 同一份存储）
        Palette.heatPeakHue = CGFloat(preset.heatHue)
        Palette.heatPeakSaturation = CGFloat(preset.heatSaturation)
        Palette.heatPeakBrightness = CGFloat(preset.heatBrightness)
        config.panelBackgroundColor = preset.panelBackgroundColor
        config.panelBackgroundBottomAlpha = preset.panelBackgroundBottomAlpha
        config.secondaryBackgroundColor = preset.secondaryBackgroundColor
        // 主前景色（2026-09-17 随参数开放进预设）：**原样写回可选值** ——
        // 预设是「固化那一刻的照片」，逐项还原才对得上「点图卡即应用」；
        // nil（内置预设 / 老预设）= 回落内置两档
        config.panelForegroundColor = preset.panelForegroundColor
        config.lightThemeEnabled = preset.lightThemeEnabled
        config.iconThemeSwap = preset.iconThemeSwap
        config.iconNoBorder = preset.iconNoBorder
        config.longProgressCard = preset.longProgressCard
        config.cardTitleFontSize = preset.cardTitleFontSize
        config.cardTitleSharpGrotesk = preset.cardTitleSharpGrotesk
        ConfigStore.save(config)
        // 记下「刚应用的是这枚」= 此后**自动保存**的目标（改任何外观参数都写回它）；
        // 同时给它补一份本值（首次应用那一刻的样子，「重置」回到这里）。
        // 点图卡 = 干净态：值本来就是这枚的，不会因此亮「已修改」
        recordAppliedThemePreset(preset.id)
        // 运行镜像：与 `onToggleLightTheme` 同一组（自建顶层窗口外观、副前景色按底色解算、
        // 遮罩两端不透明度、次背景色都读它们），漏一个就会出现「面板换了、弹窗还是旧色」
        Palette.lightThemeActive = config.lightThemeEnabled
        Palette.panelBackgroundActive = config.panelBackgroundColor
        Palette.panelBackgroundBottomAlphaActive = config.panelBackgroundBottomAlpha
        Palette.secondaryBackgroundActive = config.secondaryBackgroundColor
        // 主前景色镜像（nil = 内置两档）：面板侧动态色在重绘时重解算，
        // 定格值（icon 着色 / 菜单栏圆点）由下面的 refreshCardForeground 补
        Palette.foregroundActive = config.panelForegroundColor
        updateProgressWinRef?.applyThemeAppearance()
        // popover 窗口外观（含箭头）必须同步重设，否则停在上一档主题
        popoverController?.appearance = Palette.panelAppearance(lightTheme: config.lightThemeEnabled)
        // 面板同步：底色 / 浅色主题 / 字号 / 字体档 / 图标互换 / 长进度卡片 由 panel.update
        // 自己比对后重绘；**点阵峰值色与次背景色不在那个比对分支里**（点阵与 hover 材质是
        // 自绘 / 烘色位图），由下面这一次整树重绘补齐 —— 同一个入口清缓存 + 重解算材质
        syncPanel()
        panelView?.refreshDotMatrixAndHoverMaterials()
        // 主前景色的定格值消费点（icon 着色 / 菜单栏圆点）也要跟上：整树标脏 + 换图标
        panelView?.refreshCardForeground()
        applyCoinIdentity(from: preset)
    }

    /// 预设里的 3D 硬币**视觉身份**四项写回（Preset / Style 两档 + 币面色 + 色场色）。
    ///
    /// ⚠️ 只写这 4 个键，**不能**走 `CoinSettings.save()` —— 那是整份快照落盘，会把预设里
    /// 根本没有的几何 / 工艺 / 运动 / logo 项一起盖掉（那些不属于主题，见 `ThemePreset` 注释）。
    /// 写盘后两个消费点各自回灌：设置窗口「3D 硬币」pane 的参数区 + 主面板内嵌小硬币。
    private func applyCoinIdentity(from preset: ThemePreset) {
        let defaults = UserDefaults.standard
        defaults.set(preset.coinPreset, forKey: UDKey.coinPreset)
        defaults.set(preset.coinAppearance, forKey: UDKey.coinAppearance)
        defaults.set(preset.coinMaterialColor, forKey: UDKey.coinMaterialColor)
        defaults.set(preset.coinFieldColor, forKey: UDKey.coinFieldColor)
        // ① 设置窗口 pane：建过才回灌（没建过就不必 —— 建的时候按当时的磁盘值初始化控件）
        SettingsWindowController.shared.reloadCoinPanelIfNeeded()
        // ② 主面板内嵌小硬币：按盘值重灌（与弹窗关闭后那条复位路径同一个入口）。
        // ⚠️ 这一句不能省：pane 没建过时 ① 是空操作，那条路上一声通知都不会发
        panelView?.reloadInlineCoinSettings()
    }

    /// 浅色主题：开启后强制浅色外观（即使系统是深色主题）；优先级高于渐变开关。
    /// 保存后经快照同步，VC 容器/popover/子面板统一换外观。
    ///
    /// 2026-09-14 用户要求：开关**同步翻转「面板背景色」的亮度** —— 只换外观不换底色的话，
    /// 「浅色外观 + 近黑遮罩」叠出来面板还是深色，等于白开；所以开 → 底色翻浅、关 → 翻回深，
    /// 双向都是同一个翻转（明度取反，色相/饱和度/不透明度不变，见 `brightnessFlipped`）。
    /// 落盘的是翻转后的真实颜色，设置窗口色盘即所见即所得；翻转只做一次，来回切换可精确还原。
    ///
    /// 2026-09-14 追加（用户要求）：**打开浅色主题时底色已亮于 50% 就不翻** ——
    /// 浅色外观要的正是亮底，把用户自选的亮底翻成暗底等于又把面板按回深色；
    /// 明度 ≤ 50% 的暗底照旧翻。关闭方向不变，仍按原逻辑无条件翻转。
    @objc private func onToggleLightTheme() {
        config.lightThemeEnabled.toggle()
        let bg = config.panelBackgroundColor
        if config.lightThemeEnabled, bg.brightness <= 0.5 {
            config.panelBackgroundColor = bg.brightnessFlipped
        }
        // 次背景色（2026-09-15 由「点阵背景色」+「hover 背景色」合并）：与底色**同一条规则** ——
        // 开浅色主题时"本就暗的才翻"（已是亮色则保持），关时无条件翻回；
        // 翻转是明度取反的自反操作，来回切换可精确还原（默认值翻转后 ≈ 旧内置浅色档 #d6d6d6）
        if config.lightThemeEnabled {
            if config.secondaryBackgroundColor.brightness <= 0.5 {
                config.secondaryBackgroundColor = config.secondaryBackgroundColor.brightnessFlipped
            }
        } else {
            config.secondaryBackgroundColor = config.secondaryBackgroundColor.brightnessFlipped
        }
        ConfigStore.save(config)
        // 自建顶层窗口的外观镜像：模态壳在 present 时读它，已开着的更新窗立即重染
        Palette.lightThemeActive = config.lightThemeEnabled
        // 底色镜像同步（翻转后的颜色才是面板实际画的底色，副前景色按它解算）
        Palette.panelBackgroundActive = config.panelBackgroundColor
        Palette.secondaryBackgroundActive = config.secondaryBackgroundColor
        updateProgressWinRef?.applyThemeAppearance()
        // popover 窗口外观（含箭头）必须同步重设，否则停留在启动时的主题
        popoverController?.appearance = Palette.panelAppearance(lightTheme: config.lightThemeEnabled)
        syncPanel()
    }

    /// 数值滚动预览：切换开关（余额数值周期随机变化演示滚动；关闭恢复真实数值）。
    @objc private func onToggleValueScrollPreview() {
        config.valueScrollPreviewEnabled.toggle()
        ConfigStore.save(config)
        syncPanel()
    }

    /// 长进度卡片：余额卡片进度条独占整行（左缘=主标题最左）+ 副标题下移一行
    ///（design/balance-card-mode.html 口径），保存后经快照同步重建卡片
    @objc private func onToggleLongProgressCard() {
        config.longProgressCard.toggle()
        ConfigStore.save(config)
        syncPanel()
    }

    /// 图标深浅互换：切换开关（余额卡片品牌 icon ClearDark ↔ ClearLight 版本互换，仅影响 icon）
    @objc private func onToggleIconThemeSwap() {
        config.iconThemeSwap.toggle()
        ConfigStore.save(config)
        syncPanel()
    }

    /// 无边框图标：切换开关（品牌 icon 改用同名 SVG 原图，不套 Icon Composer 底板；
    /// 仅影响 icon。宿主面板按快照比对后在 `swapBrandIconsInPlace` 里就地换图）
    @objc private func onToggleIconNoBorder() {
        config.iconNoBorder.toggle()
        ConfigStore.save(config)
        syncPanel()
    }

    /// 平台开关落盘（设置窗口「平台」pane 每次勾选变化即调，已无「保存」按钮）：落盘后同步右键菜单、
    /// 自动签到定时器和面板状态。2026-09-12 由玻璃弹窗迁入设置窗口，先「保存按钮」后改「勾选即生效」。
    /// ⚠️ 这里是**整份替换**（`config = updated`），安全的前提是 `updated` 的合并基为宿主此刻的配置 ——
    /// 由 `SettingsWindow.applyPlatformConfigNow()` 现取传入（`makeConfig(basingOn:)`）。一旦谁把基换回
    /// 「建表时的快照」，本函数就会把表格之外的改动整份打回旧值（菜单栏显隐 / 账号列表 / 外观参数）
    private func applyPlatformConfig(_ updated: AppConfig) {
        let oldConfig = config
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

    @objc private func onAbout() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let shell = DialogShell()
        // 面板工具类弹窗统一用 App 图标快照（见 Dialogs.makeAppIconSnapshot 注释）
        shell.addIcon(makeAppIconSnapshot())
        shell.addTitle("关于 iBalance")
        // 长文阅读类弹窗：内容宽 +8 抵消 sidePadding 增量，再 +20 加宽正文行宽
        shell.contentWidth = DialogMetrics.width + 8 + 20
        shell.addInfo("菜单栏常驻小工具，实时聚合多个 AI 服务的余额与额度。\n\n"
            + "• DeepSeek 余额（官方 API 查询）\n• ZhiPu 余额（浏览器登录态自动采集）\n• Qwen Token Plan 周额度（浏览器登录态自动采集）\n• WorkBuddy 积分（导入本机登录账号，自动签到）\n• TRAE 积分（本地解密，自动签到）\n• ZCode 额度（本机 JWT + JSON 导入，一键切号）\n• Codex 额度（auth.json 导入，一键切号）\n\n"
            + "多账号管理 · 自动签到 · 日/周用量统计 · 应用内自更新\n\n"
            + "配置存于 ~/Library/Application Support/com.local.ibalance\n版本 v\(build)")
        shell.addButton("知道了", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }
    }

    // MARK: - App 自更新（GitHub Releases）

    @objc private func onToggleUpdateAutoCheck() {
        config.updateAutoCheck.toggle()
        ConfigStore.save(config)
        syncPanel()
    }

    @objc private func onCheckForUpdate() {
        Task { await runUpdateFlow(autoCheck: false) }
    }

    /// 启动 20s 后静默检查（避开启动高峰；失败静默不打扰）
    private func scheduleAutoUpdateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.autoUpdateCheckIfNeeded()
        }
    }

    /// 静默检查：每日至多一次；开关关闭不查；发现新版且当日未被「稍后再说」抑制才弹窗
    private func autoUpdateCheckIfNeeded() {
        guard config.updateAutoCheck else { return }
        let today = Self.todayString()
        guard UserDefaults.standard.string(forKey: UDKey.updateLastCheckDate) != today else { return }
        Task { await runUpdateFlow(autoCheck: true, today: today) }
    }

    /// 更新进度窗（手动检查全程复用同一实例；关闭后再开自动重建）
    private var updateProgressWinRef: UpdateProgressWindowController?
    /// 取（必要时创建）更新窗——只在真正要展示时访问；仅问「开着没」用 updateProgressWinRef
    private var updateProgressWin: UpdateProgressWindowController {
        if let existing = updateProgressWinRef { return existing }
        let created = UpdateProgressWindowController()
        updateProgressWinRef = created
        return created
    }
    /// 更新流程进行中标志：防止连点 / 自动检查与手动检查并发跑两条流程
    private var updateFlowRunning = false

    /// 检查 → 确认 → 下载替换完整流程。检查阶段（网络连通 + 版本比对）一律在后台
    /// 静默进行，不出任何窗口；结果呈现按情况分流：
    /// - 网络故障 / 无最新版本（手动检查）→ NSAlert 终态提示（自动检查保持静默）；
    /// - 发现新版本（两种流程一致）→ 更新窗口「发现新版本」态展示更新日志（独立
    ///   文本框），立即更新后窗口展示网络连通 → 版本信息 → 下载 → 校验 → 安装，
    ///   任一环节失败原地给「重试 / 手动下载 / 关闭」出口。更新窗口全程非模态。
    @MainActor
    private func runUpdateFlow(autoCheck: Bool, today: String = "") async {
        guard !updateFlowRunning else { return }
        updateFlowRunning = true
        defer { updateFlowRunning = false }
        do {
            // 后台静默检查，不出窗口；fetchLatestRelease 内部 NWPath 离线瞬时判定 + API→atom 源回退
            let rel = try await UpdateService.fetchLatestRelease()
            if autoCheck {
                UserDefaults.standard.set(today, forKey: UDKey.updateLastCheckDate)
            }
            let current = UpdateService.currentVersion()
            guard UpdateService.isNewer(rel.version, than: current) else {
                // 手动检查无新版：NSAlert 终态提示，不拉更新窗口
                if !autoCheck {
                    presentCheckResultAlert(title: "已是最新版本",
                                            message: "当前版本 v\(current)，GitHub Releases 上没有更新的发布。",
                                            warning: false)
                }
                return
            }
            if autoCheck,
               UserDefaults.standard.string(forKey: UDKey.updateSnoozeDate) == today { return }

            // ⚠️ split 按 Character 匹配，而 GitHub 正文是 CRLF——"\r\n" 在 Swift 里是
            // 单个字素簇 Character，既 ≠ "\n" 也 ≠ "\r"，按 \n 切会整段不分 → 全文因
            // 含 SHA256 行被整条滤掉 →「发布说明为空」。必须按换行语义 isNewline 切。
            var notes = rel.notes
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.lowercased().contains("sha256") }
                .joined(separator: "\n")
            if notes.isEmpty { notes = "（发布说明为空）" }

            // 发现新版本：不再弹 DialogShell 模态确认框（runModal 与 popover transient 态
            // 冲突，弹窗被连坐关闭 + 主线程吊死在永不返回的 runModal 上 → 闪退）。
            // 改由进度窗直接切「发现新版本」态：更新日志独立滚动文本框 + 立即更新/稍后再说，
            // 全程非模态，无 runModal。
            NSApp.activate(ignoringOtherApps: true)
            updateProgressWin.showUpdateAvailable(
                version: rel.version,
                current: current,
                notes: notes,
                onInstall: { [weak self] in
                    Task { @MainActor in await self?.performInstall(rel) }
                },
                onLater: {
                    if autoCheck { UserDefaults.standard.set(today, forKey: UDKey.updateSnoozeDate) }
                })
        } catch {
            Logger.log(.refresh, "[update] check failed (auto=\(autoCheck)): \(error.localizedDescription)")
            guard !autoCheck else { return }   // 静默检查失败不打扰
            // 手动检查失败（网络故障等）：NSAlert 终态提示
            presentCheckResultAlert(title: "检查更新失败",
                                    message: error.localizedDescription,
                                    warning: true)
        }
    }

    /// 手动检查的结果终态提示（无新版 / 检查失败）：NSAlert。
    /// ⚠️ 两个连坐陷阱都必须拆掉：
    /// ① 面板 transient 态会把 runModal 里的点击判为「面板外」→ popover 关闭——
    ///    所以弹前先 performClose 收起面板；
    /// ② performClose 触发的 popoverDidClose 里有 NSApp.hide（归还焦点），它会在
    ///    alert 弹出后送达，把 modal 窗一起藏掉（弹窗一闪即逝）——所以置
    ///    isPresentingSystemAlert 让 popoverDidClose 跳过 hide，alert 结束后自行归还。
    private func presentCheckResultAlert(title: String, message: String, warning: Bool) {
        isPresentingSystemAlert = true
        defer { isPresentingSystemAlert = false }
        popoverController?.performClose(nil)
        floatingPanel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        // 检查更新终态提示也走 App 图标快照（与其他面板工具弹窗同口径）
        alert.icon = makeAppIconSnapshot()
        alert.alertStyle = warning ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        // 同上：NSAlert 窗口不在面板视图树上，外观按全局镜像显式设
        alert.window.appearance = Palette.topLevelWindowAppearance
        _ = alert.runModal()
        // 归还焦点：仅当无其它可见窗口时（避免把更新窗口/浮窗连坐隐藏）
        if !(updateProgressWinRef?.isVisible ?? false) && !(floatingPanel?.isVisible ?? false) {
            NSApp.hide(nil)
        }
    }

    /// 下载 → SHA256/签名校验 → 暂存到应用同级隐藏目录 → spawn 替换脚本 → 自动重启。
    /// 任一步失败都未做改动（旧 bundle 完整在位）。全程驱动更新窗口（手动检查 /
    /// 自动检查确认后共用），失败原地给「重试 / 手动下载 / 关闭」出口。
    /// beginInstall 从发现新版态原地过渡：日志与标题原位保留，窗口零重置。
    @MainActor
    private func performInstall(_ rel: ReleaseInfo) async {
        let win = updateProgressWin
        win.beginInstall(version: rel.version)
        do {
            let staged = try await UpdateService.prepareAndStage(rel, reporter: win.reporter)
            win.report(UpdateProgress(stage: .install, state: .active, detail: "正在替换并重启…"))
            try UpdateService.installAndRestart(stagedURL: staged)   // 成功则内部 terminate 不再返回
        } catch UpdateError.cancelled {
            Logger.log(.refresh, "[update] cancelled by user")
            win.closeWindow()
        } catch {
            Logger.log(.refresh, "[update] install failed: \(error.localizedDescription)")
            NSApp.activate(ignoringOtherApps: true)
            win.showFailure(message: error.localizedDescription) { [weak self] in
                Task { @MainActor in await self?.performInstall(rel) }
            }
        }
    }

    // MARK: - 更新流程 UI 演示（--update-demo）

    /// 循环演示更新窗口全流程 UI（不出网、不真替换）：
    /// 发现新版 → 立即更新 → 下载（量化进度）→ 校验 → 暂存 → 安装完成
    /// → 停 2s 回到「发现新版本」态，可反复点「立即更新」调试各状态过渡。
    /// 点取消 = 结束演示（与真实流程的取消语义一致：关窗）。
    @MainActor
    private func runUpdateDemo() {
        // 更新描述读真实 GitHub Releases 最新版文本（与真实流程同一数据源与清洗规则，
        // 调试所见即线上所得）；版本号仍用 999.0.0 标记演示态。取不到时在框内明示失败。
        Task { @MainActor in
            var notes = "（获取 Release 文本失败，检查网络后重试）"
            if let rel = try? await UpdateService.fetchLatestRelease() {
                let trimmed = rel.notes
                    .split(whereSeparator: \.isNewline)   // 同 runUpdateFlow：CRLF 是单字素簇，按 \n 切不开
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.lowercased().contains("sha256") }
                    .joined(separator: "\n")
                if !trimmed.isEmpty { notes = trimmed }
            }
            updateProgressWin.showUpdateAvailable(
                version: "999.0.0",
                current: UpdateService.currentVersion(),
                notes: notes,
                onInstall: { [weak self] in
                    Task { @MainActor in await self?.runInstallDemo() }
                },
                onLater: {})
        }
    }

    @MainActor
    private func runInstallDemo() async {
        let win = updateProgressWin
        win.beginInstall(version: "999.0.0")
        // 下载：量化进度 0→1，约 6s（2.25 MB @ 380 KB/s）
        let total: Int64 = 2_357_248
        let steps = 24
        for i in 1...steps {
            if win.reporter.isCancelled() { win.closeWindow(); return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            let f = Double(i) / Double(steps)
            let received = Int64(Double(total) * f)
            win.report(UpdateProgress(stage: .download, state: .active, fraction: f,
                                      detail: String(format: "%.1f MB / %.1f MB · 380 KB/s",
                                                     Double(received) / 1_048_576,
                                                     Double(total) / 1_048_576),
                                      received: received, total: total, bytesPerSecond: 380 * 1024))
        }
        if win.reporter.isCancelled() { win.closeWindow(); return }
        // 校验：indeterminate（约 1.2s）
        win.report(UpdateProgress(stage: .verify, state: .active, detail: "SHA256 + 签名校验中…"))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if win.reporter.isCancelled() { win.closeWindow(); return }
        // 暂存到应用同级（约 0.8s）
        win.report(UpdateProgress(stage: .stage, state: .active, detail: "暂存到应用同级目录…"))
        try? await Task.sleep(nanoseconds: 800_000_000)
        if win.reporter.isCancelled() { win.closeWindow(); return }
        // 安装：demo 停在满格完成态（不执行真实替换/重启），2s 后回到发现新版态循环
        win.report(UpdateProgress(stage: .install, state: .done, fraction: 1,
                                  detail: "演示完成 · 即将回到发现新版态"))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if win.reporter.isCancelled() { win.closeWindow(); return }
        runUpdateDemo()
    }

    /// 面板右键「Key / 额度设置…」：打开设置窗口并落到账号 pane
    ///（Key/额度 2026-09-13 并入账号 pane，原独立 keyQuota pane 删除）
    @objc func onSetApiKey() {
        openSettingsWindow(pane: .accounts)
    }

    /// 「Key / 额度」保存（设置窗口表单 → 落盘 → 立即刷新）：
    /// 凭据三件套走钥匙串（ConfigStore.save 内部转发 CredentialVault），额度进 config.json。
    /// 表单语义 = 所见即所存：空串即清除该覆盖（ZhiPu / Qwen 回到浏览器登录态）。
    private func applyKeyQuota(apiKey: String, quota: Double, zhipuToken: String, qwenTicket: String) {
        config.deepseekApiKey = apiKey
        config.deepseekCommonQuota = max(0, quota)
        config.bigmodelTokenOverride = zhipuToken
        config.qwenTicketOverride = qwenTicket
        ConfigStore.save(config)
        onRefresh()
    }

    /// 设置窗口「已保存账号」行的逐个删除（2026-09-13 用户要求）：
    /// platform = 平台键（workbuddy / trae / zcode / codex），uid 定位具体账号。
    /// 二次确认后仅从 iBalance 移除该账号（钥匙串 bundle 由 ConfigStore.save 按新数组重写），
    /// 平台本机登录态不动；删的是当前登录号时该平台卡片消失，重新导入即可恢复。
    private func onDeleteAccount(platform: String, uid: String) {
        // 平台名 / 账号展示名 / 移除动作：一处 switch 集中；uid 找不到（已删或键不符）直接返回
        let target: (platform: String, account: String, remove: () -> Void)
        switch platform {
        case "workbuddy":
            guard let a = config.workbuddyAccounts.first(where: { $0.uid == uid }) else { return }
            target = ("WorkBuddy", a.nickname, { self.config.workbuddyAccounts.removeAll { $0.uid == uid } })
        case "trae":
            guard let a = config.traeAccounts.first(where: { $0.uid == uid }) else { return }
            target = ("TRAE", a.username.isEmpty ? a.uid : a.username,
                      { self.config.traeAccounts.removeAll { $0.uid == uid } })
        case "zcode":
            guard let a = config.zcodeAccounts.first(where: { $0.uid == uid }) else { return }
            target = ("ZCode", a.displayName, { self.config.zcodeAccounts.removeAll { $0.uid == uid } })
        case "codex":
            guard let a = config.codexAccounts.first(where: { $0.uid == uid }) else { return }
            target = ("Codex", a.email.isEmpty ? a.uid : a.email,
                      { self.config.codexAccounts.removeAll { $0.uid == uid } })
        default:
            return
        }

        let shell = DialogShell()
        shell.addTitle("删除账号")
        shell.addInfo("即将删除已保存的 \(target.platform) 账号「\(target.account)」。\n\n"
            + "只删 iBalance 里保存的这份凭据，平台本机登录状态不受影响。此操作不可撤销。")
        _ = shell.addButton("取消", keyEquivalent: "\u{1b}")
        let idxDelete = shell.addButton("删除", keyEquivalent: "")
        shell.markDestructive(idxDelete)
        guard shell.present() == idxDelete else { return }

        target.remove()
        // 菜单栏显隐记录一并清掉（同切号口径：残留记录会压过新会话的默认显隐规则）
        let prefix: String
        switch platform {
        case "workbuddy": prefix = MenuBarPrefix.wb
        case "trae": prefix = MenuBarPrefix.trae
        case "zcode": prefix = MenuBarPrefix.zcode
        default: prefix = MenuBarPrefix.codex
        }
        config.menuBarVisible.removeValue(forKey: prefix + uid)
        ConfigStore.save(config)
        // 菜单栏立即重排（被删条目即时消失）+ 面板重绘 + 重新拉余额
        updateTitle(immediate: true, tag: "account-delete")
        syncPanel()
        onRefresh()
    }

    // MARK: - 菜单栏条目显示控制

    /// 菜单栏条目 id 前缀
    enum MenuBarPrefix {
        static let ds = "ds"
        static let zhipu = "zhipu"
        static let qwen = "qwen"
        static let trae = "trae:"
        static let wb = "wb:"
        static let zcode = "zcode:"
        static let codex = "codex:"
    }

    /// 判断某条目在菜单栏是否可见
    /// 显式配置优先；无记录时使用默认值：DS/Trae主/Wb主 默认可见；ZCode主默认隐藏（保持旧版行为）；非主账号默认隐藏
    /// （2026-08-31 移除「余额 ≤0 强制隐藏」：显隐完全交给用户右键自行切换，
    ///   用尽账号不再被强制加卡片渐变、右键不再被拦截）
    private func isMenuBarVisible(id: String, isCurrent: Bool) -> Bool {
        if let v = config.menuBarVisible[id] { return v }
        // 默认值
        if id == MenuBarPrefix.ds || id == MenuBarPrefix.zhipu || id == MenuBarPrefix.qwen { return true }
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
            // DS / ZhiPu / Qwen 是单账号平台，条目恒为当前账号
            isCurrent = (itemId == MenuBarPrefix.ds || itemId == MenuBarPrefix.zhipu || itemId == MenuBarPrefix.qwen)
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
    /// 菜单栏跟随面板板块视觉序：API 组（DS/ZhiPu/Qwen，面板在上）在前，
    /// Agent 组在后，组内相对顺序保持 platformOrder 不变。
    private func balancePlatformOrder() -> [String] {
        let saved = menuBarPlatformOrder
            ?? UserDefaults.standard.stringArray(forKey: UDKey.balancePlatformOrder)
            ?? []
        let order = BalancePlatform.normalizedOrder(from: saved)
        let apiIDs: Set<String> = [BalancePlatform.deepSeek.rawValue,
                                   BalancePlatform.bigModel.rawValue,
                                   BalancePlatform.qwen.rawValue]
        return order.filter { apiIDs.contains($0) } + order.filter { !apiIDs.contains($0) }
    }

    /// 按面板余额卡片顺序构建要显示在菜单栏的条目（id, symbol, value, icon）。
    /// 平台组顺序与余额面板共用 UserDefaults；每平台只显示当前账号一条（2026-08-30，
    /// 切号完成 performAccountSwitch 即时 updateTitle 实时换条，数值沿用缓存）。
    private func orderedMenuBarEntries() -> [(id: String, symbol: String, value: String, isCurrent: Bool, icon: String)] {
        var entries: [(id: String, symbol: String, value: String, isCurrent: Bool, icon: String)] = []

        // 1. DeepSeek（icon 前缀 + 货币符号 + 金额）
        if let ds = cacheDs {
            entries.append((id: MenuBarPrefix.ds, symbol: ds.symbol, value: fmtAmountRaw(ds.totalRaw), isCurrent: true, icon: "deepseek"))
        }

        // 1b. ZhiPu（智谱 BigModel；icon 复用 zhipu，货币符号走 DS 同款小字号）
        if let bal = cacheBigModelBalance {
            entries.append((id: MenuBarPrefix.zhipu, symbol: "¥", value: fmtAmountCommas(bal, decimals: 2), isCurrent: true, icon: "zhipu"))
        }

        // 1c. Qwen（千问 Token Plan；周额度剩余百分比，同 ZCode 行口径）
        if let q = cacheQwen, q.weekLimit > 0 {
            let pct = fmtAmountCommas(q.weekRem / q.weekLimit * 100, decimals: 1) + "%"
            entries.append((id: MenuBarPrefix.qwen, symbol: "", value: pct, isCurrent: true, icon: "qwen"))
        }

        // 探活分段计时（前置 DS/ZhiPu/Qwen 只读内存缓存，不单独计时）
        let tPre = Date()

        // 2. ZCode（仅当前账号）
        let zcodeMainUid = ZcodeService.currentUid() ?? ""
        if let main = config.zcodeAccounts.first(where: { $0.uid == zcodeMainUid }),
           let c = cacheZcodeAccounts[main.uid], c.total > 0 {
            let pct = fmtAmountCommas(c.remain / c.total * 100, decimals: 1) + "%"
            entries.append((id: MenuBarPrefix.zcode + main.uid, symbol: "", value: pct, isCurrent: true, icon: "zhipu"))
        }
        let tZcode = Date()

        // 3. Codex（仅当前账号）
        let codexMainUid = CodexService.currentUid() ?? ""
        if let main = config.codexAccounts.first(where: { $0.uid == codexMainUid }),
           let c = cacheCodexAccounts[main.uid] {
            let pct = fmtAmountCommas(100 - c.usedPercent, decimals: 0) + "%"
            entries.append((id: MenuBarPrefix.codex + main.uid, symbol: "", value: pct, isCurrent: true, icon: "codex"))
        }
        let tCodex = Date()

        // 4. TRAE（仅当前账号）
        let traeMainUid = TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? ""
        if let main = traeCheckinAccounts().first(where: { $0.uid == traeMainUid }),
           let c = cacheTraeAccounts[main.uid] {
            let remaining = c.limit - c.used
            entries.append((id: MenuBarPrefix.trae + main.uid, symbol: "", value: fmtAmountCommas(remaining, decimals: 0), isCurrent: true, icon: "trae-color"))
        }
        let tTrae = Date()

        // 5. WorkBuddy（仅当前账号）
        let wbMainUid = WorkBuddyService.authInfo()?.uid ?? ""
        if let main = wbCheckinAccounts().first(where: { $0.uid == wbMainUid }),
           let c = cacheWbAccounts[main.uid] {
            entries.append((id: MenuBarPrefix.wb + main.uid, symbol: "", value: fmtAmountCommas(c.remain, decimals: 0), isCurrent: true, icon: "workbuddy"))
        }
        let tWb = Date()

        // 余额面板拖拽只改变平台组顺序；这里按平台前缀重排，保持每组内部账号顺序不变。
        let ordered = balancePlatformOrder().flatMap { platformID in
            switch platformID {
            case "ds":
                return entries.filter { $0.id == MenuBarPrefix.ds }
            case BalancePlatform.bigModel.rawValue:
                return entries.filter { $0.id == MenuBarPrefix.zhipu }
            case BalancePlatform.qwen.rawValue:
                return entries.filter { $0.id == MenuBarPrefix.qwen }
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
        let tOrder = Date()
        // 分段计时只在慢时打（日常 1~3ms，不值得刷屏）：首次调用、切号后新账号首次判定
        // 会因各处缓存全 miss 明显变慢，这里直接指到是哪个平台
        func ms(_ from: Date, _ to: Date) -> Int { Int(to.timeIntervalSince(from) * 1000) }
        let totalMs = ms(tPre, tOrder)
        if totalMs >= 5 {
            Logger.log(.refresh, "[MenuBarEntries] \(totalMs)ms [zcode=\(ms(tPre, tZcode)) codex=\(ms(tZcode, tCodex)) trae=\(ms(tCodex, tTrae)) wb=\(ms(tTrae, tWb)) order=\(ms(tWb, tOrder))]")
        }
        return ordered
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
        // 条目表一次算到位：fingerprint 与下面的渲染循环共用同一份。原来一次渲染要跑两遍
        // orderedMenuBarEntries()，每次都要做平台探活（TRAE/WB 读登录态、账号表拼接），纯浪费主线程
        let entries = isOffline ? [] : orderedMenuBarEntries()
        let visibleEntries = entries.filter { isMenuBarVisible(id: $0.id, isCurrent: $0.isCurrent) }
        let tEntries = Date()
        let fingerprint = (isOffline ? "offline" : visibleEntries
            .map { "\($0.id):\($0.value):dot=\(menuBarGlowState(for: $0.id) != nil)" }
            .joined(separator: "|"))
            + "|size:\(NSFont.menuBarFont(ofSize: 0).pointSize)"
        if fingerprint == lastTitleFingerprint, statusItem.button?.image != nil {
            // 条目探活耗时也打出来：unchanged 分支不做烘焙，它的耗时≈平台探活 + 判活成本
            let entriesMs = Int(Date().timeIntervalSince(t0) * 1000)
            Logger.log(.refresh, "updateTitleImpl[\(updateTitleRenderCount)] \(tag): unchanged, skip [entries=\(entriesMs)ms]")
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
            menuBarGlow.clear()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Logger.log(.refresh, "updateTitleImpl[\(updateTitleRenderCount)] \(tag): offline, \(ms)ms")
            // 面板打开时同步重绘
            syncPanel()
            return
        }

        // 平台图标尺寸 = 菜单栏字号 + 3pt（略大于文本行高）
        let iconSize = menuSize + 3

        var hasContent = false
        var renderedIds: [String] = []
        // 光晕层用：本次实际渲染的条目（id/icon，顺序与标题位图内附件一致）
        var renderedEntries: [(id: String, icon: String)] = []
        for entry in visibleEntries {
            renderedIds.append(entry.id)
            renderedEntries.append((entry.id, entry.icon))
            if hasContent { append("  \u{2009}") }

            // 平台品牌图标（黑形，随整条标题烘焙进 template 位图）；TRAE 缩小 6%，ZCode 缩小 13%
            let iconScale: CGFloat
            switch entry.icon {
            case "trae-color": iconScale = 0.94
            case "zhipu": iconScale = 0.87
            case "codex": iconScale = 0.90
            case "qwen": iconScale = 0.90
            default: iconScale = 1.0
            }
            // DeepSeek 图标后用细空格（后面紧跟 ¥ 符号），其余平台保持普通空格
            // 状态点平台：图标前插入预留空隙（圆点左侧间距），点消失时重烘焙自动回收；
            // 末字符 kern −2.2（普通 −0.2 + 额外 −2.0）：点→图标间距缩 2pt（2026-09-13，
            // 空格字形组合凑不出精确 2pt，直接在 advance 上扣）。
            // 首位条目只补一个细空格：点槽够容纳 [点][图标间距] 即可（中段条目的槽
            // 含条目分隔，首位没有前一内容，点将贴位图左缘——见 GlowController 定位处；
            // 补整段分隔会让点位右移、左缘视觉空隙过大，2026-09-13 用户打回）
            if menuBarGlowState(for: entry.id) != nil {
                if !hasContent { append("\u{2009}") }
                let reserve = MenuBarStatusGlowController.dotReserve
                attr.append(NSAttributedString(
                    string: String(reserve.dropLast()),
                    attributes: [.font: boldFont, .kern: -0.2]))
                attr.append(NSAttributedString(
                    string: String(reserve.suffix(1)),
                    attributes: [.font: boldFont, .kern: MenuBarStatusGlowController.dotReserveTailKern]))
            }
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
        let tAttr = Date()

        // 光晕层同步：附件（平台图标）在标题位图内的精确 frame 用 NSLayoutManager 解出，
        // 与 NSString.draw 同一套排版引擎，坐标可直接对位
        let titleH = attr.boundingRect(with: NSSize(width: 10000, height: 100),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let iconInfos = attachmentRects(in: attr)
        let glowEntries = zip(renderedEntries, iconInfos).map {
            MenuBarStatusGlowController.EntryIcon(id: $0.id, rect: $1.rect, leftFreeSpace: $1.leftFreeSpace)
        }
        // 各条目整段横向区间（图标起 → 下一条目内容起），供排序滑动动画裁快照
        let spansByID = entrySpans(attr: attr, iconInfos: iconInfos, entries: renderedEntries)
        let newImage = renderTemplateTitleImage(attr) ?? NSImage()  // 烘焙失败 = 空图（原 nil 赋值同样清空）
        let tBake = Date()
        let newIDs = renderedEntries.map(\.id)
        var animated = false
        if !isOffline, !lastMenuBarIDs.isEmpty, newIDs != lastMenuBarIDs,
           !Set(newIDs).intersection(lastMenuBarIDs).isEmpty,
           let oldImage = statusItem.button?.image {
            animated = menuBarGlow.beginReorder(oldImage: oldImage,
                                                oldSpansByID: lastMenuBarSpans,
                                                newImage: newImage,
                                                newEntries: glowEntries,
                                                newSpansByID: spansByID)
        }
        if !animated {
            statusItem.button?.image = newImage
        }
        lastMenuBarIDs = newIDs
        lastMenuBarSpans = spansByID
        menuBarGlow.setEntries(glowEntries, imageHeight: ceil(titleH))
        let tGlow = Date()

        // 面板打开时同步重绘
        syncPanel()
        let tEnd = Date()

        // 阶段计时：常态渲染 4~5ms，切号这类「全条目换 id」会明显变慢 ——
        // 拆开看是条目探活贵、烘焙贵、还是赋值/重排（含系统 replicant）贵，别靠猜
        func stage(_ from: Date, _ to: Date) -> Int { Int(to.timeIntervalSince(from) * 1000) }
        let ms = stage(t0, tEnd)
        let slow = ms >= 10 ? " SLOW!" : ""
        Logger.log(.refresh, "updateTitleImpl[\(updateTitleRenderCount)] \(tag): call-render=\(updateTitleCallCount)/\(updateTitleRenderCount), ids=[\(renderedIds.joined(separator: ","))], attrLen=\(attr.length), \(ms)ms\(slow) [entries=\(stage(t0, tEntries)) attr=\(stage(tEntries, tAttr)) bake=\(stage(tAttr, tBake)) glow=\(stage(tBake, tGlow)) sync=\(stage(tGlow, tEnd))]")
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
        async let g: Void = refreshOneBigModel(cfg, seq: seq)
        async let h: Void = refreshOneQwen(cfg, seq: seq)
        async let b: Void = refreshOneWorkBuddy(cfg, seq: seq)
        async let c: Void = refreshOneTrae(cfg, seq: seq)
        async let e: Void = refreshOneZcode(cfg, seq: seq)
        async let f: Void = refreshOneCodex(cfg, seq: seq)
        _ = await (a, g, h, b, c, e, f)

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
        cacheBigModelBalance = c.bigmodel
        cacheBigModelInflow = c.bigmodelInflow
        cacheBigModelCycleStartInflow = c.bigmodelCycleStartInflow
        cacheBigModelCycleStartBalance = c.bigmodelCycleStartBalance
        cacheBigModelUsedRatio = c.bigmodelUsedRatio
        cacheQwen = c.qwen.map { QwenService.Quota(weekRem: $0.weekRem, weekLimit: $0.weekLimit,
                                                   remainingDays: $0.remainingDays, expireAt: $0.expireAt,
                                                   weekResetAt: $0.weekResetAt ?? 0) }
        if let wb = c.wb { cacheWb = (wb.remain, wb.total) }
        cacheWbAccounts = c.wbAccounts.mapValues { ($0.remain, $0.total) }
        cacheTraeAccounts = c.traeAccounts.mapValues { ($0.limit, $0.used, $0.resetAt) }
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
        c.bigmodel = cacheBigModelBalance
        c.bigmodelUsedRatio = cacheBigModelUsedRatio
        c.bigmodelInflow = cacheBigModelInflow
        c.bigmodelCycleStartInflow = cacheBigModelCycleStartInflow
        c.bigmodelCycleStartBalance = cacheBigModelCycleStartBalance
        c.qwen = cacheQwen.map { .init(weekRem: $0.weekRem, weekLimit: $0.weekLimit,
                                       remainingDays: $0.remainingDays, expireAt: $0.expireAt,
                                       weekResetAt: $0.weekResetAt) }
        c.wbAccounts = cacheWbAccounts.mapValues { .init(remain: $0.remain, total: $0.total) }
        c.traeAccounts = cacheTraeAccounts.mapValues { .init(limit: $0.limit, used: $0.used, resetAt: $0.resetAt) }
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

    /// ZhiPu（智谱 BigModel）余额刷新：手填覆盖 token 优先，否则扫浏览器 Cookies 解密登录态，
    /// 调财务报告接口取 availableBalance。无凭据静默跳过（对齐 DeepSeek 未配置行为）。
    private func refreshOneBigModel(_ cfg: AppConfig, seq: Int64) async {
        let t0 = Date()
        guard cfg.bigmodelRefreshEnabled else {
            Logger.log(.refresh, "[\(seq)] ZhiPu: disabled, skipped")
            if ownsRefresh(seq) { failedServices.remove("ZhiPu") }
            return
        }
        // 鉴权失败自愈：清 token 缓存重新采集再试一轮；仍失败才报错
        var result = await bigModelFetch(cfg: cfg, seq: seq)
        if result.authFailed {
            Logger.log(.refresh, "[\(seq)] ZhiPu: 登录态失效，清缓存重采")
            BigModelService.clearCachedToken()
            result = await bigModelFetch(cfg: cfg, seq: seq)
        }
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] ZhiPu: not owner after fetch (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip writeback")
            return
        }
        if let bal = result.balance {
            cacheBigModelBalance = bal
            UsageStore.observe(platform: "zhipu", uid: "zhipu", value: bal, increasing: false)

            // 周期基线：入账 = 累计充值 + 赠送（服务端记账）。
            // 检测到跳涨（新充值/补赠）→ 重置锚点：本次增量作为分母，当前余额为周期顶点；
            // 尚未观测到充值的首期 → 回退累计口径（对齐旧行为，点阵仍可用）。
            let inflow = max(0, result.budget)
            if cacheBigModelInflow == nil || cacheBigModelCycleStartInflow == nil {
                cacheBigModelInflow = inflow
                cacheBigModelCycleStartInflow = inflow
                cacheBigModelCycleStartBalance = bal
                Logger.log(.refresh, "[\(seq)] ZhiPu: 周期锚点初始化，inflow=\(inflow)")
            } else if let seen = cacheBigModelInflow, inflow > seen + 0.005 {
                Logger.log(.refresh, "[\(seq)] ZhiPu: 检测到新充值 \(seen) → \(inflow)，重置周期锚点")
                cacheBigModelInflow = inflow
                cacheBigModelCycleStartInflow = inflow
                cacheBigModelCycleStartBalance = bal
            } else {
                cacheBigModelInflow = inflow
            }
            let cycleDenom = inflow - (cacheBigModelCycleStartInflow ?? inflow)
            let ratio: Double
            if cycleDenom > 0.005, let startBal = cacheBigModelCycleStartBalance {
                // 本周期口径：自最近一次充值以来已用 / 本次充值额
                ratio = min(1, max(0, (startBal - bal) / cycleDenom))
            } else {
                // 首期回退：累计消耗 / 累计入账
                ratio = min(1, max(0, (inflow - bal) / max(inflow, 0.005)))
            }
            cacheBigModelUsedRatio = ratio
            _ = zhipuPulsingTracker.observe("main", ratio: ratio)
            failedServices.remove("ZhiPu")
            Logger.log(.refresh, "[\(seq)] ZhiPu: OK value=\(bal) inflow=\(inflow) denom=\(max(0, cycleDenom)) used=\(Int(ratio*100))% (elapsed=\(Int(Date().timeIntervalSince(t0)*1000))ms)")
        }
        if !result.error.isEmpty {
            notify("ZhiPu 余额查询", result.error)
            failedServices.insert("ZhiPu")
            Logger.log(.refresh, "[\(seq)] ZhiPu: ERROR \(result.error)")
        }
        updateTitle(tag: "zhipu-\(seq)")
    }

    /// 单轮 ZhiPu 查询：解析 token（手填 > 缓存 > 浏览器采集）后请求报告接口
    private func bigModelFetch(cfg: AppConfig, seq: Int64) async -> (balance: Double?, budget: Double, authFailed: Bool, error: String) {
        guard let token = BigModelService.resolveToken(override: cfg.bigmodelTokenOverride), !token.isEmpty else {
            Logger.log(.refresh, "[\(seq)] ZhiPu: no login cookie found, skipped")
            if ownsRefresh(seq) { failedServices.remove("ZhiPu") }
            return (nil, 0, false, "")
        }
        return await Logger.measure("[\(seq)] ZhiPu.fetch") {
            await BigModelService.fetch(token: token)
        }
    }

    /// Qwen（千问 Token Plan）周额度刷新：手填覆盖 ticket 优先，否则扫浏览器 Cookies 解密登录态，
    /// 调控制台网关取周配额。无凭据静默跳过（对齐 ZhiPu 行为）。
    private func refreshOneQwen(_ cfg: AppConfig, seq: Int64) async {
        let t0 = Date()
        guard cfg.qwenRefreshEnabled else {
            Logger.log(.refresh, "[\(seq)] Qwen: disabled, skipped")
            if ownsRefresh(seq) { failedServices.remove("Qwen") }
            return
        }
        // 鉴权失败自愈：清 ticket 缓存重新采集再试一轮；仍失败才报错
        var result = await qwenFetch(cfg: cfg, seq: seq)
        if result.authFailed {
            Logger.log(.refresh, "[\(seq)] Qwen: 登录态失效，清缓存重采")
            QwenService.clearCachedTicket()
            result = await qwenFetch(cfg: cfg, seq: seq)
        }
        guard ownsRefresh(seq) else {
            Logger.log(.refresh, "[\(seq)] Qwen: not owner after fetch (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip writeback")
            return
        }
        if let q = result.quota {
            cacheQwen = q
            // 用量记录：口径 = 周剩余额度百分比（同 ZCode 行的百分点口径；
            // fetch 已保证 weekLimit > 0）。周重置跳涨由 UsageStore 基线平移承接，用量不清零。
            UsageStore.observe(platform: "qwen", uid: "qwen", value: q.weekRem / q.weekLimit * 100, increasing: false)
            let ratio = q.weekLimit > 0 ? min(1, max(0, (q.weekLimit - q.weekRem) / q.weekLimit)) : 0
            _ = qwenPulsingTracker.observe("main", ratio: ratio)
            failedServices.remove("Qwen")
            Logger.log(.refresh, "[\(seq)] Qwen: OK weekRem=\(q.weekRem)/\(q.weekLimit) used=\(Int(ratio*100))% days=\(q.remainingDays) (elapsed=\(Int(Date().timeIntervalSince(t0)*1000))ms)")
        }
        if !result.error.isEmpty {
            notify("Qwen 配额查询", result.error)
            failedServices.insert("Qwen")
            Logger.log(.refresh, "[\(seq)] Qwen: ERROR \(result.error)")
        }
        updateTitle(tag: "qwen-\(seq)")
    }

    /// 单轮 Qwen 查询：解析 ticket（手填 > 缓存 > 浏览器采集）后请求控制台网关
    private func qwenFetch(cfg: AppConfig, seq: Int64) async -> (quota: QwenService.Quota?, authFailed: Bool, error: String) {
        guard let ticket = QwenService.resolveTicket(override: cfg.qwenTicketOverride), !ticket.isEmpty else {
            Logger.log(.refresh, "[\(seq)] Qwen: no login cookie found, skipped")
            if ownsRefresh(seq) { failedServices.remove("Qwen") }
            return (nil, false, "")
        }
        return await Logger.measure("[\(seq)] Qwen.fetch") {
            await QwenService.fetch(ticket: ticket)
        }
    }

    func refreshOneWorkBuddy(_ cfg: AppConfig, seq: Int64) async {
        let t0 = Date()
        guard cfg.workbuddyEnabled else {
            Logger.log(.refresh, "[\(seq)] WorkBuddy: disabled, skipped")
            if ownsRefresh(seq) { failedServices.remove("WorkBuddy") }
            return
        }
        // 主账号（当前登录）：用 authInfo 直接查询
        // 顺手把主账号补进 config 并落盘（钥匙串 + config）——写操作只在刷新流程做，
        // 不进 wbCheckinAccounts()（那个跑在菜单栏渲染 / 面板快照的高频只读路径上）
        persistCurrentWbAccountIfNeeded()
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
            // 裂变包重置日（副标题）：仅主账号、按 uid 各自 ≥1h 拉一次（get-user-resource 全量包列表）。
            // 按 uid 而非全局节流：切号后新主账号需立刻补一次，否则副标题空窗到上次的 1h 期满。
            if let auth = WorkBuddyService.authInfo(),
               wbFissionFetchedAt[auth.uid].map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                // 时间戳在请求返回后才写：请求失败时下一轮（~2.5min）重试，不空等 1 小时
                let resetAt = await WorkBuddyService.fetchFissionReset(
                    token: auth.token, uid: auth.uid, domain: auth.domain)
                wbFissionFetchedAt[auth.uid] = Date()
                if let resetAt, ownsRefresh(seq) {
                    cacheWbFission[auth.uid] = resetAt
                    Logger.log(.refresh, "[\(seq)] WB.fission: uid=\(auth.uid) resetAt=\(resetAt)")
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
        // 当前登录号变化（ZCode 端独立登录/切号）时自动追加，保证大卡片恒落在当前登录号；
        // 只追加、不覆盖已存账号的 token（已存 token 可能比本轮 provider 解析出的更适合恢复会话）。
        var accounts = cfg.zcodeAccounts
        if case .success(let current) = ZcodeService.importCurrentAccount(),
           !accounts.contains(where: { $0.uid == current.uid }) {
            accounts.append(current)
            Logger.log(.refresh, "[\(seq)] ZCode: current login uid=\(current.uid) not imported, appended")
            if !config.zcodeAccounts.contains(where: { $0.uid == current.uid }) {
                config.zcodeAccounts.append(current)
                ConfigStore.save(config)
            }
        }
        Logger.log(.refresh, "[\(seq)] ZCode: accounts=\(accounts.count)")
        zcodeInvalidUids.removeAll()   // 账号级失效集合每轮重建
        // 体验套餐（start-plan）JWT 仅当前登录号持有；余额查询时优先于存量 token（多为付费档 API Key）
        let startPlanJWT = ZcodeService.currentStartPlanJWT()
        for (i, ac) in accounts.enumerated() {
            if !ownsRefresh(seq) {
                Logger.log(.refresh, "[\(seq)] ZCode[\(i)/\(accounts.count)]: not owner (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip remaining")
                return
            }
            let acctag = "[\(seq)] ZCode[\(i)/\(accounts.count)] uid=\(ac.uid)"
            // 存量账号自动回填昵称（早期导入无 nickname）：credentials.json 可解出且 uid 匹配时写入一次
            if ac.nickname.isEmpty, let nick = ZcodeService.autoNickname(forUid: ac.uid),
               let idx = config.zcodeAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                config.zcodeAccounts[idx].nickname = nick
                ConfigStore.save(config)
            }
            // 到期跳过已移除（对齐 Cockpit）：套餐到期是服务端事实，本地缓存判定会在
            // 用户领取新套餐后永远卡在「已到期」（旧 planEndsAt 挡住新请求）；
            // 每轮真实请求，到期展示交给快照层按最新 planEndsAt 判断
            // 体验套餐优先：账号即当前登录号且存量 token 不是 JWT 时，先用 JWT 查体验套餐
            // （billing/balance），无有效体验套餐（过期/未领取/请求失败）再回落存量 token 口径
            let r: ZcodeService.BalanceResult
            if let sp = startPlanJWT, sp.uid == ac.uid, sp.token != ac.token {
                let primary = await Logger.measure("\(acctag).fetchBalance[startPlan]") {
                    await ZcodeService.fetchBalance(token: sp.token)
                }
                if case .ok(let v) = primary, v.total > 0 {
                    r = primary
                } else {
                    r = await Logger.measure("\(acctag).fetchBalance") {
                        await ZcodeService.fetchBalance(token: ac.token)
                    }
                }
            } else {
                r = await Logger.measure("\(acctag).fetchBalance") {
                    await ZcodeService.fetchBalance(token: ac.token)
                }
            }
            guard ownsRefresh(seq) else {
                Logger.log(.refresh, "\(acctag): not owner after fetch, skip writeback")
                return
            }
            switch r {
            case .ok(let v):
                guard v.total > 0 else {
                    // 查询成功但无有效套餐（全部到期）：不判失败，保留旧缓存继续展示「套餐已到期」
                    Logger.log(.refresh, "\(acctag): no active quota, keep last cache")
                    zcodePulsingTracker.reset(ac.uid)
                    continue
                }
                cacheZcodeAccounts[ac.uid] = v
                UsageStore.observe(platform: "zcode", uid: ac.uid, value: v.remain / v.total * 100, increasing: false)
                _ = zcodePulsingTracker.observe(ac.uid, ratio: (v.total - v.remain) / v.total)
                Logger.log(.refresh, "\(acctag): OK remain=\(v.remain) total=\(v.total)")
            case .accountInvalid:
                // 账号级失效（token 过期 401 / 账号无套餐 500 等）：不判平台刷新失败，
                // 悬浮气泡 ID 后挂黄色徽章，保留旧缓存
                zcodeInvalidUids.insert(ac.uid)
                zcodePulsingTracker.reset(ac.uid)
                Logger.log(.refresh, "\(acctag): account invalid (token 过期或无套餐), badge only")
                continue
            case .networkFailed:
                // 请求层失败（HTTP 非 200 / 网络/解析错误）：真正的平台级失败
                zcodeFailed = true
                Logger.log(.refresh, "\(acctag): request failed, marked failed")
                continue
            }
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
        var currentAccountUID: String?
        // auth.json 是当前登录态的权威来源；登录切换后自动更新对应账号 token/email。
        if case .success(let current) = CodexService.importCurrentAccount() {
            currentAccountUID = current.uid
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
            var usage = await Logger.measure("\(acctag).fetchUsage", {
                await CodexService.fetchUsage(token: account.token,
                                              fallbackUid: account.uid,
                                              fallbackEmail: account.email)
            })
            if usage == nil {
                // 账号可能已在另一个 Codex 实例重新登录：扫描候选 home，按 UID 获取新凭据后只重试一次。
                Logger.log(.refresh, "\(acctag): fetchUsage failed, scanning Codex homes for refreshed credentials")
                if let refreshed = CodexService.reimportAccount(uid: account.uid),
                   refreshed.token != account.token {
                    accounts[i] = refreshed
                    if let configIdx = config.codexAccounts.firstIndex(where: { $0.uid == account.uid }) {
                        config.codexAccounts[configIdx] = refreshed
                        ConfigStore.save(config)
                    }
                    Logger.log(.refresh, "\(acctag): refreshed credentials found, retrying fetchUsage once")
                    let retryAccount = refreshed
                    usage = await Logger.measure("\(acctag).fetchUsage.retry", {
                        await CodexService.fetchUsage(token: retryAccount.token,
                                                      fallbackUid: retryAccount.uid,
                                                      fallbackEmail: retryAccount.email)
                    })
                } else {
                    Logger.log(.refresh, "\(acctag): no newer credentials found in Codex homes")
                }
            }
            guard let usage else {
                // 子账号失效不影响平台级刷新提示；当前登录账号失败才提示用户。
                let isSubAccount = currentAccountUID.map { $0 != account.uid } ?? false
                if ownsRefresh(seq), !isSubAccount {   // 只在仍是 owner 且为主账号时标记失败
                    failed = true
                }
                Logger.log(.refresh, "\(acctag): fetchUsage returned nil (\(isSubAccount ? "subaccount failure ignored" : "FAILED"))")
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
        let mainTrae: (limit: Double, used: Double, resetAt: Double)? = await Logger.measure("[\(seq)] TRAE.main.fetchCredits") {
            await TraeService.fetchCredits(storagePath: cfg.traeStoragePath)
        }
        if let t = mainTrae {
            guard ownsRefresh(seq) else {
                Logger.log(.refresh, "[\(seq)] TRAE: not owner after main fetch (cancelled=\(Task.isCancelled), seqNow=\(refreshSeq)), skip writeback")
                return
            }
            cacheTrae = t
            if !mainUid.isEmpty {
                cacheTraeAccounts[mainUid] = (t.limit, t.used, adoptTraeResetAt(uid: mainUid, candidate: t.resetAt))
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
                cacheTraeAccounts[ac.uid] = (r.limit, r.used, adoptTraeResetAt(uid: ac.uid, candidate: r.resetAt))
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

    /// TRAE 套餐重置点采纳节流（≥1h，与 WB 裂变包同款口径）：
    /// 积分（limit/used）每轮刷新照常更新；resetAt 仅在首次 / 旧周期已翻转 / 距上次
    /// 采纳 ≥1h 时才写入新值。套餐数据与积分来自同一全量响应（ide_user_ent_usage
    /// 无法按参数分离，已实测 require_usage 三种取值响应一致），网络层省不掉，
    /// 故在数据写入层降低套餐（重置时间）的更新频率。
    func adoptTraeResetAt(uid: String, candidate: Double) -> Double {
        let now = Date()
        let old = cacheTraeAccounts[uid]?.resetAt ?? 0
        if old > now.timeIntervalSince1970,
           let last = traeResetAtAdoptedAt[uid],
           now.timeIntervalSince(last) < 3600 {
            return old   // 旧周期未翻转且 1h 内已采纳 → 沿用旧值
        }
        traeResetAtAdoptedAt[uid] = now
        return candidate
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

        // 文件菜单：⌘W 关设置窗口（accessory App 没有可见菜单条，但 keyEquivalent 照常分发）。
        // ⚠️ 不用系统约定的 `performClose:`：它作用在「当时的 key window」上，更新窗口等模态
        //    开着时会把无关窗口一起牵连；这里只认设置窗口（见 onCloseSettingsWindow）。
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        let closeItem = fileMenu.addItem(withTitle: "关闭窗口",
                                         action: #selector(onCloseSettingsWindow),
                                         keyEquivalent: "w")
        closeItem.target = self
        fileMenuItem.submenu = fileMenu

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

    // MARK: - Cockpit

    @objc private func onOpenCockpit() {
        openApp(bundleId: config.cockpitAppId, missingTitle: "未找到 Cockpit App",
                missingMsg: "未找到 Bundle ID 为 \(config.cockpitAppId) 的应用，请确认 Cockpit 已安装。")
    }

    /// 通过 Bundle ID 启动应用，找不到时弹出 alert 提示并保持面板不关闭。
    private func openApp(bundleId: String, missingTitle: String, missingMsg: String) {
        // 仅用于存在性检查（缺失时提示），真正启动交给 ProcessUtil
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil else {
            let shell = DialogShell()
            shell.addTitle(missingTitle)
            shell.addInfo(missingMsg)
            shell.addButton("好", keyEquivalent: "\r")
            _ = keepPanelAliveDuring { shell.present() }
            return
        }
        // 走 ProcessUtil（/usr/bin/open + 净化环境）：NSWorkspace.openApplication 会把
        // iBalance 的进程环境原样传给目标 Electron 应用，毒变量会让它 Node 模式秒退
        ProcessUtil.openApp(bundleId: bundleId, label: bundleId)
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

    /// 到期倒计时文案分段（ZCode/Codex/Qwen/WB/TRAE 共用）：剩余 ≥1 天 → ["剩余","x天"]
    /// （2026-09-10 简化：只显示天数）；剩余 <1 天 → ["剩余","HH:MM"]；
    /// 已到期 → nil（由调用方给各自的提示文案）。
    /// 段间 2pt 间距由面板副标题 stack 布局提供（stack.spacing=2），不再用空格字符做间隔。
    private static func expireCountdownText(endsAt: TimeInterval) -> [String]? {
        let remainSec = endsAt - Date().timeIntervalSince1970
        guard remainSec > 0 else { return nil }
        let total = Int(remainSec)
        let days = total / 86400
        if days > 0 {
            return ["剩余", "\(days)天"]
        }
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        return ["剩余", String(format: "%02d:%02d", h, m)]
    }

    /// Agent 卡副标题 meta 文案：最近 10 次会话均速 →「x tok/s」。
    /// <100 保留 1 位小数、≥100 取整（面板宽 254，控制 meta 列宽）；nil = 无会话数据，meta 隐藏
    private static func tokSpeedText(_ speed: Double?) -> String? {
        guard let speed else { return nil }
        let v = speed < 100 ? String(format: "%.1f", speed) : String(format: "%.0f", speed)
        return v + " tok/s"
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

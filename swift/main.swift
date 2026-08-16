// main.swift — iBalance 入口 + AppDelegate（菜单栏 UI / 定时器 / 编排）
// macOS 菜单栏常驻应用（NSStatusItem），实时汇总多平台余额/积分。
// 不依赖 Python/rumps，编译为单个 .app，内存占用 ~10MB。
// 配置从 .app 同目录 config.json 读取，改配置无需重新编译。

import Cocoa
import UserNotifications

// MARK: - 弹窗统一封装（原生 NSAlert 设定）
//
// v44 重写：回归原生 NSAlert 布局——标题/说明用 messageText / informativeText（系统排版，
// 系统字号、换行与间距），按钮用 alert.addButton（系统按钮行：第一个添加的在右侧，
// 即默认主操作，回车触发；后续按钮往左排，取消按钮绑 Esc）。
// 仅两类内容放 accessoryView：输入控件（输入框/下拉）、含可点链接的富文本说明
// （informativeText 不支持可点击链接）。间距全部交给系统，不再做视图树居中、
// 隐藏占位按钮等 hack。调用侧 API 与旧版保持一致，各弹窗零改动。

enum DialogMetrics {
    /// accessoryView 默认内容宽（NSAlert 按此宽度自适应窗口；窗口宽 ≈ 此值 + 系统边距 16×2）
    static let width: CGFloat = 240
    /// 输入类弹窗（配置Key/千问）内容宽：说明文字较长，在默认宽基础上加宽一档
    static let inputWidth: CGFloat = 280
    /// accessory 内控件区左右边距（说明/控件距窗口边缘 = 系统 16pt + 此值）
    static let sidePadding: CGFloat = 8
    /// accessory 内富文本说明与控件区间距
    static let vSpacing: CGFloat = 8
    /// 苹果 HIG：标准 alert 图标 64×64pt
    static let iconSize: CGFloat = 64
}

/// 统一弹窗：原生 NSAlert 薄封装
@MainActor
final class DialogShell {
    private let alert = NSAlert()
    /// 富文本说明（含链接）：informativeText 不支持可点链接，放 accessoryView 顶部
    private var richInfo: NSAttributedString?
    /// 输入控件（输入框/下拉等），放 accessoryView 底部
    private var contentPart: (view: NSView, height: CGFloat)?
    private var buttonCount = 0
    /// accessoryView 内容宽（addContent/addInfo 的排版宽度；调用侧布局控件行也用它算宽度）
    var contentWidth: CGFloat = DialogMetrics.width
    var firstResponder: NSView?

    init() {
        alert.alertStyle = .informational
        // macOS 26 无条件显示 suppression checkbox，强制隐藏（实测有效）
        alert.showsSuppressionButton = false
        alert.suppressionButton?.isHidden = true
    }

    /// 设置标题（系统标题区，加粗）
    func addTitle(_ text: String) {
        alert.messageText = text
    }

    /// 设置图标（系统图标槽，64×64）
    func addIcon(_ image: NSImage?) {
        guard let image else { return }
        image.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
        alert.icon = image
    }

    /// 添加纯文本说明：统一转富文本样式（12pt 次级标签色、与容器等宽），与其他弹窗 info 一致
    func addInfo(_ text: String) {
        addInfo(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    }

    /// 添加富文本说明（支持链接）：左对齐，放 accessoryView 顶部
    func addInfo(_ attr: NSAttributedString) {
        richInfo = attr
    }

    /// 添加自定义控件（输入框、下拉等）
    func addContent(_ view: NSView, height: CGFloat) {
        contentPart = (view, height)
    }

    /// 添加按钮（原生按钮行：第一个添加的在右侧，即默认主操作）。
    /// 返回按钮索引，present() 返回值与之比较。
    @discardableResult
    func addButton(_ title: String, keyEquivalent: String = "") -> Int {
        let btn = alert.addButton(withTitle: title)
        if !keyEquivalent.isEmpty {
            btn.keyEquivalent = keyEquivalent
        }
        let idx = buttonCount
        buttonCount += 1
        return idx
    }

    /// 显示模态弹窗，返回点击的按钮索引（取消/关闭 = -1）
    func present() -> Int {
        // 组装 accessoryView：富文本说明（如有）在上、控件区在下
        var parts: [(view: NSView, height: CGFloat)] = []
        if let rich = richInfo {
            let textWidth = contentWidth - DialogMetrics.sidePadding * 2
            let bounds = rich.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
            let tv = NSTextView(frame: .zero)
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.backgroundColor = .clear
            tv.isRichText = true
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainerInset = .zero
            tv.alignment = .natural
            tv.textStorage?.setAttributedString(rich)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            parts.append((tv, ceil(bounds.height)))
        }
        if let part = contentPart {
            parts.append(part)
        }

        if !parts.isEmpty {
            var totalHeight: CGFloat = 0
            for (i, p) in parts.enumerated() {
                if i > 0 { totalHeight += DialogMetrics.vSpacing }
                totalHeight += p.height
            }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: totalHeight))
            var y = totalHeight
            for (i, p) in parts.enumerated() {
                y -= p.height
                p.view.frame = NSRect(x: DialogMetrics.sidePadding, y: y,
                                      width: contentWidth - DialogMetrics.sidePadding * 2,
                                      height: p.height)
                container.addSubview(p.view)
                if i < parts.count - 1 { y -= DialogMetrics.vSpacing }
            }
            alert.accessoryView = container
        }

        if let fr = firstResponder {
            alert.window.initialFirstResponder = fr
        }

        NSApp.activate(ignoringOtherApps: true)
        // NSAlert 视图树在 runModal 后才完成真实布局，图标/标题居中需在模态运行中微调
        DispatchQueue.main.async { [weak self] in
            self?.centerIconAndTitle()
        }
        let resp = alert.runModal()
        return resp.rawValue >= 1000 ? resp.rawValue - 1000 : -1
    }

    /// 模态运行中：把系统图标与标题水平居中（说明文字/按钮/间距保持系统排版）。
    /// ⚠️ v44 原生化后系统标题字段/图标视图的装配晚于 runModal 后的第一个 async tick，
    /// 直接执行会因找不到视图而静默跳过（表现为不居中）——先探测就绪，未就绪则 50ms 重试。
    private func centerIconAndTitle(retries: Int = 8) {
        guard let cv = alert.window.contentView else {
            return
        }
        cv.layoutSubtreeIfNeeded()

        let title = alert.messageText
        let iconView = findSubview(named: "_NSAlertImageView", in: cv)
        let titleField = title.isEmpty ? nil : findTextField(withText: title, in: cv)
        if iconView == nil || titleField == nil {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.centerIconAndTitle(retries: retries - 1)
                }
            }
            return
        }

        if let iconView {
            let size = iconView.frame.size
            iconView.frame.origin.x = (cv.bounds.width - size.width) / 2
            // 图标顶部与窗口顶部的间距 +4pt（整体下移）
            iconView.frame.origin.y -= 4
        }

        if let tf = titleField {
            tf.alignment = .center
            // ⚠️ 只设 cell.alignment 不生效：NSAlert 标题的 attributedStringValue 自带
            // Alignment Natural 段落样式，渲染时段落样式优先，必须连同段落样式一起改为 center
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attr = NSMutableAttributedString(attributedString: tf.attributedStringValue)
            attr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attr.length))
            tf.attributedStringValue = attr
            // 标题字段若为固有宽度（标题较短时），frame 也一并居中
            tf.frame.origin.x = (cv.bounds.width - tf.frame.width) / 2
        }
    }

    /// 按类名查找私有视图（如 _NSAlertImageView），找不到返回 nil
    private func findSubview(named className: String, in view: NSView) -> NSView? {
        if type(of: view).description().contains(className) {
            return view
        }
        for sub in view.subviews {
            if let found = findSubview(named: className, in: sub) {
                return found
            }
        }
        return nil
    }

    /// 在 NSAlert 内容视图树中查找显示指定文本的 NSTextField（即 messageText 对应的标题字段）
    private func findTextField(withText text: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.stringValue == text {
            return tf
        }
        for sub in view.subviews {
            if let found = findTextField(withText: text, in: sub) {
                return found
            }
        }
        return nil
    }
}

/// DeepSeek 品牌图标（PNG，保持原色非 template），用于 API Key / 日常额度弹窗
private func makeDsBrandIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "deepseek", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
    return img
}

/// 千问品牌图标（PNG，保持原色非 template），用于千问账号弹窗
private func makeQwenBrandIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "qwen-color", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
    return img
}

/// WorkBuddy 品牌图标（PNG，保持原色非 template），用于添加账号选择弹窗
private func makeWbBrandIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "workbuddy", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
    return img
}

/// DeepSeek 日常额度弹窗控制器（MVC：NSAlert = View，本类 = Controller）。
@MainActor
final class DsQuotaDialog: NSObject {
    private let popup = NSPopUpButton()
    private let customField = NSTextField()
    private let presets: [(label: String, value: Double)] = [
        ("未设置", 0),
        ("¥10", 10),
        ("¥20", 20),
        ("¥50", 50),
        ("¥100", 100),
    ]

    /// - Parameter quota: 当前已设置的额度（0 = 未设置），用于弹窗初值
    init(quota: Double) {
        super.init()
        for opt in presets { popup.addItem(withTitle: opt.label) }
        popup.menu?.addItem(withTitle: "自定义", action: nil, keyEquivalent: "")
        customField.placeholderString = "自定义额度"
        customField.font = NSFont.systemFont(ofSize: 12)

        if quota > 0 {
            if let idx = presets.firstIndex(where: { $0.value == quota }) {
                popup.selectItem(at: idx)
            } else {
                popup.selectItem(at: presets.count) // 自定义
            }
            customField.stringValue = "\(Int(quota))"
        } else {
            popup.selectItem(at: 0)
        }
        popup.target = self
        popup.action = #selector(popupChanged(_:))
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx < presets.count {
            let v = presets[idx].value
            customField.stringValue = v > 0 ? "\(Int(v))" : ""
        }
    }

    func present() -> Double? {
        let shell = DialogShell()
        shell.addIcon(makeDsBrandIcon())
        shell.addTitle("日常充值额度")
        // 说明文字与金额控件同容器等宽（富文本路径放 accessoryView，宽度对齐控件行）；
        // 颜色对齐系统次级标签色，字号 12pt
        shell.addInfo(NSAttributedString(
            string: "设置日常充值额度，用于显示余额进度。",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))

        // 控件区：下拉(110pt) + 间距(8pt) + 输入框(撑满)，纯 frame 布局
        let rowWidth = DialogMetrics.width - DialogMetrics.sidePadding * 2
        let popupWidth: CGFloat = 110
        let fieldWidth = rowWidth - popupWidth - 8
        let row = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 28))
        popup.frame = NSRect(x: 0, y: 1, width: popupWidth, height: 26)
        customField.frame = NSRect(x: popupWidth + 8, y: 2, width: fieldWidth, height: 24)
        row.addSubview(popup)
        row.addSubview(customField)
        shell.addContent(row, height: 28)

        // NSAlert 按钮顺序：先添加的在右边（默认按钮）
        let save = shell.addButton("保存", keyEquivalent: "\r")
        shell.addButton("取消", keyEquivalent: "\u{1b}")
        let clicked = shell.present()
        guard clicked == save else { return nil }

        if let customVal = Double(customField.stringValue.trimmingCharacters(in: .whitespaces)), customVal > 0 {
            return customVal
        }
        let idx = popup.indexOfSelectedItem
        return idx < presets.count ? presets[idx].value : 0
    }
}

/// 通用输入弹窗控制器（API Key / 千问 Ticket 等单行文本输入）。
/// 构建、联动、取值收拢在控制器内；外部只调用 present()。
@MainActor
final class InputDialog: NSObject {
    private let title: String
    private let info: String
    private let linkText: String
    private let linkURL: URL
    private let prefill: String
    private let icon: NSImage?
    /// 辅助按钮（如千问「自动获取」）：标题 + 点击回调（回传输入框以便写入结果）
    private let extraButton: (title: String, handler: (NSTextField) -> Void)?
    private let inputView = NSTextField()

    init(title: String, info: String, linkText: String, linkURL: URL, prefill: String,
         icon: NSImage? = nil,
         extraButton: (title: String, handler: (NSTextField) -> Void)? = nil) {
        self.title = title
        self.info = info
        self.linkText = linkText
        self.linkURL = linkURL
        self.prefill = prefill
        self.icon = icon
        self.extraButton = extraButton
        super.init()

        // 输入框使用 NSTextField（苹果 HIG 单行文本输入规范）：
        // - 原生 roundedBezel 外观，与系统一致
        // - cell.wraps = false + isScrollable = true → 单行不换行、水平滚动
        // - field editor 原生支持 Cmd+C/V/X/A（由主菜单 Edit 菜单分发）+ 右键菜单
        inputView.isBezeled = true
        inputView.bezelStyle = .roundedBezel
        inputView.isEditable = true
        inputView.isSelectable = true
        inputView.font = NSFont.systemFont(ofSize: 12)
        inputView.stringValue = prefill
        inputView.cell?.isScrollable = true
        inputView.cell?.wraps = false
        inputView.lineBreakMode = .byTruncatingTail
    }

    /// 辅助按钮点击：把外部传入的 handler 交给输入框（handler 内部可写回结果）
    @objc private func extraTapped(_ sender: NSButton) {
        extraButton?.handler(inputView)
    }

    /// 同步模态运行。返回用户输入内容（去除首尾空白），取消/空输入返回 nil。
    func present() -> String? {
        let shell = DialogShell()
        shell.addIcon(icon)
        shell.addTitle(title)

        // 说明 + 链接（富文本路径放 accessoryView，与输入控件同容器等宽，12pt——与日常额度弹窗同一套规范）
        let infoAttr = NSMutableAttributedString(
            string: info,
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.secondaryLabelColor])
        infoAttr.append(NSAttributedString(
            string: linkText,
            attributes: [.link: linkURL,
                         .foregroundColor: NSColor.linkColor,
                         .underlineStyle: NSUnderlineStyle.single.rawValue,
                         .font: NSFont.systemFont(ofSize: 12)]))
        shell.addInfo(infoAttr)

        // 输入行：输入框 + 可选辅助按钮（如千问「自动获取」）；
        // 行宽从 shell.contentWidth 推导（本弹窗用加宽规格 inputWidth）
        shell.contentWidth = DialogMetrics.inputWidth
        let rowWidth = shell.contentWidth - DialogMetrics.sidePadding * 2
        let extraBtnWidth: CGFloat = extraButton != nil ? 72 : 0
        let fieldWidth = extraBtnWidth > 0 ? rowWidth - extraBtnWidth - 8 : rowWidth
        let row = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 28))
        inputView.frame = NSRect(x: 0, y: 2, width: fieldWidth, height: 24)
        row.addSubview(inputView)
        if let extra = extraButton {
            let btn = NSButton(title: extra.title, target: self, action: #selector(extraTapped(_:)))
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 12)
            btn.controlSize = .small
            btn.frame = NSRect(x: fieldWidth + 8, y: 1, width: extraBtnWidth, height: 26)
            row.addSubview(btn)
        }
        shell.addContent(row, height: 28)
        shell.firstResponder = inputView

        // NSAlert 按钮顺序：第一个添加的在右侧（默认主操作）
        let save = shell.addButton("保存", keyEquivalent: "\r")
        shell.addButton("稍后", keyEquivalent: "\u{1b}")
        let clicked = shell.present()
        guard clicked == save else { return nil }
        let v = inputView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private let statusBar = NSStatusBar.system
    private var statusItem: NSStatusItem!
    private var autoCheckinMenuItem: NSMenuItem!
    private var refreshIntervalMenuItem: NSMenuItem!
    private var refreshIntervalOptions: [NSMenuItem] = []
    private var decimalsQwMenuItem: NSMenuItem!
    private var hideMainIconMenuItem: NSMenuItem!
    private var timer: Timer?
    private var checkinTimer: Timer?
    private var wbOauthMenuItem: NSMenuItem!
    private var wbOauthInProgress = false
    private var wbOauthCancelled = false
    private var traeCollectMenuItem: NSMenuItem!
    private var traeCollectInProgress = false
    // 手动签到进行中标记：防重复触发
    private var manualCheckinInProgress = false
    // NSPopover 详情面板（左键打开；设置菜单保留给右键/齿轮）
    private var popoverController: NSPopover?
    private var panelView: BalancePanelView?
    /// 面板打开期间锁定的原始 origin：菜单栏 title 更新导致 button 宽度变化、
    /// popover 自动 reposition 时，用 KVO 同步把 window 拉回原位（无动画，避免跳动）。
    private var panelAnchorOrigin: NSPoint?
    /// popover window 的 frame KVO 观察令牌：面板打开期间生效，关闭时移除。
    private var panelFrameObserver: NSKeyValueObservation?
    // 最近一次面板关闭所在事件的时间戳（transient 面板外点击会先关闭面板，
    // 随后同一 click 的 mouseUp 才触发 status item action → 用于识别「本次点击已关闭面板」）
    private var lastCloseEventTime: TimeInterval = 0
    private var settingsMenu: NSMenu!
    private var lastUpdatedAt = ""
    /// 上次余额刷新完成时间：打开面板时若距此 <1分钟则跳过自动刷新，避免频繁请求
    private var lastRefreshTime = Date.distantPast

    /// 进行中的刷新任务：onRefresh 触发时先取消旧任务，保证同一时刻只有一个刷新在跑
    private var refreshTask: Task<Void, Never>?

    private var config = AppConfig()
    // 缓存原始数据，切换小数位时即时重绘（仅在主线程变更）
    private var cacheDs: (symbol: String, totalRaw: String, total: Double)?
    private var cacheWb: (remain: Double, total: Double)?
    /// WorkBuddy 多账号额度缓存：uid → (remain, total)，用于面板显示每号余额卡片
    private var cacheWbAccounts: [String: (remain: Double, total: Double)] = [:]
    private var cacheTrae: (limit: Double, used: Double)?
    /// TRAE 多账号额度缓存：uid → (limit, used)
    private var cacheTraeAccounts: [String: (limit: Double, used: Double)] = [:]
    private var cacheQw: QianwenService.Quota?
    /// ZCode 多账号额度缓存：uid → (remain, total, planEndsAt)，remain/total 为 token 数，planEndsAt 为免费套餐到期戳（0=无）
    private var cacheZcodeAccounts: [String: (remain: Double, total: Double, planEndsAt: TimeInterval)] = [:]
    // 点阵脉冲状态：仅由真实数据刷新（refreshOne*）更新，面板开关 syncPanel 只读不写
    // 规则：usedRatio 上升（额度被消耗）→ pulsing=true；稳定或回升 → pulsing=false
    private var prevTraeRatio: [String: Double] = [:]
    private var traePulsing: [String: Bool] = [:]
    private var prevWbRatio: [String: Double] = [:]
    private var wbPulsing: [String: Bool] = [:]
    private var prevZcodeRatio: [String: Double] = [:]
    private var zcodePulsing: [String: Bool] = [:]
    private var prevQwRatio: Double = -1   // -1 = 未初始化
    private var qwPulsing = false
    private var prevDsRatio: Double = -1   // DeepSeek 已用占比上次值（-1 = 未初始化）
    private var dsPulsing = false          // 余额被消耗 → 点阵脉冲

    /// 点阵脉冲核心规则（WB/TRAE/千问/DeepSeek 共用）：
    /// usedRatio 上升 → pulsing=true（被消耗）；稳定或回升 → pulsing=false；首轮（prev<0）不触发。
    private func updatePulsingState(prevRatio: inout Double, pulsing: inout Bool, newRatio: Double) {
        if prevRatio >= 0 { pulsing = newRatio > prevRatio }
        prevRatio = newRatio
    }
    // 离线标记：网络不可达时菜单栏显示离线提示并暂停刷新
    private var isOffline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标（与 Info.plist LSUIElement 双保险）
        NSApp.setActivationPolicy(.accessory)

        // 安装主菜单：菜单栏 App 虽不显示菜单条，但 Edit 菜单的快捷键
        // （Cmd+C/V/X/A）会分发给弹窗内 NSTextField 的 field editor，
        // 从而原生支持复制/粘贴/剪切/全选 + 右键菜单。
        setupMainMenu()

        config = ConfigStore.load()

        // 菜单栏 status item
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        if !config.hideMainIcon {
            statusItem.button?.image = loadTemplateImage(named: "credit-card-filled", size: NSSize(width: 16, height: 16))
        }
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = "¥..."

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

        decimalsQwMenuItem = NSMenuItem(title: "Qwen 显示1位小数", action: #selector(onToggleDecimals(_:)), keyEquivalent: "")
        decimalsQwMenuItem.target = self
        decimalsQwMenuItem.state = (config.qianwenDecimals == 1) ? .on : .off
        menu.addItem(decimalsQwMenuItem)

        menu.addItem(NSMenuItem.separator())

        let apiKeyMenuItem = NSMenuItem(title: "设置 API Key…", action: #selector(onSetApiKey), keyEquivalent: "")
        apiKeyMenuItem.target = self
        menu.addItem(apiKeyMenuItem)

        let qwTicketMenuItem = NSMenuItem(title: "手动设置千问 Ticket（备用）…", action: #selector(onSetQianwenTicket), keyEquivalent: "")
        qwTicketMenuItem.target = self
        menu.addItem(qwTicketMenuItem)

        menu.addItem(NSMenuItem.separator())

        hideMainIconMenuItem = NSMenuItem(title: "显示菜单栏主图标", action: #selector(onToggleHideMainIcon), keyEquivalent: "")
        hideMainIconMenuItem.target = self
        hideMainIconMenuItem.state = config.hideMainIcon ? .off : .on
        menu.addItem(hideMainIconMenuItem)

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

    // MARK: - 图标（从 Resources 加载 SVG template image，系统自动 tint + active/inactive 变暗）

    private func loadTemplateImage(named name: String, size: NSSize) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = size
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

    /// 强制 status item 按当前聚焦状态重绘。通知可能在非主线程投递，统一回主线程更新 UI。
    @objc private func refreshStatusItemAppearance() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusItem.button?.image = self.config.hideMainIcon ? nil : self.loadTemplateImage(named: "credit-card-filled", size: NSSize(width: 16, height: 16))
            self.updateTitle()
            self.statusItem.button?.needsDisplay = true
        }
    }

    /// 千分位格式化（每 k 加逗号）
    private func fmtAmountCommas(_ value: Any, decimals: Int) -> String {
        guard let dv = anyToDouble(value) else { return "\(value)" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = decimals
        f.minimumFractionDigits = decimals
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: dv)) ?? String(format: "%.\(decimals)f", dv)
    }

    /// 按服务器回传的原始小数位格式化（不截断不补零），千分位美化
    private func fmtAmountRaw(_ raw: String) -> String {
        let frac = raw.contains(".") ? raw.split(separator: ".", maxSplits: 1)[1].count : 0
        return fmtAmountCommas(raw, decimals: min(frac, 8))
    }

    // MARK: - 详情面板（NSPopover）

    /// 左键点击 → 切换详情面板；右键 → 手动弹出设置菜单。
    @objc private func onStatusItemClicked(_ sender: Any?) {
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
    private func buildPanelOnce() {
        guard statusItem?.button != nil else { return }
        let panel = BalancePanelView()
        panel.onOpenCockpit = { [weak self] in self?.onOpenCockpit() }
        panel.onToggleAutoCheckin = { [weak self] in self?.onToggleAutoCheckin() }
        panel.onAddWbAccount = { [weak self] in self?.onAddWbAccount() }
        panel.onAddZcodeAccount = { [weak self] in self?.onAddZcodeAccount() }
        panel.onSetDsQuota = { [weak self] in self?.onSetDsQuota() }
        panel.onSetInterval = { [weak self] in self?.applyRefreshInterval(TimeInterval($0)) }
        panel.onSetApiKey = { [weak self] in self?.onSetApiKey() }
        panel.onSetQwTicket = { [weak self] in self?.onSetQianwenTicket() }
        panel.onToggleHideIcon = { [weak self] in self?.onToggleHideMainIcon() }
        panel.onToggleHideWbNickname = { [weak self] in self?.onToggleHideWbNickname() }
        panel.onToggleDebug = { [weak self] in self?.onToggleDebug() }
        panel.onAbout = { [weak self] in self?.onAbout() }
        panel.onManualCheckin = { [weak self] in self?.onManualCheckin() }
        panel.onShowCheckinHistory = { [weak self] in self?.onShowCheckinHistory() }
        panel.onQuit = { [weak self] in self?.onQuit() }
        // 余额卡片点击：DeepSeek / 千问 打开浏览器，TRAE / WorkBuddy 启动应用
        panel.onClickDeepSeek = {
            NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
        }
        panel.onClickTrae = { [weak self] in
            self?.openApp(bundleId: "cn.trae.solo.app", missingTitle: "未找到 TRAE 应用",
                          missingMsg: "未找到 Bundle ID 为 cn.trae.solo.app 的应用，请确认 TRAE 已安装。")
        }
        panel.onClickWorkBuddy = { [weak self] in
            self?.openApp(bundleId: "com.workbuddy.workbuddy", missingTitle: "未找到 WorkBuddy 应用",
                          missingMsg: "未找到 Bundle ID 为 com.workbuddy.workbuddy 的应用，请确认 WorkBuddy 已安装。")
        }
        panel.onSwitchWbAccount = { [weak self] uid in
            self?.switchWbAccount(uid: uid)
        }
        panel.onCollectTraeAccount = { [weak self] in self?.onCollectTraeAccount() }
        panel.onSwitchTraeAccount = { [weak self] uid in
            self?.switchTraeAccount(uid: uid)
        }
        panel.onClickZcode = { [weak self] in
            self?.openApp(bundleId: "dev.zcode.app", missingTitle: "未找到 ZCode 应用",
                          missingMsg: "未找到 Bundle ID 为 dev.zcode.app 的应用，请确认 ZCode 已安装。")
        }
        panel.onSwitchZcodeAccount = { [weak self] uid in
            self?.switchZcodeAccount(uid: uid)
        }
        panel.onClickQianwen = {
            NSWorkspace.shared.open(URL(string: "https://platform.qianwenai.com/home/billing/subscription/token-plan-individual")!)
        }
        let popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        // 固定深色外观：面板背景是深色纯色，强制 darkAqua 保证 labelColor 等动态颜色
        // 在浅色系统外观下也渲染为深色模式取值（否则深色底配黑字不可读），且不受焦点影响
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = BalancePanelViewController(panel: panel)
        // 面板自带 320 内在宽度，直接按约束解出真实高度，避免零尺寸 popover
        popover.contentSize = panel.fittingSize
        popoverController = popover
        panelView = panel
    }

    /// 复用已构建的 popover/panel 展示，不再重建视图层级（消除高频点击延迟）。
    private func showPanel() {
        guard let button = statusItem.button else { return }
        if popoverController == nil { buildPanelOnce() }   // 兜底：未预构建时按需构建一次
        guard let popover = popoverController, let panel = panelView else { return }
        // 先展示缓存数据（即时响应），再触发自动刷新拿最新
        panel.update(makePanelSnapshot())
        // 1分钟内已刷新过则跳过，避免频繁开关面板触发大量 API 请求
        if Date().timeIntervalSince(lastRefreshTime) >= 60 {
            onRefresh()
        }
        // ⚠️ 必须在 show 之前激活 App：LSUIElement 应用默认不活跃，popover 首帧会按
        // 「非活跃」渲染（玻璃材质整体偏暗），激活后才呈现正常色调（官方推荐姿势）。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // popover 窗口默认不是 key window：.transient 只在 key window 状态下
        // 才会响应「面板外点击」关闭，且非 key 时玻璃材质同样偏暗 → 强制置 key。
        popover.contentViewController?.view.window?.makeKey()
        // 锁定面板原始 origin，并用 KVO 监听 popover window frame 变化：
        // 菜单栏 title 更新导致 button 宽度变化、popover 自动 reposition 时，
        // 立即（无动画）把 window 拉回原位，避免面板跳动后归位的视觉抖动。
        startPanelOriginLock()
    }

    /// 启用面板位置锁定：记录原始 origin，KVO 监听 window frame，偏离时立即无动画拉回。
    private func startPanelOriginLock() {
        guard let w = popoverController?.contentViewController?.view.window else { return }
        panelAnchorOrigin = w.frame.origin
        // 移除旧观察（若有），再重新添加
        panelFrameObserver?.invalidate()
        panelFrameObserver = w.observe(\.frame, options: [.new]) { [weak self] win, _ in
            guard let self = self, let origin = self.panelAnchorOrigin else { return }
            // 仅当 origin 偏离时才校正（避免无谓的 setFrameOrigin 循环）
            if win.frame.origin != origin {
                // 禁用动画：直接 setFrameOrigin 会触发默认动画，需包裹 NSAnimationContext
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                win.setFrameOrigin(origin)
                NSAnimationContext.endGrouping()
            }
        }
    }

    // MARK: - NSPopoverDelegate

    /// 模态弹窗（NSAlert 等）运行期间临时把 popover 行为切为 applicationDefined：
    /// .transient 会把「与弹窗交互」误判为「点击面板外」而关闭面板，
    /// 导致点「操作」区的 API Key / 千问 Ticket / 关于 等选项时面板先消失。
    /// block 结束后恢复 .transient（恢复「点击面板外自动关闭」）。
    /// 注意：仅包裹同步模态；异步长流程（如 OAuth 打开浏览器）不要用，否则面板会一直浮在最前。
    private func keepPanelAliveDuring<T>(_ block: () -> T) -> T {
        guard let popover = popoverController, popover.isShown else { return block() }
        popover.behavior = .applicationDefined
        defer { popover.behavior = .transient }
        return block()
    }

    /// popover 关闭后归还焦点（隐藏 App），让之前活跃的应用恢复前台，
    /// 避免菜单栏小工具霸占焦点。
    func popoverDidClose(_ notification: Notification) {
        // 移除面板位置锁定：停用 KVO + 清空原始 origin
        panelFrameObserver?.invalidate()
        panelFrameObserver = nil
        panelAnchorOrigin = nil
        // 记录关闭时正在处理的事件时间戳：transient「面板外点击」关闭时，
        // currentEvent 即该 click（onStatusItemClicked 用它识别同一 click，避免抖动重弹）
        lastCloseEventTime = NSApp.currentEvent?.timestamp ?? 0
        NSApp.hide(nil)
    }

    /// 从当前缓存构建面板数据快照（离线横幅 / 四服务 / 设置状态 / 更新时间）
    private func makePanelSnapshot() -> PanelSnapshot {
        var s = PanelSnapshot()
        s.offline = isOffline
        s.updatedAt = lastUpdatedAt
        if let ds = cacheDs {
            s.ds = "\(ds.symbol)\u{2009}\(fmtAmountRaw(ds.totalRaw))"
            if config.deepseekCommonQuota > 0 {
                let used = max(0, config.deepseekCommonQuota - ds.total)
                s.dsUsedRatio = min(1, used / config.deepseekCommonQuota)
            }
            s.dsPulsing = dsPulsing
        }
        // 调试模式：DeepSeek 金额固定 999.99（无缓存时也显示，便于查看卡片 UI）
        if config.debugMode {
            s.ds = "¥\u{2009}999.99"
        }
        if config.deepseekCommonQuota > 0 {
            s.dsInfoText = "日常额度 ¥\(Int(config.deepseekCommonQuota))"
        }
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
            }
            snap.checkinDone = UserDefaults.standard.string(forKey: "trae_checkin_date_\(ac.uid)") == today
            snap.checkinFailed = UserDefaults.standard.string(forKey: "trae_checkin_failed_date_\(ac.uid)") == today
            snap.streak = UserDefaults.standard.integer(forKey: "trae_checkin_streak_\(ac.uid)")
            snap.reward = UserDefaults.standard.integer(forKey: "trae_checkin_reward_\(ac.uid)")
            snap.pulsing = traePulsing[ac.uid] ?? false
            s.traeAccounts.append(snap)
        }
        if let qw = cacheQw, qw.weekLimit > 0 {
            let weekPct = qw.weekRem / qw.weekLimit * 100
            s.qwWeek = fmtAmountCommas(weekPct, decimals: config.qianwenDecimals) + "%"
            s.qwWeekUsedRatio = 1 - weekPct / 100
            s.qwPulsing = qwPulsing
            // 套餐到期天数：优先用 API 返回的 remainingDays（和官网显示完全一致）
            // 仅当 remainingDays<=0 且 expireAt>0 时回退 Calendar 本地计算（今天到期/已过期场景）
            if qw.remainingDays > 0 {
                s.qwExpireText = "\u{2009}\(qw.remainingDays)\u{2009}天后到期"
            } else if qw.expireAt > 0 {
                let cal = Calendar.current
                let startOfToday = cal.startOfDay(for: Date())
                let startOfExpire = cal.startOfDay(for: Date(timeIntervalSince1970: qw.expireAt))
                let diffDays = cal.dateComponents([.day], from: startOfToday, to: startOfExpire).day ?? 0
                if diffDays == 0 {
                    s.qwExpireText = "\u{2009}今天到期"
                } else if diffDays < 0 {
                    s.qwExpireText = "\u{2009}已过期\(-diffDays)\u{2009}天"
                } else {
                    s.qwExpireText = "\u{2009}\(diffDays)\u{2009}天后到期"
                }
            }
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
            }
            snap.checkinDone = UserDefaults.standard.string(forKey: "wb_checkin_date_\(ac.uid)") == today
            snap.checkinFailed = UserDefaults.standard.string(forKey: "wb_checkin_failed_date_\(ac.uid)") == today
            snap.streak = UserDefaults.standard.integer(forKey: "wb_checkin_streak_\(ac.uid)")
            snap.reward = UserDefaults.standard.integer(forKey: "wb_checkin_reward_\(ac.uid)")
            snap.pulsing = wbPulsing[ac.uid] ?? false
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
                // 到期副标题：仅当前账号 + 有免费套餐（Start Plan）时显示，剩余时长 HH:mm（小时可超 24）
                if isCurrent, c.planEndsAt > 0 {
                    let remainSec = c.planEndsAt - Date().timeIntervalSince1970
                    if remainSec > 0 {
                        let h = Int(remainSec) / 3600
                        let m = (Int(remainSec) % 3600) / 60
                        snap.expireText = String(format: "\u{2009}%02d:%02d\u{2009}后到期", h, m)
                    }
                }
            }
            snap.pulsing = zcodePulsing[ac.uid] ?? false
            s.zcodeAccounts.append(snap)
        }
        // ── 设置/操作状态 ──
        s.traeAutoCheckin = config.traeAutoCheckin
        s.wbAutoCheckin = config.workbuddyAutoCheckin
        // 自动签到副标题：今日签到统计「M-d x成功 x失败」（手动一键签到写同一套标记，自然计入；
        // 失败按 failed_date==today 口径，昨日失败残留不计）
        var okCount = 0
        var failCount = 0
        for ac in traeAccountsList {
            if UserDefaults.standard.string(forKey: "trae_checkin_date_\(ac.uid)") == today { okCount += 1 }
            if UserDefaults.standard.string(forKey: "trae_checkin_failed_date_\(ac.uid)") == today { failCount += 1 }
        }
        for ac in accounts {
            if UserDefaults.standard.string(forKey: "wb_checkin_date_\(ac.uid)") == today { okCount += 1 }
            if UserDefaults.standard.string(forKey: "wb_checkin_failed_date_\(ac.uid)") == today { failCount += 1 }
        }
        if okCount + failCount > 0 {
            let df = DateFormatter()
            df.dateFormat = "M-d"
            s.lastCheckinTime = "\(df.string(from: Date())) \(okCount)成功 \(failCount)失败"
        }
        s.wbOauthInProgress = wbOauthInProgress
        s.refreshIntervalSeconds = Int(config.refreshInterval)
        s.hideMainIcon = config.hideMainIcon
        s.hideWbNickname = config.hideWbNickname
        s.debugMode = config.debugMode
        return s
    }

    /// 数据变化时同步刷新面板（面板打开时才重绘）
    private func syncPanel() {
        guard popoverController?.isShown == true, let panel = panelView else { return }
        panel.update(makePanelSnapshot())
    }

    // MARK: - 菜单回调

    @objc private func onRefresh() {
        panelView?.setRefreshing(true)   // 面板显示「刷新中…」脉冲提示
        // 取消进行中的旧刷新再起新任务：定时器/网络恢复/开面板/手动可并发触发，
        // 不取消会导致旧任务慢响应覆盖新缓存，且重复请求有触发风控的风险
        refreshTask?.cancel()
        refreshTask = Task { await performRefresh() }
    }

    @objc private func onToggleDecimals(_ sender: NSMenuItem) {
        if sender == decimalsQwMenuItem {
            toggleQwDecimals()
        }
    }

    /// 千问小数位 0/1 切换（菜单与面板共用）
    private func toggleQwDecimals() {
        config.qianwenDecimals = (config.qianwenDecimals == 1) ? 0 : 1
        decimalsQwMenuItem.state = (config.qianwenDecimals == 1) ? .on : .off
        updateTitle()
        ConfigStore.save(config)
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

    @objc private func onToggleHideMainIcon() {
        config.hideMainIcon = !config.hideMainIcon
        hideMainIconMenuItem.state = config.hideMainIcon ? .off : .on
        statusItem.button?.image = config.hideMainIcon ? nil : loadTemplateImage(named: "credit-card-filled", size: NSSize(width: 16, height: 16))
        updateTitle()
        ConfigStore.save(config)
        syncPanel()
    }

    @objc private func onToggleHideWbNickname() {
        config.hideWbNickname = !config.hideWbNickname
        ConfigStore.save(config)
        syncPanel()
    }

    /// 调试模式：余额卡片角标全显 + DeepSeek 金额固定 999.99（UI 验证用）
    @objc private func onToggleDebug() {
        config.debugMode = !config.debugMode
        ConfigStore.save(config)
        syncPanel()
    }

    @objc private func onQuit() {
        NSApp.terminate(nil)
    }

    @objc private func onAbout() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let shell = DialogShell()
        shell.addIcon(NSApp.applicationIconImage)
        shell.addTitle("关于 iBalance")
        // 长文阅读类弹窗：内容宽 +8 抵消 sidePadding 增量，保持正文行宽不变
        shell.contentWidth = DialogMetrics.width + 8
        shell.addInfo("菜单栏常驻小工具，实时聚合多平台账户余额与积分。\n\n"
            + "• DeepSeek 余额（API Key 查询）\n• WorkBuddy 积分（多号 OAuth，自动签到）\n• TRAE 积分（本地解密，自动签到）\n• 千问 Token Plan 周额度（Edge 登录态）\n• 刷新间隔 1 / 3 / 5 分钟\n\n"
            + "配置存于同目录 config.json\n版本 v\(build)")
        shell.addButton("知道了", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }
    }

    @objc private func onSetApiKey() {
        guard let key = keepPanelAliveDuring({ promptForApiKey(prefill: config.deepseekApiKey) }) else { return }
        config.deepseekApiKey = key
        ConfigStore.save(config)
        onRefresh()
    }

    @objc private func onSetDsQuota() {
        let quota = keepPanelAliveDuring { DsQuotaDialog(quota: config.deepseekCommonQuota).present() }
        guard let quota else { return }  // 取消
        config.deepseekCommonQuota = max(0, quota)
        ConfigStore.save(config)
        syncPanel()
    }

    // MARK: - 统一格式化标题（用缓存 + 当前小数位）

    private func updateTitle() {
        // 菜单栏字号比系统默认小 1pt
        let menuSize = NSFont.menuBarFont(ofSize: 0).pointSize - 1
        let baseFont = NSFont.systemFont(ofSize: menuSize, weight: .regular)
        let boldFont = NSFont.systemFont(ofSize: menuSize, weight: .semibold)

        // 离线标记：网络不可达时菜单栏只显示离线提示
        if isOffline {
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: "⚠︎", attributes: [.font: baseFont]))
            attr.append(NSAttributedString(string: " 离线", attributes: [.font: baseFont]))
            statusItem.button?.attributedTitle = attr
            return
        }

        let attr = NSMutableAttributedString()
        func append(_ s: String, bold: Bool = false) {
            attr.append(NSAttributedString(string: s, attributes: [.font: bold ? boldFont : baseFont]))
        }

        var hasContent = false

        if let ds = cacheDs {
            let total = fmtAmountRaw(ds.totalRaw)
            if !config.hideMainIcon { append(" ") }
            append(ds.symbol)
            append("\u{2009}\(total)", bold: true)
            hasContent = true
        }

        if let trae = cacheTrae {
            if hasContent { append("  ") }
            let remaining = trae.limit - trae.used
            let amount = fmtAmountCommas(remaining, decimals: 0)
            append("✦")
            append("\u{2009}\(amount)", bold: true)
            hasContent = true
        }

        if let wb = cacheWb {
            if hasContent { append("  ") }
            append("W")
            append("\u{2009}\(fmtAmountCommas(wb.remain, decimals: 0))", bold: true)
            hasContent = true
        }

        if let qw = cacheQw {
            if hasContent { append("  ") }
            append("Q")
            append("\u{2009}\(fmtAmountCommas(qw.weekRem / max(qw.weekLimit, 1) * 100, decimals: config.qianwenDecimals))%", bold: true)
            hasContent = true
        }

        if hasContent {
            statusItem.button?.attributedTitle = attr
        } else {
            let placeholder = NSMutableAttributedString()
            placeholder.append(NSAttributedString(string: "¥", attributes: [.font: baseFont]))
            placeholder.append(NSAttributedString(string: "...", attributes: [.font: boldFont]))
            statusItem.button?.attributedTitle = placeholder
        }

        // 面板打开时同步重绘
        syncPanel()
        // 面板位置锁定由 startPanelOriginLock 的 KVO 接管：origin 偏离时立即无动画拉回
    }

    // MARK: - 请求编排（四服务并行，各自独立更新 UI）

    /// 主刷新流程：离线直接返回；在线则并行拉取四个服务，先到先显示。
    /// 任务被取消时（新刷新已发起）不再写时间戳/停动效，交由新任务收尾。
    private func performRefresh() async {
        guard !Task.isCancelled else { return }
        guard NetworkMonitor.shared.isOnline else {
            isOffline = true
            panelView?.setRefreshing(false)
            updateTitle()
            return
        }
        isOffline = false
        let cfg = config

        // 四服务并行请求，先到先显示：每个服务返回后立即写缓存并重绘标题，互不等待
        async let a: Void = refreshOneDeepSeek(cfg)
        async let b: Void = refreshOneWorkBuddy(cfg)
        async let c: Void = refreshOneTrae(cfg)
        async let d: Void = refreshOneQianwen(cfg)
        async let e: Void = refreshOneZcode(cfg)
        _ = await (a, b, c, d, e)

        // 已被取消（被更新的刷新取代）→ 不写收尾状态，避免提前停掉新任务的刷新动效
        guard !Task.isCancelled else { return }
        // 记录更新时间（面板底部展示）
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        lastUpdatedAt = f.string(from: Date())
        lastRefreshTime = Date()  // 记录本次刷新完成时间，用于面板打开时节流
        panelView?.setRefreshing(false)  // 先停动效，syncPanel 再写入真实更新时间
        syncPanel()
    }

    private func refreshOneDeepSeek(_ cfg: AppConfig) async {
        let ds = await DeepSeekService.fetch(apiKey: cfg.deepseekApiKey)
        // 已取消（被新刷新取代）：取消导致的失败不写缓存也不报错，避免旧结果覆盖新缓存
        guard !Task.isCancelled else { return }
        if let bal = ds.balance {
            let totalNum = Double(bal.totalRaw) ?? 0
            cacheDs = (bal.symbol, bal.totalRaw, totalNum)
            // 脉冲：已用占比（=额度-余额）上升（余额被消耗）→ pulsing；稳定或回升 → 停止
            if config.deepseekCommonQuota > 0 {
                let used = max(0, config.deepseekCommonQuota - totalNum)
                updatePulsingState(prevRatio: &prevDsRatio, pulsing: &dsPulsing,
                                   newRatio: min(1, used / config.deepseekCommonQuota))
            } else {
                prevDsRatio = -1
                dsPulsing = false
            }
        }
        if !ds.error.isEmpty { notifyError(ds.error) }
        updateTitle()
    }

    private func refreshOneWorkBuddy(_ cfg: AppConfig) async {
        guard cfg.workbuddyEnabled else {
            return
        }
        // 主账号（当前登录）：用 authInfo 直接查询
        if let wb = await WorkBuddyService.fetchSummary() {
            guard !Task.isCancelled else { return }
            cacheWb = wb
            if let uid = WorkBuddyService.authInfo()?.uid {
                cacheWbAccounts[uid] = wb
                updatePulsingForWb(uid: uid, remain: wb.remain, total: wb.total)
            }
            updateTitle()
        }
        // 多号：遍历其余账号，先刷新 token 再查额度
        let accounts = wbCheckinAccounts()
        for ac in accounts {
            if Task.isCancelled { return }  // 被新刷新取代：不再发后续账号请求
            if ac.uid == WorkBuddyService.authInfo()?.uid { continue } // 主账号已查
            let refreshed = await WorkBuddyService.refreshTokenIfNeeded(account: ac)
            if refreshed != ac {
                if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                    config.workbuddyAccounts[idx] = refreshed
                    ConfigStore.save(config)
                }
            }
            if let r = await WorkBuddyService.fetchSummaryForAccount(token: refreshed.token, uid: refreshed.uid, domain: refreshed.domain) {
                guard !Task.isCancelled else { return }
                cacheWbAccounts[refreshed.uid] = r
                updatePulsingForWb(uid: refreshed.uid, remain: r.remain, total: r.total)
            }
        }
        syncPanel()
    }

    /// WB 脉冲计算：usedRatio = (total-remain)/total，上升 → pulsing=true（被消耗）；稳定/回升 → false
    private func updatePulsingForWb(uid: String, remain: Double, total: Double) {
        var prev = prevWbRatio[uid] ?? -1
        var pulsing = wbPulsing[uid] ?? false
        updatePulsingState(prevRatio: &prev, pulsing: &pulsing,
                           newRatio: total > 0 ? (total - remain) / total : 0)
        prevWbRatio[uid] = prev
        wbPulsing[uid] = pulsing
    }

    // MARK: - ZCode（智谱 Coding Plan）余额刷新

    /// 遍历 config 中导入的 ZCode 账号，逐号查询 Coding Plan 用量（本平台无签到）
    private func refreshOneZcode(_ cfg: AppConfig) async {
        for ac in cfg.zcodeAccounts {
            if Task.isCancelled { return }  // 被新刷新取代：不再发后续账号请求
            // 存量账号自动回填昵称（早期导入无 nickname）：credentials.json 可解出且 uid 匹配时写入一次
            if ac.nickname.isEmpty, let nick = ZcodeService.autoNickname(forUid: ac.uid),
               let idx = config.zcodeAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                config.zcodeAccounts[idx].nickname = nick
                ConfigStore.save(config)
            }
            let r = await ZcodeService.fetchBalance(token: ac.token)
            guard !Task.isCancelled, r.total > 0 else { continue }
            cacheZcodeAccounts[ac.uid] = r
            var prev = prevZcodeRatio[ac.uid] ?? -1
            var pulsing = zcodePulsing[ac.uid] ?? false
            updatePulsingState(prevRatio: &prev, pulsing: &pulsing,
                               newRatio: r.total > 0 ? (r.total - r.remain) / r.total : 0)
            prevZcodeRatio[ac.uid] = prev
            zcodePulsing[ac.uid] = pulsing
        }
        syncPanel()
    }

    private func refreshOneTrae(_ cfg: AppConfig) async {
        // 主账号（当前登录）：从 storage.json 解密查询
        let mainUid = TraeService.readAuthInfo(storagePath: cfg.traeStoragePath)?.uid ?? ""
        if let t = await TraeService.fetchCredits(storagePath: cfg.traeStoragePath) {
            guard !Task.isCancelled else { return }
            cacheTrae = t
            if !mainUid.isEmpty {
                cacheTraeAccounts[mainUid] = t
                updatePulsingForTrae(uid: mainUid, limit: t.limit, used: t.used)
            }
            updateTitle()
        }
        // 多号：遍历 config 中预存的其他账号，用各自加密块解密 token 后查额度
        for ac in config.traeAccounts where ac.uid != mainUid {
            if Task.isCancelled { return }  // 被新刷新取代：不再发后续账号请求
            if let token = TraeService.getTokenFromEncrypted(ac.encryptedAuthInfo),
               let r = await TraeService.fetchCreditsForToken(token) {
                guard !Task.isCancelled else { return }
                cacheTraeAccounts[ac.uid] = r
                updatePulsingForTrae(uid: ac.uid, limit: r.limit, used: r.used)
            }
        }
        syncPanel()
        // 补全签到 streak/reward（auto-checkin 关闭时也能显示）
        guard !Task.isCancelled else { return }  // 取消后不再发签到状态请求，减少对风控接口的打扰
        await traeCheckinStatusFill()
    }

    /// TRAE 脉冲计算：usedRatio 上升 → pulsing=true（被消耗）；稳定/回升 → false
    private func updatePulsingForTrae(uid: String, limit: Double, used: Double) {
        var prev = prevTraeRatio[uid] ?? -1
        var pulsing = traePulsing[uid] ?? false
        updatePulsingState(prevRatio: &prev, pulsing: &pulsing,
                           newRatio: limit > 0 ? used / limit : 0)
        prevTraeRatio[uid] = prev
        traePulsing[uid] = pulsing
    }

    /// 收集 TRAE 待查询账号：config 预存账号 + 当前登录账号（uid 去重）
    /// 主账号不在 config 时自动加入（不持久化，下次切换后由用户决定是否采集保存）
    private func traeCheckinAccounts() -> [TraeAccount] {
        var accounts = config.traeAccounts
        if let cur = TraeService.readAuthInfo(storagePath: config.traeStoragePath),
           !accounts.contains(where: { $0.uid == cur.uid }) {
            accounts.append(TraeAccount(uid: cur.uid, username: cur.username, encryptedAuthInfo: cur.encryptedAuthInfo))
        }
        return accounts
    }

    private func refreshOneQianwen(_ cfg: AppConfig) async {
        let qw = await QianwenService.fetchQuota(manualTicket: cfg.qianwenTicket)
        guard !Task.isCancelled else { return }  // 被新刷新取代：取消导致的空结果不写缓存
        if let q = qw.quota {
            cacheQw = q
            // 脉冲：周 usedRatio 上升（被消耗）→ pulsing；稳定/回升 → 停止
            updatePulsingState(prevRatio: &prevQwRatio, pulsing: &qwPulsing,
                               newRatio: q.weekLimit > 0 ? (q.weekLimit - q.weekRem) / q.weekLimit : 0)
            updateTitle()
        }
    }

    // MARK: - WorkBuddy 自动签到

    /// 收集待签到账号：config 预存的其他账号 + 当前登录账号（token 自动刷新，uid 去重）
    /// 主账号不在 config 时自动持久化（含 refreshToken/expiresAt），下次主账号切换后原账号仍可续期签到。
    private func wbCheckinAccounts() -> [WBAccount] {
        var accounts = config.workbuddyAccounts
        if let auth = WorkBuddyService.authInfo(),
           !accounts.contains(where: { $0.uid == auth.uid }) {
            let main = WBAccount(token: auth.token, uid: auth.uid, domain: auth.domain,
                                 nickname: auth.nickname, refreshToken: auth.refreshToken, expiresAt: auth.expiresAt)
            accounts.append(main)
            config.workbuddyAccounts.append(main)
            ConfigStore.save(config)
        }
        return accounts
    }

    /// 多号签到核心：遍历账号，每号本地日期守卫（每天最多一次），签到前自动刷新 token。
    /// streak/reward 为 0 时即使今天已签也会查状态补全。
    /// 自动路径走错峰：每账号每天有随机就绪时刻（now+0~10min，wbCheckinReadyTimestamp），
    /// 未到点的账号本轮跳过（不打任何接口）；force=true（手动一键签到）绕过错峰立即全签。
    private func wbAutoCheckinIfNeeded(force: Bool = false) async {
        let today = Self.todayString()
        var accounts = wbCheckinAccounts()
        for i in 0..<accounts.count {
            var ac = accounts[i]
            let dateKey = "wb_checkin_date_\(ac.uid)"
            let streakKey = "wb_checkin_streak_\(ac.uid)"
            let rewardKey = "wb_checkin_reward_\(ac.uid)"
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 今天已签到且 streak/reward 均有值且 history 已有今天的记录 → 跳过
            // （history 缺记录时放行进下方流程查状态补写，补上后恢复零网络跳过）
            if UserDefaults.standard.string(forKey: dateKey) == today && prevStreak > 0 && prevReward > 0
               && checkinHistory(key: "wb_checkin_history_\(ac.uid)").contains(where: { $0.date == today }) { continue }

            // 错峰守卫：未到今日就绪时刻的账号本轮跳过（手动一键签到不受限）
            if !force,
               Date().timeIntervalSince1970 < Self.checkinReadyTimestamp(keyPrefix: "wb_checkin_ready", uid: ac.uid, today: today) {
                continue
            }

            // 签到前自动刷新 token（距过期 < 1 小时则用 refreshToken 续期）
            let refreshed = await WorkBuddyService.refreshTokenIfNeeded(account: ac)
            if refreshed != ac {
                if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                    config.workbuddyAccounts[idx] = refreshed
                    ConfigStore.save(config)
                }
                ac = refreshed
                accounts[i] = refreshed
            }

            // 查状态：已签则记录日期跳过；不可签也记录避免重复尝试
            if let st = await WorkBuddyService.fetchCheckinStatus(token: ac.token, uid: ac.uid, domain: ac.domain) {
                if st.todayCheckedIn || !st.available {
                    if st.todayCheckedIn {
                        // daily-checkin 接口在「已签到」时不返回 continuous_days，需基于上次签到日期推算
                        // 优先用 API continuousDays（权威值）；无值时用 nextStreak(prevDate, prevStreak) 推算
                        let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                        let newStreak: Int
                        if st.continuousDays > 0 {
                            newStreak = st.continuousDays
                        } else if !prevDate.isEmpty && prevDate != today {
                            newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak, today: today)
                        } else {
                            newStreak = max(prevStreak, 1)
                        }
                        UserDefaults.standard.set(newStreak, forKey: streakKey)
                        let newReward = prevReward == 0 ? st.reward : prevReward
                        if newReward > 0 {
                            UserDefaults.standard.set(newReward, forKey: rewardKey)
                        }
                        // 状态补全也追加历史记录（今天 history 无记录才补：streak/reward 是跨天
                        // 持久值，非零不能代表「今天已记录」；补记时刻用当前时间，服务端不返回真实时刻）
                        let hk = "wb_checkin_history_\(ac.uid)"
                        if !checkinHistory(key: hk).contains(where: { $0.date == today }) {
                            appendCheckinHistory(key: hk,
                                                 date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                        }
                        // 只有确认今天已签到才写 dateKey=today；
                        // !st.available（活动不可用/token 过期）不写，避免签到流程误判已签
                        UserDefaults.standard.set(today, forKey: dateKey)
                        // 已确认签到成功，清除历史失败残留标记（与 TRAE 侧对齐）
                        UserDefaults.standard.set(false, forKey: "wb_checkin_failed_\(ac.uid)")
                        UserDefaults.standard.removeObject(forKey: "wb_checkin_failed_date_\(ac.uid)")
                    }
                    syncPanel()
                    continue
                }
            }

            // 已签（dateKey==today）但状态补全未确认成功（如 status 查询失败）→
            // 不发起 claim，等待下轮补写历史，避免对已签账号误触发签到接口
            if UserDefaults.standard.string(forKey: dateKey) == today { continue }

            // 执行签到
            let r = await WorkBuddyService.claimCheckin(token: ac.token, uid: ac.uid, domain: ac.domain)
            if r.success {
                let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                let prevStreak2 = UserDefaults.standard.integer(forKey: streakKey)
                UserDefaults.standard.set(today, forKey: dateKey)
                let timeStr = Self.nowTimeString()
                UserDefaults.standard.set(timeStr, forKey: "wb_last_checkin_time")
                let newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak2, today: today)
                UserDefaults.standard.set(newStreak, forKey: streakKey)
                // 解析签到奖励积分（creditDesc 是 String 形式的积分数）
                let credit = Int(r.creditDesc) ?? 0
                if credit > 0 {
                    UserDefaults.standard.set(credit, forKey: rewardKey)
                }
                // 追加历史记录
                appendCheckinHistory(key: "wb_checkin_history_\(ac.uid)",
                                     date: today, time: timeStr, reward: credit, streak: newStreak)
                syncPanel()
                // 签到后刷新积分显示（仅当前登录号）
                if config.workbuddyEnabled, WorkBuddyService.authInfo()?.uid == ac.uid {
                    if let wb = await WorkBuddyService.fetchSummary() {
                        cacheWb = wb
                        updateTitle()
                    }
                }
                let content = UNMutableNotificationContent()
                content.title = "WorkBuddy 自动签到（\(ac.nickname)）"
                content.body = r.creditDesc.isEmpty ? "签到成功 ✓" : "签到成功 ✓ 积分：\(r.creditDesc)"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_auto_checkin_\(ac.uid)", content: content, trigger: nil)) { _ in }
                // 签到成功清除失败标记（含日期口径，用于卡片角标/统计）
                UserDefaults.standard.set(false, forKey: "wb_checkin_failed_\(ac.uid)")
                UserDefaults.standard.removeObject(forKey: "wb_checkin_failed_date_\(ac.uid)")
            } else {
                // 签到失败：记录失败标记 + 当日日期（用于卡片角标与「x成功 x失败」统计）
                UserDefaults.standard.set(true, forKey: "wb_checkin_failed_\(ac.uid)")
                UserDefaults.standard.set(today, forKey: "wb_checkin_failed_date_\(ac.uid)")
                syncPanel()
            }
        }
    }

    // MARK: - WorkBuddy 添加账号（OAuth 采集 / 当前账号 JSON 导入）

    @objc private func onAddWbAccount() {
        // OAuth 采集进行中 → 再点一次 = 取消采集
        guard !wbOauthInProgress else {
            wbOauthCancelled = true
            return
        }
        // 选择导入方式（同步模态，keepPanelAliveDuring 保持面板不关闭）
        let shell = DialogShell()
        shell.addIcon(makeWbBrandIcon())
        shell.addTitle("添加 WorkBuddy 账号")
        shell.contentWidth = DialogMetrics.inputWidth
        shell.addInfo("OAuth 导入：打开浏览器登录新账号，登录成功后自动采集凭据。\n\nJSON 导入：读取 WorkBuddy Desktop 当前登录账号（auth 文件），适合已在 Desktop 登录的账号。")
        let oauth = shell.addButton("OAuth 导入", keyEquivalent: "\r")
        let json = shell.addButton("JSON 导入")
        shell.addButton("取消", keyEquivalent: "\u{1b}")
        let clicked = keepPanelAliveDuring { shell.present() }
        if clicked == oauth {
            startWbOauth()
        } else if clicked == json {
            importWbFromAuthFile()
        }
    }

    /// 启动 OAuth 采集（浏览器登录 → 轮询 token → 写入 config）
    private func startWbOauth() {
        wbOauthInProgress = true
        wbOauthCancelled = false
        wbOauthMenuItem.title = "取消添加 WorkBuddy 账号…"
        syncPanel()
        Task { await runOauth() }
    }

    /// 从 WorkBuddy Desktop 当前登录账号导入：读取 auth 文件（workbuddy-desktop.info，JSON 格式），
    /// uid 去重后写入 config（已存在则更新凭据），随后拉取余额刷新卡片。
    private func importWbFromAuthFile() {
        guard let auth = WorkBuddyService.authInfo() else {
            let shell = DialogShell()
            shell.addTitle("导入失败")
            shell.addInfo("未读取到 WorkBuddy Desktop 的登录信息。\n请先在 WorkBuddy Desktop 中登录账号后重试。")
            shell.addButton("好的", keyEquivalent: "\r")
            _ = keepPanelAliveDuring { shell.present() }
            return
        }
        let account = WBAccount(token: auth.token, uid: auth.uid, domain: auth.domain,
                                nickname: auth.nickname, refreshToken: auth.refreshToken, expiresAt: auth.expiresAt)
        let existed = config.workbuddyAccounts.contains { $0.uid == account.uid }
        if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == account.uid }) {
            config.workbuddyAccounts[idx] = account
        } else {
            config.workbuddyAccounts.append(account)
        }
        ConfigStore.save(config)
        syncPanel()
        // 导入后立即拉取余额刷新卡片；自动签到开启时补一次签到（与 OAuth 导入对齐）
        Task { await refreshOneWorkBuddy(config) }
        if config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }
        let shell = DialogShell()
        shell.addTitle("导入成功")
        shell.addInfo(existed
            ? "已更新账号「\(account.nickname)」的凭据（共 \(config.workbuddyAccounts.count) 个账号）"
            : "已导入账号「\(account.nickname)」（共 \(config.workbuddyAccounts.count) 个账号）")
        shell.addButton("好的", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }
    }

    private func runOauth() async {
        // 启动时发引导通知
        let guide = UNMutableNotificationContent()
        guide.title = "请在浏览器中登录 WorkBuddy 账号"
        guide.body = "登录成功后自动采集，无需其他操作（10 分钟内有效）"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_oauth_guide", content: guide, trigger: nil)) { _ in }

        let result = await WorkBuddyService.collectAccount(isCancelled: { [weak self] in self?.wbOauthCancelled ?? true })

        var msg: String
        var success = false
        switch result {
        case .success(let account):
            if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == account.uid }) {
                config.workbuddyAccounts[idx] = account
            } else {
                config.workbuddyAccounts.append(account)
            }
            ConfigStore.save(config)
            msg = "已添加账号「\(account.nickname)」（共 \(config.workbuddyAccounts.count) 个其他账号）"
            success = true
        case .failure(let err):
            msg = err
        }
        wbOauthInProgress = false
        wbOauthMenuItem.title = "添加 WorkBuddy 账号…"
        syncPanel()

        let content = UNMutableNotificationContent()
        content.title = success ? "WorkBuddy 账号采集成功" : "WorkBuddy 账号采集失败"
        content.body = msg
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_oauth_result", content: content, trigger: nil)) { _ in }

        if success, config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }
    }

    // MARK: - 千问手动设置 Ticket + TCC 引导

    @objc private func onSetQianwenTicket() {
        guard let ticket = keepPanelAliveDuring({ promptForQianwenTicket(prefill: config.qianwenTicket) }) else { return }
        config.qianwenTicket = ticket
        ConfigStore.save(config)
        onRefresh()
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

    private func promptForQianwenTicket(prefill: String = "") -> String? {
        let dialog = InputDialog(
            title: "请输入千问 login_qianwenai_ticket",
            info: "点击「自动获取」可从 Edge 登录态读取，或手动填写。备用方式：F12 → Application → Cookies → 复制 .qianwenai.com 下 login_qianwenai_ticket：",
            linkText: "platform.qianwenai.com Token Plan 页面",
            linkURL: URL(string: "https://platform.qianwenai.com/home/billing/subscription/token-plan-individual")!,
            prefill: prefill,
            icon: makeQwenBrandIcon(),
            extraButton: ("自动获取", { iv in
                let (ticket, tccBlocked) = QianwenService.edgeTicket()
                if let ticket = ticket, !ticket.isEmpty {
                    iv.stringValue = ticket
                } else if tccBlocked {
                    let shell = DialogShell()
                    shell.addTitle("无法读取 Edge 登录态")
                    shell.addInfo("Edge 浏览器的 Cookie 文件受系统保护。\n\n请到 系统设置 → 隐私与安全 → 完全磁盘访问 中添加 iBalance，授权后重新点击「自动获取」。")
                    let settings = shell.addButton("打开系统设置", keyEquivalent: "\r")
                    shell.addButton("好的", keyEquivalent: "\u{1b}")
                    if shell.present() == settings, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    let shell = DialogShell()
                    shell.addTitle("未读取到千问登录态")
                    shell.addInfo("请确认已用 Edge 浏览器登录 platform.qianwenai.com，或手动填写 Ticket。")
                    shell.addButton("好的", keyEquivalent: "\r")
                    _ = shell.present()
                }
            }))
        return dialog.present()
    }

    // MARK: - 自动签到（TRAE + WorkBuddy 合并开关）

    @objc private func onToggleAutoCheckin() {
        let on = !(config.traeAutoCheckin || config.workbuddyAutoCheckin)
        config.traeAutoCheckin = on
        config.workbuddyAutoCheckin = on
        autoCheckinMenuItem.state = on ? .on : .off
        ConfigStore.save(config)
        if on {
            startCheckinTimer()
            Task { await traeAutoCheckinIfNeeded() }
            Task { await wbAutoCheckinIfNeeded() }
        } else {
            stopCheckinTimer()
        }
        syncPanel()
    }

    // MARK: - 手动签到（全部账号，链路与自动签到一致）

    /// 手动触发全部账号签到：复用 traeAutoCheckinIfNeeded / wbAutoCheckinIfNeeded
    /// （含每日守卫、token 刷新、退避），完成后弹窗汇总各账号签到情况。
    @objc private func onManualCheckin() {
        guard !manualCheckinInProgress else { return }
        manualCheckinInProgress = true

        let today = Self.todayString()
        // 签到前快照：区分「本次刚签到」vs「今日早已签到」
        var traeBefore: [String: String] = [:]
        for ac in traeCheckinAccounts() {
            traeBefore[ac.uid] = UserDefaults.standard.string(forKey: "trae_checkin_date_\(ac.uid)") ?? ""
        }
        var wbBefore: [String: String] = [:]
        for ac in wbCheckinAccounts() {
            wbBefore[ac.uid] = UserDefaults.standard.string(forKey: "wb_checkin_date_\(ac.uid)") ?? ""
        }

        Task {
            // 与自动签到完全一致的逻辑链路（每日守卫、token 刷新、退避均生效）；
            // force 绕过两平台错峰就绪时刻：手动一键签到立即全签
            async let traeTask = traeAutoCheckinIfNeeded(force: true)
            async let wbTask = wbAutoCheckinIfNeeded(force: true)
            _ = await (traeTask, wbTask)

            // ── 汇总各账号签到结果 ──
            var rows: [CheckinResultRow] = []
            var okCount = 0
            var failCount = 0

            for ac in traeCheckinAccounts() {
                let dateKey = UserDefaults.standard.string(forKey: "trae_checkin_date_\(ac.uid)") ?? ""
                let failed = UserDefaults.standard.string(forKey: "trae_checkin_failed_date_\(ac.uid)") == today
                let streak = UserDefaults.standard.integer(forKey: "trae_checkin_streak_\(ac.uid)")
                let reward = UserDefaults.standard.integer(forKey: "trae_checkin_reward_\(ac.uid)")
                if dateKey == today {
                    let tag = (traeBefore[ac.uid] ?? "") == today ? "今日已签到" : "签到成功"
                    var detail = ""
                    if streak > 0 { detail += " 连续\(streak)\u{2009}天" }
                    if reward > 0 { detail += " 积分+\(reward)" }
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：\(tag)\(detail)", state: .ok))
                    okCount += 1
                } else if failed {
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：签到失败", state: .fail))
                    failCount += 1
                } else {
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：未签到（token 失效或退避中）", state: .skipped))
                }
            }
            for ac in wbCheckinAccounts() {
                let dateKey = UserDefaults.standard.string(forKey: "wb_checkin_date_\(ac.uid)") ?? ""
                let failed = UserDefaults.standard.string(forKey: "wb_checkin_failed_date_\(ac.uid)") == today
                let streak = UserDefaults.standard.integer(forKey: "wb_checkin_streak_\(ac.uid)")
                let reward = UserDefaults.standard.integer(forKey: "wb_checkin_reward_\(ac.uid)")
                if dateKey == today {
                    let tag = (wbBefore[ac.uid] ?? "") == today ? "今日已签到" : "签到成功"
                    var detail = ""
                    if streak > 0 { detail += " 连续\(streak)\u{2009}天" }
                    if reward > 0 { detail += " 积分+\(reward)" }
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：\(tag)\(detail)", state: .ok))
                    okCount += 1
                } else if failed {
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：签到失败", state: .fail))
                    failCount += 1
                } else {
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：未签到（token 失效或活动不可用）", state: .skipped))
                }
            }

            manualCheckinInProgress = false

            // 结果弹窗（DialogShell 原生模板）；签到期间主面板已被关闭时不打扰
            // （数据已写入，下次打开卡片可见）
            guard popoverController?.isShown == true, !rows.isEmpty else { return }
            keepPanelAliveDuring { presentCheckinResult(okCount: okCount, failCount: failCount, rows: rows) }
        }
    }

    /// 手动签到结果弹窗：沿用 DialogShell 原生模板（图标/标题居中 + 富文本结果列表 + 系统按钮），
    /// 文字规格与输入类弹窗一致（12pt、与容器等宽）
    private func presentCheckinResult(okCount: Int, failCount: Int, rows: [CheckinResultRow]) {
        let shell = DialogShell()
        shell.addIcon(NSApp.applicationIconImage)
        shell.addTitle("手动签到完成")
        shell.contentWidth = DialogMetrics.inputWidth

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attr = NSMutableAttributedString()
        func append(_ s: String, color: NSColor) {
            attr.append(NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]))
        }
        append("成功\u{2009}\(okCount) · 失败\u{2009}\(failCount)\n\n",
               color: failCount > 0 ? .systemOrange : .secondaryLabelColor)
        for row in rows {
            let (symbol, color): (String, NSColor)
            switch row.state {
            case .ok: (symbol, color) = ("✓  ", .systemGreen)
            case .fail: (symbol, color) = ("✗  ", .systemOrange)
            case .skipped: (symbol, color) = ("–  ", .systemGray)
            }
            append(symbol, color: color)
            append(row.text + "\n", color: row.state == .fail ? .systemOrange : .secondaryLabelColor)
        }
        // 去掉末行多余的换行
        if attr.length > 0 { attr.deleteCharacters(in: NSRange(location: attr.length - 1, length: 1)) }
        shell.addInfo(attr)

        shell.addButton("完成", keyEquivalent: "\r")
        _ = shell.present()
    }

    // MARK: - 签到历史

    /// 查看签到历史：汇总 TRAE / WB 各账号的签到记录，按时间倒序展示最近 20 条
    @objc private func onShowCheckinHistory() {
        keepPanelAliveDuring { presentCheckinHistory() }
    }

    /// 签到历史弹窗：沿用 DialogShell 原生模板（图标/标题居中 + 富文本结果列表 + 系统按钮），
    /// 文字规格与输入类弹窗一致（12pt、与容器等宽）；长文阅读类，内容宽 +38
    /// （8 抵消 sidePadding 增量 + 30 加宽 info 列表）
    private func presentCheckinHistory() {
        // 记录的 date 为 yyyy-MM-dd、time 为 M-d HH:mm（appendCheckinHistory 写入口径）
        struct Row { let date: String; let time: String; let text: String }
        var rows: [Row] = []
        for ac in traeCheckinAccounts() {
            for r in checkinHistory(key: "trae_checkin_history_\(ac.uid)") {
                let reward = r.reward > 0 ? " 积分+\(r.reward)" : ""
                rows.append(Row(date: r.date, time: r.time,
                                text: "\(r.time) TRAE · \(ac.username)\(reward) 连续\(r.streak)天"))
            }
        }
        for ac in wbCheckinAccounts() {
            for r in checkinHistory(key: "wb_checkin_history_\(ac.uid)") {
                let reward = r.reward > 0 ? " 积分+\(r.reward)" : ""
                rows.append(Row(date: r.date, time: r.time,
                                text: "\(r.time) WorkBuddy · \(ac.nickname)\(reward) 连续\(r.streak)天"))
            }
        }
        // 仅显示最近两天（今天 + 昨天）；date 为 yyyy-MM-dd，字符串序即日期序
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Date()).map { df.string(from: $0) } ?? ""
        let sorted = rows
            .filter { $0.date >= cutoff }
            .sorted { $0.date == $1.date ? $0.time > $1.time : $0.date > $1.date }

        let shell = DialogShell()
        shell.addIcon(NSApp.applicationIconImage)
        shell.addTitle("签到历史")
        shell.contentWidth = DialogMetrics.inputWidth + 38
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attr = NSMutableAttributedString()
        func append(_ s: String, color: NSColor) {
            attr.append(NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]))
        }
        if sorted.isEmpty {
            append("最近两天暂无签到记录", color: .secondaryLabelColor)
        } else {
            append("最近两天共 \(sorted.count) 条\n\n", color: .secondaryLabelColor)
            for r in sorted {
                append(r.text + "\n", color: .secondaryLabelColor)
            }
            // 去掉末行多余的换行
            if attr.length > 0 { attr.deleteCharacters(in: NSRange(location: attr.length - 1, length: 1)) }
        }
        shell.addInfo(attr)
        shell.addButton("关闭", keyEquivalent: "\r")
        _ = shell.present()
    }

    /// 补全 TRAE 多账号签到 streak/reward：遍历所有账号，streak 或 reward 为 0 时查状态 API 填充。
    /// 每天最多跑一次（trae_status_fill_date 守卫），避免每次余额刷新都打 status API 触发风控。
    /// auto-checkin 已开启且主账号今日已签到时跳过（签到流程会顺带补全 streak/reward，去重）。
    private func traeCheckinStatusFill() async {
        let today = Self.todayString()
        // 每天最多补全一次，避免每次余额刷新都打 status API 触发风控
        let fillDateKey = "trae_status_fill_date"
        if UserDefaults.standard.string(forKey: fillDateKey) == today { return }
        let mainUid = TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? ""
        // auto-checkin 已开启且主账号今日已签到 → 签到流程会顺带补全 streak/reward，跳过
        if config.traeAutoCheckin && !mainUid.isEmpty
           && UserDefaults.standard.string(forKey: "trae_checkin_date_\(mainUid)") == today {
            UserDefaults.standard.set(today, forKey: fillDateKey)
            return
        }
        let accounts = traeCheckinAccounts()
        for ac in accounts {
            let dateKey = "trae_checkin_date_\(ac.uid)"
            let streakKey = "trae_checkin_streak_\(ac.uid)"
            let rewardKey = "trae_checkin_reward_\(ac.uid)"
            let timeKey = "trae_last_checkin_time_\(ac.uid)"
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 仅当今天已签到且 streak/reward 均有值时才跳过
            if prevStreak > 0 && prevReward > 0 && UserDefaults.standard.string(forKey: dateKey) == today { continue }
            // token：主账号从 storage.json；其他账号从 encryptedAuthInfo
            let token: String? = (ac.uid == mainUid)
                ? TraeService.getToken(storagePath: config.traeStoragePath)
                : TraeService.getTokenFromEncrypted(ac.encryptedAuthInfo)
            guard let tk = token, !tk.isEmpty else { continue }
            guard let st = await TraeService.fetchCheckinStatus(token: tk, storagePath: config.traeStoragePath) else { continue }
            if st.checkedIn {
                // 优先用 API continuousDays；无值时基于上次签到日期用 nextStreak 推算
                let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                let newStreak: Int
                if st.continuousDays > 0 {
                    newStreak = st.continuousDays
                } else if !prevDate.isEmpty && prevDate != today {
                    newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak, today: today)
                } else {
                    newStreak = max(prevStreak, 1)
                }
                UserDefaults.standard.set(newStreak, forKey: streakKey)
                let newReward = prevReward == 0 ? st.reward : prevReward
                if newReward > 0 {
                    UserDefaults.standard.set(newReward, forKey: rewardKey)
                }
                if !checkinHistory(key: "trae_checkin_history_\(ac.uid)").contains(where: { $0.date == today }) {
                    appendCheckinHistory(key: "trae_checkin_history_\(ac.uid)",
                                         date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                }
                UserDefaults.standard.set(today, forKey: dateKey)
            }
        }
        UserDefaults.standard.set(today, forKey: "trae_status_fill_date")
        syncPanel()
    }


    /// 多账号签到核心：遍历所有 TRAE 账号，每号本地日期守卫（每天最多一次），
    /// streak/reward 为 0 时即使今天已签也会查状态补全。每号独立退避，避免触发风控。
    /// 文件日志写入 /tmp/iBalance_trae_checkin.log 便于测试观察。
    /// force=true（手动一键签到）绕过错峰就绪时刻立即全签；退避机制始终生效（防风控保护）。
    private func traeAutoCheckinIfNeeded(force: Bool = false) async {
        let today = Self.todayString()
        let accounts = traeCheckinAccounts()
        let mainUid = TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? ""
        // 与 Logger.Channel.traeCheckin 同一落点（/tmp/iBalance_trae_checkin.log）
        func log(_ msg: String) { Logger.log(.traeCheckin, msg) }
        log("=== 开始多账号签到，共 \(accounts.count) 个账号（mainUid=\(mainUid)）===")
        for ac in accounts {
            let dateKey = "trae_checkin_date_\(ac.uid)"
            let streakKey = "trae_checkin_streak_\(ac.uid)"
            let rewardKey = "trae_checkin_reward_\(ac.uid)"
            let failedKey = "trae_checkin_failed_\(ac.uid)"
            let retryKey = "trae_next_retry_time_\(ac.uid)"
            let timeKey = "trae_last_checkin_time_\(ac.uid)"
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 今天已签到 → 跳过（强本地守卫，零网络）；history 还没有今天的记录时放行，
            // 走下方状态查证补写历史（补上后恢复零网络跳过）
            if UserDefaults.standard.string(forKey: dateKey) == today
               && checkinHistory(key: "trae_checkin_history_\(ac.uid)").contains(where: { $0.date == today }) {
                log("[\(ac.uid)] 今日已签到，跳过")
                continue
            }
            // 错峰守卫：未到今日就绪时刻的账号本轮跳过（手动一键签到不受限）
            if !force,
               Date().timeIntervalSince1970 < Self.checkinReadyTimestamp(keyPrefix: "trae_checkin_ready", uid: ac.uid, today: today) {
                continue
            }
            // token：主账号从 storage.json 解密；其他账号从 encryptedAuthInfo 解密
            let token: String? = (ac.uid == mainUid)
                ? TraeService.getToken(storagePath: config.traeStoragePath)
                : TraeService.getTokenFromEncrypted(ac.encryptedAuthInfo)
            guard let tk = token, !tk.isEmpty else {
                log("[\(ac.uid)] token 解密失败，跳过")
                continue
            }

            // status 退避：status 查询失败时短退避，避免反复打触发风控
            let statusRetryKey = "trae_status_retry_\(ac.uid)"
            if let rt = UserDefaults.standard.object(forKey: statusRetryKey) as? Date, Date() < rt {
                log("[\(ac.uid)] status 退避期内，跳过")
                continue
            }
            let stOpt = await TraeService.fetchCheckinStatus(token: tk, storagePath: config.traeStoragePath)
            guard let st = stOpt else {
                // status 查询失败（网络/风控）：递增退避 5min→10min→…→60min 封顶，
                // 防止 60s 轮询粒度下失败账号被反复重试（风控场景越打越糟）
                let failCountKey = "trae_status_fail_count_\(ac.uid)"
                let fails = UserDefaults.standard.integer(forKey: failCountKey) + 1
                UserDefaults.standard.set(fails, forKey: failCountKey)
                let backoff = min(TimeInterval(300) * pow(2, Double(fails - 1)), 3600)
                UserDefaults.standard.set(Date().addingTimeInterval(backoff), forKey: statusRetryKey)
                log("[\(ac.uid)] status 查询失败 x\(fails)，退避 \(Int(backoff))s")
                continue
            }
            UserDefaults.standard.set(0, forKey: "trae_status_fail_count_\(ac.uid)")
            log("[\(ac.uid)] 状态查询 enable=\(st.enable) checkedIn=\(st.checkedIn) continuousDays=\(st.continuousDays) reward=\(st.reward)")
            if !st.enable || st.checkedIn {
                if st.checkedIn {
                    let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                    let newStreak: Int
                    if st.continuousDays > 0 {
                        newStreak = st.continuousDays
                    } else if !prevDate.isEmpty && prevDate != today {
                        newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak, today: today)
                    } else {
                        newStreak = max(prevStreak, 1)
                    }
                    UserDefaults.standard.set(newStreak, forKey: streakKey)
                    let newReward = prevReward == 0 ? st.reward : prevReward
                    if newReward > 0 {
                        UserDefaults.standard.set(newReward, forKey: rewardKey)
                    }
                    if !checkinHistory(key: "trae_checkin_history_\(ac.uid)").contains(where: { $0.date == today }) {
                        appendCheckinHistory(key: "trae_checkin_history_\(ac.uid)",
                                             date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                    }
                    UserDefaults.standard.set(today, forKey: dateKey)
                    UserDefaults.standard.removeObject(forKey: retryKey)
                    UserDefaults.standard.set(false, forKey: failedKey)
                    UserDefaults.standard.removeObject(forKey: "trae_checkin_failed_date_\(ac.uid)")
                    log("[\(ac.uid)] 服务端已签到，补全 streak=\(newStreak) reward=\(newReward)")
                }
                syncPanel()
                continue
            }
            // 退避检查：在退避期内不调 claim，避免频繁请求触发服务端风控
            if let retryTime = UserDefaults.standard.object(forKey: retryKey) as? Date,
               Date() < retryTime {
                log("[\(ac.uid)] 退避期内，跳过（至 \(retryTime)）")
                continue
            }
            // 已签（dateKey==today）但状态补全未确认成功（如 status 查询失败）→
            // 不发起 claim，等待下轮补写历史，避免对已签账号误触发签到接口
            if UserDefaults.standard.string(forKey: dateKey) == today {
                log("[\(ac.uid)] 今日已签但历史待补全，跳过 claim")
                continue
            }
            log("[\(ac.uid)] 开始执行签到请求…")
            let (httpStatus, respJson) = await TraeService.claimCheckin(token: tk, storagePath: config.traeStoragePath)
            let bizCode = respJson?["code"] as? Int
            log("[\(ac.uid)] 签到响应 http=\(httpStatus) bizCode=\(bizCode ?? -1) body=\(respJson ?? [:])")
            if httpStatus == 200 && bizCode == 0 {
                let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                let prevStreak2 = UserDefaults.standard.integer(forKey: streakKey)
                UserDefaults.standard.set(today, forKey: dateKey)
                let timeStr = Self.nowTimeString()
                UserDefaults.standard.set(timeStr, forKey: timeKey)
                let newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak2, today: today)
                UserDefaults.standard.set(newStreak, forKey: streakKey)
                // 解析签到奖励积分（data.reward.credit / data.credit / data.credits 等）
                let data = respJson?["data"] as? [String: Any]
                let reward = (data?["reward"] as? [String: Any])?["credit"] as? Int
                    ?? data?["credit"] as? Int
                    ?? data?["credits"] as? Int
                    ?? data?["today_credit"] as? Int
                    ?? 0
                if reward > 0 {
                    UserDefaults.standard.set(reward, forKey: rewardKey)
                }
                appendCheckinHistory(key: "trae_checkin_history_\(ac.uid)",
                                     date: today, time: timeStr, reward: reward, streak: newStreak)
                updateAutoCheckinMenuTitle()
                UserDefaults.standard.set(false, forKey: failedKey)
                UserDefaults.standard.removeObject(forKey: retryKey)
                UserDefaults.standard.removeObject(forKey: "trae_checkin_failed_date_\(ac.uid)")
                log("[\(ac.uid)] 签到成功 streak=\(newStreak) reward=\(reward)")
                // 刷新该账号余额：主账号从 storage.json 查询；其他账号用 token 查询
                if ac.uid == mainUid {
                    if let credits = await TraeService.fetchCredits(storagePath: config.traeStoragePath) {
                        cacheTrae = credits
                        cacheTraeAccounts[ac.uid] = credits
                        updateTitle()
                    }
                } else if let r = await TraeService.fetchCreditsForToken(tk) {
                    cacheTraeAccounts[ac.uid] = r
                }
                // 签到成功通知（每号独立 identifier，避免互相覆盖）
                let content = UNMutableNotificationContent()
                content.title = "TRAE 自动签到"
                content.body = "账号 \(ac.username) 签到成功 ✓"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "trae_auto_checkin_\(ac.uid)", content: content, trigger: nil)) { _ in }
            } else {
                // 签到失败：记录失败标记 + 当日日期（用于卡片角标与「x成功 x失败」统计）
                UserDefaults.standard.set(true, forKey: failedKey)
                UserDefaults.standard.set(today, forKey: "trae_checkin_failed_date_\(ac.uid)")
                // 9074（操作太过频繁）是服务端对非客户端流量的传输层风控，重试无意义，当天不再尝试；
                // 其他失败退避 5 分钟
                let backoff: TimeInterval = (bizCode == 9074) ? Self.secondsUntilTomorrow() : 300
                UserDefaults.standard.set(Date().addingTimeInterval(backoff), forKey: retryKey)
                log("[\(ac.uid)] 签到失败，退避 \(backoff)s")
            }
            // 账号间间隔 3 秒，避免同设备短时间内连续请求签到触发服务端风控
            if ac.uid != accounts.last?.uid {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        log("=== 多账号签到结束 ===\n")
        syncPanel()
    }

    // MARK: - TRAE 多账号采集 / 切换

    /// 采集当前 storage.json 中的登录账号到 config（用户在 TRAE 内登录后触发）
    @objc private func onCollectTraeAccount() {
        guard !traeCollectInProgress else { return }
        traeCollectInProgress = true
        traeCollectMenuItem.title = "正在采集…"
        syncPanel()

        let result = TraeService.collectCurrentAccount(storagePath: config.traeStoragePath)
        var msg: String
        var success = false
        var isExisting = false
        switch result {
        case .success(let info):
            let account = TraeAccount(uid: info.uid, username: info.username, encryptedAuthInfo: info.encryptedAuthInfo)
            if let idx = config.traeAccounts.firstIndex(where: { $0.uid == account.uid }) {
                config.traeAccounts[idx] = account
                isExisting = true
            } else {
                config.traeAccounts.append(account)
            }
            ConfigStore.save(config)
            msg = isExisting
                ? "账号「\(info.username)」已存在，已更新其凭证"
                : "已添加账号「\(info.username)」（共 \(config.traeAccounts.count) 个 TRAE 账号）"
            success = true
        case .failure(let err):
            msg = err
        }
        traeCollectInProgress = false
        traeCollectMenuItem.title = "采集 TRAE 当前账号…"
        syncPanel()

        // 弹窗提示（成功/失败/已存在 三种状态）
        let shell = DialogShell()
        // 弹窗图标用 TRAE 品牌 logo（非 template，保持原色）
        if let url = Bundle.main.url(forResource: "trae", withExtension: "png"),
           let traeIcon = NSImage(contentsOf: url) {
            traeIcon.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            shell.addIcon(traeIcon)
        }
        shell.addTitle(success ? (isExisting ? "账号已存在" : "添加账号成功") : "添加账号失败")
        shell.addInfo(msg)
        shell.addButton("好", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }

        if success {
            Task { onRefresh() }
        }
    }

    // MARK: - ZCode 添加账号（JSON 导入）

    /// 从 ~/.zcode/v2/config.json 导入当前登录的 ZCode 账号（暂只支持此方式，无 OAuth）。
    /// 平台无昵称 API（OAuth token 加密不可读），导入后弹输入框让用户自定义昵称（可跳过）。
    @objc private func onAddZcodeAccount() {
        var msg: String
        var success = false
        var isExisting = false
        switch ZcodeService.importCurrentAccount() {
        case .success(let imported):
            var account = imported
            // 昵称：优先从 credentials.json 解密 user_info 自动带出（OAuth 登录资料），
            // 拿不到时弹输入框手填兜底（预填已有昵称）
            if account.nickname.isEmpty {
                if let nick = keepPanelAliveDuring({
                    promptForZcodeNickname(prefill: config.zcodeAccounts.first { $0.uid == account.uid }?.nickname ?? "")
                }) {
                    account.nickname = nick
                }
            }
            if let idx = config.zcodeAccounts.firstIndex(where: { $0.uid == account.uid }) {
                config.zcodeAccounts[idx] = account
                isExisting = true
            } else {
                config.zcodeAccounts.append(account)
            }
            ConfigStore.save(config)
            msg = isExisting
                ? "账号 \(account.displayName) 已存在，已更新其凭证"
                : "已添加账号 \(account.displayName)（共 \(config.zcodeAccounts.count) 个 ZCode 账号）"
            success = true
        case .failure(let err):
            msg = err
        }
        syncPanel()

        // 弹窗提示（成功/失败/已存在 三种状态）
        let shell = DialogShell()
        // 弹窗图标用 ZCode 品牌 logo（PNG，非 template，保持原色）
        if let url = Bundle.main.url(forResource: "zcode", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            shell.addIcon(icon)
        }
        shell.addTitle(success ? (isExisting ? "账号已存在" : "添加账号成功") : "添加账号失败")
        shell.addInfo(msg)
        shell.addButton("好", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }

        if success {
            Task { onRefresh() }
        }
    }

    /// ZCode 昵称输入框（平台无昵称 API，由用户自定义用于多账号区分）
    private func promptForZcodeNickname(prefill: String = "") -> String? {
        let icon: NSImage? = {
            guard let url = Bundle.main.url(forResource: "zcode", withExtension: "png"),
                  let img = NSImage(contentsOf: url) else { return nil }
            img.isTemplate = false
            img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            return img
        }()
        let dialog = InputDialog(title: "设置 ZCode 账号昵称",
                                 info: "为该账号设置昵称，用于多账号区分。留空则显示账号尾号。",
                                 linkText: "", linkURL: URL(string: "about:blank")!,
                                 prefill: prefill, icon: icon)
        return dialog.present()
    }

    /// 切换 TRAE 账号：后台执行杀进程 → 写 storage.json → 重启 TRAE。
    /// 不立即关闭面板：让用户看到「切换中」脉冲反馈，切换完成后再关闭。
    private func switchTraeAccount(uid: String) {
        guard let account = config.traeAccounts.first(where: { $0.uid == uid }) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            TraeService.switchAccount(account: TraeAccountInfo(
                uid: account.uid,
                username: account.username,
                avatarUrl: "",
                encryptedAuthInfo: account.encryptedAuthInfo,
                token: TraeService.getTokenFromEncrypted(account.encryptedAuthInfo) ?? ""
            ), storagePath: self.config.traeStoragePath)
            // 切换完成 → 回主线程触发 syncPanel（卡片重排），延迟 0.6s 后关闭面板
            DispatchQueue.main.async { [weak self] in
                self?.syncPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.popoverController?.close()
                }
            }
        }
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

    /// 切换 WorkBuddy 账号：杀进程 → 写 auth 文件 → 重启 WorkBuddy Desktop。
    /// 在后台线程执行（含 Thread.sleep），避免阻塞 UI。
    /// 不立即关闭面板：让用户看到「切换中」反馈 + 卡片重排动画，切换完成后再关闭。
    private func switchWbAccount(uid: String) {
        Logger.log(.switchAccount, "[iBalance] switchWbAccount called: uid=\(uid)")
        guard let account = config.workbuddyAccounts.first(where: { $0.uid == uid }) else {
            Logger.log(.switchAccount, "[iBalance] account not found for uid=\(uid)")
            return
        }
        Logger.log(.switchAccount, "[iBalance] found account: \(account.nickname)")
        // 直接用 config 中的 token 切换，WorkBuddy Desktop 启动后会自行刷新 token
        DispatchQueue.global(qos: .userInitiated).async {
            WorkBuddyService.switchAccount(account)
            // 切换完成 → 回主线程触发 syncPanel（更新卡片），延迟 0.6s 后关闭面板
            DispatchQueue.main.async { [weak self] in
                self?.syncPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.popoverController?.close()
                }
            }
        }
    }

    /// 切换 ZCode 账号：杀进程 → 写 credentials/config → 重启 ZCode。
    /// 在后台线程执行（含等待进程退出），切换完成后再关闭面板（同 WB 流程）。
    private func switchZcodeAccount(uid: String) {
        Logger.log(.switchAccount, "[iBalance] switchZcodeAccount called: uid=\(uid)")
        guard let account = config.zcodeAccounts.first(where: { $0.uid == uid }) else {
            Logger.log(.switchAccount, "[iBalance] zcode account not found for uid=\(uid)")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            ZcodeService.switchAccount(account)
            // 切换完成 → 回主线程触发 syncPanel（更新卡片），延迟 0.6s 后关闭面板
            DispatchQueue.main.async { [weak self] in
                self?.syncPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.popoverController?.close()
                }
            }
        }
    }

    // MARK: - 签到定时器

    private func startCheckinTimer() {
        stopCheckinTimer()
        guard config.traeAutoCheckin || config.workbuddyAutoCheckin else { return }
        // 60s 粒度轮询：为 WB 每账号随机就绪时刻（错峰窗口 10 分钟）提供判定精度；
        // 未到点/已签账号只做 UserDefaults 比较即跳过，不发网络请求
        checkinTimer = Timer.scheduledTimer(timeInterval: 60,
                                            target: self,
                                            selector: #selector(onCheckinTimerFired),
                                            userInfo: nil,
                                            repeats: true)
    }

    private func stopCheckinTimer() {
        checkinTimer?.invalidate()
        checkinTimer = nil
    }

    @objc private func onCheckinTimerFired() {
        // 60s 粒度轮询（两平台均按各自错峰就绪时刻判定）；未到点/已签账号零网络跳过，
        // 失败重试由各平台退避机制控制（TRAE status 递增退避 / claim 9074 当天熔断）
        if config.traeAutoCheckin { Task { await traeAutoCheckinIfNeeded() } }
        if config.workbuddyAutoCheckin { Task { await wbAutoCheckinIfNeeded() } }
    }

    /// 更新自动签到菜单标题，附上最近签到时间
    /// TRAE 多账号取所有账号中最晚的签到时间
    private func updateAutoCheckinMenuTitle() {
        var traeTime = ""
        for ac in traeCheckinAccounts() {
            if let t = UserDefaults.standard.string(forKey: "trae_last_checkin_time_\(ac.uid)"), !t.isEmpty {
                traeTime = Self.latestCheckinTime(trae: traeTime, wb: t) ?? t
            }
        }
        let wbTime = UserDefaults.standard.string(forKey: "wb_last_checkin_time") ?? ""
        var parts: [String] = []
        if !traeTime.isEmpty { parts.append("TRAE \(traeTime)") }
        if !wbTime.isEmpty { parts.append("WB \(wbTime)") }
        if parts.isEmpty {
            autoCheckinMenuItem.title = "自动签到"
        } else {
            autoCheckinMenuItem.title = "自动签到（\(parts.joined(separator: " · "))）"
        }
        syncPanel()
    }

    // MARK: - 工具

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    /// 自动签到错峰：返回账号「今日就绪时间戳」（秒）。keyPrefix 区分平台（wb_checkin_ready / trae_checkin_ready）。
    /// 当天首次遇到该账号时生成 now + 0~600s 随机偏移并持久化（UserDefaults 存 "日期|时间戳"），
    /// 同一天内恒定返回同一值、跨天自动重生成 → 多号在约 10 分钟窗口内随机错开签到，
    /// 避免同一轮询点批量请求触发服务端风控（仿 Cockpit Tools 的 per-account schedule）。
    private static func checkinReadyTimestamp(keyPrefix: String, uid: String, today: String) -> TimeInterval {
        let key = "\(keyPrefix)_\(uid)"
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

    private static func nowTimeString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M-d HH:mm"
        return fmt.string(from: Date())
    }

    /// 距明天 0 点的秒数（9074 风控拦截后当天不再重试 claim）
    private static func secondsUntilTomorrow() -> TimeInterval {
        Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(86400)
            .timeIntervalSinceNow
    }

    /// 取 TRAE / WB 两个签到时间（M-d HH:mm）中较晚的那个；都为空返回 nil。
    /// 同年场景下按月日时分比较；跨年因格式不含年份仅作近似比较。
    private static func latestCheckinTime(trae: String, wb: String) -> String? {
        let df = DateFormatter()
        df.dateFormat = "M-d HH:mm"
        // 用当前年份兜底，使 date(from:) 能解析出可比较的 Date
        var comps = Calendar.current.dateComponents([.year], from: Date())
        df.defaultDate = Calendar.current.date(from: comps)
        var latest: Date?
        var latestStr: String?
        for str in [trae, wb] where !str.isEmpty {
            guard let d = df.date(from: str) else { continue }
            if latest == nil || d > latest! {
                latest = d
                latestStr = str
            }
        }
        return latestStr
    }

    /// 计算签到连续天数：上次签到是昨天 → streak+1；今天已签 → 保持；否则重置为 1
    private static func nextStreak(prevDate: String, prevStreak: Int, today: String) -> Int {
        guard !prevDate.isEmpty else { return 1 }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let p = df.date(from: prevDate), let t = df.date(from: today) else { return 1 }
        let diff = Calendar.current.dateComponents([.day], from: p, to: t).day ?? 0
        if diff == 1 { return prevStreak + 1 }
        if diff == 0 { return max(prevStreak, 1) }
        return 1
    }

    // MARK: - 签到历史记录

    /// 签到历史记录条目
    struct CheckinRecord: Codable {
        let date: String       // yyyy-MM-dd
        let time: String       // HH:mm:ss
        let reward: Int        // 签到奖励积分
        let streak: Int        // 当时的连续天数
    }

    /// 追加一条签到记录（同一天同 uid 仅保留最后一次）
    private func appendCheckinHistory(key: String, date: String, time: String, reward: Int, streak: Int) {
        var list = checkinHistory(key: key)
        list.removeAll { $0.date == date }
        list.append(CheckinRecord(date: date, time: time, reward: reward, streak: streak))
        // 仅保留最近 90 天
        if list.count > 90 { list.removeFirst(list.count - 90) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 读取签到历史
    private func checkinHistory(key: String) -> [CheckinRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CheckinRecord].self, from: data) else { return [] }
        return list
    }

    private func notifyError(_ msg: String) {
        let content = UNMutableNotificationContent()
        content.title = "DeepSeek 余额查询"
        content.body = msg
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ds_balance_error", content: content, trigger: nil)) { _ in }
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

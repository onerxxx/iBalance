// Dialogs.swift — iBalance
// 弹窗统一封装:DialogShell 布局系统 + 各业务弹窗(InputDialog / DeepSeek 设置 / 平台自动化)
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 布局常量    DialogMetrics（内容宽 240 / 输入类 280 / 边距 8 / 图标 66，集中处）
// NSAlert 壳  DialogShell（原生 NSAlert 薄封装；轻量确认/输入类弹窗走它，别另起 NSAlert）
// 玻璃模态壳  GlassModalShell（另一个文件：整窗 Liquid Glass 模态窗口，App 图标 header +
//            内容块 + 保存/取消；更新窗口同配方。DeepSeek 设置 / 平台开关走它）
// 业务弹窗    InputDialog / DeepSeekSettingsDialog / PlatformAutomationSettingsDialog
//
// ⚠️ 两个壳怎么选：要「和更新窗口 / 平台开关一样的玻璃浮窗」= GlassModalShell；
//    只要一个系统小弹窗（如单行输入）= DialogShell。
// ⚠️ DialogShell 三件套（血泪坑，详见 AGENT.md 陷阱 #6）：
//    1) 标题/说明走 messageText + informativeText（系统排版），别自己堆 label；
//    2) 需要自定义排版的内容放 accessoryView；
//    3) 按钮用 addButton（第一个添加的在右侧 = 主操作、回车触发），取消按钮绑 Esc。

import Cocoa
import UserNotifications

// MARK: - 弹窗统一封装（原生 NSAlert 设定）
//
// v44 重写：回归原生 NSAlert 布局——标题/说明用 messageText / informativeText（系统排版，
// 系统字号、换行与间距），按钮用 alert.addButton（系统按钮行：第一个添加的在右侧，
// 即默认主操作，回车触发；后续按钮往左排，取消按钮绑 Esc）。
// 需要自定义排版的内容放 accessoryView：输入控件、含可点链接的富文本说明。
// 标题和图标统一使用 NSAlert 原生标题区，保持各弹窗结构一致。

enum DialogMetrics {
    /// accessoryView 默认内容宽（NSAlert 按此宽度自适应窗口；窗口宽 ≈ 此值 + 系统边距 16×2）
    static let width: CGFloat = 240
    /// 输入类弹窗（配置Key）内容宽：说明文字较长，在默认宽基础上加宽一档
    static let inputWidth: CGFloat = 280
    /// accessory 内控件区左右边距（说明/控件距窗口边缘 = 系统 16pt + 此值）
    static let sidePadding: CGFloat = 8
    /// accessory 内富文本说明与控件区间距
    static let vSpacing: CGFloat = 8
    /// 弹窗图标统一 66pt（2026-09-08 用户拍板，全弹窗唯一出处）
    static let iconSize: CGFloat = 66
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
    func addButton(_ title: String, keyEquivalent: String = "", tintColor: NSColor? = nil) -> Int {
        let btn = alert.addButton(withTitle: title)
        if !keyEquivalent.isEmpty {
            btn.keyEquivalent = keyEquivalent
        }
        if tintColor != nil {
            // macOS 26 的 NSAlert rounded 次按钮使用 tintProminence 控制主次层级；
            // contentTintColor 仅适用于无边框按钮，bezelColor 在该 appearance 下会被忽略。
            btn.tintProminence = .primary
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
        // ⚠️ 强制窗口先行上屏再进模态循环：自更新等后台 Task 冷启动场景下，
        // activate 尚未完成时直接 runModal 存在竞态——模态窗口从未被 WindowServer
        // 登记显示（CGWindowList 里不存在），主线程却吊死在 modal loop 等输入，
        // 表现为「弹窗闪没/无任何界面可点、进程假死」。访问 alert.window 会强制
        // 实例化 NSAlert 的私有 panel，orderFrontRegardless 不依赖 app active 态。
        let modalWindow = alert.window
        // NSAlert 是自建顶层窗口、不在面板视图树上：外观按全局镜像显式设，
        // 否则应用内浅色主题（系统深色）时弹窗仍是系统深色
        modalWindow.appearance = Palette.topLevelWindowAppearance
        modalWindow.orderFrontRegardless()
        let resp = alert.runModal()
        return resp.rawValue >= 1000 ? resp.rawValue - 1000 : -1
    }
}

/// WorkBuddy 品牌图标（PNG，保持原色非 template），用于添加账号选择弹窗
func makeWbBrandIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "workbuddy", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
    return img
}

/// App 图标快照（App-Icon-Default-1024@1x.png，ictool 按 design-generation 27 导出的
/// Default rendition，随 icons/*.png 打包）。操作磁贴类弹窗（手动签到/签到历史/检查更新/关于）
/// 统一用它，不走 NSApp.applicationIconImage（后者受系统图标缓存影响）
func makeAppIconSnapshot() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "App-Icon-Default-1024@1x", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
    return img
}

/// 弹窗统一输入框（Key / 额度 弹窗四行共用）：**只用系统 bezel，不自定义外观**。
///
/// - 形状与内缩都交给 `bezelStyle = .roundedBezel`：系统画圆角 + 边框，并自带内缩
///   （实测文字左起 = field 左缘 **+7pt**；关掉 bezel 只有 3pt、贴边）——
///   不需要手写 padding，也不需要 layer 圆角 / masksToBounds。
/// - 黑底：`NSTextField` 出厂就是 `drawsBackground = true` + `backgroundColor =
///   .textBackgroundColor`（系统语义色），深色外观下实测渲染为近黑 0.09，
///   一个颜色字段都不用写。
/// - 单行：只需 `cell.wraps = false`。实测默认 `wraps = true` 会折行（长文本折成 2 行），
///   而 `usesSingleLineMode` / `maximumNumberOfLines` / `lineBreakMode` 对是否折行毫无影响，
///   故不再设；`cell.isScrollable = true` 保留，否则长 token 尾部滚不到。
final class DarkInputField: NSTextField {
    /// 统一口径：高 22 = macOS regular 尺寸控件的标准高（`cell.cellSize` 建议 23，
    /// 系统偏好设置里的标准输入框就是 22）。探针实测：字 12 时 18 以上文字完整
    /// （墨迹像素恒 209），16 起开始压字（207）—— 22 是下限之上的安全值。
    static let defaultHeight: CGFloat = 22

    init(value: String = "", placeholder: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Self.defaultHeight))
        stringValue = value
        placeholderString = placeholder
        bezelStyle = .roundedBezel
        font = .systemFont(ofSize: 12)
        cell?.wraps = false
        cell?.isScrollable = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// DeepSeek 设置弹窗（面板「Key / 额度」磁贴入口）：配置 DeepSeek API Key / 日常充值额度
/// + ZhiPu Token / Qwen Ticket 覆盖。窗口走 `GlassModalShell`（与更新窗口、平台开关弹窗同款
/// 玻璃模态浮窗），内容为四行「label 在上、控件在下」表单；回车 = 保存、Esc = 取消。
@MainActor
final class DeepSeekSettingsDialog: NSObject {
    private let apiKeyField: DarkInputField
    private let popup = NSPopUpButton()
    private let customField: DarkInputField
    private let zhipuTokenField: DarkInputField
    private let qwenTicketField: DarkInputField
    private let presets: [(label: String, value: Double)] = [
        ("未设置", 0),
        ("¥10", 10),
        ("¥20", 20),
        ("¥50", 50),
        ("¥100", 100),
    ]

    /// - Parameters:
    ///   - apiKey: 当前 DeepSeek API Key
    ///   - quota: 当前已设置的日常充值额度（0 = 未设置）
    ///   - zhipuToken: 当前 ZhiPu Token 覆盖（空 = 自动从浏览器登录态读取）
    ///   - qwenTicket: 当前 Qwen Ticket 覆盖（空 = 自动从浏览器登录态读取）
    init(apiKey: String, quota: Double, zhipuToken: String = "", qwenTicket: String = "") {
        // 四个输入框一套口径（DarkInputField：系统默认外观 + 单行），不再各写一遍控件样式
        apiKeyField = DarkInputField(value: apiKey)
        zhipuTokenField = DarkInputField(value: zhipuToken)
        qwenTicketField = DarkInputField(value: qwenTicket)
        customField = DarkInputField(placeholder: "自定义额度")
        super.init()

        for opt in presets { popup.addItem(withTitle: opt.label) }
        popup.menu?.addItem(withTitle: "自定义", action: nil, keyEquivalent: "")

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

    func present() -> (apiKey: String?, quota: Double, zhipuToken: String?, qwenTicket: String?)? {
        // 窗口配方与平台开关弹窗 / 更新窗口同源（GlassModalShell：整窗玻璃 + 无红绿灯 +
        // 系统 16pt 连续曲率圆角 + 同步模态）；宽度也吃壳的默认值，三个玻璃弹窗等宽
        let shell = GlassModalShell()
        shell.setWindowTitle("iBalance DeepSeek / ZhiPu / Qwen 设置")
        let infoAttr = NSMutableAttributedString(
            string: "配置 API Key 和日常充值额度。获取 API Key：",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.secondaryLabelColor])
        infoAttr.append(NSAttributedString(
            string: "platform.deepseek.com/api_keys",
            attributes: [.link: URL(string: "https://platform.deepseek.com/api_keys")!,
                         .foregroundColor: NSColor.linkColor,
                         .underlineStyle: NSUnderlineStyle.single.rawValue,
                         .font: NSFont.systemFont(ofSize: 12)]))
        shell.addHeader(title: "DeepSeek / ZhiPu / Qwen 设置", info: infoAttr)

        // 四行设置共用一个内容容器：文本在上、控件在下，统一左对齐。
        let rowWidth = shell.contentWidth
        let labelHeight: CGFloat = 18
        // 控件行高 = 输入框统一高（下拉也吃这个值，保证同行等高）
        let controlHeight: CGFloat = DarkInputField.defaultHeight
        let labelControlGap: CGFloat = 4
        let rowHeight = labelHeight + labelControlGap + controlHeight
        let rowGap: CGFloat = 10
        let content = NSView(frame: NSRect(x: 0, y: 0,
                                           width: rowWidth,
                                           height: rowHeight * 4 + rowGap * 3))
        // 每行结构同构（label 在上偏 +32，控件在下），自底向上逐行叠放：
        // Qwen Ticket（底）→ ZhiPu Token → 日常额度 → API Key（顶）
        let keyLabel = NSTextField(labelWithString: "API Key")
        keyLabel.font = NSFont.systemFont(ofSize: 12)
        keyLabel.textColor = NSColor.labelColor
        keyLabel.alignment = .left
        keyLabel.frame = NSRect(x: 0, y: rowHeight * 3 + rowGap * 3 + controlHeight + labelControlGap,
                                width: rowWidth, height: labelHeight)
        apiKeyField.frame = NSRect(x: 0, y: rowHeight * 3 + rowGap * 3,
                                   width: rowWidth, height: controlHeight)
        content.addSubview(keyLabel)
        content.addSubview(apiKeyField)

        let quotaLabel = NSTextField(labelWithString: "日常额度")
        quotaLabel.font = NSFont.systemFont(ofSize: 12)
        quotaLabel.textColor = NSColor.labelColor
        quotaLabel.alignment = .left
        quotaLabel.frame = NSRect(x: 0, y: rowHeight * 2 + rowGap * 2 + controlHeight + labelControlGap,
                                  width: rowWidth, height: labelHeight)
        let popupWidth: CGFloat = 110
        popup.frame = NSRect(x: 0, y: rowHeight * 2 + rowGap * 2, width: popupWidth, height: controlHeight)
        // 与同行下拉等高同基线（旧版这里是 24 高 + 下移 2 的例外，已统一）
        customField.frame = NSRect(x: popupWidth + 8, y: rowHeight * 2 + rowGap * 2,
                                   width: rowWidth - popupWidth - 8, height: controlHeight)
        content.addSubview(quotaLabel)
        content.addSubview(popup)
        content.addSubview(customField)

        let zpLabel = NSTextField(labelWithString: "ZhiPu Token（空 = 自动读取浏览器登录态）")
        zpLabel.font = NSFont.systemFont(ofSize: 12)
        zpLabel.textColor = NSColor.labelColor
        zpLabel.alignment = .left
        zpLabel.frame = NSRect(x: 0, y: rowHeight + rowGap + controlHeight + labelControlGap,
                               width: rowWidth, height: labelHeight)
        zhipuTokenField.frame = NSRect(x: 0, y: rowHeight + rowGap,
                                       width: rowWidth, height: controlHeight)
        content.addSubview(zpLabel)
        content.addSubview(zhipuTokenField)

        let qwLabel = NSTextField(labelWithString: "Qwen Ticket（空 = 自动读取浏览器登录态）")
        qwLabel.font = NSFont.systemFont(ofSize: 12)
        qwLabel.textColor = NSColor.labelColor
        qwLabel.alignment = .left
        qwLabel.frame = NSRect(x: 0, y: controlHeight + labelControlGap,
                               width: rowWidth, height: labelHeight)
        qwenTicketField.frame = NSRect(x: 0, y: 0,
                                       width: rowWidth, height: controlHeight)
        content.addSubview(qwLabel)
        content.addSubview(qwenTicketField)
        shell.addContent(content, height: content.frame.height)
        // 初始焦点落在内部真实输入控件上（容器本身不是响应者）
        shell.firstResponder = apiKeyField

        // 按钮：第一个添加的在最右 = 主操作（保存，回车）；取消绑 Esc
        let save = shell.addButton("保存", keyEquivalent: "\r", primary: true)
        shell.addButton("取消", keyEquivalent: "\u{1b}")
        guard shell.present() == save else { return nil }

        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let zpRaw = zhipuTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let qwRaw = qwenTicketField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customVal = Double(customField.stringValue.trimmingCharacters(in: .whitespaces)), customVal > 0 {
            return (apiKey.isEmpty ? nil : apiKey, customVal, zpRaw.isEmpty ? nil : zpRaw, qwRaw.isEmpty ? nil : qwRaw)
        }
        let idx = popup.indexOfSelectedItem
        let quota = idx < presets.count ? presets[idx].value : 0
        return (apiKey.isEmpty ? nil : apiKey, quota, zpRaw.isEmpty ? nil : zpRaw, qwRaw.isEmpty ? nil : qwRaw)
    }
}

/// 弹窗内小号 checkbox：空标题、居中，辅助功能名用于旁白等读屏
private func makeCheckbox(label: String, isOn: Bool) -> NSButton {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    checkbox.controlSize = .small
    checkbox.alignment = .center
    checkbox.state = isOn ? .on : .off
    checkbox.setAccessibilityLabel(label)
    return checkbox
}

/// 各平台刷新 / 自动签到 / 卡片显示开关弹窗：窗口配方走 `GlassModalShell`
/// （titled + fullSizeContentView + NSGlassEffectView 整窗一块玻璃；窗口层参数、系统
/// 16pt 连续曲率圆角与模态收口都在壳里，详见 docs/glass-modal-window-guide.md）。
/// 内容为 NSGridView 开关表；回车 = 保存、Esc = 取消。
@MainActor
final class PlatformAutomationSettingsDialog: NSObject {
    private struct Row {
        let name: String
        let platformID: String
        /// 平台名列前置图标：bundle SVG 资源名（与面板品牌卡同图，ZCode 用 "zhipu"）
        let icon: String
        let refresh: NSButton
        let checkin: NSButton?
        let card: NSButton
        let usage: NSButton?    // nil = 该平台无用量行，「用量」列显「—」占位
    }

    /// 行首「全选」控制器：勾选全开该行所有开关、取消全关；
    /// 行内任一开关变化时反向同步——全开=勾选、全关=空白、部分开启=混合态「−」。
    private final class RowAllHandler: NSObject {
        private let all: NSButton
        private let options: [NSButton]

        init(all: NSButton, options: [NSButton]) {
            self.all = all
            self.options = options
            super.init()
            all.allowsMixedState = true
            all.state = Self.syncedState(of: options)
            all.target = self
            all.action = #selector(toggleAll(_:))
            for option in options {
                option.target = self
                option.action = #selector(syncAllState(_:))
            }
        }

        /// 全选框应显示的状态：全开=勾选、全关=空白、部分=「−」
        private static func syncedState(of options: [NSButton]) -> NSControl.StateValue {
            if options.allSatisfy({ $0.state == .on }) { return .on }
            return options.contains { $0.state == .on } ? .mixed : .off
        }

        @objc private func toggleAll(_ sender: NSButton) {
            // 点击后 sender.state 已按系统循环 off→mixed→on→off 跳变（实测）：
            // mixed 只会从「全关」点出，按主流惯例（混合态点击=全选）与 .on 一样导向全开
            let state: NSControl.StateValue = sender.state == .off ? .off : .on
            for option in options { option.state = state }
            sender.state = state    // 归一「−」中间值：选项全开时全选框不能停在混合态
        }

        @objc private func syncAllState(_ sender: NSButton) {
            all.state = Self.syncedState(of: options)
        }
    }

    /// 平台名列前置品牌图标：bundle SVG 裁边模板图（与面板品牌卡同名资源），
    /// 固定 12×12 显示框 + 按比例填满，各 SVG 墨迹视觉大小统一（2026-09-10 用户指定）
    ///
    /// contentTintColor 必须显式设成 labelColor：模板图在 NSImageView 里的默认着色是
    /// **secondaryLabelColor**（实测 α=0.549），比同一行的平台名 label（.labelColor，
    /// α=0.847）淡一档，看起来像两个色号；显式指定后两者同色。
    private static func brandIconView(_ resource: String) -> NSImageView {
        let iv = NSImageView()
        iv.image = BalancePanelView.trimmedBundleSvgIcon(resource, size: 12)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.contentTintColor = .labelColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 12).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return iv
    }

    private let rows: [Row]
    private let initialConfig: AppConfig
    /// 行首「全选」checkbox 的控制器；action 目标需存活至弹窗关闭，由本类持有
    private var rowAllHandlers: [RowAllHandler] = []

    init(config: AppConfig) {
        initialConfig = config
        rows = [
            Row(name: "DeepSeek", platformID: "ds",
                icon: "deepseek",
                refresh: makeCheckbox(label: "DeepSeek 刷新", isOn: config.deepseekRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "DeepSeek 卡片显示",
                                   isOn: config.panelCardVisible["ds"] ?? true),
                usage: makeCheckbox(label: "DeepSeek 用量显示",
                                    isOn: config.panelUsageVisible["ds"] ?? true)),
            Row(name: "ZhiPu", platformID: "zhipu",
                icon: "zhipu",
                refresh: makeCheckbox(label: "ZhiPu 刷新", isOn: config.bigmodelRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "ZhiPu 卡片显示",
                                   isOn: config.panelCardVisible["zhipu"] ?? true),
                usage: makeCheckbox(label: "ZhiPu 用量显示",
                                    isOn: config.panelUsageVisible["zhipu"] ?? true)),
            Row(name: "Qwen", platformID: "qwen",
                icon: "qwen",
                refresh: makeCheckbox(label: "Qwen 刷新", isOn: config.qwenRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "Qwen 卡片显示",
                                   isOn: config.panelCardVisible["qwen"] ?? true),
                usage: makeCheckbox(label: "Qwen 用量显示",
                                    isOn: config.panelUsageVisible["qwen"] ?? true)),
            Row(name: "WorkBuddy", platformID: "wb",
                icon: "workbuddy",
                refresh: makeCheckbox(label: "WorkBuddy 刷新", isOn: config.workbuddyEnabled),
                checkin: makeCheckbox(label: "WorkBuddy 自动签到", isOn: config.workbuddyAutoCheckin),
                card: makeCheckbox(label: "WorkBuddy 卡片显示",
                                   isOn: config.panelCardVisible["wb"] ?? true),
                usage: makeCheckbox(label: "WorkBuddy 用量显示",
                                    isOn: config.panelUsageVisible["wb"] ?? true)),
            Row(name: "TRAE", platformID: "trae",
                icon: "trae-color",
                refresh: makeCheckbox(label: "TRAE 刷新", isOn: config.traeRefreshEnabled),
                checkin: makeCheckbox(label: "TRAE 自动签到", isOn: config.traeAutoCheckin),
                card: makeCheckbox(label: "TRAE 卡片显示",
                                   isOn: config.panelCardVisible["trae"] ?? true),
                usage: makeCheckbox(label: "TRAE 用量显示",
                                    isOn: config.panelUsageVisible["trae"] ?? true)),
            Row(name: "ZCode", platformID: "zcode",
                icon: "zhipu",
                refresh: makeCheckbox(label: "ZCode 刷新", isOn: config.zcodeRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "ZCode 卡片显示",
                                   isOn: config.panelCardVisible["zcode"] ?? true),
                usage: makeCheckbox(label: "ZCode 用量显示",
                                    isOn: config.panelUsageVisible["zcode"] ?? true)),
            Row(name: "Codex", platformID: "codex",
                icon: "codex",
                refresh: makeCheckbox(label: "Codex 刷新", isOn: config.codexRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "Codex 卡片显示",
                                   isOn: config.panelCardVisible["codex"] ?? true),
                usage: makeCheckbox(label: "Codex 用量显示",
                                    isOn: config.panelUsageVisible["codex"] ?? true)),
        ]
        super.init()
    }

    /// 同步模态运行：保存回车 / 取消 Esc 结束模态；仅保存返回新配置。
    func present() -> AppConfig? {
        let shell = GlassModalShell()
        shell.setWindowTitle("iBalance 平台开关")
        shell.addHeader(title: "平台开关",
                        info: NSAttributedString(
                            string: "选择各平台是否参与刷新、自动签到（支持签到的平台）、在面板显示余额卡片，以及是否显示该平台的用量行。",
                            attributes: [.font: NSFont.systemFont(ofSize: 11),
                                         .foregroundColor: NSColor.secondaryLabelColor]))

        // ── 开关表格（NSGridView 列轨道对齐，口径同旧版）──
        let headerAll = NSTextField(labelWithString: "")
        let headerName = NSTextField(labelWithString: "平台")
        let headerRefresh = NSTextField(labelWithString: "刷新")
        let headerCheckin = NSTextField(labelWithString: "签到")
        let headerCard = NSTextField(labelWithString: "卡片")
        let headerUsage = NSTextField(labelWithString: "用量")
        for label in [headerAll, headerName, headerRefresh, headerCheckin, headerCard, headerUsage] {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        headerAll.alignment = .center
        headerRefresh.alignment = .center
        headerCheckin.alignment = .center
        headerCard.alignment = .center
        headerUsage.alignment = .center

        /// 「—」占位（该平台无此项能力）
        func unavailablePlaceholder(_ label: String) -> NSView {
            let unavailable = NSTextField(labelWithString: "—")
            unavailable.alignment = .center
            unavailable.font = .systemFont(ofSize: 12)
            unavailable.textColor = .tertiaryLabelColor
            unavailable.setAccessibilityLabel(label)
            return unavailable
        }
        var gridRows: [[NSView]] = [[headerAll, headerName, headerRefresh, headerCheckin, headerCard, headerUsage]]
        for row in rows {
            let name = NSTextField(labelWithString: row.name)
            name.font = .systemFont(ofSize: 12)
            name.textColor = .labelColor   // 图标 tint 同此色号（见 brandIconView）
            // 平台名列：前置 bundle SVG 品牌图标（裁边模板图，12pt 显示框），
            // 与面板品牌卡同图；取不到资源（表外平台）则只留文字
            let nameCell = NSStackView(views: [Self.brandIconView(row.icon), name])
            nameCell.orientation = .horizontal
            nameCell.alignment = .centerY
            nameCell.spacing = 5
            let rowAll = makeCheckbox(label: "\(row.name) 全选", isOn: false)
            rowAllHandlers.append(RowAllHandler(all: rowAll,
                                                options: [row.refresh, row.checkin, row.card, row.usage].compactMap { $0 }))
            let checkinView = row.checkin ?? unavailablePlaceholder("该平台不支持签到")
            let usageView = row.usage ?? unavailablePlaceholder("该平台不支持用量显示")
            gridRows.append([rowAll, nameCell, row.refresh, checkinView, row.card, usageView])
        }
        let grid = NSGridView(views: gridRows)
        let headerHeight: CGFloat = 22
        let rowHeight: CGFloat = 27
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).width = 26
        grid.column(at: 0).xPlacement = .center
        // 平台列吃掉余量：26 + 130 + 54×4 + 间距 4×5 = 392 = 壳内容宽（旧 240 宽壳为 116）
        grid.column(at: 1).width = 130
        grid.column(at: 1).xPlacement = .leading
        for col in 2...5 {
            grid.column(at: col).width = 54
            grid.column(at: col).xPlacement = .center
        }
        grid.row(at: 0).height = headerHeight
        for index in 1...rows.count {
            grid.row(at: index).height = rowHeight
        }
        let gridH = headerHeight + CGFloat(rows.count) * rowHeight
            + CGFloat(rows.count) * 4
        shell.addContent(grid, height: gridH)

        // 按钮：第一个添加的在最右 = 主操作（保存，回车）；取消绑 Esc
        let save = shell.addButton("保存", keyEquivalent: "\r", primary: true)
        shell.addButton("取消", keyEquivalent: "\u{1b}")
        guard shell.present() == save else { return nil }

        var updatedConfig = initialConfig
        updatedConfig.deepseekRefreshEnabled = rows[0].refresh.state == .on
        updatedConfig.bigmodelRefreshEnabled = rows[1].refresh.state == .on
        updatedConfig.qwenRefreshEnabled = rows[2].refresh.state == .on
        updatedConfig.workbuddyEnabled = rows[3].refresh.state == .on
        updatedConfig.workbuddyAutoCheckin = rows[3].checkin?.state == .on
        updatedConfig.traeRefreshEnabled = rows[4].refresh.state == .on
        updatedConfig.traeAutoCheckin = rows[4].checkin?.state == .on
        updatedConfig.zcodeRefreshEnabled = rows[5].refresh.state == .on
        updatedConfig.codexRefreshEnabled = rows[6].refresh.state == .on
        for row in rows {
            updatedConfig.panelCardVisible[row.platformID] = (row.card.state == .on)
            if let usage = row.usage {
                updatedConfig.panelUsageVisible[row.platformID] = (usage.state == .on)
            }
        }
        return updatedConfig
    }
}

/// 通用输入弹窗控制器（API Key 等单行文本输入）。
/// 构建、联动、取值收拢在控制器内；外部只调用 present()。
@MainActor
final class InputDialog: NSObject {
    private let title: String
    private let info: String
    private let linkText: String
    private let linkURL: URL
    private let prefill: String
    private let icon: NSImage?
    private let inputView = NSTextField()

    init(title: String, info: String, linkText: String, linkURL: URL, prefill: String,
         icon: NSImage? = nil) {
        self.title = title
        self.info = info
        self.linkText = linkText
        self.linkURL = linkURL
        self.prefill = prefill
        self.icon = icon
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

        // 输入行（行宽从 shell.contentWidth 推导，本弹窗用加宽规格 inputWidth）
        shell.contentWidth = DialogMetrics.inputWidth
        let rowWidth = shell.contentWidth - DialogMetrics.sidePadding * 2
        let row = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 28))
        inputView.frame = NSRect(x: 0, y: 2, width: rowWidth, height: 24)
        row.addSubview(inputView)
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

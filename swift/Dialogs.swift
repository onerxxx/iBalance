// Dialogs.swift — iBalance
// 弹窗统一封装:DialogShell 布局系统 + 各业务弹窗(InputDialog / DeepSeek 设置 / 平台自动化)
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)

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
        modalWindow.orderFrontRegardless()
        // NSAlert 视图树在 runModal 后才完成真实布局，图标/标题居中需在模态运行中微调
        DispatchQueue.main.async { [weak self] in
            self?.centerIconAndTitle()
            // 长内容 accessoryView 的最终布局可能晚于首帧完成，再校正一次标题区，
            // 避免手动签到结果弹窗的图标/标题被 NSAlert 重新布局后偏移。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.centerIconAndTitle()
            }
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
        // 不同 macOS 版本的 NSAlert 图标私有类名可能不同；优先使用已知类名，
        // 找不到时回退到内容树中的第一个 NSImageView，避免长内容弹窗无法进入居中逻辑。
        let iconView = (findSubview(named: "_NSAlertImageView", in: cv) as? NSImageView)
            ?? findFirstImageView(in: cv)
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
            // NSAlert 会把图标放进一个约等于图标大小的左侧 slot；移动 imageView
            // 本身会被 slot 裁住，因此优先移动这个窄容器，才能把整枚图标移到窗口中心。
            if let iconSlot = iconView.superview,
               iconSlot.bounds.width <= iconView.bounds.width + 2 {
                centerViewHorizontally(iconSlot, in: cv)
            } else {
                centerViewHorizontally(iconView, in: cv)
            }
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
            centerViewHorizontally(tf, in: cv)
        }
    }

    /// 将外层容器的水平中心转换到视图父容器坐标系后定位。
    /// NSAlert 标题/图标通常嵌套在私有容器中，不能直接用 contentView 的宽度计算 frame.origin.x。
    private func centerViewHorizontally(_ view: NSView, in container: NSView) {
        guard let superview = view.superview else { return }
        let centerInSuperview = container.convert(
            NSPoint(x: container.bounds.midX, y: container.bounds.midY),
            to: superview
        ).x
        var frame = view.frame
        frame.origin.x = centerInSuperview - frame.width / 2
        view.frame = frame
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

    /// NSAlert 的图标视图在不同系统版本中使用不同私有类名，通用兜底查找。
    private func findFirstImageView(in view: NSView) -> NSImageView? {
        if let imageView = view as? NSImageView {
            return imageView
        }
        for sub in view.subviews {
            if let found = findFirstImageView(in: sub) {
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

/// WorkBuddy 品牌图标（PNG，保持原色非 template），用于添加账号选择弹窗
func makeWbBrandIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "workbuddy", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
    return img
}

/// DeepSeek 设置弹窗：配置 DeepSeek API Key / 日常充值额度 + ZhiPu Token 覆盖。
@MainActor
final class DeepSeekSettingsDialog: NSObject {
    private let apiKeyField = NSTextField()
    private let popup = NSPopUpButton()
    private let customField = NSTextField()
    private let zhipuTokenField = NSTextField()
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
    init(apiKey: String, quota: Double, zhipuToken: String = "") {
        super.init()
        apiKeyField.isBezeled = true
        apiKeyField.bezelStyle = .roundedBezel
        apiKeyField.isEditable = true
        apiKeyField.isSelectable = true
        apiKeyField.font = NSFont.systemFont(ofSize: 12)
        apiKeyField.stringValue = apiKey
        apiKeyField.cell?.isScrollable = true
        apiKeyField.cell?.wraps = false
        apiKeyField.lineBreakMode = .byTruncatingTail

        zhipuTokenField.isBezeled = true
        zhipuTokenField.bezelStyle = .roundedBezel
        zhipuTokenField.isEditable = true
        zhipuTokenField.isSelectable = true
        zhipuTokenField.font = NSFont.systemFont(ofSize: 12)
        zhipuTokenField.stringValue = zhipuToken
        zhipuTokenField.cell?.isScrollable = true
        zhipuTokenField.cell?.wraps = false
        zhipuTokenField.lineBreakMode = .byTruncatingTail

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

    func present() -> (apiKey: String?, quota: Double, zhipuToken: String?)? {
        let shell = DialogShell()
        if let icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: DialogMetrics.iconSize, weight: .regular)) {
            icon.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            shell.addIcon(icon)
        }
        shell.addTitle("DeepSeek / ZhiPu 设置")
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
        shell.addInfo(infoAttr)
        shell.contentWidth = DialogMetrics.inputWidth

        // 三行设置共用一个 accessory 容器：文本在上、控件在下，统一左对齐。
        let rowWidth = shell.contentWidth - DialogMetrics.sidePadding * 2
        let labelHeight: CGFloat = 18
        let controlHeight: CGFloat = 28
        let labelControlGap: CGFloat = 4
        let rowHeight = labelHeight + labelControlGap + controlHeight
        let rowGap: CGFloat = 10
        let content = NSView(frame: NSRect(x: 0, y: 0,
                                           width: rowWidth,
                                           height: rowHeight * 3 + rowGap * 2))
        // 每行结构同构（label 在上偏 +32，控件在下），自底向上逐行叠放：
        // ZhiPu Token（底）→ 日常额度（中）→ API Key（顶）
        let keyLabel = NSTextField(labelWithString: "API Key")
        keyLabel.font = NSFont.systemFont(ofSize: 12)
        keyLabel.textColor = NSColor.labelColor
        keyLabel.alignment = .left
        keyLabel.frame = NSRect(x: 0, y: rowHeight * 2 + rowGap * 2 + controlHeight + labelControlGap,
                                width: rowWidth, height: labelHeight)
        apiKeyField.frame = NSRect(x: 0, y: rowHeight * 2 + rowGap * 2,
                                   width: rowWidth, height: controlHeight)
        content.addSubview(keyLabel)
        content.addSubview(apiKeyField)

        let quotaLabel = NSTextField(labelWithString: "日常额度")
        quotaLabel.font = NSFont.systemFont(ofSize: 12)
        quotaLabel.textColor = NSColor.labelColor
        quotaLabel.alignment = .left
        quotaLabel.frame = NSRect(x: 0, y: rowHeight + rowGap + controlHeight + labelControlGap,
                                  width: rowWidth, height: labelHeight)
        let popupWidth: CGFloat = 110
        popup.frame = NSRect(x: 0, y: rowHeight + rowGap, width: popupWidth, height: controlHeight)
        customField.frame = NSRect(x: popupWidth + 8, y: rowHeight + rowGap + 2,
                                   width: rowWidth - popupWidth - 8,
                                   height: 24)
        content.addSubview(quotaLabel)
        content.addSubview(popup)
        content.addSubview(customField)

        let zpLabel = NSTextField(labelWithString: "ZhiPu Token（空 = 自动读取浏览器登录态）")
        zpLabel.font = NSFont.systemFont(ofSize: 12)
        zpLabel.textColor = NSColor.labelColor
        zpLabel.alignment = .left
        zpLabel.frame = NSRect(x: 0, y: controlHeight + labelControlGap,
                               width: rowWidth, height: labelHeight)
        zhipuTokenField.frame = NSRect(x: 0, y: 0,
                                       width: rowWidth, height: controlHeight)
        content.addSubview(zpLabel)
        content.addSubview(zhipuTokenField)
        shell.addContent(content, height: content.frame.height)
        shell.firstResponder = apiKeyField

        // NSAlert 按钮顺序：先添加的在右边（默认按钮）
        let save = shell.addButton("保存", keyEquivalent: "\r")
        shell.addButton("取消", keyEquivalent: "\u{1b}")
        let clicked = shell.present()
        guard clicked == save else { return nil }

        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let zpRaw = zhipuTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customVal = Double(customField.stringValue.trimmingCharacters(in: .whitespaces)), customVal > 0 {
            return (apiKey.isEmpty ? nil : apiKey, customVal, zpRaw.isEmpty ? nil : zpRaw)
        }
        let idx = popup.indexOfSelectedItem
        let quota = idx < presets.count ? presets[idx].value : 0
        return (apiKey.isEmpty ? nil : apiKey, quota, zpRaw.isEmpty ? nil : zpRaw)
    }
}

/// 各平台刷新 / 自动签到 / 卡片显示开关弹窗：沿用 DialogShell 的原生标题、说明和按钮布局。
@MainActor
final class PlatformAutomationSettingsDialog: NSObject {
    private struct Row {
        let name: String
        let platformID: String
        let refresh: NSButton
        let checkin: NSButton?
        let card: NSButton
        let usage: NSButton
    }

    private let rows: [Row]
    private let initialConfig: AppConfig

    init(config: AppConfig) {
        initialConfig = config
        func makeCheckbox(label: String, isOn: Bool) -> NSButton {
            let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            checkbox.controlSize = .small
            checkbox.alignment = .center
            checkbox.state = isOn ? .on : .off
            checkbox.setAccessibilityLabel(label)
            return checkbox
        }

        rows = [
            Row(name: "DeepSeek", platformID: "ds",
                refresh: makeCheckbox(label: "DeepSeek 刷新", isOn: config.deepseekRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "DeepSeek 卡片显示",
                                   isOn: config.panelCardVisible["ds"] ?? true),
                usage: makeCheckbox(label: "DeepSeek 用量显示",
                                    isOn: config.panelUsageVisible["ds"] ?? true)),
            Row(name: "ZhiPu", platformID: "zhipu",
                refresh: makeCheckbox(label: "ZhiPu 刷新", isOn: config.bigmodelRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "ZhiPu 卡片显示",
                                   isOn: config.panelCardVisible["zhipu"] ?? true),
                usage: makeCheckbox(label: "ZhiPu 用量显示",
                                    isOn: config.panelUsageVisible["zhipu"] ?? true)),
            Row(name: "WorkBuddy", platformID: "wb",
                refresh: makeCheckbox(label: "WorkBuddy 刷新", isOn: config.workbuddyEnabled),
                checkin: makeCheckbox(label: "WorkBuddy 自动签到", isOn: config.workbuddyAutoCheckin),
                card: makeCheckbox(label: "WorkBuddy 卡片显示",
                                   isOn: config.panelCardVisible["wb"] ?? true),
                usage: makeCheckbox(label: "WorkBuddy 用量显示",
                                    isOn: config.panelUsageVisible["wb"] ?? true)),
            Row(name: "TRAE", platformID: "trae",
                refresh: makeCheckbox(label: "TRAE 刷新", isOn: config.traeRefreshEnabled),
                checkin: makeCheckbox(label: "TRAE 自动签到", isOn: config.traeAutoCheckin),
                card: makeCheckbox(label: "TRAE 卡片显示",
                                   isOn: config.panelCardVisible["trae"] ?? true),
                usage: makeCheckbox(label: "TRAE 用量显示",
                                    isOn: config.panelUsageVisible["trae"] ?? true)),
            Row(name: "ZCode", platformID: "zcode",
                refresh: makeCheckbox(label: "ZCode 刷新", isOn: config.zcodeRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "ZCode 卡片显示",
                                   isOn: config.panelCardVisible["zcode"] ?? true),
                usage: makeCheckbox(label: "ZCode 用量显示",
                                    isOn: config.panelUsageVisible["zcode"] ?? true)),
            Row(name: "Codex", platformID: "codex",
                refresh: makeCheckbox(label: "Codex 刷新", isOn: config.codexRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "Codex 卡片显示",
                                   isOn: config.panelCardVisible["codex"] ?? true),
                usage: makeCheckbox(label: "Codex 用量显示",
                                    isOn: config.panelUsageVisible["codex"] ?? true)),
        ]
        super.init()
    }

    func present() -> AppConfig? {
        let shell = DialogShell()
        let icon = NSImage(systemSymbolName: "circle.grid.2x2.topleft.checkmark.filled", accessibilityDescription: nil)
        shell.addIcon(icon)
        shell.addTitle("平台开关")
        shell.addInfo("选择各平台是否参与刷新、自动签到（支持签到的平台）、在面板显示余额卡片，以及是否显示该平台的用量行。")
        shell.contentWidth = DialogMetrics.width + 8 + 60 + 54 + 4

        let headerName = NSTextField(labelWithString: "平台")
        let headerRefresh = NSTextField(labelWithString: "刷新")
        let headerCheckin = NSTextField(labelWithString: "签到")
        let headerCard = NSTextField(labelWithString: "卡片")
        let headerUsage = NSTextField(labelWithString: "用量")
        for label in [headerName, headerRefresh, headerCheckin, headerCard, headerUsage] {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        headerRefresh.alignment = .center
        headerCheckin.alignment = .center
        headerCard.alignment = .center
        headerUsage.alignment = .center

        var gridRows: [[NSView]] = [[headerName, headerRefresh, headerCheckin, headerCard, headerUsage]]
        for row in rows {
            let name = NSTextField(labelWithString: row.name)
            name.font = .systemFont(ofSize: 12)
            name.textColor = .labelColor
            let checkinView: NSView
            if let checkin = row.checkin {
                checkinView = checkin
            } else {
                let unavailable = NSTextField(labelWithString: "—")
                unavailable.alignment = .center
                unavailable.font = .systemFont(ofSize: 12)
                unavailable.textColor = .tertiaryLabelColor
                unavailable.setAccessibilityLabel("该平台不支持签到")
                checkinView = unavailable
            }
            gridRows.append([name, row.refresh, checkinView, row.card, row.usage])
        }

        // NSGridView 让每一列共享同一条轨道：平台列左对齐，各控件列居中，
        // 表头、checkbox 和「—」占位符天然保持表格对齐，不再手算坐标。
        let grid = NSGridView(views: gridRows)
        let headerHeight: CGFloat = 22
        let rowHeight: CGFloat = 27
        let rowSpacing: CGFloat = 4
        grid.rowSpacing = rowSpacing
        grid.columnSpacing = 4
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).width = 116
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).width = 54
        grid.column(at: 1).xPlacement = .center
        grid.column(at: 2).width = 54
        grid.column(at: 2).xPlacement = .center
        grid.column(at: 3).width = 54
        grid.column(at: 3).xPlacement = .center
        grid.column(at: 4).width = 54
        grid.column(at: 4).xPlacement = .center
        grid.row(at: 0).height = headerHeight
        for index in 1...rows.count {
            grid.row(at: index).height = rowHeight
        }
        let gridHeight = headerHeight + CGFloat(rows.count) * rowHeight
            + CGFloat(rows.count) * rowSpacing
        shell.addContent(grid, height: gridHeight)
        let save = shell.addButton("保存", keyEquivalent: "\r")
        shell.addButton("取消", keyEquivalent: "\u{1b}")
        guard shell.present() == save else { return nil }

        var updatedConfig = initialConfig
        updatedConfig.deepseekRefreshEnabled = rows[0].refresh.state == .on
        updatedConfig.bigmodelRefreshEnabled = rows[1].refresh.state == .on
        updatedConfig.workbuddyEnabled = rows[2].refresh.state == .on
        updatedConfig.workbuddyAutoCheckin = rows[2].checkin?.state == .on
        updatedConfig.traeRefreshEnabled = rows[3].refresh.state == .on
        updatedConfig.traeAutoCheckin = rows[3].checkin?.state == .on
        updatedConfig.zcodeRefreshEnabled = rows[4].refresh.state == .on
        updatedConfig.codexRefreshEnabled = rows[5].refresh.state == .on
        for row in rows {
            updatedConfig.panelCardVisible[row.platformID] = (row.card.state == .on)
            updatedConfig.panelUsageVisible[row.platformID] = (row.usage.state == .on)
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

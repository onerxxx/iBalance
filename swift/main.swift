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

/// DeepSeek 品牌图标（PNG，保持原色非 template），用于 API Key / 日常额度弹窗
private func makeDsBrandIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "deepseek", withExtension: "png"),
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

/// DeepSeek 设置弹窗：一次性配置 API Key 和日常充值额度。
@MainActor
final class DeepSeekSettingsDialog: NSObject {
    private let apiKeyField = NSTextField()
    private let popup = NSPopUpButton()
    private let customField = NSTextField()
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
    init(apiKey: String, quota: Double) {
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

    func present() -> (apiKey: String?, quota: Double)? {
        let shell = DialogShell()
        shell.addIcon(makeDsBrandIcon())
        shell.addTitle("DeepSeek 设置")
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

        // 两行设置共用一个 accessory 容器：文本在上、控件在下，统一左对齐。
        let rowWidth = shell.contentWidth - DialogMetrics.sidePadding * 2
        let labelHeight: CGFloat = 18
        let controlHeight: CGFloat = 28
        let labelControlGap: CGFloat = 4
        let rowHeight = labelHeight + labelControlGap + controlHeight
        let rowGap: CGFloat = 10
        let content = NSView(frame: NSRect(x: 0, y: 0,
                                           width: rowWidth,
                                           height: rowHeight * 2 + rowGap))
        let keyLabel = NSTextField(labelWithString: "API Key")
        keyLabel.font = NSFont.systemFont(ofSize: 12)
        keyLabel.textColor = NSColor.labelColor
        keyLabel.alignment = .left
        keyLabel.frame = NSRect(x: 0, y: rowHeight + rowGap + controlHeight + labelControlGap,
                                width: rowWidth, height: labelHeight)
        apiKeyField.frame = NSRect(x: 0, y: rowHeight + rowGap,
                                   width: rowWidth, height: controlHeight)
        content.addSubview(keyLabel)
        content.addSubview(apiKeyField)

        let quotaLabel = NSTextField(labelWithString: "日常额度")
        quotaLabel.font = NSFont.systemFont(ofSize: 12)
        quotaLabel.textColor = NSColor.labelColor
        quotaLabel.alignment = .left
        quotaLabel.frame = NSRect(x: 0, y: controlHeight + labelControlGap,
                                  width: rowWidth, height: labelHeight)
        let popupWidth: CGFloat = 110
        popup.frame = NSRect(x: 0, y: 0, width: popupWidth, height: controlHeight)
        customField.frame = NSRect(x: popupWidth + 8, y: 2,
                                   width: rowWidth - popupWidth - 8,
                                   height: 24)
        content.addSubview(quotaLabel)
        content.addSubview(popup)
        content.addSubview(customField)
        shell.addContent(content, height: content.frame.height)
        shell.firstResponder = apiKeyField

        // NSAlert 按钮顺序：先添加的在右边（默认按钮）
        let save = shell.addButton("保存", keyEquivalent: "\r")
        shell.addButton("取消", keyEquivalent: "\u{1b}")
        let clicked = shell.present()
        guard clicked == save else { return nil }

        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let customVal = Double(customField.stringValue.trimmingCharacters(in: .whitespaces)), customVal > 0 {
            return (apiKey.isEmpty ? nil : apiKey, customVal)
        }
        let idx = popup.indexOfSelectedItem
        let quota = idx < presets.count ? presets[idx].value : 0
        return (apiKey.isEmpty ? nil : apiKey, quota)
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
                                   isOn: config.panelCardVisible["ds"] ?? true)),
            Row(name: "WorkBuddy", platformID: "wb",
                refresh: makeCheckbox(label: "WorkBuddy 刷新", isOn: config.workbuddyEnabled),
                checkin: makeCheckbox(label: "WorkBuddy 自动签到", isOn: config.workbuddyAutoCheckin),
                card: makeCheckbox(label: "WorkBuddy 卡片显示",
                                   isOn: config.panelCardVisible["wb"] ?? true)),
            Row(name: "TRAE", platformID: "trae",
                refresh: makeCheckbox(label: "TRAE 刷新", isOn: config.traeRefreshEnabled),
                checkin: makeCheckbox(label: "TRAE 自动签到", isOn: config.traeAutoCheckin),
                card: makeCheckbox(label: "TRAE 卡片显示",
                                   isOn: config.panelCardVisible["trae"] ?? true)),
            Row(name: "ZCode", platformID: "zcode",
                refresh: makeCheckbox(label: "ZCode 刷新", isOn: config.zcodeRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "ZCode 卡片显示",
                                   isOn: config.panelCardVisible["zcode"] ?? true)),
            Row(name: "Codex", platformID: "codex",
                refresh: makeCheckbox(label: "Codex 刷新", isOn: config.codexRefreshEnabled),
                checkin: nil,
                card: makeCheckbox(label: "Codex 卡片显示",
                                   isOn: config.panelCardVisible["codex"] ?? true)),
        ]
        super.init()
    }

    func present() -> AppConfig? {
        let shell = DialogShell()
        let icon = NSImage(systemSymbolName: "circle.grid.2x2.topleft.checkmark.filled", accessibilityDescription: nil)
        shell.addIcon(icon)
        shell.addTitle("平台开关")
        shell.addInfo("选择各平台是否参与刷新、自动签到（支持签到的平台），以及是否在面板显示余额卡片。")
        shell.contentWidth = DialogMetrics.width + 8 + 60

        let headerName = NSTextField(labelWithString: "平台")
        let headerRefresh = NSTextField(labelWithString: "刷新")
        let headerCheckin = NSTextField(labelWithString: "签到")
        let headerCard = NSTextField(labelWithString: "卡片")
        for label in [headerName, headerRefresh, headerCheckin, headerCard] {
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        headerRefresh.alignment = .center
        headerCheckin.alignment = .center
        headerCard.alignment = .center

        var gridRows: [[NSView]] = [[headerName, headerRefresh, headerCheckin, headerCard]]
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
            gridRows.append([name, row.refresh, checkinView, row.card])
        }

        // NSGridView 让每一列共享同一条轨道：平台列左对齐，三个控件列居中，
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
        updatedConfig.workbuddyEnabled = rows[1].refresh.state == .on
        updatedConfig.workbuddyAutoCheckin = rows[1].checkin?.state == .on
        updatedConfig.traeRefreshEnabled = rows[2].refresh.state == .on
        updatedConfig.traeAutoCheckin = rows[2].checkin?.state == .on
        updatedConfig.zcodeRefreshEnabled = rows[3].refresh.state == .on
        updatedConfig.codexRefreshEnabled = rows[4].refresh.state == .on
        for row in rows {
            updatedConfig.panelCardVisible[row.platformID] = (row.card.state == .on)
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

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private let statusBar = NSStatusBar.system
    private var statusItem: NSStatusItem!
    private var autoCheckinMenuItem: NSMenuItem!
    private var refreshIntervalMenuItem: NSMenuItem!
    private var refreshIntervalOptions: [NSMenuItem] = []

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
    private var floatingPanel: NSPanel?
    /// pin 时预建的下一轮面板（unpin/重开面板时由 showPanel 恢复为 panelView）
    private var prebuiltPanelView: BalancePanelView?
    /// 内容转移中标志：popover 关闭由 pin 转移引发，popoverDidClose 跳过
    /// 「记录事件时间戳 + NSApp.hide」（hide 会连浮动窗一起隐藏）
    private var isTransferringPanel = false
    private var settingsMenu: NSMenu!
    /// 面板最近一次释放拖拽后的平台顺序；面板未拖拽前回退到 UserDefaults。
    private var menuBarPlatformOrder: [String]?
    private var lastUpdatedAt = ""
    /// 上次余额刷新完成时间：打开面板时若距此 <1分钟则跳过自动刷新，避免频繁请求
    private var lastRefreshTime = Date.distantPast

    /// 进行中的刷新任务：onRefresh 触发时先取消旧任务，保证同一时刻只有一个刷新在跑
    private var refreshTask: Task<Void, Never>?
    /// 刷新序号（递增）：日志中关联 onRefresh / performRefresh / refreshOne*
    private var refreshSeq: Int64 = 0
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

    private var config = AppConfig()
    /// 调试用量样例缓存：开启时只在切换开关时重新随机，避免面板普通刷新时图表跳动。
    private var debugUsageRows: [UsageRowSnapshot] = []
    // 缓存原始数据，切换小数位时即时重绘（仅在主线程变更）
    private var cacheDs: (symbol: String, totalRaw: String, total: Double)?
    private var cacheWb: (remain: Double, total: Double)?
    /// WorkBuddy 多账号额度缓存：uid → (remain, total)，用于面板显示每号余额卡片
    private var cacheWbAccounts: [String: (remain: Double, total: Double)] = [:]
    private var cacheTrae: (limit: Double, used: Double)?
    /// TRAE 多账号额度缓存：uid → (limit, used)
    private var cacheTraeAccounts: [String: (limit: Double, used: Double)] = [:]
    /// ZCode 多账号额度缓存：uid → (remain, total, planEndsAt)，remain/total 为 token 数，planEndsAt 为免费套餐到期戳（0=无）
    private var cacheZcodeAccounts: [String: (remain: Double, total: Double, planEndsAt: TimeInterval)] = [:]
    /// Codex usage 缓存：uid → (usedPercent, resetAt)
    private var cacheCodexAccounts: [String: (usedPercent: Double, resetAt: TimeInterval)] = [:]
    // 点阵脉冲状态：仅由真实数据刷新（refreshOne*）更新，面板开关 syncPanel 只读不写
    // 规则：usedRatio 上升（额度被消耗）→ pulsing=true；稳定或回升 → pulsing=false
    private var prevTraeRatio: [String: Double] = [:]
    private var traePulsing: [String: Bool] = [:]
    private var prevWbRatio: [String: Double] = [:]
    private var wbPulsing: [String: Bool] = [:]
    private var prevZcodeRatio: [String: Double] = [:]
    private var zcodePulsing: [String: Bool] = [:]
    private var prevDsRatio: Double = -1   // DeepSeek 已用占比上次值（-1 = 未初始化）
    private var dsPulsing = false          // 余额被消耗 → 点阵脉冲

    /// 点阵脉冲核心规则（WB/TRAE/ZCode/DeepSeek 共用）：
    /// usedRatio 上升 → pulsing=true（被消耗）；稳定或回升 → pulsing=false；首轮（prev<0）不触发。
    private func updatePulsingState(prevRatio: inout Double, pulsing: inout Bool, newRatio: Double) {
        if prevRatio >= 0 { pulsing = newRatio > prevRatio }
        prevRatio = newRatio
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
    private func buildPanelOnce() {
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
        panel.onToggleSubAccountDim = { [weak self] in self?.onToggleSubAccountDim() }
        panel.onToggleDebugUsage = { [weak self] in self?.onToggleDebugUsage() }
        panel.onAbout = { [weak self] in self?.onAbout() }
        panel.onManagePlatformToggles = { [weak self] in self?.onManagePlatformToggles() }
        panel.onManualCheckin = { [weak self] in self?.onManualCheckin() }
        panel.onShowCheckinHistory = { [weak self] in self?.onShowCheckinHistory() }
        panel.onQuit = { [weak self] in self?.onQuit() }
        // 右上角 pin：置顶常驻——内容转移至无边框 NSPanel 浮动窗口（无箭头、
        // 浮层层级、背景原生拖动）；取消置顶时装回 popover 回到按钮下方
        panel.onTogglePin = { [weak self] in self?.togglePanelPin() }
        // 余额卡片点击：DeepSeek 打开浏览器，TRAE / WorkBuddy / ZCode 启动应用
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
        panel.onClickCodex = { [weak self] in
            self?.openApp(bundleId: "com.openai.codex", missingTitle: "未找到 Codex 应用",
                          missingMsg: "未找到 Codex 应用，请确认 ChatGPT/Codex 已安装。")
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

    /// 切换面板置顶（popover ↔ 无边框 NSPanel 浮动窗口）：
    /// - 置顶：popover 内容（contentViewController）转移至 NSPanel——无边框窗口
    ///   天然无箭头，浮层层级 + 背景原生拖动；面板背景为 TintedVisualEffectView
    ///   （毛玻璃 + 圆角 + 裁剪），透明窗口承载后外观与 popover 无缝。
    /// - 取消：浮窗退场，showPanel 把同一 VC 装回 popover，回到按钮下方。
    private func togglePanelPin() {
        // 取消置顶：浮窗退场，弹出预建的 popover（pin 时已 buildPanelOnce）零构建等待
        if let fp = floatingPanel, fp.isVisible {
            fp.orderOut(nil)
            fp.contentViewController = nil
            // popoverController == nil 的兜底（预建异常时现场重建）仍由 showPanel 处理
            showPanel()
            return
        }
        guard let popover = popoverController, popover.isShown,
              let vc = popover.contentViewController,
              let popWindow = vc.view.window else { return }
        // 用内容视图自身的屏幕位置定位浮窗：popover 窗口 frame 含箭头/阴影边距，
        // 直接套用会向左上偏移；无边框浮窗内容铺满窗口，与原内容像素级重合
        let viewFrame = popWindow.convertToScreen(vc.view.convert(vc.view.bounds, to: nil))
        let fp = floatingPanel ?? makeFloatingPanel()
        floatingPanel = fp
        // 转移标志：popover 关闭回调跳过「记录点击时间戳 + NSApp.hide」
        //（hide 会隐藏包括新浮窗在内的全部窗口）
        isTransferringPanel = true
        // 先挂载（窗口按 preferredContentSize 自动定形），再 setFrame 覆盖为
        // 内容视图的实际屏幕位置——顺序颠倒会被挂载时的自动 resize 带偏
        fp.contentViewController = vc
        fp.setFrame(viewFrame, display: false)
        popWindow.orderOut(nil)
        popover.close()
        isTransferringPanel = false
        fp.orderFrontRegardless()
        // 预建下一轮 popover：unpin / 点击菜单栏重开面板时零构建等待。
        // 面板重建是百毫秒级主线程工作，放在 pin 之后执行——浮窗刚显示、用户
        // 尚未开始拖动，卡顿感知极弱；旧 popover（含转移过的 VC）在此整体释放。
        // ⚠️ 置顶期间 panelView 必须继续指向浮窗中的面板（数据刷新目标），
        // 预建面板单独存放，showPanel 时恢复
        let pinnedPanel = panelView
        popoverController = nil
        buildPanelOnce()
        prebuiltPanelView = panelView
        panelView = pinnedPanel
    }

    /// 置顶浮动窗：无边框 + 不激活（点击面板不抢 App 焦点，与 popover 行为一致）、
    /// 透明背景（圆角玻璃由面板容器自绘）、浮层层级、跟随全部 Space。
    /// ⚠️ 不用 isMovableByWindowBackground：borderless 窗口上系统会显示灰色拖动
    /// 示意条；也不用 titled+fullSizeContentView 规避——透明 titlebar 会截获顶部
    /// 鼠标事件（「余额」标题行的 pin 按钮在 titlebar 区收不到点击，无法解除置顶）。
    /// 拖动改由面板视图自绘（BalancePanelView.mouseDown）
    private func makeFloatingPanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces]
        p.hidesOnDeactivate = false
        return p
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
    private func keepPanelAliveDuring<T>(_ block: () -> T) -> T {
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
        // 刷新失败标记：按固定顺序列出本轮获取失败的服务（footer 展示，成功即自动清除）
        if !failedServices.isEmpty {
            let order = ["DeepSeek", "WorkBuddy", "TRAE", "ZCode", "Codex"]
            let names = order.filter { failedServices.contains($0) }
            if !names.isEmpty { s.failedText = names.joined(separator: "、") + " 刷新失败" }
        }
        if let ds = cacheDs {
            s.ds = "\(ds.symbol)\u{2009}\(fmtAmountRaw(ds.totalRaw))"
            if config.deepseekCommonQuota > 0 {
                let used = max(0, config.deepseekCommonQuota - ds.total)
                s.dsUsedRatio = min(1, used / config.deepseekCommonQuota)
            }
            s.dsPulsing = dsPulsing
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
            snap.checkinDone = UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(ac.uid)) == today
            // 签到已关闭的平台不显示失败角标（当日失败标记仍保留，重新开启后可见）；
            // 风控（9074/操作太频繁）也显示角标，但颜色为橙黄（checkinRisk）
            let traeRiskToday = UserDefaults.standard.string(forKey: UDKey.traeCheckinRiskDate(ac.uid)) == today
            snap.checkinFailed = config.traeAutoCheckin
                && (UserDefaults.standard.string(forKey: UDKey.traeCheckinFailDate(ac.uid)) == today || traeRiskToday)
            snap.checkinRisk = config.traeAutoCheckin && traeRiskToday
            snap.streak = UserDefaults.standard.integer(forKey: UDKey.traeCheckinStreak(ac.uid))
            snap.reward = UserDefaults.standard.integer(forKey: UDKey.traeCheckinReward(ac.uid))
            snap.pulsing = traePulsing[ac.uid] ?? false
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
            }
            snap.checkinDone = UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(ac.uid)) == today
            // 签到已关闭的平台不显示失败角标（当日失败标记仍保留，重新开启后可见）
            snap.checkinFailed = config.workbuddyAutoCheckin
                && UserDefaults.standard.string(forKey: UDKey.wbCheckinFailDate(ac.uid)) == today
            snap.streak = UserDefaults.standard.integer(forKey: UDKey.wbCheckinStreak(ac.uid))
            snap.reward = UserDefaults.standard.integer(forKey: UDKey.wbCheckinReward(ac.uid))
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
                        let total = Int(remainSec)
                        let days = total / 86400
                        let h = (total % 86400) / 3600
                        let m = (total % 3600) / 60
                        if days > 0 {
                            snap.expireText = String(format: "\u{2009}%d天 %02d:%02d\u{2009}后到期", days, h, m)
                        } else {
                            snap.expireText = String(format: "\u{2009}%02d:%02d\u{2009}后到期", h, m)
                        }
                    } else {
                        // Start Plan 已到期：卡片显示"套餐已到期"红色提示，且不再参与定时刷新
                        snap.expired = true
                        snap.expireText = "套餐已到期"
                    }
                }
            }
            snap.pulsing = zcodePulsing[ac.uid] ?? false
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
                // 到期副标题：仅当前账号显示，剩余时长格式同 ZCode（HH:mm，小时可超 24）
                if isCurrent, c.resetAt > 0 {
                    let remainSec = c.resetAt - Date().timeIntervalSince1970
                    if remainSec > 0 {
                        let total = Int(remainSec)
                        let days = total / 86400
                        let h = (total % 86400) / 3600
                        let m = (total % 3600) / 60
                        if days > 0 {
                            snap.expireText = String(format: "\u{2009}%d天 %02d:%02d\u{2009}后到期", days, h, m)
                        } else {
                            snap.expireText = String(format: "\u{2009}%02d:%02d\u{2009}后到期", h, m)
                        }
                    } else {
                        snap.expireText = "已到期"
                    }
                }
            }
            s.codexAccounts.append(snap)
        }
        // ── 日/周用量（本地差值基线，见 UsageStore；仅当前账号）──
        func fmtUsage(_ v: Double, percent: Bool, decimals: Int) -> String {
            percent ? String(format: "%.1f%%", v) : fmtAmountCommas(v, decimals: decimals)
        }
        func usageRow(icon: String, name: String, platform: String, uid: String,
                      current: Double?, increasing: Bool, decimals: Int,
                      percent: Bool, prefix: String = "") -> UsageRowSnapshot? {
            guard !uid.isEmpty, let cur = current,
                  let u = UsageStore.usage(platform: platform, uid: uid, current: cur, increasing: increasing) else { return nil }
            let daily = UsageStore.weeklyUsage(platform: platform, uid: uid)
            return UsageRowSnapshot(platform: platform, icon: icon, name: name,
                                    todayText: prefix + fmtUsage(u.today, percent: percent, decimals: decimals),
                                    weekText: prefix + fmtUsage(u.week, percent: percent, decimals: decimals),
                                    dailyUsage: daily,
                                    dailyUsageTexts: daily.map { prefix + fmtUsage($0, percent: percent, decimals: decimals) })
        }
        if let ds = cacheDs,
           let row = usageRow(icon: "deepseek", name: "DeepSeek", platform: "ds", uid: "main",
                              current: ds.total, increasing: false, decimals: 2, percent: false, prefix: ds.symbol) {
            s.usageRows.append(row)
        }
        if let row = usageRow(icon: "workbuddy", name: "WorkBuddy", platform: "wb", uid: mainUid,
                              current: cacheWbAccounts[mainUid]?.remain, increasing: false,
                              decimals: config.workbuddyDecimals, percent: false) {
            s.usageRows.append(row)
        }
        if let row = usageRow(icon: "trae-color", name: "TRAE", platform: "trae", uid: traeMainUid,
                              current: cacheTraeAccounts[traeMainUid]?.used, increasing: true,
                              decimals: config.traeDecimals, percent: false) {
            s.usageRows.append(row)
        }
        if let zc = cacheZcodeAccounts[zcodeMainUid], zc.total > 0,
           let row = usageRow(icon: "zhipu", name: "ZCode", platform: "zcode", uid: zcodeMainUid,
                              current: zc.remain / zc.total * 100, increasing: false,
                              decimals: 1, percent: true) {
            s.usageRows.append(row)
        }
        if let row = usageRow(icon: "codex", name: "Codex", platform: "codex", uid: codexMainUid,
                              current: cacheCodexAccounts[codexMainUid]?.usedPercent, increasing: true,
                              decimals: 1, percent: true) {
            s.usageRows.append(row)
        }
        // 调试模式始终提供完整的七日样例，即使本机尚未配置任何平台账号，方便直接观察面积图。
        s.debugUsageEnabled = config.debugUsageEnabled
        if config.debugUsageEnabled {
            if debugUsageRows.isEmpty { debugUsageRows = makeDebugUsageRows() }
            s.usageRows = debugUsageRows
        }
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
        s.subAccountDimEnabled = config.subAccountDimEnabled
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
            let todayText = item.percent
                ? String(format: "%.1f%%", today)
                : item.prefix + fmtAmountCommas(today, decimals: item.decimals)
            let weekText = item.percent
                ? String(format: "%.1f%%", week)
                : item.prefix + fmtAmountCommas(week, decimals: item.decimals)
            return UsageRowSnapshot(platform: item.platform, icon: item.icon, name: item.name,
                                    todayText: todayText, weekText: weekText,
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
    private func syncPanel(file: StaticString = #file, line: Int = #line) {
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

    @objc private func onRefresh() {
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

    /// Mono 字体：余额卡片与用量列表切换 SF Mono（中文回退系统字体），
    /// 保存后经快照同步，面板对已注册 label 就地换字体（不重建卡片）
    @objc private func onToggleMonoFont() {
        config.monoFontEnabled = !config.monoFontEnabled
        ConfigStore.save(config)
        syncPanel()
    }

    /// 弱化非当前账号：切换小卡片整卡降透明（悬停复亮）的新设计
    @objc private func onToggleSubAccountDim() {
        config.subAccountDimEnabled = !config.subAccountDimEnabled
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
    private enum MenuBarPrefix {
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
    private func updateTitle(tag: String = #function) {
        updateTitleCallCount &+= 1
        let callNo = updateTitleCallCount
        titleDebouncer.dispatch("updateTitle@\(callNo)#\(tag)") { [weak self] in
            self?.updateTitleImpl(tag: "debounced@\(callNo)#\(tag)")
        }
    }

    /// 用户主动操作（右键切换显隐等）的立即通道：跳过去抖当场渲染并应用位图
    /// （菜单栏瞬间反馈），面板位置由 startPanelOriginLock 的 KVO 锁定接管。
    private func updateTitle(immediate: Bool, tag: String = #function) {
        guard immediate else { updateTitle(tag: tag); return }
        updateTitleCallCount &+= 1
        let callNo = updateTitleCallCount
        titleDebouncer.flush { [weak self] in
            self?.updateTitleImpl(tag: "immediate@\(callNo)#\(tag)")
        }
    }

    /// 实际绘制：构建 attributed string → 烘焙 3x 位图 template → 赋给 button.image。
    /// 每次都会打印耗时，便于定位「菜单栏位图烘焙太重导致主线程卡顿」。
    private func updateTitleImpl(tag: String) {
        let t0 = Date()
        updateTitleRenderCount &+= 1
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
                updatePulsingState(prevRatio: &prevDsRatio, pulsing: &dsPulsing,
                                   newRatio: min(1, used / config.deepseekCommonQuota))
            } else {
                prevDsRatio = -1
                dsPulsing = false
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

    private func refreshOneWorkBuddy(_ cfg: AppConfig, seq: Int64) async {
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
        var prev = prevWbRatio[uid] ?? -1
        var pulsing = wbPulsing[uid] ?? false
        updatePulsingState(prevRatio: &prev, pulsing: &pulsing,
                           newRatio: total > 0 ? (total - remain) / total : 0)
        prevWbRatio[uid] = prev
        wbPulsing[uid] = pulsing
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
            // Start Plan 已到期（缓存 planEndsAt > 0 且已过期）→ 不再刷新该账号，
            // 保留卡片"套餐已到期"提示，避免无效请求与误判失败
            if let cached = cacheZcodeAccounts[ac.uid],
               cached.planEndsAt > 0, cached.planEndsAt <= Date().timeIntervalSince1970 {
                Logger.log(.refresh, "\(acctag): plan expired at \(cached.planEndsAt), skip fetch")
                continue
            }
            let r = await Logger.measure("\(acctag).fetchBalance") {
                await ZcodeService.fetchBalance(token: ac.token)
            }
            guard ownsRefresh(seq) else {
                Logger.log(.refresh, "\(acctag): not owner after fetch, skip writeback")
                return
            }
            guard r.total > 0 else {
                zcodeFailed = true  // 该号获取失败（token 失效或网络错误）
                Logger.log(.refresh, "\(acctag): total<=0, marked failed")
                continue
            }
            cacheZcodeAccounts[ac.uid] = r
            if r.total > 0 {
                UsageStore.observe(platform: "zcode", uid: ac.uid, value: r.remain / r.total * 100, increasing: false)
            }
            var prev = prevZcodeRatio[ac.uid] ?? -1
            var pulsing = zcodePulsing[ac.uid] ?? false
            updatePulsingState(prevRatio: &prev, pulsing: &pulsing,
                               newRatio: r.total > 0 ? (r.total - r.remain) / r.total : 0)
            prevZcodeRatio[ac.uid] = prev
            zcodePulsing[ac.uid] = pulsing
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

    /// 补全 WorkBuddy 多账号签到 streak/reward：遍历所有账号，streak 或 reward 为 0 时查状态 API 填充。
    /// 每天最多跑一次（wb_status_fill_date 守卫），避免每次余额刷新都打 status API 触发风控。
    /// auto-checkin 已开启且主账号今日已签到时跳过（签到流程会顺带补全 streak/reward，去重）。
    /// 与 TRAE 侧 traeCheckinStatusFill 对齐：自动签到关闭时，手动在 Desktop 签过也能补写历史。
    private func wbCheckinStatusFill() async {
        let today = Self.todayString()
        // 每天最多补全一次，避免每次余额刷新都打 status API 触发风控
        let fillDateKey = UDKey.wbStatusFillDate
        if UserDefaults.standard.string(forKey: fillDateKey) == today { return }
        // auto-checkin 已开启且主账号今日已签到 → 签到流程会顺带补全 streak/reward，跳过
        if config.workbuddyAutoCheckin,
           let mainUid = WorkBuddyService.authInfo()?.uid,
           UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(mainUid)) == today {
            UserDefaults.standard.set(today, forKey: fillDateKey)
            return
        }
        let accounts = wbCheckinAccounts()
        for i in 0..<accounts.count {
            var ac = accounts[i]
            let dateKey = UDKey.wbCheckinDate(ac.uid)
            let streakKey = UDKey.wbCheckinStreak(ac.uid)
            let rewardKey = UDKey.wbCheckinReward(ac.uid)
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 仅当今天已签到且 streak/reward 均有值时才跳过
            if prevStreak > 0 && prevReward > 0 && UserDefaults.standard.string(forKey: dateKey) == today { continue }
            // 查状态前自动刷新 token（距过期 < 1 小时则用 refreshToken 续期）
            let refreshed = await WorkBuddyService.refreshTokenIfNeeded(account: ac)
            if refreshed != ac {
                if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                    config.workbuddyAccounts[idx] = refreshed
                    ConfigStore.save(config)
                }
                ac = refreshed
            }
            guard let st = await WorkBuddyService.fetchCheckinStatus(token: ac.token, uid: ac.uid, domain: ac.domain) else { continue }
            if st.todayCheckedIn {
                // 优先用 API continuousDays（权威值）；无值时基于上次签到日期用 nextStreak 推算
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
                // 今天 history 无记录才补：streak/reward 是跨天持久值，非零不能代表「今天已记录」
                let hk = UDKey.wbCheckinHistory(ac.uid)
                if !checkinHistory(key: hk).contains(where: { $0.date == today }) {
                    appendCheckinHistory(key: hk,
                                         date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                }
                UserDefaults.standard.set(today, forKey: dateKey)
                // 已确认今天已签到，清除历史失败残留标记（与签到流程对齐）
                UserDefaults.standard.set(false, forKey: UDKey.wbCheckinFailed(ac.uid))
                UserDefaults.standard.removeObject(forKey: UDKey.wbCheckinFailDate(ac.uid))
            }
        }
        UserDefaults.standard.set(today, forKey: UDKey.wbStatusFillDate)
        syncPanel()
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
            let dateKey = UDKey.wbCheckinDate(ac.uid)
            let streakKey = UDKey.wbCheckinStreak(ac.uid)
            let rewardKey = UDKey.wbCheckinReward(ac.uid)
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 今天已签到且 streak/reward 均有值且 history 已有今天的记录 → 跳过
            // （history 缺记录时放行进下方流程查状态补写，补上后恢复零网络跳过）
            if UserDefaults.standard.string(forKey: dateKey) == today && prevStreak > 0 && prevReward > 0
               && checkinHistory(key: UDKey.wbCheckinHistory(ac.uid)).contains(where: { $0.date == today }) { continue }

            // 错峰守卫：未到今日就绪时刻的账号本轮跳过（手动一键签到不受限）
            if !force,
               Date().timeIntervalSince1970 < Self.checkinReadyTimestamp(key: UDKey.wbCheckinReady(ac.uid), today: today) {
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
                        let hk = UDKey.wbCheckinHistory(ac.uid)
                        if !checkinHistory(key: hk).contains(where: { $0.date == today }) {
                            appendCheckinHistory(key: hk,
                                                 date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                        }
                        // 只有确认今天已签到才写 dateKey=today；
                        // !st.available（活动不可用/token 过期）不写，避免签到流程误判已签
                        UserDefaults.standard.set(today, forKey: dateKey)
                        // 已确认签到成功，清除历史失败残留标记（与 TRAE 侧对齐）
                        UserDefaults.standard.set(false, forKey: UDKey.wbCheckinFailed(ac.uid))
                        UserDefaults.standard.removeObject(forKey: UDKey.wbCheckinFailDate(ac.uid))
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
                UserDefaults.standard.set(timeStr, forKey: UDKey.wbLastCheckinTime)
                let newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak2, today: today)
                UserDefaults.standard.set(newStreak, forKey: streakKey)
                // 解析签到奖励积分（creditDesc 是 String 形式的积分数）
                let credit = Int(r.creditDesc) ?? 0
                if credit > 0 {
                    UserDefaults.standard.set(credit, forKey: rewardKey)
                }
                // 追加历史记录
                appendCheckinHistory(key: UDKey.wbCheckinHistory(ac.uid),
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
                Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_auto_checkin_\(ac.uid)", content: content, trigger: nil)) }
                // 签到成功清除失败标记（含日期口径，用于卡片角标/统计）
                UserDefaults.standard.set(false, forKey: UDKey.wbCheckinFailed(ac.uid))
                UserDefaults.standard.removeObject(forKey: UDKey.wbCheckinFailDate(ac.uid))
            } else {
                // 签到失败：记录失败标记 + 当日日期（用于卡片角标与「x成功 x失败」统计）
                UserDefaults.standard.set(true, forKey: UDKey.wbCheckinFailed(ac.uid))
                UserDefaults.standard.set(today, forKey: UDKey.wbCheckinFailDate(ac.uid))
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
        // 收窄一档：长文规格 width+8（240+8=248，与关于弹窗基准一致），替代 inputWidth(280)
        shell.contentWidth = DialogMetrics.width + 8
        shell.addInfo("OAuth 导入：打开浏览器登录新账号，登录成功后自动采集凭据。\n\nJSON 导入：直接读取你在 WorkBuddy App 中登录的账号。已经登录 App 的话，选择这个即可。")
        let oauth = shell.addButton("OAuth 导入", keyEquivalent: "\r")
        let json = shell.addButton("JSON 导入 (推荐)", tintColor: .systemBlue)
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
        refreshSeq &+= 1
        let importSeq = refreshSeq
        Logger.log(.refresh, "[\(importSeq)] onImportWbAuthFile triggering ad-hoc WB refresh")
        Task { await refreshOneWorkBuddy(config, seq: importSeq) }
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
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_oauth_guide", content: guide, trigger: nil))

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
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_oauth_result", content: content, trigger: nil))

        if success, config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }
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

    /// 签到成功行的 SF Symbol 信息项：状态 + 连续天数 + 奖励积分（0 值项省略）。
    private func checkinInfoItems(alreadyCheckedIn: Bool, streak: Int, reward: Int) -> [CheckinInfoItem] {
        var items = [CheckinInfoItem(symbol: "checkmark.seal", text: alreadyCheckedIn ? "已签到" : "签到成功")]
        if streak > 0 { items.append(CheckinInfoItem(symbol: "flame", text: "\(streak)\u{2009}天")) }
        if reward > 0 { items.append(CheckinInfoItem(symbol: "gift", text: "+\(reward)")) }
        return items
    }

    /// 手动触发全部账号签到：复用 traeAutoCheckinIfNeeded / wbAutoCheckinIfNeeded
    /// （含每日守卫、token 刷新、退避），完成后弹窗汇总各账号签到情况。
    @objc private func onManualCheckin() {
        guard !manualCheckinInProgress else { return }
        manualCheckinInProgress = true
        syncPanel()  // 立即刷新面板：签到磁贴开始脉冲 + 禁点

        let today = Self.todayString()
        // 签到前快照：区分「本次刚签到」vs「今日早已签到」
        var traeBefore: [String: String] = [:]
        for ac in traeCheckinAccounts() {
            traeBefore[ac.uid] = UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(ac.uid)) ?? ""
        }
        var wbBefore: [String: String] = [:]
        for ac in wbCheckinAccounts() {
            wbBefore[ac.uid] = UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(ac.uid)) ?? ""
        }

        Task {
            // 与自动签到完全一致的逻辑链路（每日守卫、token 刷新、退避均生效）；
            // force 绕过两平台错峰就绪时刻：手动一键签到立即全签；
            // 平台开关里关闭了签到的平台，手动签到同样跳过（与自动签到行为一致）
            await withTaskGroup(of: Void.self) { group in
                if config.traeAutoCheckin {
                    group.addTask { await self.traeAutoCheckinIfNeeded(force: true) }
                }
                if config.workbuddyAutoCheckin {
                    group.addTask { await self.wbAutoCheckinIfNeeded(force: true) }
                }
            }

            // ── 汇总各账号签到结果 ──
            var rows: [CheckinResultRow] = []
            var okCount = 0
            var failCount = 0

            for ac in traeCheckinAccounts() {
                let dateKey = UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(ac.uid)) ?? ""
                let failed = UserDefaults.standard.string(forKey: UDKey.traeCheckinFailDate(ac.uid)) == today
                let risk = UserDefaults.standard.string(forKey: UDKey.traeCheckinRiskDate(ac.uid)) == today
                let streak = UserDefaults.standard.integer(forKey: UDKey.traeCheckinStreak(ac.uid))
                let reward = UserDefaults.standard.integer(forKey: UDKey.traeCheckinReward(ac.uid))
                if dateKey == today {
                    let infoItems = checkinInfoItems(alreadyCheckedIn: (traeBefore[ac.uid] ?? "") == today,
                                                     streak: streak, reward: reward)
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：", state: .ok, infoItems: infoItems))
                    okCount += 1
                } else if !config.traeAutoCheckin {
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：已跳过（签到已关闭）", state: .skipped))
                } else if failed || risk {
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：\(risk ? "签到失败（风控）" : "签到失败")", state: .fail))
                    failCount += 1
                } else {
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：未签到（token 失效或退避中）", state: .skipped))
                }
            }
            for ac in wbCheckinAccounts() {
                let dateKey = UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(ac.uid)) ?? ""
                let failed = UserDefaults.standard.string(forKey: UDKey.wbCheckinFailDate(ac.uid)) == today
                let streak = UserDefaults.standard.integer(forKey: UDKey.wbCheckinStreak(ac.uid))
                let reward = UserDefaults.standard.integer(forKey: UDKey.wbCheckinReward(ac.uid))
                if dateKey == today {
                    let infoItems = checkinInfoItems(alreadyCheckedIn: (wbBefore[ac.uid] ?? "") == today,
                                                     streak: streak, reward: reward)
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：", state: .ok, infoItems: infoItems))
                    okCount += 1
                } else if !config.workbuddyAutoCheckin {
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：已跳过（签到已关闭）", state: .skipped))
                } else if failed {
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：签到失败", state: .fail))
                    failCount += 1
                } else {
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：未签到（token 失效或活动不可用）", state: .skipped))
                }
            }

            manualCheckinInProgress = false
            syncPanel()  // 停掉签到磁贴的进行中脉冲（面板已关闭时无害，下次打开即常态）

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
        // 手动签到结果较长，info 容器在输入类弹窗基准上加宽 25pt，减少账号名称换行。
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
        func appendSymbol(_ name: String, color: NSColor) {
            let symbolSize: CGFloat = 11.5
            guard let source = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                  let configured = source.withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium)) else { return }
            // NSTextAttachment 不会稳定继承 surrounding foregroundColor，先把 SF Symbol
            // 显式渲染成与卡片副标题一致的灰色，避免图标在弹窗中出现不同色相/亮度。
            let imageSize = NSSize(width: symbolSize, height: symbolSize)
            let image = NSImage(size: imageSize)
            image.lockFocus()
            color.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()
            configured.draw(in: NSRect(origin: .zero, size: imageSize),
                            from: .zero, operation: .destinationIn, fraction: 1)
            image.unlockFocus()
            let attachment = NSTextAttachment()
            attachment.image = image
            // 让图标与 12pt 正文同高并保持基线视觉居中。
            attachment.bounds = NSRect(x: 0, y: -1.5, width: symbolSize, height: symbolSize)
            attr.append(NSAttributedString(attachment: attachment))
        }
        append("成功\u{2009}\(okCount) · 失败\u{2009}\(failCount)\n\n",
               color: failCount > 0 ? .systemOrange : .secondaryLabelColor)
        for row in rows {
            if !row.infoItems.isEmpty {
                let infoColor = NSColor.systemGray
                append(row.text, color: infoColor)
                for (index, item) in row.infoItems.enumerated() {
                    append(index == 0 ? "\u{2009}" : "\u{2003}", color: infoColor)
                    appendSymbol(item.symbol, color: infoColor)
                    append("\u{2009}\(item.text)", color: infoColor)
                }
                append("\n", color: infoColor)
            } else {
                let (symbol, color): (String, NSColor)
                switch row.state {
                case .ok: (symbol, color) = ("✓  ", .systemGreen)
                case .fail: (symbol, color) = ("✗  ", .systemOrange)
                case .skipped: (symbol, color) = ("–  ", .systemGray)
                }
                append(symbol, color: color)
                append(row.text + "\n", color: row.state == .fail ? .systemOrange : .secondaryLabelColor)
            }
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
            for r in checkinHistory(key: UDKey.traeCheckinHistory(ac.uid)) {
                let reward = r.reward > 0 ? " 积分+\(r.reward)" : ""
                rows.append(Row(date: r.date, time: r.time,
                                text: "\(r.time) TRAE · \(ac.username)\(reward) 连续\(r.streak)天"))
            }
        }
        for ac in wbCheckinAccounts() {
            for r in checkinHistory(key: UDKey.wbCheckinHistory(ac.uid)) {
                let reward = r.reward > 0 ? " 积分+\(r.reward)" : ""
                rows.append(Row(date: r.date, time: r.time,
                                text: "\(r.time) WorkBuddy · \(ac.nickname)\(reward) 连续\(r.streak)天"))
            }
        }
        // 仅显示最近两天（今天 + 昨天）；date 为 yyyy-MM-dd，字符串序即日期序
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Date()).map { Self.dfDay.string(from: $0) } ?? ""
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
        let fillDateKey = UDKey.traeStatusFillDate
        if UserDefaults.standard.string(forKey: fillDateKey) == today { return }
        let mainUid = TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? ""
        // auto-checkin 已开启且主账号今日已签到 → 签到流程会顺带补全 streak/reward，跳过
        if config.traeAutoCheckin && !mainUid.isEmpty
           && UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(mainUid)) == today {
            UserDefaults.standard.set(today, forKey: fillDateKey)
            return
        }
        let accounts = traeCheckinAccounts()
        for ac in accounts {
            let dateKey = UDKey.traeCheckinDate(ac.uid)
            let streakKey = UDKey.traeCheckinStreak(ac.uid)
            let rewardKey = UDKey.traeCheckinReward(ac.uid)
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
                if !checkinHistory(key: UDKey.traeCheckinHistory(ac.uid)).contains(where: { $0.date == today }) {
                    appendCheckinHistory(key: UDKey.traeCheckinHistory(ac.uid),
                                         date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                }
                UserDefaults.standard.set(today, forKey: dateKey)
            }
        }
        UserDefaults.standard.set(today, forKey: UDKey.traeStatusFillDate)
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
            let dateKey = UDKey.traeCheckinDate(ac.uid)
            let streakKey = UDKey.traeCheckinStreak(ac.uid)
            let rewardKey = UDKey.traeCheckinReward(ac.uid)
            let failedKey = UDKey.traeCheckinFailed(ac.uid)
            let retryKey = UDKey.traeNextRetryTime(ac.uid)
            let timeKey = UDKey.traeLastCheckinTime(ac.uid)
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 今天已签到 → 跳过（强本地守卫，零网络）；history 还没有今天的记录时放行，
            // 走下方状态查证补写历史（补上后恢复零网络跳过）
            if UserDefaults.standard.string(forKey: dateKey) == today
               && checkinHistory(key: UDKey.traeCheckinHistory(ac.uid)).contains(where: { $0.date == today }) {
                log("[\(ac.uid)] 已签到，跳过")
                continue
            }
            // 错峰守卫：未到今日就绪时刻的账号本轮跳过（手动一键签到不受限）
            if !force,
               Date().timeIntervalSince1970 < Self.checkinReadyTimestamp(key: UDKey.traeCheckinReady(ac.uid), today: today) {
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

            // 风控日手动重试额度（force 专用）：手动一键签到时对风控账号放行 status/claim 重试，
            // 否则风控退避到明天、当天角标状态永远无法更新；每账号每天最多 maxManualRiskRetriesPerDay 次，
            // 同一轮签到内只消耗一次额度（status/claim 共享），防止反复触发服务端风控
            let riskToday = UserDefaults.standard.string(forKey: UDKey.traeCheckinRiskDate(ac.uid)) == today
            var manualRiskRetryUsed = Self.manualRetryCount(key: UDKey.traeManualRetryCount(ac.uid), today: today)
            var manualRiskRetryGranted = false
            func grantManualRiskRetry() -> Bool {
                if manualRiskRetryGranted { return true }
                guard manualRiskRetryUsed < Self.maxManualRiskRetriesPerDay else { return false }
                manualRiskRetryUsed += 1
                manualRiskRetryGranted = true
                UserDefaults.standard.set("\(today)|\(manualRiskRetryUsed)", forKey: UDKey.traeManualRetryCount(ac.uid))
                return true
            }
            // status 退避：status 查询失败时短退避，避免反复打触发风控
            let statusRetryKey = UDKey.traeStatusRetry(ac.uid)
            if let rt = UserDefaults.standard.object(forKey: statusRetryKey) as? Date, Date() < rt {
                if force && riskToday && grantManualRiskRetry() {
                    log("[\(ac.uid)] status 退避期内，手动重试 \(manualRiskRetryUsed)/\(Self.maxManualRiskRetriesPerDay)")
                } else {
                    log("[\(ac.uid)] status 退避期内，跳过")
                    continue
                }
            }
            let stOpt = await TraeService.fetchCheckinStatus(token: tk, storagePath: config.traeStoragePath)
            guard let st = stOpt else {
                // status 查询失败（网络/风控）：递增退避 5min→10min→…→60min 封顶，
                // 防止 60s 轮询粒度下失败账号被反复重试（风控场景越打越糟）
                let failCountKey = UDKey.traeStatusFailCount(ac.uid)
                let fails = UserDefaults.standard.integer(forKey: failCountKey) + 1
                UserDefaults.standard.set(fails, forKey: failCountKey)
                let backoff = min(TimeInterval(300) * pow(2, Double(fails - 1)), 3600)
                UserDefaults.standard.set(Date().addingTimeInterval(backoff), forKey: statusRetryKey)
                log("[\(ac.uid)] status 查询失败 x\(fails)，退避 \(Int(backoff))s")
                continue
            }
            UserDefaults.standard.set(0, forKey: UDKey.traeStatusFailCount(ac.uid))
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
                    if !checkinHistory(key: UDKey.traeCheckinHistory(ac.uid)).contains(where: { $0.date == today }) {
                        appendCheckinHistory(key: UDKey.traeCheckinHistory(ac.uid),
                                             date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                    }
                    UserDefaults.standard.set(today, forKey: dateKey)
                    UserDefaults.standard.removeObject(forKey: retryKey)
                    UserDefaults.standard.set(false, forKey: failedKey)
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinFailDate(ac.uid))
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinRiskDate(ac.uid))
                    log("[\(ac.uid)] 服务端已签到，补全 streak=\(newStreak) reward=\(newReward)")
                }
                syncPanel()
                continue
            }
            // 退避检查：在退避期内不调 claim，避免频繁请求触发服务端风控。
            // 旧版本风控只写了 failDate（无 riskDate）：检测到「剩余退避 > 30 分钟」的
            // 长退避（普通失败仅退避 5 分钟，只有风控会封顶到明天）即视为存量风控，
            // 补写风控标记迁移口径（角标橙黄、统计计「风控」）——不依赖手动签到，自动轮询即可完成迁移。
            // 风控退避例外：手动签到且当日额度未用完时放行重试（否则当天角标状态永远无法更新）
            if let retryTime = UserDefaults.standard.object(forKey: retryKey) as? Date,
               Date() < retryTime {
                let legacyRiskBackoff = !riskToday && retryTime.timeIntervalSinceNow > 1800
                if legacyRiskBackoff {
                    UserDefaults.standard.set(today, forKey: UDKey.traeCheckinRiskDate(ac.uid))
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinFailDate(ac.uid))
                    log("[\(ac.uid)] 存量风控退避（无风控标记），补写风控标记")
                }
                if force && (riskToday || legacyRiskBackoff) && grantManualRiskRetry() {
                    log("[\(ac.uid)] 风控退避期内，手动重试 \(manualRiskRetryUsed)/\(Self.maxManualRiskRetriesPerDay)")
                } else {
                    log("[\(ac.uid)] 退避期内，跳过（至 \(retryTime)）")
                    continue
                }
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
                appendCheckinHistory(key: UDKey.traeCheckinHistory(ac.uid),
                                     date: today, time: timeStr, reward: reward, streak: newStreak)
                updateAutoCheckinMenuTitle()
                UserDefaults.standard.set(false, forKey: failedKey)
                UserDefaults.standard.removeObject(forKey: retryKey)
                UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinFailDate(ac.uid))
                UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinRiskDate(ac.uid))
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
                Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "trae_auto_checkin_\(ac.uid)", content: content, trigger: nil)) }
            } else {
                // 风控判定：9074（操作太过频繁）是服务端对非客户端流量的传输层风控，
                // 提示文案含「频繁/frequent/rate limit/too many」同理 → 记风控标记
                // （角标橙黄色、统计计「x风控」不计「x失败」），重试无意义，当天不再尝试；
                // 其他失败记失败标记，退避 5 分钟
                let msg = (respJson?["msg"] as? String) ?? (respJson?["message"] as? String) ?? ""
                let lower = msg.lowercased()
                let isRisk = bizCode == 9074 || msg.contains("频繁")
                    || lower.contains("frequent") || lower.contains("rate limit") || lower.contains("too many")
                UserDefaults.standard.set(true, forKey: failedKey)
                if isRisk {
                    UserDefaults.standard.set(today, forKey: UDKey.traeCheckinRiskDate(ac.uid))
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinFailDate(ac.uid))
                } else {
                    UserDefaults.standard.set(today, forKey: UDKey.traeCheckinFailDate(ac.uid))
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinRiskDate(ac.uid))
                }
                let backoff: TimeInterval = isRisk ? Self.secondsUntilTomorrow() : 300
                UserDefaults.standard.set(Date().addingTimeInterval(backoff), forKey: retryKey)
                log("[\(ac.uid)] 签到失败（\(isRisk ? "风控" : "待重试")），退避 \(backoff)s")
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

    // MARK: - Codex 添加账号（JSON 导入）

    /// 从 ~/.codex/auth.json 导入当前登录账号；邮箱直接作为卡片昵称。
    @objc private func onAddCodexAccount() {
        var msg: String
        var success = false
        var isExisting = false
        switch CodexService.importCurrentAccount() {
        case .success(let account):
            if let idx = config.codexAccounts.firstIndex(where: { $0.uid == account.uid }) {
                config.codexAccounts[idx] = account
                isExisting = true
            } else {
                config.codexAccounts.append(account)
            }
            ConfigStore.save(config)
            msg = isExisting
                ? "账号 \(account.email) 已存在，已更新本机凭据"
                : "已添加账号 \(account.email)（共 \(config.codexAccounts.count) 个 Codex 账号）"
            success = true
        case .failure(let err):
            msg = err
        }
        syncPanel()

        let shell = DialogShell()
        if let url = Bundle.main.url(forResource: "codex", withExtension: "svg"),
           let icon = NSImage(contentsOf: url) {
            icon.isTemplate = false
            icon.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            shell.addIcon(icon)
        }
        shell.addTitle(success ? (isExisting ? "账号已存在" : "添加账号成功") : "添加账号失败")
        shell.addInfo(msg)
        shell.addButton("好", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }
        if success { Task { onRefresh() } }
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
        let storagePath = config.traeStoragePath
        performAccountSwitch(serviceName: "TRAE",
                             failureMessage: "写入 storage.json 未成功，已重启恢复原账号") {
            TraeService.switchAccount(account: TraeAccountInfo(
                uid: account.uid,
                username: account.username,
                avatarUrl: "",
                encryptedAuthInfo: account.encryptedAuthInfo,
                token: TraeService.getTokenFromEncrypted(account.encryptedAuthInfo) ?? ""
            ), storagePath: storagePath)
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

    /// 统一编排各平台切号流程：后台执行平台特定的凭据写入/重启，回主线程刷新面板并关闭。
    /// 各平台只提供 action，避免重复实现相同的线程切换、失败提示和收尾逻辑。
    private func performAccountSwitch(serviceName: String,
                                      failureMessage: String,
                                      action: @escaping () -> Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil else { return }
            let ok = action()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !ok {
                    self.notify("\(serviceName) 切号失败", failureMessage)
                } else {
                    self.syncPanel()
                    self.onRefresh()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.popoverController?.close()
                }
            }
        }
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
        performAccountSwitch(serviceName: "WorkBuddy",
                             failureMessage: "写入认证文件未成功，已重启恢复原账号") {
            WorkBuddyService.switchAccount(account)
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
        performAccountSwitch(serviceName: "ZCode",
                             failureMessage: "写入凭据文件未成功，已重启恢复原账号") {
            ZcodeService.switchAccount(account)
        }
    }

    /// 切换 Codex 账号：退出 Codex → 写 ~/.codex/auth.json → 重启 Codex。
    /// 不立即关闭面板，让用户看到卡片上的切换中反馈。
    private func switchCodexAccount(uid: String) {
        Logger.log(.switchAccount, "[iBalance] switchCodexAccount called: uid=\(uid)")
        guard let account = config.codexAccounts.first(where: { $0.uid == uid }) else {
            Logger.log(.switchAccount, "[iBalance] Codex account not found for uid=\(uid)")
            return
        }
        performAccountSwitch(serviceName: "Codex",
                             failureMessage: "写入 ~/.codex/auth.json 未成功，已重启恢复原账号") {
            CodexService.switchAccount(account)
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
            if let t = UserDefaults.standard.string(forKey: UDKey.traeLastCheckinTime(ac.uid)), !t.isEmpty {
                traeTime = Self.latestCheckinTime(trae: traeTime, wb: t) ?? t
            }
        }
        let wbTime = UserDefaults.standard.string(forKey: UDKey.wbLastCheckinTime) ?? ""
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

    /// 日期/数字格式化器缓存：Formatter 创建开销大，这些工具被每次刷新与签到轮询高频调用，
    /// 统一 static let 复用（DateFormatter macOS 10.9+ 线程安全，后台 Task 中也可用）
    private static let dfDay = makeDateFormatter("yyyy-MM-dd")   // 日期（今日/签到日比较）
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

    private static func todayString() -> String {
        dfDay.string(from: Date())
    }

    /// 自动签到错峰：返回账号「今日就绪时间戳」（秒）。key 为该账号的就绪标记 key（UDKey.wb/traeCheckinReady）。
    /// 当天首次遇到该账号时生成 now + 0~600s 随机偏移并持久化（UserDefaults 存 "日期|时间戳"），
    /// 同一天内恒定返回同一值、跨天自动重生成 → 多号在约 10 分钟窗口内随机错开签到，
    /// 避免同一轮询点批量请求触发服务端风控（仿 Cockpit Tools 的 per-account schedule）。
    private static func checkinReadyTimestamp(key: String, today: String) -> TimeInterval {
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
    private static let maxManualRiskRetriesPerDay = 3

    /// 读取风控日手动重试计数（"日期|次数"格式；日期不符自动归零）
    private static func manualRetryCount(key: String, today: String) -> Int {
        guard let saved = UserDefaults.standard.string(forKey: key) else { return 0 }
        let parts = saved.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, parts[0] == today, let n = Int(parts[1]) else { return 0 }
        return n
    }

    private static func nowTimeString() -> String {
        dfTime.string(from: Date())
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
    private static func nextStreak(prevDate: String, prevStreak: Int, today: String) -> Int {
        guard !prevDate.isEmpty else { return 1 }
        guard let p = dfDay.date(from: prevDate), let t = dfDay.date(from: today) else { return 1 }
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

    /// 通用系统通知通道（余额查询失败 / 切号失败回滚等一次性事件共用）：
    /// title 同时用作请求标识（同标题后发替换先发）。服务级刷新失败走面板 footer 标记
    /// （每轮刷新都会失败，发通知会刷屏），不走这里。
    private func notify(_ title: String, _ body: String) {
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

// Controls.swift — iBalance
// 自绘控件:MiniSwitch / MonoSegmented / HoverCard / ActionTileButton 等(自包含)
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)

import Cocoa
import CoreImage

/// 视觉缩放开关：在 .mini 基础上通过 affineTransform 缩至 0.81 倍，使整体更紧凑。
/// AppKit layer-backed 视图经 Auto Layout 同步会把 anchorPoint 重置为 (0,0)，
/// 直接 setAffineTransform 会从左下角缩放导致偏移；这里在 layout() / viewDidMoveToWindow()
/// 里恢复中心锚点 + 补偿 position + 应用缩放，保持开关视觉居中、点击区域不变（frame 不缩小）。
final class MiniSwitch: NSSwitch {
    private let visualScale: CGFloat = 0.81

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlSize = .mini
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTransform()
    }

    override func layout() {
        super.layout()
        applyTransform()
        // AppKit 可能在 layout 同步后重置 layer transform，下一帧再设一次
        DispatchQueue.main.async { [weak self] in
            self?.applyTransform()
        }
    }

    /// 绘制前兜底：NSStackView 布局过程中 frame 多次调整会反复重置 layer transform，
    /// 而 layout() 仅在尺寸变化时触发，调整停止后不再调用 → 只有最后一行开关幸存缩放。
    /// viewWillDraw 每次绘制前必调用，无论被重置多少次都能恢复。
    override func viewWillDraw() {
        super.viewWillDraw()
        applyTransform()
    }

    private func applyTransform() {
        guard let l = layer, l.bounds.width > 0 else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        let target = CGAffineTransform(scaleX: visualScale, y: visualScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if l.anchorPoint != center {
            var p = l.position
            p.x += l.bounds.width * (center.x - l.anchorPoint.x)
            p.y += l.bounds.height * (center.y - l.anchorPoint.y)
            l.anchorPoint = center
            l.position = p
        }
        if l.affineTransform() != target {
            l.setAffineTransform(target)
        }
        CATransaction.commit()
    }

    /// 手动补一次缩放：视图从隐藏恢复显示（NSStackView detach/reattach）时
    /// AppKit 可能重置 layer transform，而尺寸未变不会触发 layout()，需主动调用。
    func applyVisualScale() {
        applyTransform()
    }
}

/// 字符风格开关（Mono 模式专用）：[×] 关 / [▪] 开（U+25AA BLACK SMALL SQUARE）。
/// 全自绘（draw(_:)），与 MonoSegmentedControl 同一渲染机制（attributed string + kern），
/// 消除 NSTextField cell 内边距导致的对齐偏差——两个字符控件直接锚定到各自容器的 trailing。
/// 点击（或 performClick）翻转 state 并发送 action，与 NSSwitch 的 state/target/action 语义一致。
final class MonoCharSwitch: NSControl {
    /// 字号/字重与 MonoSegmentedControl 一致
    private let fontSize: CGFloat = 12
    /// 字符间距（与 MonoSegmentedControl 一致，不用空格破坏等宽对齐）
    private let kern: CGFloat = 2.0
    /// 开关状态（NSControl 的 state 不可覆写，这里自定义同名存储属性，对外语义一致）
    private var _state: NSControl.StateValue = .off
    var state: NSControl.StateValue {
        get { _state }
        set { _state = newValue; needsDisplay = true }
    }
    /// 最近一次 mouseDown 已由控件自身处理（行手势需跳过，防止双重翻转）。
    var lastMouseDownHandled = false

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 单字符渲染宽度（JetBrainsMono 等宽，`[`/`▪`/`×`/`]` 同宽）
    private var charWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MonoFontProvider.font(size: fontSize, weight: .semibold),
        ]
        return ("0" as NSString).size(withAttributes: attrs).width
    }

    /// 内容总宽 = 3 字符 + 2 处 kern（`[`-center, center-`]` 两个间隙）
    private var totalWidth: CGFloat { charWidth * 3 + kern * 2 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: totalWidth, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        // 开用 U+25AA BLACK SMALL SQUARE，关用 ×(U+00D7)
        let text = on ? "[▪]" : "[×]"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MonoFontProvider.font(size: fontSize, weight: .semibold),
            // 选中态亮色用 Palette.cardForeground（#E9E9E9），与折叠标题/余额卡前景一致
            .foregroundColor: on ? Palette.cardForeground : NSColor.secondaryLabelColor,
            .kern: kern,
        ]
        let str = text as NSString
        let sz = str.size(withAttributes: attrs)
        // 控件被约束拉伸时内容居中（与 MonoSegmentedControl 一致）
        let startX = max((bounds.width - sz.width) / 2, 0)
        str.draw(at: NSPoint(x: startX, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }

    override func performClick(_ sender: Any?) {
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }

    override func mouseDown(with event: NSEvent) {
        // 整行手势已覆盖点击；此处兜底保证控件本体点击也可用。
        // 标记本次点击已处理，行手势识别到后跳过（防双重翻转）；
        // 若手势最终未触发（拖拽取消等），延迟清除标志避免吞掉后续点击。
        lastMouseDownHandled = true
        performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.lastMouseDownHandled = false
        }
    }
}

/// 开关行整行点击转发：按当前 Mono 模式翻转可见的那个开关（MonoCharSwitch ↔ NSSwitch）。
/// 若字符开关的 mouseDown 已自行处理本次点击（lastMouseDownHandled），则跳过，
/// 避免与控件本体点击双重翻转抵消。
final class SwitchRowTapHandler: NSObject {
    let sw: MiniSwitch
    let char: MonoCharSwitch
    init(sw: MiniSwitch, char: MonoCharSwitch) { self.sw = sw; self.char = char; super.init() }
    @objc func toggle(_ sender: NSClickGestureRecognizer) {
        if char.lastMouseDownHandled {
            char.lastMouseDownHandled = false
            return
        }
        let active: NSControl = char.isHidden ? sw : char
        active.performClick(nil)
    }
}

/// 字符风格分段控件（Mono 模式专用）：方括号包裹 + 段间制表符竖线分隔 [1│3│5]
/// （│ = U+2502 box drawings light vertical，JetBrainsMono 已覆盖），
/// 与 MonoCharSwitch 的 [▪]/[×] 容器风格一致：方括号与竖线固定淡灰（tertiaryLabelColor），
/// 数字选中 Palette.cardForeground（#E9E9E9）、未选中灰。
/// 用 JetBrainsMono 等宽字体渲染（与 MonoCharSwitch 同设计语言：12pt semibold，略放宽段间距），
/// 点击段切换 selectedSegment 并发送 action，与 NSSegmentedControl 的
/// selectedSegment/target/action 语义一致，便于按 Mono 模式与原生分段控件同框显隐切换。
/// 全自绘（draw(_:)）、无子视图、无 layer transform，避免 AppKit 复杂控件重置问题。
final class MonoSegmentedControl: NSControl {
    private let titles: [String]
    /// 字号/字重与 MonoCharSwitch 一致
    private let fontSize: CGFloat = 12
    /// 字符间距：数值与括号/分隔线之间保留更明确的呼吸空间。
    private let kern: CGFloat = 3.0
    /// 段间制表符竖线（box drawings light vertical，等宽字下为实心竖线）
    private let separator = "│"
    /// 整体包裹方括号（与 MonoCharSwitch 的 [▪]/[×] 容器同风格）
    private let bracket = "["
    /// 当前选中段（-1 = 无选中，语义与 NSSegmentedControl 一致）
    var selectedSegment: Int = -1 {
        didSet { needsDisplay = true }
    }

    init(titles: [String], target: AnyObject?, action: Selector?) {
        self.titles = titles
        super.init(frame: .zero)
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 单段数字渲染宽度（JetBrainsMono 等宽，各段同宽）
    private var digitWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MonoFontProvider.font(size: fontSize, weight: .semibold),
        ]
        return ("0" as NSString).size(withAttributes: attrs).width
    }

    /// 制表符竖线渲染宽度（等宽字体下与数字同宽，但显式测量避免字体差异）
    private var separatorWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MonoFontProvider.font(size: fontSize, weight: .semibold),
        ]
        return (separator as NSString).size(withAttributes: attrs).width
    }

    /// 方括号渲染宽度（等宽字体下与数字同宽）
    private var bracketWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MonoFontProvider.font(size: fontSize, weight: .semibold),
        ]
        return (bracket as NSString).size(withAttributes: attrs).width
    }

    /// 按实际绘制的富文本测量总宽，避免逐字符测量与绘制时重复计算 kern，导致右括号被裁切。
    private var totalWidth: CGFloat {
        ceil(renderedString().size().width)
    }

    private func renderedString() -> NSAttributedString {
        let font = MonoFontProvider.font(size: fontSize, weight: .semibold)
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: kern,
        ]
        let bracketAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Palette.cardForeground,
            .kern: kern,
        ]
        let text = NSMutableAttributedString(string: bracket, attributes: bracketAttrs)
        for (i, title) in titles.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: i == selectedSegment ? Palette.cardForeground : NSColor.secondaryLabelColor,
                .kern: kern,
            ]
            text.append(NSAttributedString(string: title, attributes: attrs))
            if i < titles.count - 1 {
                text.append(NSAttributedString(string: separator, attributes: separatorAttrs))
            }
        }
        // 最后一个字符不再附带 kern，避免测量宽度包含不可见的尾部字距，导致内容视觉偏左。
        let closingAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Palette.cardForeground,
        ]
        text.append(NSAttributedString(string: "]", attributes: closingAttrs))
        return text
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: totalWidth, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = renderedString()
        let size = text.size()
        // 内容右对齐（视觉右缘贴设置行尾，与最初紧凑排版位置一致）；
        // 控件本体撑满 114pt overlay 容器以扩大命中区，视觉排版不受影响。
        let startX = max(bounds.width - size.width, 0)
        text.draw(at: NSPoint(x: startX, y: bounds.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !titles.isEmpty else { return }
        // 命中区约束在 [] 内容区内：内容右对齐，左括号以左的空白不响应点击。
        // 段间命中边界 = 视觉分隔符（│）的中点：
        // 点击数字/方括号/竖线左半 → 竖线左侧的段，竖线右半/右侧数字 → 右侧的段。
        // 排版与 draw/renderedString 一致：[ k 数字 k │ k 数字 k │ k 数字 k ]
        let contentX = bounds.width - totalWidth
        guard p.x >= contentX else { return }
        let step = digitWidth + kern * 2 + separatorWidth
        var idx = titles.count - 1
        for i in 0..<(titles.count - 1) {
            // 第 i 个分隔符（段 i 与 i+1 之间）的左缘与中点
            let sepLeft = contentX + bracketWidth + kern + CGFloat(i) * step + digitWidth + kern
            let sepMid = sepLeft + separatorWidth / 2
            if p.x < sepMid { idx = i; break }
        }
        if selectedSegment != idx {
            selectedSegment = idx
            sendAction(action, to: target)
        }
    }
}

/// 紧凑分段控件：纯使用 AppKit 原生 controlSize/font/segmentWidth 控制尺寸，
/// 不使用任何 layer transform（AppKit 复杂控件会在首次显示时重置 layer 属性导致缩放失效）。
/// 选中段高亮色固定为 #7F7F7F。
/// NSSegmentedControl 的自定义 cell：收窄每段标题的水平内边距。
/// 系统 .mini 分段控件每段内边距约 7pt/侧，「3分钟」@9pt 宽约 25pt，38pt 段下
/// 25 + 14 ≈ 39pt 仍会溢出被省略号截断。这里改由 cell 自绘标题：
/// 水平余量均分居中（约 6.5pt/侧，等价于收窄内边距），38pt 段即可稳定容纳。
final class CompactSegmentedCell: NSSegmentedCell {
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with view: NSView) {
        // 临时清空标题让 super 只画背景/选中 bezel（选中态由 isSelected(forSegment:)
        // 驱动，与标题内容无关），随后按收窄内边距自绘标题，避免双层文字。
        let originalLabel = self.label(forSegment: segment)
        setLabel("", forSegment: segment)
        super.drawSegment(segment, inFrame: frame, with: view)
        setLabel(originalLabel ?? "", forSegment: segment)
        guard let label = originalLabel, !label.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.controlTextColor,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        // 水平：段内余量均分居中；垂直：draw(in:) 实测不垂直居中（偏上约 3pt），
        // 需手动以 (midY - 文本高/2) 定位用 draw(at:)。
        let origin = NSPoint(x: frame.midX - size.width / 2,
                             y: frame.midY - size.height / 2)
        (label as NSString).draw(at: origin, withAttributes: attrs)
    }
}

final class MiniSegmentedControl: NSSegmentedControl {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlSize = .mini
        segmentStyle = .rounded
        appearance = NSAppearance(named: .darkAqua)
        // 选中段高亮色 = #666666（AppKit bezel 会提亮渐变，填暗一档补偿）
        selectedSegmentBezelColor = NSColor(calibratedRed: 0x66/255.0, green: 0x66/255.0, blue: 0x66/255.0, alpha: 1)
        // 监听系统颜色变化通知，在主题色切换时更新 bezel 颜色
        NotificationCenter.default.addObserver(self, selector: #selector(accentColorChanged),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func accentColorChanged() {
        selectedSegmentBezelColor = NSColor(calibratedRed: 0x66/255.0, green: 0x66/255.0, blue: 0x66/255.0, alpha: 1)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 首次进窗口时换成 CompactSegmentedCell（收窄内边距）。此刻 segment 已由
        // init(labels:...) 配置完毕，直接复制配置；target/action/segmentStyle 等状态
        // 在 NSControl/NSSegmentedControl 层，换 cell 不受影响。
        if !(cell is CompactSegmentedCell), let old = cell as? NSSegmentedCell {
            let compact = CompactSegmentedCell()
            compact.segmentCount = old.segmentCount
            compact.trackingMode = old.trackingMode
            compact.controlSize = .mini
            for i in 0..<old.segmentCount {
                compact.setLabel(old.label(forSegment: i) ?? "", forSegment: i)
            }
            // selectedSegment 状态存储在 cell 上，换 cell 会丢失（新 cell 默认 -1 无选中），
            // 首次打开会视觉上"没选中任何段"，必须显式迁移。
            compact.selectedSegment = old.selectedSegment
            cell = compact
        }
        let miniFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        font = miniFont
        cell?.font = miniFont
        for i in 0..<segmentCount {
            setWidth(38, forSegment: i)
        }
        needsLayout = true
    }
}

/// 面板滚动 hover 同步：内容滚动后 AppKit 不会补发 mouseEntered/mouseExited，
/// 面板控制器在滚动时用 AppKit hitTest 判定光标所在视图（与系统 tracking 同源，
/// 无边框浮窗中也可靠——各视图自行 convert 判定曾在浮窗中持续误判），遍历视图树
/// 按外部判定结果同步 hover 状态。
protocol PanelScrollHoverSync: AnyObject {
    /// 按外部（hitTest）判定同步 hover：inside = 光标命中本视图
    func syncHoverState(_ inside: Bool)
}

/// 设置卡片行容器：hover 时仅提亮文本颜色（secondaryLabel/tertiaryLabel → hoverTextColor），
/// switch/radio 等控件保持不变；无背景变化。光标变为 pointingHand 提示可点击。
final class HoverRowView: NSView, PanelScrollHoverSync {
    private var trackingArea: NSTrackingArea?
    /// 当前 hover 状态（滚动同步时用于判断是否需要切换）
    private var isMouseInside = false
    private var labels: [NSTextField] = []
    private var highlightedLabels: [NSTextField] = []
    var hoverTextColor: NSColor = .labelColor
    /// hover 时行背景色（nil = 不绘制背景，保持原文本/tint 提亮行为）
    var hoverBackgroundColor: NSColor? = nil
    /// hover 时行背景渐变（亮→暗端点，与余额卡片 HoverCard 同一套 Palette 常量）；
    /// 设置后优先于 hoverBackgroundColor 平色。层常驻，opacity 淡入淡出。
    var hoverGradientColors: [NSColor]? = nil {
        didSet {
            guard hoverGradientColors != oldValue else { return }
            if let gradient = hoverGradientColors, gradient.count >= 2 {
                hoverGradientLayer.colors = gradient.map { $0.cgColor }
            } else {
                // 清空配置：立即移除渐变层（无动画，避免残留）
                hoverGradientLayer.removeFromSuperlayer()
                hoverGradientInstalled = false
            }
        }
    }
    /// 统一 hover 渐变层：首次进入 hover 时挂载，之后常驻复用
    private let hoverGradientLayer = CAGradientLayer()
    private var hoverGradientInstalled = false
    /// 行背景圆角（hoverBackgroundColor 非 nil 时生效）
    var backgroundCornerRadius: CGFloat = 6
    /// 行 hover 状态回调（用量行用于显示右侧趋势 popover）。
    var onHoverChanged: ((Bool) -> Void)?
    /// hover 时是否对灰色文本/tint 做提亮（false = 仅背景变化，用于用量行等）
    var enablesTextBrightening: Bool = true
    /// hover 时是否绘制发丝边框（与余额卡片 HoverCard 同一套 Palette：常态白@20%、
    /// hover 提亮到白@35%，0.8pt borderWidth，0.22s 渐变）。仅用量行启用，
    /// 设置卡片行保持纯平态。开启时预设 borderColor 避免首帧从黑边渐变。
    var enablesHoverBorder: Bool = false {
        didSet {
            guard enablesHoverBorder != oldValue else { return }
            wantsLayer = true
            if enablesHoverBorder {
                layer?.borderColor = Palette.hoverBorderNormal.cgColor
            } else {
                layer?.borderWidth = 0
                layer?.borderColor = nil
            }
        }
    }
    /// hover 锁定：子面板（趋势图 popover）打开期间锚定行保持高亮，
    /// 鼠标移出仅回调 onHoverChanged(false)（驱动子面板延迟关闭），视觉不退出
    private var hoverLocked = false

    /// 设置 hover 锁定（纯视觉操作，不碰事件状态/回调）：
    /// - 锁定：立即点亮高亮（未 hover 时）
    /// - 解锁：无条件熄灭——解锁只发生在子面板关闭/切换到其他平台行时，
    ///   旧行本就不应保持亮；不能用鼠标位置判定恢复（浮窗中坐标同步被禁用，
    ///   会导致旧行残留高亮、与子面板平台不一致）
    func setHoverLocked(_ locked: Bool) {
        guard locked != hoverLocked else { return }
        hoverLocked = locked
        if locked {
            if !isMouseInside { enterHoverVisual() }
        } else {
            exitHoverVisual()
        }
    }
    /// 需要 hover 提亮的 tint 控件 setter：contentTintColor 为 systemGray 的 NSImageView / NSButton
    /// 跟随整行 hover 提亮为 labelColor，行为与下方选项小字（systemGray 文字）一致。
    /// 用闭包捕获具体类型，使 animator().contentTintColor 能正确解析（NSControl 父类不暴露该属性）。
    private var tintables: [(NSColor) -> Void] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    private func collectLabels() {
        labels = []
        tintables = []
        func scan(_ v: NSView) {
            if let tf = v as? NSTextField { labels.append(tf) }
            else if let iv = v as? NSImageView,
                    iv.contentTintColor == NSColor.systemGray || iv.contentTintColor == NSColor.labelColor {
                tintables.append({ [weak iv] c in iv?.animator().contentTintColor = c })
            }
            else if let btn = v as? NSButton,
                    btn.contentTintColor == NSColor.systemGray || btn.contentTintColor == NSColor.labelColor {
                tintables.append({ [weak btn] c in btn?.animator().contentTintColor = c })
            }
            for sub in v.subviews { scan(sub) }
        }
        scan(self)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        onHoverChanged?(true)
        enterHoverVisual()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        onHoverChanged?(false)
        // hover 锁定（子面板打开期间）：保持高亮视觉，直到子面板关闭解锁。
        // onHoverChanged 照常回调（子面板的延迟关闭逻辑不受影响）
        if hoverLocked { return }
        exitHoverVisual()
    }

    /// 进入 hover 视觉（渐变/背景 + 可选文字提亮）；与事件回调解耦，锁定时复用
    private func enterHoverVisual() {
        if let gradient = hoverGradientColors, gradient.count >= 2 {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.hover)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            wantsLayer = true
            layer?.cornerRadius = backgroundCornerRadius
            layer?.cornerCurve = .continuous
            if !hoverGradientInstalled {
                // 首次挂载：初始透明，靠下方 opacity 赋值淡入
                hoverGradientLayer.frame = bounds
                hoverGradientLayer.colors = gradient.map { $0.cgColor }
                hoverGradientLayer.cornerRadius = backgroundCornerRadius
                hoverGradientLayer.cornerCurve = .continuous
                hoverGradientLayer.opacity = 0
                layer?.addSublayer(hoverGradientLayer)
                hoverGradientInstalled = true
            }
            let pts = Palette.gradientEndpoints(angleDeg: Palette.hoverGradientAngleDeg, in: bounds)
            hoverGradientLayer.startPoint = pts.start
            hoverGradientLayer.endPoint = pts.end
            hoverGradientLayer.opacity = 1
            CATransaction.commit()
        } else if let bg = hoverBackgroundColor {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.hover)
            wantsLayer = true
            layer?.cornerRadius = backgroundCornerRadius
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = bg.cgColor
            CATransaction.commit()
        }
        if enablesHoverBorder {
            wantsLayer = true
            layer?.cornerRadius = backgroundCornerRadius
            layer?.cornerCurve = .continuous
            // 与余额卡片 HoverCard 同款：0.8pt + 白@35% 发丝边框
            animateLayerKey(layer, keyPath: "borderWidth", to: 0.8)
            animateLayerKey(layer, keyPath: "borderColor", to: Palette.hoverBorderBright.cgColor)
        }
        guard enablesTextBrightening else { return }
        collectLabels()
        // 过滤条件必须包含 hoverTextColor：快速进出后再次 enter 时，label 的
        // model 色已是亮色（animator 动画改的是 model 值），漏收集会导致最终
        // 退出时 highlightedLabels 为空、亮色卡死不回落
        highlightedLabels = labels.filter {
            $0.textColor == NSColor.systemGray || $0.textColor == NSColor.tertiaryLabelColor
                || $0.textColor == hoverTextColor
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.hover
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for l in highlightedLabels { l.animator().textColor = self.hoverTextColor }
            for setter in tintables { setter(NSColor.labelColor) }
        }, completionHandler: nil)
    }

    /// 退出 hover 视觉；与事件回调解耦，解锁时无条件调用
    private func exitHoverVisual() {
        if hoverGradientInstalled {
            // 渐变层常驻：淡出而非移除，避免下次进入重建导致的闪烁
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.hover)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            hoverGradientLayer.opacity = 0
            CATransaction.commit()
        }
        if hoverBackgroundColor != nil {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.hover)
            layer?.backgroundColor = nil
            CATransaction.commit()
        }
        if enablesHoverBorder {
            animateLayerKey(layer, keyPath: "borderWidth", to: 0)
            animateLayerKey(layer, keyPath: "borderColor", to: Palette.hoverBorderNormal.cgColor)
        }
        guard enablesTextBrightening else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.hover
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for l in highlightedLabels { l.animator().textColor = NSColor.systemGray }
            for setter in tintables { setter(NSColor.systemGray) }
        }, completionHandler: nil)
        highlightedLabels.removeAll()
    }

    /// 渐变层 frame 不随 AutoLayout 同步，布局时手动贴满 bounds
    override func layout() {
        super.layout()
        if hoverGradientInstalled { hoverGradientLayer.frame = bounds }
    }

    // MARK: - 面板滚动 hover 同步
    func syncHoverState(_ inside: Bool) {
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }
}

/// 无边框图标按钮：使用 macOS 原生 bezelStyle 实现 hover 时自动显示圆角背景，
/// 系统自动处理背景绘制，仅用 tracking area 管理图标颜色变化。
/// hover 时系统渲染浅色圆角背景（略大于图标），图标同步提亮为 labelColor。
final class HoverIconButton: NSButton, PanelScrollHoverSync {
    /// 按钮容器尺寸（正方形）
    static let buttonSize: CGFloat = 22
    private var trackingArea: NSTrackingArea?
    /// 当前 hover 状态（滚动同步时用于判断是否需要切换）
    private var isMouseInside = false
    /// hover 背景独立子 layer：固定正圆（不依赖 self.layer bounds，避免尺寸异常变长方形）
    private let hoverBgLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 无边框按钮：hover 背景自绘（大圆角容器，替代系统 recessed 的小圆角底）
        isBordered = false
        setButtonType(.momentaryPushIn)         // 点击时有按下效果
        imagePosition = .imageOnly
        title = ""
        imageScaling = .scaleProportionallyDown
        contentTintColor = .systemGray
        wantsLayer = true
        hoverBgLayer.masksToBounds = true
        hoverBgLayer.cornerRadius = Self.buttonSize / 2  // 圆角拉满：22×22 → 11pt 正圆
        hoverBgLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hoverBgLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateHoverBgGeometry()
    }

    /// 换窗（popover ↔ 置顶浮窗转移）时 tracking area 拆卸不会派发 mouseExited，
    /// hover 状态与背景动画值会卡在亮色——强制归零；鼠标仍在按钮上时系统会补发 entered
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isMouseInside = false
        contentTintColor = .systemGray
        hoverBgLayer.backgroundColor = NSColor.clear.cgColor
    }

    /// hover 背景几何：固定 buttonSize×buttonSize 正圆居中，不依赖 view bounds。
    private func updateHoverBgGeometry() {
        guard let l = layer, l.bounds.width > 0 else { return }
        let size = Self.buttonSize
        hoverBgLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        hoverBgLayer.position = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
        hoverBgLayer.cornerRadius = size / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        contentTintColor = .labelColor
        // 兜底：确保 hover 背景几何已就位（layout 时序未触发时）
        updateHoverBgGeometry()
        // hover 背景：极淡白底淡入（0.22s，同全项目过渡节奏）
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor",
                        to: NSColor.white.withAlphaComponent(0.12).cgColor)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        contentTintColor = .systemGray
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor", to: NSColor.clear.cgColor)
    }

    // MARK: - 面板滚动 hover 同步
    func syncHoverState(_ inside: Bool) {
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }
}

/// 手动刷新按钮：点击时图标顺时针旋转一圈。
/// AppKit layer-backed 视图经 Auto Layout 同步会把 anchorPoint 重置为 (0,0)，
/// 直接旋转会绕左下角转；需在 layout() 里恢复中心锚点 + 补偿 position（同 MiniSwitch 思路）。
/// hover 自绘圆形白@8% 背景 + 图标 tint 提亮（同 footer HoverIconButton 样式）；
/// 仅按钮自身 hover 生效，行 hover 不驱动任何提亮。
final class RefreshIconButton: NSButton, PanelScrollHoverSync {
    private var isSpinning = false
    private var trackingArea: NSTrackingArea?
    /// 当前 hover 状态（滚动同步时用于判断是否需要切换）
    private var isMouseInside = false
    /// hover 背景独立子 layer：frame 与图标同步偏移 1pt（视觉左下），
    /// 与 self.layer 的旋转动画解耦，避免旋转时背景跟着转。
    private let hoverBgLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        title = ""
        imageScaling = .scaleProportionallyDown
        contentTintColor = .systemGray
        wantsLayer = true
        hoverBgLayer.masksToBounds = true
        hoverBgLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hoverBgLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 图标视觉偏移：draw 平移 -3,-1（整体左移 2pt + 原下偏 1pt），
    /// hover 背景圆由 layer 绘制（bounds 原位居中），不随平移。
    override func draw(_ dirtyRect: NSRect) {
        let t = NSAffineTransform()
        t.translateX(by: -3, yBy: isFlipped ? 1 : -1)
        t.concat()
        super.draw(dirtyRect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreCenterAnchor()
        // 换窗（popover ↔ 置顶浮窗转移）不派发 mouseExited，hover 卡亮一并归零
        //（同 HoverIconButton）；鼠标仍在按钮上时系统会补发 mouseEntered
        isMouseInside = false
        contentTintColor = .systemGray
        hoverBgLayer.backgroundColor = NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        restoreCenterAnchor()
        updateHoverBgGeometry()
        // AppKit 可能在 layout 同步后重置 layer 属性，下一帧再修一次
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreCenterAnchor()
            self.updateHoverBgGeometry()
        }
    }

    /// hover 背景几何：固定 16×16 正圆（不依赖 view bounds，避免尺寸异常变长方形），
    /// 用 transform 偏移 1pt（视觉左下），transform 不被 AppKit layer 布局重置。
    private func updateHoverBgGeometry() {
        guard let l = layer, l.bounds.width > 0 else { return }
        let size: CGFloat = 16
        hoverBgLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        hoverBgLayer.position = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
        hoverBgLayer.cornerRadius = size / 2
        hoverBgLayer.transform = CATransform3DMakeTranslation(-3, isFlipped ? 1 : -1, 0)
    }

    /// 恢复 layer 锚点 + 补偿 position，使旋转绕图标视觉圆心。
    /// 图标经 draw(_:) 偏移 -3,-1 后视觉圆心 = (5, 6.04)，上移 0.4pt → y=6.44，
    /// anchorPoint：x=5/16=0.3125，y=6.44/16≈0.4025。
    private func restoreCenterAnchor() {
        guard let l = layer, l.bounds.width > 0 else { return }
        let center = CGPoint(x: 0.3125, y: 0.4025)
        guard l.anchorPoint != center else { return }
        var p = l.position
        p.x += l.bounds.width * (center.x - l.anchorPoint.x)
        p.y += l.bounds.height * (center.y - l.anchorPoint.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.anchorPoint = center
        l.position = p
        CATransaction.commit()
    }

    /// 点击发送 action 时顺时针旋转一圈（-2π，0.45s ease-in-out）
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        spinOnce()
        return super.sendAction(action, to: target)
    }

    private func spinOnce() {
        guard let l = layer, !isSpinning else { return }
        restoreCenterAnchor()
        isSpinning = true
        // macOS NSView（isFlipped=false）layer 坐标系 y 向上，rotation.z 正值=屏幕逆时针；
        // arrow.clockwise 箭头朝顺时针，故用负角 -2π 让屏幕上呈顺时针旋转。
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = -CGFloat.pi * 2
        anim.duration = 0.45
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = true
        anim.delegate = self
        l.add(anim, forKey: "spinOnce")
    }

    // MARK: - hover 背景
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        // 兜底：确保 hover 背景几何已就位（layout 时序未触发时）
        updateHoverBgGeometry()
        // hover 背景：极淡白底淡入 + 图标 tint 提亮（0.22s，同全项目过渡节奏）
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor",
                        to: NSColor.white.withAlphaComponent(0.12).cgColor)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.hover
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().contentTintColor = .labelColor
        }, completionHandler: nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor", to: NSColor.clear.cgColor)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.hover
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().contentTintColor = .systemGray
        }, completionHandler: nil)
    }

    // MARK: - 面板滚动 hover 同步
    func syncHoverState(_ inside: Bool) {
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }
}

extension RefreshIconButton: CAAnimationDelegate {
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        isSpinning = false
    }
}

/// 余额卡片容器：hover 时显示 8% 背景圆角，并切换签到信息子视图颜色。
/// 点击卡片触发 onClick 回调（如打开对应平台主页或应用）。
class HoverCard: NSView, PanelScrollHoverSync {
    private var trackingArea: NSTrackingArea?
    private weak var dragContentView: NSView?
    private var dragNormalBackgroundColor: CGColor?
    private var hasCapturedDragBackground = false
    private var isMouseInside = false
    private var isDragHoverLocked = false
    /// 点击回调：由外部设置，mouseUp 时触发
    var onClick: (() -> Void)?
    /// 右键点击回调：由外部设置，rightMouseDown 时触发（参数为事件，可用于弹出菜单定位）
    var onRightClick: ((NSEvent) -> Void)?
    /// 拖拽回调：设置后，整张卡片都可用于排序拖拽。
    var onDragStarted: ((NSPoint) -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    /// hover 状态回调：true=进入，false=离开（如「悬停显示昵称」）
    var onHover: ((Bool) -> Void)?
    /// hover 效果容器：背景色 + 边框统一淡入淡出
    private let hoverEffectLayer = CALayer()
    /// hover 背景层：统一 hover 渐变（Palette.hoverGradient*）
    private let hoverGradientLayer = CAGradientLayer()

    var dragContentLayer: CALayer? { dragContentView?.layer }

    func configureDragContentView(_ view: NSView) {
        view.wantsLayer = true
        dragContentView = view
        if !hasCapturedDragBackground {
            dragNormalBackgroundColor = layer?.backgroundColor
            hasCapturedDragBackground = true
        }
    }

    func setDragContentOpacity(_ opacity: Float) {
        dragContentView?.wantsLayer = true
        dragContentView?.layer?.opacity = opacity
    }

    /// 幽灵卡片移除后，实际卡片可能没有收到新的 mouseEntered/mouseExited，
    /// 因此归位时必须用窗口当前光标位置重新判断 hover，而不是只依赖旧状态。
    private func isPointerInsideCard() -> Bool {
        guard let window else { return isMouseInside }
        let point = convert(window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin, from: nil)
        return point != .zero && bounds.contains(point)
    }

    // MARK: - 面板滚动 hover 同步
    /// 滚动后 AppKit 不补发 enter/exit：按外部（hitTest）判定同步。
    /// 拖拽锁定期间跳过（材质由 setDragHoverLocked 全权管理）。
    func syncHoverState(_ inside: Bool) {
        guard !isDragHoverLocked else { return }
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }

    /// 拖拽期间锁住 hover 材质，避免卡片随幽灵位置移动到光标下方时重新淡入变亮。
    /// 归位交接时传入 animated=false，直接切换到最终状态，避免与幽灵卡片重叠一帧。
    func setDragHoverLocked(_ locked: Bool, animated: Bool = true) {
        guard isDragHoverLocked != locked else { return }
        isDragHoverLocked = locked
        if locked {
            hoverEffectLayer.removeAnimation(forKey: "opacityTransition")
            layer?.removeAnimation(forKey: "borderWidthTransition")
            layer?.removeAnimation(forKey: "borderColorTransition")
            // 占位卡片只保留静态内容，不继承按下拖动前已经存在的 hover 材质。
            // 关闭隐式动画，避免从 hover 状态切到占位状态时再闪一帧。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverEffectLayer.opacity = 0
            hoverEffectLayer.isHidden = true
            layer?.backgroundColor = dragNormalBackgroundColor ?? kCardBackground.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = Palette.hoverBorderNormal.cgColor
            CATransaction.commit()
            return
        }

        let showing = isPointerInsideCard()
        isMouseInside = showing
        hoverEffectLayer.isHidden = false
        layer?.backgroundColor = dragNormalBackgroundColor ?? kCardBackground.cgColor
        if !animated {
            hoverEffectLayer.removeAnimation(forKey: "opacityTransition")
            layer?.removeAnimation(forKey: "borderWidthTransition")
            layer?.removeAnimation(forKey: "borderColorTransition")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverEffectLayer.opacity = showing ? 1 : 0
            layer?.borderWidth = showing ? 0.8 : 0
            layer?.borderColor = (showing ? Palette.hoverBorderBright : Palette.hoverBorderNormal).cgColor
            CATransaction.commit()
            onHover?(showing)
            return
        }
        animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: showing ? 1 : 0)
        animateLayerKey(layer, keyPath: "borderWidth", to: showing ? 0.8 : 0)
        animateLayerKey(layer, keyPath: "borderColor",
                        to: (showing ? Palette.hoverBorderBright : Palette.hoverBorderNormal).cgColor)
        onHover?(showing)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHoverGradient()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupHoverGradient() {
        wantsLayer = true
        // 统一 hover 渐变背景：Palette.hoverGradient*（余额卡片/磁贴/折叠标题条/用量条目共用）
        hoverGradientLayer.colors = Palette.hoverGradient.map { $0.cgColor }
        hoverEffectLayer.opacity = 0
        hoverEffectLayer.addSublayer(hoverGradientLayer)
        layer?.addSublayer(hoverEffectLayer)
    }

    /// 子层 frame 不随 AutoLayout 同步，布局时手动贴满 bounds（圆角由父 layer masksToBounds 裁出）
    override func layout() {
        super.layout()
        hoverEffectLayer.frame = bounds
        hoverGradientLayer.frame = hoverEffectLayer.bounds
        let pts = Palette.gradientEndpoints(angleDeg: Palette.hoverGradientAngleDeg, in: bounds)
        hoverGradientLayer.startPoint = pts.start
        hoverGradientLayer.endPoint = pts.end
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    /// 点击后鼠标通常仍停留在卡片内，AppKit 不会重新派发 mouseExited；
    /// 主动清除 hover 材质，避免点击可折叠标题后高亮一直残留。
    func clearHoverEffect(animated: Bool = true) {
        isMouseInside = false
        guard !isDragHoverLocked else { return }
        if animated {
            animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: 0)
            animateLayerKey(layer, keyPath: "borderWidth", to: 0)
            animateLayerKey(layer, keyPath: "borderColor", to: Palette.hoverBorderNormal.cgColor)
        } else {
            hoverEffectLayer.removeAnimation(forKey: "opacityTransition")
            layer?.removeAnimation(forKey: "borderWidthTransition")
            layer?.removeAnimation(forKey: "borderColorTransition")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverEffectLayer.opacity = 0
            layer?.borderWidth = 0
            layer?.borderColor = Palette.hoverBorderNormal.cgColor
            CATransaction.commit()
        }
        onHover?(false)
    }

    /// 可排序卡片不把事件命中交给内部 label、图标等子视图，确保整张卡片都能开始拖拽。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if onDragStarted != nil, bounds.contains(point) {
            return self
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onDragStarted != nil {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        if isDragHoverLocked { return }
        // hover 背景淡入（与用量条目同色）
        animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: 1)
        // 发丝边框淡入：0.8pt + 边框色提亮到 Palette.hoverBorderBright
        animateLayerKey(layer, keyPath: "borderWidth", to: 0.8)
        animateLayerKey(layer, keyPath: "borderColor", to: Palette.hoverBorderBright.cgColor)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        if isDragHoverLocked { return }
        // hover 背景淡出，露出容器统一背景
        animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: 0)
        animateLayerKey(layer, keyPath: "borderWidth", to: 0)
        animateLayerKey(layer, keyPath: "borderColor", to: Palette.hoverBorderNormal.cgColor)
        onHover?(false)
    }

    /// 点击卡片：mouseDown 记录按下位置，mouseUp 在 bounds 内时触发回调（避免拖出后误触）
    override func mouseDown(with event: NSEvent) {
        guard onDragStarted != nil, let window else {
            // 不调用 super：避免被当作无意义点击传给父视图
            return
        }

        let start = event.locationInWindow
        var dragging = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture,
                                          inMode: .eventTracking,
                                          dequeue: true) {
            if next.type == .leftMouseDragged {
                if !dragging {
                    let current = next.locationInWindow
                    let distance = hypot(current.x - start.x, current.y - start.y)
                    guard distance >= 3 else { continue }
                    dragging = true
                    NSCursor.closedHand.push()
                    onDragStarted?(current)
                }
                onDragChanged?(next.locationInWindow)
            } else if next.type == .leftMouseUp {
                if dragging {
                    onDragChanged?(next.locationInWindow)
                    onDragEnded?()
                    NSCursor.pop()
                } else {
                    onClick?()
                }
                return
            }
        }

        // 窗口关闭等异常情况下也要恢复拖拽状态，避免光标栈残留。
        if dragging {
            onDragEnded?()
            NSCursor.pop()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 不调用 super：由 onRightClick 接管，弹出上下文菜单
        onRightClick?(event)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) {
            onClick?()
        }
    }
}

/// 操作磁贴按钮：纵向 icon + 多行文本（最多两行）。
/// 继承 HoverCard：hover 效果与余额卡片完全统一（hover 背景色、0.8pt white@20% 发丝边框、
/// bounds 内 mouseUp 触发），叠加磁贴特有的 icon 软光晕。
final class ActionTileButton: HoverCard {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// 目标-动作（与 NSButton 兼容，支持后续赋值）
    var target: AnyObject?
    var action: Selector?
    /// 进行中（脉冲 + 禁点）状态标记
    private var isInProgress = false
    /// icon 固定尺寸
    private let iconSize: CGFloat

    /// svgIconSize：SVG 品牌图的视觉微调尺寸（如 ZCode 14.45 ≈ 0.9×），
    /// 仅作用于 SVG——Mono ASCII 始终按盒尺寸 iconSize 烘焙，各磁贴大小一致
    init(symbol: String? = nil, bundleIcon iconName: String? = nil, title: String, target: AnyObject?, action: Selector?, iconSize: CGFloat = 16, svgIconSize: CGFloat? = nil) {
        self.iconSize = iconSize
        super.init(frame: .zero)
        self.target = target
        self.action = action
        // 点击经 HoverCard.onClick 触发（target/action 可在 init 后再赋值，闭包点击时取最新值）
        onClick = { [weak self] in
            guard let self, let action = self.action else { return }
            _ = self.target?.perform(action, with: self)
        }
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // 边框色与卡片统一 white@20%（hover 时由 HoverCard 动画 borderWidth 到 0.8）
        layer?.borderColor = Palette.hoverBorderNormal.cgColor
        layer?.borderWidth = 0

        // 只缩不放：SVG 微调尺寸（如 14.45）在 16pt 盒内保持原大居中，
        // 不会被放大抹掉微调；Mono ASCII（1.25:1）按盒等比缩小
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.masksToBounds = false
        // icon 软光晕：hover 时淡入阴影，营造高级质感（硬编码中性灰，不随系统强调色）
        iconView.layer?.shadowColor = NSColor(calibratedWhite: 0.62, alpha: 1.0).cgColor
        iconView.layer?.shadowRadius = 6
        iconView.layer?.shadowOffset = .zero
        iconView.layer?.shadowOpacity = 0.0
        // 优先使用 bundle 内自定义 SVG（stroke=currentColor，isTemplate 跟随 tint 变色）
        if let name = iconName, let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            // SVG 用微调尺寸（缺省 = 盒尺寸）；Mono ASCII 用 iconSize，互不影响
            let brandSize = svgIconSize ?? iconSize
            img.size = NSSize(width: brandSize, height: brandSize)
            iconView.image = img
            iconView.contentTintColor = Palette.cardForeground
        } else if let s = symbol, let sym = NSImage(systemSymbolName: s, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
            sym.isTemplate = true
            // 强制 size = iconSize，避免 SF Symbol 的 alignmentRect 顶部留白导致视觉偏上
            sym.size = NSSize(width: iconSize, height: iconSize)
            iconView.image = sym
            iconView.contentTintColor = Palette.cardForeground
        }
        label.font = .systemFont(ofSize: 9)
        // 文本用石墨灰系统语义色（弱于 icon 的 Palette.cardForeground，降低存在感）
        label.textColor = .systemGray
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = true
        label.setContentHuggingPriority(.defaultLow, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false

        // 纵向 stack：icon + label 垂直居中
        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
        ])

        setTitle(title)
        // 磁贴文本最多两行且会截断，toolTip 展示完整动作名（HIG：图标类控件应有悬停提示）
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) {
        // 文本始终石墨灰、icon 始终 Palette.cardForeground，无高亮态
        label.stringValue = title
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)  // 卡片同款：hover 背景色、发丝边框
        // 磁贴特有：icon 软光晕
        animateLayerKey(iconView.layer, keyPath: "shadowOpacity", to: 0.45, duration: Motion.hover)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        animateLayerKey(iconView.layer, keyPath: "shadowOpacity", to: 0.0, duration: Motion.hover)
    }

    override func mouseUp(with event: NSEvent) {
        // 进行中不可重复触发（主流程侧另有状态守卫，这里拦掉视觉层点击）
        guard !isInProgress else { return }
        super.mouseUp(with: event)  // HoverCard：bounds 内触发 onClick
    }

    /// 进行中状态：true 时禁点 + 背景呼吸脉冲（手动签到/账号采集等长任务的通用反馈）
    func setInProgress(_ on: Bool) {
        guard on != isInProgress else { return }
        isInProgress = on
        if on {
            // 背景在白 5%↔14% 间呼吸（与 hover 底色同族，避免视觉突兀），
            // autoreverses + infinity 持续到任务结束；模型值先落 5% 保证动画移除后不闪清
            let pulse = CABasicAnimation(keyPath: "backgroundColor")
            pulse.fromValue = NSColor.white.withAlphaComponent(0.05).cgColor
            pulse.toValue = NSColor.white.withAlphaComponent(0.14).cgColor
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            layer?.add(pulse, forKey: "progressPulse")
        } else {
            layer?.removeAnimation(forKey: "progressPulse")
            // 恢复常态底色（若此刻正悬停，hover 渐变层照常覆盖在上）
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// 半透明遮罩视图：用 draw(_:) 而非 layer.backgroundColor 渲染色块。
/// NSView 的 backing layer 在加入 window 前可能为 nil，直接 set backgroundColor 会失效；
/// draw 由 AppKit 在确定进入渲染层级后调用，能可靠地呈现颜色。
/// 设置 bottomColor 后改为纵向渐变绘制：顶部 color（暗）→ 底部 bottomColor（中灰），
/// gradientStartY 指定渐变起点（距顶部 pt，起点以上保持纯暗色，与渐变起点无缝衔接）。
final class TintOverlayView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }
    var bottomColor: NSColor? { didSet { needsDisplay = true } }
    /// 渐变起始位置（距视觉顶部的 pt 数，isFlipped 语义：顶部为 0）；默认 0 = 从顶部渐变
    var gradientStartY: CGFloat = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = color else { return }
        if let b = bottomColor {
            let startY = min(max(bounds.minY + gradientStartY, bounds.minY), bounds.maxY)

            // 固定区域只绘制到渐变起点。不能先填满整个 bounds 再绘制渐变，
            // 否则渐变起点的半透明 c 会叠加在已有的 c 上，导致起点比上方固定区域更深。
            if startY > bounds.minY {
                c.setFill()
                NSBezierPath(rect: NSRect(x: bounds.minX,
                                           y: bounds.minY,
                                           width: bounds.width,
                                           height: startY - bounds.minY)).fill()
            }

            guard startY < bounds.maxY else { return }
            // isFlipped=true 时 minY 在顶部：colors[0]（暗）→ 渐变起点，colors[1]（中灰）→ 底部
            NSGradient(colors: [c, b])?.draw(from: NSPoint(x: bounds.midX, y: startY),
                                             to: NSPoint(x: bounds.midX, y: bounds.maxY),
                                             options: [])
        } else {
            c.setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }
}

/// 带遮罩的毛玻璃容器：在 NSVisualEffectView 毛玻璃之上叠一层半透明 NSView，
/// 用 draw(_:) 渲染，保留玻璃透明质感的同时加深底色（无色相）。
final class TintedVisualEffectView: NSVisualEffectView {
    private let tintView = TintOverlayView()

    var tintColor: NSColor? {
        didSet { tintView.color = tintColor }
    }

    /// 渐变底部色：设置后遮罩从 tintColor（顶部，暗）纵向渐变到此色（底部，中灰）
    var tintBottomColor: NSColor? {
        didSet { tintView.bottomColor = tintBottomColor }
    }

    /// 渐变起始位置（距容器顶部的 pt 数，0 = 从顶部渐变；起点以上保持纯暗色）
    var tintGradientStartY: CGFloat = 0 {
        didSet {
            guard abs(oldValue - tintGradientStartY) > 0.5 else { return }
            tintView.gradientStartY = tintGradientStartY
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTintView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTintView()
    }

    private func setupTintView() {
        tintView.translatesAutoresizingMaskIntoConstraints = false
        // 作为第一个子视图插入（在 panel 内容之下，毛玻璃之上）
        addSubview(tintView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// 手动签到结果行状态：成功 / 失败 / 跳过（token 失效、退避中等）
enum CheckinRowState { case ok, fail, skipped }

/// 手动签到结果行中的 SF Symbol 信息项，与余额卡片副标题保持一致。
struct CheckinInfoItem {
    let symbol: String
    let text: String
}

/// 手动签到结果行：状态符号 + 文本（由手动签到结果弹窗渲染）
struct CheckinResultRow {
    let text: String
    let state: CheckinRowState
    let infoItems: [CheckinInfoItem]

    init(text: String, state: CheckinRowState, infoItems: [CheckinInfoItem] = []) {
        self.text = text
        self.state = state
        self.infoItems = infoItems
    }
}

/// 提示层贴靠边：bottom = 面板底缘（下方还有内容），top = 面板顶缘（上方还有内容）
enum FadeHintEdge { case top, bottom }

/// 滚动提示层可调参数（config.json 持久化；「滚动提示」弹窗滑杆实时预览）
struct FadeHintParams: Equatable {
    /// 提示条带高度（pt）
    var bandHeight: Double = 54
    /// 贴靠边高光渐变最亮处 alpha
    var highlightAlpha: Double = -0.6
    /// 底色遮罩 50% 处 alpha（贴靠边恒为 1）
    var maskMidAlpha: Double = 0.45
    /// 箭头描边 alpha
    var arrowAlpha: Double = 0.75
    /// 箭头浮动幅度（pt，2s 周期）
    var bobAmplitude: Double = 2
}

/// 面板顶/底缘「还有内容」提示层：半透明底色渐变遮罩 + 透明白高光
/// 渐变 + 指向箭头（2s 周期轻微浮动，top 指上 / bottom 指下）。
/// 由控制器在内容超出视口且未滚到对应边缘时显示；纯视觉层，鼠标/滚轮事件全部穿透。
/// （原磨砂快照 + CIGaussianBlur 方案已移除，现为纯静态遮罩，无需滚动时刷新）
final class ScrollFadeHint: NSView {
    override var isFlipped: Bool { true }

    let edge: FadeHintEdge

    /// 可调参数（调参弹窗滑杆拖动时实时赋值 → applyParams 即时生效）
    var params = FadeHintParams() {
        didSet {
            guard oldValue != params else { return }
            applyParams()
        }
    }

    /// 底色遮罩层：半透明容器色，mask 控制不透明度渐变（贴靠边最深 → 对侧透明）
    private let tintLayer = CALayer()
    private let tintMaskLayer = CAGradientLayer()
    private let gradientLayer = CAGradientLayer()
    /// darken 蒙版：负值高光时作为 gradientLayer 的 mask，控制透明度渐变；
    /// 灰阶本身均匀无 RGB 插值，渐变只发生在蒙版 alpha，避免渐变带状/ muddy。
    private let gradientMaskLayer = CAGradientLayer()
    private let arrowLayer = CAShapeLayer()
    private var isShown = false

    init(edge: FadeHintEdge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        // 本视图翻转坐标系（y=0 在顶）；贴靠边的 y：top=0，bottom=1
        let nearY: CGFloat = edge == .top ? 0 : 1
        let farY: CGFloat = edge == .top ? 1 : 0
        // 底色遮罩层最底：半透明近黑打底。
        // 专用色而非 Palette.containerTint：提示层要比面板容器底更透，避免滚动提示发黑发重
        tintLayer.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.22).cgColor
        tintMaskLayer.locations = [0, 0.5, 1]
        tintMaskLayer.startPoint = CGPoint(x: 0.5, y: farY)
        tintMaskLayer.endPoint = CGPoint(x: 0.5, y: nearY)
        tintLayer.mask = tintMaskLayer
        layer?.addSublayer(tintLayer)
        gradientLayer.locations = [0, 0.5, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: farY)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: nearY)
        layer?.addSublayer(gradientLayer)
        // darken 蒙版：与高光同向（对侧透明 → 贴靠边满），applyParams 负值分支挂到 gradientLayer.mask
        gradientMaskLayer.locations = [0, 0.5, 1]
        gradientMaskLayer.startPoint = CGPoint(x: 0.5, y: farY)
        gradientMaskLayer.endPoint = CGPoint(x: 0.5, y: nearY)
        // 箭头：圆角折线 chevron，bottom 指下 / top 指上（路径 y 向下，以 bounds 左上为原点）
        arrowLayer.fillColor = nil
        arrowLayer.lineWidth = 1.8
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round
        arrowLayer.bounds = CGRect(x: 0, y: 0, width: 9, height: 4.2)
        let tipY: CGFloat = edge == .top ? 0 : 4.2
        let baseY: CGFloat = edge == .top ? 4.2 : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: baseY))
        path.addLine(to: CGPoint(x: 4.5, y: tipY))
        path.addLine(to: CGPoint(x: 9, y: baseY))
        arrowLayer.path = path
        layer?.addSublayer(arrowLayer)
        applyParams()
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 参数变化即时生效：颜色/渐变重设 + 浮动动画按新幅度重建
    /// （bandHeight 由 VC 的约束更新）
    private func applyParams() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 底色遮罩不透明度：0（对侧）→ maskMidAlpha（50%）→ 1（贴靠边）
        tintMaskLayer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(params.maskMidAlpha).cgColor,
            NSColor.white.cgColor,
        ]
        // 高光渐变：
        //  · 正值 → 白色高光，Normal 混合（常规提亮）：透明度直接编码在渐变颜色 alpha 里。
        //  · 负值 → 灰阶 + Photoshop「变暗 Darken」混合模式：逐通道取 min(底色, 灰阶)，
        //           已暗通道保持原样、仅压暗亮于灰阶的通道，因此比直接叠黑色更保留内容色相。
        //    关键：darken 的透明度渐变放进 gradientMaskLayer（纯 alpha 蒙版，无 RGB 插值），
        //          gradientLayer 本身只铺均匀灰阶（backgroundColor）+ compositingFilter，
        //          避免渐变颜色插值与混合模式叠加产生带状/ muddy。
        //    灰阶：darken 即「变暗」，源灰阶本应偏暗——不再是 1−|alpha| 的近白灰，
        //          取 0.3×(1−|alpha|)（下限 0.05，−0.7 → 0.09），始终落在暗灰区间。
        //    强度：由蒙版 alpha 随 |alpha| 缩放（对侧 0 → 贴靠边 |alpha|），曲线 0 → 0.39 → 1 同高光形状；
        //          |alpha| 越大、灰阶越暗 + 蒙版越满，效果越深。
        //    说明：纯黑源在 Darken 下与 Normal 等价（min(底,0)=0），故下限保留 0.05 而非 0。
        let hiAbs = abs(params.highlightAlpha)
        if params.highlightAlpha >= 0 {
            gradientLayer.compositingFilter = nil
            gradientLayer.mask = nil
            gradientLayer.backgroundColor = nil
            gradientLayer.colors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(hiAbs * 0.39).cgColor,
                NSColor.white.withAlphaComponent(hiAbs).cgColor,
            ]
        } else {
            gradientLayer.compositingFilter = CIFilter(name: "CIDarkenBlendMode")
            // 均匀暗灰铺底（无渐变颜色），透明度交给蒙版
            let grayLevel = CGFloat(max(0.05, 0.3 * (1 - hiAbs)))
            gradientLayer.colors = nil
            gradientLayer.backgroundColor = NSColor(white: grayLevel, alpha: 1).cgColor
            // darken 蒙版：对侧透明 → 贴靠边，强度随 |alpha| 缩放（曲线 0 → 0.39 → 1 同高光形状）
            let peak = min(1, hiAbs)
            gradientMaskLayer.colors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0.39 * peak).cgColor,
                NSColor.white.withAlphaComponent(peak).cgColor,
            ]
            gradientLayer.mask = gradientMaskLayer
        }
        arrowLayer.strokeColor = NSColor.white.withAlphaComponent(params.arrowAlpha).cgColor
        CATransaction.commit()
        // 浮动幅度变化：重建动画（正在显示时立即以新幅度浮动）
        arrowLayer.removeAnimation(forKey: "fadeHintBob")
        updateBobAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        tintMaskLayer.frame = CGRect(origin: .zero, size: bounds.size)
        gradientLayer.frame = bounds
        gradientMaskLayer.frame = CGRect(origin: .zero, size: bounds.size)
        // 箭头偏向贴靠边：top 层放 0.36 高度处（靠上），bottom 层放 0.64（靠下）
        let yRatio = edge == .top ? 0.36 : 0.64
        arrowLayer.position = CGPoint(x: bounds.midX, y: bounds.height * yRatio)
        CATransaction.commit()
    }

    private func updateBobAnimation() {
        let key = "fadeHintBob"
        if isShown && arrowLayer.animation(forKey: key) == nil {
            // 1s 单程 + 自动回返 = 2s 完整周期，与全局脉冲节奏一致；
            // 浮动方向朝贴靠边外：bottom 向下(+)，top 向上(−)
            let amp = CGFloat(params.bobAmplitude)
            guard amp > 0 else { return }
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0
            bob.toValue = edge == .top ? -amp : amp
            bob.duration = 1.0
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arrowLayer.add(bob, forKey: key)
        } else if !isShown {
            arrowLayer.removeAnimation(forKey: key)
        }
    }

    /// 显示/隐藏提示层（0.22s easeInEaseOut，与全局 hover 过渡一致）
    func setShown(_ shown: Bool) {
        guard isShown != shown else { return }
        isShown = shown
        updateBobAnimation()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.hover
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = shown ? 1 : 0
        }
    }

    /// 纯指示层：不参与命中测试，滚轮与点击穿透到下方滚动内容
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 置顶浮窗右下角 resize 把手：自绘两条 45° 斜线 + 承载拖拽 resize。
/// 浮窗是 borderless + nonactivating（不能加 .resizable：macOS 26 下无边框面板
/// 无系统边缘热区，且有空闲 CPU 飙高的系统 bug），resize 由本视图自绘实现。
final class PanelResizeHandle: NSView {
    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 480
    static let minHeight: CGFloat = 220

    /// 拖动结束且尺寸有变化时上报最终窗口尺寸（AppDelegate 持久化到 config）
    var onResizeEnded: ((NSSize) -> Void)?

    private var hovered = false
    private var trackingArea: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        let color = (hovered ? NSColor.labelColor : NSColor.systemGray).withAlphaComponent(0.9)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        // 两条 45° 斜线（右下朝向），长 6pt、间隔 4pt，贴角落内缩 2.5pt
        let inset: CGFloat = 2.5
        let len: CGFloat = 6
        for offset in [CGFloat(0), CGFloat(4)] {
            path.move(to: NSPoint(x: bounds.maxX - inset - len - offset, y: bounds.minY + inset))
            path.line(to: NSPoint(x: bounds.maxX - inset - offset, y: bounds.minY + inset + len))
        }
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        // 仅高度可调：纵向 resize 光标（上下双向箭头），不再用 crosshair
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    /// 浮窗是 nonactivatingPanel（不激活 App、不成 key window）：用户在其他应用
    /// 前台点击把手属于「非活跃窗口首次点击」，默认被系统吞掉——必须接受首次鼠标事件
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 拖动 resize（事件驱动 + 轮询兜底）
    // 主路径与浮窗移动（BalancePanelView.mouseDown）同一套 nextEvent 事件跟踪：
    // mouseDown 送达后，后续 dragged/up 事件由窗口持有（隐式鼠标抓取），逐事件
    // 驱动 setFrame，跟手无量化卡顿。
    // 兜底：nonactivating 面板在个别激活状态下 dragged 事件可能被路由给前台
    // App——100ms 无事件时读全局鼠标位置补帧，左键松开即结束。
    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else {
            super.mouseDown(with: event)
            return
        }
        let startMouse = NSEvent.mouseLocation
        let startFrame = window.frame
        let startMaxY = startFrame.maxY
        // 高度上限：屏幕可见高度与「顶边到屏幕底」取小——固定左上角拖高时
        // 底缘最多贴到屏幕可见区底边，不越出屏幕
        let maxH = window.screen
            .map { min($0.visibleFrame.height, startMaxY - $0.visibleFrame.minY) } ?? 1000
        Logger.log(.refresh, "[ResizeHandle] drag start frame=\(Int(startFrame.width))x\(Int(startFrame.height))")

        // 仅高度可调：宽度恒定（不响应水平拖拽），向下拖增高（屏幕 y 向下减小），
        // 高度 clamp 在 [minHeight, maxH]，左上角恒定
        func applyDrag(_ cur: NSPoint) {
            let w = startFrame.width
            let h = min(max(startFrame.height - (cur.y - startMouse.y), Self.minHeight), maxH)
            guard abs(window.frame.height - h) > 0.5 else { return }
            window.setFrame(NSRect(x: startFrame.minX, y: startMaxY - h,
                                   width: w, height: h), display: true)
        }

        while true {
            if let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                         until: Date(timeIntervalSinceNow: 0.1),
                                         inMode: .default, dequeue: true) {
                if ev.type == .leftMouseUp { break }
                applyDrag(NSEvent.mouseLocation)
            } else {
                // 超时无事件：左键已松开（事件流丢失兜底）→ 结束；否则按全局位置补帧
                if NSEvent.pressedMouseButtons & 1 == 0 { break }
                applyDrag(NSEvent.mouseLocation)
            }
        }
        let sz = window.frame.size
        Logger.log(.refresh, "[ResizeHandle] drag end frame=\(Int(sz.width))x\(Int(sz.height))")
        if sz != startFrame.size { onResizeEnded?(sz) }
    }
}

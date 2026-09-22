// Controls.swift — iBalance 自绘控件库（自包含，不依赖业务类型）
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 开关          MiniSwitch（原生 NSSwitch .mini 视觉缩 0.81）/ MonoCharSwitch（Mono 模式字符开关）
//               SwitchRowTapHandler（整行点击手势的 target，必须被行强持有否则失效）
// 下拉          CompactPopUpButton（9pt 字号）
// 卡片容器       HoverCard（hover 材质由容器共享 HoverMaterialHost + 整卡 hitTest 接管）
// 行容器         HoverRowView（hover 提亮背景+文本）/ SubAccountItemView（其余账号 chip，点击切号）
// 图标按钮       HoverIconButton / RefreshIconButton（刷新自转，CAAnimationDelegate）
// 玻璃与遮罩      TintedVisualEffectView（面板玻璃，继承面板遮罩色）/ TintOverlayView
// pin 浮窗 resize  PanelResizeHandle（浮窗自绘把手；**仅高度可调**，宽度恒等于起拖宽）
// hover 协议      PanelScrollHoverSync（滚动时同步 hover 状态）/ HoverEnterValidation
// 签到结果模型     CheckinRowState / CheckinInfoItem / CheckinResultRow（渲染在 Dialogs.swift）
//
// ⚠️ hover 类控件在面板滚动时必须同步状态 → 实现 PanelScrollHoverSync。
//    改 hover 逻辑先确认是否需要滚动同步，否则滚动后会残留高亮。

import Cocoa
import CoreText

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
        appearance = Self.themedAppearance(light: false)
    }

    // 完全原生外观（2026-09-07 定稿「能还原原生开关吗 只做尺寸上的修改」）：
    // 曾尝试「开」轨道=系统灰的自绘路线（draw 覆写 + canDrawSubviewsIntoLayer，
    // 详见记忆 project-zcode-tokens-panel），观感反复被打回后整体回退——
    // 本类只保留 0.81 缩放做尺寸修改，勿再加自绘。

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 控件自带 appearance（不继承容器）：浅色主题需显式切浅色，否则浅色面板里
    /// 开关仍渲染深色样式
    private static func themedAppearance(light: Bool) -> NSAppearance? {
        NSAppearance(named: light ? .aqua : .darkAqua)
    }

    /// 主题跟随（开关行与气泡同管线）
    func applyThemeAppearance(light: Bool) {
        appearance = Self.themedAppearance(light: light)
    }

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
/// 全自绘（draw(_:)），attributed string + kern 渲染，
/// 消除 NSTextField cell 内边距导致的对齐偏差——两个字符控件直接锚定到各自容器的 trailing。
/// 点击（或 performClick）翻转 state 并发送 action，与 NSSwitch 的 state/target/action 语义一致。
final class MonoCharSwitch: NSControl {
    /// 字号/字重
    private let fontSize: CGFloat = 12
    /// 字符间距（不用空格破坏等宽对齐）
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
            // 选中态亮色用 Palette.cardForeground（#EBEBEB），与折叠标题/余额卡前景一致
            .foregroundColor: on ? Palette.cardForeground : NSColor.secondaryLabelColor,
            .kern: kern,
        ]
        let str = text as NSString
        let sz = str.size(withAttributes: attrs)
        // 控件被约束拉伸时内容居中
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
        // 点击落在行内按钮上（如「自动检查更新」行的手动检查按钮）不翻转开关，
        // 按钮自身 action 已处理该次点击；hitTest 沿 superview 链回溯，覆盖按钮的子视图。
        if let row = sender.view, let hit = row.hitTest(sender.location(in: row)) {
            var v: NSView? = hit
            while let cur = v, cur !== row {
                if cur is NSButton { return }
                v = cur.superview
            }
        }
        let active: NSControl = char.isHidden ? sw : char
        active.performClick(nil)
    }
}

/// 视觉缩放下拉菜单：在原生 NSPopUpButton 基础上通过 affineTransform 缩至 0.8 倍，
/// 与 MiniSwitch 同一套 layer transform 处理（layout / viewDidMoveToWindow / viewWillDraw
/// 三处兜底重放——AppKit 复杂控件会在布局同步后重置 layer 属性）。
/// frame 不缩小：点击区域保持原生尺寸，仅视觉缩放。
/// ⚠️ 不自定义初始化器：NSPopUpButton 的指定初始化器是 init(frame:pullsDown:)，
/// 覆写 init(frame:) 走 NSControl 链会内部转发回指定初始化器并触发 Swift 运行时陷阱（实测崩溃）。
final class CompactPopUpButton: NSPopUpButton {
    private let visualScale: CGFloat = 0.8

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
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

    override func viewWillDraw() {
        super.viewWillDraw()
        applyTransform()
    }

    private func applyTransform() {
        guard let l = layer, l.bounds.width > 0 else { return }
        // 锚点取右缘中点：缩放向右收拢，视觉右缘与 frame 右缘重合，
        // 与设置行开关控件（trailing 贴行尾）右对齐；垂直方向仍绕中心
        let anchor = CGPoint(x: 1.0, y: 0.5)
        let target = CGAffineTransform(scaleX: visualScale, y: visualScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if l.anchorPoint != anchor {
            var p = l.position
            p.x += l.bounds.width * (anchor.x - l.anchorPoint.x)
            p.y += l.bounds.height * (anchor.y - l.anchorPoint.y)
            l.anchorPoint = anchor
            l.position = p
        }
        if l.affineTransform() != target {
            l.setAffineTransform(target)
        }
        CATransaction.commit()
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

/// 几何变化期间补发 mouseEntered 的事件级校验：折叠/展开、滚动、窗口 resize 等
/// 内容位移后，AppKit 会按陈旧几何补发 enter/exit（实测事件位置可偏离视图当前
/// bounds 数百 pt，且成对事件可能重复/丢失）。真实进入必然发生在视图框内，
/// 因此 enter 到达时校验事件位置 ∈ bounds 即可无状态地滤掉全部错位补发——
/// 这类事件点亮的是错位位置上的旧卡片，是折叠/展开假 hover 的根源。
/// 自造事件（syncHoverState 的 NSEvent()，window 为 nil）不经此校验。
enum HoverEnterValidation {
    /// true = 事件可信（自造事件或位置确在当前 bounds 内）
    static func isPlausible(_ event: NSEvent, in view: NSView) -> Bool {
        guard event.window != nil else { return true }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
    /// 退出事件的同源校验（与 isPlausible 镜像）：真实退出必然发生在视图框 **之外**，
    /// 因此事件位置仍落在 bounds 内 = 几何变化期的错位补发，必须丢弃。
    /// 漏掉这一侧会让「行的 hover 视觉」被凭空补发的 exit 打灭（亮一下又变灰）。
    /// 自造事件（syncHoverState 的 NSEvent()，window 为 nil）照常可信。
    static func isPlausibleExit(_ event: NSEvent, in view: NSView) -> Bool {
        guard event.window != nil else { return true }
        return !view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
}

/// 账号 chip 统一样式规格（用户定稿）：子账号按钮（SubAccountItemView）与当前账号
/// 积分 chip（RollingNumberView chipLayer）共用一套数值，改任何口径只动这里。
final class ChipStyle {
    private init() {}
    /// 圆角
    static let cornerRadius: CGFloat = 3.5
    /// 左右内边距（背景贴内容的内缩进）
    static let hPadding: CGFloat = 4
    /// coin 图标边长（两处统一；2026-09-02 用户要求缩小 2pt）
    static let iconSize: CGFloat = 6
    /// icon↔文本间距
    static let iconTextGap: CGFloat = 2
    /// 图标视觉下偏（stack 按 alignment rect 居中，正值 = 向下，与数值基线对齐）
    static let iconVerticalOffset: CGFloat = 1
    /// 字号/字重（与子账号 label 同款）
    static let fontSize: CGFloat = Palette.cardSubFontSize
    static let fontWeight: NSFont.Weight = .semibold

    /// 末字符「墨迹相对 advance」的左右空档（lsb / rsb），单位 pt。
    ///
    /// 背景若按 **advance 边界**贴边，尾部字符的 rsb 会被一起算进内缩进——
    /// 实测 9pt semibold（.AppleSystemUIFontDemi）：数字 rsb ≈ 0.65~0.76pt，
    /// 末位是「1」时高达 1.27pt；而左侧 coin 图标是按墨迹紧裁缩放的位图
    /// （空档 ≈ 0）→ 右侧视觉内缩进比左侧大 0.7~1.3pt，即「右边更空」。
    /// 背景按 **墨迹边界**对齐即可左右等距：右侧内缩进 = hPadding − rsb。
    static func inkBearings(_ text: String, font: NSFont) -> (lsb: CGFloat, rsb: CGFloat) {
        guard let scalar = text.unicodeScalars.last, scalar.value <= 0xFFFF else { return (0, 0) }
        var uni = UniChar(scalar.value)
        var glyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(font, &uni, &glyph, 1) else { return (0, 0) }
        var adv = CGSize.zero
        var box = CGRect.null
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &box, 1)
        return (lsb: box.minX, rsb: adv.width - (box.minX + box.width))
    }

    /// 墨迹右空档（背景贴墨迹用）
    static func trailingInkGap(_ text: String, font: NSFont) -> CGFloat {
        inkBearings(text, font: font).rsb
    }

    /// 配色档：背景 = cardForeground（深色外观 浅灰 / 浅色外观 深灰，不透明），
    /// 前景恒反向（深色外观深字 / 浅色外观浅字）；hover 背景降不透明度（0.85）保留反馈差
    static let bgDefault = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0xEB / 255.0, green: 0xEB / 255.0, blue: 0xEB / 255.0, alpha: 1)
            : NSColor(calibratedWhite: 0.13, alpha: 1)
    }
    static let bgHover = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0xEB / 255.0, green: 0xEB / 255.0, blue: 0xEB / 255.0, alpha: 0.85)
            : NSColor(calibratedWhite: 0.13, alpha: 0.85)
    }
    static let fgMain = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 0.15, alpha: 1)
            : NSColor(calibratedWhite: 0.87, alpha: 1)
    }
}

/// 子账号 chip 内的积分图标：通过 alignmentRectInsets 实现视觉下偏
/// （stack 按 alignment rect 居中，frame 整体低于中线 offset pt），不引入包裹视图。
/// 正值 = 视觉向下。
final class SubAccountIconView: NSImageView {
    var verticalOffset: CGFloat = 0
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: -verticalOffset, left: 0, bottom: verticalOffset, right: 0)
    }
    /// 位图 1:1 对齐设备像素：栈布局给的 frame origin 含前邻文本 advance 的分数 pt，
    /// 原样 blit 在 2x 屏会落到半像素上（重采样发糊）——layout 时把 origin 吸附到
    /// 0.5pt（= 1 设备像素@2x）网格；宽高为整 pt 不动
    override func layout() {
        super.layout()
        let f = frame
        let snapped = NSRect(x: (f.origin.x * 2).rounded() / 2,
                             y: (f.origin.y * 2).rounded() / 2,
                             width: f.width, height: f.height)
        if snapped != f { setFrameOrigin(snapped.origin) }
    }
}

/// Agent 卡其余账号切换项（icon+积分）：处于主卡 HoverCard 内部、整卡 hitTest 被卡片
/// 接管，点击由卡片 mouseDown 命中路由转交 onClick；光标 pointingHand 提示可点击。
/// 按钮样式（用户定稿，浅色主题反转）：深色外观 白@80% 背景 + 深色前景；
/// 浅色外观 黑@80% 背景 + 浅色前景；hover 背景再上一档（92%）。
final class SubAccountItemView: NSStackView {
    /// 点击切换账号回调（nil = 不可点）
    var onClick: (() -> Void)?
    /// 昵称（hover 子面板内容,原小卡片标题信息）
    var nickname = ""
    /// 积分文本（hover 子面板第二行,与卡片数值同源）
    var valueText = ""
    /// 令牌失效/账号无套餐（账号级问题）：hover 气泡 ID 行末挂黄色警示徽章
    var tokenInvalid = false
    /// hover 进出回调（面板侧弹/收昵称子面板;进出有 0.3s 延迟防扫过闪烁）
    var onTipToggle: ((Bool) -> Void)?
    /// hover 即时翻转回调（setHovered 状态真变化时触发,无 tooltip 延迟;
    /// 锚卡借此让当前账号积分/数值让位）
    var onHoverChanged: ((Bool) -> Void)?
    private var isHovered = false
    private var tipWorkItem: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ChipStyle.cornerRadius
        layer?.cornerCurve = .continuous
        // 背景贴内容太紧：左右各 hPadding 内边距（命中区随之略宽）
        edgeInsets = NSEdgeInsets(top: 0, left: ChipStyle.hPadding, bottom: 0, right: ChipStyle.hPadding)
        applyState(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 动态色经 .cgColor 落盘定格外观：主题切换时重跑着色
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyState(animated: false)
    }

    /// hover 态由所在卡片的 mouseMoved/mouseEntered/mouseExited 统一驱动
    /// （HoverCard.syncInteractiveHover）——整卡 hitTest 接管下子视图自身 tracking 不投递
    func setHovered(_ inside: Bool) {
        guard inside != isHovered else { return }
        isHovered = inside
        applyState(animated: true)
        onHoverChanged?(inside)
        if inside { scheduleTip() } else { hideTip() }
    }

    /// 系统tooltip手感：悬停 0.3s 才触发，移开立即收（收起即便没弹过也回调,
    /// 面板侧按 isShown 幂等）
    private func scheduleTip() {
        guard !nickname.isEmpty else { return }
        tipWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onTipToggle?(true) }
        tipWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func hideTip() {
        tipWorkItem?.cancel()
        tipWorkItem = nil
        onTipToggle?(false)
    }

    /// 配色/几何档统一在 ChipStyle（用户定稿，浅色主题反转）——本类只消费，
    /// RollingNumberView 当前账号积分 chip 复用同一套。

    /// 积分数值 label（弱引用，chip 持有于面板）：供墨迹回补读取当前文本/字体
    weak var valueLabel: NSTextField?

    /// 右内缩进按末字符墨迹回补：背景贴墨迹而非 advance，左右视觉等距
    /// （末字符 rsb 默认会被算成内缩进，见 ChipStyle.inkBearings）。
    /// 文本/字体变化（含 Mono 开关就地刷字体）后需重调 —— 走 refreshOpticalPadding()
    func applyOpticalPadding(text: String, font: NSFont) {
        edgeInsets.right = max(0, ChipStyle.hPadding - ChipStyle.trailingInkGap(text, font: font) + 0.2)
    }

    /// 按 valueLabel 当前文本+字体重算墨迹回补（文本更新 / 字体策略切换后调用）
    func refreshOpticalPadding() {
        guard let lbl = valueLabel else { return }
        // 兜底走主面板字体解析器（2026-09-15 SG 档全覆盖）：本 chip 的 valueLabel 经
        // `BalancePanelView.registerFont` 建（font 恒非 nil），且字体档翻转后 applyPanelFonts
        // 就地换字体 → 末字符 rsb 随之变，须重算墨迹回补（见 Panel.applyPanelFonts）
        applyOpticalPadding(text: lbl.stringValue,
                            font: lbl.font ?? PanelFont.font(size: ChipStyle.fontSize,
                                                             weight: ChipStyle.fontWeight))
    }

    /// 离场下沉期间冻结背景写入。mouseExited 中 setHovered(false) 与离场块同拍执行，
    /// 其 0.25s 背景淡出快于 chip 整体淡出，不冻结会「背景先化掉、裸文本在下沉」。
    /// 旧实现钉 presentation 当前值：presentation 在未提交帧拿不到时回退读 model——
    /// 而 model 已被先行的 setHovered(false) 改成默认色，禁用动作写入等于把背景
    /// 一帧拍灭（「背景瞬间消失」根因）。现改为纯标志位：冻结期间 applyState 跳过
    /// 背景写入，model 保持离场前颜色（在途背景动画自然播完，终点即 model 值），
    /// 背景只随 chip 整体 alpha 淡出。配合 mouseExited 先离场块、后熄 hover 的顺序。
    private var backgroundFrozen = false

    func freezeBackground() {
        backgroundFrozen = true
    }

    /// 换入路径解除冻结（离场被代际取消、未走 resetVisualState 的场景），
    /// 并按当前 hover 态重铺背景（此刻 chip 在淡入起点，重铺不可见）
    func unfreezeBackground() {
        guard backgroundFrozen else { return }
        backgroundFrozen = false
        applyState(animated: false)
    }

    /// 冻结复位：落藏后恢复默认背景/文本色（供下一轮换入）
    func resetVisualState() {
        backgroundFrozen = false
        isHovered = false
        applyState(animated: false)
    }

    /// 背景与文本/图标色随 hover 切换：背景走 CATransaction（图层属性），
    /// 文本/图标走 NSAnimationContext animator（非图层属性），时长统一 Motion.hover
    private func applyState(animated: Bool) {
        let bg = isHovered ? ChipStyle.bgHover : ChipStyle.bgDefault
        let fg = ChipStyle.fgMain
        // 背景冻结期间跳过背景写入（离场下沉中，背景只随 chip 整体 alpha 淡出）
        if !backgroundFrozen {
            // 与当前账号积分 chip 的 resolveChipColor 同口径：浅色主题可能强制
            // 覆盖系统外观，必须按视图 effectiveAppearance 解算动态色。
            effectiveAppearance.performAsCurrentDrawingAppearance {
                CATransaction.begin()
                CATransaction.setAnimationDuration(animated ? Motion.hover : 0)
                layer?.backgroundColor = bg.cgColor
                CATransaction.commit()
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? Motion.hover : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for case let tf as NSTextField in arrangedSubviews { tf.animator().textColor = fg }
            for case let iv as NSImageView in arrangedSubviews { iv.animator().contentTintColor = fg }
        }
    }
}

/// 行容器：hover 时提亮文本与灰 tint 图标（→ hoverTextColor），switch/radio 等控件保持不变；
/// 背景/边框由 hoverGradientColors、enablesHoverBorder 控制（不设则纯提亮）。
/// 现役唯一调用点 = 用量表行（wrapHoverRow，hoverTextColor = Palette.cardForeground）；
/// 其余 hover 交互走 HoverCard / 各视图自绘。光标变为 pointingHand 提示可点击。
final class HoverRowView: NSView, PanelScrollHoverSync {
    private var trackingArea: NSTrackingArea?
    /// 当前 hover 状态（滚动同步时用于判断是否需要切换）
    private var isMouseInside = false
    private var labels: [NSTextField] = []
    private var highlightedLabels: [NSTextField] = []
    var hoverTextColor: NSColor = .labelColor
    /// hover 时行背景色（nil = 不绘制背景，保持原文本/tint 提亮行为）
    var hoverBackgroundColor: NSColor? = nil
    /// 进入 hover 前保存的原始背景色（退出时恢复，避免 hover 平色把持久底色抹成透明）
    private var originalBackgroundColor: CGColor?
    /// hover 时行背景渐变（亮→暗端点，与余额卡片 HoverCard 同一套 Palette 常量）；
    /// 设置后优先于 hoverBackgroundColor 平色。层常驻，opacity 淡入淡出。
    var hoverGradientColors: [NSColor]? = nil {
        didSet {
            guard hoverGradientColors != oldValue else { return }
            if let gradient = hoverGradientColors, gradient.count >= 2 {
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    self.hoverGradientLayer.colors = gradient.map { $0.cgColor }
                }
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
    /// 动态色经 .cgColor 落盘会定格当时外观：系统主题切换时按新 effectiveAppearance 重解算
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if hoverGradientInstalled, let gradient = hoverGradientColors {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                self.hoverGradientLayer.colors = gradient.map { $0.cgColor }
            }
        }
        // hover 平色也按新外观重解算（此刻正悬停则立即落盘，非悬停时下一次 enter 会再写）
        if isMouseInside, let bg = hoverBackgroundColor {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                self.layer?.backgroundColor = bg.cgColor
            }
        }
    }
    /// 行背景圆角（hoverBackgroundColor 非 nil 时生效）
    var backgroundCornerRadius: CGFloat = 6
    /// 行 hover 交给所在列表的共享材质宿主（行间整块滑动，2026-09-13 用量行「沿用
    /// 连续效果」）：开启后自带渐变/描边视觉停用，文字提亮照旧。宿主 = 列表容器
    /// installHoverMaterialHost()（用量 = usageContentStack，含渐变背景+描边）。
    var usesSharedHoverMaterial = false
    /// 挂窗期间缓存的宿主：行随数据刷新被移出层级后 superview 链已断
    /// （hoverMaterialHost 向上查找落空），靠它收走遗留在旧几何上的材质
    private weak var cachedRowHost: HoverMaterialHost?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            cachedRowHost = hoverMaterialHost
        } else {
            cachedRowHost?.hideIfCurrent(rect: bounds, in: self)
        }
    }
    /// 行 hover 状态回调（用量行用于显示右侧趋势 popover）。
    var onHoverChanged: ((Bool) -> Void)?
    /// hover 时是否对灰色文本/tint 做提亮（false = 仅背景变化，用于用量行等）
    var enablesTextBrightening: Bool = true
    /// hover 时是否绘制发丝边框（与余额卡片 HoverCard 同一套 Palette：常态 hoverBorderNormal、
    /// hover 提亮到 hoverBorderBright，线宽统一读 `Palette.cardBorderWidth`（现 1.0pt），0.22s 渐变）。仅用量行启用，
    /// 设置卡片行保持纯平态。开启时预设 borderColor 避免首帧从黑边渐变。
    var enablesHoverBorder: Bool = false {
        didSet {
            guard enablesHoverBorder != oldValue else { return }
            wantsLayer = true
            // 无论开关都保留常态 borderColor：width=0 时无色视觉差异，
            // 但再次打开时模型值非 nil，动画 fromValue 不再是零色的幽灵黑边。
            layer?.borderColor = Palette.borderCGColor(Palette.hoverBorderNormal, in: self)
            if !enablesHoverBorder {
                layer?.borderWidth = 0 // 用量行关闭态仍不画（设置卡纯平口径不变）
            }
        }
    }
    /// hover 锁定：子面板（趋势图 popover）打开期间锚定行保持高亮，
    /// 鼠标移出仅回调 onHoverChanged(false)（驱动子面板延迟关闭），视觉不退出
    private var hoverLocked = false

    /// 左键点击回调（mouseUp 且仍在行 bounds 内触发；用量行映射到子面板「过去周」）
    var onLeftClick: (() -> Void)?
    /// 右键点击回调（rightMouseDown 触发；用量行映射到子面板「回到本周」）
    var onRightClick: (() -> Void)?

    /// 整行即左键点击热区：置顶浮窗下若不消费 mouseDown，事件沿 responder chain
    /// 转给 BalancePanelView 的拖窗循环，mouseUp 被吞、onLeftClick 失效（同 HoverCard 口径）
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.buttonNumber == 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onLeftClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 不调用 super：右键由回调接管，不触发系统上下文菜单
        onRightClick?()
    }

    /// 设置 hover 锁定（纯视觉操作，不碰事件状态/回调）：
    /// - 锁定：立即点亮高亮（未 hover 时）
    /// - 解锁：光标已不在本行才熄灭。**不能无条件熄灭**——子面板弹出会盖住光标并让
    ///   AppKit 补发一个 exit，随后延迟关闭又触发解锁；光标其实一直停在行上，
    ///   无条件熄灭就是用户看到的「hover 亮一下又变暗」。
    ///   判定走窗口 hitTest（与 syncHoverAfterScroll 同源；各视图自行 convert 判定
    ///   在置顶浮窗里会持续误判），拿不到窗口时保守熄灭。
    func setHoverLocked(_ locked: Bool) {
        guard locked != hoverLocked else { return }
        hoverLocked = locked
        if locked {
            if !isMouseInside { enterHoverVisual() }
        } else if isCursorOverSelf() {
            isMouseInside = true   // 回到常态 hover 语义：后续真实 exit 仍能正常熄灭
        } else {
            exitHoverVisual()
        }
    }

    /// 光标是否仍落在此行内（窗口 hitTest，跨子面板窗口只看本窗口的命中结果）
    private func isCursorOverSelf() -> Bool {
        guard let window, window.contentView != nil else { return false }
        let p = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        var node = window.contentView?.hitTest(p)
        while let v = node {
            if v === self { return true }
            node = v.superview
        }
        return false
    }
    /// 需要 hover 提亮的 tint 控件 setter：contentTintColor 为**副前景灰**（Palette.secondaryForeground，
    /// 浅色外观下按面板底色加深过）的 NSImageView / NSButton
    /// 跟随整行 hover 提亮（**与文字同一个 hoverTextColor**，勿再写死 labelColor——
    /// 用量行 hoverTextColor = Palette.cardForeground #EBEBEB，labelColor 是纯白，
    /// 两者并排会让同一行出现「两个前景色」；Token 面板自绘行的 icon/文字同色口径见
    /// TokensPanel.drawProjectRows 的 rowColor）。
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
                    iv.contentTintColor == Palette.secondaryForeground || iv.contentTintColor == NSColor.labelColor {
                tintables.append({ [weak iv] c in iv?.contentTintColor = c })
            }
            else if let btn = v as? NSButton,
                    btn.contentTintColor == Palette.secondaryForeground || btn.contentTintColor == NSColor.labelColor {
                tintables.append({ [weak btn] c in btn?.contentTintColor = c })
            }
            for sub in v.subviews { scan(sub) }
        }
        scan(self)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard HoverEnterValidation.isPlausible(event, in: self) else { return }
        isMouseInside = true
        onHoverChanged?(true)
        enterHoverVisual()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // 错位补发过滤（与 mouseEntered 的 isPlausible 镜像）：几何变化期 AppKit 会按
        // 陈旧几何补发 exit，事件位置仍落在行内时不是真实退出——放过去会让「行的
        // hover 视觉先亮后灭」。自造事件（syncHoverState）window 为 nil，照常放行。
        guard HoverEnterValidation.isPlausibleExit(event, in: self) else { return }
        isMouseInside = false
        onHoverChanged?(false)
        // hover 锁定（子面板打开期间）：保持高亮视觉，直到子面板关闭解锁。
        // onHoverChanged 照常回调（子面板的延迟关闭逻辑不受影响）
        if hoverLocked { return }
        exitHoverVisual()
    }

    /// 进入 hover 视觉（渐变/背景 + 可选文字提亮）；与事件回调解耦，锁定时复用
    private func enterHoverVisual() {
        if usesSharedHoverMaterial {
            // 共享材质模式：背景+描边由列表宿主整块滑入（层挂在列表容器上），
            // 本行不再自持任何 hover 图层
            wantsLayer = true
            layer?.cornerRadius = backgroundCornerRadius
            layer?.cornerCurve = .continuous
            let host = hoverMaterialHost ?? cachedRowHost
            host?.show(rect: bounds, in: self, cornerRadius: backgroundCornerRadius)
            cachedRowHost = host ?? cachedRowHost
        } else if let gradient = hoverGradientColors, gradient.count >= 2 {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.hover)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            wantsLayer = true
            layer?.cornerRadius = backgroundCornerRadius
            layer?.cornerCurve = .continuous
            if !hoverGradientInstalled {
                // 首次挂载：初始透明，靠下方 opacity 赋值淡入
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    hoverGradientLayer.colors = gradient.map { $0.cgColor }
                }
                // ⚠️ 必须压在内容之下：rowStack（含全部 label/icon）的层早已在 sublayers 里，
                // addSublayer 追加的层默认叠在**最上面**——不定 z 的话这块黑 @50% 的 hover 底
                // 会盖住文字，观感即「文字先变亮、底色淡入后又被蒙灰（先亮后变暗）」。
                // 与 HoverMaterialHost.materialLayer 同口径（该处注释：背景块画在所有卡片之下）。
                hoverGradientLayer.zPosition = -1
                hoverGradientLayer.cornerRadius = backgroundCornerRadius
                hoverGradientLayer.cornerCurve = .continuous
                hoverGradientLayer.opacity = 0
                layer?.addSublayer(hoverGradientLayer)
                hoverGradientInstalled = true
            } else {
                // 非首次：渐变层已挂载，但外观可能在两次 hover 之间切换，重算颜色避免深浅色错配
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    hoverGradientLayer.colors = gradient.map { $0.cgColor }
                }
            }
            // frame 每次 enter 都重贴（HoverCard.layout() 同款口径）：子层 frame 不随
            // Auto Layout 同步，视图宽度自上次 hover 后若变化（面板宽度调整/浮窗 resize/
            // 约束重排），旧 frame 会让渐变背景盖不准视图
            hoverGradientLayer.frame = bounds
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
            // 进入前记录原始 backgroundColor（可能是持久配置或 nil/透明）
            // 只记录一次：避免快速 enter/exit 把 hover 颜色误当"原始"保存
            if originalBackgroundColor == nil {
                originalBackgroundColor = layer?.backgroundColor
            }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                self.layer?.backgroundColor = bg.cgColor
            }
            CATransaction.commit()
        }
        if enablesHoverBorder && !usesSharedHoverMaterial {
            wantsLayer = true
            layer?.cornerRadius = backgroundCornerRadius
            layer?.cornerCurve = .continuous
            // borderColor 模型值若为 nil（enablesHoverBorder 设置时的边界情况或外部手动清零），
            // 先写回常态色，避免 fromValue 缺失造成首帧从 (0,0,0,0) 黑闪到亮色
            if layer?.borderColor == nil {
                layer?.borderColor = Palette.borderCGColor(Palette.hoverBorderNormal, in: self)
            }
            // 与余额卡片 HoverCard 同款：线宽统一读 `Palette.cardBorderWidth` + hoverBorderBright 描边
            animateLayerKey(layer, keyPath: "borderWidth", to: Palette.cardBorderWidth)
            animateLayerKey(layer, keyPath: "borderColor",
                            to: Palette.borderCGColor(Palette.hoverBorderBright, in: self))
        }
        guard enablesTextBrightening else { return }
        collectLabels()
        // 过滤条件必须包含 hoverTextColor：快速进出后再次 enter 时，label 的
        // model 色已是亮色（animator 动画改的是 model 值），漏收集会导致最终
        // 退出时 highlightedLabels 为空、亮色卡死不回落
        highlightedLabels = labels.filter {
            $0.textColor == Palette.secondaryForeground || $0.textColor == NSColor.tertiaryLabelColor
                || $0.textColor == hoverTextColor
        }
        // 文字/图标色**直接落定**，不走 NSAnimationContext + animator（2026-09-12 用户指定
        // 「把文本的 hover 动画去掉看看，直接变亮」）。注：「先亮后变暗」的真凶不是动画，
        // 而是 hoverGradientLayer 没设 zPosition 盖住了文字（见 enterHoverVisual）——
        // 这里保持直接落定属既有偏好，背景/边框的淡入不受影响。
        for l in highlightedLabels { l.textColor = self.hoverTextColor }
        for setter in tintables { setter(self.hoverTextColor) }
    }

    /// 退出 hover 视觉；由 mouseExited / setHoverLocked(false) 触发
    private func exitHoverVisual() {
        if usesSharedHoverMaterial {
            // 共享材质模式：交给宿主宽限收场（相邻行立即接管则材质直接滑走不闪）
            (hoverMaterialHost ?? cachedRowHost)?.hideIfCurrent(rect: bounds, in: self)
        } else {
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
                // 恢复进入前的原始底色（持久卡底），不是一律抹成 nil——
                // nil 会让原本带色的行变成"裸玻璃"，与周边卡片色差一帧跳变。
                layer?.backgroundColor = originalBackgroundColor
                CATransaction.commit()
                // 下一轮 enter 重新捕获：避免后续外部改了底色又被旧 originalBackgroundColor 盖掉
                originalBackgroundColor = nil
            }
            if enablesHoverBorder {
                animateLayerKey(layer, keyPath: "borderWidth", to: 0)
                animateLayerKey(layer, keyPath: "borderColor",
                                to: Palette.borderCGColor(Palette.hoverBorderNormal, in: self))
            }
        }
        guard enablesTextBrightening else { return }
        // 与 enter 对称：颜色直接落定（不走 animator，理由见 enterHoverVisual）
        for l in highlightedLabels { l.textColor = Palette.secondaryForeground }
        for setter in tintables { setter(Palette.secondaryForeground) }
        highlightedLabels.removeAll()
    }

    /// 渐变层 frame 不随 AutoLayout 同步，布局时手动贴满 bounds
    override func layout() {
        super.layout()
        if hoverGradientInstalled { hoverGradientLayer.frame = bounds }
        if usesSharedHoverMaterial, isMouseInside {
            (hoverMaterialHost ?? cachedRowHost)?
                .updateGeometry(rect: bounds, in: self, cornerRadius: backgroundCornerRadius)
        }
    }

    // MARK: - 面板滚动 hover 同步
    func syncHoverState(_ inside: Bool) {
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }
}

/// header 图标按钮共有的「点击 / 拖动换位」分流挂点（2026-09-13 起无需按住 Cmd）：
/// mouseDown 转交面板做阈值判断（PanelDrag.beginHeaderIconDrag），未超阈值原地松手
/// 由按钮回放自己的点击链路，超阈值进入拖拽重排。
protocol HeaderIconDraggable: NSView {
    /// 起手回调：把 mouseDown 事件原样转交面板
    var onDragStart: ((NSEvent) -> Void)? { get set }
    /// 阈值内原地松手 = 普通点击（各按钮回放自己的点击链路）
    func performClickAction()
}

/// header 按钮的「常态前景色」统一入口（HoverIconButton / RefreshPieButton 都实现）：
/// 槽位重排后按「落在哪一格」统一切换色调时，不必对两种按钮类型分别判别
///（当前用途：中间格那颗改成卡片主标题色，见 PanelDrag.applyHeaderButtonSlots）。
protocol HeaderTintAdjustable: NSView {
    var normalTintColor: NSColor { get set }
}

/// 无边框图标按钮（header 图标组共用）：hover 底自绘（hoverBgLayer 正圆 + hoverBackgroundColor），
/// 系统 bezel 关闭，tracking area 管理「底色淡入 + 图标提亮到 hoverTintColor」。
/// 默认提亮色 labelColor；header 六颗按钮走 PanelLayout.makeHeaderIconButton 统一构造，
/// 不单独指定 hoverTintColor，hover 观感与同组一致。
final class HoverIconButton: NSButton, PanelScrollHoverSync, HeaderIconDraggable, HeaderTintAdjustable {
    /// 按钮容器尺寸（正方形）
    static let buttonSize: CGFloat = 22
    /// hover 底色（**与卡片 hover 材质同源 = 次背景色**）：header 图标按钮 / 手动刷新按钮 /
    /// 刷新周期饼图按钮 / 拖动槽位指引的空位填充，四处共用同一常量 ——
    /// 同组按钮的 hover 底不可能各写一份而走样
    ///
    /// 2026-09-22 用户「header 按钮的 hover 背景色使用卡片 hover 背景色」⇒ 原写死的
    /// `NSColor.white.withAlphaComponent(0.12)`（极淡白圆底）改为 `Palette.hoverGradientBright`：
    /// 它就是卡片 hover 材质块（`HoverMaterialHost.materialLayer`）颜色数组 `Palette.hoverGradient`
    /// 里的那档，两档同值 ⇒ 即设置窗口「面板 → 次背景色」。
    /// 材质块是 `CAGradientLayer`、按钮底是纯色正圆，故按钮取**单个色停**即可；
    /// 改次背景色后按钮底在下次 hover 时当场解算跟随（无须 `refreshDotMatrixAndHoverMaterials()`
    /// 那套材质宿主重解算）。
    /// ⚠️ 该色是 `NSColor(name:)` 动态色（provider 忽略 appearance、只读运行镜像
    /// `secondaryBackgroundActive`），落 `CALayer.backgroundColor` 走 `.cgColor` 安全；
    /// 不走 `Palette.borderCGColor` 是因为它与外观无关，包一层 `performAsCurrentDrawingAppearance`
    /// 结果完全一样
    static let hoverBackgroundColor: NSColor = Palette.hoverGradientBright
    /// 非 hover 常态 tint；默认 = 副前景色（面板第二层灰，浅色外观下按面板底色加深），
    /// header 可按主题指定黑色动态色。
    var normalTintColor: NSColor = Palette.secondaryForeground {
        didSet {
            if !isMouseInside { contentTintColor = normalTintColor }
        }
    }
    /// hover 时的 tint；默认使用系统标签色，特殊按钮可单独指定。
    var hoverTintColor: NSColor = .labelColor
    /// 拖动换位起手回调（header 图标；nil = 未接入分流，mouseDown 走普通按钮链路）
    var onDragStart: ((NSEvent) -> Void)?
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
        contentTintColor = normalTintColor
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
        contentTintColor = normalTintColor
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
        guard HoverEnterValidation.isPlausible(event, in: self) else { return }
        isMouseInside = true
        contentTintColor = hoverTintColor
        // 兜底：确保 hover 背景几何已就位（layout 时序未触发时）
        updateHoverBgGeometry()
        // hover 背景：极淡白底淡入（0.22s，同全项目过渡节奏）
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor",
                        to: Self.hoverBackgroundColor.cgColor)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        contentTintColor = normalTintColor
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor", to: NSColor.clear.cgColor)
    }

    override func mouseDown(with event: NSEvent) {
        // 按下即转交面板做点击/拖拽分流（阈值判断在 PanelDrag）；未接入时走普通点击链路
        guard let onDragStart else { super.mouseDown(with: event); return }
        onDragStart(event)
    }

    func performClickAction() {
        // 阈值内原地松手 = 普通点击：直接走 target/action（不走 performClick，免按压视觉二次驱动）
        sendAction(action, to: target)
    }

    // MARK: - 面板滚动 hover 同步
    func syncHoverState(_ inside: Bool) {
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }
}

/// header 拖动时的**槽位指引层**（2026-09-14 用户「拖动时给我 header 上空位的视觉指引」）：
/// 拖拽会话期间铺出整条槽位（数量 = BalancePanelView.headerButtonSlotCount）——
/// 空位画虚线圆（一眼看出「这儿可以放」），
/// 当前落点画亮环（落点是占用位时只描环、不填充，避免盖住那颗按钮的图标）。
///
/// 画在按钮**之上**（由 PanelLayout.build 用 positioned: .above 挂载）：整层以 stroke
/// 为主，叠在图标上方也不遮字形；非拖拽会话由调用方置 isHidden。
///
/// 视图几何由外部钉成「正好一个按钮带」（leading = 槽位条起点、width = 槽位条总宽、
/// height = 按钮边长、centerY 与按钮同轴），所以内部第 i 槽就是 x = i × pitch 的
/// 一个边长正方形、y 直接贴 bounds —— 不在这里再算一次垂直居中。
///
/// 配色走 `Palette.panelHeaderContentColor`（浅色外观黑 / 深色外观系统灰）而非纯白，
/// 两种外观下都看得见；落点为空位时的填充沿用 `HoverIconButton.hoverBackgroundColor`，
/// 与真实 hover 底色同源，给出「落点即悬停」的观感。
final class HeaderSlotGuidesView: NSView {
    /// 槽位占用表（下标 = 槽位，true = 该槽有按钮）；由 applyHeaderButtonSlots 同步
    var occupied: [Bool] = []
    /// 当前落点槽位（nil = 未落到任何槽）
    var dropSlot: Int?

    private let pitch = BalancePanelView.headerButtonSlotPitch

    override var isFlipped: Bool { false }

    /// 纯装饰层：挂在按钮之上，必须永不参与命中测试 —— 否则会吃掉按钮的
    /// 点击与 hover 进出（虽然非拖拽会话恒 hidden，但这条不能靠 hidden 兜底）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let side = bounds.height
        guard side > 0, !occupied.isEmpty else { return }
        let tint = Palette.panelHeaderContentColor
        for index in 0..<occupied.count {
            let rect = NSRect(x: CGFloat(index) * pitch, y: 0, width: side, height: side)
            let isEmpty = !occupied[index]
            if isEmpty {
                tint.withAlphaComponent(0.05).setFill()
                NSBezierPath(ovalIn: rect).fill()
                let dashed = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                dashed.lineWidth = 1
                dashed.setLineDash([2.5, 2.5], count: 2, phase: 0)
                tint.withAlphaComponent(0.22).setStroke()
                dashed.stroke()
            }
            if index == dropSlot {
                if isEmpty {
                    HoverIconButton.hoverBackgroundColor.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                }
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1.5
                tint.withAlphaComponent(0.45).setStroke()
                ring.stroke()
            }
        }
    }
}

/// 手动刷新按钮：点击时图标顺时针旋转一圈。
/// AppKit layer-backed 视图经 Auto Layout 同步会把 anchorPoint 重置为 (0,0)，
/// 直接旋转会绕左下角转；需在 layout() 里恢复中心锚点 + 补偿 position（同 MiniSwitch 思路）。
/// hover 自绘圆形**次背景色**底 + 图标 tint 提亮（底色与卡片 hover 材质同源，
/// 同 footer HoverIconButton 样式）；
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
        contentTintColor = Palette.secondaryForeground
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
        contentTintColor = Palette.secondaryForeground
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

    /// 点击是否旋转一圈（默认转；个别按钮如「立即检查更新」不转，PanelLayout 里关掉）
    var spinsOnAction = true

    /// 点击发送 action 时顺时针旋转一圈（-2π，0.45s ease-in-out）
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if spinsOnAction { spinOnce() }
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
        guard HoverEnterValidation.isPlausible(event, in: self) else { return }
        isMouseInside = true
        // 兜底：确保 hover 背景几何已就位（layout 时序未触发时）
        updateHoverBgGeometry()
        // hover 背景：极淡白底淡入 + 图标 tint 提亮（0.22s，同全项目过渡节奏）
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor",
                        to: HoverIconButton.hoverBackgroundColor.cgColor)
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
            self.animator().contentTintColor = Palette.secondaryForeground
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

/// header 右上角刷新周期饼图按钮：圆形饼图随时间填充，走满一圈 = 一个自动刷新周期
/// （时长 = 设置的刷新分钟数），每秒重算重绘；点击弹出间隔单选菜单（1/3/5 分钟）。
/// 大小/配色对齐 header 左上角 HoverIconButton：22×22 容器、11pt 图形、
/// 副前景色常态墨迹（= 系统灰基准 + 按面板底色对比度补偿，同 HoverIconButton）、
/// hover **次背景色**正圆背景 + labelColor 提亮（底色同卡片 hover 材质）。
/// 周期数据由 cycleProvider 直读 AppDelegate 的 repeating Timer（fireDate 恒为
/// 下次自动刷新时刻，本轮起点 = fireDate − 间隔）：手动刷新不重建定时器、饼图
/// 不跳变，改间隔重建定时器后自动跟随，面板侧零状态推送。
final class RefreshPieButton: NSView, PanelScrollHoverSync, HeaderIconDraggable, HeaderTintAdjustable {
    static let buttonSize = HoverIconButton.buttonSize
    /// 饼图直径：与 header 图标 11pt 同尺寸，视觉分量对齐
    private let pieDiameter: CGFloat = 11
    /// 间隔选项（分钟），与状态栏菜单同一组档位
    private let minuteOptions = [1, 3, 5]

    /// 周期数据源：返回 (本轮起点, 周期秒数)
    var cycleProvider: (() -> (anchor: Date, interval: TimeInterval))?
    /// 左键点击回调：立即手动刷新（宿主 onRefresh 会重建定时器，cycleProvider
    /// 锚点随之归零，本视图只需立即重绘）
    var onSelectRefresh: (() -> Void)?
    /// 右键菜单选中回调（秒数）
    var onSelectInterval: ((TimeInterval) -> Void)?
    /// 拖动换位起手回调（header 图标；nil = 未接入分流，mouseDown 保持按下即刷新）
    var onDragStart: ((NSEvent) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isMouseInside = false
    /// 非 hover 常态墨迹色（默认副前景灰）；与 HoverIconButton.normalTintColor 同语义 ——
    /// 槽位重排后落在 header 中间格时由面板侧统一切成卡片主标题色
    var normalTintColor: NSColor = Palette.secondaryForeground {
        didSet { needsDisplay = true }
    }
    /// hover 背景独立子 layer：固定 buttonSize 正圆（同 HoverIconButton 口径）
    private let hoverBgLayer = CALayer()
    /// 每秒推进的显示定时器（挂窗时建、离窗拆，防 Timer→target 引用环）
    private var tickTimer: Timer?
    /// 上次写入 toolTip 的周期：变化才重写（改间隔后提示自动跟随）
    private var lastToolTipInterval: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverBgLayer.masksToBounds = true
        hoverBgLayer.cornerRadius = Self.buttonSize / 2
        hoverBgLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hoverBgLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 周期推进

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 换窗（popover ↔ 置顶浮窗转移）不派发 mouseExited，hover 卡亮一并归零
        isMouseInside = false
        hoverBgLayer.backgroundColor = NSColor.clear.cgColor
        syncTickTimer()
        updateToolTipIfNeeded()
        needsDisplay = true
    }

    /// 挂窗 1s 一拍（.common 模式，滚动/菜单追踪中不停摆）；离窗拆表
    private func syncTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1, target: self, selector: #selector(onTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    @objc private func onTick() {
        // 面板隐藏期间不重绘（popover 关闭时 window 已拆、置顶浮窗 isVisible=false）
        guard window?.isVisible == true else { return }
        updateToolTipIfNeeded()
        needsDisplay = true
    }

    private func updateToolTipIfNeeded() {
        guard let provider = cycleProvider else { return }
        let p = provider()
        guard p.interval != lastToolTipInterval else { return }
        lastToolTipInterval = p.interval
        let minutes = max(1, Int((p.interval / 60).rounded()))
        toolTip = "每 \(minutes) 分钟自动刷新 · 点击立即刷新，右键改间隔"
    }

    /// 当前进度 = 本轮已流逝 / 周期（0…1；时钟回拨钳 0、漏拍钳满格 = 即将刷新）
    private func currentFraction() -> CGFloat {
        guard let provider = cycleProvider else { return 0 }
        let p = provider()
        guard p.interval > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(p.anchor)
        guard elapsed > 0 else { return 0 }
        return CGFloat(min(elapsed / p.interval, 1))
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 常态墨迹 = normalTintColor（默认副前景色：系统灰基准 + 按面板底色对比度补偿；
        // 落在 header 中间格时被切成卡片主标题色），hover 提亮到系统标签色
        let ink = isMouseInside ? NSColor.labelColor : normalTintColor
        let pieRect = NSRect(x: bounds.midX - pieDiameter / 2, y: bounds.midY - pieDiameter / 2,
                             width: pieDiameter, height: pieDiameter)
        // 轨道整圆（饼底）
        ink.withAlphaComponent(0.2).setFill()
        NSBezierPath(ovalIn: pieRect).fill()
        // 进度扇形：12 点起顺时针填充（数学角 90° 起、角度递减 = 屏幕顺时针）
        let f = currentFraction()
        if f > 0 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: pieRect.midX, y: pieRect.midY))
            path.line(to: CGPoint(x: pieRect.midX, y: pieRect.maxY))
            path.appendArc(withCenter: CGPoint(x: pieRect.midX, y: pieRect.midY),
                           radius: pieDiameter / 2,
                           startAngle: 90,
                           endAngle: 90 - 360 * f,
                           clockwise: true)
            path.close()
            ink.setFill()
            path.fill()
        }
        // 外圈描边：线宽对齐同组 SF Symbol 图标 11pt 默认字重的笔画粗细
        let ring = NSBezierPath(ovalIn: pieRect)
        ring.lineWidth = 1
        ink.setStroke()
        ring.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - 点击（左键 = 手动刷新，右键 = 间隔单选菜单）

    override func mouseDown(with event: NSEvent) {
        // 按下即转交面板做点击/拖拽分流（阈值判断在 PanelDrag）；未接入时保持原「按下即刷新」
        guard let onDragStart else {
            onSelectRefresh?()
            needsDisplay = true
            return
        }
        onDragStart(event)
    }

    func performClickAction() {
        onSelectRefresh?()
        // onRefresh 已同步重建定时器 → provider 锚点=现在，立即重绘即归零
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let current = cycleProvider?().interval ?? 0
        let menu = NSMenu()
        for minutes in minuteOptions {
            let item = NSMenuItem(title: "\(minutes)分钟",
                                  action: #selector(intervalPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes * 60
            item.state = TimeInterval(item.tag) == current ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func intervalPicked(_ sender: NSMenuItem) {
        onSelectInterval?(TimeInterval(sender.tag))
    }

    // MARK: - hover（同 HoverIconButton：次背景色正圆背景 + 提亮，走事件级校验）

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
        guard HoverEnterValidation.isPlausible(event, in: self) else { return }
        isMouseInside = true
        updateHoverBgGeometry()
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor",
                        to: HoverIconButton.hoverBackgroundColor.cgColor)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        animateLayerKey(hoverBgLayer, keyPath: "backgroundColor", to: NSColor.clear.cgColor)
        needsDisplay = true
    }

    /// hover 背景几何：固定 buttonSize 正圆居中（不依赖 view bounds）
    private func updateHoverBgGeometry() {
        guard let l = layer, l.bounds.width > 0 else { return }
        hoverBgLayer.bounds = CGRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize)
        hoverBgLayer.position = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
    }

    // MARK: - 面板滚动 hover 同步
    func syncHoverState(_ inside: Bool) {
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }
}

/// 余额卡片容器：hover 材质（渐变背景 + 1.2pt 发丝描边）由容器共享的
/// `HoverMaterialHost` 统一承载——材质是**一个实体**，hover 在卡片之间转移时整块
/// 滑过去并停住；本卡只报告进出与自己的几何，并切换签到信息子视图颜色。
/// 点击卡片触发 onClick 回调（如打开对应平台主页或应用）。
class HoverCard: NSView, PanelScrollHoverSync {
    private var trackingArea: NSTrackingArea?
    private weak var dragContentView: NSView?
    private var dragNormalBackgroundColor: CGColor?
    private var hasCapturedDragBackground = false
    private var isMouseInside = false
    private var isDragHoverLocked = false
    /// 点击后主动清 hover 时置位：光标仍停留在原位，此后折叠/展开等内容位移触发的
    /// 补发 mouseEntered（系统 tracking 重算、syncHoverState 校准）不再点亮，
    /// 直到光标真实离开（mouseExited 复位）才恢复进入能力
    private var suppressEnterUntilExit = false
    /// 点击回调：由外部设置，mouseUp 时触发
    var onClick: (() -> Void)?
    /// 临时诊断（2026-09-06 假 hover 排查）：hover 事件日志的卡片标识，验完移除
    var hoverDebugLabel = ""
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
    /// hover 确认时长（Agent 卡 Token 板块切换用）：设置后进入卡片按常规亮起 hover
    /// 材质，驻留满时长触发 onHoverConfirmed；提前真实离开取消并复位。几何变化补发的
    /// exit（事件位置仍在卡内）与补发 enter（isMouseInside 未清）均不重置计时，
    /// 避免确认切换引发高度变化后重跑。
    /// （原「光晕下移进度填充」视觉随烘焙位图一起删除——2026-09-08 用户要求去掉
    /// 烘焙位图，深浅主题统一淡渐变 hover，驻留只保留计时语义）
    var hoverDwellDuration: CFTimeInterval?
    /// 进度撑满回调（主线程，时长到达时触发一次）
    var onHoverConfirmed: (() -> Void)?
    private var dwellWork: DispatchWorkItem?
    private var dwellConfirmed = false
    /// 最近一次用过的共享 hover 材质宿主（卡片被移出层级后 superview 链已断，靠它收材质）
    private weak var cachedMaterialHost: HoverMaterialHost?

    /// hover 材质（渐变背景 + 发丝描边）由容器共享（`HoverMaterialHost`），本卡不自持图层：
    /// 材质是**一个实体**，hover 在卡片之间转移时整块滑过去并停住，而不是两卡各自
    /// 淡入 / 被自身边界裁成蒙版式的滑入（2026-09-10 用户口径：「这个框要完整的从一个卡片
    /// 位置移动到另个卡片的位置然后停住」、「背景色现在也跟随边框移动，而不是蒙版」）。
    /// 未安装宿主的窗口（若将来有）只是没有 hover 材质，其余外观不受影响。
    private func syncHoverMaterial(_ visible: Bool, immediate: Bool = false) {
        let host = hoverMaterialHost ?? cachedMaterialHost
        guard let host else { return }
        cachedMaterialHost = host
        if visible {
            host.show(for: self, immediate: immediate)
        } else {
            host.cardDidExit(self)
        }
    }

    /// 卡片被移出层级（账号重建）时 superview 链已断，靠缓存的宿主通知收材质
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cachedMaterialHost?.cardDidExit(self) }
    }

    var dragContentLayer: CALayer? { dragContentView?.layer }

    func configureDragContentView(_ view: NSView) {
        view.wantsLayer = true
        dragContentView = view
        if !hasCapturedDragBackground {
            // 记录时刻已在层级内：非透明卡会有 kCardBackground.cgColor（可能是 clear），
            // 平台卡等透明卡的 backgroundColor 为 nil。按当前值原样保存，后续不覆盖。
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

    /// 异步落点（计时回调）的权威在场校验：视图仍在窗口层级且光标仍在卡片 bounds 内。
    /// 与 isPointerInsideCard 的区别：窗口已脱离（面板收起）时 isMouseInside 是滞留真值，
    /// 此处按「不在场」处理。不依赖 enter/exit 事件配对——快速掠过时真实离开的 exit
    /// 可能丢失或被 dwell 卡的陈旧坐标闸误吞，事件计数不可信，落点时刻以光标位置为准。
    var isPointerInsideNow: Bool {
        guard window != nil else { return false }
        return isPointerInsideCard()
    }

    /// 离开收尾：取消进度 + 状态复位 + hover 材质交给宿主（宽限后淡出 / 下一张卡接管）
    /// + onHover(false)。mouseExited 真实离开路径与 dwell 计时落点自检共用
    /// （保证两条路径视觉/回调一致）。
    private func performHoverExitVisuals() {
        cancelHoverDwell()
        isMouseInside = false
        suppressEnterUntilExit = false
        if isDragHoverLocked { return }
        syncHoverMaterial(false)
        onHover?(false)
    }

    // MARK: - 面板滚动 hover 同步
    /// 滚动后 AppKit 不补发 enter/exit：按外部（hitTest）判定同步。
    /// 拖拽锁定期间跳过（材质由 setDragHoverLocked 全权管理）。
    func syncHoverState(_ inside: Bool) {
        guard !isDragHoverLocked else { return }
        if inside == isMouseInside { return }
        Logger.log(.layout, "[HoverDbg] sync \(hoverDebugLabel) -> \(inside) cursor=\(NSEvent.mouseLocation) cardOnScreen=\(window.map { $0.convertToScreen(convert(bounds, to: nil)) ?? .zero }) win=\(window?.frame ?? .zero)")
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }

    /// 拖拽期间收起 hover 材质，避免卡片随幽灵位置移动到光标下方时重新亮起。
    /// 归位交接时传入 animated=false，直接落到最终状态，避免与幽灵卡片重叠一帧。
    func setDragHoverLocked(_ locked: Bool, animated: Bool = true) {
        guard isDragHoverLocked != locked else { return }
        isDragHoverLocked = locked
        if locked {
            cancelHoverDwell()
            layer?.backgroundColor = dragNormalBackgroundColor ?? kCardBackground.cgColor
            // 材质不该跟着幽灵卡片跑
            hoverMaterialHost?.hideNow()
            return
        }

        let showing = isPointerInsideCard()
        isMouseInside = showing
        layer?.backgroundColor = dragNormalBackgroundColor ?? kCardBackground.cgColor
        // 拖拽已把材质收起（hideNow），归位按「首次出现」落位；animated=false 时直接显示
        syncHoverMaterial(showing, immediate: !animated)
        onHover?(showing)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 尺寸变化后（驻留切换高度等）让共享材质贴回卡片轮廓
    override func layout() {
        super.layout()
        // 本卡不再自持 hover 图层：尺寸变化时让共享材质贴回卡片轮廓
        // （驻留切换高度 / 内容变化都会走到这里）
        hoverMaterialHost?.updateGeometry(for: self)
    }

    /// 动态色经 .cgColor 落盘会定格当时外观：系统主题切换时按新 effectiveAppearance 重解算
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 共享材质的渐变颜色与描边色都是定格色，交给宿主重解算
        hoverMaterialHost?.refreshAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        // mouseMoved：其余账号项的按钮高亮/昵称气泡由卡片按光标位置统一驱动
        // （整卡 hitTest 接管下，子视图自身 tracking 不投递）
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    /// 点击后鼠标通常仍停留在卡片内，AppKit 不会重新派发 mouseExited；
    /// 主动清除 hover 材质，避免点击可折叠标题后高亮一直残留。
    func clearHoverEffect() {
        cancelHoverDwell()
        isMouseInside = false
        suppressEnterUntilExit = true
        guard !isDragHoverLocked else { return }
        syncHoverMaterial(false)
        onHover?(false)
    }

    /// 可排序卡片不把事件命中交给内部 label、图标等子视图，确保整张卡片都能开始拖拽。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if onDragStarted != nil, bounds.contains(point) {
            return self
        }
        return super.hitTest(point)
    }

    /// 当前账号积分 chip 命中区域提供者（返回本卡坐标系命中区；chip 未点亮返回 nil）——
    /// chip 是 RollingNumberView 内的 CALayer、无自有 tracking，hover 判定并入卡片统一驱动
    var chipHitRectProvider: (() -> NSRect?)?
    /// chip hover 进出回调（面板侧挂 0.3s 防扫过后弹昵称+积分气泡）
    var onChipHover: ((Bool) -> Void)?
    private var chipHovered = false

    /// 其余账号项 hover 统一由卡片按光标位置驱动（mouseMoved / enter / exit 三入口）：
    /// 命中项点亮、其余熄灭；合成事件（无 window,如 syncHoverState 自造 NSEvent）跳过
    private func syncInteractiveHover(at event: NSEvent) {
        guard event.window != nil else { return }
        syncInteractiveHover(atWindowPoint: event.locationInWindow)
    }

    private func syncInteractiveHover(atWindowPoint p: NSPoint) {
        let hit = interactiveSubview(at: p) as? SubAccountItemView
        for case let item as SubAccountItemView in interactiveSubviews {
            item.setHovered(item === hit)
        }
        // 当前账号积分 chip：命中区域由 provider 按点亮态给出（未点亮 nil 恒熄）
        var chipHit = false
        if let rect = chipHitRectProvider?(), rect.contains(convert(p, from: nil)) {
            chipHit = true
        }
        if chipHit != chipHovered {
            chipHovered = chipHit
            onChipHover?(chipHit)
        }
    }

    /// 以当前真实光标位置重算 hover：chip 换入落点（账号条 dwell 到时）后光标可能
    /// 恰停在积分按钮上静止——无 mouseMoved 补发，主动探测一次否则气泡永不弹出
    func syncInteractiveHoverFromCursor() {
        guard let w = window else { return }
        syncInteractiveHover(atWindowPoint: w.mouseLocationOutsideOfEventStream)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        syncInteractiveHover(at: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        syncInteractiveHover(at: event)
        let plausible = HoverEnterValidation.isPlausible(event, in: self)
        Logger.log(.layout, "[HoverDbg] enter \(hoverDebugLabel) plausible=\(plausible) real=\(isPointerInsideNow) loc=\(event.locationInWindow) cardOnScreen=\(window.map { $0.convertToScreen(convert(bounds, to: nil)) ?? .zero }) win=\(window?.frame ?? .zero)")
        guard plausible else { return }
        // dwell 卡确认切换会改 Token 板块高度 → 窗口原点平移，AppKit 补发**陈旧窗口
        // 坐标**的 enter：光标停在全卡顶部附近时（看光晕下移时正是），错位量足以把
        // 补发落进上方卡片点亮假 hover（0.15s 后才被 scheduleHoverSync 校准熄灭）。
        // 事件坐标可陈旧、实时光标不会骗人：再按 mouseLocation 权威校验一次。
        if hoverDwellDuration != nil, event.window != nil, !isPointerInsideNow { return }
        // dwell 卡：确认后几何变化补发的 enter（isMouseInside 未清）不重启进度
        if isMouseInside, hoverDwellDuration != nil { return }
        isMouseInside = true
        if isDragHoverLocked || suppressEnterUntilExit { return }
        if let dwell = hoverDwellDuration, !dwellConfirmed {
            startHoverDwell(duration: dwell)
        } else {
            syncHoverMaterial(true)
        }
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        Logger.log(.layout, "[HoverDbg] exit \(hoverDebugLabel) loc=\(event.locationInWindow) cardOnScreen=\(window.map { $0.convertToScreen(convert(bounds, to: nil)) ?? .zero }) win=\(window?.frame ?? .zero)")
        // dwell 卡：几何变化补发的 exit 其事件位置仍在卡内（陈旧坐标），忽略——
        // 否则确认切换引发高度变化后进度被打回重跑；自造事件（syncHoverState，
        // window=nil）是 hitTest 权威判定，照常退出。此路径仅按位置重算 hover 项，
        // 光标未动高亮不该丢
        if hoverDwellDuration != nil, event.window != nil,
           bounds.contains(convert(event.locationInWindow, from: nil)) {
            syncInteractiveHover(at: event)
            return
        }
        // 先走离场视觉（onHover(false) → chip 冻结背景）再熄 chip hover：
        // 反过来 setHovered(false) 的背景淡出会先于冻结启动，chip 下沉期间
        // 背景快速化掉（「裸文本在下沉」的旧根因）
        performHoverExitVisuals()
        syncInteractiveHover(at: event)
    }

    /// 启动 hover 确认：材质照常就位，排驻留计时（满时长落点自检 + onHoverConfirmed）。
    /// （原「光晕位图下移」进度视觉已随烘焙位图删除）
    private func startHoverDwell(duration: CFTimeInterval) {
        syncHoverMaterial(true)
        dwellWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dwellWork != nil else { return }
            self.dwellWork = nil
            guard self.isPointerInsideNow else {
                // 落点自检：快速掠过的真实 exit 可能丢失或被陈旧坐标闸误吞，
                // 计时到点以光标真实位置为准——人不在卡上按真实离开收尾，不触发确认
                self.performHoverExitVisuals()
                return
            }
            self.dwellConfirmed = true
            self.onHoverConfirmed?()
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 取消/复位确认进度（真实离开、点击清除、拖拽锁定）
    private func cancelHoverDwell() {
        dwellWork?.cancel()
        dwellWork = nil
        dwellConfirmed = false
    }

    /// 点击卡片：mouseDown 记录按下位置，mouseUp 在 bounds 内时触发回调（避免拖出后误触）
    /// 可点击子区域（如 Agent 卡其余账号切换项）：mouseDown 落在这些视图内时，
    /// 点击转交该视图的 onClick，不再触发整卡 onClick/拖拽（整卡 hitTest 被本类
    /// 接管、子视图自身收不到事件，须由卡片代为路由）。
    var interactiveSubviews: [NSView] = []

    /// 命中检测：窗口坐标点落在任一 interactiveSubview 内返回该视图
    /// （isHiddenOrHasHiddenAncestor 覆盖条整体显隐：strip 隐藏期间不命中）
    private func interactiveSubview(at locationInWindow: NSPoint) -> NSView? {
        guard !interactiveSubviews.isEmpty else { return nil }
        let local = convert(locationInWindow, from: nil)
        return interactiveSubviews.first {
            // 命中框必须是按钮自身 bounds：点已转到按钮坐标系，若误用卡片 bounds,
            // 按钮内小正值恒落在卡片内 → 条上所有项全部命中、first 恒取左边项
            // （右边按钮 hover 无反应、点击触发左边账号的根因）
            !$0.isHiddenOrHasHiddenAncestor && $0.bounds.contains(convert(local, to: $0))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard onDragStarted != nil, let window else {
            // 不调用 super：避免被当作无意义点击传给父视图
            return
        }

        let start = event.locationInWindow
        // 可点击子区域优先：按下点在切换项内时，松手仍在项内才触发项的 onClick
        if let item = interactiveSubview(at: start) {
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                              until: .distantFuture,
                                              inMode: .eventTracking,
                                              dequeue: true) {
                if next.type == .leftMouseUp {
                    if interactiveSubview(at: next.locationInWindow) === item {
                        (item as? SubAccountItemView)?.onClick?()
                    }
                    return
                }
            }
            return
        }
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
    /// [GradProbe] 诊断去重键：只在「有无颜色/尺寸」变化时记一条，避免每次重绘刷屏
    private var probeKey = ""
    override func draw(_ dirtyRect: NSRect) {
        let key = "\(color != nil)+\(bottomColor != nil)+\(Int(bounds.width))x\(Int(bounds.height))"
        if key != probeKey {
            probeKey = key
            Logger.log(.layout, "[GradProbe] TintOverlay.draw id=\(ObjectIdentifier(self).hashValue) color=\(color != nil) bottom=\(bottomColor != nil) frame=\(bounds) hidden=\(isHidden) alpha=\(alphaValue) inWindow=\(window != nil)")
        }
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

    /// [GradProbe] 遮罩子视图几何/显隐快照（诊断 body 遮罩不生效用）
    var tintProbe: String {
        "tintFrame=\(tintView.frame) hidden=\(tintView.isHidden) alpha=\(tintView.alphaValue) containerFrame=\(frame) inWindow=\(tintView.window != nil)"
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

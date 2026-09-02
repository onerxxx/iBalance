// RollingNumberView.swift — 余额数值「逐位数字垂直滚动」视图（里程表 / odometer 效果）
//
// 结构：
//   RollingNumberView（数值容器，右对齐逐字符槽位）
//     ├─ DigitWheelView × N   数字位：0-9 垂直排成一条 strip，裁剪出单格高，
//     │                        目标数字变化时 strip 上下平移 → 该位数字垂直滚动
//     └─ TextSlotView × M     静态位（自绘）：¥/$ 前缀（60% 字号）、千分位逗号、
//                              小数点、% 后缀、占位 —；自绘避开 NSTextField cell 的
//                              文本内边距（会把字形右移 ~2pt），字形与数字轮同构图
//
// 水平对齐口径（与原单 label 右对齐连续排版像素级一致）：
//   - 所有槽宽取字形精确 advance（不 ceil）——逐槽连续排布 == 连续文本排版，
//     消除逐槽取整累积出的额外字距（实测 "1,234.56" Inter 13pt：精确 54.5pt vs 逐槽 ceil 60pt）；
//   - 数字位槽宽 = **当前显示数字的真实 advance**（非 tabular 统一位宽）：
//     比例数字字体（Inter 默认数字 "1"=5.5 vs "0"=8.58）下静止排版与单 label 完全一致；
//     滚动时槽宽由车轮的连续滚动位置推导（与滚动同参数插值）——右缘固定、
//     左缘随宽度变化平移，非等宽字体滚动自然不抖不跳；等宽/monospacedDigit 字体下
//     各数字 advance 相等，槽宽恒定，行为与 tabular 方案零差异；
//   - 数字轮 cell 字形贴槽左（kern=0 自然定位），右对齐时数值右边缘 =
//     最后一位 advance 边界，整齐。
//   - 槽位右锚点 = bounds.width − 2.5（原右对齐 label 的 textContainer
//     lineFragmentPadding=2.5，文本行右缘实际在单元格右缘 − 2.5 处；
//     锚在 65 会整体右偏 2.5pt，即「数字偏右」根因，已修正）。
// 垂直对齐口径：货币前缀小字与主数字**基线对齐**——静态槽高度 = 自身字体行高，
//   y = 主字体 ascender − 前缀 ascender（label 无论贴顶/垂直居中，高度=自身行高时两者等价）。
//
// 动画模型（自驱动）：终值文本一次下发（setText(animated: true, rollDuration:)），
// 每个数字轮拿自己的最终目标数字，各自跑一段独立 tween：行进 d 格耗时
// = rollDuration × d/10 —— 全体车轮共享同一角速度，最长 10 格的行程恰好占满
// rollDuration 预算；行进距离不同的位到达时刻天然错开（异步落定，里程表观感：
// 各轮转到自己的数字就停，不等别的轮）。每轮再有 ±6% 确定性相位抖动，
// 打破「行进距离恰好相同」的车轮之间的同步。
// 中途改目标（新数据打断未完的滚动）时，从所在的连续位置重新规划 tween，天然续接。
// 滚动期间每帧重排 slots（数字右缘固定、左缘随槽宽插值平移——比例数字字体下的
// 自然滚动观感）。面板不可见时冻结进度并挂起 ticker，回窗口后续滚。
// 位数变化（如 99.9 → 100.1 跨位数）时结构不匹配 → 整组重建直接落值（单帧，可接受）。

import Cocoa

/// 字形精确 advance 宽度（fileprivate：DigitWheelView / RollingNumberView 共用）
private func textWidth(_ s: String, font: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
}

private extension Int {
    var mod10: Int {
        let r = self % 10
        return r >= 0 ? r : r + 10
    }
}

// MARK: - DigitWheelView（单个数字位的车轮）

/// 数字轮：0-9 十个数字垂直排列，首尾各补一格（顶部 9 / 底部 0）支持跨 0 环绕的
/// 最短路径滚动；视图裁剪出单格高度窗口，滚动 = 平移 strip。
final class DigitWheelView: NSView {

    /// 主字体（与数值整体字体一致；变化时重算度量并重渲染 strip）
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold) {
        didSet { guard font != oldValue else { return }; rebuildMetrics() }
    }
    /// 数字颜色（hover 提亮时由外部整体设置）
    var textColor: NSColor = Palette.cardForeground {
        didSet {
            guard textColor != oldValue else { return }
            rebuildStrip()
        }
    }
    /// 数字带是预渲染位图，动态色定格其中：系统主题/面板外观（渐变开关）切换时重渲
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildStrip()
    }

    /// 单格行高（滚动步长 = 一格）：ascender - descender + leading
    private var cellH: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// 落定数字（滚动期间恒定取目标值）：外部按字符求墨迹空档用，
    /// 恒定值保证 chip 右缘在滚动全程不抖（落定即精确值）
    var displayDigit: Int { ((Int(round(targetPos)) % 10) + 10) % 10 }

    /// 当前槽宽：从连续滚动位置计算出的数字 advance。
    /// 非等宽字体下，1→8 滚动时宽度也随滚动进度连续变化；
    /// 等宽字体下自然变成恒定宽度。
    private(set) var currentWidth: CGFloat = 0

    /// 每个数字自己的真实 advance。不要用统一 tabular width 做外部排版，
    /// tabularWidth 只负责给内部排版提供足够的绘制宽度。
    private var digitWidths: [CGFloat] = []
    private var tabWidth: CGFloat = 0

    /// 数字带图层：12 格（含顶部 9/底部 0 环绕缓冲）一次性预渲染成位图，
    /// 滚动每帧只改图层 origin.y —— 主线程零绘制，合成器以屏幕刷新率平移。
    /// 这是流畅度的根本保障（此前逐帧 draw 是掉帧根因；计数频率反而是次要的）。
    private let stripLayer = CALayer()
    private var stripCGImage: CGImage?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true   // 只露出单格高度窗口
        layer?.addSublayer(stripLayer)
        rebuildMetrics()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 0-9 最大 advance（诊断/排布参考）
    static func tabularWidth(_ font: NSFont) -> CGFloat {
        let widths = (0...9).map { textWidth(String($0), font: font) }
        return widths.max() ?? textWidth("0", font: font)
    }

    /// 12 格：i=0 → "9"（顶部环绕）、i=1...10 → "0"..."9"、i=11 → "0"（底部环绕）
    private func rebuildMetrics() {
        digitWidths = (0...9).map { textWidth(String($0), font: font) }
        tabWidth = digitWidths.max() ?? textWidth("0", font: font)
        rebuildStrip()
        currentWidth = widthForPosition(pos)
    }

    /// 一次性渲染整条数字带（12 格位图，@2x）。
    /// 位图上下文非 flipped（y 向上）：cell i 画在 (11-i)*cellH，使图像首行 = cell 0，
    /// 作为 layer.contents 时 cell 0 位于图层顶部——与旧 draw 的视觉顺序一致。
    /// ⚠️ 动态色在位图里按 NSAppearance.current 解算后定格——必须包在本视图的
    /// effectiveAppearance 下渲染（面板后台刷新时 current 可能是系统浅色，直接渲染
    /// 会把黑字定格进位图，渐变开的深色面板上不可读）。
    private func rebuildStrip() {
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            self.renderStripBitmap()
        }
    }

    private func renderStripBitmap() {
        let w = ceil(max(tabWidth, 1))
        let h = cellH * 12
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .calibratedRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for i in 0..<12 {
            let d = ((i - 1) % 10 + 10) % 10
            let s = NSAttributedString(string: String(d), attributes: [
                .font: font,
                .foregroundColor: textColor,
            ])
            s.draw(at: NSPoint(x: 0, y: CGFloat(11 - i) * cellH))
        }
        NSGraphicsContext.restoreGraphicsState()
        stripCGImage = rep.cgImage
        stripLayer.contents = stripCGImage
        stripLayer.contentsScale = scale
        stripLayer.frame = NSRect(x: 0, y: 0, width: w, height: h)
        stripLayer.isGeometryFlipped = true   // 视图 flipped：子层几何按 y 向下解释
        applyStripOrigin()
    }

    override func layout() {
        super.layout()
        applyStripOrigin()
    }

    /// 设置目标数字。animated=false 直接落位（含槽宽）；true 从当前连续位置向
    /// 目标做一段独立 tween（时长由 rollDuration 按行进格数分配），到点精确停在目标位。
    func setDigit(_ d: Int, animated: Bool, rollDuration: CFTimeInterval = 0.9) {
        let best = nearestEquivalentTarget(d).target
        if animated {
            targetPos = best
            beginTween(to: best, rollDuration: rollDuration)
        } else {
            pos = best
            targetPos = best
            tweenDuration = 0   // 使任何进行中的 tween 失效
            currentWidth = widthForPosition(pos)
            applyStripOrigin()
        }
    }

    /// 目标等价位选择：环绕缓冲区内取「距当前位置最近」的等价位置（如 9→0 走 1 格
    /// 而不是 9 格）。只允许 [0, 10] 内的等价位置：顶部缓冲 -1 处 strip 完全不覆盖
    /// 窗口（渲染空白），0→9 改走正面长滚（9 格），9→0 仍走 1 格底缓冲（10）。
    /// setDigit 与 plannedTravelCells 共用本口径，勿单边修改。
    private func nearestEquivalentTarget(_ d: Int) -> (target: Double, cells: Double) {
        let db = Double(d)
        var best = db
        var bestDist = abs(db - pos)
        for delta in [10.0] {   // 只考虑底部缓冲 +10；-10（顶部缓冲 pos=-1）禁用
            let cand = db + delta
            if cand >= 0.0 && cand <= 10.0 {
                let dist = abs(cand - pos)
                if dist < bestDist { best = cand; bestDist = dist }
            }
        }
        return (best, bestDist)
    }

    /// 只询距离不落位：若此刻 setDigit(d) 将行进的格数（整段式时长归一预算用）
    func plannedTravelCells(to d: Int) -> Double {
        nearestEquivalentTarget(d).cells
    }

    /// 规划一段 tween：从当前位置出发到 dest，行进 d 格耗时 = rollDuration × d/10。
    /// 全体车轮共享同一角速度 → 最长 10 格的车轮恰好占满 rollDuration；
    /// 行进距离不同的位到达时刻天然错开。±6% 确定性相位抖动消除「同距离
    /// 车轮完美同步」的机械感。同一格距重复触发（0 格）时 tween 时长为 0 →
    /// advance 首帧即落定，不产生无谓滚动。
    private func beginTween(to dest: Double, rollDuration: CFTimeInterval) {
        tweenStart = pos
        tweenElapsed = 0
        let cells = abs(dest - pos)
        let phase = 0.94 + 0.12 * tweenPhase   // 0.94…1.06，实例级恒定
        tweenDuration = rollDuration * cells / 10 * phase
    }

    /// 实例固定相位 0..<1（确定性伪随机：同距离车轮因各自的相位而错峰落定；
    /// 对单个轮子在其生命周期内恒定，重启 App 变化与否无感知影响）
    private lazy var tweenPhase: Double = {
        let m = ObjectIdentifier(self).hashValue.magnitude
        return Double(m % 997) / 997.0
    }()

    /// 帧推进：沿本段 tween 时间轴积分（ease-out cubic：起手快、收尾稳，
    /// 与全 App 动效语言一致），到点后精确落在目标位置——时间轴模型没有
    /// 指数尾巴，天然不存在亚像素爬行的逐帧微抖。
    /// 槽宽永远由连续位置推导（单一状态源），每帧只改 strip 图层位置，
    /// 无任何主线程重绘。返回是否仍在滚动。
    func advance(dt: CFTimeInterval) -> Bool {
        guard tweenDuration > 0 else { return false }   // 无进行中的 tween：已落定
        tweenElapsed += dt
        let p = min(1, tweenElapsed / tweenDuration)
        let eased = 1 - pow(1 - p, 3)
        pos = tweenStart + (targetPos - tweenStart) * eased
        if !widthFrozen { currentWidth = widthForPosition(pos) }
        applyStripOrigin()
        if p >= 1 {
            pos = targetPos            // 精确落点
            normalize()
            tweenDuration = 0
            if !widthFrozen { currentWidth = widthForPosition(pos) }
            applyStripOrigin()
            return false
        }
        return true
    }

    /// 槽宽冻结（结构变化滑移期专用）：比例数字字体下槽宽随滚动位置逐帧插值，
    /// 逐帧累计位置漂移与整组平移叠加会让相邻位视觉换位——冻结后槽宽恒为
    /// 目标位宽（垂直滚动照常），水平每帧位置恒定 = 纯平移。
    /// 调 freezeWidthAtTarget 冻结、unfreezeWidth 解冻（滑移落定时必须解冻）。
    private var widthFrozen = false
    func freezeWidthAtTarget() {
        widthFrozen = true
        currentWidth = widthForPosition(targetPos)
    }
    func unfreezeWidth() {
        guard widthFrozen else { return }
        widthFrozen = false
        currentWidth = widthForPosition(pos)
    }

    // —— 独立 tween 状态（每位车轮自己的时间轴；不共享任何全局缓动参数）——
    private var tweenStart: Double = 0          // 本段动画起点（连续位置）
    private var tweenElapsed: CFTimeInterval = 0
    private var tweenDuration: CFTimeInterval = 0   // 0 = 无动画（已落定）

    /// 根据连续位置计算当前槽宽。
    /// 例如 1→8 的中间态，宽度在 advance(1) 与 advance(8) 之间连续插值。
    /// 这样既保留垂直滚动，又保持比例数字字体的横向排版正确。
    private func widthForPosition(_ p: Double) -> CGFloat {
        guard digitWidths.count == 10 else { return 0 }
        let base = floor(p)
        let t = p - base
        let a = Int(base).mod10
        let b = (a + 1).mod10
        return digitWidths[a] + (digitWidths[b] - digitWidths[a]) * CGFloat(t)
    }

    /// 落定后把位置归一回 [0,10)，避免多轮滚动后向缓冲区漂移
    private func normalize() {
        guard pos < 0 || pos >= 10 else { return }
        var p = pos.truncatingRemainder(dividingBy: 10)
        if p < 0 { p += 10 }
        pos = p
        targetPos = p
    }

    /// 连续位置（单位=格）：0...9 对应数字 0...9，[-1,10] 为环绕缓冲区；
    /// 动画期间取中间值实现平滑滚动
    private var pos: Double = 0
    private var targetPos: Double = 0

    private func applyStripOrigin() {
        // cell i 的顶边 = (i-1-pos)*cellH；strip 首行(cell 0)的顶边 = -(1+pos)*cellH
        let y = -(1.0 + CGFloat(pos)) * cellH
        // 像素网格对齐（2x 屏 = 0.5pt 步进）：连续小数位置会让合成器把预渲染位图
        // 放在亚像素处重采样 → 字形边缘每帧微移（上下抖动/shimmer）。
        // 对齐后字形始终紧实，0.5pt 步进在 75Hz 下仍然顺滑。
        let scale = window?.backingScaleFactor ?? 2
        stripLayer.frame.origin.y = (y * scale).rounded() / scale
    }
}

// MARK: - TextSlotView（静态字符槽，自绘）

/// 静态字符槽（¥/$ 前缀、千分位逗号、小数点、% 后缀、占位 —）。
/// 用自绘绕过 NSTextField cell 的文本内边距（cell 会把字形右移 ~2pt，
/// 小数点/逗号紧邻数字时肉眼可辨——「. 偏右」根因）与自动缩放路径；
/// 绘制笔尖 = 槽左缘 = 排版 pen 位置，与数字轮/原单 label 构图一致。
final class TextSlotView: NSView {

    var text: String = "" {
        didSet { guard text != oldValue else { return }; needsDisplay = true }
    }
    var font: NSFont = NSFont.systemFont(ofSize: 13) {
        didSet { guard font != oldValue else { return }; needsDisplay = true }
    }
    var textColor: NSColor = .labelColor {
        didSet { guard textColor != oldValue else { return }; needsDisplay = true }
    }

    init(text: String, font: NSFont, color: NSColor) {
        self.text = text
        self.font = font
        self.textColor = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ]).draw(at: NSPoint(x: 0, y: 0))
    }
}

// MARK: - RollingNumberView（数值容器）

/// 余额数值逐位滚动视图：文本拆成逐字符槽位，数字位是车轮、其余是静态 label。
/// 对外行为对齐原右对齐 NSTextField：固定外部宽度内右对齐排布（超宽左溢裁掉）、
/// 暴露 baselineAnchor（内部隐藏同字体探针 label）供标题基线对齐。
final class RollingNumberView: NSView {

    typealias FontProvider = (CGFloat, NSFont.Weight, Bool) -> NSFont

    // —— 字体策略（由面板注入；Mono/Inter/系统开关切换时 refreshFont() 就地更新）——
    private var specSize: CGFloat = 13
    private var specWeight: NSFont.Weight = .semibold
    private var fontProvider: FontProvider = { size, weight, _ in
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private(set) var currentText: String = "—"   // 最近一次应用的文本（滚动续接/判据用）

    /// 排布对齐方向：默认右对齐（余额数值口径，右缘锚定 + 左溢裁剪）；
    /// 左对齐供 ZCode Token 子面板总计大数字使用（左缘贴版心，与原 drawText 排版一致）
    var alignsLeft = false

    /// 数值前缀图标（Agent 卡积分前的 coin 标记）：伴随视图，不参与 setText 的结构
    /// 比对与滑移复用，排布时贴最左槽左侧、与数字成组右对齐——数字槽宽逐帧变化时
    /// 随最左槽平移（固定锚在数值列左缘会与短数字拉开大空隙，故随组内嵌）。
    /// 图像须 isTemplate（着色随 setTextColor 同步）。nil = 无前缀。
    var prefixIcon: NSImage? {
        didSet {
            guard prefixIcon !== oldValue else { return }
            prefixIconView.image = prefixIcon
            prefixIconView.isHidden = prefixIcon == nil
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    /// 常规态前缀图标边长（chip 态切 ChipStyle.iconSize 与子账号按钮统一；面板按此
    /// 尺寸烘焙 2× 图像，chip 态只缩小绘制——放大糊、缩小清晰；离开 hover 复原此值）
    static let baseIconSize: CGFloat = 10
    private var prefixIconSize: CGFloat = RollingNumberView.baseIconSize
    private let prefixIconGap: CGFloat = ChipStyle.iconTextGap
    private let prefixIconView = NSImageView()

    private var mainFont: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private var prefixFont: NSFont = .monospacedDigitSystemFont(ofSize: 7.8, weight: .semibold)
    private var lineH: CGFloat = 16
    private var prefixLineH: CGFloat = 10
    private var digitWidth: CGFloat = 8   // 仅诊断日志用（字体等宽性验证）
    private var textColor: NSColor = Palette.cardForeground

    // —— 基础字体档（configure 注入）：chip 态切走、退出态复原的复原锚点 ——
    private var baseSize: CGFloat = 13
    private var baseWeight: NSFont.Weight = .semibold
    private var baseLineH: CGFloat = 16

    // —— 当前账号积分 hover chip（2026-09-02 用户定稿）——
    // 账号条换入时点亮：贴「前缀 icon + 数字组」实际边缘的圆角背景（不占 65pt 定宽），
    // 配色复用 ChipStyle（浅色主题反转同口径）。
    private let chipLayer = CALayer()
    private var isChipActive = false
    /// chip hover 态：背景在 ChipStyle.bgDefault/bgHover 两档间切换（与子账号按钮同款两档）
    private var isChipHovered = false

    /// 点亮/熄灭积分 chip。熄灭复原基础字体档 + cardForeground；
    /// chip hover 让位走 setDimmed（自动按激活态选正确复原色）
    func setChipActive(_ on: Bool) {
        guard isChipActive != on || (on && chipLayer.backgroundColor == nil) else { return }
        isChipActive = on
        // 字体切子账号 chip 同款（ChipStyle 统一规格），退出回基础档
        specSize = on ? ChipStyle.fontSize : baseSize
        specWeight = on ? ChipStyle.fontWeight : baseWeight
        // 图标同步切 chip 档（与子账号按钮同尺寸），退出复原常规档边长
        prefixIconSize = on ? ChipStyle.iconSize : Self.baseIconSize
        refreshFont()
        relayoutSlots()
        invalidateIntrinsicContentSize()
        resolveChipColor()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        chipLayer.isHidden = false
        chipLayer.opacity = on ? 1 : 0
        CATransaction.commit()
        setTextColor(on ? ChipStyle.fgMain : Palette.cardForeground)
    }

    /// chip hover 让位/复原：dim 系统灰；复原按激活态回 chip 前景或常规前景
    func setDimmed(_ dim: Bool) {
        setTextColor(dim ? .systemGray
                        : (isChipActive ? ChipStyle.fgMain : Palette.cardForeground))
    }

    /// chip 点亮时的命中区域（chipLayer frame 转换到 target 视图坐标系）；未点亮返回 nil。
    /// chip 是 CALayer 无自有 tracking：光标是否悬停在积分按钮上由所在卡片的
    /// mouseMoved/enter/exit 统一换算判定（HoverCard.chipHitRectProvider 消费）
    func chipHitRect(in target: NSView) -> NSRect? {
        guard isChipActive, !chipLayer.isHidden else { return nil }
        return target.convert(chipLayer.frame, from: self)
    }

    /// chip hover 反馈：背景切 ChipStyle.bgHover 档（0.85 不透明度保留反馈差），
    /// 离开复原 bgDefault；时长与卡片 hover 背景一致（Motion.hover）。仅点亮态可见
    func setChipHovered(_ on: Bool) {
        guard isChipHovered != on else { return }
        isChipHovered = on
        guard isChipActive else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.hover)
        resolveChipColor()
        CATransaction.commit()
    }

    /// 动态色经 .cgColor 落盘定格外观：主题切换时重解算（仅激活时可见，未激活等下次点亮）
    private func resolveChipColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.chipLayer.backgroundColor =
                (self.isChipHovered ? ChipStyle.bgHover : ChipStyle.bgDefault).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isChipActive { resolveChipColor() }
    }

    private enum SlotKind { case digit, prefix, plain }
    private struct Slot {
        let view: NSView
        let kind: SlotKind
        var width: CGFloat   // 静态槽：精确 advance（不取整）；数字槽：初始值，排布时读 wheel.currentWidth
        var yOff: CGFloat    // 静态槽基线对齐偏移（flipped 坐标，y 向下）
        var height: CGFloat  // 槽高：digit/plain=主行高，prefix=自身行高（基线对齐口径）
    }
    private var slots: [Slot] = []

    /// 基线探针：隐藏 label 与主数字同字体，firstBaselineAnchor 供外部基线约束
    private let baselineProbe = NSTextField(labelWithString: "0")
    private var probeHeightC: NSLayoutConstraint?

    var baselineAnchor: NSLayoutYAxisAnchor { baselineProbe.firstBaselineAnchor }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        var w = slots.reduce(0) { $0 + slotWidth($1) }
        if prefixIcon != nil { w += prefixIconGap + prefixIconSize }
        // 高度取基础档行高：chip 态字体缩小行高变小，但视图高度保持 16（row1 基线
        // 探针/标题基线约束稳定，标题不随 hover 态跳动）；槽位在 relayoutSlots 垂直居中
        return NSSize(width: w, height: max(lineH, baseLineH))
    }

    init() {
        super.init(frame: .zero)
        // 左溢裁剪：复刻原右对齐 label 超宽时裁掉左侧（数值尾部优先可见）的边界行为
        wantsLayer = true
        layer?.masksToBounds = true
        chipLayer.cornerRadius = ChipStyle.cornerRadius
        chipLayer.isHidden = true
        chipLayer.opacity = 0
        layer?.insertSublayer(chipLayer, at: 0)   // 垫底：子视图槽位（含各自 layer）在其上
        baselineProbe.isHidden = true
        baselineProbe.font = mainFont
        baselineProbe.cell?.wraps = false
        baselineProbe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(baselineProbe)
        NSLayoutConstraint.activate([
            baselineProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
            baselineProbe.trailingAnchor.constraint(equalTo: trailingAnchor),
            baselineProbe.topAnchor.constraint(equalTo: topAnchor),
        ])
        prefixIconView.isHidden = true
        // 图像按常规态边长烘焙，chip 态缩小绘制（frame 由 prefixIconSize 逐帧给出）
        prefixIconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(prefixIconView)
        setText("—", animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 面板注入字体规格与提供器（uiFont：Mono/Inter/系统 + 等宽数字策略）
    func configure(size: CGFloat, weight: NSFont.Weight, fontProvider: @escaping FontProvider) {
        baseSize = size          // 基础档：chip 态退出的复原锚点
        baseWeight = weight
        specSize = size
        specWeight = weight
        self.fontProvider = fontProvider
        refreshFont()
        // 字体与数字等宽性 dump（比例数字字体下槽宽动态方案的关键判据）
        let dw = (0...9).map { String(format: "%.2f", textWidth(String($0), font: mainFont)) }
        Logger.log(.layout, "[RollDiag] font=\(mainFont.fontName) size=\(mainFont.pointSize) digits=[\(dw.joined(separator: ","))] tabW=\(digitWidth)")
    }

    /// Mono/Inter 开关切换后就地刷新字体（不重建槽位，滚动状态保留）。
    /// 数字槽宽由 wheel 按新字体重算（rebuildCells 内落位）。
    func refreshFont() {
        // chip 态用子账号 chip 同款字体（9pt semibold、非 mono）；常规态走基础档（mono 等宽数字）
        mainFont = fontProvider(specSize, specWeight, !isChipActive)
        // ¥/$ 前缀：60% 字号 semibold（对齐原 applyValueText 富文本策略，不用等宽数字）
        prefixFont = fontProvider(specSize * 0.6, .semibold, false)
        lineH = ceil(mainFont.ascender - mainFont.descender + mainFont.leading)
        prefixLineH = ceil(prefixFont.ascender - prefixFont.descender + prefixFont.leading)
        digitWidth = DigitWheelView.tabularWidth(mainFont)
        // 基线探针恒用基础档字体：对外 firstBaselineAnchor 稳定，标题行不随 chip 态跳动
        let probeFont = fontProvider(baseSize, baseWeight, true)
        baseLineH = ceil(probeFont.ascender - probeFont.descender + probeFont.leading)
        baselineProbe.font = probeFont
        probeHeightC?.isActive = false
        let hc = baselineProbe.heightAnchor.constraint(equalToConstant: baseLineH)
        hc.isActive = true
        probeHeightC = hc
        for i in slots.indices {
            let s = slots[i]
            if let w = s.view as? DigitWheelView {
                w.font = mainFont   // didSet → rebuildCells 按新字体落位槽宽
            } else if let t = s.view as? TextSlotView {
                let f = (s.kind == .prefix) ? prefixFont : mainFont
                t.font = f
                slots[i].width = textWidth(t.text, font: f)
                slots[i].yOff = mainFont.ascender - f.ascender
                slots[i].height = (s.kind == .prefix) ? prefixLineH : lineH
            }
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    /// 设置数值文本。结构不变（数字位/静态位一一对应）→ 终值一次下发，各位数字
    /// 轮独立滚动到自己的目标数字后停下（异步落定）；
    /// 结构变化（位数增减、— ↔ 数值等）→ 整组重建直接落值；
    /// slideOnRebuild=true 时结构变化走「整组滑移」：数字轮从右对齐配对复用（原地
    /// 滚到新值），全体槽位从旧布局缓动平移到新布局——变长时原数字右移、新增高位
    /// 从左移入；变短时整组左移、移出高位列随组滑出后移除（周期切换等用户主动换值；
    /// 打开/后台刷新保持直接落值不变）。
    /// rollDuration：本次滚动/滑移的时长预算，仅 animated=true 时生效。
    /// totalDuration：整段式时长（开面板补发口径，非 nil 时忽略 rollDuration）——先求本轮
    /// 最大行进格数，把预算换算成「最长轮恰好占满 totalDuration」，其余车轮按格数等比
    /// 提前落定（共享角速度、错峰到达的设计不变），整段动画从开始到停下恒为 totalDuration。
    func setText(_ text: String, animated: Bool, rollDuration: CFTimeInterval = 0.9,
                 slideOnRebuild: Bool = false, totalDuration: CFTimeInterval? = nil) {
        endSlide()   // 在途滑移立即落定，防陈旧槽位干扰结构比对
        let structureChanged: Bool
        let chars = Array(text)
        let isDigit = chars.map { $0.isASCII && $0.isNumber }
        if chars.count == slots.count,
           zip(isDigit, slots).allSatisfy({ $0.0 == ($0.1.kind == .digit) }) {
            var effectiveRoll = rollDuration
            if animated, let total = totalDuration {
                var maxCells = 0.0
                for (i, ch) in chars.enumerated() where isDigit[i] {
                    if let w = slots[i].view as? DigitWheelView, let d = ch.wholeNumberValue {
                        maxCells = max(maxCells, w.plannedTravelCells(to: d))
                    }
                }
                if maxCells > 0 { effectiveRoll = total * 10 / maxCells }
            }
            for (i, ch) in chars.enumerated() {
                if isDigit[i], let w = slots[i].view as? DigitWheelView, let d = ch.wholeNumberValue {
                    w.setDigit(d, animated: animated, rollDuration: effectiveRoll)
                } else if let t = slots[i].view as? TextSlotView {
                    if t.text != String(ch) {
                        t.text = String(ch)
                        // 静态字符变化同步槽宽（如 ¥ ↔ $、千分位变化）
                        let f = (slots[i].kind == .prefix) ? prefixFont : mainFont
                        slots[i].width = textWidth(String(ch), font: f)
                    }
                }
            }
            if animated {
                startTicker()
            } else {
                // 非动画落位（数字槽宽/静态字符宽度已同步更新），重排一次
                relayoutSlots()
                invalidateIntrinsicContentSize()
            }
            structureChanged = false
        } else {
            rebuild(chars, slideOnRebuild: animated && slideOnRebuild, rollDuration: rollDuration)
            structureChanged = true
            // TODO(性能诊断): 每次结构重建打日志（滚动期间频繁重建 = 无动效根因），确认后移除
            Self.rebuildLogCount += 1
            if Self.rebuildLogCount <= 20 {
                Logger.log(.layout, "[RollDbg] REBUILD '\(text)' slots=\(slots.count) chars=\(chars.count)")
            }
        }
        currentText = text
        if structureChanged {
            // 结构变化触发布局/固有尺寸重算
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }
    private static var rebuildLogCount = 0

    /// 设置整组前景色（hover 提亮/回暗；逐槽传播）
    /// - animated: true = Motion.hover(0.25s) display-link 逐帧 RGB 插值淡变
    ///   （chip hover 积分让位/复原动效）。自绘槽位不走 AppKit 动画，颜色渐变只能
    ///   逐帧重绘：动态色先按视图生效外观解算成 RGB 参与插值，落定帧写回原始
    ///   动态色（主题切换着色不受影响）；window 为空（卡片离屏）直接落值不空转。
    /// 设置整组前景色（chip hover 积分让位/复原；逐槽传播，瞬时切换不走动画）
    func setTextColor(_ c: NSColor) {
        textColor = c
        prefixIconView.contentTintColor = c
        for s in slots {
            if let w = s.view as? DigitWheelView { w.textColor = c }
            else if let t = s.view as? TextSlotView { t.textColor = c }
        }
    }

    // —— 内部 ——

    /// 重建槽位（结构变化）。slideOnRebuild=false：直接落值（打开/后台刷新口径）。
    /// true：结构变化滑移——数字轮按「从右对齐配对」复用（个位对个位，原地滚动到
    /// 新值），未复用的旧槽位作为移出列随组滑出后移除；新布局由 relayoutSlots 给出，
    /// 旧→新布局的平移由同一 ticker 驱动（见 onTick 滑移段），时长对齐 rollDuration。
    private func rebuild(_ chars: [Character], slideOnRebuild: Bool, rollDuration: CFTimeInterval) {
        // 旧槽位从右到左配对池：数字轮与「同字符」静态槽都可复用——静态槽若不复用，
        // 逗号会以「旧槽滑出 + 新槽滑入」两份存在，两条轨迹不同（delta ≠ 逗号自己的
        // 位移），中途会穿过相邻数字列 = 滑移期数字换位视觉 bug 的根源
        var reusePool: [NSView] = []
        var oldX: [ObjectIdentifier: CGFloat] = [:]
        for s in slots.reversed() { reusePool.append(s.view) }
        for s in slots { oldX[ObjectIdentifier(s.view)] = s.view.frame.origin.x }
        let oldViews = slots.map { $0.view }
        let oldWidth = slots.reduce(0) { $0 + slotWidth($1) }
        let oldHadContent = !slots.isEmpty

        // 先按从右到左扫描标记每个新槽位复用池里的哪个候选（数字对数字、同字符静态
        // 对同字符静态；不兼容时不推进池，左侧继续尝试）。记录原始下标而非消费指针：
        // 构建循环按 LTR 走，若用共享指针会与 RTL 标记序错位（错配 + 越界崩溃）
        var reuseSource = [Int?](repeating: nil, count: chars.count)
        var poolIdx = 0
        for i in stride(from: chars.count - 1, through: 0, by: -1) {
            guard poolIdx < reusePool.count else { break }
            let ch = chars[i]
            let cand = reusePool[poolIdx]
            let compatible: Bool
            if ch.isASCII, ch.isNumber {
                compatible = cand is DigitWheelView
            } else {
                compatible = cand is TextSlotView && (cand as? TextSlotView)?.text == String(ch)
            }
            if compatible {
                reuseSource[i] = poolIdx
                poolIdx += 1
            }
        }
        // 滑移成立才冻结槽宽（比例字体宽度插值 × 整组平移 = 相邻位换位，见 widthFrozen 注）
        let willSlide = slideOnRebuild && oldHadContent

        var reused: Set<ObjectIdentifier> = []
        var newSlots: [Slot] = []
        for (i, ch) in chars.enumerated() {
            if ch.isASCII, ch.isNumber, let d = ch.wholeNumberValue {
                let w: DigitWheelView
                if let src = reuseSource[i], let old = reusePool[src] as? DigitWheelView {
                    w = old
                    reused.insert(ObjectIdentifier(old))
                } else {
                    w = DigitWheelView()
                    w.font = mainFont
                    w.textColor = textColor
                    addSubview(w)
                }
                w.setDigit(d, animated: slideOnRebuild, rollDuration: rollDuration)
                if willSlide { w.freezeWidthAtTarget() }
                newSlots.append(Slot(view: w, kind: .digit, width: w.currentWidth,
                                     yOff: 0, height: lineH))
            } else {
                // 首字符 ¥/$ 且后面还有内容 → 货币符号小字号槽（对齐原 applyValueText 判定）
                let isPrefixSymbol = i == 0 && (ch == "¥" || ch == "$") && chars.count > 1
                let kind: SlotKind = isPrefixSymbol ? .prefix : .plain
                let f = isPrefixSymbol ? prefixFont : mainFont
                let t: TextSlotView
                if let src = reuseSource[i], let old = reusePool[src] as? TextSlotView {
                    t = old
                    reused.insert(ObjectIdentifier(old))   // 勿漏：否则旧逗号进滑出列表，落定时被连带移除
                } else {
                    t = TextSlotView(text: String(ch), font: f, color: textColor)
                    addSubview(t)
                }
                newSlots.append(Slot(view: t, kind: kind,
                                     width: textWidth(String(ch), font: f),
                                     yOff: mainFont.ascender - f.ascender,
                                     height: isPrefixSymbol ? prefixLineH : lineH))
            }
        }

        // 滑移状态先清（endSlide 不适用：槽位表已被替换），旧未复用视图先记后移除
        slideStarts.removeAll()
        slideExits.removeAll()
        slideDelta = 0
        slideElapsed = 0
        slideDuration = 0
        let newWidth = newSlots.reduce(0) { $0 + slotWidth($1) }
        for v in oldViews where !reused.contains(ObjectIdentifier(v)) {
            if slideOnRebuild, oldHadContent {
                let sx = oldX[ObjectIdentifier(v)] ?? v.frame.origin.x
                slideExits.append(SlideExit(view: v, startX: sx))
            } else {
                v.removeFromSuperview()
            }
        }
        slots = newSlots
        // 滑移状态必须先于 relayoutSlots 登记：relayout 是滑移感知的（按进度插值），
        // 状态空 = p=1 直接落终点，状态就位后这次调用即按起点铺首帧，无中间闪帧
        if slideOnRebuild, oldHadContent {
            slideDelta = newWidth - oldWidth
            for s in slots where reused.contains(ObjectIdentifier(s.view)) {
                if let sx = oldX[ObjectIdentifier(s.view)] {
                    slideStarts[ObjectIdentifier(s.view)] = sx
                }
            }
            slideDuration = rollDuration
            slideElapsed = 0
        }
        relayoutSlots()
        if slideDuration > 0 {
            startTicker()
        }
    }

    // —— 结构变化滑移（与车轮滚动共用 ticker；插值统一在 relayoutSlots 内做）——

    private struct SlideExit { let view: NSView; let startX: CGFloat }
    /// 保留槽位的旧布局 x（新布局 x 由 relayoutSlots 实时给出；新建槽起点 = 终点 − slideDelta）
    private var slideStarts: [ObjectIdentifier: CGFloat] = [:]
    /// 变短/换型时移出的旧槽位（随组滑出，落定移除）
    private var slideExits: [SlideExit] = []
    /// 新布局总宽 − 旧布局总宽：>0 变长（整组右移、高位移入），<0 变短（左移、移出）
    private var slideDelta: CGFloat = 0
    private var slideElapsed: CFTimeInterval = 0
    private var slideDuration: CFTimeInterval = 0

    /// 滑移进度 0→1（ease-out cubic；非滑移期恒 1 = 直接落最终布局）
    private func slideProgress() -> CGFloat {
        guard slideDuration > 0 else { return 1 }
        let p = min(1, slideElapsed / slideDuration)
        return CGFloat(1 - pow(1 - p, 3))
    }

    /// 滑移立即落定（setText 重入/视图销毁前的清理口径）
    private func endSlide() {
        guard slideDuration > 0 || !slideExits.isEmpty else { return }
        slideDuration = 0
        slideElapsed = 0
        slideDelta = 0
        slideStarts.removeAll()
        for s in slots { (s.view as? DigitWheelView)?.unfreezeWidth() }
        for e in slideExits { e.view.removeFromSuperview() }
        slideExits.removeAll()
        relayoutSlots()
    }

    /// 槽位末字符的墨迹右空档（数字槽取落定数字；静态槽取自身文本）
    private func trailingInkGap(_ s: Slot) -> CGFloat {
        if let w = s.view as? DigitWheelView {
            return ChipStyle.trailingInkGap(String(w.displayDigit), font: w.font)
        }
        if let t = s.view as? TextSlotView {
            return ChipStyle.trailingInkGap(t.text, font: t.font)
        }
        return 0
    }

    /// 槽位首字符的墨迹左空档（同上，供无前缀图标时回补左侧）
    private func leadingInkGap(_ s: Slot) -> CGFloat {
        if let w = s.view as? DigitWheelView {
            return ChipStyle.inkBearings(String(w.displayDigit), font: w.font).lsb
        }
        if let t = s.view as? TextSlotView {
            return ChipStyle.inkBearings(t.text, font: t.font).lsb
        }
        return 0
    }

    /// 槽位当前宽度：数字槽直接读 wheel.currentWidth；静态槽使用字符 advance。
    private func slotWidth(_ s: Slot) -> CGFloat {
        (s.view as? DigitWheelView)?.currentWidth ?? s.width
    }

    /// 右对齐排布 slots（与原右对齐 label 一致；总宽超出外部宽度时左溢裁掉）。
    /// 滚动期间每帧调用（槽宽插值），静止时随 layout()/setText 调用。
    ///
    /// 右锚点 = bounds.width − cellTextPadding：原版右对齐 NSTextField 的文本行右缘
    /// 实际在「单元格右缘 − lineFragmentPadding(2.5pt)」处（NSLayoutManager 实测：65pt
    /// 单元格文本行右缘 = 62.5；逐槽锚 65 会整体右偏 2.5pt —— 即「数字偏右」根因）。
    private let cellTextPadding: CGFloat = 2.5
    private func relayoutSlots() {
        // 滑移进行中：按进度插值落位（保留槽=旧x→新x；新建槽=终点−delta；
        // 移出列随组平移）——所有铺布局路径（layout/setText/ticker）统一走这里，
        // 滑移中间态不会被任何一次重排打回终点（闪动根因）
        let p = slideProgress()
        // chip 态垂直居中：字体缩小后行高 < 视图高（intrinsic 恒取基础档），槽位整体
        // 下移半个差值；常规态 lineH == bounds.height，yShift = 0 行为不变
        let yShift = max(0, (bounds.height - lineH) / 2)
        // 左对齐：左缘锚 0（原 drawText 的 pen 位置），正向逐槽排布；
        // 右对齐：右缘锚 bounds−右留白，逆向排布（超宽左溢裁掉）。
        // chip 态右留白抬到 hPadding：视图定宽 65 且 masksToBounds，右缘不留够内边距
        // 的话 chip 背景右侧会被裁掉（左右内缩进不对称），故整组左移让 chip 完整入界
        let rightInset = isChipActive ? max(cellTextPadding, ChipStyle.hPadding) : cellTextPadding
        var x = alignsLeft ? 0 : bounds.width - rightInset
        for s in alignsLeft ? slots : slots.reversed() {
            let w = slotWidth(s)
            var fx: CGFloat
            if alignsLeft {
                fx = x
                x += w
            } else {
                x -= w
                fx = x
            }
            if p < 1 {
                let id = ObjectIdentifier(s.view)
                let startX = slideStarts[id] ?? (fx - slideDelta)
                fx = startX + (fx - startX) * p
            }
            s.view.frame = NSRect(x: fx, y: s.yOff + yShift, width: w, height: s.height)
        }
        if p < 1 {
            for e in slideExits {
                e.view.frame.origin.x = e.startX + slideDelta * p
            }
        }
        // 前缀图标贴最左槽左侧（右/左对齐下 slots.first 均为最左槽；滑移期随插值帧同步平移）
        if prefixIcon != nil, let first = slots.first {
            prefixIconView.frame = NSRect(x: first.view.frame.minX - prefixIconGap - prefixIconSize,
                                          y: yShift + (lineH - prefixIconSize) / 2,
                                          width: prefixIconSize, height: prefixIconSize)
        }
        // 积分 chip 贴内容组边缘（含前缀 icon）：左右内边距走 ChipStyle.hPadding
        // （与子账号 chip 同口径），高度 = 当前行高（chip 态 9pt 行高 ≈12 与子账号
        // chip 同款），随槽位逐帧重算。
        // ⚠️ 贴的是 **墨迹边缘** 不是槽位（advance）边缘：末位字符的 rsb（≈0.7pt，
        // 末位「1」时 1.27pt）若算进内缩进，右视觉内缩进会比左侧图标侧大一圈
        // （图标是按墨迹紧裁位图，空档≈0）——右侧内缩去 rsb 后左右等距。
        if !slots.isEmpty {
            var minX = slots.map { $0.view.frame.minX }.min() ?? 0
            if !prefixIconView.isHidden { minX = min(minX, prefixIconView.frame.minX) }
            let maxX = slots.map { $0.view.frame.maxX }.max() ?? bounds.width
            let trailGap = max(0, (slots.last.map { trailingInkGap($0) } ?? 0) - 0.2)
            // 左侧：图标墨迹填满 frame（紧裁缩放）→ 空档 0；无图标时按首字符 lsb 回补
            let leadGap = prefixIconView.isHidden ? (slots.first.map { leadingInkGap($0) } ?? 0) : 0
            let inkMinX = minX + leadGap
            let inkMaxX = maxX - trailGap
            chipLayer.frame = NSRect(x: inkMinX - ChipStyle.hPadding, y: yShift,
                                     width: (inkMaxX - inkMinX) + ChipStyle.hPadding * 2, height: lineH)
        }
        // TODO(诊断): 槽位坐标 dump（限前 24 次），定位偏右；确认后移除
        Self.posDiagCount += 1
        if Self.posDiagCount <= 24 {
            let parts = slots.map { s in
                String(format: "%.2f@%.2f", slotWidth(s), s.view.frame.origin.x)
            }.joined(separator: " ")
            Logger.log(.layout, "[RollPos] '\(currentText)' boundsW=\(String(format: "%.1f", bounds.width)) pad=\(cellTextPadding) [\(parts)]")
        }
    }
    private static var posDiagCount = 0

    override func layout() {
        super.layout()
        relayoutSlots()
        // TODO(诊断): 上游几何 dump（限前 8 次），定位偏右；确认后移除
        if Self.posDiagCount <= 8, let row1 = superview {
            var chain = "value=\(String(format: "%.1f,%.1f %.1fx%.1f", frame.origin.x, frame.origin.y, frame.width, frame.height))"
            var v: NSView? = row1
            var depth = 0
            while let cur = v, depth < 5 {
                let f = cur.frame
                chain += " L\(depth)[\(String(describing: type(of: cur))) \(String(format: "%.1f,%.1f %.1fx%.1f", f.origin.x, f.origin.y, f.width, f.height))]"
                v = cur.superview
                depth += 1
            }
            // 找同级 row2 里的点阵（content stack 的第二个 arranged view）
            if let content = row1.superview, content.subviews.count > 1,
               let row2 = content.subviews[1] as? NSView {
                for sub in row2.subviews {
                    let f = sub.frame
                    chain += " row2sub[\(String(describing: type(of: sub))) \(String(format: "%.1f,%.1f %.1fx%.1f", f.origin.x, f.origin.y, f.width, f.height))]"
                }
            }
            Logger.log(.layout, "[RollGeo] '\(currentText)' \(chain)")
        }
    }

    // —— 滚动驱动（单视图一个 displayLink，静止即暂停；NSView.displayLink macOS 15+）——

    private var link: CADisplayLink?
    private var lastTS: CFTimeInterval = 0
    /// 因面板不可见而挂起（onTick 里置位；回窗口后续滚）
    private var tickerSuspended = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // 面板重新可见：解冻挂起中的滚动（进度在隐藏期间未被推进）
            if tickerSuspended {
                tickerSuspended = false
                startTicker()
            }
        } else {
            // 离开窗口即拆 displayLink：NSView.displayLink 强持有 target、本视图又
            // 强持有 link，唯一解除点原本在 deinit —— 成环后 deinit 永不执行，滚动
            // 过一次的视图随卡片重建永久滞留（数字 strip 位图每位几十 KB）。
            // tickerSuspended 保住「隐藏期冻结、回窗口续滚」语义：重新入窗经
            // startTicker 重建 link。
            tickerSuspended = true
            link?.invalidate()
            link = nil
        }
    }

    private func startTicker() {
        if link == nil {
            let l = displayLink(target: self, selector: #selector(onTick(_:)))
            // .common：滚动期间面板处于 event tracking（菜单/popover 交互）也不停帧
            l.add(to: .main, forMode: .common)
            link = l
        }
        lastTS = 0
        link?.isPaused = false
    }

    @objc private func onTick(_ l: CADisplayLink) {
        // 面板不可见（popover 关闭等）：冻结进度并挂起 ticker（复刻旧计数动画的
        // 「隐藏期动画挂起」语义），viewDidMoveToWindow 回窗口后续滚。
        guard window != nil else {
            lastTS = 0
            tickerSuspended = true
            l.isPaused = true
            return
        }
        // TODO(性能诊断): 每帧回调耗时/间隔统计（限滚动前 90 帧），定位卡顿来源后移除
        let t0 = CFAbsoluteTimeGetCurrent()
        // ⚠️ 用墙钟（CACurrentMediaTime）计时：实测低刷新率屏上 display link 会在
        // 同一帧内以相同 timestamp 连发多次（dt=0），若用 l.timestamp 累计 elapsed
        // 会把动画拖成几乎不动（卡顿根因）。墙钟对重复回调天然免疫。
        let now = CACurrentMediaTime()
        if lastTS == 0 { lastTS = now }
        let dt = max(0, now - lastTS)
        lastTS = now
        var moving = false
        for s in slots {
            if let w = s.view as? DigitWheelView, w.advance(dt: dt) { moving = true }
        }
        // 结构变化滑移：relayoutSlots 已按进度插值，这里只推进时间轴
        var sliding = false
        if slideDuration > 0 {
            slideElapsed += dt
            if slideElapsed >= slideDuration {
                endSlide()   // 落定（清状态 + 按最终布局重排）
            } else {
                relayoutSlots()
            }
            moving = true
            sliding = true
        }
        if !sliding {
            // 比例数字字体：每帧读取 wheel.currentWidth，右缘固定、左缘自然移动。
            relayoutSlots()
        }
        if !moving {
            l.isPaused = true
            lastTS = 0
            // 落定：最终槽宽 = 各数字真实 advance，固有尺寸收敛
            invalidateIntrinsicContentSize()
        }
        Self.perfFrames += 1
        if Self.perfFrames <= 90 {
            Self.perfCosts.append(CFAbsoluteTimeGetCurrent() - t0)
            if Self.perfFrames == 90 {
                let avg = Self.perfCosts.reduce(0, +) / 90
                let mx = Self.perfCosts.max() ?? 0
                Logger.log(.layout, String(format: "[RollPerf] wheelTick 90帧: 回调avg=%.2fms max=%.2fms", avg * 1000, mx * 1000))
            }
        }
    }
    private static var perfFrames = 0
    private static var perfCosts: [CFTimeInterval] = []
}

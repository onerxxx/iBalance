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
//   - 默认字体（系统 SF）下槽间另施固定负字距 slotTracking（2026-09-13 用户要求
//     字距收一点 → 2026-09-17「减小默认字体下数值滚动的字体间距」再收到 **−0.02em**，
//     唯一旋钮 `sfSlotTrackingEm`；Mono / Sharp Grotesk 不施）：槽宽本身仍 = advance，
//     收紧只发生在排布推进量上，数字轮裁剪窗口与右缘 advance 对齐口径均不受影响；
//   - 数字位槽宽 = **当前显示数字的真实 advance**（非 tabular 统一位宽）：
//     比例数字字体（Inter 默认数字 "1"=5.5 vs "0"=8.58）下静止排版与单 label 完全一致；
//     滚动时槽宽由车轮的连续滚动位置推导（与滚动同参数插值）——右缘固定、
//     左缘随宽度变化平移，非等宽字体滚动自然不抖不跳；等宽/monospacedDigit 字体下
//     各数字 advance 相等，槽宽恒定，行为与 tabular 方案零差异；
//   - 数字轮 cell 字形贴槽左（kern=0 自然定位），右对齐时数值右边缘 =
//     最后一位 advance 边界，整齐。
//   - **槽间间隙是弹性缓冲**（2026-09-16）：滚动中数字轮的**排布推进量**改用
//     `layoutWidth`（= max(理想宽, 墨迹护栏)，理想宽 = 起点→目标 advance 的单调
//     ease-in；护栏 = 可见墨迹右沿 − 槽距/邻槽空档），与 `currentWidth`
//     （防裁剪帧宽）解耦。前缀和逐槽守恒 ⇒ 字符位置只走单调路径，不再因帧宽的
//     逐格冲收而整串往复震动；静止态两者相等 → 排版与被吸收前逐像素一致。
//     容器侧「推进量」与「帧宽」必须分开取：`slotAdvance` / `slotWidth`。
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
// 时间曲线 = **定稿「从快到慢」ease-out cubic**（2026-09-16 开放为设置项，2026-09-17
// 用户「动效的参数固化，移除参数开放」后固定回常量）：
// 位 / 宽度 / 滑移三条量必须共用同一条曲线（不同形会在中段错速，
// 让宽度低于可见宽数字的 advance 造成裁剪）。解析唯一入口 `rollEase(_:)`。
// 中途改目标（新数据打断未完的滚动）时，从所在的连续位置重新规划 tween，天然续接。
// 滚动期间每帧重排 slots（数字右缘固定、左缘随槽宽插值平移——比例数字字体下的
// 自然滚动观感）。槽宽由「过渡中贴住较宽数字」的 C¹ 曲线唯一推导：滚过的数值
// 零裁剪，抵达目标位时恰好收到落定宽——普通滚动与位数变化滑移共用同一调度，
// 均无「滚动到位后回缩」；槽位横向坐标做像素网格对齐，宽度变化不产生亚像素
// 重采样抖动。面板不可见时冻结进度并挂起 ticker，回窗口后续滚。
// 位数变化（如 99.9 → 100.1 跨位数）时结构不匹配 → 整组重建直接落值（单帧，可接受）。

import Cocoa

/// 字形精确 advance 宽度（fileprivate：DigitWheelView / RollingNumberView 共用）
private func textWidth(_ s: String, font: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
}

/// smoothstep：C¹ 连续的 0→1 过渡（两端零斜率），宽度爬坡无速度突跳
private func smoothstep(_ x: Double) -> Double {
    let c = max(0, min(1, x))
    return c * c * (3 - 2 * c)
}

/// 数字滚动的**时间曲线解析唯一入口**。
/// ⚠️ 2026-09-17 用户「动效的参数固化，移除参数开放」：档位**固定为「从快到慢」（ease-out cubic）**——
/// 定稿值 = 固化那一刻配置里的选择（`roll_curve` = easeOut），于是 config 键、设置窗口「动效曲线」
/// 单选、运行镜像 `RollingNumberView.curve` 一并移除（与「主副标题行距系数」同一条固化做法）。
/// 备选口径的算式留在函数里当注释，要换就改 return 那一行。
///
/// ⚠️ 四条量必须共用本函数：`DigitWheelView.advance`（车轮位置）/
/// `delayedWidthPos`（宽度专用位置）/ `updateLayoutWidth`（排布理想宽）/
/// `RollingNumberView.slideProgress`（滑移）——不同形会在中段错速，让宽度低于
/// 可见宽数字的 advance，造成字形右缘被窗口裁掉。
/// 单位换值的槽内滚字 / 横向位移另有自己的 ease-out（另一条动效语言，不随之改）。
private func rollEase(_ x: Double) -> Double {
    let c = max(0, min(1, x))
    return 1 - pow(1 - c, 3)                    // 从快到慢（单减速段）：起手快、收尾长
    // 备用口径（固化前由设置窗口「动效曲线」选）：
    //   c * c * c                                            —— 从慢到快（单加速段）
    //   c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2 —— 慢-快-慢（对称）
}

/// 像素网格对齐（2x 屏 = 0.5pt 步进）：位图槽/图层落在亚像素处会被合成器
/// 重采样 → 字形边缘每帧微移（shimmer）。对齐后字形始终紧实。
private func pixelAligned(_ v: CGFloat, scale: CGFloat) -> CGFloat {
    (v * scale).rounded() / scale
}

private extension Int {
    var mod10: Int {
        let r = self % 10
        return r >= 0 ? r : r + 10
    }
}

// MARK: - 裁剪窗口边缘渐隐（数字轮/滚字槽共用）

/// 边缘渐隐 mask 固定主体：clear→black→black→clear 垂直渐变，挂在 layer.mask 上
/// 只削 alpha，不影响内容颜色（hover 提亮、主题换色、位图定格色均不受影响）。
private func makeEdgeFadeMask() -> CAGradientLayer {
    let l = CAGradientLayer()
    l.colors = [NSColor.clear.cgColor, NSColor.black.cgColor,
                NSColor.black.cgColor, NSColor.clear.cgColor]
    l.startPoint = CGPoint(x: 0.5, y: 0)
    l.endPoint = CGPoint(x: 0.5, y: 1)
    return l
}

/// 按窗口高度刷新渐隐带（NumberFlow 同款）：带高 = 字号 × 0.125em/缘（其默认
/// mask-height 0.25em 总量的一半），0.5pt 栅格取整。落定字形墨迹距窗口缘 ≥0.15em
/// （基线/大写字高留白，含逗号/百分号等最低低位），恒在带外；只有滚动中经过
/// 窗口缘的字形被柔化。高度未定或带高过半（极端小窗）不挂 mask，行为同旧硬裁剪。
private func attachEdgeFadeMask(_ mask: CAGradientLayer, to view: NSView, font: NSFont) {
    guard let layer = view.layer, layer.bounds.height > 0 else { return }
    let h = layer.bounds.height
    let fade = max(1, (font.pointSize * 0.25).rounded() / 2)
    guard fade * 2 < h else {
        if layer.mask === mask { layer.mask = nil }
        return
    }
    mask.frame = layer.bounds
    mask.locations = [0, fade / h, 1 - fade / h, 1].map { NSNumber(value: $0) }
    if layer.mask !== mask { layer.mask = mask }
}

// MARK: - DigitWheelView（单个数字位的车轮）

/// 数字轮：0-9 十个数字垂直排列，首尾各补一格（顶部 9 / 底部 0）支持跨 0 环绕的
/// 最短路径滚动；视图裁剪出单格高度窗口，滚动 = 平移 strip。
final class DigitWheelView: NSView {

    /// 主字体（与数值整体字体一致；变化时重算度量并重渲染 strip）。
    /// 初值走 `PanelFont.system`（= 原系统等宽数字口径）：实际字体恒由
    /// `RollingNumberView.refreshFont()` 经注入的 fontProvider 覆写，这里只作占位
    var font: NSFont = PanelFont.system(size: 13, weight: .semibold, monoDigits: true) {
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

    /// 单格行高（滚动步长 = 一格）：ascender - descender + leading。
    /// **存储属性**（2026-09-14 由计算属性改）：读 `font` 要走 `swift_beginAccess`
    /// 独占检查（它带 didSet），而本值是 draw / layout / applyStripOrigin 里每帧多次读取的
    /// 热点——当日一次偶发 EXC_BAD_ACCESS（SIGSEGV，故障地址是无效指针）正落在该读取路径上
    /// （`swift_beginAccess` ← `cellH.getter`）。改存储后只在字体变化时算一次，
    /// 顺带去掉高频路径上的独占检查开销。同步点：`rebuildMetrics()`（唯一写口）
    private var cellH: CGFloat = 0

    /// 基线居中补偿：cell 高 = ceil(自然行高)，ceil 补白（0~1pt，随字体变：SF 13pt
    /// ≈0.35 / SG ≈0.5）——基线探针（NSTextField）在盒内垂直居中、补白均分到上下，
    /// 数字轮却按 cell 顶绘制，两者基线差 = 补白的一半且换字体时跳变（用户实测
    /// 「换字体后积分被推高」）。绘制统一加 pad，让数字基线与居中口径逐字体一致。
    /// 与 cellH 同因改存储，随字体在 `rebuildMetrics()` 里同步
    private var baselinePad: CGFloat = 0

    /// 落定数字（滚动期间恒定取目标值）：外部按字符求墨迹空档用，
    /// 恒定值保证 chip 右缘在滚动全程不抖（落定即精确值）
    var displayDigit: Int { ((Int(round(targetPos)) % 10) + 10) % 10 }

    /// 当前槽宽：由连续滚动位置唯一推导（widthForPosition，C¹ 平滑——平台段与
    /// smoothstep 爬坡段零斜率衔接，无速度突跳）；等宽字体下各数字 advance 相等，
    /// 自然恒定宽度。
    ///
    /// ⚠️ 这是**防裁剪帧宽**：滚动中贴住窗口内可见的较宽数字，保证滚出/滚入的字形
    /// 不被裁。它只决定 wheel 自己的 frame 宽（绘制/裁剪口径），**不决定排布推进量**
    /// —— 后者见 `layoutWidth`。
    private(set) var currentWidth: CGFloat = 0

    // MARK: 排布宽与帧宽解耦（「拿槽间间隙当缓冲」—— 消除滚动时相邻字符的位置震动）
    //
    // 问题：`currentWidth` 是**防裁剪帧宽**——收窄过渡要撑住离场的宽字形，直到行程
    // 72% 才开始收。这份宽度过去**同时**充当排布推进量：每跨一格就冲一次、收一次，
    // 后面所有字符被推出去又拽回来，方向反复 = 滚动时的「位置震动」。SG 比例数字
    // 单槽 advance 最大差 5.71pt @23.4pt，观感明显。
    //
    // 解法：排布推进量改用 `layoutWidth`，与帧宽彻底解耦：
    //
    //   layoutWidth = max(理想宽, 墨迹护栏)
    //     理想宽   = 起点数字 advance → 目标数字 advance，沿 ease-in
    //                （与车轮同一条时间曲线）**单调**推进 —— 单调是关键，杜绝
    //                「先撑住再猛收」的往复；
    //     墨迹护栏 = 窗口内可见两格的**墨迹右沿**（只算与核心可见带相交的格）
    //                −（槽间字距 + 邻槽最小左侧空档）—— 给「滚入的宽数字别碰上
    //                右邻」兜底。像素级离线实测：单靠理想宽在 1→5 这类场合差 2.1pt。
    //
    // 端点精确性：护栏项恒 ≤ 该位自然 advance（墨迹右沿 ≤ advance，且扣掉了字距与
    // 邻槽空档），故整数位置处 max() 恒取理想宽 = advance —— 静止排版与不用本机制时
    // 逐像素一致（离线实测 t=0/1 误差 0.000000pt）。
    //
    // 帧宽仍取 `currentWidth`（保住「滚出/滚入的字形不被裁」这条既有口径）；
    // `currentWidth − layoutWidth` 那份多出来的宽度**全落在相邻两槽之间的空隙里**
    // （帧右缘探进空隙，字形绘制基准仍在帧左缘 = 布局位置不动）—— 这正是「字符间距
    // 充当缓冲、优先挤压间距」的落点：帧多占的只是空隙里的空白，位置纹丝不动。
    //
    // 离线实测（Sharp Grotesk Book20 @23.4pt，逐格 7 帧 @60fps）：
    //   现行：多格滚动每段 1~3 次方向反转，最大单步位移 4.9pt（0→5 的 167→117→154 鞭打）
    //   本条：方向反转 0 次，最大单步位移 0.08pt

    /// 排布推进宽（容器算下一槽位置用：`step = layoutWidth + slotTracking`）
    private(set) var layoutWidth: CGFloat = 0
    /// 本段理想宽端点：起点取**当前已渲染的排布宽**（滚动被打断时承接，横向无跳）
    private var layoutStart: CGFloat = 0
    private var layoutEnd: CGFloat = 0
    /// 排布宽需扣除的固定量 = 槽间字距 + 邻槽最小左侧空档（容器注入，见 `slotAllowance`）
    var slotAllowance: CGFloat = 0

    /// 每帧推进排布宽（`advance` 里、`currentWidth` 之后调用；无 tween 即落定值）
    private func updateLayoutWidth() {
        guard tweenDuration > 0 else {
            layoutWidth = layoutEnd
            return
        }
        let t = min(1, tweenElapsed / tweenDuration)
        let ideal = layoutStart + (layoutEnd - layoutStart) * CGFloat(rollEase(t))
        // 护栏由 pos 实时给出（pos 连续 ⇒ 护栏连续）；max 整体单调，仅交叉处有速度折点
        layoutWidth = max(ideal, visibleInkGuard())
    }

    /// 墨迹护栏：窗口内可见两格的墨迹右沿（仅计入与核心可见带相交的格）− `slotAllowance`。
    /// 「核心可见带」= 窗口上下各扣掉边缘渐隐带（`attachEdgeFadeMask` 同口径）——
    /// 落在渐隐带里的字形已被柔化，不必再为它让出间隙。
    private func visibleInkGuard() -> CGFloat {
        var ownInk: CGFloat = 0
        let frac = pos - floor(pos)
        // 可见两格：离场（cell 顶在窗口顶上方 frac 格）、入场（下方 1−frac 格）
        for (d, cellTop) in [(Int(floor(pos)).mod10, -CGFloat(frac) * cellH),
                             (Int(ceil(pos)).mod10, (1 - CGFloat(frac)) * cellH)] {
            let lo = max(digitInkTops[d] + cellTop, inkFade)
            let hi = min(digitInkBottoms[d] + cellTop, cellH - inkFade)
            if hi > lo { ownInk = max(ownInk, digitInkRights[d]) }
        }
        return ownInk - slotAllowance
    }

    /// 数字 d 的墨迹右沿（自槽左缘 = advance − rsb）；随字体在 `rebuildMetrics` 重算
    private var digitInkRights: [CGFloat] = []
    /// 数字 d 墨迹的上下沿（cell 坐标，自 cell 顶向下）——护栏判断字形是否还在可见带内
    private var digitInkTops: [CGFloat] = []
    private var digitInkBottoms: [CGFloat] = []
    /// 边缘渐隐带高（`attachEdgeFadeMask` 同口径；随字体在 `rebuildMetrics` 重算）
    private var inkFade: CGFloat = 0

    /// 每个数字自己的真实 advance。不要用统一 tabular width 做外部排版，
    /// tabularWidth 只负责给内部排版提供足够的绘制宽度。
    private var digitWidths: [CGFloat] = []
    private var tabWidth: CGFloat = 0
    /// 比例数字判定（SG 档：各数字 advance 不等）。advance 每帧读（advance/widthForPosition
    /// 热点），随字体在 rebuildMetrics 落存储，热路径不走属性重算
    private var widthDelayActive = false

    /// 数字带图层：12 格（含顶部 9/底部 0 环绕缓冲）一次性预渲染成位图，
    /// 滚动每帧只改图层 origin.y —— 主线程零绘制，合成器以屏幕刷新率平移。
    /// 这是流畅度的根本保障（此前逐帧 draw 是掉帧根因；计数频率反而是次要的）。
    private let stripLayer = CALayer()
    private var stripCGImage: CGImage?
    /// 窗口上下边缘渐隐（主体/刷新见 makeEdgeFadeMask / attachEdgeFadeMask）
    private let edgeFadeMask = makeEdgeFadeMask()

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
        // 字体派生量先落存储（cellH / baselinePad 的唯一写口，见其声明处）
        let natural = font.ascender - font.descender + font.leading
        cellH = ceil(natural)
        baselinePad = (cellH - natural) / 2
        digitWidths = (0...9).map { textWidth(String($0), font: font) }
        tabWidth = digitWidths.max() ?? textWidth("0", font: font)
        widthDelayActive = digitWidths.contains { $0 != digitWidths[0] }
        // 墨迹表（自槽左缘 / 自 cell 顶，flipped）：护栏「字形是否还在可见带内」的判据。
    // 用 CTLine 墨迹盒（与绘制同一渲染栈，逐字体精确）；advance − rsb 即墨迹右沿
    let lineBoxes = (0...9).map { d -> CGRect in
        CTLineGetBoundsWithOptions(
            CTLineCreateWithAttributedString(
                NSAttributedString(string: String(d), attributes: [.font: font])),
            .useGlyphPathBounds)
    }
    digitInkRights = (0...9).map { d in lineBoxes[d].maxX }   // 笔尖在槽左缘，故 = maxX
    digitInkTops = (0...9).map { d in baselinePad + font.ascender - lineBoxes[d].maxY }
    digitInkBottoms = (0...9).map { d in baselinePad + font.ascender - lineBoxes[d].minY }
    // 边缘渐隐带高（`attachEdgeFadeMask` 同口径）：带内的字形已被柔化，护栏不必为它让位
    inkFade = max(1, (font.pointSize * 0.25).rounded() / 2)
    rebuildStrip()
    currentWidth = widthForPosition(pos)
    // 字体变了 → 排布宽按新度量重置（落定口径，无动画）
    syncLayoutWidthToCurrentDigit()
}

    /// 把排布宽同步到「当前显示数字」的落定值（换字体 / 非动画落值 / 初始化用）
    private func syncLayoutWidthToCurrentDigit() {
        layoutEnd = digitWidths[displayDigit]
        layoutStart = layoutEnd
        layoutWidth = layoutEnd
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

    /// 主前景色镜像变化后的**强制重渲**（2026-09-17 随参数开放新增）：
    /// 数字带是烘色位图，颜色在渲染时定格；而颜色源 `Palette.cardForeground` 是同一个
    /// 动态色实例 —— `textColor` 的 didSet 相等守卫拦得住它，切主前景色时**不会自己重渲**，
    /// 必须由 `Panel.refreshCardForeground()` 的整树遍历显式调到这里
    func refreshForegroundColor() {
        rebuildStrip()
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
            s.draw(at: NSPoint(x: 0, y: CGFloat(11 - i) * cellH - baselinePad))
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
        attachEdgeFadeMask(edgeFadeMask, to: self, font: font)
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
            syncLayoutWidthToCurrentDigit()
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
        // 宽度时间轴起点先取（在重置 tweenElapsed 之前）：滚动中重规划时承接
        // 当前延迟宽度对应的位置，槽宽连续无跳变；无在途 tween 时 = pos
        widthStartPos = delayedWidthPos
        tweenStart = pos
        tweenElapsed = 0
        let cells = abs(dest - pos)
        let phase = 0.94 + 0.12 * tweenPhase   // 0.94…1.06，实例级恒定
        tweenDuration = rollDuration * cells / 10 * phase
        // 布局宽本段端点：起点承接**当前已渲染值**（滚动被打断时横向不跳），
        // 终点 = 目标数字的 advance（护栏每帧由 pos 实时给出，无需端点）
        layoutStart = layoutWidth
        let td = ((Int(round(dest)) % 10) + 10) % 10
        layoutEnd = digitWidths[td]
    }

    /// 实例固定相位 0..<1（确定性伪随机：同距离车轮因各自的相位而错峰落定；
    /// 对单个轮子在其生命周期内恒定，重启 App 变化与否无感知影响）
    private lazy var tweenPhase: Double = {
        let m = ObjectIdentifier(self).hashValue.magnitude
        return Double(m % 997) / 997.0
    }()

    /// 帧推进：沿本段 tween 时间轴积分（曲线 = `rollEase(_:)` 按设置档位实时解析），
/// 到点后精确落在目标位置 —— 时间轴模型没有指数尾巴，天然不存在
/// 亚像素爬行的逐帧微抖。
    /// 槽宽永远由连续位置推导（单一状态源，过渡全程贴住较宽数字防裁剪），每帧
    /// 只改 strip 图层位置，无任何主线程重绘。返回是否仍在滚动。
    func advance(dt: CFTimeInterval) -> Bool {
        guard tweenDuration > 0 else { return false }   // 无进行中的 tween：已落定
        tweenElapsed += dt
        let p = min(1, tweenElapsed / tweenDuration)
        let eased = rollEase(p)
        pos = tweenStart + (targetPos - tweenStart) * eased
        currentWidth = widthForPosition(delayedWidthPos)
        updateLayoutWidth()
        applyStripOrigin()
        if p >= 1 {
            pos = targetPos            // 精确落点
            normalize()
            tweenDuration = 0
            currentWidth = widthForPosition(pos)   // 落定宽即目标宽（曲线整数精确），无回缩
            syncLayoutWidthToCurrentDigit()        // 布局宽也精确落定（偏差归零）
            applyStripOrigin()
            return false
        }
        return true
    }


    // —— 独立 tween 状态（每位车轮自己的时间轴；不共享任何全局缓动参数）——
    private var tweenStart: Double = 0          // 本段动画起点（连续位置）
    private var tweenElapsed: CFTimeInterval = 0
    private var tweenDuration: CFTimeInterval = 0   // 0 = 无动画（已落定）
    /// 本段 tween 的总时长只读出口（0 = 已落定）。宿主 `RollingNumberView` 汇总
    /// 「本轮最长轮的落定时刻」来定滑移时长（见 `slideTime(rollDuration:)`），
    /// 故不做 private —— 读的就是规划时已经算好、含实例相位抖动的那个真值
    var activeTweenDuration: CFTimeInterval { tweenDuration }
    /// 宽度时间轴起点（连续位置）：beginTween 时承接在途延迟宽度，见 beginTween
    private var widthStartPos: Double = 0

    /// 宽度专用连续位置：SG 比例数字下滞后 Motion.rollWidthDelay 启动、压缩进
    /// tween 剩余时长（与 pos 同一条曲线 `rollEase`——必须同形，否则中段
    /// 错速会让宽度低于可见宽数字的 advance 造成裁剪），tween 结束点恰达
    /// targetPos —— 落定宽度精确等于目标 advance，到位后不再有任何宽度调整。
    /// 等宽字体（宽度恒定）与短于延迟的微滚直接跟 pos。
    private var delayedWidthPos: Double {
        let delay = Motion.rollWidthDelay
        guard widthDelayActive, tweenDuration > delay else { return pos }
        let wp = min(1, max(0, (tweenElapsed - delay) / (tweenDuration - delay)))
        let eased = rollEase(wp)
        return widthStartPos + (targetPos - widthStartPos) * eased
    }

    /// 根据连续位置计算当前槽宽。
    /// 例如 1→8 的中间态，宽度在 advance(1) 与 advance(8) 之间连续插值——
    /// 既保留垂直滚动，又保持比例数字字体的横向排版正确。
    /// 过渡中窗口里同时有「上侧滚出的旧数字」与「下侧滚入的新数字」，两者共用
    /// 同一条静态 strip 位图（同一 x 基准），槽宽一旦低于较宽一方的 advance，
    /// 其字形右缘立即被窗口裁掉——因此插值以「贴住宽者」为第一优先：
    /// - 收窄（下一格更窄）：前 72% 过渡槽宽恒贴旧数字（滚过的数值零裁剪），
    ///   72%→97% smoothstep 收完——窗口由 0.8→0.95 拉长（2026-09-16 用户
    ///   「宽度变化太急促」：同一条 C¹ S 曲线跑更长区间，峰值速度约减半，
    ///   且早段亏宽反而更小，旧数字墨迹仍落在渐隐带内不可见）；收窄完成点
    ///   97% 仍早于车轮视觉停止（无到位后回缩）；
    /// - 变宽（下一格更宽）：前 22% smoothstep 撑开到新数字宽（原 0.15 同日
    ///   拉长缓动），让进入的宽数字尽早免裁（残差仅起始的细条，同在渐隐带内）。
    /// 落定态 pos 为整数（t=0）恒精确等于当前数字 advance，静止排版不受影响。
    private func widthForPosition(_ p: Double) -> CGFloat {
        guard digitWidths.count == 10 else { return 0 }
        let base = floor(p)
        let t = p - base
        let a = Int(base).mod10
        let b = (a + 1).mod10
        let wa = digitWidths[a]
        let wb = digitWidths[b]
        if wb > wa {
            return wa + (wb - wa) * CGFloat(smoothstep(t / 0.22))
        }
        if wb < wa {
            return wa + (wb - wa) * CGFloat(smoothstep((t - 0.72) / 0.25))
        }
        return wa
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
        // 落定态（无 tween）pos 必为整数——非动画 setDigit / 落点精确停 / normalize
        // 三处共同保证。分数残留会把整条数字带推出窗口：等宽数字字体下横位不变，
        // 视觉即「数值顶部平齐截断、底缘完好」（2026-09-13 用户偶发上报）。就地取整
        // 恢复不变量（可见数字 = round(pos)，不变）并打点取证，[RollDbg] 定位后移除
        if tweenDuration == 0 {
            let frac = pos - pos.rounded()
            if abs(frac) > 0.01 {
                Logger.log(.layout, "[RollDbg] FRACTIONAL-POS pos=\(String(format: "%.3f", pos)) frac=\(String(format: "%.3f", frac)) cellH=\(String(format: "%.1f", cellH))")
                pos = pos.rounded()
            }
        }
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

    /// 当前落定字符（滚字过渡期间 = 目标字符；正在滚出的旧字符走 `outgoing`）。
    /// 外部读它求墨迹空档（`trailingInkGap` / `leadingInkGap`）与结构配对判据。
    private(set) var text: String = ""
    // 初值走 PanelFont.system（原 systemFont 口径）：实际字体恒由 RollingNumberView
    // 排布时覆写，这里只作占位，统一到 PanelFont 便于「禁散写」grep 审计
    var font: NSFont = PanelFont.system(size: 13) {
        didSet {
            guard font != oldValue else { return }
            updateBaselinePad()
            needsDisplay = true
            attachEdgeFadeMask(edgeFadeMask, to: self, font: font)
        }
    }
    var textColor: NSColor = .labelColor {
        didSet { guard textColor != oldValue else { return }; needsDisplay = true }
    }
    /// 窗口上下边缘渐隐（与数字轮同款，见 makeEdgeFadeMask / attachEdgeFadeMask）
    private let edgeFadeMask = makeEdgeFadeMask()

    /// 基线居中补偿（与 DigitWheelView.baselinePad 同口径，见彼处注释）：
    /// ceil 补白的一半，换字体时随字体变化，保证静态槽与数字轮/探针基线一致。
    /// 存储属性（同 DigitWheelView 的理由：读 `font` 要过 `swift_beginAccess`），
    /// 写口唯一 —— `updateBaselinePad()`，由 init 与 font.didSet 调用
    private var baselinePad: CGFloat = 0

    /// 基线补偿的唯一写口（init 中直接赋值不触发 didSet，必须显式调一次）
    private func updateBaselinePad() {
        let natural = font.ascender - font.descender + font.leading
        baselinePad = (ceil(natural) - natural) / 2
    }
    /// % 单独基线光学补偿（2026-09-13 用户定稿只对 % 处理）：静态槽（未翻转视图
    /// draw）与数字轮位图两条管线的落墨位置有逐字体偏差，% 最明显偏上；按 em 比例
    /// 下移。0.06 ≈ 离屏实测的槽/轮墨迹差量级，微调改这一个系数即可
    private static let percentBaselineAdjust: CGFloat = 0.06

    // —— 槽内滚字（单位制换值：同一槽位换字符，如 "," 滚成 "."）——
    // 与数字轮同向：旧字向上滚出、新字自下方滚入。两段错峰（旧字先清场）是为了让
    // 调用方能在「槽内为空」的那一刻把槽位横向挪到新位置——跳位不可见（见
    // RollingNumberView.relayoutSlots 的静态槽分支）。
    private var outgoing: String?
    private var rollElapsed: CFTimeInterval = 0
    private var rollOut: CFTimeInterval = 0        // 旧字滚出时长
    private var rollInDelay: CFTimeInterval = 0    // 新字起滚时刻
    private var rollIn: CFTimeInterval = 0         // 新字滚入时长

    init(text: String, font: NSFont, color: NSColor) {
        self.text = text
        self.font = font
        self.textColor = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true   // 滚字时只露单格窗口（与数字轮同口径）
        // init 里直赋 font 不触发 didSet → 基线补偿显式补一次
        updateBaselinePad()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 直接落字（无动画）：结构未变时的即时替换（¥ ↔ $ 等）与复用槽的字体同步
    func setTextImmediately(_ s: String, font f: NSFont) {
        self.font = f
        guard s != text else { return }
        outgoing = nil
        rollOut = 0
        rollIn = 0
        rollInDelay = 0
        text = s
        needsDisplay = true
    }

    /// 槽内滚字：旧字向上滚出 → 新字自下方滚入。字符相同则只同步字体、原地不动。
    func rollTo(_ s: String, font f: NSFont,
                out: CFTimeInterval, inDelay: CFTimeInterval, inDuration: CFTimeInterval) {
        self.font = f
        guard s != text else { return }
        guard !text.isEmpty else {   // 空槽（首次落字）没有可滚出的旧字
            text = s
            needsDisplay = true
            return
        }
        outgoing = text
        text = s
        rollElapsed = 0
        rollOut = out
        rollInDelay = inDelay
        rollIn = inDuration
        needsDisplay = true
    }

    /// 立即结束滚字并落定新字（换值被打断 / 清理口径；不落定会把槽留在半滚态）
    func finishRoll() {
        guard rollOut > 0 || rollIn > 0 else { return }
        rollOut = 0
        rollIn = 0
        rollInDelay = 0
        outgoing = nil
        needsDisplay = true
    }

    /// 帧推进（与数字轮共用 ticker）。返回是否仍在滚。
    func advance(dt: CFTimeInterval) -> Bool {
        guard rollOut > 0 || rollIn > 0 else { return false }
        rollElapsed += dt
        if rollElapsed >= rollInDelay + rollIn {
            finishRoll()
            return false
        }
        needsDisplay = true
        return true
    }

    override func layout() {
        super.layout()
        attachEdgeFadeMask(edgeFadeMask, to: self, font: font)
    }

    override func draw(_ dirtyRect: NSRect) {
        let cellH = ceil(font.ascender - font.descender + font.leading)
        let outP = rollOut > 0 ? min(1, rollElapsed / rollOut) : 1
        let inP = rollIn > 0 ? min(1, max(0, rollElapsed - rollInDelay) / rollIn) : 1
        // ease-out cubic：与全 App 动效语言一致
        let eOut = CGFloat(1 - pow(1 - outP, 3))
        let eIn = CGFloat(1 - pow(1 - inP, 3))
        if let old = outgoing, eOut < 1 {
            drawGlyph(old, atY: -cellH * eOut + baselinePad)          // 向上滚出
        }
        if !text.isEmpty {
            drawGlyph(text, atY: cellH * (1 - eIn) + baselinePad)     // 自下方滚入
        }
    }

    private func drawGlyph(_ s: String, atY y: CGFloat) {
        guard !s.isEmpty else { return }
        // % 单独基线补偿：未翻转 y-up 坐标，减 = 视觉下移
        let adj = (s == "%") ? -font.pointSize * Self.percentBaselineAdjust : 0
        NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ]).draw(at: NSPoint(x: 0, y: y + adj))
    }
}

// MARK: - RollingNumberView（数值容器）

/// 余额数值逐位滚动视图：文本拆成逐字符槽位，数字位是车轮、其余是静态 label。
/// 对外行为对齐原右对齐 NSTextField：固定外部宽度内右对齐排布（超宽左溢裁掉）、
/// 暴露 baselineAnchor（内部隐藏同字体探针 label）供标题基线对齐。
final class RollingNumberView: NSView {

    typealias FontProvider = (CGFloat, NSFont.Weight, Bool) -> NSFont

    // 自旋时长口径 / 时间曲线档位两处运行镜像（`slideTiming` / `curve`）2026-09-17 已随
    // 「动效的参数固化」整体移除：真值改由本文件的 `slideTime()` 与 `rollEase(_:)` 两个常量口径
    // 唯一提供，不再有全局可写状态（与「主副标题行距系数」固化成 `BalancePanelView` 常量同一条做法）

    // —— 字体策略（由面板注入；configure 时恒被宿主覆盖，默认档只作未 configure 的占位）——
    private var specSize: CGFloat = 13
    private var specWeight: NSFont.Weight = .semibold
    private var fontProvider: FontProvider = { size, weight, mono in
        PanelFont.system(size: size, weight: weight, monoDigits: mono)
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
    /// 前缀图标的**烘焙**边长（面板按此尺寸烘 2× 图像，绘制时按需缩放）：与绘制尺寸解耦 ——
    /// 绘制边长 = 当前字号的一半（常规态，见 `updatePrefixIconSize`），最大字号 18pt → 9pt，
    /// 故烘焙取 10 留余量（缩小绘制清晰、放大发糊，所以烘焙必须 ≥ 绘制）
    static let baseIconSize: CGFloat = 10   // 2026-09-14 由「常规态边长 8.5」改为纯烘焙基准
    /// 前缀图标当前绘制边长：常规态 = **当前字号的一半**（2026-09-14 用户指定），
    /// chip 态 = `ChipStyle.iconSize`（与子账号按钮同款）；frame 由 relayoutSlots 逐帧给出，
    /// 固有宽也按它计入
    private var prefixIconSize: CGFloat = RollingNumberView.baseIconSize
    private let prefixIconGap: CGFloat = ChipStyle.iconTextGap
    private let prefixIconView = NSImageView()

    // 初值走 PanelFont.system（= 原系统等宽数字口径），refreshFont() 恒会覆写
    private var mainFont: NSFont = PanelFont.system(size: 13, weight: .semibold, monoDigits: true)
    private var prefixFont: NSFont = PanelFont.system(size: 7.8, weight: .semibold, monoDigits: true)
    private var lineH: CGFloat = 16
    private var prefixLineH: CGFloat = 10
    private var digitWidth: CGFloat = 8   // 仅诊断日志用（字体等宽性验证）
    /// 默认字体（系统 SF）下的槽间负字距（pt，负 = 收紧）：逐槽排布的间距 = 各字符
    /// advance 连续相接，等宽数字档字形侧边距偏宽，用户要求默认字体下字距收一点
    /// （2026-09-13）。随 refreshFont 按主字体重算；Mono / Sharp Grotesk 恒 0 保持
    /// 字体自带度量（fontName 带 "." 前缀 = 系统私有 SF 家族）
    private var slotTracking: CGFloat = 0
    /// 系统 SF 档的槽间紧缩量（em，负 = 收紧）—— **收字距的唯一旋钮**。
    /// 2026-09-13 首定 −0.01（用户「字距收一点」）；2026-09-17 用户「减小默认字体下
    /// 数值滚动的字体间距」→ **−0.02**（13pt 下每槽多收 0.13pt，7 位数字串合计再紧 ~0.8pt）。
    /// 与实例级 `trackingEm`（Token 总计大数字用来**加宽**）相加后乘字号，见 `refreshFont()`。
    private static let sfSlotTrackingEm: CGFloat = -0.02
    /// 全数字最小左空档（lsb，随 refreshFont 重算）：数字轮护栏的固定扣除量之一
    private var minNeighborInkCache: CGFloat = 0

    /// 实例级字距增量（em，正 = 加宽，2026-09-16）：叠加在字体默认口径之上（系统 SF
    /// 的 −0.01em 紧缩仍保留）。Token 总计大数字用它加宽字距；默认 0 = 其余实例不变
    var trackingEm: CGFloat = 0
    private var textColor: NSColor = Palette.cardForeground

    // —— 基础字体档（configure 注入）：chip 态切走、退出态复原的复原锚点 ——
    private var baseSize: CGFloat = 13
    private var baseWeight: NSFont.Weight = .semibold
    private var baseLineH: CGFloat = 16
    /// 数字墨迹基线在单元格内的 y 偏移（flipped：自 cell 顶算；随字体在
    /// `updateBaselineAlignShift` 里刷新）——前缀图标按「底边落基线」定位靠它
    private var wheelBaselineInCell: CGFloat = 0

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
        // 图标同步切 chip 档（与子账号按钮同尺寸），退出复原「字号一半」的常规档
        updatePrefixIconSize()
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

    /// chip hover 让位/复原：dim 副前景灰；复原按激活态回 chip 前景或常规前景
    func setDimmed(_ dim: Bool) {
        setTextColor(dim ? Palette.secondaryForeground
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

    // MARK: 探针基线实测对齐（2026-09-13 统一解法）

    /// 槽位整体基线对齐偏移（flipped，正=下移）：探针 cell 的**真实绘制基线**与
    /// 「ceil 补白/2 + ascender」轮绘制模型的差。NSTextFieldCell 盒内垂直定位并非
    /// 补白均分——离屏实测（高=cellH 盒内渲染 "0"）：SG 18pt 比模型低 ~2.4pt、
    /// SF 18pt 高 ~1.2pt，逐字体大小方向都不同（「换字体数值偏上/偏下」根因）。
    /// 槽位统一加此偏移，数字墨迹精确落在探针基线上；任何字体×字号自动成立
    ///（实测校准，勿改回纯模型推导）。随 refreshFont 按当前字体对（主/探针）重算。
    private var baselineAlignShift: CGFloat = 0
    /// NEG-SHIFT 哨兵去重（进入坏态打一次点，复健后复位）
    private var loggedNegShiftState = false
    /// 实测基线缓存（key = 字体名|字号|盒高）：测量要离屏渲染一次小位图，逐参数只做一次
    private static var probeBaselineCache: [String: CGFloat] = [:]

    /// 实测 label「0」在 boxH 盒内的绘制基线（距盒顶）。
    /// 基线 = (墨迹顶 + 墨迹底 + capHeight) / 2："0" 上下过冲对称，中点法消过冲，
    /// 与轮位图同一字形同一渲染栈，偏差 ≤0.3pt。测不到墨迹时退回「盒底 − descender」。
    private static func measuredProbeBaseline(font: NSFont, boxH: CGFloat) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(Int(boxH))"
        if let cached = probeBaselineCache[key] { return cached }
        let label = NSTextField(labelWithString: "0")
        label.font = font
        label.frame = NSRect(x: 0, y: 0, width: 60, height: boxH)
        var result = boxH - font.descender
        if let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) {
            label.cacheDisplay(in: label.bounds, to: rep)
            var top = Int.max, bottom = -1
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.05 {
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            if top <= bottom {
                let scale = Double(rep.pixelsHigh) / Double(boxH)
                let inkTop = Double(top) / scale, inkBottom = Double(bottom) / scale
                result = CGFloat((inkTop + inkBottom + Double(font.capHeight)) / 2)
            }
        }
        probeBaselineCache[key] = result
        return result
    }

    /// 按当前字体对（主数字/探针）重算对齐偏移：轮墨迹基线（模型）→ 探针实测基线
    private func updateBaselineAlignShift() {
        let natural = mainFont.ascender - mainFont.descender + mainFont.leading
        let wheelBaseline = (lineH - natural) / 2 + mainFont.ascender
        // 轮墨迹基线在 cell 内的 y：前缀图标「底边贴基线」按它落位（见 relayoutSlots）
        wheelBaselineInCell = wheelBaseline
        baselineAlignShift = Self.measuredProbeBaseline(font: baselineProbe.font ?? mainFont,
                                                        boxH: baseLineH) - wheelBaseline
    }

    /// 前缀图标绘制边长：常规态 = **当前字号的一半**（2026-09-14 用户指定），
    /// chip 态 = 子账号按钮同款 `ChipStyle.iconSize`。宽也参与固有宽 ⇒ 调用方需自行标脏
    private func updatePrefixIconSize() {
        prefixIconSize = isChipActive ? ChipStyle.iconSize : specSize / 2
    }

    override var isFlipped: Bool { true }

    /// 数字内容前缘 guide：relayoutSlots 落位后把内容组（槽位 + 前缀 icon）最左缘
    /// 同步进 leading 约束 constant——标题行让位约束钉它而非数值**列**前缘（列宽为
    /// 最宽数字组合预留，短数值右锚后列内留白很大），标题可借用留白尽量完整显示。
    /// 槽位是 frame 布局，guide 只能用约束表达：leading = leadingAnchor + 内容 minX
    ///（constant 逐帧更新），宽 = 视图宽 − minX 由尾/顶/底固定约束给出；
    /// 未布局/无槽位时回退全宽 = 保守挡在列前缘（旧行为）
    let contentLeadingGuide = NSLayoutGuide()
    private var contentLeadingConstraint: NSLayoutConstraint!

    override var intrinsicContentSize: NSSize {
        var w = slotsTotalWidth(slots)
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
        addLayoutGuide(contentLeadingGuide)
        NSLayoutConstraint.activate([
            contentLeadingGuide.topAnchor.constraint(equalTo: topAnchor),
            contentLeadingGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentLeadingGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        contentLeadingConstraint = contentLeadingGuide.leadingAnchor.constraint(equalTo: leadingAnchor)
        contentLeadingConstraint.isActive = true
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

    /// 字号档变化（设置窗口「主标题字号」联动，2026-09-13）：基础档与规格档同步到新
    /// 字号——基线探针/行高/槽位/¥$ 前缀全部按新字号重算（滚动状态保留；chip 态仅
    /// 临时改绘不落 spec 的口径不变）
    func setSize(_ size: CGFloat) {
        guard size != specSize || size != baseSize else { return }
        baseSize = size
        specSize = size
        refreshFont()
    }

    /// Mono/Inter 开关切换后就地刷新字体（不重建槽位，滚动状态保留）。
    /// 数字槽宽由 wheel 按新字体重算（rebuildCells 内落位）。
    func refreshFont() {        // chip 态用子账号 chip 同款字体（9pt semibold、非 mono）；常规态走基础档（mono 等宽数字）
        mainFont = fontProvider(specSize, specWeight, !isChipActive)
        // ¥/$ 前缀：60% 字号 semibold（对齐原 applyValueText 富文本策略，不用等宽数字）
        prefixFont = fontProvider(specSize * 0.6, .semibold, false)
        lineH = ceil(mainFont.ascender - mainFont.descender + mainFont.leading)
        prefixLineH = ceil(prefixFont.ascender - prefixFont.descender + prefixFont.leading)
        digitWidth = DigitWheelView.tabularWidth(mainFont)
        slotTracking = mainFont.pointSize
            * (trackingEm + (mainFont.fontName.hasPrefix(".") ? Self.sfSlotTrackingEm : 0))
        // 全数字最小左空档（lsb）：邻槽字形最坏的起笔位置；与 slotTracking 一起构成
        // 数字轮「排布宽需扣除的固定量」（护栏判据用，见 DigitWheelView.visibleInkGuard）
        minNeighborInkCache = (0...9).map {
            CTLineGetBoundsWithOptions(
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: String($0), attributes: [.font: mainFont])),
                .useGlyphPathBounds).minX
        }.min() ?? 0
        for s in slots where s.view is DigitWheelView {
            (s.view as? DigitWheelView)?.slotAllowance = slotTracking + minNeighborInkCache
        }
        // 基线探针恒用基础档字体：对外 firstBaselineAnchor 稳定，标题行不随 chip 态跳动
        let probeFont = fontProvider(baseSize, baseWeight, true)
        baseLineH = ceil(probeFont.ascender - probeFont.descender + probeFont.leading)
        baselineProbe.font = probeFont
        probeHeightC?.isActive = false
        let hc = baselineProbe.heightAnchor.constraint(equalToConstant: baseLineH)
        hc.isActive = true
        probeHeightC = hc
        updateBaselineAlignShift()
        updatePrefixIconSize()
        for i in slots.indices {
            let s = slots[i]
            if let w = s.view as? DigitWheelView {
                w.font = mainFont   // didSet → rebuildCells 按新字体落位槽宽
                // 轮子的可见窗口（frame 高）必须随字体行框更新：槽高在结构重建时定格，
                // 换字体/字号后 lineH 变了而槽高不变 → 新字体的数字格被轮子裁剪切底
                //（2026-09-13 用户实测：换回默认字体后数字被裁剪一半）
                slots[i].height = lineH
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
    /// rollDuration 默认预算 1.2s（2026-09-13 用户指定，原 0.9 → 1.5 → 1.2 定稿）：
    /// 未显式传时长的调用方（Token 总计窗口外刷新等）的「10 格一圈」预算口径
    func setText(_ text: String, animated: Bool, rollDuration: CFTimeInterval = 1.2,
                 slideOnRebuild: Bool = false, totalDuration: CFTimeInterval? = nil) {
        endSwap()    // 在途单位换值（纵向换位）立即落定：滚出槽清掉、偏移归零
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
                        // 结构未变、仅静态字符换字（¥ ↔ $）：即时替换不走滚字
                        let f = (slots[i].kind == .prefix) ? prefixFont : mainFont
                        t.setTextImmediately(String(ch), font: f)
                        // 静态字符变化同步槽宽（如 ¥ ↔ $、千分位变化）
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

    // MARK: 单位制切换换值（数字滚动 + 字符纵向换位）

    /// 换值阶段：.fall 消失字符先向下滚出 → .rise 新增字符再从下方滚入。
    /// 两段错峰是**必须的**：同一处位置（下标相同）上「滚出槽」与「滚入槽」重合，
    /// 同时运动会变成上下交叉叠字，与滑移版的毛病同源。
    private enum SwapPhase { case idle, fall, rise }
    private var swapPhase: SwapPhase = .idle
    /// 当前相位内已过时长（相位切换时归零）
    private var swapElapsed: CFTimeInterval = 0
    /// 本次换值的总时长（跨相位累计，只给横向位移插值用）
    private var swapTotalElapsed: CFTimeInterval = 0
    /// 滚出槽（已脱离 slots 表，按进度单独落位）：记录移除瞬间的 frame 作起点
    private var swapFalling: [(view: NSView, frame: NSRect)] = []
    /// 滚入槽（在 slots 表内，`swapYOffset` 给出纵向偏移）
    private var swapRising: Set<ObjectIdentifier> = []
    /// 复用数字轮的旧 x：数字顺序配对下复用轮会落在与旧位不同的下标上，
    /// 有 0～十几 pt 的横向位移——插值抹平，避免落位硬跳（见 relayoutSlots）
    private var swapShiftStarts: [ObjectIdentifier: CGFloat] = [:]
    /// 本次重建新建的槽位（rebuild 回填，滚入段据此建 swapRising）
    private var lastFreshViews: Set<ObjectIdentifier> = []

    /// 单位制切换换值（如千分位完整数字 ↔ M 单位）：**数字轮照常滚动**，
    /// 消失的字符（千分位逗号 / 多余低位数字）先向下滚出，随后新增字符
    /// （小数点、单位字母 M）从下方滚入。
    ///
    /// ⚠️ 为什么不用滑移：滑移的前提是新旧两串存在**位次对应关系**（同格式下位数
    /// 增减，数字轮与同字符静态槽从右向左配对平移）。单位切换时静态位语义完全不同
    /// （旧串是逗号、新串是小数点 + 单位字母），配对池会被不兼容的静态槽挡住，
    /// 于是大量槽位退化成「新建槽滑入 + 旧槽滑出」——两组轨迹在中途交叉，
    /// 屏上同时出现两串数字 = **数值叠字**（2026-09-12 用户反馈）。
    ///
    /// 本方案：按**下标**配对（左对齐数值以首位为锚，复用槽横向基本不动），
    /// 且所有运动都是纵向的，任何一帧都不会出现两串字符并列。
    /// 时长统一取 `Motion.unitSwap`；rollDuration 默认与纵向两段总时长对齐，
    /// 让「M 滚入」与「数字轮停稳」同时收尾。
    func rollSwapText(_ text: String, rollDuration: CFTimeInterval = Motion.unitSwap.total) {
        endSwap()
        endSlide()
        guard text != currentText else { return }
        // 占位「—」/ 离屏：没有可滚出的旧内容，直接落值（首次入场不做换位动效）
        guard window != nil, !isHidden, currentText != "—" else {
            setText(text, animated: false)
            return
        }
        lastFreshViews.removeAll()
        swapFalling.removeAll()
        swapShiftStarts.removeAll()
        rebuild(Array(text), slideOnRebuild: false, rollDuration: rollDuration,
                pairByDigits: true, deferRemoval: true, rollDigits: true)
        currentText = text
        needsLayout = true
        invalidateIntrinsicContentSize()
        // 滚入槽在滚出段就要先候场到行外下方（否则它们会先按终点现身、
        // 进滚入段又跳下去，凭空多一次闪动）
        swapRising = lastFreshViews
        swapPhase = .fall
        swapElapsed = 0
        swapTotalElapsed = 0
        // 首帧立刻按新相位落位：ticker 下一拍（~16ms）才跑，不先排一次的话
        // 滚入槽会以终点位置闪现一帧再跳回行外（闪动）
        relayoutSlots()
        startTicker()
    }

    /// 换值立即落定：滚出槽移除、纵向偏移归零（外部落值 / 视图销毁前的清理口径）
    private func endSwap() {
        guard swapPhase != .idle || !swapFalling.isEmpty else { return }
        swapPhase = .idle
        swapElapsed = 0
        swapTotalElapsed = 0
        swapRising.removeAll()
        swapShiftStarts.removeAll()
        for e in swapFalling { e.view.removeFromSuperview() }
        swapFalling.removeAll()
        lastFreshViews.removeAll()
        // 在途滚字落定：ticker 一停就没人推进它了，不落定会把槽留在半滚态
        for s in slots { (s.view as? TextSlotView)?.finishRoll() }
        relayoutSlots()
    }

    /// 单位换值的横向位移进度（0→1，ease-out cubic）：整段与数字轮滚动同长，
    /// 复用轮从旧 x 缓动到新 x，与纵向两段并行
    private func swapShiftProgress() -> CGFloat {
        let p = min(1, swapTotalElapsed / Motion.unitSwap.total)
        return CGFloat(1 - pow(1 - p, 3))
    }

    /// 滚出段结束 → 清掉滚出槽，进入滚入段（候场在下方的新槽开始升起）
    private func beginSwapRise() {
        for e in swapFalling { e.view.removeFromSuperview() }
        swapFalling.removeAll()
        swapPhase = .rise
        swapElapsed = 0
    }

    /// 单位换值的逐帧纵向偏移（flipped 坐标，正值向下）：
    /// 滚入槽在滚出段先停在 +lineH（行外下方候场），滚入段从 +lineH 升到 0
    /// （ease-out：起手快、收尾贴位）。滚出槽不在 slots 表内，由 `relayoutSlots`
    /// 单独落位。非换值期恒 0。
    private func swapYOffset(_ view: NSView) -> CGFloat {
        guard swapPhase != .idle, swapRising.contains(ObjectIdentifier(view)) else { return 0 }
        guard swapPhase == .rise else { return lineH }
        let p = min(1, swapElapsed / Motion.unitSwap.riseIn)
        return CGFloat(pow(1 - p, 3)) * lineH
    }

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

    /// **主前景色镜像变化后的就地重渲**（2026-09-17 随参数开放新增）：
    /// 数字带是烘色位图（颜色渲染时定格），且颜色源 `Palette.cardForeground` 是同一个
    /// 动态色实例 —— `setTextColor` 那条路的 didSet 相等守卫不会触发，必须显式重建。
    /// 卡片余额数值与 Token 总计大数字都是本类实例，调用点 = `Panel.refreshCardForeground()`
    /// 的整树遍历（`refreshSecondaryForeground` 那种"标脏就行"对它们无效）
    func refreshForegroundColor() {
        for s in slots {
            if let w = s.view as? DigitWheelView { w.refreshForegroundColor() }
            else if let t = s.view as? TextSlotView { t.needsDisplay = true }
        }
        needsDisplay = true
    }

    // —— 内部 ——

    /// 重建槽位（结构变化）。slideOnRebuild=false：直接落值（打开/后台刷新口径）。
    /// true：结构变化滑移——数字轮按「从右对齐配对」复用（个位对个位，原地滚动到
    /// 新值），未复用的旧槽位作为移出列随组滑出后移除；新布局由 relayoutSlots 给出，
    /// 旧→新布局的平移由同一 ticker 驱动（见 onTick 滑移段），时长对齐 rollDuration。
    ///
    /// - pairByDigits: true = 数字轮与静态字符都**按出现顺序**配对（左→右：新串第 k 个
    ///   数字接旧串第 k 个数字、第 k 个静态位接第 k 个静态位），供单位制换值
    ///   `rollSwapText` 用；false = 原有「从右向左配对」（右对齐余额口径）。
    /// - deferRemoval: true = 未复用的旧槽位既不进滑移也不立即移除，改由调用方做
    ///   「向下滚出」的纵向动画（记入 `swapFalling`，见 `rollSwapText` / `endSwap`）。
    /// - rollDigits: true = 单位换值口径 —— 复用数字轮滚动到新值、复用静态槽槽内滚字
    ///   （「数字滚动」+「字符可以滚成新字符」两条都是用户明确要求的手感）；
    ///   滑移/直接落值两条既有路径的动画口径不受影响。
    private func rebuild(_ chars: [Character], slideOnRebuild: Bool, rollDuration: CFTimeInterval,
                         pairByDigits: Bool = false, deferRemoval: Bool = false,
                         rollDigits: Bool = false) {
        // 旧槽位从右到左配对池：数字轮与「同字符」静态槽都可复用——静态槽若不复用，
        // 逗号会以「旧槽滑出 + 新槽滑入」两份存在，两条轨迹不同（delta ≠ 逗号自己的
        // 位移），中途会穿过相邻数字列 = 滑移期数字换位视觉 bug 的根源
        var reusePool: [NSView] = []
        var oldX: [ObjectIdentifier: CGFloat] = [:]
        for s in slots.reversed() { reusePool.append(s.view) }
        for s in slots { oldX[ObjectIdentifier(s.view)] = s.view.frame.origin.x }
        let oldViews = slots.map { $0.view }
        let oldWidth = slotsTotalWidth(slots)
        let oldHadContent = !slots.isEmpty

        // 标记每个新槽位复用了哪个旧视图（数字对数字、同字符静态对同字符静态）。
        // 存**视图本身**而非池下标：两条配对路径（下标配对 / 从右向左配对）共用构建循环。
        var reuseSource = [NSView?](repeating: nil, count: chars.count)
        func compatible(_ ch: Character, _ cand: NSView) -> Bool {
            if ch.isASCII, ch.isNumber { return cand is DigitWheelView }
            return cand is TextSlotView && (cand as? TextSlotView)?.text == String(ch)
        }
        if pairByDigits {
            // 数字顺序配对（单位换值口径）：新串第 k 位数字接旧串第 k 位数字，
            // 复用率最高、滚动最连贯（下标配对会因新旧串静态位错位而大量退化成滚出/滚入）。
            // 数字两侧都是左→右序，所以复用轮之间不会换位、不会互相穿越。
            var wheelIdx = 0
            let wheelPool = slots.compactMap { $0.view as? DigitWheelView }
            for i in 0..<chars.count where chars[i].isASCII && chars[i].isNumber {
                guard wheelIdx < wheelPool.count else { break }
                reuseSource[i] = wheelPool[wheelIdx]
                wheelIdx += 1
            }
            // 静态字符同样按出现顺序配对（新串第 k 个静态位接旧串第 k 个）：
            // - 字符相同（M ↔ M 的逗号/小数点/单位字母）→ 原地复用，不再无谓地滚出/滚入；
            // - 字符不同（`,` ↔ `.` / `M`）→ **同一槽内滚字**（旧字向上滚出、新字自下方滚入），
            //   横向跳位安排在滚出段结束那一刻（槽内为空，跳位不可见）。
            var textIdx = 0
            let textPool = slots.compactMap { $0.view as? TextSlotView }
            for i in 0..<chars.count where !(chars[i].isASCII && chars[i].isNumber) {
                guard textIdx < textPool.count else { break }
                reuseSource[i] = textPool[textIdx]
                textIdx += 1
            }
        } else {
            // 从右到左扫描（右对齐余额口径；不兼容时不推进池，左侧继续尝试）。
            // 记录视图而非消费指针：构建循环按 LTR 走，若用共享指针会与 RTL 标记序错位
            // （错配 + 越界崩溃）
            var poolIdx = 0
            for i in stride(from: chars.count - 1, through: 0, by: -1) {
                guard poolIdx < reusePool.count else { break }
                let cand = reusePool[poolIdx]
                if compatible(chars[i], cand) {
                    reuseSource[i] = cand
                    poolIdx += 1
                }
            }
        }

        var reused: Set<ObjectIdentifier> = []
        var fresh: Set<ObjectIdentifier> = []   // 新建槽位（单位换值的「自下方滚入」据此判定）
        var newSlots: [Slot] = []
        for (i, ch) in chars.enumerated() {
            if ch.isASCII, ch.isNumber, let d = ch.wholeNumberValue {
                let w: DigitWheelView
                var isFresh = false
                if let old = reuseSource[i] as? DigitWheelView {
                    w = old
                    reused.insert(ObjectIdentifier(old))
                } else {
                    w = DigitWheelView()
                    w.font = mainFont
                    w.textColor = textColor
                    w.slotAllowance = slotTracking + minNeighborInkCache
                    addSubview(w)
                    isFresh = true
                    fresh.insert(ObjectIdentifier(w))
                }
                // 复用轮：滑移路径按原口径滚动；单位换值（rollDigits）额外放开滚动
                // ——「依然使用数字滚动」是用户明确要求的手感。
                // 新建轮：直接落值，入场交给纵向滚入（自下方升起），不叠滚动
                w.setDigit(d, animated: slideOnRebuild || (rollDigits && !isFresh),
                           rollDuration: rollDuration)
                newSlots.append(Slot(view: w, kind: .digit, width: w.currentWidth,
                                     yOff: 0, height: lineH))
            } else {
                // 首字符 ¥/$ 且后面还有内容 → 货币符号小字号槽（对齐原 applyValueText 判定）
                let isPrefixSymbol = i == 0 && (ch == "¥" || ch == "$") && chars.count > 1
                let kind: SlotKind = isPrefixSymbol ? .prefix : .plain
                let f = isPrefixSymbol ? prefixFont : mainFont
                let t: TextSlotView
                if let old = reuseSource[i] as? TextSlotView {
                    t = old
                    reused.insert(ObjectIdentifier(old))   // 勿漏：否则旧逗号进滑出列表，落定时被连带移除
                    if rollDigits {
                        // 单位换值：同一槽内滚字（旧字向上滚出 → 新字自下方滚入），
                        // 字符相同则原地不动。横向跳位见 relayoutSlots 静态槽分支。
                        t.rollTo(String(ch), font: f,
                                 out: Motion.unitSwap.fallOut,
                                 inDelay: Motion.unitSwap.fallOut,
                                 inDuration: Motion.unitSwap.riseIn)
                    } else {
                        t.setTextImmediately(String(ch), font: f)
                    }
                } else {
                    t = TextSlotView(text: String(ch), font: f, color: textColor)
                    addSubview(t)
                    fresh.insert(ObjectIdentifier(t))
                }
                newSlots.append(Slot(view: t, kind: kind,
                                     width: textWidth(String(ch), font: f),
                                     yOff: mainFont.ascender - f.ascender,
                                     height: isPrefixSymbol ? prefixLineH : lineH))
            }
        }
        lastFreshViews = fresh

        // 滑移状态先清（endSlide 不适用：槽位表已被替换），旧未复用视图先记后移除
        slideStarts.removeAll()
        slideExits.removeAll()
        slideDelta = 0
        slideElapsed = 0
        slideDuration = 0
        let newWidth = slotsTotalWidth(newSlots)
        if deferRemoval {
            // 复用轮旧 x 存档：数字顺序配对下复用轮会落到与旧位不同的下标，
            // 横向位移由 relayoutSlots 插值抹平（旧 x 就是本帧的实际位置）
            swapShiftStarts = oldX
        }
        for v in oldViews where !reused.contains(ObjectIdentifier(v)) {
            if deferRemoval {
                // 单位换值：先留在屏上做「向下滚出」，起点取移除瞬间的实际 frame
                swapFalling.append((view: v, frame: v.frame))
            } else if slideOnRebuild, oldHadContent {
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
            slideDuration = slideTime()
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

    /// 滑移时长（唯一计算入口）。原先恒取 `rollDuration`（默认 1.2s）而**与位移量无关** →
    /// 位数变化时整组平移明显拖在滚字后面（用户反馈），2026-09-16 落地两档口径；
    /// ⚠️ **2026-09-17 用户「动效的参数固化，移除参数开放」：定稿为「跟随位移」**
    ///（`roll_slide_timing` = distance），设置窗口的单选与 config 键随之移除。
    /// 现行口径：按整组位移量 `|slideDelta|` 缩放，钳制在 `rollSlideMin … rollSlideMax`
    /// （位移 ≤1 个数字宽取下限，≥3 个取上限；位移小就快、位移大也封顶）。
    /// 固化前的另一档 `.wheelTail`（取本轮数字轮里最长的 tween 时长、与滚字同拍收尾）
    /// 算式见下方注释 —— 要换回来把那几行接回去即可。
    /// 两档都不再看 `rollDuration` —— 它是滚字预算，与平移距离无关。
    private func slideTime() -> CFTimeInterval {
        // 一个数字宽的近似值：比例数字档实测 ≈0.62em（等宽档差异不影响量级）
        let digitWidth = max(1, mainFont.pointSize * 0.62)
        let steps = abs(slideDelta) / digitWidth
        let p = min(1, max(0, (steps - 1) / 2))   // 1 个宽 → 0；≥3 个宽 → 1
        return Motion.rollSlideMin + (Motion.rollSlideMax - Motion.rollSlideMin) * Double(p)
        // 备用口径（固化前由设置窗口「滑移时长」选）：
        //   var longest = 0.0
        //   for s in slots { if let w = s.view as? DigitWheelView {
        //       longest = max(longest, w.activeTweenDuration) } }
        //   return max(Motion.rollSlideMin, longest)
    }

    /// 滑移进度 0→1（曲线与数字滚动统一，同走 `rollEase`；
    /// 非滑移期恒 1 = 直接落最终布局）
    private func slideProgress() -> CGFloat {
        guard slideDuration > 0 else { return 1 }
        let p = min(1, slideElapsed / slideDuration)
        return CGFloat(rollEase(p))
    }

    /// 滑移立即落定（setText 重入/视图销毁前的清理口径）
    private func endSlide() {
        guard slideDuration > 0 || !slideExits.isEmpty else { return }
        slideDuration = 0
        slideElapsed = 0
        slideDelta = 0
        slideStarts.removeAll()
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

    /// 槽位**排布推进量**（容器算下一槽 x 用）：数字槽读 wheel.layoutWidth（与帧宽解耦，
    /// 见 DigitWheelView 顶部注释「排布宽与帧宽解耦」）；静态槽 = 自身 advance。
    /// ⚠️ 帧宽（`slotWidth`）与排布推进量必须分开：前者管绘制/裁剪，后者管位置
    private func slotAdvance(_ s: Slot) -> CGFloat {
        (s.view as? DigitWheelView)?.layoutWidth ?? s.width
    }

    /// 槽组总占宽：Σ排布推进量 + 槽间负字距（n 个槽共 n−1 个间隙）。固有宽度与滑移
    /// slideDelta（整组平移量）都以它为口径，漏加会让滑移起点/终点差出一个字距。
    /// ⚠️ 用 `slotAdvance`（排布量）而非 `slotWidth`（帧宽）：静止态两者相等，滚动中
    /// 帧宽会多出防裁剪的余量，混用会让固有宽/滑移量跟着抖
    private func slotsTotalWidth(_ list: [Slot]) -> CGFloat {
        list.reduce(0) { $0 + slotAdvance($1) } + slotTracking * CGFloat(max(0, list.count - 1))
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
        // 下移半个差值；常规态 lineH == bounds.height，居中项 = 0 行为不变。
        // baselineAlignShift = 探针实测基线 − 轮绘制模型基线（2026-09-13 统一解法），
        // 数字墨迹随槽位整体落在探针真实基线上，逐字体精确。
        // （曾按 2026-09-06 需求 hover 点亮时整组上移 3pt，同日用户撤销「不再位移」，
        // 并已实测上移会与账号条/标题行产生叠影，勿加回）
        let yShift = max(0, (bounds.height - lineH) / 2) + baselineAlignShift
        // [RollDbg] 基线偏移哨兵：yShift 明显为负 = 数字带被推出窗口顶部（顶部截字
        // 的另一嫌疑：探针实测基线缓存中毒）。进入坏态打一次点、复健复位，定位后移除
        if yShift < -1 {
            if !loggedNegShiftState {
                loggedNegShiftState = true
                Logger.log(.layout, "[RollDbg] NEG-SHIFT '\(currentText)' yShift=\(String(format: "%.2f", yShift)) lineH=\(lineH) baseLineH=\(baseLineH) boundsH=\(String(format: "%.1f", bounds.height)) alignShift=\(String(format: "%.2f", baselineAlignShift)) font=\(mainFont.fontName)@\(mainFont.pointSize)")
            }
        } else {
            loggedNegShiftState = false
        }
        // 单位换值的横向位移进度（非换值期恒 1 = 直接落最终 x）
        let swapShiftP: CGFloat = (swapPhase != .idle && !swapShiftStarts.isEmpty)
            ? swapShiftProgress() : 1
        // 左对齐：左缘锚 0（原 drawText 的 pen 位置），正向逐槽排布；
        // 右对齐：右缘锚 bounds−右留白，逆向排布（超宽左溢裁掉）。
        // chip 态右留白抬到 hPadding：视图定宽 65 且 masksToBounds，右缘不留够内边距
        // 的话 chip 背景右侧会被裁掉（左右内缩进不对称），故整组左移让 chip 完整入界
        let rightInset = isChipActive ? max(cellTextPadding, ChipStyle.hPadding) : cellTextPadding
        var x = alignsLeft ? 0 : bounds.width - rightInset
        let pxScale = window?.backingScaleFactor ?? 2   // 槽位横向像素网格对齐（见 pixelAligned）
        for s in alignsLeft ? slots : slots.reversed() {
            let w = slotWidth(s)          // 帧宽（防裁剪口径：绘制/裁剪用）
            let adv = slotAdvance(s)      // 排布推进量（与帧宽解耦：位置用）
            var fx: CGFloat
            if alignsLeft {
                fx = x
                x += adv + slotTracking    // 负字距：后续槽左移收紧（左缘锚定）
            } else {
                x -= adv
                fx = x
                x -= slotTracking          // 负字距：下一槽（左侧）右移收紧（右缘锚定）
            }
            if p < 1 {
                let id = ObjectIdentifier(s.view)
                let startX = slideStarts[id] ?? (fx - slideDelta)
                fx = startX + (fx - startX) * p
            } else if let sx = swapShiftStarts[ObjectIdentifier(s.view)] {
                if s.view is TextSlotView {
                    // 静态槽：横向跳位安排在滚出段结束那一刻——此时旧字已滚出、新字还在
                    // 行外，槽内为空，跳位完全不可见（见 TextSlotView.rollTo 的两段错峰）
                    if swapTotalElapsed < Motion.unitSwap.fallOut { fx = sx }
                } else if swapShiftP < 1 {
                    // 数字轮：整段从旧 x 缓动到新 x（数字顺序配对会有小幅横向位移，
                    // 硬跳会像落位错帧）。滚入/滚出槽不在 swapShiftStarts 里，不受影响。
                    fx = sx + (fx - sx) * swapShiftP
                }
            }
            // swapYOffset：单位换值的「自下方滚入」纵向偏移（非换值期恒 0）。
            // 横向坐标像素对齐：位图槽落在亚像素处会被重采样，宽度变化时字缘发糊微移
            s.view.frame = NSRect(x: pixelAligned(fx, scale: pxScale),
                                  y: s.yOff + yShift + swapYOffset(s.view),
                                  width: w, height: s.height)
        }
        // 单位换值：滚出槽已脱离 slots 表，按进度从各自起点向下滚出（x 保持原位）。
        // 与滚入段严格错峰（见 onTick），同位置不会出现上下交叉的两串字符。
        if swapPhase == .fall {
            let p = min(1, swapElapsed / Motion.unitSwap.fallOut)
            let drop = CGFloat(p * p) * lineH   // ease-in：像被抽走
            for e in swapFalling {
                e.view.frame = NSRect(x: e.frame.minX, y: e.frame.minY + drop,
                                      width: e.frame.width, height: e.frame.height)
            }
        }
        if p < 1 {
            for e in slideExits {
                e.view.frame.origin.x = pixelAligned(e.startX + slideDelta * p, scale: pxScale)
            }
        }
        // 前缀图标贴最左槽左侧（右/左对齐下 slots.first 均为最左槽；滑移期随插值帧同步平移）。
        // 纵向（2026-09-14 用户指定）：**底边落在数字基线上**（不再是行内居中）——
        // y = 基线 − 边长，基线 = 内容块顶 yShift + 轮墨迹基线的 cell 内偏移
        if prefixIcon != nil, let first = slots.first {
            prefixIconView.frame = NSRect(
                x: pixelAligned(first.view.frame.minX - prefixIconGap - prefixIconSize, scale: pxScale),
                y: yShift + wheelBaselineInCell - prefixIconSize,
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
            let chipX = pixelAligned(inkMinX - ChipStyle.hPadding, scale: pxScale)
            let chipRight = pixelAligned(inkMaxX + ChipStyle.hPadding, scale: pxScale)
            chipLayer.frame = NSRect(x: chipX, y: yShift,
                                     width: chipRight - chipX, height: lineH)
            // 内容前缘 guide（见属性注释）：与 chip 取同源内容组边缘（含前缀 icon，
            // 不含 chip padding——标题让位对齐的是数字墨迹不是 chip 背景盒）
            contentLeadingConstraint.constant = minX
        } else {
            contentLeadingConstraint.constant = bounds.width   // 无槽位回退列前缘（保守）
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
            if let w = s.view as? DigitWheelView {
                if w.advance(dt: dt) { moving = true }
            } else if let t = s.view as? TextSlotView {
                if t.advance(dt: dt) { moving = true }   // 单位换值的槽内滚字
            }
        }
        // 单位换值：滚出段 →（错峰）→ 滚入段。relayoutSlots 按进度落位，这里推进时间轴
        if swapPhase != .idle {
            swapElapsed += dt
            swapTotalElapsed += dt
            switch swapPhase {
            case .idle:
                break
            case .fall:
                if swapElapsed >= Motion.unitSwap.fallOut { beginSwapRise() }
            case .rise:
                if swapElapsed >= Motion.unitSwap.riseIn { endSwap() }
            }
            moving = true
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

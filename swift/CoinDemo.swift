// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 目的      App 面板「操作」磁贴 → 玻璃弹窗里复刻 mintform-react 的 CSS 3D 硬币
// 参考源    ../mintform-react-main/src：Mintform.tsx（几何/材质/交互算式）、
//           MintformBase.css + Mintform.css（分层与渐变）、core/{geometry,material,
//           motion,appearance}.ts、runtime/useMintformMotion.ts（弹簧与朝向光）
// ⚠️关键前提 参考实现整条 3D 链路**没有 perspective** → 纯正交投影：屏幕坐标就是 (x,y)，
//           translateZ 只决定遮挡、不影响位置。硬币每个面（前后盖 / 侧壁面板）都是平面，
//           平面→屏幕在正交下是**仿射**映射 → 渐变端点直接投影、CGPath 直接 copy(using:)。
// 渲染      Coin3DView 自绘（CG，不走 CALayer 3D）：侧壁面板（背向剔除+深度排序）
//           + 前后盖分层（outer/rim/innerRing/surface/环遮蔽/内阴影/lowerField/mark）
// 重绘驱动  displayLink ticker（`.common`，runModal 下也出帧）每帧置 needsDisplay；
//           ⚠️ 入窗必须**无条件** startTicker（viewDidMoveToWindow 曾用 `if suspended`
//           当闸门，而 suspended 初值 false → 首帧后彻底不动，拖动/自旋全无重绘，
//           表现为「必须先点一下硬币才能拖动」）；鼠标拖动另外自己置一次 needsDisplay
// 盖面阴影  三圈：① **环遮蔽**（与朝向无关，`surfaceRimShadow`）—— 参考实现没有它，
//           它的 offset 纯 ∝ normal.x，正面（normal.x = 0）时两项都退化成 `inset 0 0`、
//           只剩被裁掉外半圈的模糊环（峰值 50%）→ 正面的盘面发平，故补；
//           ② 硬边月牙（`inset −2·shadow-x 0 <色>`）③ 模糊月牙（blur 4px·sizeScale）
// 动效/配色 弹簧自旋、pitchArc 俯仰弧、惰性弹跳；材质 = sgho 预设或
//           Coin Color 派生（CoinMaterial.derived，core/material.ts deriveMaterialTokens 移植）；
//           lowerField 色场颜色独立可调（Field color 色井，不参与派生，CoinSettings.fieldColor）；
//           Preset 两档（CoinPreset：GHO 关色场 / sGHO 开色场）照 Mintform.tsx MintformPreset
// mark/logo CoinLogoArt（CoinSVG.swift 解析：GHO 预设或上传 .svg）+ logoScale/markDepth
// 立体 mark  markDepth > 0 时沿盖面法线挤出成实体 —— 正交下法线位移是常数向量，
//           实体 = 平面轮廓沿该向量的 Minkowski 扫掠（叠 N 份平移副本取并集 = 侧壁）
// mark 上色 **不设独立颜色**：顶面与侧壁都走盖面那支 surface 渐变，侧壁沿挤出方向**浅压暗**
//           （markWallShadeTop → markWallShadeEdge，与币面 inset 阴影同口径：越靠边界越深）；
//           ⚠️ 侧壁宽度 = 挤出位移（几何），所以只压一档浅的 —— 压深了它就是一条随厚度变宽的
//           暗带（曾经 0.45→0.85，看起来像「mark 的轮廓随厚度变粗」）。
//           且 mark 画在盖面 ④ 与「inset 阴影 / lowerField」**之间**，与盖面吃同一遍着色
//           → 视觉上 mark 就是硬币本体雕出来的浮雕（见 drawMark / paintFaceMaterial）
// mark 边界阴影 轮廓外一圈**与朝向无关**的接触阴影（Shadow opacity / Shadow spread 两旋钮）：侧壁只在斜看时有，
//           纯正面立体感全压在它身上；与盖面环遮蔽同源（落影在低的那一侧：币在内侧、
//           mark 在外侧）。⚠️ 投影**随 Logo depth 变宽变黑**（用户 2026-09-11 指定）：
//           宽度 ×(1 + markShadowDepthWidthGain·t)、峰值不透明度 ×(1 + markShadowDepthAlphaGain·t)，
//           t = 厚度滑杆归一化值 —— 任何朝向都成立；投射体几何另见 `markRimShadowCaster`
//           （`.sweptBody` 影贴着挤出体走，`.footprint` 固定在底面轮廓）。
//           ⚠️ 必须排在侧壁/顶面**之前**（内侧半圈靠后两层盖掉），且全程**一次填充**
// 调参      CoinMetrics（几何/动效旋钮）+ CoinFormMetrics（表单行高/列宽，Control·Edge 共用）
//           参数区 Control / Edge / Motion 三块；调参实时上币 + 通知同步主面板小硬币
// 落盘      CoinSettings（UserDefaults，key 见 UDKey.coin*）：**自动保存**（2026-09-13 起，
//           原显式「保存」按钮已删）—— 每次参数变更即时整份写盘；实时同步主面板小硬币。
//           一个控件一条；上传的 logo 存 SVG 原文 + 文件名
// mark 适配 上传件按 viewBox 撑满 160 盒会冲出 r=61.5 的裁剪圆 → drawMark 按 radialReach
//           把它整体缩回圆的外接方形内（只缩不放，预设不动）
// 表单      CoinFormSectionView（标题+容器基类）/ CoinFormCardView（圆角卡+行间发丝线）
//           / CoinFormRowView（一行一参数、等高）/ CoinSliderRowView（滑杆行）；
//           Control 区 = CoinControlSectionView（排最前），Edge 区 = CoinEdgeSectionView，
//           Motion 区 = CoinMotionSectionView —— 三块装进 CoinDemoPanelView 里的
//           NSScrollView（设置窗口内嵌时视口 = 参数区自然高、整卡随页面滚动；
//           弹窗壳内同参数区自然高），「保存 / 关闭」按钮固定在 GlassModalShell 的 footer
// 入口      CoinDemoDialog.present()（GlassModalShell；面板侧接线见 PanelLayout/Panel/main）
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa
import UniformTypeIdentifiers

// 本文件是「一个自成体系的复刻件」：下面这些类型只服务本文件，名字带 Coin 前缀避免撞模块内其他类型。

// MARK: - 数值口径（对照 mintform 默认 props 与 CSS 变量，单位 = 160pt 参考盒的 px）

/// 硬币几何 / 动效的全部旋钮。`size`（160）是**参考盒**：mintform 的 CSS 把这些 px 值
/// 写死在 size=160 的基准上，运行时尺寸（`Coin3DView.size`）变了就按
/// sizeScale = size / 160 换算 —— 随尺寸缩放的只有内缩 / mark 裁剪半径，
/// 影的模糊·扩散与惰性弹跳在参考实现里**不**乘 sizeScale，这里同样不乘。
enum CoinMetrics {
    /// 参考盒边长（= mintform 默认 size；下面所有数值的基准盒）
    static let size: CGFloat = 160
    /// Coin Size 滑杆范围（上限同时决定弹窗内容区高度，见 `Coin3DView.contentHeight`）。
    /// 上限 192 → **170**（2026-09-13 用户要求「coin size 上限为 170」）；
    /// 落盘值超过上限的由 `CoinSettings.load` 的夹取自动收进 170。
    static let defaultSize = 160.0
    static let sizeRange: ClosedRange<Double> = 96...170
    /// 「Panel coin size」默认值与滑杆范围（pt）：主面板 Token 板块里那枚内嵌硬币的直径。
    /// 与弹窗的 `size` 相互独立 —— 弹窗是「浮在舞台上的大币」，内嵌是「贴着数字的记号」
    /// （2026-09-12 用户指定可单独调）。厚度 / 浮雕深度仍按内嵌直径 ÷ 弹窗直径等比缩放。
    static let defaultPanelSize = 32.0
    static let panelSizeRange: ClosedRange<Double> = 16...48
    /// 厚度默认值 = size × 0.10（Mintform.tsx `thickness ?? size * 0.1`）。
    /// 运行时可调，见 `Coin3DView.thickness`；滑杆范围见 `thicknessRange`。
    static let defaultThickness = 16.0
    /// Edge 面板的厚度滑杆范围（用户指定 10…70）
    static let thicknessRange: ClosedRange<Double> = 10...70
    /// 侧壁分段数（**固定值，不随 size 变化**；2026-09-12 用户指定）。
    /// 原为自适应 `round(π·size / 4.19)`（4.19 = core/appearance.ts TARGET_PANEL_WIDTH.high，
    /// 目标是「每块面板绝对宽 ~4.19pt」），代价是小尺寸硬币的分段数按比例缩水：
    /// 32pt 内嵌硬币只剩 24 段（撞下限），L4 侧壁经线数量远少于 160pt 弹窗硬币。
    /// 定值 120 = 参考盒 size 160 在该公式下的原取值 —— 弹窗硬币外观**完全不变**，
    /// 小尺寸硬币的侧壁密度与之对齐。
    /// 附带收益：`width/size` = panelWidthRatio/120 成为常量，面板内切圆比例
    /// （`cos(width/size)`）不再随尺寸漂移。
    static let panelSegments = 120
    /// outline 描边线宽下限（pt，2026-09-12 用户指定 0.2）。
    /// 线宽 = 基准 × outlineWidth × sizeScale，小尺寸硬币会掉到亚像素：
    /// 32pt 内嵌硬币的 0.5× 经线只有 0.1pt（2x 屏 0.2 设备像素），被抗锯齿摊平成
    /// 一层极淡的灰，等于白画。统一钳到该下限后细线仍然可见。
    /// 大尺寸硬币（160pt 及以上）所有线宽本来就 ≥ 0.4pt，不受影响。
    static let minOutlineWidth = 0.2
    /// rendering.edge.panelWidthRatio 默认值（> π 才有叠压，防侧壁露缝）
    static let panelWidthRatio = 3.4
    /// 盖面三层内缩（--mintform-rim-inset / inner-ring-inset / surface-inset）
    static let rimInset = 1.0
    static let innerRingInset = 16.5
    static let surfaceInset = 18.0
    /// mark 的 clip-path: circle(61.5px at center)
    static let markClipRadius = 61.5
    /// mark 立体化：Logo 厚度 = 沿**盖面法线**把平面轮廓挤出的深度（单位同 160 参考盒 px）。
    /// 0 = 保持参考实现的平贴观感；范围上限取到硬币半厚（16/2）以内，超了就不像浮雕了。
    static let defaultMarkDepth = 4.0
    static let markDepthRange: ClosedRange<Double> = 0...12
    /// 侧壁明暗：沿挤出方向往材质面阴影里压多少 —— **只是一档浅压暗**（把斜面与材质分开），
    /// 顶面边缘取 `markWallShadeTop`，扫掠外缘取 `markWallShadeEdge`，中间线性过渡
    /// （与币面 inset 阴影同口径：越靠边界越深）。
    /// ⚠️ 这一档**不承担「轮廓」职责**，轮廓见 `markShadowSpread` 那圈边界阴影。侧壁的宽度 = 挤出位移（几何，
    /// 与 Logo depth 成正比、改不掉），一旦压深（曾用到 0.85，几乎等于影色）它就和那圈影连成
    /// 一条**随厚度变宽的暗带** —— 看起来像「币面上 mark 的轮廓粗了一圈」。压暗量因此按
    /// 「明显弱于影的峰值」取（约 1/4 档）：厚度只表现为身体变宽 / 顶面位移，轮廓宽度恒定。
    static let markWallShadeTop = 0.04
    static let markWallShadeEdge = 0.12
    /// 挤出实体沿位移方向叠几份：屏幕位移每 `markExtrudeStep` px 一份，上限 24 份。
    /// 正交投影下挤出位移是**常数向量**，所以实体 = 平面图形沿该向量的 Minkowski 扫掠，
    /// 用有限份平移副本取并集逼近 —— 步长够小就是精确的（见 `drawMark`）。
    static let markExtrudeStep = 0.5
    static let markExtrudeStepLimit = 24
    /// 边界阴影挂靠的**扫掠并集**副本间距（px，见 `sweepOutline`）：`CGPath.union` 不便宜，
    /// 份数越少越好；而这支并集只喂给边界阴影那圈模糊，间距（2）远小于模糊半径（8）时
    /// 包络上的蜂窝起伏（细笔画最明显）在模糊后不可分辨。
    /// ⚠️ 只有 `.sweptBody` 那一档用得到它（`.footprint` 不算并集）。
    static let sweepOutlineGap = 2.0
    /// mark 的「边界阴影」：浮雕轮廓外一圈**与朝向无关**的接触阴影（模糊半径 / 峰值不透明度）。
    /// ⚠️ 与币面「环形环境遮蔽」同源（见 `surfaceRimShadow`），口径只有一条：**落影永远在低的那一侧**。
    /// 币的凸起边缘（抬起的盘缘）落影在凹陷的盘面上 → 边界**内侧**；mark 的凸起边缘（抬起的浮雕）
    /// 落影在它压着的币面上 → 轮廓**外侧**。没有它的话纯正面（挤出位移 = 0、连侧壁都不存在）
    /// 浮雕会彻底平掉，读起来像贴上去的贴纸 —— 币靠环遮蔽立住，mark 靠这一圈。
    /// 两只旋钮 2026-09-14 起开放到设置 forms（Control 区 **Shadow opacity / Shadow spread**，
    /// 经 CoinSettings 落盘、内嵌小硬币同步跟随）：
    /// - **spread** 是**视觉衰减距离**（160 盒 px）：轮廓处满值、往外这么远衰减到 0；0 = 整圈关断。
    /// - **opacity** 是**轮廓处可见峰值不透明度**（N 遍合成后，百分数）。⚠️ 单遍 setShadow 在形状
    ///   边界只落地一半 alpha（高斯台阶半高，见 drawMark 的 ×2 补偿）→ 单遍可见峰值封顶 0.5，
    ///   N 遍 source-over 合成封顶 1−0.5^N；每遍落点 alpha 由峰值反解：b = 1−(1−peak)^(1/N)，见 drawMark。
    ///   ⚠️ 想往上顶**只能加遍数** —— 所以遍数随滑杆值自适应（`markRimShadowPasses(forPeak:)`）：
    ///   ≤75% 仍走 N=2（老值视觉一个像素都不动），75% 往上自动升到 3…6 遍。
    static let markShadowSpreadRange: ClosedRange<Double> = 0...16
    /// Shadow opacity 滑杆量程（百分数）。⚠️ 100 是**滑杆刻度**、不是渲染封顶：真正能落到的合成峰值
    /// 见 `markShadowOpacityCeiling`（100% 时 N=6 → 98.4375%，顶端那 1.6% 肉眼不可分辨）。
    /// 2026-09-14 用户「改为最高 100%」由 0...75 放宽到此；放宽只动上限，老值（≤75）读回来一字不改。
    static let markShadowOpacityRange: ClosedRange<Double> = 0...100
    /// 出厂默认：spread 8（参考实现量级）；opacity 70 = 旧定值 markRimShadowAlpha 0.45
    /// （2026-09-11 用户「初始阴影再深一些」）× N=2 遍合成 ≈ 0.6975 取整 —— 2026-09-14
    /// 「加深 svg 带来的阴影」后以此为新基线开放调参。
    static let defaultMarkShadowSpread = 8.0
    static let defaultMarkShadowOpacity = 70.0
    /// 边界阴影的**叠画遍数**：同一轮廓把带影填充重复 N 次，影逐遍 source-over 合成
    /// 1−(1−a)^N，抬起单遍 0.5 的可见峰值上限 —— 只加深，模糊半径与轮廓形态不变。
    /// ⚠️ 遍数**随滑杆值自适应**（`markRimShadowPasses(forPeak:)`）：合成封顶 1−0.5^N，
    /// 峰值 ≤ 75% 时 N=2 就够（α≤1 的夹取线还没咬到），再往上必须加遍数才真能变深。
    /// 代价 = 每多一遍一次模糊（离线探针、160pt/2× 弹窗币 depth 拉满：1.26→2.30 ms/帧，N=6 ≈ 3.9 ms/帧；
    /// 重画只发生在硬币运动期间，静止有位图缓存不吃）。峰值低时不多花这笔钱。
    static let markRimShadowMinPasses = 2
    static let markRimShadowMaxPasses = 6
    /// 渲染真正能落到的合成峰值上限 = 1 − 0.5^Nmax（Nmax = 6 → 98.4375%）。
    /// 滑杆给到 100 只是刻度取整，落点一律夹到这里（否则反解出的每遍 alpha 会越过 α≤1 的夹取线，
    /// 顶端一段滑杆变成「推了没反应」的死区）
    static var markShadowOpacityCeiling: Double {
        1 - pow(0.5, Double(markRimShadowMaxPasses))
    }
    /// 给定目标峰值（**分数** 0…1，即滑杆百分数 /100）时该叠几遍：每遍可见峰值 ≤ 0.5（色 α≤1 夹取），
    /// 要 1−(1−b)^N = peak 反解出的 b 不越过 0.5 就得 N ≥ log2(1/(1−peak)) —— 取满足条件的最小遍数
    /// （夹在 min…max 之间）。于是峰值低时不多花模糊，且 0…75% 这一段恒为 2 遍 = 与旧版逐像素一致。
    static func markRimShadowPasses(forPeak peak: Double) -> Int {
        let p = min(max(peak, 0), markShadowOpacityCeiling)
        guard p > 0 else { return markRimShadowMinPasses }
        let needed = Int((log(1 - p) / log(0.5)).rounded(.up))
        return min(max(needed, markRimShadowMinPasses), markRimShadowMaxPasses)
    }
    /// 接触阴影挂哪种几何（用户 2026-09-11 定：投影要**随 Logo depth 变宽变黑**，见下面两个 gain）。
    /// - `.sweptBody`（默认）：挂在挤出体的扫掠并集上 —— 身体一鼓出去，影跟着身体走，
    ///   扫掠包络上的凹角 / 被挤窄的缝隙还会把模糊影从两侧灌满 → 额外加一层「越深越宽越黑」。
    /// - `.footprint`：只挂底面轮廓，几何与 depth 无关（投影固定不动，只有 gain 那条在起作用）。
    ///
    /// 实测（离线逐 depth 渲染对比，size=160 / 2× 设备 px / 72 条射线量可见半影带宽；
    /// 这是**未加 gain** 的纯几何效应）：depth 0→12、rot 70°、细笔画 logo 时
    /// `sweptBody` 带宽均值 7.3→8.0、峰值 17.5→21.6；`footprint` 7.3→7.2、17.5→16.2。
    /// ⚠️ 纯几何效应**在正面（挤出位移 = 0）恒为零** —— 所以「depth 越大投影越宽越黑」这件事
    /// 由下面两个 gain 显式承担（任何朝向下都成立），几何档只决定影贴着谁走。
    static let markRimShadowCaster: CoinMarkShadowCaster = .sweptBody
    /// **关联 ①（宽度）**：投影随 Logo depth 变宽。depth 归一化 t = markDepth / markDepthRange.upperBound，
    /// 实际模糊半径 = `markShadowSpread` × (1 + gain × t) —— 默认 0.5 → depth 拉满时宽 1.5 倍。
    static let markShadowDepthWidthGain = 0.5
    /// **关联 ②（黑度）**：投影随 Logo depth 变黑。每遍落点 b = 1−(1−peak)^(1/N)（peak =
    /// Shadow opacity，N 见 `markRimShadowPasses(forPeak:)`），实际再乘 (1 + gain × t)。
    /// ⚠️ 取 0.11 而不是更大：出厂 peak 70%（N=2）的 b = 0.4523，×(1+0.11) 后色值 2b ≈ 1.004
    /// 恰好顶到 setShadow 色 α≤1 的夹取线 —— 调大只会让「变黑」提前顶死失去变化
    /// （宽度那条 gain 不受此限）。⚠️ 峰值拉到 ~90% 以上时这条 gain 本就已顶死（每遍落点接近 0.5
    /// 的可见上限），「越深越黑」不再额外生效 —— 这是既有口径，非本次放宽量程引入。
    static let markShadowDepthAlphaGain = 0.11
    /// 盖面「环形环境遮蔽」：一圈**与朝向无关**的内阴影（宽度 / 峰值不透明度）。
    /// ⚠️ 参考实现没有这个 —— 它的 box-shadow offset 纯 ∝ normal.x，正面（normal.x = 0）时
    /// `inset 0 0 <色>`（硬边）与 `inset 0 0 4px`（模糊）都退化成只剩模糊那半圈，
    /// 而且外半圈被裁剪吃掉、峰值只到 50% → 正面的盘面发平、看不出是个凹盘。
    /// 这里补一圈「从 radius − w 渐深到 radius 满值」的环，任何朝向都在。
    static let surfaceRimShadow = 8.0
    static let surfaceRimShadowAlpha = 0.35
    /// 盖面内阴影的模糊半径（CSS `inset 0 0 4px`，随尺寸缩放）——
    /// 落地影的 blur 用的是同一个数，两者同源。
    /// ⚠️ 落地影（bottom −40px / 宽 75% / spread 4px / 组不透明度 0.1）与它那套常量
    /// （`shadowBottom` / `shadowWidthRatio` / `shadowWidthReduction` / `shadowSpread` /
    /// `shadowOpacity`）已按用户 2026-09-13 要求「3D 硬币去掉地上的阴影」整段移除；
    /// 这个 `shadowBlur` 因为盖面也在用，保留。
    static let shadowBlur = 4.0
    /// 惰性弹跳（--mintform-idle-height / duration，缓动 cubic-bezier(.45,0,.55,1)）
    static let idleBounceHeight = 20.0
    static let idleBounceDuration = 3.0
    /// 弹簧（profile = reference：stiffness 15；damping = 2√k → 临界阻尼、不过冲）
    static let springStiffness = 15.0
    /// rendering.motion.spinDegrees：一次点按**一圈**的度数，实际转 `turns` 圈（Turns 滑杆 1…5）
    static let spinDegrees = 360.0
    /// motion.pitchArc：点按过程中的额外俯仰，进度中点为峰值、结束回零
    static let pitchArc = 18.0
    /// 拖动灵敏度（Mintform.tsx DRAG_*）
    static let dragYawPerPixel = 0.55
    static let dragTiltPerPixel = 0.28
    static let dragStartDistance = 5.0
    static let maxFlickDegrees = 180.0
    /// 俯仰夹紧窗口半径（±45）：拖拽俯仰与点按弧的显示夹紧都**挂在静止俯仰上**
    /// （restingTilt ± 本值）—— resting tilt 可设到 ±180（翻背面），绝对 ±45 会在
    /// 非零静止俯仰下把拖拽/显示瞬间拽回 0 附近（参考实现静止俯仰恒 0，不存在此问题）
    static let pitchLimit = 45.0
    /// 弹簧静止阈值（runtime/useMintformMotion.ts）
    static let restEpsilon = 0.02
    /// 默认静止朝向（yaw，度）：CoinSettings.restingRotation 的出厂默认（45）。
    /// 用户 2026-09-11 指定（参考实现出生是 0 = 纯正面）；实际出生姿态走 Coin3DView 的
    /// restingRotation / restingTilt 属性，由弹窗与内嵌实例各自灌值。
    static let defaultRestingRotation = 45.0
    /// Motion 区滑杆范围（用户 2026-09-11 指定）：静止俯仰 / 静止朝向 ±180（可翻到背面），
    /// 点按自旋 1…5 圈。
    static let restingTiltRange: ClosedRange<Double> = -180...180
    static let restingRotationRange: ClosedRange<Double> = -180...180
    static let turnsRange: ClosedRange<Double> = 1...5
    /// Outline 线稿的内部结构层级（Style = Outline 时 Outline level 滑杆）。
    /// 原为 1…5，2026-09-12 用户指定**去掉 L5**（mark 扫掠过程线）→ 上限收到 4。
    /// 老值 5 由 `CoinSettings.load()` 夹回 4，不会把滑杆顶歪。
    static let outlineLevelRange: ClosedRange<Double> = 1...4
    /// Outline 线稿的**基准线宽**（px/160 盒；各类线 = 基准 × 各自系数，全乘 sizeScale）
    static let outlineWidthRange: ClosedRange<Double> = 1...10
}

// MARK: - 三维点与 CSS 旋转（坐标系：x 右 / y 下 / z 朝观察者，与 CSS 一致）

struct CoinVec {
    var x: Double
    var y: Double
    var z: Double
}

/// CSS `rotateY(θ)`：x' = x·cosθ + z·sinθ，z' = −x·sinθ + z·cosθ
private func coinRotY(_ p: CoinVec, _ radians: Double) -> CoinVec {
    let c = cos(radians), s = sin(radians)
    return CoinVec(x: p.x * c + p.z * s, y: p.y, z: -p.x * s + p.z * c)
}

/// CSS `rotateX(θ)`：y' = y·cosθ − z·sinθ，z' = y·sinθ + z·cosθ
private func coinRotX(_ p: CoinVec, _ radians: Double) -> CoinVec {
    let c = cos(radians), s = sin(radians)
    return CoinVec(x: p.x, y: p.y * c - p.z * s, z: p.y * s + p.z * c)
}

// MARK: - 颜色（sRGB 分量 + oklab 混合）

/// 不透明 sRGB 三通道。CSS 的 `color-mix(in oklab, …)` 是参考实现推导整套材质 token 的
/// 唯一手段，所以这里必须真的走 oklab（sRGB 直接插值在深色/高饱和两端会明显发灰）。
struct CoinRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    /// display-p3 原值（mintform 预设材质用的色彩空间）→ 落到 sRGB
    init(p3 r: Double, _ g: Double, _ b: Double) {
        let converted = NSColor(displayP3Red: r, green: g, blue: b, alpha: 1).usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        self.init(Double(converted.redComponent),
                  Double(converted.greenComponent),
                  Double(converted.blueComponent))
    }

    static let black = CoinRGB(0, 0, 0)
    static let white = CoinRGB(1, 1, 1)

    private var linearComponents: (Double, Double, Double) {
        func f(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return (f(r), f(g), f(b))
    }

    private static func srgbComponent(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// Oklab（Björn Ottosson 的矩阵）—— color-mix 的插值空间
    private var oklab: (Double, Double, Double) {
        let (r, g, b) = linearComponents
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    private static func fromOklab(_ L: Double, _ A: Double, _ B: Double) -> CoinRGB {
        let l_ = L + 0.3963377774 * A + 0.2158037573 * B
        let m_ = L - 0.1055613458 * A - 0.0638541728 * B
        let s_ = L - 0.0894841775 * A - 1.2914855480 * B
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return CoinRGB(srgbComponent(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                       srgbComponent(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                       srgbComponent(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    /// `color-mix(in oklab, a, b, t)`：t=0 取 a、t=1 取 b
    static func mix(_ a: CoinRGB, _ b: CoinRGB, _ t: Double) -> CoinRGB {
        let t = min(max(t, 0), 1)
        let (al, aa, ab) = a.oklab
        let (bl, ba, bb) = b.oklab
        return fromOklab(al + (bl - al) * t, aa + (ba - aa) * t, ab + (bb - ab) * t)
    }

    func cgColor(alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    /// 非 `NSColor(cgColor:)`（那条路是可失败的）：分量直构造
    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// "#RRGGBB"（落盘用；分量四舍五入到 8 位）
    var hex: String {
        String(format: "#%02X%02X%02X",
               Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// 解析 "#RRGGBB"（前导 `#` 可省）；长度不对或含非十六进制字符 → nil
    init?(hex: String) {
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(Double((value >> 16) & 0xFF) / 255,
                  Double((value >> 8) & 0xFF) / 255,
                  Double(value & 0xFF) / 255)
    }
}

/// 渐变停止点（CSS 渐变里的「颜色 + 位置」，颜色可带透明度：lowerField 就是从透明渐显）
struct CoinStop {
    let color: CoinRGB
    let alpha: Double
    let location: CGFloat

    init(_ color: CoinRGB, alpha: Double = 1, at location: CGFloat) {
        self.color = color
        self.alpha = alpha
        self.location = location
    }
}

/// 已投影的一条线性渐变（端点 + 渐变对象）
struct CoinGradient {
    let gradient: CGGradient
    let start: CGPoint
    let end: CGPoint
}

// MARK: - 材质（sgho 预设）

/// `preset="sgho"` = REFERENCE_GHO 材质 + 默认 lowerField（紫）。
/// 面材质的 shade 派生根在 `faceTokens(shade:)`，照 MintformBase.css 里
/// `.mintform__face` 那 5 条 color-mix 抄。
struct CoinMaterial: Equatable {
    var faceBase: CoinRGB
    var faceMid: CoinRGB
    var faceShadow: CoinRGB
    var faceHighlight: CoinRGB
    var faceDepthHighlight: CoinRGB
    var edgeBase: CoinRGB
    var edgeAccent: CoinRGB
    /// lowerField（sgho 默认：reach 0.5、softness 0.3 → 50% 起透明、80% 起实色）
    var field: CoinRGB
    var fieldTransparentAt: Double
    var fieldOpaqueAt: Double

    static let sgho = CoinMaterial(
        faceBase: CoinRGB(p3: 0.31, 0.85, 0.24),
        faceMid: CoinRGB(p3: 0.28, 0.75, 0.29),
        faceShadow: CoinRGB(p3: 0.22, 0.61, 0.22),
        faceHighlight: CoinRGB(p3: 0.42, 0.98, 0.78),
        faceDepthHighlight: CoinRGB(p3: 0.19, 0.72, 0.44),
        edgeBase: CoinRGB(p3: 0.31, 0.85, 0.24),
        edgeAccent: CoinRGB(p3: 0.28, 0.75, 0.29),
        field: CoinRGB(p3: 0.61, 0.57, 0.98),
        fieldTransparentAt: 50,
        fieldOpaqueAt: 80)

    /// Coin Color 换色：core/material.ts `deriveMaterialTokens` 原样移植 ——
    /// 从一个颜色推整套面/边 token。lowerField 不参与派生（参考实现里它是独立 prop，
    /// sgho 预设的紫色色场保持不变）。
    static func derived(from base: CoinRGB) -> CoinMaterial {
        let (h, s, l) = rgbToHSL(base)
        let neutral = s < 8
        // shade()：中性色锁灰；饱和度夹 18…92、亮度夹 5…94（与参考实现同口径，
        // hsl() 输出前四舍五入成整数 —— 派生结果要与参考实现逐位对齐就照抄）
        func shade(_ h: Double, _ s: Double, _ l: Double) -> CoinRGB {
            hslToRGB(hue: neutral ? 0 : h.rounded(),
                     sat: neutral ? 0 : min(max(s, 18), 92).rounded(),
                     light: min(max(l, 5), 94).rounded())
        }
        let mid = shade(h + 3, s * 0.75, l - 3)
        return CoinMaterial(
            faceBase: base,
            faceMid: mid,
            faceShadow: shade(h + 3, s * 0.7, l - 13),
            faceHighlight: shade(h + 31, s + 17, l + 16),
            faceDepthHighlight: shade(h + 30, s - 10, l - 9),
            edgeBase: base,
            edgeAccent: mid,
            field: sgho.field,
            fieldTransparentAt: sgho.fieldTransparentAt,
            fieldOpaqueAt: sgho.fieldOpaqueAt)
    }

    /// RGB（0…1）→ HSL（h 度 / s、l 百分数），core/material.ts parseHexToHsl 的算式
    private static func rgbToHSL(_ c: CoinRGB) -> (h: Double, s: Double, l: Double) {
        let maximum = max(c.r, c.g, c.b), minimum = min(c.r, c.g, c.b)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        var hue = 0.0
        if delta != 0 {
            if maximum == c.r { hue = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6) }
            if maximum == c.g { hue = (c.b - c.r) / delta + 2 }
            if maximum == c.b { hue = (c.r - c.g) / delta + 4 }
            hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        return (hue, saturation * 100, lightness * 100)
    }

    /// HSL（h 度 / s、l 百分数）→ RGB
    private static func hslToRGB(hue: Double, sat: Double, light: Double) -> CoinRGB {
        let s = sat / 100, l = light / 100
        let chroma = (1 - abs(2 * l - 1)) * s
        let hp = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (chroma, x, 0)
        case ..<2: (r1, g1, b1) = (x, chroma, 0)
        case ..<3: (r1, g1, b1) = (0, chroma, x)
        case ..<4: (r1, g1, b1) = (0, x, chroma)
        case ..<5: (r1, g1, b1) = (x, 0, chroma)
        default:   (r1, g1, b1) = (chroma, 0, x)
        }
        let m = l - chroma / 2
        return CoinRGB(r1 + m, g1 + m, b1 + m)
    }

    /// 随朝向明暗派生的 5 个面 token（shade = faceShade ∈ 0…1）
    func faceTokens(shade: Double) -> (base: CoinRGB, mid: CoinRGB, shadow: CoinRGB,
                                       highlight: CoinRGB, depth: CoinRGB) {
        (CoinRGB.mix(faceBase, faceShadow, shade),
         CoinRGB.mix(faceMid, faceShadow, shade),
         CoinRGB.mix(faceShadow, .black, shade * 0.30),
         CoinRGB.mix(faceHighlight, faceBase, shade),
         CoinRGB.mix(faceDepthHighlight, faceShadow, shade))
    }
}

// MARK: - 预设

/// mintform `preset` 两档（Mintform.tsx `MintformPreset`；aave 参考实现有 token 但本弹窗没接）。
/// 两者共用同一套 GHO 面/边 token（REFERENCE_GHO），差别**只在 lowerField**：
/// - `gho`  = 无色场（参考实现 `lowerField: false` → transparentAt/opaqueAt = 100，全程透明，
///   渲染层盖面 `fieldTransparentAt < 100` 与侧壁 `end <= start` 两条路径天然不画）；
/// - `sgho` = 启用色场（默认紫，Field color 色井可改）。
/// Coin color 色井在这两档下都照常覆盖面/边 token（参考实现的 `material` prop 同口径）。
enum CoinPreset: Int, CaseIterable {
    case gho, sgho

    var title: String {
        switch self {
        case .gho:  return "GHO"
        case .sgho: return "sGHO"
        }
    }
}

// MARK: - 外观档

/// 外观档（Control 区 **Style** 拉下按钮，用户 2026-09-11 指定）：
/// UI 名叫 **Style**（用户 2026-09-11 指定）；`default` = 现在的材质渲染（mintform 复刻）；
/// - `outline` = 线稿外观：硬币**外轮廓**（两盖圆投影的凸包描边）+ 盖面**边框**
///   （innerRing / surface 内缩圆细线）+ **mark 填充实色**（贴可见盖面平面）。
///   线与填充全用 `material.faceBase`（跟 Coin color 走），不画材质层。
enum CoinAppearance: Int, CaseIterable {
    case `default`, outline

    var title: String {
        switch self {
        case .default: return "Default"
        case .outline: return "Outline"
        }
    }
}

// MARK: - 边纹样式

/// mintform `edge.finish` 三档（core/appearance.ts `MintformEdgeFinish`）。
/// 三者共用同一套密封侧壁网格，只改**面板怎么上色**：
/// - `reeded`  = 每 `accentEvery` 块换一次 ridge 色（sgho 默认 2）→ 竖向齿纹；
/// - `uniform` = 取消交替，整圈同色，但保留每块面板自己的 90° 横向高光；
/// - `smooth`  = 连横向高光也去掉，整圈读成一整块连续材质。
enum CoinEdgeFinish: Int, CaseIterable {
    case reeded, uniform, smooth

    var title: String {
        switch self {
        case .reeded:  return "Reeded"
        case .uniform: return "Uniform"
        case .smooth:  return "Smooth"
        }
    }

    /// 交替齿纹的间隔（Mintform.tsx `accentEvery`）：非 reeded 恒 0 = 不交替
    var accentEvery: Int { self == .reeded ? 2 : 0 }
}

// MARK: - mark 接触阴影的投射体

/// `markShadowSpread` 那圈接触阴影「挂在哪块几何上」。⚠️ 它只决定**影贴着谁走**；
/// 「投影随 Logo depth 变宽变黑」那条关联由 `markShadowDepthWidthGain` /
/// `markShadowDepthAlphaGain` 显式承担（任何档、任何朝向都生效）。
enum CoinMarkShadowCaster {
    /// 挂**整个挤出体的扫掠并集**（底面 ∪ 沿途副本 ∪ 顶面，默认）：身体鼓出去，影跟着身体走，
    /// 扫掠包络上的凹角 / 被挤窄的缝隙还会额外把模糊影灌满 → 除 gain 之外再加一层「越深越宽越黑」。
    case sweptBody
    /// 只挂**底面轮廓**：几何与 depth 完全无关，影固定不动（只剩 gain 那条关联在起作用）。
    /// 代价：挤出到一定深度后身体会把「远端」那半圈影盖住（实测 72 条射线里极端档约 10 条无影）
    /// → 投影看起来偏向近端一侧。
    case footprint
}

// MARK: - 侧壁几何

/// 硬币侧壁的面板模板（与姿态无关，初始化算一次）。
/// 与 Mintform.tsx 同式：`--mintform-edge-panel-width` = ratio×size/segments、
/// `--mintform-edge-panel-radius` = (size/2)·cos(panelWidth/size)（参考实现就是把面板宽
/// 当弧度塞进 cos，照抄不改 —— 它决定面板收在哪个内切圆上）。
struct CoinGeometry {
    let segments: Int
    let panelWidth: Double
    let panelRadius: Double
    /// 第 index 块面板的 4 个角（局部坐标，0 号在硬币正上方、顺时针编号）
    let corners: [[CoinVec]]
    /// 横向渐变（CSS `linear-gradient(90deg, …)`）沿切向的起止点
    let axes: [(CoinVec, CoinVec)]
    let normals: [CoinVec]
    /// lowerField 在每块面板上的强度（core/geometry.ts ridgeFieldStrength）
    let fieldStrength: [Double]

    init(size: Double, thickness: Double, transparentAt: Double, opaqueAt: Double) {
        // 固定分段数：不随 size 变化（见 CoinMetrics.panelSegments 的说明）
        let count = CoinMetrics.panelSegments
        let width = CoinMetrics.panelWidthRatio * size / Double(count)
        // 参考实现把「面板宽」当弧度塞进 cos（照抄不改）：它决定面板收在哪个内切圆上
        let radius = size / 2 * cos(width / size)
        let halfWidth = width / 2
        let halfThickness = thickness / 2

        // 局部坐标：rotateZ(a) translateY(−r) rotateX(90°) 之后 · (u, 沿厚度偏移)
        func point(_ u: Double, _ w: Double, _ angle: Double) -> CoinVec {
            let c = cos(angle), s = sin(angle)
            return CoinVec(x: u * c + radius * s, y: u * s - radius * c, z: w)
        }

        var cornerList: [[CoinVec]] = []
        var axisList: [(CoinVec, CoinVec)] = []
        var normalList: [CoinVec] = []
        var strengthList: [Double] = []
        let start = min(max(transparentAt / 100, 0), 1)
        let end = min(max(opaqueAt / 100, start), 1)
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * .pi
            cornerList.append([point(-halfWidth, -halfThickness, angle),
                               point(halfWidth, -halfThickness, angle),
                               point(halfWidth, halfThickness, angle),
                               point(-halfWidth, halfThickness, angle)])
            axisList.append((point(-halfWidth, 0, angle), point(halfWidth, 0, angle)))
            normalList.append(CoinVec(x: sin(angle), y: -cos(angle), z: 0))
            // 环角 → 竖直位置：0 号在顶（vp=0），半圈即物理底部（vp=1）
            let vertical = (1 - cos(angle)) / 2
            strengthList.append(end <= start ? (vertical >= end ? 1 : 0)
                                             : min(max((vertical - start) / (end - start), 0), 1))
        }

        segments = count
        panelWidth = width
        panelRadius = radius
        corners = cornerList
        axes = axisList
        normals = normalList
        fieldStrength = strengthList
    }
}

// MARK: - 参考实现的纯函数移植（core/geometry.ts · core/motion.ts）

enum CoinMath {
    /// core/geometry.ts projectCoinNormal
    static func projectedNormal(yaw: Double, pitch: Double) -> CoinVec {
        let y = yaw * .pi / 180, p = pitch * .pi / 180
        return CoinVec(x: sin(y), y: -sin(p) * cos(y), z: cos(p) * cos(y))
    }

    /// core/motion.ts shadingForNormal（lighting="reference"：无方向光，纯参考配方）
    static func shading(for normal: CoinVec) -> (face: Double, edge: Double) {
        let edgeOn = hypot(normal.x, normal.y)
        return (edgeOn * edgeOn, normal.z * normal.z)
    }

    /// core/motion.ts pitchArcOffset：点按弧在中点达峰值、终点回到起始偏移
    static func pitchArcOffset(rotation: Double, origin: Double, target: Double,
                               startOffset: Double, arc: Double) -> Double {
        let distance = target - origin
        if abs(distance) < 0.000001 { return 0 }
        let progress = min(max((rotation - origin) / distance, 0), 1)
        return startOffset * (1 - progress) + arc * sin(.pi * progress)
    }

    /// 惰性弹跳相位（0…1 三角波：0/1 在原点、0.5 在最高点）——对应 CSS 的 0%/50%/100% 关键帧
    static func bouncePhase(now: CFTimeInterval) -> Double {
        let t = now.truncatingRemainder(dividingBy: CoinMetrics.idleBounceDuration)
            / CoinMetrics.idleBounceDuration
        return t < 0.5 ? t * 2 : (1 - t) * 2
    }

    /// cubic-bezier(0.45, 0, 0.55, 1)（CSS 关键帧的缓动）——牛顿迭代解 t(x) 再取 y
    static func easeInOut(_ x: Double) -> Double {
        let x1 = 0.45, y1 = 0.0, x2 = 0.55, y2 = 1.0
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let mt = 1 - t
            return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t
        }
        var t = min(max(x, 0), 1)
        for _ in 0..<6 {
            let error = bezier(t, x1, x2) - x
            if abs(error) < 1e-6 { break }
            let mt = 1 - t
            let slope = 3 * mt * mt * x1 + 6 * mt * t * (x2 - x1) + 3 * t * t * (1 - x2)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        return bezier(min(max(t, 0), 1), y1, y2)
    }

    /// 圆 → 目标坐标（正交下是椭圆：把贝塞尔圆整段映射过去）
    static func circlePath(radius: Double, transform: CGAffineTransform) -> CGPath {
        var transform = transform
        let path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius,
                                            width: radius * 2, height: radius * 2),
                          transform: nil)
        return path.copy(using: &transform) ?? path
    }

    /// CSS `linear-gradient(θ, …)` 的渐变线：过盒心、方向 (sinθ, −cosθ)、
    /// 长度 = 盒边长 ×(|sinθ|+|cosθ|)；两端点经仿射映射到目标坐标。
    static func linearGradient(angle: Double, boxSide: Double, transform: CGAffineTransform,
                              stops: [CoinStop]) -> CoinGradient? {
        let theta = angle * .pi / 180
        let dx = sin(theta), dy = -cos(theta)
        let half = boxSide * (abs(sin(theta)) + abs(cos(theta))) / 2
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: stops.map { $0.color.cgColor(alpha: $0.alpha) } as CFArray,
                                        locations: stops.map(\.location)) else { return nil }
        return CoinGradient(gradient: gradient,
                            start: CGPoint(x: -dx * half, y: -dy * half).applying(transform),
                            end: CGPoint(x: dx * half, y: dy * half).applying(transform))
    }

    /// CSS inset box-shadow：把「偏移后的圆」之外、裁剪形状之内的那圈阴影补上。
    /// 硬边（blur=0）一把成；带模糊时拆成若干**互不重叠**的环带按权重叠加 ——
    /// 环带之间不叠，透明度是精确相加，不会出现重复混色（这是分带而不是画 N 层的原因）。
    static func fillInsetShadow(_ ctx: CGContext, clip: CGPath, transform: CGAffineTransform,
                                circleCenter: CGPoint, radius: Double, blur: Double,
                                color: CGColor) {
        func ellipse(_ center: CGPoint, _ r: Double) -> CGPath {
            CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2),
                   transform: nil)
        }
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        if blur < 0.5 {
            let path = CGMutablePath()
            path.addRect(CGRect(x: -4000, y: -4000, width: 8000, height: 8000))
            path.addPath(ellipse(circleCenter, radius), transform: transform)
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        } else {
            let steps = 6
            let full = color.alpha
            // 由内向外：环带 alpha 线性爬升，最外圈（偏移圆之外）拿满值
            for step in 0..<steps {
                let inner = radius - blur + 2 * blur * Double(step) / Double(steps)
                let outer = radius - blur + 2 * blur * Double(step + 1) / Double(steps)
                let path = CGMutablePath()
                path.addPath(ellipse(circleCenter, outer), transform: transform)
                path.addPath(ellipse(circleCenter, inner), transform: transform)
                ctx.setFillColor(color.copy(alpha: full * Double(step + 1) / Double(steps)) ?? color)
                ctx.addPath(path)
                ctx.fillPath(using: .evenOdd)
            }
            let path = CGMutablePath()
            path.addRect(CGRect(x: -4000, y: -4000, width: 8000, height: 8000))
            path.addPath(ellipse(circleCenter, radius + blur), transform: transform)
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()
    }

}

// MARK: - 姿态框架

/// 当前帧的正交投影框架：硬币中心的局部坐标 → 目标坐标。
/// 局部→世界用 `rotateX(pitch) rotateY(rotation)`（即 CSS 的 body 变换），
/// 正交投影就是丢掉 z；视图与位图都是 y 向下、与 CSS 同向，不必翻符号。
struct CoinFrame {
    let rotation: Double
    let pitch: Double
    let center: CGPoint
    /// 当前厚度（px，见 `Coin3DView.thickness`）：决定两个盖面在 z 上的位置
    let thickness: Double

    /// 局部点 → 世界（body 是纯旋转且原点在硬币中心，所以点与方向同一套变换）
    func transform(_ p: CoinVec) -> CoinVec {
        coinRotX(coinRotY(p, rotation * .pi / 180), pitch * .pi / 180)
    }

    /// 局部点 → 目标坐标（正交：屏幕坐标就是 (x, y)）
    func project(_ p: CoinVec) -> CGPoint {
        let world = transform(p)
        return CGPoint(x: center.x + world.x, y: center.y + world.y)
    }

    /// 盖面局部（原点在盖心、y 向下、单位 = 160 盒 px）→ 目标坐标的仿射映射。
    /// CSS: front = `translateZ(+h/2)`；back = `rotateY(180deg) translateZ(+h/2)`。
    /// ⚠️ rotateY 只取反 x 与 z，**y 轴不动** —— 后盖是 x 镜像、z 落到 −h/2，
    /// y 必须与前盖同号；早先这里让 unitY 跟着 sign 一起取反，后盖内容被整块反转 180°
    /// （logo 倒立 + surface 渐变 highlight→depth 上下颠倒）。
    func capTransform(front: Bool) -> CGAffineTransform {
        let sign: Double = front ? 1 : -1
        let z = sign * thickness / 2
        let origin = project(CoinVec(x: 0, y: 0, z: z))
        let unitX = project(CoinVec(x: sign, y: 0, z: z))
        let unitY = project(CoinVec(x: 0, y: 1, z: z))
        return CGAffineTransform(a: unitX.x - origin.x, b: unitX.y - origin.y,
                                 c: unitY.x - origin.x, d: unitY.y - origin.y,
                                 tx: origin.x, ty: origin.y)
    }

    /// 盖面是否朝向观察者（凸体只需正面：背面必被正面/侧壁挡住）
    func capIsVisible(front: Bool) -> Bool {
        transform(CoinVec(x: 0, y: 0, z: front ? 1 : -1)).z > 0
    }
}

// MARK: - 硬币渲染视图

/// 3D 硬币。视图是翻转坐标（y 向下，与 CSS 同向），硬币中心 = (bounds.midX, restCenterY)；
/// 本地几何一律用「以硬币中心为原点、边长 = size 的盒」坐标，正交投影即 (x, y) 直投。
final class Coin3DView: NSView {

    /// 弹窗内容区高度（定值，按滑杆上界一次性算死）：
    /// 硬币投影半径（最大尺寸×最大厚度）+ 惰性弹跳。**不含落地影**（2026-09-13 用户要求
    /// 「3D 硬币去掉地上的阴影」，相关代码与高度预算一并移除）。
    /// 运行时「整组（币顶到币底）在这个舞台里垂直居中」——于是任何尺寸下都不裁、重心不跳。
    static let contentHeight: CGFloat = {
        let s = CoinMetrics.sizeRange.upperBound
        let t = CoinMetrics.thicknessRange.upperBound
        let top = (s * s + t * t).squareRoot() / 2 + CoinMetrics.idleBounceHeight + 1
        let bottom = s / 2
        return CGFloat((top + bottom).rounded(.up))
    }()

    /// 静止时硬币中心（y 自视图顶向下）：整组垂直居中。上留「投影半径 + 弹跳」、
    /// 下留「半径」—— 满量程实例按 contentHeight（滑杆上界算死）居中，
    /// 设置窗口内嵌实例舞台收窄（stageHeight = fit 当前参数），两条在滑杆范围内
    /// 恒成立，不做运行时钳制。
    /// 紧凑实例（见 `compactInline`）没有弹跳，按自身 size/thickness 收紧的盒居中。
    private var restCenterY: CGFloat {
        let reach = (size * size + thickness * thickness).squareRoot() / 2
        if compactInline {
            return compactFittingHeight / 2
        }
        let top = max(size / 2 + CoinMetrics.idleBounceHeight,
                      reach + CoinMetrics.idleBounceHeight + 1)
        let bottom = size / 2
        return (stageHeight - top - bottom) / 2 + top
    }

    /// 舞台高度（宿主按需收窄，默认 = contentHeight 满量程）：内嵌面板用 fit 当前
    /// size/thickness 的值省掉用不到的滑杆上界留白（「缩小预览视图」2026-09-13）；
    /// 居中公式随它走，任何高度下整组垂直居中不裁
    var stageHeight: CGFloat = contentHeight {
        didSet {
            guard stageHeight != oldValue else { return }
            needsDisplay = true   // coinCenter 在 draw 链路读取，重绘即重居中
        }
    }

    /// 紧凑实例所需的正方形边长：投影半径（含厚度）×2 + 1pt 余量 + **弹跳余量**。
    /// 弹跳以静止位为中心上下对称（见 `bounceOffset`），所以余量 = 幅度本身（上下各半）。
    /// 供内嵌方（Token 板块）定 frame 用；普通弹窗实例不用它（那是满量程 `contentHeight`）。
    var compactFittingHeight: CGFloat {
        let reach = (size * size + thickness * thickness).squareRoot() / 2
        let coin = max(size / 2, reach) * 2 + 1
        return CGFloat((coin + bounceAmplitude).rounded(.up))
    }

    /// 惰性弹跳幅度（pt）：弹窗按参考盒的绝对 20px；内嵌紧凑实例按 sizeScale 缩放
    /// （32pt 硬币 → 4pt）。直接套 20px 会让小硬币跳出数字行带。
    private var bounceAmplitude: Double {
        compactInline ? CoinMetrics.idleBounceHeight * sizeScale : CoinMetrics.idleBounceHeight
    }

    /// 惰性弹跳的纵向相位：弹窗是「从地面弹起」（0…1，只向上）；
    /// 内嵌硬币贴着文字、上下都有邻居，改成以静止位为**中心**对称浮动（-0.5…0.5），
    /// 免得只往上顶撞到上一行。
    private var bounceOffset: Double {
        let phase = CoinMath.easeInOut(CoinMath.bouncePhase(now: CACurrentMediaTime() - startTime))
        return compactInline ? (phase - 0.5) : phase
    }

    /// 尺寸换算：所有随尺寸缩放的 CSS px 值都乘它（参考盒 160 不变）
    private var sizeScale: Double { size / Double(CoinMetrics.size) }

    /// 硬币直径（px）：驱动侧壁几何、盖面半径、位图尺寸 → 重建几何 + 丢缓存
    var size: Double = CoinMetrics.defaultSize {
        didSet {
            guard size != oldValue else { return }
            rebuildGeometry()
        }
    }

    /// 厚度（px）：直接改侧壁几何与两个盖面的 z → 必须重建几何 + 丢弃位图缓存
    var thickness: Double = CoinMetrics.defaultThickness {
        didSet {
            guard thickness != oldValue else { return }
            rebuildGeometry()
        }
    }

    /// 材质：Coin Color 派生（`CoinMaterial.derived(from:)`）；lowerField 参数进侧壁几何
    var material = CoinMaterial.sgho {
        didSet {
            guard material != oldValue else { return }
            rebuildGeometry()
        }
    }

    /// 边纹样式：只改侧壁怎么上色，不动几何 → 丢缓存即可
    var edgeFinish: CoinEdgeFinish = .reeded {
        didSet {
            guard edgeFinish != oldValue else { return }
            invalidateRender()
        }
    }

    /// 外观档（见 `CoinAppearance`）：只改怎么画，不动几何 → 丢缓存即可。
    /// ⚠️ 不能叫 `appearance` —— NSView 自带 `appearance: NSAppearance?`，撞名会报 override
    var style: CoinAppearance = .default {
        didSet {
            guard style != oldValue else { return }
            invalidateRender()
        }
    }

    /// Outline 线稿的内部结构层级（1…5，Style = Outline 时 Control 区「Outline level」可调）：
    /// 级别越高内部线越多，见 `drawOutline` 的分层说明。只影响 outline 渲染 → 丢缓存
    var outlineLevel = 1 {
        didSet {
            guard outlineLevel != oldValue else { return }
            invalidateRender()
        }
    }

    /// Outline 线稿的**基准线宽**（px/160 盒，1…10；各类线 = 基准 × 各自系数）：
    /// hull 1.5×、innerRing/rim 1×、surface/L3 0.6×、裁剪圆 0.5×、经线 0.5×、扫掠线 0.4×
    var outlineWidth = 1.0 {
        didSet {
            guard outlineWidth != oldValue else { return }
            invalidateRender()
        }
    }

    /// logo 缩放（Mintform.tsx mark.scale，滑杆范围 0.5…1.25）：丢缓存
    var logoScale = 1.0 {
        didSet { guard logoScale != oldValue else { return }; invalidateRender() }
    }

    /// logo 厚度（沿盖面法线挤出的深度，px/160 盒）：只动 mark 怎么画 → 丢缓存。
    /// 0 = 平贴（= 参考实现原样）；> 0 时 mark 变成硬币实体的一部分，转起来能看见侧壁
    var markDepth: Double = CoinMetrics.defaultMarkDepth {
        didSet { guard markDepth != oldValue else { return }; invalidateRender() }
    }

    /// mark 边界阴影的**可见峰值不透明度**（轮廓处、N 遍合成后；分数 0…0.984375，设置存百分数）：
    /// drawMark 里反解出每遍的落点 alpha，见 `CoinMetrics.markShadowOpacityRange`
    var markShadowOpacity = CoinMetrics.defaultMarkShadowOpacity / 100 {
        didSet { guard markShadowOpacity != oldValue else { return }; invalidateRender() }
    }

    /// mark 边界阴影的**视觉衰减距离**（px/160 盒；0 = 整圈阴影关断）
    var markShadowSpread = CoinMetrics.defaultMarkShadowSpread {
        didSet { guard markShadowSpread != oldValue else { return }; invalidateRender() }
    }

    /// logo 轮廓（GHO 预设或上传的 SVG 解析结果）：丢缓存 + 重算基准缩放
    var logoArt = CoinSVG.ghoPreset {
        didSet {
            logoContentFit = Self.contentFit(for: logoArt)
            invalidateRender()
        }
    }

    /// Logo 反色（Control 区 Logo 组的原生开关）：把 logo 与硬币面互为**负形** ——
    /// 裁剪圆内「logo 实体」变透明、「logo 之外」变实心（logo 自己的镂空洞自然被填实）。
    /// 两种外观档都生效：Outline 走 even-odd 一次填充；Default 把「裁剪圆 − logo」合成
    /// 单条路径当**一个实体**，照常吃挤出 / 侧壁 / 顶面 / 边界阴影。
    var logoInverted = false {
        didSet {
            guard logoInverted != oldValue else { return }
            invalidateRender()
        }
    }

    /// 轮廓自带的内容缩放（见 `contentFit(for:)`）：只跟轮廓有关，所以在 `logoArt` 变化时
    /// 算一次，别在每帧的 `drawMark` 里重算路径包围盒
    private var logoContentFit = 1.0

    /// 内容冲出裁剪圆（按 viewBox 撑满 160 盒的上传件）时，整体缩回圆内所需的**基准缩放**。
    /// **只缩不放**（≤1），两级判定：
    /// 1. 外接方形还没出圆 → 恒为 1，一分不动。预设 mark 是照着固定裁剪圆画的（擦边是刻意外观），
    ///    以及留白正常的 viewBox 都落在这一档。
    /// 2. 外接方形确实出圆 → 按 `radialReach`（**真实几何**离圆心的最大半径）收缩。用外接方收缩只能
    ///    保证方形进圆，方形四角仍在圆外 → 上传件看起来还是「缺角」。
    private static func contentFit(for art: CoinLogoArt) -> Double {
        let clip = CoinMetrics.markClipRadius
        guard let square = art.boundingReach, square > clip,
              let reach = art.radialReach, reach > clip else { return 1 }
        return clip / reach
    }

    // 姿态与弹簧状态（对应 Mintform.tsx 的 animationRef）；
    // 出生姿态 = restingRotation / restingTilt（下面的 rotation/target 与 tilt/tiltTarget
    // 初值必须与属性默认值同值：45/0，否则一入窗弹簧就空转/俯仰一段）
    private var rotation = CoinMetrics.defaultRestingRotation
    private var target = CoinMetrics.defaultRestingRotation
    private var velocity = 0.0
    private var tilt = 0.0
    private var tiltTarget = 0.0
    private var tiltVelocity = 0.0
    private var usesPitchArc = false
    private var pitchOrigin = 0.0
    private var pitchTarget = 0.0
    private var pitchStartOffset = 0.0

    /// 静止朝向（yaw，度，Motion 区 Resting rotation 滑杆）：出生姿态与「回正」目标。
    /// 改动即时对齐（rotation/target/velocity 一起写），拖滑杆时硬币直接跟手。
    var restingRotation = CoinMetrics.defaultRestingRotation {
        didSet {
            guard restingRotation != oldValue else { return }
            rotation = restingRotation
            target = restingRotation
            velocity = 0
        }
    }
    /// 静止俯仰（度，Motion 区 Resting tilt 滑杆，±180 可翻到背面）：出生姿态。
    /// 拖拽俯仰的夹紧窗口也挂在它身上（restingTilt ± pitchLimit，见 mouseDragged）。
    var restingTilt = 0.0 {
        didSet {
            guard restingTilt != oldValue else { return }
            tilt = restingTilt
            tiltTarget = restingTilt
            tiltVelocity = 0
        }
    }
    /// 点按自旋圈数（Motion 区 Turns 滑杆 1…5）：spin() 一次转 turns × 360°
    var turns = 1

    private let springDamping = 2 * CoinMetrics.springStiffness.squareRoot()
    /// 侧壁模板：随尺寸 / 厚度 / 材质（lowerField 参数）重建（见 `rebuildGeometry()`）
    private var geometry: CoinGeometry
    private let startTime = CACurrentMediaTime()

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var suspended = false

    // 位图缓存：3D 部分只在姿态变化时重建，惰性弹跳阶段每帧只做一次 blit
    private var cachedImage: CGImage?
    private var cachedKey: [Double] = []

    // 拖动状态
    private var dragStart = CGPoint.zero
    private var dragStartRotation = 0.0
    private var dragStartTilt = 0.0
    private var dragLastX: CGFloat = 0
    private var dragLastTime: CFTimeInterval = 0
    private var dragVelocity = 0.0
    private var dragged = false
    private var suppressClick = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// 内嵌紧凑实例（Token 板块大数字左边那枚小硬币）：只保留硬币本体渲染 ——
    /// 高度按 `compactFittingHeight` 收紧到行带内。
    /// **惰性弹跳保留**（2026-09-12 用户指定「硬币在主面板时也会上下移动」），
    /// 但幅度按 sizeScale 缩放、且以静止位为中心上下对称（见 `bounceOffset`）。
    /// ⚠️ 材质 / logo / 边纹 / 厚度 / 浮雕深度这些**参数**与弹窗完全同源（见 CoinSettings），
    /// 紧凑的只是呈现（弹窗是「浮在舞台上的大币」，内嵌是「贴着文字的记号」）。
    var compactInline = false
    /// 是否接受鼠标交互（点击自旋 / 拖动翻转）。内嵌实例同样保持开启（用户 2026-09-11 指定：
    /// 任何时候都能操作）—— 命中只限硬币圆内，圈外的滚动 / hover 不受影响。
    var interactive = true

    /// 兜底接受「非活跃窗口的首次鼠标事件」：弹窗刚上屏 / App 被系统切到后台时窗口不是
    /// key，默认这第一下会被系统吞去当激活点击 —— 表现为「必须先点一下才能拖动硬币」。
    /// 这里让第一下按下就直接进入拖动（同 ResizeHandle 的口径）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }


    override init(frame frameRect: NSRect) {
        geometry = CoinGeometry(size: CoinMetrics.defaultSize,
                                thickness: CoinMetrics.defaultThickness,
                                transparentAt: CoinMaterial.sgho.fieldTransparentAt,
                                opaqueAt: CoinMaterial.sgho.fieldOpaqueAt)
        super.init(frame: frameRect)
        // 初始轮廓（GHO 预设）不触发 didSet，这里补算一次基准缩放
        logoContentFit = Self.contentFit(for: logoArt)
        // 每帧靠 needsDisplay 重绘：显式声明「needsDisplay 即重绘 layer 内容」，
        // 不吃 AppKit 对「被祖先带上图层」的视图默认策略的亏
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 几何/上色参数变了：丢掉离屏位图，下一帧重画
    private func invalidateRender() {
        cachedImage = nil
        cachedKey = []
        needsDisplay = true
    }

    /// 尺寸 / 厚度 / 材质的 lowerField 参数变了 → 侧壁模板整块重建
    private func rebuildGeometry() {
        geometry = CoinGeometry(size: size, thickness: thickness,
                                transparentAt: material.fieldTransparentAt,
                                opaqueAt: material.fieldOpaqueAt)
        invalidateRender()
    }

    // MARK: 布局与生命周期

    private var coinCenter: CGPoint { CGPoint(x: bounds.midX, y: restCenterY) }
    /// 命中区 = 直径 size 的圆（对应 CSS 里 border-radius:50% 的按钮）
    private var hitRadius: CGFloat { CGFloat(size / 2) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactive else { return nil }   // 内嵌实例：鼠标事件穿过去（面板照常滚动/hover）
        let local = convert(point, from: superview)
        guard hypot(local.x - coinCenter.x, local.y - coinCenter.y) <= hitRadius else { return nil }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        guard interactive else { return }   // 内嵌实例不是可拖控件，别放抓手光标
        addCursorRect(NSRect(x: coinCenter.x - hitRadius, y: coinCenter.y - hitRadius,
                             width: hitRadius * 2, height: hitRadius * 2), cursor: .openHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // 入窗（含首次）就起 ticker：静止弹跳、点按自旋、拖动重绘全靠它每帧
            // needsDisplay。⚠️ 曾经这里是 `if suspended { ... }`，而 suspended 初值
            // false → 首次入窗被整段跳过：硬币画完第一帧后彻底不动，拖动改了 rotation
            // 也没人重绘（draw 只跑 1 次），表现为「必须先点一下硬币（spin 里才第一次
            // 调 startTicker）才能拖动」。startTicker 自身幂等，直接无条件调。
            suspended = false
            startTicker()
        } else {
            // 离开窗口即拆 displayLink：NSView.displayLink 强持有 target、本视图又持有 link，
            // 不主动 invalidate 会成环（与 RollingNumberView 同坑）
            suspended = true
            link?.invalidate()
            link = nil
        }
    }

    private func startTicker() {
        if link == nil {
            let created = displayLink(target: self, selector: #selector(onTick(_:)))
            // .common：runModal 跑的是 NSModalPanelRunLoopMode，只有 common 模式集能出帧
            created.add(to: .main, forMode: .common)
            link = created
        }
        lastTimestamp = 0
        link?.isPaused = false
    }

    // MARK: 每帧推进

    @objc private func onTick(_ link: CADisplayLink) {
        guard window != nil else {
            suspended = true
            link.isPaused = true
            return
        }
        // 窗口收起 / 所在区块被隐藏（面板关掉、Token 板块隐藏）时不出帧：内嵌实例常驻面板，
        // 不设这道闸就会在菜单栏小工具后台常开 60fps 空转。displayLink 保持运行以便自动恢复。
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else {
            lastTimestamp = 0
            return
        }
        let now = CACurrentMediaTime()
        if lastTimestamp == 0 { lastTimestamp = now }
        // 墙钟计时 + dt 封顶（参考实现 Math.min(delta, 0.05)）：
        // 低刷新率屏上 displayLink 可能同帧连发（dt=0），墙钟对重复回调免疫
        let dt = min(now - lastTimestamp, 0.05)
        lastTimestamp = now
        advance(dt: dt)
        needsDisplay = true
    }

    /// 弹簧积分（runtime/useMintformMotion.ts 的 render 原样移植）
    private func advance(dt: Double) {
        let spinning = abs(target - rotation) >= CoinMetrics.restEpsilon
            || abs(velocity) >= CoinMetrics.restEpsilon
        let tilting = abs(tiltTarget - tilt) >= CoinMetrics.restEpsilon
            || abs(tiltVelocity) >= CoinMetrics.restEpsilon

        if spinning {
            let acceleration = CoinMetrics.springStiffness * (target - rotation) - springDamping * velocity
            velocity += acceleration * dt
            rotation += velocity * dt
            if abs(target - rotation) < CoinMetrics.restEpsilon, abs(velocity) < CoinMetrics.restEpsilon {
                rotation = target
                velocity = 0
            }
        }
        if tilting {
            let acceleration = CoinMetrics.springStiffness * (tiltTarget - tilt) - springDamping * tiltVelocity
            tiltVelocity += acceleration * dt
            tilt += tiltVelocity * dt
            if abs(tiltTarget - tilt) < CoinMetrics.restEpsilon,
               abs(tiltVelocity) < CoinMetrics.restEpsilon {
                tilt = tiltTarget
                tiltVelocity = 0
            }
        }
    }

    /// 当前帧姿态：rotation + 实际俯仰（含点按弧）
    private var currentPose: (rotation: Double, pitch: Double) {
        let spinning = abs(target - rotation) >= CoinMetrics.restEpsilon
            || abs(velocity) >= CoinMetrics.restEpsilon
        let offset = (spinning && usesPitchArc)
            ? CoinMath.pitchArcOffset(rotation: rotation, origin: pitchOrigin, target: pitchTarget,
                                      startOffset: pitchStartOffset, arc: CoinMetrics.pitchArc)
            : 0
        return (rotation, min(max(tilt + offset, restingTilt - CoinMetrics.pitchLimit),
                              restingTilt + CoinMetrics.pitchLimit))
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragStartRotation = rotation
        dragStartTilt = tilt
        dragLastX = point.x
        dragLastTime = event.timestamp
        dragVelocity = 0
        dragged = false
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        if !dragged, hypot(dx, dy) < CoinMetrics.dragStartDistance { return }
        dragged = true
        rotation = dragStartRotation + Double(dx) * CoinMetrics.dragYawPerPixel
        target = rotation
        velocity = 0
        tilt = min(max(dragStartTilt - Double(dy) * CoinMetrics.dragTiltPerPixel,
                       restingTilt - CoinMetrics.pitchLimit), restingTilt + CoinMetrics.pitchLimit)
        tiltTarget = tilt
        tiltVelocity = 0
        // 拖动即时重绘：姿态是这里直接改的，别只依赖 ticker 的每帧 needsDisplay
        //（ticker 若因任何原因没跑，拖动就会「拖半天硬币一动不动」）。
        needsDisplay = true
        let elapsed = event.timestamp - dragLastTime
        if elapsed > 0 {
            let instantaneous = Double(point.x - dragLastX) * CoinMetrics.dragYawPerPixel / elapsed
            dragVelocity = min(max(instantaneous, -1440), 1440)
        }
        dragLastX = point.x
        dragLastTime = event.timestamp
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        guard dragged else {
            if !suppressClick { spin() }
            return
        }
        // 甩动：把松手瞬间的角速度折算成一小段目标位移，之后交给同一根弹簧收尾
        suppressClick = true
        DispatchQueue.main.async { [weak self] in self?.suppressClick = false }
        let flick = min(max(dragVelocity * 0.15, -CoinMetrics.maxFlickDegrees), CoinMetrics.maxFlickDegrees)
        target = rotation + flick
        velocity = 0
        tiltTarget = tilt
        tiltVelocity = 0
        usesPitchArc = false
        pitchOrigin = rotation
        pitchTarget = rotation
        pitchStartOffset = 0
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:    // space → 再转一圈（Enter/Esc 已被弹窗按钮的 keyEquivalent 占用）
            spin()
        case 53:    // esc → 关弹窗
            NSApp.stopModal(withCode: .cancel)
        default:
            super.keyDown(with: event)
        }
    }

    /// 点按自旋：方向顺时针、`turns` 圈（Motion 区 Turns 滑杆 1…5，默认 1）
    func spin() {
        usesPitchArc = true
        // 上一次自旋可能正处在俯仰弧中途：先把当前可见的弧折进起始偏移，避免瞬间跳变
        pitchStartOffset = CoinMath.pitchArcOffset(rotation: rotation, origin: pitchOrigin,
                                                  target: pitchTarget, startOffset: pitchStartOffset,
                                                  arc: CoinMetrics.pitchArc)
        pitchOrigin = rotation
        target += Double(turns) * CoinMetrics.spinDegrees
        pitchTarget = target
        startTicker()
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pose = currentPose
        // 惰性弹跳：弹窗与内嵌都跑（相位口径不同，见 bounceOffset）；幅度按实例缩放
        let bounce = bounceOffset

        guard let image = coinImage(pose: pose, scale: window?.backingScaleFactor ?? 2) else { return }
        let side = size + thickness * 2
        let rect = NSRect(x: coinCenter.x - side / 2,
                          y: coinCenter.y - side / 2 - CGFloat(bounceAmplitude * bounce),
                          width: side, height: side)
        // 翻转视图里 CGContext.draw 会上下颠倒：显式反翻转一次
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// 3D 硬币位图（姿态/明暗没变就直接复用）
    private func coinImage(pose: (rotation: Double, pitch: Double), scale: CGFloat) -> CGImage? {
        let shade = CoinMath.shading(for: CoinMath.projectedNormal(yaw: pose.rotation, pitch: pose.pitch))
        let key = [pose.rotation, pose.pitch, shade.face, shade.edge, Double(scale),
                   style == .outline ? 1 : 0, Double(outlineLevel), Double(outlineWidth),
                   logoInverted ? 1 : 0]
        if let cachedImage, cachedKey == key { return cachedImage }
        guard let image = renderCoin(pose: pose, shade: shade, scale: scale) else { return nil }
        cachedImage = image
        cachedKey = key
        return image
    }

    /// 把硬币画进一张离屏位图。正交投影下平面→屏幕是仿射，所以侧壁面板与盖面分层
    /// 都能用「投影端点 + 整段 CGPath 映射」精确画出来。
    private func renderCoin(pose: (rotation: Double, pitch: Double),
                            shade: (face: Double, edge: Double), scale: CGFloat) -> CGImage? {
        let side = size + thickness * 2
        let pixels = Int((side * scale).rounded(.up))
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        // 位图里也翻成 y 向下，与本视图 / CSS 同向
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        let frame = CoinFrame(rotation: pose.rotation, pitch: pose.pitch,
                              center: CGPoint(x: side / 2, y: side / 2),
                              thickness: thickness)
        // Outline 外观：整条材质管线都不走，只画线稿（见 `drawOutline`）
        if style == .outline {
            drawOutline(ctx, frame: frame, pose: pose)
            return ctx.makeImage()
        }
        let tokens = material.faceTokens(shade: shade.face)
        drawSidewall(ctx, frame: frame, edgeShade: shade.edge)
        if frame.capIsVisible(front: true) {
            drawCap(ctx, frame: frame, front: true, tokens: tokens, pose: pose)
        }
        if frame.capIsVisible(front: false) {
            drawCap(ctx, frame: frame, front: false, tokens: tokens, pose: pose)
        }
        return ctx.makeImage()
    }

    // MARK: 侧壁

    // MARK: Outline 外观

    /// Outline 外观：整条材质管线不走，只画线稿（线与填充全用 `material.faceBase`，
    /// 跟 Coin color 走）。`outlineLevel`（1…4，L5「mark 扫掠过程线」已于 2026-09-12
    /// 按用户要求去掉）决定**内部结构线**画到哪一层，越高越多：
    /// - L1：**外轮廓**（两盖圆投影的凸包，正交下圆柱剪影 = 两盖圆的 Minkowski 和；
    ///   并集在两圆相交处有凹角、描边出锯齿，所以用凸包）+ **边框**（可见盖面的
    ///   innerRing / surface 内缩圆）—— 基础档；
    /// - L2：+ rim 圆 + mark 裁剪圆；
    /// - L3：+ 前后盖**完整椭圆**（厚度结构线，剪影内部的两圈）；
    /// - L4：+ **侧壁经线**（可见面板沿厚度方向的棱线，剔除口径同 `drawSidewall`）—— 最高档。
    /// 线宽全走基准 `outlineWidth`（1…10 px）：hull 1.5×、innerRing/rim 1×、surface/L3 0.6×、
    /// 裁剪圆 0.5×、经线 0.5×，最后统一乘 sizeScale，并钳到
    /// `CoinMetrics.minOutlineWidth`（0.2pt，防小尺寸掉进亚像素不可见）。
    /// **色相全部同源**（都取 `material.faceBase`，随 Coin Color 走），层级靠 alpha 区分：
    /// hull/边框/rim 1.0、L3 椭圆 0.8、L2 裁剪圆 0.7、**L4 经线 0.7、L5 扫掠线 0.7**
    /// （末两者 2026-09-12 用户指定由 0.5/0.6 提到 0.7——细线叠加亚像素抗锯齿后
    /// 有效墨量 ≈ alpha × 像素覆盖率，0.5 会显得像另一个颜色）。
    /// mark 填充实色所有级别都画（**先填后描**：线压在填充上，裁剪圆描边才不会被
    /// 恰好落在其上的填充盖掉半边）。
    private func drawOutline(_ ctx: CGContext, frame: CoinFrame,
                             pose: (rotation: Double, pitch: Double)) {
        let half = size / 2
        let level = outlineLevel
        let w = outlineWidth
        let ink = material.faceBase.cgColor()
        let frontVisible = frame.capIsVisible(front: true)
        let cap = frame.capTransform(front: frontVisible)
        func stroke(_ path: CGPath, _ width: Double, alpha: Double = 1) {
            ctx.addPath(path)
            ctx.setStrokeColor(material.faceBase.cgColor(alpha: alpha))
            // 钳到下限：小尺寸硬币的细线（0.4×/0.5×/0.6×）否则会掉到亚像素不可见
            ctx.setLineWidth(max(width * w * sizeScale, CoinMetrics.minOutlineWidth))
            ctx.strokePath()
        }

        // mark 填充（所有级别）：贴可见盖面平面，吃裁剪圆与 contentFit，
        // 几何口径与 `drawMark` 同源（solids + base 映射 + 裁剪），不挤出不叠阴影
        let art = logoArt
        if !art.isEmpty {
            let total = logoScale * sizeScale * logoContentFit
            let center = Double(CoinSVG.box) / 2
            let base = CGAffineTransform(translationX: -center, y: -center)
                .concatenating(CGAffineTransform(scaleX: total, y: total))
                .concatenating(cap)
            let clipRadius = CoinMetrics.markClipRadius * sizeScale
            ctx.saveGState()
            ctx.addPath(CoinMath.circlePath(radius: clipRadius, transform: cap))
            ctx.clip()
            ctx.setFillColor(ink)
            if logoInverted {
                // 反色：裁剪圆 + logo 各子路径**一次 even-odd 填充** → logo 变透明、
                // 其余变实心。even-odd 只看交叠次数，所以 logo 自己的镂空洞（内圈）
                // 计数变奇 → 被填实，正好是正色版的负形。
                ctx.addPath(CoinMath.circlePath(radius: clipRadius, transform: cap))
                for solid in art.solids(scale: total) {
                    var mapped = base
                    guard let path = solid.path.copy(using: &mapped) else { continue }
                    ctx.addPath(path)
                }
                ctx.fillPath(using: .evenOdd)
            } else {
                for solid in art.solids(scale: total) {
                    var mapped = base
                    guard let path = solid.path.copy(using: &mapped) else { continue }
                    ctx.addPath(path)
                    ctx.fillPath(using: solid.evenOdd ? .evenOdd : .winding)
                }
            }
            ctx.restoreGState()
        }

        // ① 外轮廓（凸包描边，所有级别）
        let front = frame.capTransform(front: true)
        let c1 = frame.project(CoinVec(x: 0, y: 0, z: thickness / 2))
        let c2 = frame.project(CoinVec(x: 0, y: 0, z: -thickness / 2))
        stroke(Self.capsuleHullPath(centers: [c1, c2], linear: front, radius: half), 1.5)

        // ② 边框（L1+）：可见盖面的两层内缩圆
        stroke(CoinMath.circlePath(radius: half - CoinMetrics.innerRingInset * sizeScale,
                                   transform: cap), 1.0)
        stroke(CoinMath.circlePath(radius: half - CoinMetrics.surfaceInset * sizeScale,
                                   transform: cap), 0.6)

        // L2+：rim 圆 + mark 裁剪圆
        if level >= 2 {
            stroke(CoinMath.circlePath(radius: half - CoinMetrics.rimInset * sizeScale,
                                       transform: cap), 1.0)
            stroke(CoinMath.circlePath(radius: CoinMetrics.markClipRadius * sizeScale,
                                       transform: cap), 0.5, alpha: 0.7)
        }

        // L3+：前后盖完整椭圆（厚度结构线；剪影内部的两圈）
        if level >= 3 {
            for center in [c1, c2] {
                let t = CGAffineTransform(a: front.a, b: front.b, c: front.c, d: front.d,
                                          tx: center.x, ty: center.y)
                stroke(CoinMath.circlePath(radius: half, transform: t), 0.6, alpha: 0.8)
            }
        }

        // L4+：侧壁经线 —— 每块可见面板沿厚度方向的那条棱（corners[0]→corners[3]）
        if level >= 4 {
            ctx.setLineWidth(max(0.5 * w * sizeScale, CoinMetrics.minOutlineWidth))
            ctx.setStrokeColor(material.faceBase.cgColor(alpha: 0.7))
            for index in 0..<geometry.segments {
                guard frame.transform(geometry.normals[index]).z > 0 else { continue }
                let corners = geometry.corners[index]
                let a = frame.project(corners[0]), b = frame.project(corners[3])
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
            }
        }

    }

    /// 「圆片沿轴向扫掠」的屏幕剪影 = 两组椭圆采样点的**凸包**（Andrew monotone chain）。
    /// 椭圆形状对两个盖是同一套线性部分（盖面平行，投影仿射只差平移）。
    private static func capsuleHullPath(centers: [CGPoint], linear: CGAffineTransform,
                                        radius: Double) -> CGPath {
        var pts: [CGPoint] = []
        let n = 96
        pts.reserveCapacity(centers.count * n)
        for center in centers {
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                let x = CGFloat(cos(a) * radius), y = CGFloat(sin(a) * radius)
                pts.append(CGPoint(x: center.x + x * linear.a + y * linear.c,
                                   y: center.y + x * linear.b + y * linear.d))
            }
        }
        let sorted = pts.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        let hull = lower.dropLast() + upper.dropLast()
        let path = CGMutablePath()
        guard let first = hull.first else { return path }
        path.move(to: first)
        for p in hull.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    // MARK: 侧壁（材质渲染）

    private func drawSidewall(_ ctx: CGContext, frame: CoinFrame, edgeShade: Double) {
        // 背向面板直接剔除（CSS: backface-visibility: hidden），其余按深度从远到近画
        var visible: [(depth: Double, index: Int, corners: [CGPoint],
                       axis: (CGPoint, CGPoint), strength: Double)] = []
        for index in 0..<geometry.segments {
            guard frame.transform(geometry.normals[index]).z > 0 else { continue }
            var depth = 0.0
            var projectedCorners: [CGPoint] = []
            projectedCorners.reserveCapacity(4)
            for corner in geometry.corners[index] {
                let rotated = frame.transform(corner)
                depth += rotated.z
                projectedCorners.append(CGPoint(x: frame.center.x + rotated.x,
                                                y: frame.center.y + rotated.y))
            }
            visible.append((depth / 4, index, projectedCorners,
                            (frame.project(geometry.axes[index].0),
                             frame.project(geometry.axes[index].1)),
                            geometry.fieldStrength[index]))
        }
        visible.sort { $0.depth < $1.depth }

        for item in visible {
            // --mintform-slice-color：reeded 时每 accentEvery 块换一次 ridge 色（data-band
            // =alternate），uniform / smooth 取消交替 → 整圈恒用 edge-primary
            let every = edgeFinish.accentEvery
            let alternate = every > 0 && (item.index + 1) % every == 0
            let ridge = alternate ? material.edgeAccent : material.edgeBase
            // --mintform-face-color = mix(slice-color, --mintform-material-shadow-raw, edgeShade)
            // （注意用**原始** shadow，不是面 shading 派生过的那支）
            let faceColor = CoinRGB.mix(ridge, material.faceShadow, edgeShade)

            let path = CGMutablePath()
            path.addLines(between: item.corners)
            path.closeSubpath()

            if edgeFinish == .smooth {
                // data-finish="smooth"：整条 background 退化成单色（只剩材质色 +
                // ridge-field 叠层），每块面板自己的横向高光被去掉 → 读成一整块连续材质
                paint(ctx, path: path, color: faceColor.cgColor())
            } else {
                // linear-gradient(90deg, mix(face,#000 12%), face 32% 68%, mix(face,#fff 10%))
                let stops = [CoinStop(CoinRGB.mix(faceColor, .black, 0.12), at: 0),
                             CoinStop(faceColor, at: 0.32),
                             CoinStop(faceColor, at: 0.68),
                             CoinStop(CoinRGB.mix(faceColor, .white, 0.10), at: 1)]
                guard let gradient = CoinMath.linearGradient(angle: 90, boxSide: geometry.panelWidth,
                                                             transform: .identity, stops: stops) else { continue }
                let projected = CoinGradient(gradient: gradient.gradient, start: item.axis.0,
                                             end: item.axis.1)
                paint(ctx, path: path, gradient: projected)
            }
            // lowerField：按环角强度把紫色以 color 混合模式压上去（background-blend-mode: color）
            if item.strength > 0.001 {
                paint(ctx, path: path, color: material.field.cgColor(alpha: item.strength), blend: .color)
            }
        }
    }

    // MARK: 盖面

    private func drawCap(_ ctx: CGContext, frame: CoinFrame, front: Bool,
                         tokens: (base: CoinRGB, mid: CoinRGB, shadow: CoinRGB,
                                  highlight: CoinRGB, depth: CoinRGB),
                         pose: (rotation: Double, pitch: Double)) {
        let transform = frame.capTransform(front: front)
        let half = size / 2
        // 随尺寸缩放的三层内缩（--mintform-*-inset 都乘 sizeScale）
        let rimRadius = half - CoinMetrics.rimInset * sizeScale
        let ringRadius = half - CoinMetrics.innerRingInset * sizeScale
        let surfaceRadius = half - CoinMetrics.surfaceInset * sizeScale
        func disc(_ radius: Double) -> CGPath {
            CoinMath.circlePath(radius: radius, transform: transform)
        }
        func capGradient(_ radius: Double, _ angle: Double, _ stops: [CoinStop]) -> CoinGradient? {
            CoinMath.linearGradient(angle: angle, boxSide: radius * 2,
                                    transform: transform, stops: stops)
        }
        let sixStop = { (t: (base: CoinRGB, mid: CoinRGB, shadow: CoinRGB,
                             highlight: CoinRGB, depth: CoinRGB)) -> [CoinStop] in
            [CoinStop(t.shadow, at: 0), CoinStop(t.base, at: 0.2),
             CoinStop(t.highlight, at: 0.4), CoinStop(t.highlight, at: 0.6),
             CoinStop(t.base, at: 0.8), CoinStop(t.shadow, at: 1)]
        }

        // ① outer：−60deg 六停
        if let gradient = capGradient(half, -60, sixStop(tokens)) {
            paint(ctx, path: disc(half), gradient: gradient)
        }
        // ② rim：+60deg 六停
        if let gradient = capGradient(rimRadius, 60, sixStop(tokens)) {
            paint(ctx, path: disc(rimRadius), gradient: gradient)
        }
        // ③ innerRing：+60deg 六停 + 20% 黑
        let ringPath = disc(ringRadius)
        if let gradient = capGradient(ringRadius, 60, sixStop(tokens)) {
            paint(ctx, path: ringPath, gradient: gradient)
        }
        paint(ctx, path: ringPath, color: CoinRGB.black.cgColor(alpha: 0.2))
        // ④ surface：自上而下 highlight→base→depth，再叠三圈 inset 阴影（环遮蔽 + 硬边 + 模糊）
        let surfacePath = disc(surfaceRadius)
        if let gradient = capGradient(surfaceRadius, 180,
                                      [CoinStop(tokens.highlight, at: 0),
                                       CoinStop(tokens.base, at: 0.5),
                                       CoinStop(tokens.depth, at: 1)]) {
            paint(ctx, path: surfacePath, gradient: gradient)
        }
        // ⑤ mark：**插在 ④ 与后面的阴影 / lowerField 之间** ——
        //    这是「mark 与币融为一体」的关键：mark 与盖面共用同一遍「面渐变 → inset 阴影 →
        //    色场」着色，不存在第二次叠色，也不存在某一层被 mark 盖掉。
        //    ⚠️ 别把 mark 挪到 ⑥ 之后（曾经如此）：那样它必须自己重演前面三层，
        //    结果是色场叠两次（mark 比周围更重色）＋ inset 阴影被抹掉（圆边一道缺口）。
        drawMark(ctx, transform: transform, disc: disc, surfaceRadius: surfaceRadius,
                 tokens: tokens, pose: pose, front: front)
        // ⑤b 环形环境遮蔽（**与朝向无关**）：参考实现正面时两项阴影都退化成 `inset 0 0`，
        //    盘面因此完全没有阴影；这里补一圈「自 radius−w 渐深到 radius 满值」的环。
        //    用 inset 原语实现：圆心内缩 w/2、blur 取 w/2 → 六段环带恰好铺满 [radius−w, radius]，
        //    最外那道满值。⚠️ 排在下面两道**方向性**阴影之前，让硬边月牙压在它上面。
        let rimShadow = CoinMetrics.surfaceRimShadow * sizeScale
        CoinMath.fillInsetShadow(ctx, clip: surfacePath, transform: transform,
                                 circleCenter: .zero, radius: surfaceRadius - rimShadow / 2,
                                 blur: rimShadow / 2,
                                 color: CoinRGB.black.cgColor(alpha: CoinMetrics.surfaceRimShadowAlpha))
        // CSS: 前盖 `inset calc(shadow-x × −2) 0 <色>`，后盖为 ×+2（后盖局部 x 是镜像的）；
        // shadow-x = 4·normal.x·sizeScale、第二道 blur = 4px·sizeScale —— 都随尺寸缩放
        let offsetX = (front ? -2 : 2) * 4 * sizeScale
            * CoinMath.projectedNormal(yaw: pose.rotation, pitch: pose.pitch).x
        CoinMath.fillInsetShadow(ctx, clip: surfacePath, transform: transform,
                                 circleCenter: CGPoint(x: offsetX, y: 0), radius: surfaceRadius,
                                 blur: 0, color: tokens.shadow.cgColor())
        CoinMath.fillInsetShadow(ctx, clip: surfacePath, transform: transform,
                                 circleCenter: CGPoint(x: offsetX, y: 0), radius: surfaceRadius,
                                 blur: CoinMetrics.shadowBlur * sizeScale,
                                 color: CoinRGB.black.cgColor(alpha: 0.8))
        // ⑥ lowerField：整盖自上而下透明→紫，color 混合（mix-blend-mode: color）
        if material.fieldTransparentAt < 100 {
            if let gradient = capGradient(half, 180,
                                          [CoinStop(material.field, alpha: 0, at: CGFloat(material.fieldTransparentAt / 100)),
                                           CoinStop(material.field, alpha: 1, at: CGFloat(material.fieldOpaqueAt / 100))]) {
                paint(ctx, path: disc(half), gradient: gradient, blend: .color)
            }
        }
    }

    // MARK: mark（logo）

    /// ⑤ mark：logo 轮廓（160 盒坐标）→「以盖心为原点」→ 乘 logoScale×sizeScale×基准缩放 → 贴到
    /// 盖面，裁剪在 circle(61.5·sizeScale) 内。调用点在盖面 ④ 与 ⑤⑥（inset 阴影 / lowerField）
    /// **之间** —— mark 因此和盖面吃同一遍着色，见 `paintFaceMaterial`。
    /// ⚠️ 复合顺序用 `.concatenating`（前一个先作用在点上）；Swift 的 `.scaledBy` 语义相反，
    /// 混用必错。描边宽度不随 CGPath 变换走，手动乘总缩放。
    /// ⚠️ 按 viewBox 撑满 160 盒的 logo（真实上传件大多如此）会冲出 r=61.5 的裁剪圆 ——
    /// 上传件被切掉一大半看起来就是「画不出来」。所以总缩放里先乘 `logoContentFit`
    /// 把内容收进圆内（只缩不放，预设与留白正常的 viewBox 不受影响）。
    /// Logo Size 滑杆再乘一次 → 100% = 刚好铺满圆；>100% 是用户主动放大，超出部分由裁剪圆切住。
    ///
    /// 立体化（`markDepth > 0`）：把平面轮廓沿**盖面法线**挤出成实体，mark 从此是硬币的一部分。
    ///
    /// ⚠️ 正交投影下「沿法线走 d」在屏幕上是**常数位移** `(normal.x, normal.y) · d`
    /// （`projectedNormal` 就是 rotateY·rotateX 作用在 (0,0,1) 上的结果），跟图形在哪没关系 ——
    /// 所以实体 = 平面图形沿该向量做 **Minkowski 扫掠**：叠 N 份平移副本取并集 = 侧壁，
    /// 最后把终点那份（顶面）重上一次色压住。步长取 0.5px 时并集与连续扫掠无可见差别。
    /// 正面朝观察者时位移为 0 → 自动退回平面观感，不需要特判；后盖朝外是 −z，故位移取负。
    ///
    /// 上色：**mark 没有自己的颜色**。顶面与侧壁都走盖面那支面渐变，侧壁只是沿挤出方向**浅压暗**
    /// （`markWallShadeTop` → `markWallShadeEdge`）—— mark 因此读起来是硬币本体雕出来的浮雕，
    /// 而不是嵌进去的另一块料。⚠️ 侧壁**不承担轮廓**：它的宽度 = 挤出位移（几何），压深了就是
    /// 一条随厚度变宽的暗带；轮廓由 ① 那圈接触阴影定义，宽度与厚度无关。
    /// ⚠️ 渐变端点跟着 `transform`（盖面）走、**不跟** mark 的位移走：抬起来的那一块取到的
    /// 仍是它落点处的材质，所以顶面与盖面逐像素同色（`shade = 0` 时差 0）。
    ///
    /// 边界阴影（`markShadowSpread` / `markShadowOpacity`）：侧壁只在**斜看**时存在（正面位移为 0 → 无侧壁），所以纯正面的
    /// 立体感全压在轮廓外那一圈接触阴影上 —— 与币的凸起边缘同口径（落影在低的那一侧，
    /// 币落在凹陷的盘面内侧、mark 落在它压着的币面外侧）。这条阴影**任何朝向都在**，
    /// 挂在**整个身体的扫掠并集**上（`sweepOutline`），与盖面的环形环境遮蔽是同一角色的两个位置。
    private func drawMark(_ ctx: CGContext, transform: CGAffineTransform,
                          disc: (Double) -> CGPath, surfaceRadius: Double,
                          tokens: (base: CoinRGB, mid: CoinRGB, shadow: CoinRGB,
                                   highlight: CoinRGB, depth: CoinRGB),
                          pose: (rotation: Double, pitch: Double), front: Bool) {
        let art = logoArt
        guard !art.isEmpty else { return }
        let total = logoScale * sizeScale * logoContentFit
        let center = Double(CoinSVG.box) / 2
        let base = CGAffineTransform(translationX: -center, y: -center)
            .concatenating(CGAffineTransform(scaleX: total, y: total))
            .concatenating(transform)

        let normal = CoinMath.projectedNormal(yaw: pose.rotation, pitch: pose.pitch)
        let depth = markDepth * sizeScale * (front ? 1 : -1)
        let dx = normal.x * depth, dy = normal.y * depth
        let reach = hypot(dx, dy)
        let extruded = reach > 0.01
        let steps = max(1, min(CoinMetrics.markExtrudeStepLimit,
                               Int((reach / CoinMetrics.markExtrudeStep).rounded(.up))))

        ctx.saveGState()
        ctx.addPath(disc(CoinMetrics.markClipRadius * sizeScale))
        ctx.clip()
        // 一个实体拆成两个面：`base` = 平面轮廓（= 接触阴影的落点、侧壁起点）、
        // `top` = 挤出终点那份（= 顶面）。填充规则两个面共用。
        // ⚠️ 整批实体分**三遍**画（边界阴影 → 侧壁 → 顶面），不是逐个实体一遍画到底：
        //    边界阴影必须整体排在所有顶面之前，否则先画完的实体顶面会被后画实体的阴影糊掉。
        var pieces: [(base: CGPath, top: CGPath, rule: CGPathFillRule)] = []
        if logoInverted {
            // 反色：把「裁剪圆 − logo」合成**一条** even-odd 路径，当单个实体交给同一套
            // 挤出 / 侧壁 / 顶面 / 边界阴影管线 —— 观感是「一块圆牌把 logo 镂空」的负形浮雕。
            // 裁剪圆与 solids 同在硬币局部坐标（base 末端就是 transform），所以圆用 disc 建。
            let combined = CGMutablePath()
            combined.addPath(disc(CoinMetrics.markClipRadius * sizeScale))
            for solid in art.solids(scale: total) {
                var mapped = base
                guard let path = solid.path.copy(using: &mapped) else { continue }
                combined.addPath(path)
            }
            var topPath: CGPath = combined
            if extruded {
                var top = CGAffineTransform(translationX: dx, y: dy)
                topPath = combined.copy(using: &top) ?? combined
            }
            pieces.append((combined, topPath, .evenOdd))
        } else {
            for solid in art.solids(scale: total) {
                var mapped = base
                guard let path = solid.path.copy(using: &mapped) else { continue }
                var topPath = path
                if extruded {
                    var top = CGAffineTransform(translationX: dx, y: dy)
                    topPath = path.copy(using: &top) ?? path
                }
                pieces.append((path, topPath, solid.evenOdd ? .evenOdd : .winding))
            }
        }
        // ① 边界阴影（**与朝向无关**，见 `markShadowSpread`）：以轮廓为中心画的模糊副本 ——
        //    内侧那一半随后被侧壁 / 顶面盖住，留下的正好是轮廓**外侧**那圈接触阴影。
        //    ⚠️ 投射体取哪种几何见 `CoinMetrics.markRimShadowCaster`：默认 **底面轮廓**
        //    （`.footprint`），与 Logo depth 完全无关 —— 投影宽度/黑度恒等于平贴时的样子；
        //    另一档 `.sweptBody` 挂挤出体的扫掠并集（底面 ∪ 沿途副本 ∪ 顶面），四周都有影，
        //    但挤出体一鼓出去，投影就跟着变宽、且把 logo 内部的缝隙越挤越黑（实测见该常量注释）。
        //    ⚠️ 并集必须**一次填充**（一条路径）：逐份填会把模糊影叠 N 次（远端糊成实心黑）。
        //    ⚠️ 顺序不能挪到顶面之后：那样内侧那一半会留在顶面上（浮雕边缘糊一圈黑）。
        //    ⚠️ CG 的 `setShadow` 在形状边界处恰好只落地一半 alpha（高斯台阶的半高），
        //    所以色值乘 2 才是「轮廓处满值」的每遍落点（α 由 Shadow opacity 反解，见下）。
        //    ⚠️ 单遍峰值封顶 0.5 —— 再往下加深靠同一轮廓叠画多遍（`markRimShadowPasses`）。
        //    ⚠️⚠️ 两个必须照做的细节：
        //      a. 模糊半径**不随 CTM 缩放**（实测：CTM 放大 2 倍，半衰距离纹丝不动），
        //         而本视图是在 `renderCoin` 那个带 backing scale 的 CTM 下画的 —— 必须手动补
        //         缩放因子，否则弹窗里（2×）这圈阴影只有设计值的一半宽。
        //      b. 必须画进**透明图层**：`setShadow` 只能连「不透明填充 + 它自己的影」一起落地，
        //         想让影单独落地就得先填一块不透明的黑 —— 那块黑会顺着轮廓的抗锯齿边带漏出来
        //         （实测沿对角边一圈 0.5×面色的暗边）。放进图层后用 `.clear` 把填充抠掉，
        //         最终只有影参与合成，边带上只剩「影自己的半覆盖」，与自然抗锯齿一致。
        if markShadowSpread > 0, markShadowOpacity > 0 {
            let deviceScale = max(0.01, hypot(ctx.ctm.a, ctx.ctm.b))
            // 「Logo depth → 投影更宽 / 更黑」这条关联（用户 2026-09-11 指定，见 CoinMetrics 两个 gain）：
            // t = Logo 厚度滑杆的归一化值，宽度与每遍落点各乘 (1 + gain·t)。放在**几何之前**算，
            // 所以任何朝向（含正面挤出位移 = 0）都成立，不被「影贴谁走」那档影响。
            let depthT = min(max(markDepth / CoinMetrics.markDepthRange.upperBound, 0), 1)
            let shadowBlur = markShadowSpread * sizeScale * deviceScale
                * (1 + CoinMetrics.markShadowDepthWidthGain * depthT)
            // 设置的可见峰值（轮廓处、N 遍合成后）反解出每遍的落点 alpha：
            // N 遍 source-over 合成 1−(1−b)^N = peak → b = 1−(1−peak)^(1/N)；
            // ×2 是 setShadow 边界半高补偿（色 α≤1 夹取 → 单遍可见峰值封顶 0.5）。
            // ⚠️ N **随峰值自适应**（滑杆 0…100% → 2…6 遍，见 markRimShadowPasses(forPeak:)）：
            // 峰值 ≤75% 时 N=2、算式与旧版逐位相同；再往上靠加遍数把 1−0.5^N 的天花板抬起来。
            // 峰值先夹到 markShadowOpacityCeiling，否则 100% 会反解出 b = 1（色值 ×2 = 2 > 1）
            // 被夹成 1，顶端一截滑杆推了没反应。
            let peak = min(markShadowOpacity, CoinMetrics.markShadowOpacityCeiling)
            let passes = CoinMetrics.markRimShadowPasses(forPeak: peak)
            let perPass = 1 - pow(1 - peak, 1 / Double(passes))
            let shadowAlpha = min(1, perPass * 2
                * (1 + CoinMetrics.markShadowDepthAlphaGain * depthT))
            // ⚠️ 并集只算一次、各遍共用：`CGPath.union` 不便宜（每帧都跑），算两遍等于白付一倍。
            let outlines = pieces.map { piece -> (path: CGPath, rule: CGPathFillRule) in
                switch CoinMetrics.markRimShadowCaster {
                case .footprint:
                    return (piece.base, piece.rule)
                case .sweptBody:
                    return sweepOutline(piece.base, rule: piece.rule, dx: dx, dy: dy, reach: reach)
                }
            }
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: shadowBlur,
                          color: CoinRGB.black.cgColor(alpha: shadowAlpha))
            ctx.setFillColor(CoinRGB.black.cgColor())
            // 同一轮廓叠画 `passes` 遍：影逐遍 source-over 合成 1−(1−a)^N，
            // 突破单遍 0.5 的可见峰值上限 —— 只加深，模糊半径与轮廓形态不变。
            for _ in 0..<passes {
                for outline in outlines {
                    ctx.addPath(outline.path)
                    ctx.fillPath(using: outline.rule)
                }
            }
            ctx.restoreGState()
            ctx.setBlendMode(.clear)
            for outline in outlines {
                ctx.addPath(outline.path)
                ctx.fillPath(using: outline.rule)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        // ② 侧壁
        if extruded {
            for piece in pieces {
                // 同一个面材质，明暗沿挤出方向**渐变** —— 顶面边缘一档、外缘稍深，
                // 与币面 inset 阴影「越靠边界越深」同一条口径；⚠️ 只是**浅压暗**：宽度 = 挤出位移，
                // 压深了就和边界阴影连成一条随厚度变宽的暗带（见 `markWallShadeEdge`）。
                // ⚠️ 逐份**不透明**叠画：后画的副本盖住先画的 → 结果仍等于并集
                //    （nonzero 不必再合并成一条路径），而每个像素取到的明暗是「最后一份含它的副本」
                //    —— 恰好就是它沿挤出方向的深度：外缘那份最后被覆盖，所以外缘最深。
                // ⚠️ evenodd 同样只能逐份填（多份并进一条路径会奇偶相消 → 侧壁被掏洞）。
                for step in 0..<steps {
                    let f = Double(step) / Double(steps)
                    var shifted = CGAffineTransform(translationX: dx * CGFloat(f), y: dy * CGFloat(f))
                    guard let copy = piece.base.copy(using: &shifted) else { continue }
                    paintFaceMaterial(ctx, clip: copy, rule: piece.rule, surfaceRadius: surfaceRadius,
                                      transform: transform, tokens: tokens,
                                      shade: CoinMetrics.markWallShadeTop
                                          + (CoinMetrics.markWallShadeEdge - CoinMetrics.markWallShadeTop)
                                          * (1 - f))
                }
            }
        }
        // ③ 顶面（= 挤出终点那份）：同一支面渐变、不压暗 → 与盖面逐像素同色
        for piece in pieces {
            paintFaceMaterial(ctx, clip: piece.top, rule: piece.rule, surfaceRadius: surfaceRadius,
                              transform: transform, tokens: tokens, shade: 0)
        }
        ctx.restoreGState()
    }

    /// 浮雕在屏幕上的**轮廓** = Minkowski 扫掠的并集（底面 ∪ 沿途副本 ∪ 顶面）。
    /// 只喂给边界阴影（`markShadowSpread`）：那圈影要贴着**整个身体**的边界，逐份填会叠影、逐份
    /// 合并又算不出边界，所以走 `CGPath.union`。侧壁 / 顶面照旧逐份画（那是精确扫掠，份数不够会露棱面）。
    /// 副本份数按「间距 ≤ `sweepOutlineGap`」取，与侧壁的 24 份无关；⚠️ `CGPath.union` 需要
    /// macOS 13+，且 evenodd 的形状（带洞的 logo）必须把 `.evenOdd` 传进去 —— 否则洞会被
    /// winding 当成实心并进来（表现为洞里糊出一圈影）。并集结果自带 nonzero 语义，填 `piece.rule` 会错。
    private func sweepOutline(_ base: CGPath, rule: CGPathFillRule,
                              dx: CGFloat, dy: CGFloat, reach: Double)
        -> (path: CGPath, rule: CGPathFillRule) {
        guard reach > 0.01 else { return (base, rule) }       // 正面：位移为 0，并集 = 底面
        let n = max(1, Int((reach / CoinMetrics.sweepOutlineGap).rounded(.up)))
        var merged = base
        for i in 1...n {
            let f = CGFloat(i) / CGFloat(n)
            var shift = CGAffineTransform(translationX: dx * f, y: dy * f)
            guard let copy = base.copy(using: &shift) else { continue }
            merged = merged.union(copy, using: rule)
        }
        // ⚠️ 每一步都得用 `rule`（原始填充规则），且结果按 `.winding` 填 —— 实测出来的唯一安全组合：
        //    试过分治合并（两两并、再并结果）且第二层改按 `.winding` 解释，evenodd 环的**洞被填掉**
        //    （并集 vs 密扫多出 432 px）。⚠️ 分治也不更快（同款 logo depth=12：9.9 vs 9.3 ms/帧）。
        return (merged, .winding)
    }

    /// 面着色 —— 盖面 ④ 与 mark 共用的**唯一**出处：盖面那支 surface 三停渐变（180°）
    /// 按 `transform`（盖面）投影，所以从哪个形状裁出来都取到同一片材质 ——
    /// 这正是「mark 与币融为一体」的算法定义：`shade = 0` 时逐像素等于盖面。
    /// `shade` = 往 `tokens.shadow` 里压的档位：0 = 顶面，`markWallShadeTop`…`markWallShadeEdge` = mark 侧壁
    /// （沿挤出方向渐变，见 `drawMark`）。
    /// `rule` 是裁剪用的填充规则 —— evenodd 轮廓必须传 `.evenOdd`，否则洞会被 winding 一并填上。
    /// ⚠️ 这里**只画面渐变**：inset 阴影与 lowerField 是盖面 ⑤⑥ 的事，mark 排在它们之前
    /// （见 drawCap 的调用位置），自然一并吃到，不需要也不该在这里重放。
    private func paintFaceMaterial(_ ctx: CGContext, clip: CGPath, rule: CGPathFillRule = .winding,
                                   surfaceRadius: Double,
                                   transform: CGAffineTransform,
                                   tokens: (base: CoinRGB, mid: CoinRGB, shadow: CoinRGB,
                                            highlight: CoinRGB, depth: CoinRGB),
                                   shade: Double) {
        func shaded(_ color: CoinRGB) -> CoinRGB {
            shade <= 0 ? color : CoinRGB.mix(color, tokens.shadow, shade)
        }
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip(using: rule)
        if let gradient = CoinMath.linearGradient(
            angle: 180, boxSide: surfaceRadius * 2, transform: transform,
            stops: [CoinStop(shaded(tokens.highlight), at: 0),
                    CoinStop(shaded(tokens.base), at: 0.5),
                    CoinStop(shaded(tokens.depth), at: 1)]) {
            ctx.drawLinearGradient(gradient.gradient, start: gradient.start, end: gradient.end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    // MARK: 绘制原语（裁剪 + 纯色/渐变填充）

    private func paint(_ ctx: CGContext, path: CGPath, gradient: CoinGradient,
                       blend: CGBlendMode = .normal) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if blend != .normal { ctx.setBlendMode(blend) }
        ctx.drawLinearGradient(gradient.gradient, start: gradient.start, end: gradient.end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// ⚠️ 纯色填充**不能**走 clip：`CGContext.clip()` 会把当前路径吃掉（clip 完当前路径即空），
    /// 之后再 `fillPath()` 是往空路径上填 —— 一个像素都不落。渐变那支没事，因为
    /// `drawLinearGradient` 是画进裁剪区、不依赖当前路径。曾经这里就是这个写法，
    /// 导致 smooth 的侧壁、侧壁 lowerField、盖面 innerRing 的 20% 黑全部静默不画
    /// （表现为「选了 smooth 厚度变 0」）。直接填同一条路径，效果与 clip 后填等价。
    private func paint(_ ctx: CGContext, path: CGPath, color: CGColor,
                       blend: CGBlendMode = .normal) {
        ctx.saveGState()
        if blend != .normal { ctx.setBlendMode(blend) }
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - 参数落盘（自动保存：每次变更即时整份写盘，实时同步靠通知）

/// 弹窗参数变更时发出的通知（CoinDemoPanelView 的每个 apply 发出，主线程同步）。
/// 通知带**内存快照**（CoinSettingsBox）—— 主面板内嵌小硬币靠它实时重灌；
/// 落盘已由 notifyLiveChange 先行完成，磁盘与内存恒一致。
extension Notification.Name {
    static let coinSettingsDidChange = Notification.Name("coinSettingsDidChange")
}

/// CoinSettings 的引用盒子（struct 进不了通知的 object 槽）
final class CoinSettingsBox {
    let value: CoinSettings
    init(_ value: CoinSettings) { self.value = value }
}

/// 弹窗整页参数的落盘快照：一个控件一条（key 见 `UDKey.coin*`；Logo 行占两条 = 原文 + 文件名）。
/// **每次变更即时整份写盘**（2026-09-13 起自动保存）；开面板从磁盘还原，重启 App
/// 也按这份还原。取值域与控件同域
/// （size / thickness 用 px、Logo size 用百分数）—— 还原时先夹回滑杆范围，
/// 将来范围收窄了老值也不会把滑杆顶歪。
struct CoinSettings {
    /// mintform preset（GHO = 无色场 / sGHO = 启用色场），Control 区第二行的拉下按钮
    var preset: CoinPreset
    /// 外观档（Default 材质渲染 / Outline 线稿），Control 区第一行「Style」的拉下按钮
    var appearance: CoinAppearance
    var materialColor: CoinRGB
    /// lowerField 色场：硬币盖面下方那层「透明渐显」的颜色（独立 prop，不随 Coin color 派生）
    var fieldColor: CoinRGB
    var size: Double
    /// 主面板 Token 板块内嵌硬币的直径（pt，Control 区「Panel coin size」）；
    /// 只影响内嵌那枚，不影响弹窗预览币（后者跟 `size` 走）
    var panelSize: Double
    var thickness: Double
    var logoScalePercent: Double
    /// logo 厚度（px/160 盒，0 = 平贴）—— mark 沿盖面法线挤出的深度
    var markDepth: Double
    /// mark 边界阴影的可见峰值不透明度（**百分数** 0…100，轮廓处 N 遍合成后；渲染封顶见
    /// `CoinMetrics.markShadowOpacityCeiling`）
    var markShadowOpacity: Double
    /// mark 边界阴影的视觉衰减距离（px/160 盒，0…16；0 = 整圈关断）
    var markShadowSpread: Double
    var finish: CoinEdgeFinish
    /// 静止俯仰（度，Motion 区 Resting tilt，-180…180，0 = 正立）
    var restingTilt: Double
    /// 静止朝向（度，Motion 区 Resting rotation，-180…180，出厂 45）
    var restingRotation: Double
    /// 点按自旋圈数（Motion 区 Turns，1…5）
    var turns: Double
    /// Outline 线稿的内部结构层级（Control 区 Outline level，1…5；仅 Outline 外观生效）
    var outlineLevel: Double
    /// Outline 线稿基准线宽（Control 区 Outline width，1…10 px；仅 Outline 外观生效）
    var outlineWidth: Double
    /// Logo 反色（Control 区 Logo 组的原生开关）：把 logo 与其周围互为负形 ——
    /// logo 的实体部分变透明、裁剪圆内其余部分变实心（见 `Coin3DView.logoInverted`）
    var logoInverted: Bool
    /// 上传的 SVG 原文；空 = 用内置 GHO 预设
    var logoSVG: String
    /// 上传的 SVG 文件名（Logo 行里显示）；空 = 内置 GHO 预设
    var logoName: String

    /// 出厂默认（= 参考实现 mintform 的 props 默认值）
    static let initial = CoinSettings(preset: .sgho,
                                      appearance: .default,
                                      materialColor: CoinMaterial.sgho.faceBase,
                                      fieldColor: CoinMaterial.sgho.field,
                                      size: CoinMetrics.defaultSize,
                                      panelSize: CoinMetrics.defaultPanelSize,
                                      thickness: CoinMetrics.defaultThickness,
                                      logoScalePercent: 100,
                                      markDepth: CoinMetrics.defaultMarkDepth,
                                      markShadowOpacity: CoinMetrics.defaultMarkShadowOpacity,
                                      markShadowSpread: CoinMetrics.defaultMarkShadowSpread,
                                      finish: .reeded,
                                      restingTilt: 0,
                                      restingRotation: CoinMetrics.defaultRestingRotation,
                                      turns: 1,
                                      outlineLevel: 1,
                                      outlineWidth: 1,
                                      logoInverted: false,
                                      logoSVG: "",
                                      logoName: "")

    /// Logo 行的说明文案：上传过就报文件名，否则说明用的是内置预设
    var logoCaption: String { logoName.isEmpty ? "内置预设" : logoName }

    /// 还原材质：色值仍是预设那个绿就用**预设**（那套面 token 是手工挑的），
    /// 动过色则走 Coin Color 派生 —— 与拖动色井时同一条路。
    /// lowerField 不参与派生（参考实现里它是独立 prop）：两条路都只取面/边 token，
    /// 色场颜色单独用 `fieldColor` 盖上去；preset = gho 时色场整体关断
    /// （照参考实现 `lowerField: false` 的落法：transparentAt/opaqueAt = 100，渐变全程透明）。
    var material: CoinMaterial {
        var m = materialColor.hex == CoinMaterial.sgho.faceBase.hex
            ? CoinMaterial.sgho : CoinMaterial.derived(from: materialColor)
        if preset == .gho {
            m.fieldTransparentAt = 100
            m.fieldOpaqueAt = 100
        } else {
            m.field = fieldColor
        }
        return m
    }

    /// 还原轮廓：有原文就重新解析（解析不了记日志后退回预设 —— 弹窗必须能打开），
    /// 没有原文就是 GHO 预设。
    var logoArt: CoinLogoArt {
        guard !logoSVG.isEmpty else { return CoinSVG.ghoPreset }
        do {
            return try CoinSVG.parse(logoSVG)
        } catch {
            Logger.log(.layout, "硬币弹窗：保存的 logo SVG 解析失败，退回预设 —— \(error.localizedDescription)")
            return CoinSVG.ghoPreset
        }
    }

    private static func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func load() -> CoinSettings {
        let defaults = UserDefaults.standard
        func double(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return clamped(defaults.double(forKey: key), range)
        }
        return CoinSettings(
            preset: (defaults.object(forKey: UDKey.coinPreset) as? Int)
                .flatMap(CoinPreset.init(rawValue:)) ?? initial.preset,
            appearance: (defaults.object(forKey: UDKey.coinAppearance) as? Int)
                .flatMap(CoinAppearance.init(rawValue:)) ?? initial.appearance,
            materialColor: defaults.string(forKey: UDKey.coinMaterialColor)
                .flatMap(CoinRGB.init(hex:)) ?? initial.materialColor,
            fieldColor: defaults.string(forKey: UDKey.coinFieldColor)
                .flatMap(CoinRGB.init(hex:)) ?? initial.fieldColor,
            size: double(UDKey.coinSize, CoinMetrics.sizeRange, initial.size),
            panelSize: double(UDKey.coinPanelSize, CoinMetrics.panelSizeRange, initial.panelSize),
            thickness: double(UDKey.coinThickness, CoinMetrics.thicknessRange, initial.thickness),
            logoScalePercent: double(UDKey.coinLogoScalePercent, 50...125,
                                     initial.logoScalePercent),
            markDepth: double(UDKey.coinMarkDepth, CoinMetrics.markDepthRange,
                              initial.markDepth),
            markShadowOpacity: double(UDKey.coinMarkShadowOpacity,
                                      CoinMetrics.markShadowOpacityRange,
                                      initial.markShadowOpacity),
            markShadowSpread: double(UDKey.coinMarkShadowSpread,
                                     CoinMetrics.markShadowSpreadRange,
                                     initial.markShadowSpread),
            // 缺省 / 越界都落到 initial.finish（= reeded，rawValue 0，正好是「没写过」的取值）
            finish: CoinEdgeFinish(rawValue: defaults.integer(forKey: UDKey.coinEdgeFinish))
                ?? initial.finish,
            restingTilt: double(UDKey.coinRestingTilt, CoinMetrics.restingTiltRange,
                                initial.restingTilt),
            restingRotation: double(UDKey.coinRestingRotation, CoinMetrics.restingRotationRange,
                                    initial.restingRotation),
            turns: double(UDKey.coinTurns, CoinMetrics.turnsRange, initial.turns),
            outlineLevel: double(UDKey.coinOutlineLevel, CoinMetrics.outlineLevelRange,
                                 initial.outlineLevel),
            outlineWidth: double(UDKey.coinOutlineWidth, CoinMetrics.outlineWidthRange,
                                 initial.outlineWidth),
            // 布尔：没写过就落 initial（false），写过就按写过的（false 也认）
            logoInverted: defaults.object(forKey: UDKey.coinLogoInverted) == nil
                ? initial.logoInverted
                : defaults.bool(forKey: UDKey.coinLogoInverted),
            logoSVG: defaults.string(forKey: UDKey.coinLogoSVG) ?? "",
            logoName: defaults.string(forKey: UDKey.coinLogoSVGName) ?? "")
    }

    /// 把当前内存快照整份写入磁盘（此后重启 / 重开弹窗都按这份还原）。
    /// 自动保存（notifyLiveChange）与弹窗壳显式保存共用；persistDefaults 转发到此。
    /// ⚠️ 不发 coinSettingsDidChange —— 改动过程中的实时同步已由 apply() 发过，
    /// 落盘本身不改变任何值。
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(preset.rawValue, forKey: UDKey.coinPreset)
        defaults.set(appearance.rawValue, forKey: UDKey.coinAppearance)
        defaults.set(materialColor.hex, forKey: UDKey.coinMaterialColor)
        defaults.set(fieldColor.hex, forKey: UDKey.coinFieldColor)
        defaults.set(size, forKey: UDKey.coinSize)
        defaults.set(panelSize, forKey: UDKey.coinPanelSize)
        defaults.set(thickness, forKey: UDKey.coinThickness)
        defaults.set(logoScalePercent, forKey: UDKey.coinLogoScalePercent)
        defaults.set(markDepth, forKey: UDKey.coinMarkDepth)
        defaults.set(markShadowOpacity, forKey: UDKey.coinMarkShadowOpacity)
        defaults.set(markShadowSpread, forKey: UDKey.coinMarkShadowSpread)
        defaults.set(finish.rawValue, forKey: UDKey.coinEdgeFinish)
        defaults.set(restingTilt, forKey: UDKey.coinRestingTilt)
        defaults.set(restingRotation, forKey: UDKey.coinRestingRotation)
        defaults.set(turns, forKey: UDKey.coinTurns)
        defaults.set(outlineLevel, forKey: UDKey.coinOutlineLevel)
        defaults.set(outlineWidth, forKey: UDKey.coinOutlineWidth)
        defaults.set(logoInverted, forKey: UDKey.coinLogoInverted)
        defaults.set(logoSVG, forKey: UDKey.coinLogoSVG)
        defaults.set(logoName, forKey: UDKey.coinLogoSVGName)
    }
}

// MARK: - 参数表单（Control / Edge / Motion 三个区块共用的口径与容器）

/// 表单口径（区块标题 / 行高 / 内缩 / 列宽的唯一出处；Control、Edge、Motion 共用）
enum CoinFormMetrics {
    static let titleH: CGFloat = 17
    static let titleGap: CGFloat = 9
    /// 统一行高：一个参数一行
    static let rowH: CGFloat = 36
    /// 行内左右内缩
    static let padX: CGFloat = 13
    /// 左侧标签列宽
    static let labelW: CGFloat = 92
    /// 右侧数值列宽（滑杆行的「16 px」；也是控件最小宽）
    static let valueW: CGFloat = 72
    /// 标签列与控件之间的间隙
    static let controlGap: CGFloat = 8
}

/// Edge 区的配色 / 圆角 / 分隔线口径（唯一出处）
enum CoinEdgeStyle {
    /// 表单容器圆角（行底不再各自圆角，靠容器裁）
    static let cardRadius: CGFloat = 10
    /// 容器底色：深色 = 白 7%，浅色 = 黑 5%
    static let cardFill = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.07)
                          : NSColor.black.withAlphaComponent(0.05)
    }
    /// 行间发丝分隔线：深色 = 白 10%，浅色 = 黑 8%
    static let separatorFill = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.10)
                          : NSColor.black.withAlphaComponent(0.08)
    }
}

/// 表单容器：一块圆角卡，内部是若干**等高**的参数行，行与行之间一条发丝分隔线。
/// 圆角裁剪交给 layer（`masksToBounds`）—— 于是行底可以整块铺满、不必各自圆角。
/// ⚠️ 底色 / 分隔线一律在 `draw` 里解析：动态 `NSColor` 落到 CALayer 上会定格当时外观，
/// 而这里的圆角半径是常量，挂在 layer 上没有外观问题。
final class CoinFormCardView: NSView {
    /// 分隔线位置（容器坐标系，y 自顶向下）
    var separatorYs: [CGFloat] = [] { didSet { needsDisplay = true } }
    /// 是否铺卡底。弹窗里铺（白 7%）；设置窗口把区块当**普通 Form 行**内嵌时不铺 ——
    /// 外层 Form Section 的卡就是它的框，再铺一层就成了「卡中卡」
    ///（2026-09-13 用户：参数放普通 forms 里，不要嵌套）
    var drawsFill = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CoinEdgeStyle.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if drawsFill {
            CoinEdgeStyle.cardFill.setFill()
            bounds.fill()
        }
        guard !separatorYs.isEmpty else { return }
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        CoinEdgeStyle.separatorFill.setFill()
        for y in separatorYs {
            NSRect(x: CoinFormMetrics.padX, y: y,
                   width: max(bounds.width - CoinFormMetrics.padX * 2, 0),
                   height: hairline).fill()
        }
    }
}

/// 表单行：一个参数占一行，行高由容器统一给（`CoinFormMetrics.rowH`）。
/// 只做**翻转坐标的容器**（`isFlipped` 是逐视图的；行不翻，行内控件就得按 y 向上手算）。
/// 行内容一律交给原生控件，行自身不吃事件、不做 hover ——
/// 于是行内空白处拖拽仍由 `isMovableByWindowBackground` 带走整个弹窗。
class CoinFormRowView: NSView {
    override var isFlipped: Bool { true }
}

/// 「标题 + 表单容器」区块基类：标题、容器框与行框的排版公共，行由子类注册。
/// 行数在 init 定死（容器高 = 行数 × rowH）；控件全原生，没有展开 / 收起，区块高度是定值。
class CoinFormSectionView: NSView {
    override var isFlipped: Bool { true }

    /// 区块标题。弹窗里画在卡上方；设置窗口「分段内嵌」时交给 Form Section header ——
    /// 那时宿主**建 pane 时就要拿到标题字符串**（实例还没建），所以子类把它做成静态常量。
    let sectionTitle: String
    /// 裸模式（设置窗口分段内嵌，2026-09-13 用户「参数放普通 forms 里不要嵌套」）：
    /// 不画标题、不铺卡底 —— 标题与卡片都由外层 Form Section 提供，本区块只是一叠普通行。
    /// 行内容仍落在**行内容区左缘**（= Section 标题左缘）：行容器左右各外扩 `padX`
    /// （见 `relayout`），正好抵消行内那层 `padX`，控件不左不右（离线实测同口径）。
    let bare: Bool

    private let titleLabel: NSTextField
    private let card = CoinFormCardView(frame: .zero)
    /// 子类通过 `addRow(_:)` 注册的行（下标即行号）
    private var rows: [NSView] = []
    /// 裸模式上下留白（与平台表格同口径 6pt）：卡底由 Form 画，这里只是行与卡缘的呼吸
    private static let bareInset: CGFloat = 6

    init(title: String, bare: Bool = false) {
        sectionTitle = title
        self.bare = bare
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        if !bare { addSubview(titleLabel) }
        card.drawsFill = !bare
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addRow(_ row: NSView) {
        rows.append(row)
        card.addSubview(row)
    }

    /// 区块总高 = 标题 + 间距 + 容器（行数 × 统一行高）；裸模式无标题、上下各 6pt
    var preferredHeight: CGFloat {
        let rowsH = CGFloat(rows.count) * CoinFormMetrics.rowH
        return bare
            ? Self.bareInset * 2 + rowsH
            : CoinFormMetrics.titleH + CoinFormMetrics.titleGap + rowsH
    }

    /// 供 SwiftUI 内嵌用（手工 frame 布局的视图不参与自适应，靠 fittingSize 报高）
    override var fittingSize: NSSize {
        NSSize(width: super.fittingSize.width, height: preferredHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        let w = bounds.width
        guard w > 0 else { return }
        let rowsH = CGFloat(rows.count) * CoinFormMetrics.rowH
        // 裸模式：行容器左右各外扩 padX（行内容因此落在行内容区左缘），且从顶部起排（无标题）。
        // 越出的那点透明边不会被看见（卡片本身的圆角裁切也在更外面）。
        let cardX: CGFloat = bare ? -CoinFormMetrics.padX : 0
        let cardW = bare ? w + CoinFormMetrics.padX * 2 : w
        let cardY: CGFloat = bare ? Self.bareInset
                                  : CoinFormMetrics.titleH + CoinFormMetrics.titleGap
        if !bare {
            titleLabel.frame = NSRect(x: 0, y: 0, width: w, height: CoinFormMetrics.titleH)
        }
        card.frame = NSRect(x: cardX, y: cardY, width: cardW, height: rowsH)
        card.separatorYs = (1..<rows.count).map { CGFloat($0) * CoinFormMetrics.rowH }
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * CoinFormMetrics.rowH,
                               width: cardW, height: CoinFormMetrics.rowH)
        }
        layoutControls(width: cardW)
    }

    /// 行内控件排版（行 frame 就位后调用；行坐标 x 与区块坐标 x 同轴。
    /// 裸模式下传的是**外扩后**的宽度，行内 `padX` 恰好抵消外扩，控件落在行内容区内）
    func layoutControls(width: CGFloat) {}

    /// 行右缘列位（数值列 / 各控件右对齐共用）
    var controlRight: CGFloat {
        let contentW = bare ? bounds.width + CoinFormMetrics.padX * 2 : bounds.width
        return contentW - CoinFormMetrics.padX
    }

    /// 标签贴左列、垂直居中（挂在某个行视图里用）
    static func place(_ label: NSTextField, inWidth width: CGFloat) {
        label.frame = NSRect(x: CoinFormMetrics.padX, y: (CoinFormMetrics.rowH - 17) / 2,
                             width: CoinFormMetrics.labelW, height: 17)
    }

    /// 控件高（拉下按钮 / 色井 / 按钮统一吃这个口径，与 DeepSeek 弹窗下拉等高）
    static let controlH: CGFloat = DarkInputField.defaultHeight
}

/// 「标签 + 滑杆 + 数值」行：Thickness / Coin size / Logo size / Turns 等滑杆行共用。
/// 滑杆连续上报（拖动中实时改几何）+ 1 单位步进取整；数值标签 monospacedDigit 右对齐。
/// `ticks > 0` 时滑杆下方画**原生刻度**并只允许取刻度值（如 Turns 1…5 给 5 档刻度）——
/// 刻度占竖向空间，滑杆 frame 因此加高，仍按行框居中。
final class CoinSliderRowView: CoinFormRowView {
    let label: NSTextField
    let slider: NSSlider
    let valueLabel: NSTextField
    private let format: (Double) -> String
    /// 原生刻度数（0 = 无刻度，默认）
    private let tickCount: Int
    /// 无刻度 / 有刻度两种滑杆高度（行框 rowH = 36，刻度版下缘要留给刻度线）
    private var sliderHeight: CGFloat { tickCount > 0 ? 32 : 20 }
    var onValueChange: ((Double) -> Void)?

    init(label title: String, range: ClosedRange<Double>, value initialValue: Double,
         format: @escaping (Double) -> String, ticks: Int = 0) {
        label = NSTextField(labelWithString: title)
        slider = NSSlider(value: initialValue, minValue: range.lowerBound,
                          maxValue: range.upperBound, target: nil, action: nil)
        valueLabel = NSTextField(labelWithString: "")
        self.format = format
        self.tickCount = ticks
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right
        valueLabel.stringValue = format(initialValue)
        slider.controlSize = .small
        slider.isContinuous = true
        if ticks > 0 {
            // 原生刻度：等分铺在 min…max 上（Ticks 个刻度 = 档位值），只允许停在刻度上
            slider.numberOfTickMarks = ticks
            slider.tickMarkPosition = .below
            slider.allowsTickMarkValuesOnly = true
        }
        // 空格 = 硬币自旋：不让滑杆把第一响应者抢走（鼠标交互不受影响）
        slider.refusesFirstResponder = true
        slider.target = self
        slider.action = #selector(sliderDragged)
        addSubview(label)
        addSubview(valueLabel)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 行整体可用性：禁用时滑杆锁死、标签 / 数值淡化（如 Outline level 只在 Outline 外观下可调）
    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            label.textColor = newValue ? .secondaryLabelColor : .tertiaryLabelColor
            valueLabel.textColor = newValue ? .labelColor : .tertiaryLabelColor
        }
    }

    /// 标签 |（弹性）滑杆 | 数值 —— 数值右缘贴 controlRight
    func layout(width: CGFloat) {
        let textY = (CoinFormMetrics.rowH - 17) / 2
        label.frame = NSRect(x: CoinFormMetrics.padX, y: textY,
                             width: CoinFormMetrics.labelW, height: 17)
        valueLabel.frame = NSRect(x: width - CoinFormMetrics.padX - CoinFormMetrics.valueW,
                                  y: textY, width: CoinFormMetrics.valueW, height: 17)
        let sliderX = CoinFormMetrics.padX + CoinFormMetrics.labelW + CoinFormMetrics.controlGap
        slider.frame = NSRect(x: sliderX, y: (CoinFormMetrics.rowH - sliderHeight) / 2,
                              width: max(valueLabel.frame.minX - CoinFormMetrics.controlGap - sliderX, 0),
                              height: sliderHeight)
    }

    @objc private func sliderDragged() {
        let value = slider.doubleValue.rounded()
        slider.doubleValue = value
        valueLabel.stringValue = format(value)
        onValueChange?(value)
    }
}

// MARK: - Control 参数区

/// 「Control」参数区（排在 Edge 之前）：Style / Preset / Coin color / Field color /
/// Coin size / Logo size / Logo depth / Logo（上传 SVG）。控件全 AppKit 原生件：
/// 外观与预设与边纹 = 原生拉下按钮、颜色 = `NSColorWell`、尺寸与厚度 = 滑杆、
/// logo = 打开文件面板选 .svg。
/// ⚠️ mark **没有独立颜色**：它由 Coin color 派生出的面材质直接上色（见 `drawMark`），
/// 所以这里只有两个颜色井（Coin color + Field color）。
final class CoinControlSectionView: CoinFormSectionView {

    /// 区块标题：弹窗里画在卡上方；设置窗口「分段内嵌」时作为 Form Section header
    ///（宿主建 pane 时就要拿到它，所以是静态常量，见基类 `sectionTitle`）
    static let sectionTitle = "Control"

    var onCoinColorChange: ((CoinRGB) -> Void)?
    /// lowerField 色场：盖面下方那层「透明渐显」的颜色（独立 prop，不随 Coin color 派生）
    var onFieldColorChange: ((CoinRGB) -> Void)?
    var onPresetChange: ((CoinPreset) -> Void)?
    var onAppearanceChange: ((CoinAppearance) -> Void)?
    /// Outline level：Outline 线稿的内部结构层级（仅 Outline 外观下可调，其余档禁用）
    var onOutlineLevelChange: ((Double) -> Void)?
    /// Outline width：Outline 线稿基准线宽（仅 Outline 外观下可调，其余档禁用）
    var onOutlineWidthChange: ((Double) -> Void)?
    var onSizeChange: ((Double) -> Void)?
    /// Panel coin size：主面板 Token 板块内嵌硬币的直径（pt），与弹窗 Coin size 独立
    var onPanelSizeChange: ((Double) -> Void)?
    /// Logo size：滑杆**百分数**（50…125），与 `CoinSettings.logoScalePercent` 同域 ——
    /// 调用方原值上报，别预先 /100
    var onLogoScaleChange: ((Double) -> Void)?
    /// Logo depth：滑杆**px**（0…12），mark 沿盖面法线挤出的深度；0 = 保持平贴
    var onMarkDepthChange: ((Double) -> Void)?
    /// Shadow opacity：滑杆**百分数**（0…100），mark 边界阴影在轮廓处的可见峰值（N 遍合成后）
    var onShadowOpacityChange: ((Double) -> Void)?
    /// Shadow spread：滑杆**px**（0…16），mark 边界阴影的视觉衰减距离；0 = 整圈关断
    var onShadowSpreadChange: ((Double) -> Void)?
    /// 传入解析成功的 logo：轮廓 + **SVG 原文**（原文随参数一起落盘，下次开弹窗还原）
    /// + **文件名**（行内展示，一并落盘）
    var onLogoChange: ((CoinLogoArt, String, String) -> Void)?
    /// Logo 反色：原生开关（`NSSwitch`）。开 = logo 与其周围互为负形
    var onLogoInvertedChange: ((Bool) -> Void)?

    // 行 0：Style 拉下按钮（Default = 材质渲染 / Outline = 线稿；样式照 Edge finish）
    private let appearanceRow = CoinFormRowView(frame: .zero)
    private let appearanceLabel = NSTextField(labelWithString: "Style")
    private let appearancePopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    /// 拉下按钮按**最长档名**量出的宽度：切档时按钮不跳，右缘始终贴同一列
    private var appearancePopUpWidth: CGFloat = 0

    // 行 1：Outline level 滑杆（1…5，整数档刻度；仅 Outline 外观下可用）
    let outlineLevelRow: CoinSliderRowView
    // 行 2：Outline width 滑杆（1…4 px 基准线宽；仅 Outline 外观下可用）
    let outlineWidthRow: CoinSliderRowView

    // 行 3：Preset 拉下按钮（GHO = 无色场 / sGHO = 启用色场；样式照 Edge finish 的拉下按钮）
    private let presetRow = CoinFormRowView(frame: .zero)
    private let presetLabel = NSTextField(labelWithString: "Preset")
    private let presetPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    /// 拉下按钮按**最长档名**量出的宽度：切档时按钮不跳，右缘始终贴同一列
    private var presetPopUpWidth: CGFloat = 0

    // 行 1：颜色井（初值取落盘参数，见 `CoinSettings.load()`）
    private let coinColorRow = CoinFormRowView(frame: .zero)
    private let coinColorLabel = NSTextField(labelWithString: "Coin color")
    private let coinColorWell = NSColorWell(frame: .zero)

    // 行 0.5：lowerField 色场颜色井（sgho 默认紫，见 `CoinMaterial.sgho.field`）
    private let fieldColorRow = CoinFormRowView(frame: .zero)
    private let fieldColorLabel = NSTextField(labelWithString: "Field color")
    private let fieldColorWell = NSColorWell(frame: .zero)

    // 行 1 / 2 / 3：滑杆
    let coinSizeRow: CoinSliderRowView
    /// 紧跟 Coin size 之后：主面板内嵌硬币的直径（只影响内嵌那枚，不动弹窗预览币）
    let panelSizeRow: CoinSliderRowView
    let logoSizeRow: CoinSliderRowView
    let logoDepthRow: CoinSliderRowView
    let shadowOpacityRow: CoinSliderRowView
    let shadowSpreadRow: CoinSliderRowView

    // 行 4：Logo 上传（标签 + 当前文件名 + 上传按钮）
    private let logoRow = CoinFormRowView(frame: .zero)
    private let logoLabel = NSTextField(labelWithString: "Logo")
    /// 当前 logo 的出处：上传过 = 文件名，否则「内置预设」。过长按中间截断
    private let logoNameLabel = NSTextField(labelWithString: "")
    private let uploadButton: NSButton = {
        let button = NSButton(title: "Upload SVG…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.refusesFirstResponder = true
        return button
    }()

    // 行 5：Logo 反色（原生开关，右缘与其它行控件同列）
    private let logoInvertRow = CoinFormRowView(frame: .zero)
    private let logoInvertLabel = NSTextField(labelWithString: "Logo invert")
    private let logoInvertSwitch = NSSwitch(frame: .zero)

    private(set) var preset: CoinPreset
    /// ⚠️ 不叫 `appearance`：NSView 自带 `appearance: NSAppearance?`，子类撞名报 override
    private(set) var selectedAppearance: CoinAppearance

    init(settings: CoinSettings, bare: Bool = false) {
        preset = settings.preset
        selectedAppearance = settings.appearance
        outlineLevelRow = CoinSliderRowView(label: "Outline level",
                                            range: CoinMetrics.outlineLevelRange,
                                            value: settings.outlineLevel,
                                            ticks: 4) { "\(Int($0))" }
        outlineWidthRow = CoinSliderRowView(label: "Outline width",
                                            range: CoinMetrics.outlineWidthRange,
                                            value: settings.outlineWidth,
                                            ticks: 10) { "\(Int($0)) px" }
        coinSizeRow = CoinSliderRowView(label: "Coin size", range: CoinMetrics.sizeRange,
                                        value: settings.size) { "\(Int($0)) px" }
        // Panel coin size：主面板内嵌硬币直径（pt）。与 Coin size 独立 —— 弹窗那枚是
        // 「舞台上的大币」，内嵌是「贴着数字的记号」，量级差一个数量级，共用一个滑杆会互相绑架
        panelSizeRow = CoinSliderRowView(label: "Panel coin size",
                                         range: CoinMetrics.panelSizeRange,
                                         value: settings.panelSize) { "\(Int($0)) px" }
        // Logo size 滑杆走百分数刻度（50…125% = mark.scale 0.5…1.25，参考实现夹这个区间）
        logoSizeRow = CoinSliderRowView(label: "Logo size", range: 50...125,
                                        value: settings.logoScalePercent) { "\(Int($0)) %" }
        // Logo 厚度：0 = 平贴（参考实现原样），> 0 时 mark 被挤出成硬币的实体部分
        logoDepthRow = CoinSliderRowView(label: "Logo depth", range: CoinMetrics.markDepthRange,
                                         value: settings.markDepth) { "\(Int($0)) px" }
        // Shadow opacity：mark 边界阴影的可见峰值（百分数；量程 0…100，遍数随值自适应，
        // 见 CoinMetrics.markShadowOpacityRange / markRimShadowPasses(forPeak:)）
        shadowOpacityRow = CoinSliderRowView(label: "Shadow opacity",
                                             range: CoinMetrics.markShadowOpacityRange,
                                             value: settings.markShadowOpacity) { "\(Int($0)) %" }
        // Shadow spread：边界阴影的衰减距离（px/160 盒），0 = 整圈阴影关断
        shadowSpreadRow = CoinSliderRowView(label: "Shadow spread",
                                            range: CoinMetrics.markShadowSpreadRange,
                                            value: settings.markShadowSpread) { "\(Int($0)) px" }
        super.init(title: CoinControlSectionView.sectionTitle, bare: bare)

        for row in [appearanceRow, outlineLevelRow, outlineWidthRow, presetRow, coinColorRow,
                    fieldColorRow, coinSizeRow, panelSizeRow, logoSizeRow, logoDepthRow,
                    shadowOpacityRow, shadowSpreadRow, logoRow, logoInvertRow] {
            addRow(row)
        }
        for label in [appearanceLabel, presetLabel, coinColorLabel, fieldColorLabel, logoLabel,
                      logoInvertLabel] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
        }
        appearanceRow.addSubview(appearanceLabel)
        appearanceRow.addSubview(appearancePopUp)
        presetRow.addSubview(presetLabel)
        presetRow.addSubview(presetPopUp)
        coinColorRow.addSubview(coinColorLabel)
        coinColorRow.addSubview(coinColorWell)
        fieldColorRow.addSubview(fieldColorLabel)
        fieldColorRow.addSubview(fieldColorWell)
        logoRow.addSubview(logoLabel)
        logoRow.addSubview(logoNameLabel)
        logoRow.addSubview(uploadButton)
        logoInvertRow.addSubview(logoInvertLabel)
        logoInvertRow.addSubview(logoInvertSwitch)

        // Logo 反色开关（原生 NSSwitch）：落盘值直接映射 state，on/off 两态
        logoInvertSwitch.state = settings.logoInverted ? .on : .off
        logoInvertSwitch.target = self
        logoInvertSwitch.action = #selector(logoInvertToggled)

        // 色井摆到落盘值（参考实现默认：币 = sgho 绿、色场 = sgho 紫）
        coinColorWell.color = settings.materialColor.nsColor
        fieldColorWell.color = settings.fieldColor.nsColor

        // Logo 行说明：落盘的文件名（没上传过就是「内置预设」）
        logoNameLabel.font = .systemFont(ofSize: 11)
        logoNameLabel.textColor = .tertiaryLabelColor
        logoNameLabel.lineBreakMode = .byTruncatingMiddle
        logoNameLabel.alignment = .right
        setLogoCaption(settings.logoCaption)

        // 色井：拖动色板连续回调（isContinuous 需 macOS 14+，本包部署目标 26）
        coinColorWell.isContinuous = true
        coinColorWell.target = self
        coinColorWell.action = #selector(coinColorChanged)
        fieldColorWell.isContinuous = true
        fieldColorWell.target = self
        fieldColorWell.action = #selector(fieldColorChanged)

        // Appearance 拉下按钮：与 Edge finish 同一套模式（标题项 + 档位 tag = rawValue + 1）
        appearancePopUp.addItem(withTitle: "")
        for option in CoinAppearance.allCases {
            appearancePopUp.addItem(withTitle: option.title)
            let item = appearancePopUp.lastItem
            item?.target = self
            item?.action = #selector(appearanceOptionPicked(_:))
            item?.tag = option.rawValue + 1
        }
        appearancePopUp.refusesFirstResponder = true
        appearancePopUp.item(at: 0)?.title = CoinAppearance.allCases
            .max { $0.title.count < $1.title.count }?.title ?? ""
        appearancePopUp.sizeToFit()
        appearancePopUpWidth = max(appearancePopUp.frame.width, CoinFormMetrics.valueW)
        syncAppearanceState()
        outlineLevelRow.onValueChange = { [weak self] in self?.onOutlineLevelChange?($0) }
        outlineWidthRow.onValueChange = { [weak self] in self?.onOutlineWidthChange?($0) }

        // Preset 拉下按钮：与 Edge finish 同一套模式（AppKit 规定标题项不进菜单，
        // 只用它的文字当按钮标题；档位另作菜单项，tag = rawValue + 1）
        presetPopUp.addItem(withTitle: "")
        for option in CoinPreset.allCases {
            presetPopUp.addItem(withTitle: option.title)
            let item = presetPopUp.lastItem
            item?.target = self
            item?.action = #selector(presetOptionPicked(_:))
            item?.tag = option.rawValue + 1
        }
        presetPopUp.refusesFirstResponder = true
        presetPopUp.item(at: 0)?.title = CoinPreset.allCases
            .max { $0.title.count < $1.title.count }?.title ?? ""
        presetPopUp.sizeToFit()
        presetPopUpWidth = max(presetPopUp.frame.width, CoinFormMetrics.valueW)
        syncPresetState()

        coinSizeRow.onValueChange = { [weak self] in self?.onSizeChange?($0) }
        panelSizeRow.onValueChange = { [weak self] in self?.onPanelSizeChange?($0) }
        // ⚠️ 原值上报（百分数 50…125）—— 单位与 `CoinSettings.logoScalePercent` 同域，
        // 换算（/100）只在 `apply(logoScale:)` 一处做。这里再除一次 = 硬币缩到 1% 且落盘成 0.x
        logoSizeRow.onValueChange = { [weak self] in self?.onLogoScaleChange?($0) }
        logoDepthRow.onValueChange = { [weak self] in self?.onMarkDepthChange?($0) }
        shadowOpacityRow.onValueChange = { [weak self] in self?.onShadowOpacityChange?($0) }
        shadowSpreadRow.onValueChange = { [weak self] in self?.onShadowSpreadChange?($0) }
        uploadButton.target = self
        uploadButton.action = #selector(uploadLogo)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutControls(width: CGFloat) {
        let textY = (CoinFormMetrics.rowH - 17) / 2
        let right = width - CoinFormMetrics.padX
        // Style 行：标签 + 拉下按钮（右缘贴 controlRight）
        appearanceLabel.frame = NSRect(x: CoinFormMetrics.padX, y: textY,
                                       width: CoinFormMetrics.labelW, height: 17)
        appearancePopUp.frame = NSRect(x: right - appearancePopUpWidth,
                                       y: (CoinFormMetrics.rowH - Self.controlH) / 2,
                                       width: appearancePopUpWidth, height: Self.controlH)
        outlineLevelRow.layout(width: width)
        outlineWidthRow.layout(width: width)
        // Preset 行：标签 + 拉下按钮（右缘贴 controlRight）
        presetLabel.frame = NSRect(x: CoinFormMetrics.padX, y: textY,
                                   width: CoinFormMetrics.labelW, height: 17)
        presetPopUp.frame = NSRect(x: right - presetPopUpWidth,
                                   y: (CoinFormMetrics.rowH - Self.controlH) / 2,
                                   width: presetPopUpWidth, height: Self.controlH)
        // 颜色井：右缘贴 controlRight，方井 52 宽
        coinColorLabel.frame = NSRect(x: CoinFormMetrics.padX, y: textY,
                                      width: CoinFormMetrics.labelW, height: 17)
        coinColorWell.frame = NSRect(x: right - Self.wellWidth, y: textY - 2,
                                     width: Self.wellWidth, height: Self.controlH)
        fieldColorLabel.frame = NSRect(x: CoinFormMetrics.padX, y: textY,
                                       width: CoinFormMetrics.labelW, height: 17)
        fieldColorWell.frame = NSRect(x: right - Self.wellWidth, y: textY - 2,
                                      width: Self.wellWidth, height: Self.controlH)
        coinSizeRow.layout(width: width)
        panelSizeRow.layout(width: width)
        logoSizeRow.layout(width: width)
        logoDepthRow.layout(width: width)
        shadowOpacityRow.layout(width: width)
        shadowSpreadRow.layout(width: width)
        logoLabel.frame = NSRect(x: CoinFormMetrics.padX, y: textY,
                                 width: CoinFormMetrics.labelW, height: 17)
        uploadButton.sizeToFit()
        let uploadW = max(ceil(uploadButton.frame.width) + 16, CoinFormMetrics.valueW)
        uploadButton.frame = NSRect(x: right - uploadW, y: (CoinFormMetrics.rowH - Self.controlH) / 2,
                                    width: uploadW, height: Self.controlH)
        // 文件名填在标签列与上传按钮之间（宽度随按钮实宽自适应，过长中间截断）
        let nameX = CoinFormMetrics.padX + CoinFormMetrics.labelW + CoinFormMetrics.controlGap
        logoNameLabel.frame = NSRect(x: nameX, y: textY,
                                     width: max(uploadButton.frame.minX
                                                - CoinFormMetrics.controlGap - nameX, 0), height: 17)
        // Logo 反色行：标签在左，原生开关右缘贴 controlRight（与色井/按钮同列）
        logoInvertLabel.frame = NSRect(x: CoinFormMetrics.padX, y: textY,
                                       width: CoinFormMetrics.labelW, height: 17)
        let switchSize = logoInvertSwitch.intrinsicContentSize
        logoInvertSwitch.frame = NSRect(x: right - switchSize.width,
                                        y: (CoinFormMetrics.rowH - switchSize.height) / 2,
                                        width: switchSize.width, height: switchSize.height)
    }

    private static let wellWidth: CGFloat = 52

    /// Logo 行说明文案（上传后 = 文件名；否则 = 内置预设），tooltip 给全文
    private func setLogoCaption(_ caption: String) {
        logoNameLabel.stringValue = caption
        logoNameLabel.toolTip = caption
    }

    // MARK: 交互

    @objc private func coinColorChanged() {
        onCoinColorChange?(Self.coinRGB(coinColorWell.color))
    }

    @objc private func fieldColorChanged() {
        onFieldColorChange?(Self.coinRGB(fieldColorWell.color))
    }

    @objc private func logoInvertToggled() {
        onLogoInvertedChange?(logoInvertSwitch.state == .on)
    }

    /// 档位 tag = rawValue + 1（标题项 tag 0 不参与，见 init）
    @objc private func presetOptionPicked(_ sender: NSMenuItem) {
        guard let option = CoinPreset(rawValue: sender.tag - 1), option != preset else { return }
        preset = option
        syncPresetState()
        onPresetChange?(option)
    }

    /// 选中态：标题项显示当前档名 + 菜单里当前档打勾；gho 档没有色场，Field color 色井一并禁用
    private func syncPresetState() {
        presetPopUp.item(at: 0)?.title = preset.title
        for item in presetPopUp.itemArray {
            guard let option = CoinPreset(rawValue: item.tag - 1) else { continue }
            item.state = option == preset ? .on : .off
        }
        fieldColorWell.isEnabled = (preset == .sgho)
    }

    /// 档位 tag = rawValue + 1（标题项 tag 0 不参与，见 init）
    @objc private func appearanceOptionPicked(_ sender: NSMenuItem) {
        guard let option = CoinAppearance(rawValue: sender.tag - 1),
              option != selectedAppearance else { return }
        selectedAppearance = option
        syncAppearanceState()
        onAppearanceChange?(option)
    }

    /// 选中态：标题项显示当前档名 + 菜单里当前档打勾；Outline level 只在 Outline 档可调
    private func syncAppearanceState() {
        appearancePopUp.item(at: 0)?.title = selectedAppearance.title
        for item in appearancePopUp.itemArray {
            guard let option = CoinAppearance(rawValue: item.tag - 1) else { continue }
            item.state = option == selectedAppearance ? .on : .off
        }
        outlineLevelRow.isEnabled = (selectedAppearance == .outline)
        outlineWidthRow.isEnabled = (selectedAppearance == .outline)
    }

    /// 上传 SVG：文件面板 → 读原文（UTF-8）→ 解析 → 回调「轮廓 + 原文」。
    /// 解析 / 读取失败如实弹错（错误信息来自 CoinSVGError 或 Foundation），不静默吞。
    @objc private func uploadLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.svg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // 原文要落盘（还原时重新解析），所以按文本读：非 UTF-8 的 SVG 会在这里报错
            let source = try String(contentsOf: url, encoding: .utf8)
            let art = try CoinSVG.parse(source)
            setLogoCaption(url.lastPathComponent)
            onLogoChange?(art, source, url.lastPathComponent)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func coinRGB(_ color: NSColor) -> CoinRGB {
        let c = color.usingColorSpace(.sRGB) ?? color
        return CoinRGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}

// MARK: - Edge 参数区

/// 「Edge」参数区：Thickness（滑杆）+ Edge finish（原生拉下按钮）。
final class CoinEdgeSectionView: CoinFormSectionView {

    /// 区块标题（同 `CoinControlSectionView.sectionTitle`）
    static let sectionTitle = "Edge"

    var onThicknessChange: ((Double) -> Void)?
    var onFinishChange: ((CoinEdgeFinish) -> Void)?

    private(set) var finish: CoinEdgeFinish

    let thicknessRow: CoinSliderRowView
    // 行 1：Edge finish —— 标签 + 原生拉下按钮（标题项 = 当前档名，菜单 = 三档选项）
    private let finishRow = CoinFormRowView(frame: .zero)
    private let finishLabel = NSTextField(labelWithString: "Edge finish")
    private let finishPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    /// 拉下按钮按**最长档名**量出的宽度：切档时按钮不跳，右缘始终贴同一列
    private var finishPopUpWidth: CGFloat = 0

    init(settings: CoinSettings, bare: Bool = false) {
        finish = settings.finish
        thicknessRow = CoinSliderRowView(label: "Thickness", range: CoinMetrics.thicknessRange,
                                         value: settings.thickness) { "\(Int($0)) px" }
        super.init(title: CoinEdgeSectionView.sectionTitle, bare: bare)
        addRow(thicknessRow)
        addRow(finishRow)
        // 滑杆 → 硬币：连续上报（拖动中实时改厚度）。漏了这句滑杆就只是自娱自乐
        thicknessRow.onValueChange = { [weak self] in self?.onThicknessChange?($0) }

        finishLabel.font = .systemFont(ofSize: 13)
        finishLabel.textColor = .secondaryLabelColor
        finishRow.addSubview(finishLabel)

        // 拉下按钮：item 0 是**标题项**（AppKit 规定它不进菜单，只用它的文字当按钮标题），
        // 三个档位另作菜单项；每项自带 target/action，认档走 `tag`（标题项 tag 0 不参与，
        // 故档位 tag = rawValue + 1）—— 不依赖按钮的 indexOfSelectedItem（拉下按钮不跟踪选中）
        finishPopUp.addItem(withTitle: "")
        for option in CoinEdgeFinish.allCases {
            finishPopUp.addItem(withTitle: option.title)
            let item = finishPopUp.lastItem
            item?.target = self
            item?.action = #selector(finishOptionPicked(_:))
            item?.tag = option.rawValue + 1
        }
        // 与滑杆同理：不让按钮把第一响应者抢走（否则空格不再触发硬币自旋）
        finishPopUp.refusesFirstResponder = true
        finishRow.addSubview(finishPopUp)

        // 宽度按最长档名量一次（切档只换标题、不再量，按钮右缘因此纹丝不动）
        finishPopUp.item(at: 0)?.title = CoinEdgeFinish.allCases
            .max { $0.title.count < $1.title.count }?.title ?? ""
        finishPopUp.sizeToFit()
        finishPopUpWidth = max(finishPopUp.frame.width, CoinFormMetrics.valueW)
        syncFinishState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutControls(width: CGFloat) {
        thicknessRow.layout(width: width)
        Self.place(finishLabel, inWidth: width)
        finishPopUp.frame = NSRect(x: width - CoinFormMetrics.padX - finishPopUpWidth,
                                   y: (CoinFormMetrics.rowH - Self.controlH) / 2,
                                   width: finishPopUpWidth, height: Self.controlH)
    }

    // MARK: 交互

    /// 拉下按钮的**菜单项**自带 target/action（不挂按钮本体）：`tag - 1` 即档位 rawValue
    @objc private func finishOptionPicked(_ sender: NSMenuItem) {
        guard let option = CoinEdgeFinish(rawValue: sender.tag - 1), option != finish else { return }
        finish = option
        syncFinishState()
        onFinishChange?(option)
    }

    /// 选中态：按钮标题项显示当前档名 + 菜单里当前档打勾（标题项 tag 0，天然被跳过）
    private func syncFinishState() {
        finishPopUp.item(at: 0)?.title = finish.title
        for item in finishPopUp.itemArray {
            guard let option = CoinEdgeFinish(rawValue: item.tag - 1) else { continue }
            item.state = option == finish ? .on : .off
        }
    }
}

// MARK: - Motion 参数区

/// 「Motion」参数区（排在 Edge 之后，用户 2026-09-11 指定）：
/// Resting tilt（静止俯仰 -180…180）/ Resting rotation（静止朝向 -180…180）/ Turns（自旋 1…5 圈）。
/// 三行都是滑杆、整数步进（`CoinSliderRowView` 自带 rounded），改动经回调实时上币。
final class CoinMotionSectionView: CoinFormSectionView {

    /// 区块标题（同 `CoinControlSectionView.sectionTitle`）
    static let sectionTitle = "Motion"

    var onRestingTiltChange: ((Double) -> Void)?
    var onRestingRotationChange: ((Double) -> Void)?
    var onTurnsChange: ((Double) -> Void)?

    let restingTiltRow: CoinSliderRowView
    let restingRotationRow: CoinSliderRowView
    let turnsRow: CoinSliderRowView

    init(settings: CoinSettings, bare: Bool = false) {
        restingTiltRow = CoinSliderRowView(label: "Resting tilt",
                                           range: CoinMetrics.restingTiltRange,
                                           value: settings.restingTilt) { "\(Int($0))°" }
        restingRotationRow = CoinSliderRowView(label: "Resting rotation",
                                               range: CoinMetrics.restingRotationRange,
                                               value: settings.restingRotation) { "\(Int($0))°" }
        turnsRow = CoinSliderRowView(label: "Turns",
                                     range: CoinMetrics.turnsRange,
                                     value: settings.turns,
                                     ticks: 5) { "\(Int($0))" }
        super.init(title: CoinMotionSectionView.sectionTitle, bare: bare)
        addRow(restingTiltRow)
        addRow(restingRotationRow)
        addRow(turnsRow)
        restingTiltRow.onValueChange = { [weak self] in self?.onRestingTiltChange?($0) }
        restingRotationRow.onValueChange = { [weak self] in self?.onRestingRotationChange?($0) }
        turnsRow.onValueChange = { [weak self] in self?.onTurnsChange?($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutControls(width: CGFloat) {
        restingTiltRow.layout(width: width)
        restingRotationRow.layout(width: width)
        turnsRow.layout(width: width)
    }
}

// MARK: - 弹窗内容

/// 参数区滚动内容承载视图（翻转坐标，布局由 `CoinDemoPanelView` 统一排）。
/// 三块参数区从上往下排在它里面，NSScrollView 按它的 frame 决定滚动范围。
final class CoinParamsStackView: NSView {
    override var isFlipped: Bool { true }
}

/// 弹窗内容：硬币舞台（fit 当前参数）+ 参数区（Control / Edge / Motion 三块自然高）。
/// 设置窗口内嵌：整卡高度随内容（舞台 fit + 参数区不裁不滚），卡片随设置页滚动，
/// 提示行钉在页面底部；GlassModalShell 弹窗壳内同自然高。
/// 参数自动保存（见 `notifyLiveChange()`）；开面板时从磁盘还原。
final class CoinDemoPanelView: NSView {

    static let gap: CGFloat = 10

    /// 舞台高度。`fixed = true`（设置窗口「分段内嵌」，2026-09-13 用户要求「容器固定尺寸」）
    /// 恒取满量程 `Coin3DView.contentHeight` —— 拖 size / thickness 只换硬币、框不动；
    /// false（弹窗）按当前参数收窄，省掉用不到的滑杆上界留白（「缩小预览视图」2026-09-13）。
    /// 公式与 Coin3DView.contentHeight 同口径，不含落地影的高度预算（阴影已移除）。
    private static func stageHeight(size: Double, thickness: Double, fixed: Bool) -> CGFloat {
        guard !fixed else { return Coin3DView.contentHeight }
        let s = CGFloat(size), t = CGFloat(thickness)
        let top = (s * s + t * t).squareRoot() / 2 + CoinMetrics.idleBounceHeight + 1
        let bottom = s / 2
        return (top + bottom).rounded(.up)
    }

    let coin = Coin3DView(frame: .zero)
    /// 参数区滚动容器（内容 = Control / Edge / Motion；设置窗口内嵌时视口 = 自然高，不再滚动）
    private let paramsScroll = NSScrollView(frame: .zero)
    private let paramsStack = CoinParamsStackView(frame: .zero)
    let control: CoinControlSectionView
    let edge: CoinEdgeSectionView
    let motion: CoinMotionSectionView
    /// 整页参数的内存快照：每个回调写一份并实时上币 / 实时落盘 / 实时同步主面板
    /// 小硬币（通知，见 `notifyLiveChange()`）
    private var settings: CoinSettings

    /// 「分段内嵌」模式（设置窗口，2026-09-13 用户：「3D 预览框不要包裹下方的 forms」）：
    /// 为 true 时本面板**自己不上屏**，只作为两块容器的宿主 —— 预览框（`stageHost`）与
    /// 表单框（`paramsHost`）分别被设置窗口的两个 Form Section 内嵌，卡片因此各归各的。
    /// 为 false（玻璃弹窗壳）时两块照旧上下排在面板里，行为与改造前完全一致。
    let splitHosting: Bool
    /// 预览框内容：只装 3D 舞台（硬币本体）
    let stageHost: CoinStageHostView
    /// 表单框内容：只装 Control / Edge / Motion 三块参数区
    let paramsHost: CoinParamsHostView

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, splitHosting: Bool = false) {
        // 控件要按落盘参数摆初值，所以先取快照再建控件、再回填硬币本体
        let settings = CoinSettings.load()
        // 分段内嵌（设置窗口）：三块参数区用**裸模式**建 —— 无标题、不铺卡底，
        // 它们各自进一个 Form Section，标题与卡片都由 Form 画（2026-09-13 用户：
        // 「硬币下面的参数放在普通的 forms 里，不要嵌套」）
        let controlSection = CoinControlSectionView(settings: settings, bare: splitHosting)
        let edgeSection = CoinEdgeSectionView(settings: settings, bare: splitHosting)
        let motionSection = CoinMotionSectionView(settings: settings, bare: splitHosting)
        self.settings = settings
        self.splitHosting = splitHosting
        control = controlSection
        edge = edgeSection
        motion = motionSection
        // 两块宿主容器先建好：弹窗模式挂进面板，分段模式交给设置窗口的两个 Section
        stageHost = CoinStageHostView(coin: coin)
        paramsHost = CoinParamsHostView(scroll: paramsScroll, stack: paramsStack,
                                        sections: [controlSection, edgeSection, motionSection],
                                        gap: Self.gap)
        super.init(frame: frameRect)
        // 舞台高度：分段内嵌（设置窗口）恒取满量程 → 容器固定尺寸；弹窗按当前参数收窄。
        // 先于入窗定值，draw 链路的居中即按此算
        coin.stageHeight = Self.stageHeight(size: settings.size, thickness: settings.thickness,
                                           fixed: splitHosting)
        // 参数区装进一个滚动容器：三块参数区都挂在 paramsStack（documentView）上
        paramsScroll.hasVerticalScroller = true
        paramsScroll.autohidesScrollers = true
        paramsScroll.drawsBackground = false
        paramsScroll.borderType = .noBorder
        paramsScroll.scrollerStyle = .overlay
        paramsScroll.hasHorizontalScroller = false
        paramsScroll.horizontalScrollElasticity = .none
        paramsScroll.documentView = paramsStack
        // ⚠️ 分段模式（设置窗口）：三块参数区**不**挂进 paramsStack、面板自身也不上屏 ——
        //    它们各自作为普通 Form 行被内嵌（见 `splitGroupViews`）。挂进来会让它们被
        //    面板的 layout 抢走父子关系，设置窗口那边就内嵌不进去了
        if !splitHosting {
            paramsStack.addSubview(control)
            paramsStack.addSubview(edge)
            paramsStack.addSubview(motion)
            addSubview(stageHost)
            addSubview(paramsHost)
        }

        coin.material = settings.material
        coin.size = settings.size
        coin.thickness = settings.thickness
        coin.logoScale = settings.logoScalePercent / 100
        coin.markDepth = settings.markDepth
        coin.markShadowOpacity = settings.markShadowOpacity / 100
        coin.markShadowSpread = settings.markShadowSpread
        coin.logoArt = settings.logoArt
        coin.edgeFinish = settings.finish
        coin.style = settings.appearance
        coin.outlineLevel = Int(settings.outlineLevel.rounded())
        coin.outlineWidth = settings.outlineWidth
        coin.logoInverted = settings.logoInverted
        coin.restingTilt = settings.restingTilt
        coin.restingRotation = settings.restingRotation
        coin.turns = Int(settings.turns.rounded())

        // 参数 → 硬币 + 内存快照 + 通知（每个回调都走 `apply`，出口只有一处）
        control.onPresetChange = { [weak self] in self?.apply(preset: $0) }
        control.onAppearanceChange = { [weak self] in self?.apply(appearance: $0) }
        control.onOutlineLevelChange = { [weak self] in self?.apply(outlineLevel: $0) }
        control.onOutlineWidthChange = { [weak self] in self?.apply(outlineWidth: $0) }
        control.onCoinColorChange = { [weak self] in self?.apply(materialColor: $0) }
        control.onFieldColorChange = { [weak self] in self?.apply(fieldColor: $0) }
        control.onSizeChange = { [weak self] in self?.apply(size: $0) }
        control.onPanelSizeChange = { [weak self] in self?.apply(panelSize: $0) }
        control.onLogoScaleChange = { [weak self] in self?.apply(logoScale: $0) }
        control.onMarkDepthChange = { [weak self] in self?.apply(markDepth: $0) }
        control.onShadowOpacityChange = { [weak self] in self?.apply(markShadowOpacity: $0) }
        control.onShadowSpreadChange = { [weak self] in self?.apply(markShadowSpread: $0) }
        control.onLogoChange = { [weak self] art, svg, name in
            self?.apply(logoArt: art, svg: svg, name: name)
        }
        control.onLogoInvertedChange = { [weak self] in self?.apply(logoInverted: $0) }
        edge.onThicknessChange = { [weak self] in self?.apply(thickness: $0) }
        edge.onFinishChange = { [weak self] in self?.apply(finish: $0) }
        motion.onRestingTiltChange = { [weak self] in self?.apply(restingTilt: $0) }
        motion.onRestingRotationChange = { [weak self] in self?.apply(restingRotation: $0) }
        motion.onTurnsChange = { [weak self] in self?.apply(turns: $0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 单个参数 → 硬币 + 内存快照 + 通知

    /// 参数变更统一出口（19 个 apply 全走这里）：快照即时落盘（2026-09-13 起自动
    /// 保存，显式「保存为默认」按钮已删）+ 通知实时同步主面板小硬币
    ///（通知带**内存快照**，主面板靠它重灌、不读盘）
    private func notifyLiveChange() {
        settings.save()
        NotificationCenter.default.post(name: .coinSettingsDidChange,
                                        object: CoinSettingsBox(settings))
    }

    /// 兼容弹窗壳的显式保存入口（入口已随操作磁贴退场）：快照整份落盘，与自动保存同函数
    func persistDefaults() {
        settings.save()
    }

    /// Preset：只决定 lowerField 开关（gho 关 / sgho 开），面/边 token 与色值不动
    private func apply(preset: CoinPreset) {
        settings.preset = preset
        coin.material = settings.material
        notifyLiveChange()
    }

    /// Appearance：Default 材质渲染 / Outline 线稿（见 `Coin3DView.drawOutline`）
    private func apply(appearance: CoinAppearance) {
        settings.appearance = appearance
        coin.style = appearance
        notifyLiveChange()
    }

    /// Outline level：线稿内部结构层级（1…5，仅 Outline 外观生效）
    private func apply(outlineLevel: Double) {
        settings.outlineLevel = outlineLevel
        coin.outlineLevel = Int(outlineLevel.rounded())
        notifyLiveChange()
    }

    /// Outline width：线稿基准线宽（1…4 px，仅 Outline 外观生效）
    private func apply(outlineWidth: Double) {
        settings.outlineWidth = outlineWidth
        coin.outlineWidth = outlineWidth
        notifyLiveChange()
    }

    private func apply(materialColor: CoinRGB) {
        settings.materialColor = materialColor
        coin.material = settings.material
        notifyLiveChange()
    }

    /// lowerField 色场：只换 `CoinMaterial.field` 颜色，面/边 token 不动
    private func apply(fieldColor: CoinRGB) {
        settings.fieldColor = fieldColor
        coin.material = settings.material
        notifyLiveChange()
    }

    private func apply(size: Double) {
        settings.size = size
        coin.size = size
        syncStageHeight()
        notifyLiveChange()
    }

    /// Panel coin size：主面板内嵌硬币的直径。**不动弹窗预览币**（它跟 `size` 走），
    /// 只更新内存快照 + 发实时同步通知（`TokensPanelView` 收到后重灌内嵌硬币）。
    private func apply(panelSize: Double) {
        settings.panelSize = panelSize
        notifyLiveChange()
    }

    /// Logo 反色：logo 与其周围互为负形（两种外观档都生效，见 `Coin3DView.logoInverted`）
    private func apply(logoInverted: Bool) {
        settings.logoInverted = logoInverted
        coin.logoInverted = logoInverted
        notifyLiveChange()
    }

    private func apply(thickness: Double) {
        settings.thickness = thickness
        coin.thickness = thickness
        syncStageHeight()
        notifyLiveChange()
    }

    /// 舞台随参数即时重算：弹窗里硬币在现有面板框内重新居中；分段内嵌（设置窗口）下舞台是
    /// **固定尺寸**（满量程），这里算出来仍是同一个数，等于不动 —— 拖 size/thickness 只换硬币。
    /// 整卡总高（fittingSize）由宿主 SwiftUI 侧按需重查——拖动滑杆过程中的总高变化到下次布局/重开才落定
    private func syncStageHeight() {
        coin.stageHeight = Self.stageHeight(size: settings.size, thickness: settings.thickness,
                                            fixed: splitHosting)
        needsLayout = true
        // 分段内嵌（设置窗口）时本面板自己不上屏，`needsLayout` 传不到预览框宿主 ——
        // 点名让它重排，硬币 frame 才会跟着新舞台高走（否则会按旧高度偏心）
        stageHost.needsLayout = true
    }

    /// Logo size：入参是滑杆**百分数**（50…125），硬币吃 0.5…1.25 的倍率 ——
    /// 全项目只有这里做这一次换算（`CoinSettings.logoScalePercent` 也存百分数）
    private func apply(logoScale percent: Double) {
        settings.logoScalePercent = percent
        coin.logoScale = percent / 100
        notifyLiveChange()
    }

    /// Logo depth：入参就是 px（0…12），与 `CoinSettings.markDepth` 同域，不做任何换算
    private func apply(markDepth: Double) {
        settings.markDepth = markDepth
        coin.markDepth = markDepth
        notifyLiveChange()
    }

    /// Shadow opacity：入参是滑杆**百分数**（0…100），硬币吃分数 —— 与 Logo size 同一套换算
    private func apply(markShadowOpacity percent: Double) {
        settings.markShadowOpacity = percent
        coin.markShadowOpacity = percent / 100
        notifyLiveChange()
    }

    /// Shadow spread：入参就是 px（0…16），与 `CoinSettings.markShadowSpread` 同域，不做任何换算
    private func apply(markShadowSpread: Double) {
        settings.markShadowSpread = markShadowSpread
        coin.markShadowSpread = markShadowSpread
        notifyLiveChange()
    }

    /// 上传的 SVG：轮廓直接上币，原文与文件名进快照（下次开弹窗重新解析 + 显示文件名）
    private func apply(logoArt: CoinLogoArt, svg: String, name: String) {
        settings.logoSVG = svg
        settings.logoName = name
        coin.logoArt = logoArt
        notifyLiveChange()
    }

    private func apply(finish: CoinEdgeFinish) {
        settings.finish = finish
        coin.edgeFinish = finish
        notifyLiveChange()
    }

    /// 静止俯仰（度）：出生姿态 + 拖拽俯仰的夹紧窗口中心（见 Coin3DView.restingTilt）
    private func apply(restingTilt: Double) {
        settings.restingTilt = restingTilt
        coin.restingTilt = restingTilt
        notifyLiveChange()
    }

    /// 静止朝向（度）：出生姿态，改动即时对齐（rotation/target/velocity 一起写）
    private func apply(restingRotation: Double) {
        settings.restingRotation = restingRotation
        coin.restingRotation = restingRotation
        notifyLiveChange()
    }

    /// 自旋圈数（1…5，滑杆已整数步进）：spin() 一次转 turns × 360°
    private func apply(turns: Double) {
        settings.turns = turns
        coin.turns = Int(turns.rounded())
        notifyLiveChange()
    }

    /// 面板自然总高 = fit 舞台 + 间距 + 参数区自然高（HostedContentView 以 fittingSize 取）
    override var fittingSize: NSSize {
        NSSize(width: super.fittingSize.width, height: preferredHeight)
    }

    var preferredHeight: CGFloat {
        coin.stageHeight + Self.gap + paramsHost.preferredHeight
    }

    /// 分段内嵌（设置窗口）时三块参数区各自的宿主，按 Control / Edge / Motion 顺序 ——
    /// 裸模式（无标题、不铺卡底），由设置窗口各放进一个 Form Section 当普通 Form 行内嵌；
    /// 标题取 `CoinControlSectionView.sectionTitle` 等静态常量（那时实例已建，但宿主要提前拿到）
    var splitGroupViews: [NSView] { [control, edge, motion] }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayout()
    }

    /// 弹窗模式的排布：两块容器上下排（分段内嵌模式下两块由各自宿主容器排，这里直接跳过）
    private func syncLayout() {
        guard !splitHosting, bounds.width > 0 else { return }
        let w = bounds.width
        stageHost.frame = NSRect(x: 0, y: 0, width: w, height: coin.stageHeight)
        paramsHost.frame = NSRect(x: 0, y: coin.stageHeight + Self.gap,
                                  width: w, height: paramsHost.preferredHeight)
    }
}

/// 预览框内容（设置窗口「分段内嵌」用）：只装 3D 舞台本体。
/// 高度 = 舞台高（随 size / thickness 参数收窄），宽度铺满行内容区 ——
/// 于是承载它的那个 Form Section 的卡片就是「3D 预览框」本身，不再包裹下方表单。
final class CoinStageHostView: NSView {
    let coin: Coin3DView

    override var isFlipped: Bool { true }

    init(coin: Coin3DView) {
        self.coin = coin
        super.init(frame: .zero)
        addSubview(coin)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 行高由舞台高决定（手工 frame 布局的视图不参与 SwiftUI 自适应，靠 fittingSize 报高）
    override var fittingSize: NSSize {
        NSSize(width: super.fittingSize.width, height: coin.stageHeight)
    }

    /// 与改造前面板 `setFrameSize → syncLayout` 同口径：frame 一变就摆硬币，
    /// 不依赖 AppKit 是否判定「需要 layout」（相等尺寸重复设置时它不一定会调 `layout()`）
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncCoin()
    }

    override func layout() {
        super.layout()
        syncCoin()
    }

    private func syncCoin() {
        // 高度取 `coin.stageHeight`（不是 bounds.height）：与改造前面板的
        // `coin.frame = (0, 0, w, stageHeight)` 完全同口径 —— 舞台高变了而 SwiftUI
        // 那一拍还没重新量高时，硬币仍按自己的舞台居中，不会因行高滞后而偏心
        coin.frame = NSRect(x: 0, y: 0, width: bounds.width, height: coin.stageHeight)
    }
}

/// 表单框内容（设置窗口「分段内嵌」用）：只装 Control / Edge / Motion 三块参数区
/// （每块自带标题 + 卡片，块内排布仍由 `CoinFormSectionView` 自己负责）。
/// 高度 = 三块自然高之和 + 块间距；宽度铺满行内容区。
final class CoinParamsHostView: NSView {
    private let scroll: NSScrollView
    private let stack: CoinParamsStackView
    private let sections: [CoinFormSectionView]
    private let gap: CGFloat

    override var isFlipped: Bool { true }

    init(scroll: NSScrollView, stack: CoinParamsStackView,
         sections: [CoinFormSectionView], gap: CGFloat) {
        self.scroll = scroll
        self.stack = stack
        self.sections = sections
        self.gap = gap
        super.init(frame: .zero)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 三块参数区自然总高（含块间距）
    var preferredHeight: CGFloat {
        sections.reduce(0) { $0 + $1.preferredHeight }
            + gap * CGFloat(max(sections.count - 1, 0))
    }

    override var fittingSize: NSSize {
        NSSize(width: super.fittingSize.width, height: preferredHeight)
    }

    /// 同 `CoinStageHostView`：frame 一变就摆三块参数区（不依赖 AppKit 的 layout 判定）
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSections()
    }

    override func layout() {
        super.layout()
        syncSections()
    }

    private func syncSections() {
        guard bounds.width > 0 else { return }
        let w = bounds.width
        // 参数区视口 = 自然高：整卡高度随内容（2026-09-13 用户要求不固定高度），
        // NSScrollView 保留做容器但永不滚动
        scroll.frame = bounds
        // 滚动内容（documentView）：宽度铺满、高度 = 三块参数区自然高之和。
        // 翻转坐标下 origin 在顶，NSScrollView 从顶端开始显示
        stack.frame = NSRect(x: 0, y: 0, width: w, height: preferredHeight)
        var y: CGFloat = 0
        for section in sections {
            section.frame = NSRect(x: 0, y: y, width: w, height: section.preferredHeight)
            y += section.preferredHeight + gap
        }
    }
}

// MARK: - 弹窗

/// 面板「操作」磁贴入口：玻璃模态壳里放一枚可点按自旋 / 可拖动翻转的 3D 硬币，
/// 下方 Control（预设 / 颜色 / 尺寸 / logo）、Edge（厚度 / 边纹）与 Motion
/// （静止俯仰 / 静止朝向 / 自旋圈数）三个参数区装进**一个定高滚动容器**（用户
/// 2026-09-11 指定），「保存 / 关闭」按钮固定在壳 footer。
/// 调参实时上币并实时同步主面板内嵌小硬币；点「保存」把当前参数落盘为默认，
/// 没保存就关（关闭 / Esc）则改动不保留。交互口径照 mintform demo：
/// 点击自旋、横向拖动转向、纵向拖动俯仰、空格再转、Esc 关闭。
@MainActor
enum CoinDemoDialog {
    /// 入口磁贴（PanelLayout 的「3D 硬币」）与弹窗 header 共用的 SF Symbol：
    /// 面板磁贴画的是它，弹窗 header 就必须是同一个（用户 2026-09-11 指定），别各写各的字面量。
    static let tileSymbol = "rotate.3d"

    /// `onClose`：弹窗收起后回调（保存 / 关闭 / Esc 都走）——外部在此解除面板保活并复位
    /// 内嵌小硬币；「保存」的落盘在本函数内部按按钮索引判断。
    static func present(onClose: (() -> Void)? = nil) {
        // 弹窗已在屏：焦点还给它，不叠第二个窗口、不重建面板视图
        if GlassModalShell.hasActiveNonModalSession {
            GlassModalShell.focusActiveNonModal()
            return
        }
        let shell = GlassModalShell()
        shell.setWindowTitle("3D 硬币")
        shell.addHeader(title: "3D 硬币", info: NSAttributedString(
            string: "复刻自 mintform 的 CSS 3D token。点击硬币播放旋转，按住拖动可自由翻转，"
                + "参数区可滚动，「保存」把当前参数存为默认。",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]),
            symbol: tileSymbol)
        let panel = CoinDemoPanelView(frame: .zero)
        shell.addContent(panel, height: panel.preferredHeight)
        shell.firstResponder = panel.coin
        // 按钮从右往左排：先加的在最右 → 关闭最右、保存在其左边（用户指定）；
        // 回车 = 保存（主操作强调色），Esc = 关闭（绑在「关闭」上，不动盘）
        shell.addButton("关闭", keyEquivalent: "\u{1b}")
        shell.addButton("保存", keyEquivalent: "\r", primary: true)
        // 非阻塞呈现：主面板保持可操作（用户 2026-09-11 指定）；「保存」在关闭回调里落盘
        shell.presentNonModal { index in
            if index == 1 {
                panel.persistDefaults()
            }
            onClose?()
        }
    }
}

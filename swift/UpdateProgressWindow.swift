// UpdateProgressWindow.swift — 自更新窗口（高度自适应状态机：发现新版/安装/失败）
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 对外类型   UpdateProgressWindowController（@MainActor，AppDelegate 持有复用）
// 状态机     Phase：.available / .installing / .failed
//            （检查阶段在后台静默进行；无新版/网络故障由调用方用 NSAlert 呈现，
//              本窗口只在「发现新版本」后才出现）
// 对外 API   showUpdateAvailable(version:current:notes:onInstall:onLater:)（唯一拉起入口）
//            beginInstall(version:)（进入安装态：仅切可见性，不重置窗口/日志/标题以外的任何东西）
//            showFailure(title:message:onRetry:)（错误进副标题 + 重试/手动下载/关闭）
//            report(_:) / reporter（进度通道，回调在 delegate 队列，内部切主线程）
//            closeWindow() / isVisible
// 视图层级   NSGlassEffectView（整窗一块 regular 玻璃，Liquid Glass 窗口）
//            └ root：header（应用图标 + 标题 + 副标题）→ content（更新描述框 | 进度描述+进度条）
//              → footer（上下文按钮，右对齐）→ InnerGlowView（内发光 + 彩色流光覆层，
//                最上层恒穿透；一层 alpha 遮罩 + 两层反向旋转的锥形渐变）
// 描述框     ConcentricScrollView：hover 卡片同款皮肤（暗色渐变 白@8%→5% 斜向 +
//            白@18% 1.2pt 描边），高度按内容实高自适应、封顶 150pt，超出框内滚动
// 高度       窗口高度随 Phase 与描述实高自动伸缩（relayoutAndResize 唯一入口，
//            保持左上角不动），宽度固定 440
// 取消标志   UpdateCancelFlag（NSLock 保护；供 URLSession delegate 队列跨线程读）
//
// ⚠️ 稳定性约束：高度只经 relayoutAndResize 一处重算（Phase 切换/描述变更时），
//    状态切换绝不重建视图 / 重复 center —— 这是消除「窗口被重置、闪烁」的根本设计。
//    按钮互斥可见性由 Phase 保证：每个 Phase 只显示自己那组按钮，keyEquivalent 不冲突。

import AppKit

/// 翻转坐标系的容器（从上往下排布）
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 窗口内发光 + 彩色流光（CSS `box-shadow: inset 0 0 Npx <color>` 的 AppKit 等价物，
/// 颜色还沿窗口边缘流转——iOS「AI 呼出」那圈渐变彩光）。
///
/// ① 内发光本体：AppKit / CALayer 都没有 insetShadow 属性（`shadow*` 一律是外阴影），
///    所以用 CG 阴影的「反相填充」把光晕打进窗口内侧：
///      · clip 到窗口形状（圆角矩形）；
///      · 画一条 even-odd 环形路径 = 视界外的大矩形 − 窗口形状 —— 填充区整块落在
///        裁剪区之外，自身颜色被裁得干干净净，只剩它投出的阴影会越过形状边界
///        往窗口内侧扩散 → 边缘亮、向内 N pt 渐隐的内发光。
/// ② 彩色流转：上一步的光晕只渲染**一次**成一张「只有 alpha 有意义」的位图当遮罩，
///    底下垫两层反向旋转的锥形渐变（`.conic`）——颜色因此沿着边缘跑圈，而浓淡/半径
///    仍由那张遮罩说了算（不再每帧重绘阴影，旋转全交给 Core Animation）。
///    两层反向且周期互质：单层是「匀速转色轮」，反向叠一层才像 iOS AI 那样颜色互相
///    追着走、交汇处缓慢演化，也不会看出循环。
///
/// ③ 波浪起伏：把阴影的**光源形状**换成「沿周向正弦调制的圆角矩形」（极角射线 ×
///    距离场二分求零点，再叠 `振幅 × sin(波数×θ + 相位)`），边缘因而起伏；流速 > 0 时
///    相位逐帧推进（每帧重渲遮罩位图，所以遮罩按 1x 渲染——低频模糊图放大无差，快 3 倍）。
///
/// 挂在 root 最上层，`hitTest` 恒 nil：纯装饰，点击 / tooltip / 拖窗全归下层。
private final class InnerGlowView: NSView {

    /// 模糊半径（pt）= CG 阴影的 blur：边缘向内这个宽度完成亮→透的过渡，越小边越硬。
    /// 光晕「到达深度」= 模糊 + 伸展（没有单独的半径参数，两个加起来才是它伸多远）
    var glowBlur: CGFloat = 32
    /// 光晕浓度：边缘处约为此值的一半（高斯核在源边界取 50%），向内衰减。
    /// 注意这是**单层**的浓度，两层叠加后的边缘实际 alpha 约为 1.8 倍（0.50 → ≈0.36）
    var glowAlpha: CGFloat = 0.50
    /// 光晕伸展（pt）≈ CSS `inset 0 0 <blur> <spread>` 的 spread：>0 时把阴影源边界整体
    /// 推到窗口外，边缘向内该深度先保持平台亮度、之后才开始模糊（更实、更厚的一圈）。
    /// ⚠️ 不能为负：源形状一旦缩进窗口内，环形填充就落在裁剪区里被实心画成黑框。
    var glowSpread: CGFloat = 0
    /// 波浪振幅（pt）：0 = 光滑圆角矩形光晕，>0 = 边缘沿周向起伏 ±该值。
    /// 波浪的**基准**光源被推到「窗口外 伸展 + 振幅」处，所以波谷也永远落在窗口外
    /// （⚠️ 源形状一旦缩进窗口，环形填充会被裁进画面变成实心黑框，同 glowSpread 那条）。
    /// 代价：一起伏就把到达深度撑到「模糊 + 伸展 + 2×振幅」——调试面板标题里实时报。
    var waveAmplitude: CGFloat = 0
    /// 波浪数：整圈波峰个数（取整才能闭合，否则首尾错位一道硬缝）
    var waveLobes: Int = 12
    /// 波浪流速（弧度/秒）：>0 = 波浪沿边缘流动，此时每帧重渲遮罩位图
    /// （遮罩按 1x 渲染，实测 ≈4ms/帧，30fps 占单核约一成）；0 = 静止，零额外开销
    var waveSpeed: Double = 0
    /// 当前波浪相位（弧度）；静止时固定 0，流动时由定时器推进
    private var wavePhase: Double = 0
    /// 裁切用圆角：titled 窗口是系统 r16 continuous（与 GlassModalShell 同口径）。
    /// 正圆 r16 与系统 continuous r16 的差别经实测可忽略——对角线边界 4.69 vs 4.66pt、
    /// 顶边圆角起点 15.8 vs 22.6pt（后者由窗口自身裁切兜住，亚像素级），
    /// 故不必为此引入 SwiftUI 的 continuous 路径。
    var cornerRadius: CGFloat = 16
    /// 色环转一圈的耗时（秒）；两层分别按此值与 1.73 倍反向旋转
    var cycleDuration: CFTimeInterval = 4
    /// 流转色环：**首尾必须同色**，否则转一圈会看到一道硬缝
    var palette: [NSColor] = [.systemGreen, .systemTeal, .systemBlue, .systemIndigo,
                              .systemPurple, .systemPink, .systemOrange, .systemGreen]

    override var isFlipped: Bool { true }

    /// 纯装饰层：恒不命中，事件穿透到下层视图 / 窗口背景
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 两层反向旋转的锥形渐变（上层半透明做加权混合，颜色才不会硬切）
    private let spinCW = CAGradientLayer()
    private let spinCCW = CAGradientLayer()
    /// 内发光遮罩：由 CG 阴影反相填充渲染成图，只有尺寸变化时才重画
    private let glowMask = CALayer()
    /// 已渲染遮罩的**点**尺寸（1x 渲染，无 backing scale 因子）：变了才重画
    private var maskKey: NSSize = .zero
    private static let spinKey = "glowSpin"
    /// 波浪流动定时器：只在「流速 > 0 且有振幅」时存在，窗口不可见时只空转不重渲
    private var waveTimer: Timer?
    private var lastWaveTick: CFTimeInterval = 0
    /// 波浪流动帧率（1x 位图 ≈4ms/帧，30fps 有余量）
    private static let waveFPS: Double = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        for (i, spin) in [spinCW, spinCCW].enumerated() {
            spin.type = .conic
            // 0 角朝上（实测：startPoint=中心、endPoint 指向正上方即 0 角，location 增大顺时针）
            spin.startPoint = CGPoint(x: 0.5, y: 0.5)
            spin.endPoint = CGPoint(x: 0.5, y: 0)
            spin.locations = (0..<palette.count).map {
                NSNumber(value: Double($0) / Double(palette.count - 1))
            }
            spin.opacity = i == 0 ? 1 : 0.55
        }
        glowMask.contentsGravity = .resize
        applyColors()
    }

    /// 动态色（system*）随外观解算，外观一变（系统深浅 / 应用内浅色主题）重取
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// 色环取色：交给 Palette 按本视图生效外观解算（动态色的 CGColor 是快照）
    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cg = palette.map { Palette.borderCGColor($0, in: self) }
        spinCW.colors = cg
        spinCCW.colors = cg
        CATransaction.commit()
    }

    /// 尺寸变化（唯一布局入口 relayoutAndResize 里赋 frame）→ 重钉层几何
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutLayers()
    }

    /// 移动窗口 / 外观重建 backing layer 后层可能被丢掉，这里自愈重挂
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayoutLayers()
        syncWaveTimer()          // 离开窗口时停流动定时器（顺带打破 Timer 对 self 的强引用）
    }

    private func relayoutLayers() {
        guard let host = layer, bounds.width > 1, bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if spinCW.superlayer !== host { host.addSublayer(spinCW) }
        if spinCCW.superlayer !== host { host.addSublayer(spinCCW) }
        if host.mask !== glowMask { host.mask = glowMask }

        // 旋转的锥形渐变必须始终盖满整个矩形 → 取外接正方形（转任意角度都不露边）；
        // 正方形与视图同心，startPoint(0.5,0.5) 因此仍落在窗口中心
        let side = ceil((bounds.width * bounds.width + bounds.height * bounds.height).squareRoot())
        let square = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side)
        spinCW.frame = square
        spinCCW.frame = square
        glowMask.frame = bounds

        // 遮罩固定按 1x 渲染：内容本就是 32pt 量级的模糊渐变（低频），路径光栅化自带抗锯齿，
        // 放大看不出差别；而位图小 4 倍 → 重渲 ≈4ms（2x 要 14ms），波浪才可能逐帧流动
        glowMask.contentsScale = 1
        if maskKey != bounds.size {
            maskKey = bounds.size
            glowMask.contents = makeGlowMaskImage(size: bounds.size)
        }
        CATransaction.commit()
        startSpinIfNeeded()
    }

    /// 顺时针 1 圈 / 逆时针 1 圈 —— 两层反向且周期互质（1 : 1.73），图案肉眼不见循环。
    /// 用 `animation(forKey:)` 判空而不是布尔开关：层被重建时动画会一并丢失，这里能自愈
    private func startSpinIfNeeded() {
        if spinCW.animation(forKey: Self.spinKey) == nil {
            // 动画一律按「1 秒 1 圈」的基准挂，实际快慢交给 layer.speed 缩放 ——
            // 改 duration 要重挂动画、相位会弹回 0 角（调试面板拖动时最明显）
            addSpin(to: spinCW, turns: 1)
            addSpin(to: spinCCW, turns: -1)
        }
        applyRate()
    }

    /// 参数改动后调它：`redrawMask` = 模糊/浓度/伸展/波浪变了（要重渲遮罩位图）；
    /// 只改转速时传 false，省掉整窗位图重绘。波浪流速另需起停定时器。
    func applyTuning(redrawMask: Bool) {
        if redrawMask { redrawMaskContents() } else { applyRate() }
        syncWaveTimer()
    }

    /// 重渲遮罩位图（波浪流动时每帧走这条）
    private func redrawMaskContents() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowMask.contents = makeGlowMaskImage(size: bounds.size)
        CATransaction.commit()
    }

    /// 起停波浪流动定时器：条件是「流速 > 0 + 有振幅 + 视图在窗口里」——
    /// 振幅为 0 时波浪退化成光滑矩形，没必要跑；视图离开窗口时停掉，顺带打破 Timer 的强引用环。
    private func syncWaveTimer() {
        let want = waveSpeed > 0 && waveAmplitude > 0.05 && window != nil
        if want, waveTimer == nil {
            lastWaveTick = CACurrentMediaTime()
            // selector 式（闭包式在 Swift 6 严格并发下要跨 actor hop）；
            // common 模式保证拖动滑块 / 滚动期间不暂停
            let t = Timer(timeInterval: 1 / Self.waveFPS, target: self,
                          selector: #selector(onWaveTick), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            waveTimer = t
        } else if !want {
            waveTimer?.invalidate()
            waveTimer = nil
        }
    }

    /// 推进波浪相位并重渲遮罩。窗口不可见时只走时钟不重渲（隐藏后 CPU 归零）
    @objc private func onWaveTick() {
        let now = CACurrentMediaTime()
        defer { lastWaveTick = now }
        guard window?.isVisible == true else { return }
        wavePhase += waveSpeed * min(0.2, now - lastWaveTick)
        redrawMaskContents()
    }

    private func applyRate() {
        setRate(spinCW, rate: 1 / cycleDuration)
        setRate(spinCCW, rate: 1 / (cycleDuration * 1.73))
    }

    /// 改 `speed` 会换掉 layer 的局部时间映射（`局部 = (父时间 − beginTime) × speed + timeOffset`），
    /// 不补偿就等于把色环瞬间拨到别的角度。先读当前局部时间，再令新映射在「此刻」正好取到
    /// 同一个值 → 相位连续，只有快慢变（beginTime 用父层时间空间，故经 superlayer 换算）。
    private func setRate(_ layer: CALayer, rate: Double) {
        guard rate > 0 else { return }
        let now = CACurrentMediaTime()
        let local = layer.convertTime(now, from: nil)
        layer.speed = Float(rate)
        layer.timeOffset = 0
        layer.beginTime = (layer.superlayer?.convertTime(now, from: nil) ?? now) - local / rate
    }

    private func addSpin(to layer: CALayer, turns: Double) {
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = turns * 2 * Double.pi
        anim.duration = 1
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: Self.spinKey)
    }

    /// 把内发光光晕渲染成一张「只有 alpha 有意义」的位图（RGB 留黑），供 CALayer.mask 用。
    /// 按点尺寸 1x 渲染（理由见 relayoutLayers），blur / 振幅单位都是 pt。
    private func makeGlowMaskImage(size: NSSize) -> CGImage? {
        let pxW = Int(ceil(size.width)), pxH = Int(ceil(size.height))
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        let shape = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                           cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(shape)
        ctx.clip()
        // 阴影源形状（伸展 + 波浪）：整体推到窗口外 offset 距离，边缘因此先有一段平台亮度；
        // 波浪的基准里含振幅本身，波谷才落不到窗口内
        // ⚠️ 负的伸展会把源形状缩进窗口内 → 环形填充落进裁剪区被实心画成黑框，故下限 0
        let spread = max(0, glowSpread)
        let amp = max(0, waveAmplitude)
        let offset = spread + amp
        let sourceRect = rect.insetBy(dx: -offset, dy: -offset)
        let sourceShape: CGPath
        if amp > 0.05 {
            sourceShape = Self.wavyShape(rect: sourceRect, cornerRadius: cornerRadius + offset,
                                         amplitude: amp, lobes: max(1, waveLobes), phase: wavePhase)
        } else if spread == 0 {
            sourceShape = shape
        } else {
            sourceShape = CGPath(roundedRect: sourceRect, cornerWidth: cornerRadius + spread,
                                 cornerHeight: cornerRadius + spread, transform: nil)
        }
        // 环形路径：视界外大矩形 − 阴影源形状（even-odd 填充即得环）
        let overflow = glowBlur * 4 + offset
        let ring = CGMutablePath()
        ring.addRect(rect.insetBy(dx: -overflow, dy: -overflow))
        ring.addPath(sourceShape)
        ctx.addPath(ring)
        ctx.setShadow(offset: .zero, blur: glowBlur, color: CGColor(gray: 0, alpha: glowAlpha))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))   // 任意不透明色：填充被 clip 裁掉，只留阴影
        ctx.drawPath(using: .eoFill)
        return ctx.makeImage()
    }

    /// 波浪形圆角矩形路径：SDF 二分求边界 → **按弧长**等距重采样 → 沿外法向（SDF 梯度）
    /// 叠正弦调制。
    /// ⚠️ 不用「内缩矩形 ⊕ 圆盘」的支撑函数：中心对称凸集的支撑函数可加，射线交点距离却
    /// 不可加（45° 方向两者差 6pt），角落曲率会算歪。
    /// ⚠️ 不直接按极角调制：`dy/dθ = (w/2)·sec²θ` 在长边中点小、靠角时大 2 倍多，沿极角
    /// 均匀的正弦视觉上「中间密、两头疏」——只有按弧长才是真波浪（流动速度也才均匀）。
    private static func wavyShape(rect: CGRect, cornerRadius rc: CGFloat,
                                  amplitude amp: CGFloat, lobes: Int, phase: Double) -> CGPath {
        let path = CGMutablePath()
        let hw = rect.width / 2, hh = rect.height / 2
        guard hw > 2, hh > 2 else { return path }
        let r = min(max(0, rc), min(hw, hh))
        let cx = rect.midX, cy = rect.midY
        let tMax = max(hw, hh) * 1.6 + r

        // ① 极角细采样（距离场二分）求边界点列 + 累计弧长：细到 ≈1pt 一段，
        //    线性插值的折线误差 ≈ 弦高 (1pt)²/8R，对 16pt 圆角是 0.008pt，可忽略
        let perim = 2 * (rect.width + rect.height - 4 * r) + 2 * .pi * r
        let fine = max(384, min(4000, Int(perim)))
        var px = [CGFloat](repeating: 0, count: fine)
        var py = [CGFloat](repeating: 0, count: fine)
        var acc = [CGFloat](repeating: 0, count: fine)
        var total: CGFloat = 0
        for i in 0..<fine {
            let th = 2 * Double.pi * Double(i) / Double(fine)
            let ux = CGFloat(cos(th)), uy = CGFloat(sin(th))
            var lo: CGFloat = 0, hi = tMax
            for _ in 0..<20 {
                let mid = (lo + hi) / 2
                if roundedRectSDF(cx + mid * ux, cy + mid * uy, cx, cy, hw, hh, r) < 0 {
                    lo = mid
                } else { hi = mid }
            }
            let t = (lo + hi) / 2
            let x = cx + t * ux, y = cy + t * uy
            if i > 0 {
                total += ((x - px[i - 1]) * (x - px[i - 1]) + (y - py[i - 1]) * (y - py[i - 1])).squareRoot()
            }
            px[i] = x; py[i] = y; acc[i] = total
        }

        // ② 按等弧长重采样，沿外法向调制（步长 ≈1.5pt）
        let n = max(96, min(2400, Int(total / 1.5)))
        let step = total / CGFloat(n)
        var k = 0
        for j in 0..<n {
            let s = CGFloat(j) * step
            while k + 2 < fine && acc[k + 1] < s { k += 1 }
            let span = acc[k + 1] - acc[k]
            let f = span > 0 ? (s - acc[k]) / span : 0
            let bx = px[k] + (px[k + 1] - px[k]) * f
            let by = py[k] + (py[k + 1] - py[k]) * f
            // 外法向 = 距离场梯度（中心差分；凸集外侧 d 递增，故梯度朝外）
            let e: CGFloat = 0.5
            let gx = roundedRectSDF(bx + e, by, cx, cy, hw, hh, r)
                - roundedRectSDF(bx - e, by, cx, cy, hw, hh, r)
            let gy = roundedRectSDF(bx, by + e, cx, cy, hw, hh, r)
                - roundedRectSDF(bx, by - e, cx, cy, hw, hh, r)
            let gl = (gx * gx + gy * gy).squareRoot()
            guard gl > 1e-6 else { continue }
            // 振幅按弧长参数化调制：整数波数 → 首尾天然接上，closeSubpath 无硬缝
            let d = amp * CGFloat(sin(2 * Double.pi * Double(lobes) * Double(j) / Double(n) + phase))
            let p = CGPoint(x: bx + gx / gl * d, y: by + gy / gl * d)
            if j == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// 圆角矩形有符号距离场：内部为负、边界 0、外部为正
    private static func roundedRectSDF(_ x: CGFloat, _ y: CGFloat,
                                       _ cx: CGFloat, _ cy: CGFloat,
                                       _ hw: CGFloat, _ hh: CGFloat, _ r: CGFloat) -> CGFloat {
        let qx = abs(x - cx) - hw + r
        let qy = abs(y - cy) - hh + r
        let lx = max(qx, 0), ly = max(qy, 0)
        return min(max(qx, qy), 0) + (lx * lx + ly * ly).squareRoot() - r
    }
}

/// 日志区滚动容器：圆角交给 macOS 27 的 cornerConfiguration ——
/// .containerConcentric 让内层圆角自动跟随玻璃窗口外形保持同心（而非写死数值）。
/// 两个 override 均为 27-only：macOS 26 上系统不会派发，圆角回落为直角。
private final class ConcentricScrollView: NSScrollView {
    /// 外观切换（系统深浅 / 应用内浅色主题）回调：层的 CGColor 是解算后的快照，
    /// 描述框描边与渐变底借此重解（见 UpdateProgressWindowController.applyNotesBoxSkin）
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .uniformCorners(radius: .containerConcentric(8))
    }

    @available(macOS 27.0, *)
    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        wantsLayer = true
        layer?.masksToBounds = true
        if let radii = effectiveCornerRadii {
            layer?.cornerRadius = radii.topLeft
        }
    }
}

/// 跨线程取消标志：下载 delegate 在后台队列轮询它
final class UpdateCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }

    func reset() {
        lock.lock(); flag = false; lock.unlock()
    }
}

// MARK: - 窗口控制器

/// 自更新单一窗口：发现新版（更新日志 + 确认）→ 下载（字节/速度）→ 校验 → 安装重启
/// 全程在此呈现，失败反馈也在此呈现，全程非模态、零额外弹窗。
/// 检查阶段在后台静默进行（无新版/网络故障由调用方 NSAlert 呈现），
/// 本窗口只在发现新版后才出现。固定尺寸 + Phase 状态机：状态切换只切可见性/文本，
/// 窗口永不重置（见文件头铁律）。
@MainActor
final class UpdateProgressWindowController: NSObject, NSWindowDelegate {

    /// 窗口生命周期阶段。切换入口只有 3 个公开方法，各自负责文本与按钮，非法组合不可表达。
    enum Phase { case available, installing, failed }

    private enum Metrics {
        static let width: CGFloat = 440
        static let pad: CGFloat = 24
        static let headerH: CGFloat = 68
        /// footer 按钮高
        static let footerButtonH: CGFloat = 26
        /// footer 区域高 = 按钮高：按钮贴区域底（局部 y=0），区域底距窗口下边缘 = pad(24)
        /// → 按钮下缘与窗口下边缘正好 24pt。
        /// ⚠️ 别把 footerH 调大于 footerButtonH——多出来的高度会变成按钮下方的死空间
        /// （曾设 30 导致下间隔 28pt，2026-09-10 用户要求改回 24）
        static let footerH: CGFloat = footerButtonH
        /// 进度区：进度条 8 + 间距 8 + 描述行 16
        static let progressH: CGFloat = 32
        static let blockGap: CGFloat = 14
        /// header 与内容区（描述框）间距
        static let headerContentGap: CGFloat = 9   // 文本框与上方 header 间距（18 缩一半）
        /// 更新描述框高度：内容实高自适应，[保底, 封顶]
        static let notesMinH: CGFloat = 64
        static let notesMaxH: CGFloat = 150
        /// 发光参数调试区（仅演示窗口显示，生产流程 0 高度）：
        /// 标题 14 + 间距 6 + 行高/行距 × 行数（行数取 tuningSpecs，
        /// 内容总高见控制器上的 `tuningContentH`——不能在这里引用 tuningSpecs：
        /// 它是 @MainActor 隔离的，非隔离的常量上下文里引用会被 Swift 6 判错）
        static let tuningTitleH: CGFloat = 14
        static let tuningRowH: CGFloat = 20
        static let tuningRowGap: CGFloat = 6
        /// footer 与调试区之间的间距
        static let tuningGap: CGFloat = 18
    }

    /// 调试区内容高（行数跟着 tuningSpecs 走，一处定义不漂移）
    private var tuningContentH: CGFloat {
        let n = CGFloat(Self.tuningSpecs.count)
        return Metrics.tuningTitleH + 6 + Metrics.tuningRowH * n + Metrics.tuningRowGap * (n - 1)
    }

    private let win: NSWindow
    private let root = FlippedView()
    private let headerRegion = FlippedView()
    private let contentRegion = FlippedView()
    private let footerRegion = FlippedView()
    /// 窗口内发光覆层：root 最上层，覆满整窗，恒不命中
    private let innerGlow = InnerGlowView()

    // ── 发光参数调试区（只在演示窗口出现；生产流程完全不建不显示）──
    /// 一行调试控件：名称 + 滑块 + 实时数值
    private struct TuningSpec {
        let name: String
        let range: ClosedRange<Double>
        let unit: String
        let decimals: Int
        /// 从 InnerGlowView 读当前值 → 滑块初值（不另抄一份默认值，免得两处漂移）
        let read: (InnerGlowView) -> Double
        let apply: (InnerGlowView, Double) -> Void
        /// 这个参数是否影响遮罩位图（模糊/浓度/伸展要重渲，周期只改速率不用）
        let redrawsMask: Bool
    }

    /// 调试滑块定义（顺序 = 面板行序）。前三行是一组：模糊 + 伸展 = 光晕到达深度；
    /// 后三行是波浪：振幅 + 波数 + 流速。
    /// ⚠️ 行数变化只需改这里 —— 面板高度 `tuningContentH` 跟着 count 走。
    private static let tuningSpecs: [TuningSpec] = [
        TuningSpec(name: "模糊", range: 0...80, unit: "pt", decimals: 0,
                   read: { Double($0.glowBlur) },
                   apply: { $0.glowBlur = CGFloat($1) }, redrawsMask: true),
        TuningSpec(name: "伸展", range: 0...40, unit: "pt", decimals: 0,
                   read: { Double($0.glowSpread) },
                   apply: { $0.glowSpread = CGFloat($1) }, redrawsMask: true),
        TuningSpec(name: "浓度", range: 0...1, unit: "", decimals: 2,
                   read: { Double($0.glowAlpha) },
                   apply: { $0.glowAlpha = CGFloat($1) }, redrawsMask: true),
        TuningSpec(name: "周期", range: 0.5...12, unit: "s", decimals: 1,
                   read: { $0.cycleDuration },
                   apply: { $0.cycleDuration = $1 }, redrawsMask: false),
        TuningSpec(name: "波幅", range: 0...12, unit: "pt", decimals: 1,
                   read: { Double($0.waveAmplitude) },
                   apply: { $0.waveAmplitude = CGFloat($1) }, redrawsMask: true),
        TuningSpec(name: "波数", range: 1...48, unit: "", decimals: 0,
                   read: { Double($0.waveLobes) },
                   apply: { $0.waveLobes = max(1, Int($1.rounded())) }, redrawsMask: true),
        TuningSpec(name: "流速", range: 0...3, unit: "rad/s", decimals: 2,
                   read: { $0.waveSpeed },
                   apply: { $0.waveSpeed = $1 }, redrawsMask: false),
    ]

    private let tuningRegion = FlippedView()
    private let tuningTitle = NSTextField(labelWithString: "发光参数")
    private var tuningNames: [NSTextField] = []
    private var tuningSliders: [NSSlider] = []
    private var tuningValues: [NSTextField] = []
    /// 每个滑块的上一轮取值（与 tuningSpecs 同序）：用来识别"这一轮到底哪个参数变了"
    private var tuningLast: [Double] = []
    /// 本次呈现是否带调试区（`showUpdateAvailable` 传入）：唯一开关，默认关
    private var glowTuning = false

    // header
    private let iconView = NSImageView()
    /// icon 高度常量约束（宽度 = 高度）：尺寸由 relayoutAndResize 按副标题实测行数更新
    private var iconHeightConstraint: NSLayoutConstraint!
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerSubtitle = NSTextField(labelWithString: "")
    // content：两块互斥/组合显示
    private let notesScroll = ConcentricScrollView()
    private let notesView = NSTextView()
    private let progressBlock = FlippedView()
    private let bar = NSProgressIndicator()
    private let detailLine = NSTextField(labelWithString: "")
    // footer：按 Phase 互斥可见
    private let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
    private let retryBtn = NSButton(title: "重试", target: nil, action: nil)
    private let manualBtn = NSButton(title: "手动下载", target: nil, action: nil)
    private let closeBtn = NSButton(title: "关闭", target: nil, action: nil)
    private let installBtn = NSButton(title: "立即更新", target: nil, action: nil)
    private let laterBtn = NSButton(title: "稍后再说", target: nil, action: nil)

    /// 描述框背景：hover 卡片同款渐变（暗色 白@8%→5% 斜向），挂 scroll layer 最底层
    private let notesBackdrop = CAGradientLayer()
    /// 描述框当前高度（relayoutAndResize 按文本实高计算，[64,150] 夹取）
    private var notesContentH: CGFloat = Metrics.notesMinH
    private let cancelFlag = UpdateCancelFlag()
    private var phase: Phase = .available
    private var retryHandler: (() -> Void)?
    private var installHandler: (() -> Void)?
    private var laterHandler: (() -> Void)?
    /// 日志文本框是否已填充（失败态据此决定是否显示日志区）
    private var notesLoaded = false
    /// 仅首次 present 时 center；用户挪动过窗口后不再强行归中（消除「位置重置」感）
    private var hasShown = false

    /// 窗口当前是否可见
    var isVisible: Bool { win.isVisible }

    /// 传给 UpdateService 的进度通道：回调来自 URLSession delegate 队列，内部统一切主线程
    private(set) lazy var reporter: UpdateReporter = UpdateReporter(
        report: { [weak self] p in
            Task { @MainActor in self?.apply(p) }
        },
        isCancelled: { [weak self] in self?.cancelFlag.value ?? false }
    )

    /// 标题栏高度（fullSizeContentView 下内容延伸进标题栏区，布局需整体下移避开红绿灯）
    private var titlebarInset: CGFloat = 0

    override init() {
        // 初始高度为占位值：真实高度由 relayoutAndResize 按 Phase + 描述实高计算
        win = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: Metrics.width, height: 320)),
                       styleMask: [.titled, .closable, .fullSizeContentView],
                       backing: .buffered,
                       defer: false)
        super.init()
        win.title = "iBalance 更新"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.backgroundColor = .clear
        win.isOpaque = false
        // 应用内主题：更新窗同样是自建顶层窗口、不在面板视图树上，外观按全局镜像显式设。
        // ⚠️ 必须在 buildUI 之前——描述框的 CALayer 描边/渐变要按窗口生效外观解算
        win.appearance = Palette.topLevelWindowAppearance
        win.delegate = self
        // Liquid Glass 窗口：整窗一块 regular 玻璃（macOS 26+ NSGlassEffectView，
        // 系统 StyleMask 无新增枚举——Tahoe/Golden Gate 的官方组合就是
        // fullSizeContentView + 透明标题栏 + 玻璃根容器）。
        // ⚠️ effectIsInteractive 不开：27 的交互式玻璃会在拖动窗口时实时重采样，
        // 玻璃层与内容层合成节奏偏差 → 内容抖动/滞后感（实测）。按钮 hover 反馈
        // 不依赖它（bezelColor 高亮照常工作）。
        let glass = NSGlassEffectView()
        glass.style = .regular
        win.contentView = glass
        root.frame = glass.bounds
        root.autoresizingMask = [.width, .height]
        glass.contentView = root
        // 红绿灯浮在玻璃上（Tahoe 一体化窗口）：窗口整体加高 titlebarInset，
        // relayoutAndResize 计算总高时会补上这段标题栏高度
        titlebarInset = win.frame.height - win.contentLayoutRect.height
        buildUI()
    }

    /// Release notes 简易 markdown 渲染（不求全，覆盖 GitHub Releases 常见语法）：
    /// - `#`/`##`/`###` 行 → 半粗标题（13/12/11pt）
    /// - `- `/`* ` 列表行 → 「• 」圆点 + 缩进
    /// - `**粗体**` → 半粗；`` `代码` `` → 等宽
    /// - 其余原样；空行保留为段间距
    private static func renderNotes(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        func paraStyle(headIndent: CGFloat) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.headIndent = headIndent
            p.paragraphSpacing = 3
            p.lineBreakMode = .byWordWrapping
            return p
        }
        for rawLine in md.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            var attrs = base
            var indent: CGFloat = 0
            let hashes = line.prefix(while: { $0 == "#" })
            if hashes.count >= 1, line.dropFirst(hashes.count).hasPrefix(" ") {
                line = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                let size: CGFloat = hashes.count == 1 ? 13 : (hashes.count == 2 ? 12 : 11)
                attrs[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
                attrs[.paragraphStyle] = paraStyle(headIndent: 0)
                out.append(NSAttributedString(string: line + "\n", attributes: attrs))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "•  " + line.dropFirst(2)
                indent = 14
            }
            attrs[.paragraphStyle] = paraStyle(headIndent: indent)
            appendInline(line + "\n", base: attrs, to: out)
        }
        return out
    }

    /// 行内扫描：`**粗体**` 与 `` `代码` ``，其余按 base 属性原样输出
    private static func appendInline(_ text: String, base: [NSAttributedString.Key: Any], to out: NSMutableAttributedString) {
        var rest = Substring(text)
        while !rest.isEmpty {
            if let b = rest.range(of: "**") {
                out.append(NSAttributedString(string: String(rest[..<b.lowerBound]), attributes: base))
                rest = rest[b.upperBound...]
                if let e = rest.range(of: "**") {
                    var bold = base
                    if let f = base[.font] as? NSFont { bold[.font] = NSFont.systemFont(ofSize: f.pointSize, weight: .semibold) }
                    out.append(NSAttributedString(string: String(rest[..<e.lowerBound]), attributes: bold))
                    rest = rest[e.upperBound...]
                } else {
                    out.append(NSAttributedString(string: "**", attributes: base))
                }
            } else if let b = rest.range(of: "`") {
                out.append(NSAttributedString(string: String(rest[..<b.lowerBound]), attributes: base))
                rest = rest[b.upperBound...]
                if let e = rest.range(of: "`") {
                    var code = base
                    if let f = base[.font] as? NSFont {
                        code[.font] = NSFont.monospacedSystemFont(ofSize: f.pointSize - 0.5, weight: .regular)
                        code[.foregroundColor] = NSColor.secondaryLabelColor
                    }
                    out.append(NSAttributedString(string: String(rest[..<e.lowerBound]), attributes: code))
                    rest = rest[e.upperBound...]
                } else {
                    out.append(NSAttributedString(string: "`", attributes: base))
                }
            } else {
                out.append(NSAttributedString(string: String(rest), attributes: base))
                return
            }
        }
    }

    // MARK: - 一次性视图构建（横向/内部布局在此定死；纵向几何由 relayoutAndResize 统一排）

    /// 裁掉应用图标四周的透明留白：macOS 图标画布按规范留 ~10% 边距，不裁的话
    /// 图形实边比 frame 顶低一截，视觉上与主标题错位（裁后图形顶=frame 顶）。
    /// 一次性全像素扫描 alpha 包围盒，仅构建时跑一次。
    ///（internal：平台开关窗口 header 图标与更新窗口统一位置/大小时复用）
    static func trimmedAppIcon() -> NSImage? {
        guard let icon = NSApp.applicationIconImage,
              let tiff = icon.tiffRepresentation,
              let src = CGImageSourceCreateWithData(tiff as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return NSApp.applicationIconImage }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return icon }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        var y = 0
        while y < h {
            var x = 0
            let rowBase = y * w * 4
            while x < w {
                if px[rowBase + x * 4 + 3] > 40 {   // 阈值 40：滤掉图标柔和投影的半透明边，只取图形实边
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                x += 1
            }
            y += 1
        }
        guard maxX >= minX, maxY >= minY else { return icon }
        // CGContext 坐标原点在左下，包围盒 y 需翻转成图像坐标
        let cropRect = CGRect(x: minX, y: h - 1 - maxY,
                              width: maxX - minX + 1, height: maxY - minY + 1)
        guard let full = ctx.makeImage(), let cropped = full.cropping(to: cropRect) else { return icon }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    private func buildUI() {
        let pad = Metrics.pad
        let innerW = Metrics.width - pad * 2

        // ── header：应用图标 + 标题 + 副标题（纵向位置由 relayoutAndResize 排）──
        root.addSubview(headerRegion)
        if let appIcon = Self.trimmedAppIcon() {
            iconView.image = appIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
        }
        // 图标纵向几何由 relayoutAndResize 按副标题实际行数动态计算（与文本块同高）
        // header 内部改用与面板卡片同构的 Auto Layout：icon 列 + 文字竖排 stack，
        // 图标尺寸/间距由约束驱动，不再手算 frame / capHeight 光学补偿
        iconView.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerSubtitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        headerTitle.textColor = .labelColor
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerSubtitle.font = .systemFont(ofSize: 11)
        headerSubtitle.textColor = .secondaryLabelColor
        headerSubtitle.lineBreakMode = .byWordWrapping
        headerSubtitle.maximumNumberOfLines = 3
        headerSubtitle.cell?.wraps = true
        headerSubtitle.cell?.isScrollable = false
        headerSubtitle.cell?.truncatesLastVisibleLine = true
        headerSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let infoStack = NSStackView(views: [headerTitle, headerSubtitle])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 2
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        headerRegion.addSubview(iconView)
        headerRegion.addSubview(infoStack)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 42)
        NSLayoutConstraint.activate([
            // icon：贴容器顶（用户定稿），正方形；尺寸常量由 relayoutAndResize 按副标题
            // 实测行数算（不能绑 stack 高度做 multiplier——icon 高→stack 宽→副标题折行→
            // stack 高是循环依赖，求解器会挑任意解，icon 曾被撑到 209pt）
            iconView.leadingAnchor.constraint(equalTo: headerRegion.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: headerRegion.topAnchor),
            iconView.widthAnchor.constraint(equalTo: iconView.heightAnchor),
            iconHeightConstraint,
            // 文字列：icon 右侧 8pt（2026-09-10 用户指定，原 12），顶距 4
            infoStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            infoStack.topAnchor.constraint(equalTo: headerRegion.topAnchor, constant: 4),
            infoStack.trailingAnchor.constraint(equalTo: headerRegion.trailingAnchor),
        ])

        // ── content：更新描述框 + 进度区（纵向布局见 relayoutAndResize）──
        root.addSubview(contentRegion)

        notesView.font = .systemFont(ofSize: 11)
        notesView.textColor = .labelColor
        // 玻璃窗口上日志区不再垫实底：文字直接浮在玻璃上（Liquid Glass 内容层语义）
        notesView.drawsBackground = false
        notesView.backgroundColor = .clear
        notesView.isEditable = false
        notesView.isSelectable = true
        // 富文本开（markdown 渲染靠属性字符串）；不可编辑所以无粘贴富文本副作用
        notesView.isRichText = true
        notesView.isAutomaticQuoteSubstitutionEnabled = false
        notesView.isAutomaticDashSubstitutionEnabled = false
        notesView.isVerticallyResizable = true
        notesView.isHorizontallyResizable = false
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        notesView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        notesView.textContainerInset = NSSize(width: 8, height: 8)
        notesScroll.documentView = notesView
        notesScroll.drawsBackground = false
        notesScroll.hasVerticalScroller = true
        notesScroll.hasHorizontalScroller = false
        notesScroll.autohidesScrollers = true
        notesScroll.wantsLayer = true
        // hover 卡片同款皮肤（动态色，随窗口外观深浅切换）：深色 白@18% 描边 +
        // 白@8%→5% 斜向渐变 / 浅色 黑@18% 描边 + 黑@6% 底（Palette.hoverBorderBright /
        // hoverGradient 取值，与面板 hover 卡片同源）；圆角由
        // ConcentricScrollView.cornerConfiguration（containerConcentric）驱动。
        // 帧/端点/颜色统一由 applyNotesBoxSkin() 上（布局后调用，见 relayoutAndResize）
        notesScroll.layer?.borderWidth = Palette.cardBorderWidth
        notesScroll.layer?.insertSublayer(notesBackdrop, at: 0)
        notesScroll.onEffectiveAppearanceChange = { [weak self] in self?.applyNotesBoxSkin() }
        contentRegion.addSubview(notesScroll)

        // ── 进度区：进度条 + 描述（只显示最新一条进度，无步骤清单）──
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 100
        bar.isIndeterminate = true
        bar.usesThreadedAnimation = true
        bar.frame = NSRect(x: 0, y: 0, width: innerW, height: 8)
        detailLine.font = .systemFont(ofSize: 11)
        detailLine.textColor = .secondaryLabelColor
        detailLine.lineBreakMode = .byTruncatingTail
        detailLine.frame = NSRect(x: 0, y: 16, width: innerW, height: 16)
        for v in [bar, detailLine] { progressBlock.addSubview(v) }
        contentRegion.addSubview(progressBlock)

        // ── footer：按钮（纵向位置由 relayoutAndResize 排）──
        root.addSubview(footerRegion)
        for b in [cancelBtn, retryBtn, manualBtn, closeBtn, installBtn, laterBtn] {
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 13)
            b.target = self
            footerRegion.addSubview(b)
        }
        cancelBtn.action = #selector(onCancel)
        retryBtn.action = #selector(onRetry)
        manualBtn.action = #selector(onManual)
        closeBtn.action = #selector(onClose)
        installBtn.action = #selector(onInstall)
        laterBtn.action = #selector(onLater)
        installBtn.bezelColor = .controlAccentColor
        retryBtn.bezelColor = .controlAccentColor
        installBtn.keyEquivalent = "\r"
        retryBtn.keyEquivalent = "\r"
        laterBtn.keyEquivalent = "\u{1b}"
        cancelBtn.keyEquivalent = "\u{1b}"
        for b in [cancelBtn, retryBtn, manualBtn, closeBtn, installBtn, laterBtn] {
            b.isHidden = true
        }
        notesScroll.isHidden = true
        progressBlock.isHidden = true

        // ── 发光参数调试区（仅演示窗口）：标题 + 每参数一行「名称 | 滑块 | 数值」──
        tuningTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        tuningTitle.textColor = .secondaryLabelColor
        tuningRegion.addSubview(tuningTitle)
        for spec in Self.tuningSpecs {
            let name = NSTextField(labelWithString: spec.name)
            name.font = .systemFont(ofSize: 11)
            name.textColor = .secondaryLabelColor
            let slider = NSSlider(value: spec.read(innerGlow), minValue: spec.range.lowerBound,
                                  maxValue: spec.range.upperBound, target: self,
                                  action: #selector(onTuningChanged))
            slider.isContinuous = true          // 拖动过程中连续回调 → 实时预览
            slider.controlSize = .small
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = .labelColor
            value.alignment = .right
            for v in [name, slider, value] { tuningRegion.addSubview(v) }
            tuningNames.append(name); tuningSliders.append(slider); tuningValues.append(value)
            tuningLast.append(spec.read(innerGlow))     // 初值 = 控件初值，首轮拖动不会误判"变了"
        }
        refreshTuningValues()
        root.addSubview(tuningRegion)
        tuningRegion.isHidden = true

        // ── 内发光覆层：必须最后加入（root 最上层、盖住全部内容）──
        innerGlow.frame = root.bounds
        innerGlow.autoresizingMask = [.width, .height]
        root.addSubview(innerGlow)
    }

    /// 调试滑块拖动中：只处理**值真的变了**的参数（否则表里恒有 redrawsMask=true 的项，
    /// 拖「周期/流速」也会连带重渲整张遮罩位图）
    @objc private func onTuningChanged() {
        var redrawMask = false, changed = false
        for (i, spec) in Self.tuningSpecs.enumerated() {
            let v = tuningSliders[i].doubleValue
            if abs(tuningLast[i] - v) < 1e-9 { continue }
            tuningLast[i] = v
            spec.apply(innerGlow, v)
            changed = true
            if spec.redrawsMask { redrawMask = true }
        }
        guard changed else { return }
        refreshTuningValues()
        innerGlow.applyTuning(redrawMask: redrawMask)
    }

    private func refreshTuningValues() {
        for (i, spec) in Self.tuningSpecs.enumerated() {
            let v = tuningSliders[i].doubleValue
            tuningValues[i].stringValue = String(format: "%.\(spec.decimals)f", v)
                + (spec.unit.isEmpty ? "" : " " + spec.unit)
        }
        // 到达深度没有独立参数：它 = 模糊 + 伸展 + 2×振幅（波浪基准已外推 振幅，波峰再 +振幅），
        // 标题里实时报出来（免得再想「半径去哪了」）
        let reach = Double(innerGlow.glowBlur + innerGlow.glowSpread + 2 * innerGlow.waveAmplitude)
        tuningTitle.stringValue = String(format: "发光参数（仅演示窗口）· 光晕到达 ≈ %.0fpt = 模糊 + 伸展 + 2×波幅",
                                        reach)
    }

    /// 调试区行几何（纵向由 relayoutAndResize 定区域 frame，这里只排区内横向 + 行序）
    private func layoutTuning() {
        guard glowTuning else { return }
        let innerW = tuningRegion.bounds.width
        let nameW: CGFloat = 34, valueW: CGFloat = 58, gap: CGFloat = 8
        let sliderW = max(80, innerW - nameW - valueW - gap * 2)
        tuningTitle.frame = NSRect(x: 0, y: 0, width: innerW, height: Metrics.tuningTitleH)
        for (i, _) in Self.tuningSpecs.enumerated() {
            let y = Metrics.tuningTitleH + 6 + CGFloat(i) * (Metrics.tuningRowH + Metrics.tuningRowGap)
            let textY = y + (Metrics.tuningRowH - 16) / 2      // 文本与滑块行垂直居中
            tuningNames[i].frame = NSRect(x: 0, y: textY, width: nameW, height: 16)
            tuningSliders[i].frame = NSRect(x: nameW + gap, y: y, width: sliderW, height: Metrics.tuningRowH)
            tuningValues[i].frame = NSRect(x: innerW - valueW, y: textY, width: valueW, height: 16)
        }
    }

    // MARK: - 对外状态切换（Phase 的唯一入口）

    /// 发现新版态：更新日志独立滚动文本框 + 立即更新 / 稍后再说。
    /// 点红绿灯关闭 = 稍后再说。
    /// `glowTuning` = true 时窗口底部多出「发光参数」调试区（只有演示流程传 true；
    /// 默认 false → 生产流程的布局、高度、控件集合与之前完全一致）。
    func showUpdateAvailable(version: String, current: String, notes: String,
                             glowTuning: Bool = false,
                             onInstall: @escaping () -> Void,
                             onLater: @escaping () -> Void) {
        cancelFlag.reset()
        self.glowTuning = glowTuning
        notesLoaded = true
        installHandler = onInstall
        laterHandler = onLater
        retryHandler = nil
        headerTitle.stringValue = "发现新版本 v\(version)"
        setSubtitle("校验通过后自动重启应用，配置不受更新影响。")
        notesView.textStorage?.setAttributedString(Self.renderNotes(notes))
        setButtons(choosing: true)
        enter(.available)
    }

    /// 安装态：从发现新版态原地过渡——点「立即更新」后更新日志文本框隐藏
    /// （notesLoaded=false，relayoutAndResize 收起并缩窗高），仅显示进度块 + 换按钮。
    func beginInstall(version: String) {
        cancelFlag.reset()
        installHandler = nil
        laterHandler = nil
        notesLoaded = false
        headerTitle.stringValue = "正在更新到 v\(version)"
        setSubtitle("下载完成后自动校验并重启；校验通过前不会改动当前版本。")
        detailLine.stringValue = ""
        bar.isHidden = false
        bar.isIndeterminate = true
        bar.doubleValue = 0
        bar.startAnimation(nil)
        setButtons(canceling: true)
        enter(.installing)
    }

    /// 失败态：错误信息进副标题（红），重试 / 手动下载 / 关闭
    func showFailure(title: String = "更新未完成",
                     message: String,
                     onRetry: @escaping () -> Void) {
        retryHandler = onRetry
        installHandler = nil
        laterHandler = nil
        headerTitle.stringValue = title
        setSubtitle(message, error: true)
        bar.stopAnimation(nil)
        bar.isHidden = true
        detailLine.stringValue = ""
        setButtons(failing: true)
        enter(.failed)
    }

    /// 调用方直推进度（安装/重启阶段由 AppDelegate 推，不经网络层）
    func report(_ progress: UpdateProgress) {
        apply(progress)
    }

    func closeWindow() {
        retryHandler = nil
        installHandler = nil
        laterHandler = nil
        bar.stopAnimation(nil)
        win.orderOut(nil)
    }

    // MARK: - Phase 切换内核

    private func enter(_ newPhase: Phase) {
        phase = newPhase
        relayoutAndResize()
        layoutFooter()
        present()
    }

    /// 全窗口纵向重排（唯一入口）：按 Phase + 描述实高重算窗口总高并保持左上角不动。
    /// - available：header + 描述框
    /// - installing / failed：header + 描述框 + 间距 + 进度条 + 进度描述
    private func relayoutAndResize() {
        let pad = Metrics.pad
        let innerW = Metrics.width - pad * 2
        let top = titlebarInset + pad
        let showNotes = notesLoaded
        let showProgress = phase == .installing || phase == .failed
        setVisibility(notesScroll, showNotes)
        setVisibility(progressBlock, showProgress)

        // 描述框高度 = 文本实高（含 8pt 上下内边距），[64, 150] 夹取；先按最终宽度
        // 铺设视图再测量，ensureLayout 强制同步排版保证 usedRect 有效
        notesScroll.frame = NSRect(x: 0, y: 0, width: innerW, height: Metrics.notesMaxH)
        notesView.frame = NSRect(x: 0, y: 0,
                                 width: innerW - notesView.textContainerInset.width * 2, height: 10)
        if let lm = notesView.layoutManager, let tc = notesView.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let fitted = used.height + notesView.textContainerInset.height * 2
            notesContentH = min(max(fitted, Metrics.notesMinH), Metrics.notesMaxH)
        }
        // 文本框隐藏时不占空间（2026-09-10 用户确认）：高度与进度块 y 均按 showNotes 计入
        let notesH = showNotes ? notesContentH : 0
        let contentH = notesH + (showProgress ? Metrics.blockGap + Metrics.progressH : 0)
        // 调试区（仅演示窗口）：区域总高 = 间距 + 内容，关闭时为 0 → 生产流程高度分毫不变
        let tuningBlockH = glowTuning ? Metrics.tuningGap + tuningContentH : 0
        setVisibility(tuningRegion, glowTuning)
        // header 实际需要的高（约束求解下一 runloop 才回填 frame，高度计算用同步测量口径）：
        // 顶距 4 + 标题 20 + 间距 2 + 副标题实测高（≤3 行 40 封顶）+ icon 底部溢出 2
        let subW = innerW - 88
        let subFitH = headerSubtitle.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: subW, height: .greatestFiniteMagnitude)).height ?? 40
        // icon 尺寸固定 42（2026-09-10 用户指定，与平台开关窗口统一）
        iconHeightConstraint.constant = 42
        let headerNeeded = 4 + 20 + 2 + min(subFitH, 40) + 2
        // header 高度贴内容（原 68pt 地板会留 12pt 死空间垫在副标题与文本框之间，
        // 视觉上吃掉 headerContentGap 的缩放）；icon 底(≤34)始终在内容高之内
        let headerH = headerNeeded
        let rootH = top + headerH + Metrics.headerContentGap + contentH + 14 + Metrics.footerH + tuningBlockH + pad

        // 窗口高度伸缩：左上角钉住（宽度恒定，高度差在阈值内不动防微抖）
        if abs(win.frame.height - rootH) > 0.5 {
            let topLeft = NSPoint(x: win.frame.minX, y: win.frame.maxY)
            win.setContentSize(NSSize(width: Metrics.width, height: rootH))
            win.setFrameTopLeftPoint(topLeft)
        }

        // 区域纵向几何（root 为翻转坐标，y 自顶向下）
        // header 内部（icon/标题/副标题）由 Auto Layout 约束排布，这里只定容器 frame
        headerRegion.frame = NSRect(x: pad, y: top, width: innerW, height: headerH)
        contentRegion.frame = NSRect(x: pad, y: top + headerH + Metrics.headerContentGap, width: innerW, height: contentH)
        // footer 上方让出调试区；按钮下缘距窗口下边缘因此在演示窗口里是
        // tuningBlockH + pad（生产窗口 tuningBlockH = 0 → 仍为 24pt）
        footerRegion.frame = NSRect(x: pad, y: rootH - pad - tuningBlockH - Metrics.footerH,
                                    width: innerW, height: Metrics.footerH)
        if glowTuning {
            tuningRegion.frame = NSRect(x: pad, y: rootH - pad - tuningContentH,
                                        width: innerW, height: tuningContentH)
            layoutTuning()
        }
        // 内发光覆层覆满整窗 —— 本方法即本文件唯一布局入口，覆层尺寸同样在此钉住
        innerGlow.frame = root.bounds
        layoutFooter()
        notesScroll.frame = NSRect(x: 0, y: 0, width: innerW, height: notesContentH)
        applyNotesBoxSkin()
        if showProgress {
            progressBlock.frame = NSRect(x: 0, y: notesH + Metrics.blockGap,
                                         width: innerW, height: Metrics.progressH)
        }
        applyLayoutDebugSkin()
    }

    // MARK: - 布局调试皮肤（--layout-debug 启动参数开启）

    /// 布局调试开关：启动带 --layout-debug 时，每个容器/文本块描专属色边 + 8% 同色底，
    /// 肉眼核对边距与缩进；正常运行零影响。
    private let layoutDebug = CommandLine.arguments.contains("--layout-debug")
    private static let debugPalette: [NSColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange,
        .systemPurple, .systemTeal, .systemPink, .systemYellow,
    ]

    private func debugSkin(_ view: NSView, _ colorIndex: Int) {
        let c = Self.debugPalette[colorIndex % Self.debugPalette.count]
        view.wantsLayer = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = c.cgColor
        view.layer?.backgroundColor = c.withAlphaComponent(0.08).cgColor
    }

    /// 索引即颜色：0红 header / 1蓝 content / 2绿 描述框 / 3橙 进度区 / 4紫 footer /
    /// 5青 icon / 6粉 标题 / 7黄 副标题
    private func applyLayoutDebugSkin() {
        guard layoutDebug else { return }
        debugSkin(headerRegion, 0)
        debugSkin(contentRegion, 1)
        debugSkin(notesScroll, 2)
        debugSkin(progressBlock, 3)
        debugSkin(footerRegion, 4)
        debugSkin(iconView, 5)
        debugSkin(headerTitle, 6)
        debugSkin(headerSubtitle, 7)
    }

    /// footer 按钮右对齐排布（数组首位 = 最右主操作）。
    /// 「立即更新」在右、「稍后再说」在左（2026-09-10 用户指定换位，主操作贴右缘
    /// 符合 macOS 惯例）；failed 态 close/manual/retry 相对次序不变，installing 态仅取消。
    private func layoutFooter() {
        let ordered: [NSButton] = [closeBtn, manualBtn, retryBtn, installBtn, laterBtn, cancelBtn]
            .filter { !$0.isHidden }
        var x = footerRegion.bounds.width
        for b in ordered {
            b.sizeToFit()
            let bw = max(b.frame.width + 24, 78)
            x -= bw
            b.frame = NSRect(x: x, y: 0, width: bw, height: Metrics.footerButtonH)
            x -= 8
        }
    }

    /// 区域显隐带 0.16s 淡入淡出（帧变化即时，窗口永不跳动）
    private func setVisibility(_ view: NSView, _ visible: Bool) {
        if visible {
            guard view.isHidden else { return }
            view.isHidden = false
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            })
        } else {
            guard !view.isHidden else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                view.animator().alphaValue = 0
            }, completionHandler: { [weak view] in
                view?.isHidden = true
                view?.alphaValue = 1
            })
        }
    }

    private func setSubtitle(_ text: String, error: Bool = false) {
        headerSubtitle.textColor = error ? .systemRed : .secondaryLabelColor
        headerSubtitle.stringValue = text
    }

    /// 按钮组互斥可见性（每 Phase 一组）
    private func setButtons(canceling: Bool) {
        cancelBtn.isHidden = !canceling
        cancelBtn.isEnabled = true
        retryBtn.isHidden = true
        manualBtn.isHidden = true
        closeBtn.isHidden = true
        installBtn.isHidden = true
        laterBtn.isHidden = true
    }

    private func setButtons(choosing: Bool) {
        cancelBtn.isHidden = true
        retryBtn.isHidden = true
        manualBtn.isHidden = true
        closeBtn.isHidden = true
        installBtn.isHidden = !choosing
        laterBtn.isHidden = !choosing
    }

    private func setButtons(failing: Bool) {
        cancelBtn.isHidden = true
        retryBtn.isHidden = !failing
        manualBtn.isHidden = !failing
        closeBtn.isHidden = !failing
        installBtn.isHidden = true
        laterBtn.isHidden = true
    }

    /// 应用内主题切换时重设窗口外观（由 AppDelegate.onToggleLightTheme 调）。
    /// 描述框的层皮肤不在这里手工重解：win.appearance 一变，notesScroll 就走
    /// viewDidChangeEffectiveAppearance → applyNotesBoxSkin 自动跟上
    func applyThemeAppearance() {
        win.appearance = Palette.topLevelWindowAppearance
    }

    /// 更新描述框皮肤：hover 卡片同款斜向渐变底 + 描边，帧/端点/颜色一并上。
    /// 动态色按视图生效外观解算（notesScroll 在窗口层级里，取它即窗口外观）。
    /// ⚠️ CGColor 落盘就定格当时外观——外观切换时由 notesScroll.onEffectiveAppearanceChange
    /// 再调一次，别改成只在 buildUI 里设一遍
    private func applyNotesBoxSkin() {
        notesBackdrop.frame = notesScroll.bounds
        // 渐变端点与 hover 卡片同源（60° 视觉角、任意宽高比不失真）
        let (start, end) = Palette.gradientEndpoints(angleDeg: Palette.hoverGradientAngleDeg,
                                                     in: notesScroll.bounds)
        notesBackdrop.startPoint = start
        notesBackdrop.endPoint = end
        notesScroll.layer?.borderColor =
            Palette.borderCGColor(Palette.hoverBorderBright, in: notesScroll)
        notesBackdrop.colors = Palette.hoverGradient.map {
            Palette.borderCGColor($0, in: notesScroll)
        }
    }

    /// 已可见时直接返回：状态在窗口打开期间切换绝不重新 center / orderFront（防闪烁）
    private func present() {
        guard !win.isVisible else { return }
        win.appearance = Palette.topLevelWindowAppearance
        if !hasShown {
            win.center()
            hasShown = true
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    // MARK: - 进度应用

    private func apply(_ p: UpdateProgress) {
        guard phase == .installing else { return }   // 窗口出现前的迟到回调一律丢弃
        if let f = p.fraction {
            if bar.isIndeterminate {
                bar.isIndeterminate = false
                bar.stopAnimation(nil)
            }
            bar.doubleValue = min(max(f, 0), 1) * 100
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        // 进度描述只显示最新一条（detail 覆盖上一条）
        detailLine.stringValue = p.detail
    }

    // MARK: - 动作

    @objc private func onCancel() {
        cancelFlag.set()
        cancelBtn.isEnabled = false
        detailLine.stringValue = "正在取消…"
    }

    @objc private func onRetry() {
        let handler = retryHandler
        retryHandler = nil
        handler?()
    }

    @objc private func onManual() {
        guard let url = URL(string: UpdateService.releasesPage) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func onClose() {
        closeWindow()
    }

    @objc private func onInstall() {
        let handler = installHandler
        installHandler = nil
        laterHandler = nil
        handler?()
    }

    @objc private func onLater() {
        let handler = laterHandler
        installHandler = nil
        laterHandler = nil
        handler?()
        closeWindow()
    }

    // MARK: - NSWindowDelegate

    /// 关闭语义按 Phase：确认态=稍后再说；安装中=取消（窗口留到流程真正退出）；
    /// 失败态直接关
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch phase {
        case .available:
            let handler = laterHandler
            installHandler = nil
            laterHandler = nil
            handler?()
            return true
        case .installing:
            onCancel()
            return false
        case .failed:
            retryHandler = nil
            return true
        }
    }
}

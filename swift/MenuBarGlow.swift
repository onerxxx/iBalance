// MenuBarGlow.swift — 菜单栏平台图标「任务状态指示」
// WB / ZCode / Codex 任一平台有可见任务态时，图标前方出现状态色圆点：
//   - 圆点本体常亮（直径 = 图标 × dotScale，不闪烁）
//   - 圆点外沿呼吸光晕（同色模糊晕，余弦淡入淡出，周期与面板光环一致）
// 实现：光晕位图预烘焙 + 60Hz Timer 逐帧写模型 opacity——多屏菜单栏镜像已提交的
// 图层内容、不传播 CA presentation 动画，只有模型值逐帧提交才能让所有屏同步呼吸
// （见 breathStep 注释）；图标本体（template 位图）与点击链路不接触。
import AppKit
import CoreImage

final class MenuBarStatusGlowController {

    /// 菜单栏条目图标在标题位图内的信息（id 判平台 / rect 为位图内 frame，top-down）
    struct EntryIcon {
        let id: String
        let rect: NSRect
        /// 图标左侧可用空隙（与前一内容的间隔，排版时解出）；nil = 位图最左、左侧无内容
        let leftFreeSpace: CGFloat?
    }

    // MARK: 调参常量
    // 圆点（常亮本体）
    private static let dotScale: CGFloat = 0.35  // 圆点直径 = 图标宽 × 0.35
    private static let dotSizeAdjust: CGFloat = -0.5  // 圆点直径固定修正（2026-09-08 缩小 0.5pt）
    private static let dotGap: CGFloat = 2       // 圆点与图标左缘的最小间距（定位收敛下限）
    private static let dotOpacity: Float = 0.9   // 常亮透明度
    private static let minIconGap: CGFloat = 1   // 空间不足时间距压缩下限（与图标）
    private static let prevContentGap: CGFloat = 2 // 与左侧内容的压缩下限（空隙不够时收敛到此）
    private static let dotLeftGap: CGFloat = 8   // 左侧有其他平台内容时，圆点与左侧内容的目标间隔
    // 光晕（呼吸，仅作用于圆点）
    private static let glowPadding: CGFloat = 5.1  // 光晕画布外扩（点），须容纳模糊扩散；每侧+0.1 = 光晕整体+0.2pt（2026-09-08）
    private static let blurSigmaPx: CGFloat = 5  // 高斯模糊 σ（3x 位图像素 ≈ 1.7pt 视觉扩散）
    private static let alphaBoost: CGFloat = 2.0 // 模糊后 alpha 增益（小面积光晕需更高增益）
    private static let glowPeakOpacity: Float = 0.7 // 呼吸峰值透明度
    private static let period: CFTimeInterval = 2.8 // 呼吸周期（与面板光环 2.8s 同口径）

    /// 状态点平台在标题烘焙时插入的预留空隙（点左侧间距）。点出现才插入、消失即随
    /// 重烘焙回收——标题排版由 updateTitleImpl 的指纹（含点存亡）驱动增删。
    /// 宽度算式：dotLeftGap(8) + 圆点(≈4.7) + 右距目标(≈4.4) ≈ 17pt，叠加条目分隔(≈9pt)；
    /// 右距由「左缘+dotLeftGap 定位 + 本空隙宽度」共同决定，只调图层不调空隙不会变（空隙是硬上限）
    static let dotReserve = "  \u{2009}"

    private let stateProvider: (String) -> AgentTaskState?
    private static let ciContext = CIContext()

    private weak var button: NSStatusBarButton?
    private var entries: [EntryIcon] = []
    /// 光晕层（呼吸，垫在圆点下）/ 圆点层（常亮本体），按条目 id 索引
    private var glowLayers: [String: CALayer] = [:]
    private var dotLayers: [String: CALayer] = [:]
    private var glowCache: [String: CGImage] = [:]
    /// 圆点存亡变化回调（出现/消失改变标题排版，由宿主触发标题重烘焙）
    var onDotPresenceChanged: (() -> Void)?
    private var lastWantedIDs: Set<String> = []
    /// 排序滑动动画进行中：sync 暂不落位（终态帧由动画收尾 sync 落定）
    private var isReordering = false

    init(stateProvider: @escaping (String) -> AgentTaskState?) {
        self.stateProvider = stateProvider
    }

    func attach(button: NSStatusBarButton) {
        self.button = button
    }

    /// 标题位图重烘焙后调用；异步延迟到下一 runloop——status item 尺寸重排
    /// （variableLength 按新位图宽调整 button frame）未必在当拍完成，提前读 bounds 会拿到旧值
    func setEntries(_ e: [EntryIcon], imageHeight: CGFloat) {
        entries = e
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    /// 离线等无标题位图场景：清空目标，sync 时移除全部图层
    func clear() {
        finishReorder()
        entries = []
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    // MARK: - 排序切换滑动动画（快照层 + 状态点帧插值，60Hz 模型值驱动，多屏同步）

    /// 面板拖拽排序提交后的过渡（回归最初朴素版，并入后续修复）：动画期间
    /// button.image = 透明占位（强制 layout 后按钮即终态宽），每个条目一层
    /// 「旧位图裁片快照」从旧位滑到新位；状态点/光晕用常驻层本体，从当前静止帧
    /// 直接插值到 sync 落定帧——两端都是实测精确值，无跨坐标系换算。
    /// 历版修复保留：x0 = 旧图原点 + 旧span（差值映射会整体左跳 imgOrigin.x）；
    /// 占位后 layoutSubtreeIfNeeded 再测终态（否则按旧宽测量收尾跳变）；
    /// 面板拖拽中即时跟手（quickReorder 缩短时长，链式重入取上一场目标位图当旧图）。
    /// 帧插值走模型值——CAAnimation 属 presentation 瞬态不随多屏镜像传播
    /// （见 breathStep 注释）。
    /// 成功返回 true（宿主不再直接设 button.image，由动画收尾时换新图）。
    /// 面板拖拽进行中的跟手模式：排序过渡缩短（0.25s → 0.12s），跨行频繁重入也能跟上
    var quickReorder = false

    @discardableResult
    func beginReorder(oldImage: NSImage,
                      oldSpansByID: [String: NSRect],
                      newImage: NSImage,
                      newEntries: [EntryIcon],
                      newSpansByID: [String: NSRect]) -> Bool {
        guard let button, button.window != nil,
              let newCG = newImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              !newEntries.isEmpty else { return false }
        // 链式重入：上一场动画未结束时按钮 image 是透明占位，旧图必须取其目标位图
        // （先取再 finishReorder，占位换成目标位图后按钮当前图才恢复可用）
        let effectiveOld = reorder?.newImage ?? oldImage
        guard let oldCG = effectiveOld.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        finishReorder()

        // 旧图原点与状态点/光晕旧帧——先于占位替换捕获（bounds 随宽度变化）
        let oldBounds = button.bounds.size
        let oldImgOrigin = NSPoint(x: (oldBounds.width - oldImage.size.width) / 2,
                                   y: (oldBounds.height - oldImage.size.height) / 2)
        let oldDotFrames = dotLayers.mapValues { $0.frame }
        let oldGlowFrames = glowLayers.mapValues { $0.frame }

        // 透明占位（新尺寸）后强制状态条立即完成宽度重排，终态几何全按真实终态测量
        button.image = NSImage(size: newImage.size)
        button.superview?.layoutSubtreeIfNeeded()

        // 终态条目表 + sync 落定：点/光晕的终态帧即收尾位置（sync 同一公式实测）
        entries = newEntries
        sync()
        let endDotFrames = dotLayers.mapValues { $0.frame }
        let endGlowFrames = glowLayers.mapValues { $0.frame }
        let b = button.bounds
        let newImgOrigin = NSPoint(x: (b.width - newImage.size.width) / 2,
                                   y: (b.height - newImage.size.height) / 2)

        let hostLayer: CALayer? = {
            if let l = button.layer { return l }
            button.wantsLayer = true
            return button.layer
        }()
        guard let hostLayer else { button.image = newImage; return false }
        let scale = CGFloat(oldCG.width) / max(1, effectiveOld.size.width)
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let imgH = newImage.size.height

        // 条目快照层：旧图裁片（图标+数值整段）从旧位滑到新位；新增条目从新图裁出原位淡入
        var sprites: [(layer: CALayer, x0: CGFloat, x1: CGFloat, a0: Float)] = []
        for e in newEntries {
            guard let span = newSpansByID[e.id], span.width > 1 else { continue }
            let x1 = newImgOrigin.x + span.minX
            var x0 = x1
            var a0: Float = 1
            var cg: CGImage?
            if let oldSpan = oldSpansByID[e.id], oldSpan.width > 1 {
                // span 是图内坐标：起点必须加旧图在按钮里的原点（差值映射会左跳 imgOrigin.x）
                x0 = oldImgOrigin.x + oldSpan.minX
                let cx = CGRect(x: oldSpan.minX * scale, y: 0,
                                width: oldSpan.width * scale, height: CGFloat(oldCG.height))
                cg = oldCG.cropping(to: cx).map { Self.tintedSprite($0, dark: dark) }
            } else {
                let ns = CGFloat(newCG.width) / max(1, newImage.size.width)
                let cx = CGRect(x: span.minX * ns, y: 0,
                                width: span.width * ns, height: CGFloat(newCG.height))
                cg = newCG.cropping(to: cx).map { Self.tintedSprite($0, dark: dark) }
                a0 = 0
            }
            guard let contents = cg else { continue }
            let l = CALayer()
            l.contentsScale = scale
            l.contents = contents
            l.masksToBounds = false
            l.frame = NSRect(x: x0, y: newImgOrigin.y, width: span.width, height: imgH)
            l.opacity = a0
            hostLayer.addSublayer(l)
            sprites.append((l, x0, x1, a0))
        }

        // 状态点/光晕：常驻层本体从旧静止帧直接插值到 sync 落定帧
        var dotAnim: [(layer: CALayer, f0: CGRect, f1: CGRect, o0: Float, o1: Float)] = []
        for (id, l) in dotLayers {
            guard let f1 = endDotFrames[id] else { continue }
            let o1 = Float(Self.dotOpacity)
            if let f0 = oldDotFrames[id] {
                if f0 != f1 { dotAnim.append((l, f0, f1, o1, o1)) }
            } else {
                l.opacity = 0  // 新增条目：原位淡入
                dotAnim.append((l, f1, f1, 0, o1))
            }
        }
        var glowAnim: [(layer: CALayer, f0: CGRect, f1: CGRect)] = []
        for (id, l) in glowLayers {
            guard let f1 = endGlowFrames[id] else { continue }
            let f0 = oldGlowFrames[id] ?? f1
            if f0 != f1 { glowAnim.append((l, f0, f1)) }
        }
        guard !sprites.isEmpty || !dotAnim.isEmpty || !glowAnim.isEmpty else {
            button.image = newImage
            return false
        }

        isReordering = true
        Logger.log(.refresh, "[Glow] reorder anim: plain sprites=\(sprites.count) dots=\(dotAnim.count) glows=\(glowAnim.count)")
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(reorderStep), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        reorder = (timer, CACurrentMediaTime(), sprites, dotAnim, glowAnim, newImage,
                   quickReorder ? 0.12 : Self.reorderDuration)
        return true
    }

    private var reorder: (timer: Timer, t0: CFTimeInterval,
                          sprites: [(layer: CALayer, x0: CGFloat, x1: CGFloat, a0: Float)],
                          dots: [(layer: CALayer, f0: CGRect, f1: CGRect, o0: Float, o1: Float)],
                          glows: [(layer: CALayer, f0: CGRect, f1: CGRect)],
                          newImage: NSImage, duration: CFTimeInterval)?

    private static let reorderDuration: CFTimeInterval = 0.25

    @objc private func reorderStep() {
        guard let r = reorder, let button else { finishReorder(); return }
        let p = min(1, (CACurrentMediaTime() - r.t0) / r.duration)
        // 二次 easeInOut
        let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        func lerpRect(_ f0: CGRect, _ f1: CGRect) -> CGRect {
            CGRect(x: f0.minX + (f1.minX - f0.minX) * CGFloat(e),
                   y: f0.minY + (f1.minY - f0.minY) * CGFloat(e),
                   width: f0.width + (f1.width - f0.width) * CGFloat(e),
                   height: f0.height + (f1.height - f0.height) * CGFloat(e))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, x0, x1, a0) in r.sprites {
            var f = l.frame
            f.origin.x = x0 + (x1 - x0) * CGFloat(e)
            l.frame = f
            l.opacity = a0 + (1 - a0) * Float(e)
        }
        for (l, f0, f1, o0, o1) in r.dots {
            l.frame = lerpRect(f0, f1)
            l.opacity = o0 + (o1 - o0) * Float(e)
        }
        for (l, f0, f1) in r.glows { l.frame = lerpRect(f0, f1) }
        CATransaction.commit()
        if button.window == nil || p >= 1 { finishReorder() }
    }

    /// 动画收尾：换上新位图、撤快照层、sync 落定（可安全重复调用）
    private func finishReorder() {
        guard let r = reorder else { return }
        reorder = nil
        r.timer.invalidate()
        button?.image = r.newImage
        for (l, _, _, _) in r.sprites { l.removeFromSuperlayer() }
        isReordering = false
        sync()
    }

    /// 把裁片按菜单栏 template 口径染色（深色外观白形 / 浅色外观黑形）：
    /// 先把原位图画进画布再 sourceAtop 叠色——sourceAtop 只作用于已有像素，
    /// 画布必须先有内容（2026-09-08 踩坑：漏画原位图 → 快照全透明，只剩闪烁）
    private static func tintedSprite(_ cg: CGImage, dark: Bool) -> CGImage {
        let w = cg.width, h = cg.height
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.draw(cg, in: rect)
        ctx.setBlendMode(.sourceAtop)
        ctx.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: 1))
        ctx.fill(rect)
        return ctx.makeImage() ?? cg
    }

    // MARK: - 图层同步

    /// 状态轮询回调：可见任务态变化但标题位图未重烘焙时刷新（图层增删/换色）
    func sync() {
        guard let button else { removeAllLayers(); return }
        if isReordering { return }  // 动画期间帧由 reorderStep 驱动，收尾 sync 落定
        let wants = entries.filter { stateProvider($0.id) != nil }
        let wantedIDs = Set(wants.map(\.id))
        for (id, l) in glowLayers where !wantedIDs.contains(id) {
            l.removeFromSuperlayer()
            glowLayers[id] = nil
        }
        for (id, l) in dotLayers where !wantedIDs.contains(id) {
            l.removeFromSuperlayer()
            dotLayers[id] = nil
        }
        // 圆点存亡变化 → 标题排版需增删 dotReserve 预留空隙：回调宿主重烘焙标题位图
        // （先更新记录再回调，宿主重烘焙触发 setEntries→sync 时不会二次触发成环）
        if wantedIDs != lastWantedIDs {
            lastWantedIDs = wantedIDs
            onDotPresenceChanged?()
        }
        Logger.log(.refresh, "[Glow] sync entries=\(entries.count) wants=\(wants.map(\.id)) states=\(entries.map { "\($0.id)=\(stateProvider($0.id).map(String.init(describing:)) ?? "nil")" })")
        guard !wants.isEmpty,
              button.window != nil,
              let img = button.image, img.size.width > 1, img.size.height > 1 else { return }
        let hostLayer: CALayer? = {
            if let l = button.layer { return l }
            button.wantsLayer = true
            return button.layer
        }()
        guard let hostLayer else { return }

        let b = button.bounds
        // NSStatusBarButton 将 image 在自身 bounds 内居中排布
        let imgRect = CGRect(x: (b.width - img.size.width) / 2,
                             y: (b.height - img.size.height) / 2,
                             width: img.size.width, height: img.size.height)
        for e in wants {
            guard let state = stateProvider(e.id) else { continue }
            // 附件 rect 为位图内 top-down 坐标 → 换算 button 层坐标（bottom-up）
            let iconRect = NSRect(x: imgRect.minX + e.rect.minX,
                                  y: imgRect.minY + (img.size.height - e.rect.maxY),
                                  width: e.rect.width,
                                  height: e.rect.height)
            // 圆点本体：图标左侧，垂直居中。位置收敛：
            //   左侧有内容（leftFreeSpace 非nil）：按「左缘 + dotLeftGap」定位（与左侧数字
            //   保持目标间隔），右距不足 dotGap 时向图标方向收敛，再不够压到 prevContentGap；
            //   左侧无内容（首条目）：期望位 = 图标左缘 - dotGap - 直径。
            let d = iconRect.width * Self.dotScale + Self.dotSizeAdjust
            var dotX = iconRect.minX - Self.dotGap - d
            if let leftFree = e.leftFreeSpace {
                let leftEdge = iconRect.minX - leftFree
                let want = leftEdge + Self.dotLeftGap
                let maxForIconGap = iconRect.minX - Self.dotGap - d
                dotX = min(max(want, leftEdge + Self.prevContentGap), maxForIconGap)
            }
            dotX = min(dotX, iconRect.minX - Self.minIconGap - d)
            let dotFrame = NSRect(x: dotX,
                                  y: iconRect.midY - d / 2,
                                  width: d, height: d)

            // 1) 呼吸光晕层：模糊圆点晕，垫在圆点下（先添加保证 z 序在圆点之下）
            let glow = glowLayers[e.id] ?? {
                let l = CALayer()
                l.masksToBounds = false
                hostLayer.addSublayer(l)
                glowLayers[e.id] = l
                return l
            }()
            glow.frame = dotFrame.insetBy(dx: -Self.glowPadding, dy: -Self.glowPadding)
            glow.contents = glowImage(state: state, diameter: d)

            // 2) 常亮圆点层
            let dot = dotLayers[e.id] ?? {
                let l = CALayer()
                l.masksToBounds = false
                hostLayer.addSublayer(l)
                l.opacity = Self.dotOpacity
                dotLayers[e.id] = l
                return l
            }()
            dot.frame = dotFrame
            dot.cornerRadius = d / 2
            dot.backgroundColor = Self.color(for: state).cgColor
            // 保证光晕恒在圆点下方
            dot.zPosition = 1
            glow.zPosition = 0
        }
        ensureBreathing()
    }

    // MARK: - 呼吸动画（60Hz Timer 逐帧驱动模型 opacity，仅光晕层）

    /// 为什么不用 CAKeyframeAnimation：多屏菜单栏镜像的是「已提交的图层内容」，
    /// CA 动画属 presentation 层瞬态、不随镜像传播——副屏拿到的是冻结帧（2026-09-08 实测）。
    /// 改用 60Hz Timer 逐帧写模型值 opacity：每次提交都进图层树，所有屏同步呼吸。
    private var breathTimer: Timer?
    private var breathStart: CFTimeInterval = 0

    private func ensureBreathing() {
        guard breathTimer == nil, !glowLayers.isEmpty else { return }
        breathStart = CACurrentMediaTime()
        // 60Hz 主循环驱动（.common 保证菜单栏追踪中也持续）；2.8s 周期下足够平滑
        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(breathStep),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        breathTimer = t
    }

    private func stopBreathing() {
        breathTimer?.invalidate()
        breathTimer = nil
    }

    /// 余弦呼吸当前 alpha（breathStep 与排序画布共用，保证光晕亮度跨动画连续）
    private func currentBreathAlpha() -> Float {
        let t = CACurrentMediaTime() - breathStart
        let phase = CGFloat(t.truncatingRemainder(dividingBy: Self.period)) / Self.period
        let breath = CGFloat(0.5) * (CGFloat(1) - cos(CGFloat(2) * CGFloat.pi * phase))
        return Self.glowPeakOpacity * Float(breath)
    }

    /// 余弦呼吸：0 → 峰值（半周期处）→ 0；圆点本体不参与（常亮）
    @objc private func breathStep() {
        guard !glowLayers.isEmpty else { stopBreathing(); return }
        let opacity = currentBreathAlpha()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, l) in glowLayers { l.opacity = opacity }
        CATransaction.commit()
    }

    // MARK: - 光晕位图（圆点剪影 → 高斯模糊），按 状态+直径 缓存

    /// 状态色：与 PanelLayout CardTaskStatusRingView.color(for:) 逐值对齐
    /// （2026-09-08 三态饱和度统一 +10%，与卡片光环同批调整）
    private static func color(for state: AgentTaskState) -> NSColor {
        switch state {
        case .running:    NSColor(calibratedRed: 0.505, green: 0.824, blue: 1.0, alpha: 1)
        case .completed:  NSColor(calibratedRed: 0.51, green: 0.95, blue: 0.40, alpha: 1)
        case .interrupted: NSColor(calibratedRed: 1, green: 0.20, blue: 0, alpha: 1)
        }
    }

    private func glowImage(state: AgentTaskState, diameter: CGFloat) -> CGImage? {
        let key = "dot|\(state)|\(Int(diameter * 10))"
        if let c = glowCache[key] { return c }
        let scale: CGFloat = 3
        let side = diameter + Self.glowPadding * 2
        let px = max(1, Int(side * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // 圆点剪影（实心圆）直接矢量绘制，无需图标形状
        Self.color(for: state).setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.glowPadding, y: Self.glowPadding,
                                    width: diameter, height: diameter)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let base = rep.cgImage else { return nil }

        // 高斯模糊 + alpha 增益（模糊拉低峰值）+ 裁回画布（模糊 extent 外扩，不裁会破坏 frame 对位）
        var ci = CIImage(cgImage: base)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(ci, forKey: kCIInputImageKey)
            blur.setValue(Self.blurSigmaPx, forKey: kCIInputRadiusKey)
            ci = blur.outputImage ?? ci
        }
        if let boost = CIFilter(name: "CIColorMatrix") {
            boost.setValue(ci, forKey: kCIInputImageKey)
            boost.setValue(CIVector(x: 0, y: 0, z: 0, w: Self.alphaBoost), forKey: "inputAVector")
            ci = boost.outputImage ?? ci
        }
        ci = ci.cropped(to: CGRect(x: 0, y: 0, width: px, height: px))
        guard let out = Self.ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        glowCache[key] = out
        return out
    }

    private func removeAllLayers() {
        stopBreathing()
        for (_, l) in glowLayers { l.removeFromSuperlayer() }
        glowLayers.removeAll()
        for (_, l) in dotLayers { l.removeFromSuperlayer() }
        dotLayers.removeAll()
    }
}

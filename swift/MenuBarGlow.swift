// MenuBarGlow.swift — 菜单栏平台图标「任务状态指示」
// WB / ZCode / Codex 任一平台有可见任务态时，图标前方出现状态色圆点：
//   - 圆点本体常亮（直径 = 图标 × dotScale，不闪烁）；进行中（蓝）额外做小球弹跳
//     （抛物线上下位移 + 触地压扁/顶点拉伸，光晕同幅跟随，见 updateBounce）
//   - 圆点外沿呼吸光晕（同色模糊晕，余弦淡入淡出，周期与面板光环一致）
// 实现：光晕位图预烘焙 + DisplayTicker 逐帧写模型 opacity（帧率 = 显示器刷新率）——多屏菜单栏镜像已提交的
// 图层内容、不传播 CA presentation 动画，只有模型值逐帧提交才能让所有屏同步呼吸
// （见 breathStep 注释）；图标本体（template 位图）与点击链路不接触。
import AppKit
import SettingsUI

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
    private static let dotOpacity = Float(MenuBarStatusDotStyle.dotOpacity) // 常亮透明度（规格共享源）
    private static let minIconGap: CGFloat = 1   // 空间不足时间距压缩下限（与图标）
    private static let prevContentGap: CGFloat = 2 // 与左侧内容的压缩下限（空隙不够时收敛到此）
    private static let dotLeftGap: CGFloat = 6   // 左侧有其他平台内容时，圆点与左侧内容的目标间隔（2026-09-13 用户要求由 8 缩 2pt）
    // 光晕（呼吸，仅作用于圆点）：透明度 / 模糊 / 烘焙规格统一在 MenuBarStatusDotStyle
    // （SettingsUI，设置窗口预览共用同一份），这里只按用途起别名
    private static let glowPadding = MenuBarStatusDotStyle.glowPadding // 光晕画布外扩（点），须容纳模糊扩散
    // 小球弹跳（仅「进行中」蓝点；光晕亮度仍走上面的呼吸，只跟随位移）
    // 参数改由设置窗口「菜单栏」pane 开放（落盘 + 实时生效），取值域/默认值/解算
    // 统一在 MenuBarBounceSettings（SettingsUI），本文件只负责把帧画出来

    /// 状态点平台在标题烘焙时插入的预留空隙（点左侧间距）。点出现才插入、消失即随
    /// 重烘焙回收——标题排版由 updateTitleImpl 的指纹（含点存亡）驱动增删。
    /// 宽度算式：dotLeftGap(6) + 圆点(≈4.7) + 右距目标(≈2.4) ≈ 13pt，叠加条目分隔(≈9pt)；
    /// 右距由「左缘+dotLeftGap 定位 + 本空隙宽度」共同决定，只调图层不调空隙不会变（空隙是硬上限）。
    /// 2026-09-13 点→图标间距 −2pt：宿主烘焙时对本空隙末字符施加 dotReserveTailKern。
    static let dotReserve = "  \u{2009}"
    /// dotReserve 末字符的 kern：普通字符默认 −0.2，此处 −2.2 = 净缩 2pt（空格字形
    /// 组合凑不出精确 2pt，直接在末字符 advance 上扣；attachmentRects 经 NSLayoutManager
    /// 解算，leftFreeSpace 与点定位口径自动一致）
    static let dotReserveTailKern: CGFloat = -2.2

    private let stateProvider: (String) -> AgentTaskState?

    /// 小球弹跳参数（设置窗口「菜单栏」pane 写入；见 `setBounce`）
    private var bounce = MenuBarBounceSettings.initial

    private weak var button: NSStatusBarButton?
    private var entries: [EntryIcon] = []
    /// 光晕层（呼吸，垫在圆点下）/ 圆点层（常亮本体），按条目 id 索引
    private var glowLayers: [String: CALayer] = [:]
    private var dotLayers: [String: CALayer] = [:]
    /// 弹跳基准：进行中圆点的静止帧（不含弹跳位移）+ 各自弹跳相位起点（按 id）
    private var dotBaseFrames: [String: CGRect] = [:]
    private var bounceStart: [String: CFTimeInterval] = [:]
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

    /// 设置窗口「菜单栏」pane 改参后调用：立刻按新参数重算当前帧（不必等下一拍出帧），
    /// 拖动滑杆时菜单栏是跟手的。无进行中圆点时是空操作。
    func setBounce(_ s: MenuBarBounceSettings) {
        bounce = s
        updateBounce(at: CACurrentMediaTime())
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

    // MARK: - 排序切换滑动动画（快照层 + 状态点帧插值，DisplayTicker 模型值驱动，多屏同步）

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
        // 出帧源 = 显示器刷新率（DisplayTicker，非 60Hz 定频）：插值密度随屏幕走
        let ticker = DisplayTicker(host: button) { [weak self] in
            guard let self else { return false }
            return self.reorderStep()
        }
        reorder = (ticker, CACurrentMediaTime(), sprites, dotAnim, glowAnim, newImage,
                   quickReorder ? 0.12 : Self.reorderDuration)
        ticker.start()
        return true
    }

    private var reorder: (ticker: DisplayTicker, t0: CFTimeInterval,
                          sprites: [(layer: CALayer, x0: CGFloat, x1: CGFloat, a0: Float)],
                          dots: [(layer: CALayer, f0: CGRect, f1: CGRect, o0: Float, o1: Float)],
                          glows: [(layer: CALayer, f0: CGRect, f1: CGRect)],
                          newImage: NSImage, duration: CFTimeInterval)?

    private static let reorderDuration: CFTimeInterval = 0.25

    /// 每帧插值；返回 false = 动画结束（自停，无需外部 invalidate）
    private func reorderStep() -> Bool {
        guard let r = reorder, button != nil else { finishReorder(); return false }
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
        if button?.window == nil || p >= 1 { finishReorder(); return false }
        return true
    }

    /// 动画收尾：换上新位图、撤快照层、sync 落定（可安全重复调用）
    private func finishReorder() {
        guard let r = reorder else { return }
        reorder = nil
        r.ticker.stop()
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
            dotBaseFrames[id] = nil
            bounceStart[id] = nil
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
            //   最左条目（无前一内容）：点贴位图左缘（want = leftEdge + 0）——leading
            //   视觉空隙只剩按钮内边距，点→图标间距与中段一致（2026-09-13 用户定稿；
            //   按中段 dotLeftGap 落位会让左缘空隙多出 6pt，用户打回）；
            //   左侧有内容：按「左缘 + dotLeftGap」定位（与左侧数字保持目标间隔），
            //   右距不足 dotGap 时向图标方向收敛，再不够压到 prevContentGap
            let d = iconRect.width * Self.dotScale + Self.dotSizeAdjust
            var dotX = iconRect.minX - Self.dotGap - d
            let isLeftmost = (e.id == entries.first?.id)
            if let leftFree = e.leftFreeSpace {
                let leftEdge = iconRect.minX - leftFree
                let want = leftEdge + (isLeftmost ? 0 : Self.dotLeftGap)
                let maxForIconGap = iconRect.minX - Self.dotGap - d
                dotX = isLeftmost
                    ? min(want, maxForIconGap)
                    : min(max(want, leftEdge + Self.prevContentGap), maxForIconGap)
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
            // 进行中（蓝）：登记弹跳基准帧，相位起点取首次出现时刻（新球从触地起跳）
            if state == .running {
                if dotBaseFrames[e.id] == nil { bounceStart[e.id] = CACurrentMediaTime() }
                dotBaseFrames[e.id] = dotFrame
            } else {
                dotBaseFrames[e.id] = nil
                bounceStart[e.id] = nil
            }
            // 保证光晕恒在圆点下方
            dot.zPosition = 1
            glow.zPosition = 0
        }
        // 立即落到当前弹跳帧：排序动画的终态帧即此刻真实帧，收尾无跳变
        updateBounce(at: CACurrentMediaTime())
        ensureBreathing()
    }

    // MARK: - 呼吸动画（DisplayTicker 逐帧驱动模型 opacity，仅光晕层）

    /// 为什么不用 CAKeyframeAnimation：多屏菜单栏镜像的是「已提交的图层内容」，
    /// CA 动画属 presentation 层瞬态、不随镜像传播——副屏拿到的是冻结帧（2026-09-08 实测）。
    /// 改用 DisplayTicker（displayLink，帧率 = 屏幕刷新率）逐帧写模型值 opacity：
    /// 每次提交都进图层树，所有屏同步呼吸。
    private var breathTicker: DisplayTicker?
    private var breathStart: CFTimeInterval = 0

    private func ensureBreathing() {
        guard breathTicker == nil, !glowLayers.isEmpty, let button else { return }
        breathStart = CACurrentMediaTime()
        // 显示器刷新率驱动（.common 保证菜单栏追踪中也持续）；2.8s 余弦周期本已平滑，
        // 高刷屏上亮度与弹跳位移都随屏幕逐帧推进
        let ticker = DisplayTicker(host: button) { [weak self] in
            guard let self else { return false }
            return self.breathStep()
        }
        breathTicker = ticker
        ticker.start()
    }

    private func stopBreathing() {
        breathTicker?.stop()
        breathTicker = nil
    }

    /// 余弦呼吸当前 alpha（breathStep 与排序画布共用，保证光晕亮度跨动画连续）；
    /// 公式与参数 = MenuBarStatusDotStyle.breathOpacity（设置窗口预览同源）
    private func currentBreathAlpha() -> Float {
        Float(MenuBarStatusDotStyle.breathOpacity(at: CACurrentMediaTime() - breathStart))
    }

    /// 余弦呼吸：0 → 峰值（半周期处）→ 0；圆点本体不参与（常亮），仅进行中圆点走弹跳。
    /// 返回 false = 无光晕层，自停
    private func breathStep() -> Bool {
        guard !glowLayers.isEmpty else { stopBreathing(); return false }
        let now = CACurrentMediaTime()
        let opacity = currentBreathAlpha()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, l) in glowLayers { l.opacity = opacity }
        CATransaction.commit()
        updateBounce(at: now)
        return true
    }

    // MARK: - 小球弹跳（仅「进行中」蓝点，模型值逐帧驱动，多屏同步）

    /// 进行中蓝点＝弹跳小球：在静止基准帧上叠加抛物线弹跳（上下位移 + 触地压扁/顶点拉伸），
    /// 光晕同幅上下跟随（亮度仍由呼吸驱动，观感不变）。与呼吸同理走模型值逐帧提交——
    /// CA 动画属 presentation 瞬态，不随菜单栏多屏镜像传播（见 breathStep 注释）。
    /// 排序滑动期间跳过：帧由 reorderStep 独占插值，收尾 sync 后再交还本函数。
    /// 形变解算在 `MenuBarBounceSettings.solve(at:)`（设置窗口预览共用同一函数，两边不会漂）。
    private func updateBounce(at now: CFTimeInterval) {
        guard !isReordering, !dotBaseFrames.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, base) in dotBaseFrames {
            guard let dot = dotLayers[id] else { continue }
            let b = bounce.solve(at: now - (bounceStart[id] ?? now))
            let w = base.width * CGFloat(b.sx)
            let h = base.height * CGFloat(b.sy)
            // 以底缘为支点形变：压扁时贴地、拉伸时向上长。
            // ⚠️ 状态栏按钮的层坐标实测 top-down（+y 向下）：dy 正值按 y-up 应用时真机
            // 弹跳整体上下镜像（2026-09-13 用户报告，静置位/图标居中因上下对称不露馅）。
            // solve() 的 dy 语义（视觉向上）不变——设置预览宿主是翻转视图、+dy 即向上；
            // 这里取负应用，支点 = base.maxY（视觉底缘）：dy=0 底缘贴地压扁，
            // dy=amplitude 整球上浮顶点拉伸。
            dot.frame = NSRect(x: base.midX - w / 2,
                               y: base.maxY - CGFloat(b.dy) - h,
                               width: w, height: h)
            dot.cornerRadius = h / 2
            if let glow = glowLayers[id] {
                glow.frame = base.insetBy(dx: -Self.glowPadding, dy: -Self.glowPadding)
                    .offsetBy(dx: 0, dy: -CGFloat(b.dy))
            }
        }
        CATransaction.commit()
    }

    // MARK: - 光晕位图（圆点剪影 → 高斯模糊），按 状态+直径 缓存

    /// 状态色：与 PanelLayout CardTaskStatusRingView.color(for:) 逐值对齐
    /// （2026-09-08 三态饱和度统一 +10%，与卡片光环同批调整）
    private static func color(for state: AgentTaskState) -> NSColor {
        switch state {
        case .running:    MenuBarStatusDotStyle.runningColor
        case .completed:  NSColor(calibratedRed: 0.51, green: 0.95, blue: 0.40, alpha: 1)
        case .interrupted: NSColor(calibratedRed: 1, green: 0.20, blue: 0, alpha: 1)
        }
    }

    private func glowImage(state: AgentTaskState, diameter: CGFloat) -> CGImage? {
        let key = "dot|\(state)|\(Int(diameter * 10))"
        if let c = glowCache[key] { return c }
        // 烘焙管线在 MenuBarStatusDotStyle（设置预览同源）；菜单栏 1:1，visualScale 缺省 1
        guard let out = MenuBarStatusDotStyle.glowBitmap(color: Self.color(for: state),
                                                         dotDiameter: diameter) else { return nil }
        glowCache[key] = out
        return out
    }

    private func removeAllLayers() {
        stopBreathing()
        for (_, l) in glowLayers { l.removeFromSuperlayer() }
        glowLayers.removeAll()
        for (_, l) in dotLayers { l.removeFromSuperlayer() }
        dotLayers.removeAll()
        dotBaseFrames.removeAll()
        bounceStart.removeAll()
    }
}

// MARK: - 小球弹跳参数的落盘（设置窗口「菜单栏」pane）

/// 取值域/默认值/解算都在 `MenuBarBounceSettings`（SettingsUI），这里只补 UserDefaults 读写。
/// 逐项独立落盘、逐次改动即写（滑杆拖动过程中也在写）—— 用户调完即是最终值，
/// 不设「保存」按钮，与「设置」pane 的刷新间隔同口径。
/// 读回一律夹回取值域：将来收窄范围时老值不会把滑杆顶歪。
extension MenuBarBounceSettings {
    static func load() -> MenuBarBounceSettings {
        let defaults = UserDefaults.standard
        func value(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        return MenuBarBounceSettings(
            amplitude: value(UDKey.menuBarBounceAmplitude, initial.amplitude),
            period: value(UDKey.menuBarBouncePeriod, initial.period),
            airRatio: value(UDKey.menuBarBounceAirRatio, initial.airRatio),
            squashMin: value(UDKey.menuBarBounceSquashMin, initial.squashMin),
            stretchMax: value(UDKey.menuBarBounceStretchMax, initial.stretchMax)
        ).clamped()
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(amplitude, forKey: UDKey.menuBarBounceAmplitude)
        defaults.set(period, forKey: UDKey.menuBarBouncePeriod)
        defaults.set(airRatio, forKey: UDKey.menuBarBounceAirRatio)
        defaults.set(squashMin, forKey: UDKey.menuBarBounceSquashMin)
        defaults.set(stretchMax, forKey: UDKey.menuBarBounceStretchMax)
    }
}

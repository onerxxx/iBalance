//
//  HoverMaterial.swift
//  iBalance
//
//  本文件速查
//  - HoverMaterialHost：跨卡片共享的 hover 材质宿主（装它的视图 = 坐标基准）
//    属性 materialLayer / outlineLayer / currentCard / isShown
//    方法 show(for:immediate:) / cardDidExit(_:) / updateGeometry(for:) / hideNow()
//         refreshAppearance()
//  - NSView.installHoverMaterialHost()：内容容器安装一次（每个面板实例各一份）
//  - NSView.hoverMaterialHost：卡片向上查找宿主（未安装 = nil，无 hover 材质）
//

import Cocoa

/// 跨卡片共享的 hover 材质：渐变背景块 + 发丝描边框，**一个实体**。
///
/// 与「每张卡自己画一份、各自淡入淡出 / 各自滑入」的区别：hover 在卡片之间转移时
/// 材质整块滑过去并停住（2026-09-10 用户两轮口径：「这个框要完整的从一个卡片位置
/// 移动到另个卡片的位置然后停住」、「背景色现在也跟随边框移动，而不是蒙版」）。
/// 跨卡移动只插值 position 与尺寸/路径（圆角矩形路径元素结构恒定，CGPath 可插值），
/// 线宽与圆角半径不参与动画 → 只变位置与尺寸，比例恒定。
///
/// 背景块画在**所有卡片之下**（zPosition < 0）：卡片与组容器底色都是 clear
/// （Palette.cardBackground = .clear），材质从卡片内容底下透出来，层次与
/// 「每张卡自持背景层」完全一致；差别只在它是一个实体，所以能整块穿过卡片间隙
/// 滑过去，而不是各卡被自身边界裁成半截（那正是 2026-09-10 被否掉的蒙版手感）。
///
/// 宿主挂在内容容器（滚动区内的 root）上，所以材质随内容一起滚动，
/// 且不需要裁切（移动两端都在卡片位置上，卡外无行程）。
final class HoverMaterialHost {
    /// 渐变背景块（圆角 = 卡片圆角，尺寸随卡片）
    let materialLayer = CAGradientLayer()
    /// 描边层（zPosition 恒定压在背景块与卡片子层之上）
    let outlineLayer = CAShapeLayer()
    /// 坐标基准 / 动态色解析基准
    private weak var hostView: NSView?
    /// 当前被指示的卡片（弱引用：卡片会被重建）
    private(set) weak var currentCard: HoverCard?
    /// 材质是否在场（false = 尚未出现或已淡出）
    private(set) var isShown = false
    /// 离开卡片后的宽限：hover 跨过卡片间隙时材质不该闪一下，留给下一张卡接管
    private static let exitGrace: CFTimeInterval = 0.12
    private var hideWork: DispatchWorkItem?

    init(hostView: NSView) {
        self.hostView = hostView
        // 背景块：圆角与卡片统一；masksToBounds 让它自己裁出圆角
        materialLayer.cornerCurve = .continuous
        materialLayer.masksToBounds = true
        materialLayer.opacity = 0
        // 画在所有卡片之下（卡片/组容器底色都是 clear）——内容压在材质之上
        materialLayer.zPosition = -1
        resolveMaterialColors()
        outlineLayer.fillColor = NSColor.clear.cgColor
        outlineLayer.lineWidth = Palette.cardBorderWidth
        outlineLayer.strokeColor = Palette.borderCGColor(Palette.hoverBorderBright, in: hostView)
        outlineLayer.opacity = 0
        // 卡片子视图层的插入顺序不可控，用 zPosition 保证框恒在内容之上
        outlineLayer.zPosition = 1000
        hostView.layer?.addSublayer(materialLayer)
        hostView.layer?.addSublayer(outlineLayer)
    }

    // MARK: - 对外

    /// 把材质移到这张卡上。immediate：拖拽截图等场景直接落位（不淡入、不走缓冲）。
    func show(for card: HoverCard, immediate: Bool = false) {
        hideWork?.cancel()
        hideWork = nil
        guard let geo = geometry(for: card) else { return }
        let wasShown = isShown
        let fromCard = currentCard
        let sameCard = fromCard === card
        currentCard = card
        if immediate {
            apply(geo, animated: false)
            setOpacity(1, animated: false)
            isShown = true
            return
        }
        if isShown && !sameCard && fromCard != nil {
            // 跨卡：整块滑过去并停住
            apply(geo, animated: true)
        } else {
            // 同卡只跟几何（驻留切换高度 / 内容变化）；首次出现（含上一张卡已被重建）
            // 直接落位再淡入——没有上一张卡可参照，滑入方向无从判定
            apply(geo, animated: false)
            if !wasShown { setOpacity(1, animated: true) }
            isShown = true
        }
    }

    /// 卡片离开：延迟隐藏（相邻卡片紧接着接管时材质不停顿）
    func cardDidExit(_ card: HoverCard) {
        guard currentCard === card else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentCard === card else { return }
            self.hideWork = nil
            self.currentCard = nil
            self.isShown = false
            self.setOpacity(0, animated: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGrace, execute: work)
    }

    /// 几何跟随：卡片 layout 后调用（尺寸变化时材质贴回卡片轮廓）。
    /// 跨卡移动动画进行中继续走动画（驻留切换高度会边动边改），静止时直接落位
    func updateGeometry(for card: HoverCard) {
        guard currentCard === card, isShown, hideWork == nil, let geo = geometry(for: card) else { return }
        apply(geo, animated: materialLayer.animation(forKey: "position") != nil)
    }

    /// 立即收起（拖拽锁定：材质不该跟着幽灵卡片跑）
    func hideNow() {
        hideWork?.cancel()
        hideWork = nil
        currentCard = nil
        isShown = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, keys) in animatedKeys {
            for key in keys { layer.removeAnimation(forKey: key) }
            layer.opacity = 0
        }
        CATransaction.commit()
    }

    /// 生效外观变化：动态色经 .cgColor 落盘会定格当时外观，按新外观重解算
    func refreshAppearance() {
        guard let hostView else { return }
        resolveMaterialColors()
        outlineLayer.strokeColor = Palette.borderCGColor(Palette.hoverBorderBright, in: hostView)
    }

    /// 跨卡移动会动的全部动画键（hideNow 清场用，含显隐）
    private var animatedKeys: [(CALayer, [String])] {
        [(materialLayer, ["opacity", "position", "bounds", "startPoint", "endPoint"]),
         (outlineLayer, ["opacity", "position", "path"])]
    }

    /// 只含几何动画键（几何落位时清场用——不动 opacity，避免打断进行中的显隐）
    private var geometryKeys: [(CALayer, [String])] {
        [(materialLayer, ["position", "bounds", "startPoint", "endPoint"]),
         (outlineLayer, ["position", "path"])]
    }

    // MARK: - 内部

    private struct Geometry {
        var center: CGPoint
        var size: CGSize
        var radius: CGFloat
    }

    /// 卡片在宿主坐标系里的几何（跨视图转换要求同一窗口）
    private func geometry(for card: HoverCard) -> Geometry? {
        guard let hostView, let win = card.window, win === hostView.window else { return nil }
        let rect = card.convert(card.bounds, to: hostView)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return Geometry(center: CGPoint(x: rect.midX, y: rect.midY),
                        size: rect.size,
                        radius: card.layer?.cornerRadius ?? Palette.cardCornerRadius)
    }

    /// 落位：背景块与描边框同时插值（同一几何、同一时长）。起点取 presentation 值，
    /// 连续快速跨卡时从当前位置接着走，相位不跳。
    private func apply(_ geo: Geometry, animated: Bool) {
        let rect = CGRect(origin: .zero, size: geo.size)
        let path = outlinePath(size: geo.size, radius: geo.radius)
        let pts = Palette.gradientEndpoints(angleDeg: Palette.hoverGradientAngleDeg, in: rect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            // 背景块跟着一起走：position + bounds（含尺寸变化）
            addGeometryAnimation(materialLayer, keyPath: "position",
                                 from: materialLayer.presentation()?.position ?? materialLayer.position,
                                 to: geo.center)
            addGeometryAnimation(materialLayer, keyPath: "bounds",
                                 from: materialLayer.presentation()?.bounds ?? materialLayer.bounds,
                                 to: rect)
            addGeometryAnimation(materialLayer, keyPath: "startPoint",
                                 from: materialLayer.presentation()?.startPoint ?? materialLayer.startPoint,
                                 to: pts.start)
            addGeometryAnimation(materialLayer, keyPath: "endPoint",
                                 from: materialLayer.presentation()?.endPoint ?? materialLayer.endPoint,
                                 to: pts.end)
            addGeometryAnimation(outlineLayer, keyPath: "position",
                                 from: outlineLayer.presentation()?.position ?? outlineLayer.position,
                                 to: geo.center)
            addGeometryAnimation(outlineLayer, keyPath: "path",
                                 from: outlineLayer.presentation()?.path ?? outlineLayer.path,
                                 to: path)
        } else {
            for (layer, keys) in geometryKeys {
                for key in keys { layer.removeAnimation(forKey: key) }
            }
        }
        materialLayer.cornerRadius = geo.radius
        materialLayer.bounds = rect
        materialLayer.position = geo.center
        materialLayer.startPoint = pts.start
        materialLayer.endPoint = pts.end
        outlineLayer.bounds = rect
        outlineLayer.position = geo.center
        outlineLayer.path = path
        CATransaction.commit()
    }

    /// 几何动画：跨卡跟随用 `Motion.hoverFollow`（比常规 hover 切换短，跟手优先）
    private func addGeometryAnimation(_ layer: CALayer, keyPath: String, from: Any?, to: Any) {
        guard let from else { return }
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = Motion.hoverFollow
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: keyPath)
    }

    private func setOpacity(_ value: Float, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [materialLayer, outlineLayer] {
            if animated {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = layer.opacity
                a.toValue = value
                a.duration = Motion.hover
                a.timingFunction = CAMediaTimingFunction(name: value > 0 ? .easeOut : .easeIn)
                layer.add(a, forKey: "opacity")
            } else {
                layer.removeAnimation(forKey: "opacity")
            }
            layer.opacity = value
        }
        CATransaction.commit()
    }

    /// 渐变颜色是 .cgColor 定格值：初始化与外观切换时都按当前生效外观重解算
    private func resolveMaterialColors() {
        guard let hostView else { return }
        hostView.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.materialLayer.colors = Palette.hoverGradient.map { $0.cgColor }
        }
    }

    /// 描边路径：内缩半个线宽，使描边外缘正好落在卡片圆角内侧；圆角同步内收，
    /// 与卡片 mask 的 .continuous 圆角差异 < 0.15pt（18% alpha 下不可见）
    private func outlinePath(size: CGSize, radius: CGFloat) -> CGPath {
        let inset = outlineLayer.lineWidth / 2
        let r = max(0, radius - inset)
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset),
                            cornerWidth: r, cornerHeight: r)
        return path
    }
}

private enum HoverMaterialAssociate {
    static var host: UInt8 = 0
}

extension NSView {
    /// 在内容容器上安装共享 hover 材质宿主（重复调用无副作用）。
    /// 卡片向上查找宿主，所以容器要覆盖目标卡片的全部范围——
    /// 面板里装在滚动内容根上，材质随内容一起滚动
    func installHoverMaterialHost() {
        guard objc_getAssociatedObject(self, &HoverMaterialAssociate.host) == nil else { return }
        wantsLayer = true
        objc_setAssociatedObject(self, &HoverMaterialAssociate.host,
                                 HoverMaterialHost(hostView: self),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 向上查找最近的共享 hover 材质宿主（含自身）；未安装返回 nil
    var hoverMaterialHost: HoverMaterialHost? {
        var view: NSView? = self
        while let cur = view {
            if let host = objc_getAssociatedObject(cur, &HoverMaterialAssociate.host) as? HoverMaterialHost {
                return host
            }
            view = cur.superview
        }
        return nil
    }
}

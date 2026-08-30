// PanelDrag.swift — iBalance
// 平台卡片拖拽排序框架:拖动状态机、幽灵卡片、重排动画、drop highlight
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)

import Cocoa
import CoreImage

extension BalancePanelView {

    // MARK: - 平台卡片排序

    var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 平台所属板块容器：DeepSeek/ZhiPu/Qwen 在 API 板块，其余在 Agent 板块。
    /// 拖拽排序与重排动画都限定在组内，卡片不跨板块移动。
    func groupContainer(forPlatformID id: String) -> NSStackView {
        (id == BalancePlatform.deepSeek.rawValue || id == BalancePlatform.bigModel.rawValue
            || id == BalancePlatform.qwen.rawValue)
            ? apiGroupContainer : balanceGroupContainer
    }

    /// 平台是否属 Agent 板块（groupContainer 的反面判定，单一事实源勿散落平台清单）
    func isAgentPlatform(_ id: String) -> Bool {
        groupContainer(forPlatformID: id) === balanceGroupContainer
    }

    private func visiblePlatformIDs() -> [String] {
        platformOrder.filter { id in
            guard let card = platformCards[id] else { return false }
            return !card.isHidden && card.frame.height > 0
        }
    }

    private func makeDragSnapshot(of card: NSView) -> NSImage? {
        guard !card.bounds.isEmpty,
              let representation = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return nil }
        // 先缓存拖动开始时的真实外观，让幽灵保留大卡片当前的 hover 样式；
        // 原卡片随后才会切成无 hover 占位，避免两者同时显示 hover 背景。
        card.cacheDisplay(in: card.bounds, to: representation)
        let image = NSImage(size: card.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    /// 平台排序对象与实际账号卡片并非总是同一层：DeepSeek 直接存卡片，
    /// 多账号平台存的是账号卡片容器。拖动视觉必须统一取当前账号卡片。
    private func draggableCard(for platformID: String) -> NSView? {
        guard let platformView = platformCards[platformID] else { return nil }
        if platformView is HoverCard { return platformView }
        if let container = platformView as? NSStackView {
            return container.arrangedSubviews.first(where: { $0 is HoverCard })
        }
        return platformView
    }

    /// 多账号平台有小卡片时，幽灵应覆盖整个账号组；单账号平台仍只显示当前卡片。
    private func dragGhostSourceView(for platformView: NSView, card: NSView) -> NSView {
        guard let container = platformView as? NSStackView,
              container.arrangedSubviews.contains(where: { view in
                  view is HoverCard && view !== card
              }) else { return card }
        return container
    }

    private func restoreDraggingSiblingCards() {
        for item in draggingSiblingCardOpacities {
            item.card.setDragContentOpacity(item.opacity)
        }
        draggingSiblingCardOpacities.removeAll()
    }

    func beginPlatformDrag(_ id: String, locationInWindow: NSPoint) {
        guard draggingPlatform == nil, let platformView = platformCards[id] else { return }
        // 拖拽接管手势期间清除 Token 板块 hover 覆盖，回落组顶平台避免拖动中内容跳动
        clearTokensHoverOverride()
        groupContainer(forPlatformID: id).layoutSubtreeIfNeeded()

        guard let card = draggableCard(for: id) else { return }
        draggingPlatform = id
        draggingCard = card

        // 多账号平台的容器内还有非当前账号小卡片，它们同样属于占位组，
        // 一起降低内容透明度，避免拖动时同组卡片仍保持满亮。
        if let container = platformCards[id] as? NSStackView {
            for sibling in container.arrangedSubviews.compactMap({ $0 as? HoverCard }) where sibling !== card {
                let opacity = sibling.dragContentLayer?.opacity ?? 1
                draggingSiblingCardOpacities.append((card: sibling, opacity: opacity))
            }
        }
        let hoverCard = card as? HoverCard
        let ghostSourceView = dragGhostSourceView(for: platformView, card: card)
        draggingGhostSourceView = ghostSourceView
        let ghostFrame = ghostSourceView.convert(ghostSourceView.bounds, to: self)
        let pointer = convert(locationInWindow, from: nil)
        draggingGhostOffset = NSPoint(x: pointer.x - ghostFrame.minX, y: pointer.y - ghostFrame.minY)

        // 必须在锁住 hover 之前截图：幽灵保留按下瞬间的大卡片 hover 外观，
        // 原卡片则继续留在排序流中并切成无 hover 占位。
        var ghostReady = false
        if let image = makeDragSnapshot(of: ghostSourceView) {
            let ghost = NSImageView(frame: ghostFrame)
            ghost.image = image
            ghost.imageScaling = .scaleAxesIndependently
            ghost.imageAlignment = .alignCenter
            ghost.wantsLayer = true
            ghost.layer?.cornerRadius = Palette.cardCornerRadius
            ghost.layer?.cornerCurve = .continuous
            ghost.layer?.shadowColor = NSColor.black.cgColor
            ghost.layer?.shadowOffset = CGSize(width: 0, height: -3)
            ghost.layer?.shadowRadius = 10
            ghost.layer?.shadowOpacity = shouldReduceMotion ? 0.35 : 0.48
            // 拖拽开始时直接显示到最终透明度，避免幽灵卡片从 0 淡入造成起手闪烁。
            ghost.alphaValue = 0.96
            addSubview(ghost, positioned: .above, relativeTo: nil)
            draggingGhostView = ghost
            movePlatformGhost(to: locationInWindow)
            ghostReady = true
        }
        hoverCard?.setDragHoverLocked(true)

        // 原卡片保留在排序流中作为轻量占位，避免其他卡片在拖动时失去节奏。
        if let hoverCard = card as? HoverCard {
            // 只降低内容层，保持卡片背景/hover 材质稳定，避免归位时背景闪亮。
            hoverCard.setDragContentOpacity(ghostReady ? 0.18 : 0.88)
        } else {
            card.wantsLayer = true
            card.layer?.opacity = ghostReady ? 0.18 : 0.88
        }
        // 小卡片仍需承担同组结构提示，不能和主拖动卡片一样降到几乎不可见。
        let siblingOpacity: Float = ghostReady ? 0.4 : 0.88
        for item in draggingSiblingCardOpacities {
            item.card.setDragContentOpacity(siblingOpacity)
        }
    }

    private func movePlatformGhost(to locationInWindow: NSPoint) {
        guard let ghost = draggingGhostView else { return }
        let pointer = convert(locationInWindow, from: nil)
        ghost.frame.origin = NSPoint(x: pointer.x - draggingGhostOffset.x,
                                     y: pointer.y - draggingGhostOffset.y)
    }

    func updatePlatformDrag(_ id: String, locationInWindow: NSPoint) {
        guard draggingPlatform == id else { return }
        movePlatformGhost(to: locationInWindow)
        groupContainer(forPlatformID: id).layoutSubtreeIfNeeded()

        let visibleIDs = Set(visiblePlatformIDs())
        // 排序只在所属板块内进行：remaining 过滤掉其他板块的平台，
        // 拖到另一板块区域时不产生跨组重排
        let group = groupContainer(forPlatformID: id)
        let remaining = platformOrder.filter { $0 != id && visibleIDs.contains($0)
            && groupContainer(forPlatformID: $0) === group }
        let targetIndex = min(remaining.count,
                             remaining.reduce(into: 0) { result, candidate in
                                 guard let card = platformCards[candidate] else { return }
                                 let center = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
                                 // 面板是非 flipped 坐标：y 越大越靠上。
                                 if center.y > locationInWindow.y { result += 1 }
                             })
        let targetID = targetIndex < remaining.count ? remaining[targetIndex] : nil

        var nextOrder = platformOrder.filter { $0 != id }
        if let targetID, let anchorIndex = nextOrder.firstIndex(of: targetID) {
            nextOrder.insert(id, at: anchorIndex)
        } else if let last = remaining.last, let lastIndex = nextOrder.firstIndex(of: last) {
            nextOrder.insert(id, at: lastIndex + 1)
        } else {
            nextOrder.append(id)
        }

        if nextOrder != platformOrder {
            platformOrder = nextOrder
            applyPlatformOrder(animated: true)
            applyUsageOrder(animated: true)
            // 拖动中即时回调让菜单栏顺序实时跟随（持久化仍只在松手时写入）；
            // 高频跨行由 TitleDebouncer 合并、指纹相同则跳过重绘。
            onPlatformOrderChanged?(nextOrder)
        }
    }

    /// 用量行跟随平台卡片顺序：重排 arrangedSubview 并用 Y 轴位移动画让行平滑让位（同 applyPlatformOrder 口径）
    private func applyUsageOrder(animated: Bool) {
        let orderedViews = platformOrder.compactMap { usageRowViews[$0] }
        let dataRows = usageContentStack.arrangedSubviews.filter { $0 !== usageHeaderRowRef }
        guard !orderedViews.isEmpty, orderedViews.count == dataRows.count else { return }
        let oldFrames = Dictionary(uniqueKeysWithValues: orderedViews.map {
            (ObjectIdentifier($0), $0.frame)
        })
        // 表头保持最上，数据行按平台顺序重排
        let desired = (usageHeaderRowRef.map { [$0] } ?? []) + orderedViews
        for (index, view) in desired.enumerated() {
            guard let currentIndex = usageContentStack.arrangedSubviews.firstIndex(of: view),
                  currentIndex != index else { continue }
            usageContentStack.removeArrangedSubview(view)
            usageContentStack.insertArrangedSubview(view, at: index)
        }
        usageContentStack.layoutSubtreeIfNeeded()
        guard animated, !shouldReduceMotion else { return }
        for view in orderedViews {
            guard let oldFrame = oldFrames[ObjectIdentifier(view)],
                  oldFrame != view.frame,
                  let layer = view.layer else { continue }
            let animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.fromValue = oldFrame.midY - view.frame.midY
            animation.toValue = 0
            animation.duration = Motion.layout
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "usageReorder")
        }
    }

    func endPlatformDrag() {
        guard let id = draggingPlatform else { return }
        draggingPlatform = nil
        guard let platformView = platformCards[id] else {
            draggingCard = nil
            draggingGhostSourceView = nil
            restoreDraggingSiblingCards()
            draggingGhostView?.removeFromSuperview()
            draggingGhostView = nil
            return
        }
        let card = draggingCard ?? draggableCard(for: id) ?? platformView
        draggingCard = nil
        let hoverCard = card as? HoverCard

        let ghost = draggingGhostView
        draggingGhostView = nil
        let ghostSourceView = draggingGhostSourceView ?? card
        draggingGhostSourceView = nil
        // 释放时以当前 arrangedSubview 的最终坐标为准，确保幽灵卡片归位到真实卡片位置。
        groupContainer(forPlatformID: id).layoutSubtreeIfNeeded()
        platformView.layer?.removeAnimation(forKey: "platformReorder")
        let finalFrame = ghostSourceView.convert(ghostSourceView.bounds, to: self)
        if let ghost, !shouldReduceMotion {
            // 归位阶段先隐藏占位卡片内容，避免幽灵卡片与占位卡片半透明叠加变亮。
            let placeholderLayer = (card as? HoverCard)?.dragContentLayer ?? card.layer

            // 拖动过程中一直使用 NSView.frame，这里也用同一坐标系做吸附，
            // 避免在 frame 与 CALayer.position 之间切换时出现右上方跳动。
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.hover
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ghost.animator().frame = finalFrame
            } completionHandler: { [weak self, weak ghost] in
                // 归位完成后做一次原子交接：占位内容直接接管并移除幽灵，
                // 避免额外的淡入动画在两层之间制造闪烁帧。
                placeholderLayer?.removeAnimation(forKey: "platformDropRestore")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                placeholderLayer?.opacity = 1
                ghost?.alphaValue = 0
                ghost?.removeFromSuperview()
                // 幽灵与占位在同一个交接事务内恢复最终 hover 状态，
                // 光标若已在卡片内则直接显示，避免多余的 hover 淡入闪烁。
                hoverCard?.setDragHoverLocked(false, animated: false)
                CATransaction.commit()
                self?.restoreDraggingSiblingCards()
                self?.draggingGhostOffset = .zero
            }
        } else {
            ghost?.removeFromSuperview()
            if let hoverCard = card as? HoverCard {
                hoverCard.setDragContentOpacity(1)
            } else {
                card.layer?.opacity = 1
            }
            restoreDraggingSiblingCards()
            hoverCard?.setDragHoverLocked(false, animated: false)
            draggingGhostOffset = .zero
        }
        UserDefaults.standard.set(platformOrder, forKey: UDKey.balancePlatformOrder)
        onPlatformOrderChanged?(platformOrder)
    }

    /// 调整 arrangedSubview 顺序，并仅用 Y 轴位移动画让相邻平台卡片平滑让位。
    /// platformOrder 是全平台一维序，重排时按板块过滤：各板块内保持组内相对顺序。
    func applyPlatformOrder(animated: Bool) {
        for group in [balanceGroupContainer, apiGroupContainer] as [NSStackView] {
            let orderedViews = platformOrder.compactMap { platformCards[$0] }
                .filter { group.arrangedSubviews.contains($0) }
            // 防御：platformOrder 缺组内平台时不重排，避免把缺的容器挤到组尾（原全量口径按组细化）
            guard orderedViews.count == group.arrangedSubviews.count else { continue }

            let oldFrames = Dictionary(uniqueKeysWithValues: orderedViews.map {
                (ObjectIdentifier($0), $0.frame)
            })
            for (index, view) in orderedViews.enumerated() {
                guard let currentIndex = group.arrangedSubviews.firstIndex(of: view),
                  currentIndex != index else { continue }
                group.removeArrangedSubview(view)
                group.insertArrangedSubview(view, at: index)
            }
            for view in orderedViews {
                group.setCustomSpacing(4, after: view)
            }
            group.layoutSubtreeIfNeeded()

            guard animated, !shouldReduceMotion else { continue }
            for view in orderedViews {
                guard let oldFrame = oldFrames[ObjectIdentifier(view)],
                  oldFrame != view.frame,
                  let layer = view.layer else { continue }
                // 使用 transform.translation.y，明确锁住 X 轴，避免重排时出现水平漂移。
                let animation = CABasicAnimation(keyPath: "transform.translation.y")
                animation.fromValue = oldFrame.midY - view.frame.midY
                animation.toValue = 0
                animation.duration = Motion.layout
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "platformReorder")
            }
        }
        // 主面板 Token 板块跟随 Agent 组顶部平台：排序变化（拖拽实时重排/账号重建）后立即重解析取数
        refreshInlineTokens()
    }

}

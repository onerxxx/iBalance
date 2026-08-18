# macOS AppKit 卡片拖动框架

这是一套基于 `NSView + CALayer + NSImageView` 的卡片拖动排序方案，适用于 macOS AppKit 面板、余额卡片、平台列表和多账号卡片组。

当前项目的主要实现位于 [`swift/Panel.swift`](../swift/Panel.swift)：

- `HoverCard`：处理 hover、整卡命中、鼠标拖动事件和拖动锁定。
- `BalancePanelView`：管理拖动状态、幽灵卡片、平台排序和归位交接。
- `UDKey.balancePlatformOrder`：持久化平台排序。

## 一、整体视觉模型

拖动时同时存在三种视觉对象：

```text
原卡片 / 占位卡片
├─ 保留在 Auto Layout 排序流中
├─ 外层 hover 背景关闭
└─ 仅降低内容层透明度

幽灵卡片
├─ 从拖动开始瞬间生成静态截图
├─ 添加到面板顶层，自由跟随光标移动
└─ 保留拖动开始瞬间的大卡片 hover 外观

同组小卡片
└─ 保留在占位组内，内容透明度降低到 0.4
```

关键原则：

1. 不要用整张卡片的 `layer.opacity` 做占位淡化，否则 hover 背景也会一起参与合成。
2. 幽灵截图必须在锁定原卡片 hover 之前生成。
3. 归位时幽灵移除、占位恢复、hover 状态恢复必须在同一个无隐式动画事务内完成。
4. hover 的最终状态要根据释放瞬间的真实光标位置重新判断，不能只依赖旧的 `mouseEntered/mouseExited`。

## 二、卡片层级设计

```text
HoverCard
└─ layer                         // 卡片圆角、背景、边框
   ├─ hoverEffectLayer           // hover 渐变和噪点
   │  ├─ hoverGradientLayer
   │  └─ noiseLayer
   └─ dragContentView.layer      // 卡片标题、图标、余额、点阵等实际内容
```

卡片内容必须注册为可以单独调透明度的层：

```swift
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
```

`addCard` 创建 `HoverCard` 后调用：

```swift
if let hc = card as? HoverCard {
    hc.configureDragContentView(stack)
}
```

## 三、拖动事件框架

### 1. 整张卡片命中

卡片需要覆盖内部 label、图标和其他子视图：

```swift
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
```

### 2. 鼠标按下与拖动阈值

当前实现使用 `window.nextEvent` 进入事件追踪。小于 `3pt` 视为点击，大于等于 `3pt` 才开始拖动：

```swift
let start = event.locationInWindow
var dragging = false

while let next = window.nextEvent(
    matching: [.leftMouseDragged, .leftMouseUp],
    until: .distantFuture,
    inMode: .eventTracking,
    dequeue: true
) {
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
```

## 四、拖动状态

`BalancePanelView` 中需要维护以下状态：

```swift
private var platformOrder: [String] = []
private var platformCards: [String: NSView] = [:]

private var draggingPlatform: String?
private weak var draggingCard: NSView?
private weak var draggingGhostSourceView: NSView?
private weak var draggingGhostView: NSImageView?
private var draggingGhostOffset = NSPoint.zero

private var draggingSiblingCardOpacities: [(card: HoverCard, opacity: Float)] = []
```

| 状态 | 用途 |
|---|---|
| `platformOrder` | 当前平台顺序，同时用于持久化 |
| `platformCards` | 平台 ID 到实际卡片或账号容器的映射 |
| `draggingPlatform` | 当前正在拖动的平台 ID，防止重复开始 |
| `draggingCard` | 当前真正被拖动的主账号卡片 |
| `draggingGhostSourceView` | 幽灵截图来源，可能是单张卡片或整个账号组 |
| `draggingGhostView` | 顶层的 `NSImageView` 幽灵 |
| `draggingGhostOffset` | 光标相对幽灵左下角的偏移，保持抓取位置不跳动 |
| `draggingSiblingCardOpacities` | 保存同组小卡片原始透明度，归位后恢复 |

## 五、单卡片与多账号卡片组

平台映射不一定直接指向 `HoverCard`：

```swift
private func draggableCard(for platformID: String) -> NSView? {
    guard let platformView = platformCards[platformID] else { return nil }
    if platformView is HoverCard { return platformView }
    if let container = platformView as? NSStackView {
        return container.arrangedSubviews.first(where: { $0 is HoverCard })
    }
    return platformView
}
```

多账号平台有小卡片时，幽灵应使用整个账号容器：

```swift
private func dragGhostSourceView(for platformView: NSView, card: NSView) -> NSView {
    guard let container = platformView as? NSStackView,
          container.arrangedSubviews.contains(where: {
              $0 is HoverCard && $0 !== card
          }) else {
        return card
    }
    return container
}
```

否则幽灵只显示主账号，大卡片同组的小卡片会消失。

## 六、幽灵卡片截图

截图必须在锁定原卡片 hover 之前执行，才能保留拖动开始瞬间的 hover 外观：

```swift
private func makeDragSnapshot(of card: NSView) -> NSImage? {
    guard !card.bounds.isEmpty,
          let representation = card.bitmapImageRepForCachingDisplay(in: card.bounds)
    else { return nil }

    card.cacheDisplay(in: card.bounds, to: representation)

    let image = NSImage(size: card.bounds.size)
    image.addRepresentation(representation)
    return image
}
```

正确顺序：

```text
当前卡片仍处于 hover
        ↓
生成幽灵截图（保留 hover）
        ↓
锁定原卡片 hover，并切换为无 hover 占位
        ↓
降低占位内容透明度
```

如果先调用 `setDragHoverLocked(true)`，幽灵截图会把 hover 背景一起截掉。

## 七、开始拖动

开始拖动的核心流程：

```swift
balanceGroupContainer.layoutSubtreeIfNeeded()

let card = draggableCard(for: id)
let ghostSourceView = dragGhostSourceView(for: platformView, card: card)
let ghostFrame = ghostSourceView.convert(ghostSourceView.bounds, to: self)
let pointer = convert(locationInWindow, from: nil)
draggingGhostOffset = NSPoint(
    x: pointer.x - ghostFrame.minX,
    y: pointer.y - ghostFrame.minY
)

// 先截图，再锁定 hover
let image = makeDragSnapshot(of: ghostSourceView)

let ghost = NSImageView(frame: ghostFrame)
ghost.image = image
ghost.imageScaling = .scaleAxesIndependently
ghost.wantsLayer = true
ghost.layer?.cornerRadius = Palette.cardCornerRadius
ghost.layer?.cornerCurve = .continuous
ghost.layer?.shadowOffset = CGSize(width: 0, height: -3)
ghost.layer?.shadowRadius = 10
ghost.layer?.shadowOpacity = shouldReduceMotion ? 0.35 : 0.48
ghost.alphaValue = 0.96
addSubview(ghost, positioned: .above, relativeTo: nil)

hoverCard?.setDragHoverLocked(true)
hoverCard?.setDragContentOpacity(0.18)
```

同组小卡片单独设置：

```swift
for item in draggingSiblingCardOpacities {
    item.card.setDragContentOpacity(0.4)
}
```

截图成功时主占位内容为 `0.18`；截图失败时使用备用透明度 `0.88`，避免卡片完全消失。

## 八、拖动过程与排序计算

幽灵移动只改变 `frame.origin`，不修改 Auto Layout 约束：

```swift
private func movePlatformGhost(to locationInWindow: NSPoint) {
    guard let ghost = draggingGhostView else { return }
    let pointer = convert(locationInWindow, from: nil)
    ghost.frame.origin = NSPoint(
        x: pointer.x - draggingGhostOffset.x,
        y: pointer.y - draggingGhostOffset.y
    )
}
```

排序目标通过其他可见平台卡片的中心点计算：

```swift
let center = card.convert(
    NSPoint(x: card.bounds.midX, y: card.bounds.midY),
    to: nil
)

// 非 flipped 坐标系：y 越大表示视觉位置越靠上
if center.y > locationInWindow.y {
    result += 1
}
```

平台顺序改变后，只对相邻卡片做 Y 轴位移动画：

```swift
let animation = CABasicAnimation(keyPath: "transform.translation.y")
animation.fromValue = oldFrame.midY - view.frame.midY
animation.toValue = 0
animation.duration = 0.2
animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
layer.add(animation, forKey: "platformReorder")
```

## 九、归位与无闪烁交接

归位时先停止平台重排动画，计算最终位置，再让幽灵吸附回去：

```swift
NSAnimationContext.runAnimationGroup { context in
    context.duration = 0.15
    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ghost.animator().frame = finalFrame
} completionHandler: {
    // 下面的交接必须在一个禁用隐式动画的事务中完成
}
```

交接顺序：

```swift
CATransaction.begin()
CATransaction.setDisableActions(true)

placeholderLayer?.removeAnimation(forKey: "platformDropRestore")
placeholderLayer?.opacity = 1
ghost.alphaValue = 0
ghost.removeFromSuperview()

// 根据释放瞬间的光标位置直接恢复 hover，不再额外淡入
hoverCard?.setDragHoverLocked(false, animated: false)

CATransaction.commit()

restoreDraggingSiblingCards()
draggingGhostOffset = .zero
```

`setDragHoverLocked(false, animated: false)` 的作用：

- 移除旧的 hover 和边框动画。
- 重新判断光标是否在卡片内。
- 光标在卡片内：直接设置 `hoverEffectLayer.opacity = 1`、`borderWidth = 0.8`。
- 光标在卡片外：直接设置 `hoverEffectLayer.opacity = 0`、`borderWidth = 0`。
- 触发 `onHover`，恢复昵称等附属内容。

如果这里使用普通 `animated = true`，幽灵消失后占位卡片会再经历一次 hover 淡入，容易产生亮一下或闪烁。

光标位置的兜底判断：

```swift
private func isPointerInsideCard() -> Bool {
    guard let window else { return isMouseInside }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return bounds.contains(point)
}
```

## 十、Hover 锁定规则

拖动期间，`mouseEntered/mouseExited` 仍可能收到事件，但不能让占位卡片重新出现 hover：

```swift
override func mouseEntered(with event: NSEvent) {
    isMouseInside = true
    if isDragHoverLocked { return }
    animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: 1)
    animateLayerKey(layer, keyPath: "borderWidth", to: 0.8)
}

override func mouseExited(with event: NSEvent) {
    isMouseInside = false
    if isDragHoverLocked { return }
    animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: 0)
    animateLayerKey(layer, keyPath: "borderWidth", to: 0)
}
```

锁定时需要同时处理：

```swift
hoverEffectLayer.removeAnimation(forKey: "opacityTransition")
layer?.removeAnimation(forKey: "borderWidthTransition")
hoverEffectLayer.opacity = 0
hoverEffectLayer.isHidden = true
layer?.backgroundColor = dragNormalBackgroundColor ?? kCardBackground.cgColor
layer?.borderWidth = 0
```

重点是恢复原本背景配置，而不是写死一个新的背景色。当前项目的卡片默认背景为透明，由外层余额容器提供背景。

## 十一、关键参数表

| 参数 | 当前值 | 作用 |
|---|---:|---|
| 拖动触发阈值 | `3pt` | 区分点击和拖动 |
| 普通 hover 动画 | `0.22s` | 渐变和边框淡入淡出 |
| hover easing | `.easeInEaseOut` | 普通 hover 过渡 |
| 重排动画 | `0.2s` | 相邻平台 Y 轴让位 |
| 重排 easing | `.easeOut` | 拖动中的位置调整 |
| 幽灵归位动画 | `0.15s` | 释放后吸附到最终位置 |
| 幽灵 alpha | `0.96` | 拖动中的整体可见度 |
| 主占位内容 alpha | `0.18` | 减少原卡片与幽灵叠加 |
| 同组小卡片 alpha | `0.4` | 保留账号组结构提示 |
| 截图失败备用 alpha | `0.88` | 防止截图失败时完全消失 |
| hover 边框宽度 | `0.8pt` | hover 时的细边框 |
| 卡片圆角 | `10pt` | 卡片和幽灵统一圆角 |
| 幽灵阴影偏移 | `(0, -3)` | 增加浮起感 |
| 幽灵阴影半径 | `10` | 柔化拖动阴影 |
| 普通幽灵阴影透明度 | `0.48` | 拖动层次感 |
| 减弱动效阴影透明度 | `0.35` | `reduce motion` 下简化视觉 |
| hover 渐变颜色 | white `0.08 → 0.05` | 轻微提亮，不使用实体背景 |
| hover 渐变角度 | `60°` | 卡片内斜向渐变 |
| 噪点触发概率 | `35 / 256` | 约 `13.7%` 像素生成颗粒 |

通用 layer 动画函数：

```swift
private func animateLayerKey(
    _ layer: CALayer?,
    keyPath: String,
    to value: Any?,
    duration: Double = 0.22
) {
    guard let layer else { return }
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.duration = duration
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    animation.fromValue = layer.value(forKeyPath: keyPath)
    animation.toValue = value
    layer.add(animation, forKey: keyPath + "Transition")
    layer.setValue(value, forKeyPath: keyPath)
}
```

## 十二、排序目标的视觉反馈

拖动过程中不给排序目标卡片加边框高亮。多账号平台的排序对象是外层账号容器（`NSStackView`），其 layer 未预设 `borderColor`，而 `CALayer` 默认边框为黑色；一旦动画 `borderWidth`，目标卡片就会出现一圈黑框。

当前做法是完全去掉 drop 边框高亮，只保留排序逻辑；拖动反馈由幽灵卡片和相邻卡片的 Y 轴让位动画提供。若将来要恢复目标高亮，必须先给目标 layer 显式设置 `borderColor`（如卡片统一的 `white@20%`），避免再次出现黑框。

## 十三、排序持久化

拖动结束后只保存平台顺序，不改变平台内部账号顺序：

```swift
UserDefaults.standard.set(
    platformOrder,
    forKey: UDKey.balancePlatformOrder
)
onPlatformOrderChanged?(platformOrder)
```

初始化时清理未知 ID，并把新增平台追加到末尾：

```swift
let normalized = savedOrder.filter { known.contains($0) }
platformOrder = normalized + defaultOrder.filter {
    !normalized.contains($0)
}
```

## 十四、复用时的最小接入步骤

1. 创建一个继承 `NSView` 的卡片类，准备 `onDragStarted/onDragChanged/onDragEnded` 回调。
2. 将卡片内容放入独立的 `dragContentView`，不要把 hover 层和内容混在同一个透明度层。
3. 覆盖 `hitTest`，确保整张卡片可以拖动。
4. 在 `mouseDown` 中设置拖动阈值，区分点击和拖动。
5. 拖动开始时先完成布局，再截取 hover 状态截图。
6. 截图成功后创建顶层 `NSImageView` 幽灵。
7. 锁定原卡片 hover，降低内容层透明度。
8. 拖动过程中只移动幽灵，排序容器只做必要的 Y 轴让位动画。
9. 释放时让幽灵吸附到最终 frame。
10. 在一个 `CATransaction` 中完成占位恢复、幽灵移除和 hover 最终状态恢复。
11. 恢复同组小卡片原始透明度。
12. 持久化排序结果，并通知菜单栏或其他消费者。

## 十五、常见错误检查表

- [ ] 幽灵截图是否发生在 `setDragHoverLocked(true)` 之前？
- [ ] 是否只降低内容层 alpha，而不是整张卡片 alpha？
- [ ] 多账号平台是否使用整个账号容器作为幽灵来源？
- [ ] 同组小卡片是否保存并恢复原始透明度？
- [ ] 归位时是否使用 `animated: false` 恢复 hover？
- [ ] 幽灵移除和占位显示是否在同一禁用隐式动画事务中？
- [ ] 是否在最终归位前调用 `layoutSubtreeIfNeeded()`？
- [ ] 是否清理 `draggingPlatform`、`draggingGhostView`、offset 和 highlight？
- [ ] 是否在异常路径也恢复光标栈？
- [ ] 是否为 `reduce motion` 提供立即归位路径？
- [ ] 是否确认没有给排序目标加边框高亮（外层容器 layer 无 `borderColor`，动画 `borderWidth` 会出现黑框）？


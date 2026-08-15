# macOS 原生 NSSegmentedControl 紧凑化指南

> 本文总结了在菜单栏 popover 面板中使用紧凑分段控件时踩过的所有坑，以及最终稳定可用的写法。

## 背景

在 iBalance 菜单栏 app 的设置面板中，需要一个**刷新时间选择器**（1分钟 / 3分钟 / 5分钟）。由于面板空间有限，系统默认的 `NSSegmentedControl` 太大，需要做紧凑化处理。

核心需求：
- 控件小巧紧凑，不占太多空间
- **首次启动不跳动**（这是最大的坑）
- 暗色外观适配
- 右对齐布局

---

## 踩过的坑（按时间顺序）

### 坑 1：直接修改 layer transform + 自定义 anchorPoint

```swift
// ❌ 失败方案
final class MiniSegmentedControl: NSSegmentedControl {
    private let visualScale: CGFloat = 0.81

    private func applyTransform() {
        guard let l = layer, l.bounds.width > 0 else { return }
        // 右中心锚点：缩放时右边缘对齐
        let rightCenter = CGPoint(x: 1.0, y: 0.5)
        let target = CGAffineTransform(scaleX: visualScale, y: visualScale)
        // ... 设置 anchorPoint + transform
    }
}
```

**问题**：编译后**首次启动**时，transform 失效，控件以未缩放的原始大小显示（看起来"无故变大"）。重启 app 后正常。

**根因**：`NSSegmentedControl` 是 AppKit 中最复杂的控件之一，内部由 `NSSegmentedCell` 管理多个 segment 的绘制。在首次显示、layer 树重建、controlSize 同步等时机，系统会**重置 layer 属性**（包括你手动设置的 `transform`、`anchorPoint`、`cornerRadius` 等）。相比之下，`NSSwitch` 内部结构简单，同样的 layer transform 方案就稳定可靠。

### 坑 2：改回 center anchorPoint（与 MiniSwitch 对齐）

```swift
// ❌ 仍然有概率首次启动失效
let center = CGPoint(x: 0.5, y: 0.5)  // 默认中心点
```

**问题**：改了 anchorPoint 之后，右对齐效果丢失了（缩放从中心开始，右边会有空白），而且首次启动变大的问题**只是降低了概率，没有根治**。

### 坑 3：重写 intrinsicContentSize 返回硬编码尺寸

```swift
// ❌ 与 Auto Layout 冲突
override var intrinsicContentSize: NSSize {
    return NSSize(width: 3 * 60 * visualScale, height: 22)
}
```

**问题**：AppKit 在 layout 过程中会根据 `controlSize`、字体、segment 数量等重新计算控件尺寸，硬编码的 `intrinsicContentSize` 与系统计算结果不一致，导致布局冲突和跳动。

### 坑 4：设置 layer.cornerRadius 做大圆角

```swift
// ❌ 高亮背景被方角裁剪
override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.height / 2
    layer?.masksToBounds = true
}
```

**问题**：外边框变成圆角了，但内部选中 segment 的**高亮背景仍然是方角**，视觉上非常违和。这是因为 AppKit 内部直接在 drawRect 中绘制高亮矩形，不走 layer 圆角裁剪。

### 坑 5：完全自绘 NSView 子类

```swift
// ⚠️ 可用但不是最优雅的方案
final class MiniSegmentedControl: NSView {
    // 用 CALayer 绘制背景胶囊 + 选中滑块 + CATextLayer 文字
    // 处理 mouseDown 点击
    // 加 CABasicAnimation 滑动动画
}
```

**问题**：这个方案确实能工作（大圆角 + 滑动动画都完美），但：
1. 完全放弃了系统控件的 accessibility（VoiceOver 不识别）
2. 选中/未选中的视觉风格与系统控件不一致（特别是暗色模式下的毛玻璃效果）
3. 代码量 ~170 行，维护成本高
4. 键盘导航不支持

**结论**：对于追求原生质感的 app，自定义自绘是最后手段。能用系统控件就用系统控件。

---

## 最终稳定方案：纯原生尺寸控制

**核心思路**：不碰任何 layer 属性（transform / anchorPoint / cornerRadius / masksToBounds），完全通过 AppKit 提供的**原生 API** 控制尺寸。

```swift
/// 紧凑分段控件：纯使用 AppKit 原生 controlSize/font/segmentWidth 控制尺寸，
/// 不使用任何 layer transform（AppKit 复杂控件会在首次显示时重置 layer 属性导致缩放失效）。
final class MiniSegmentedControl: NSSegmentedControl {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlSize = .mini          // 系统最小控件尺寸
        segmentStyle = .rounded      // 圆角风格
        appearance = NSAppearance(named: .darkAqua)  // 暗色外观
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // ⚠️ 关键：必须在 viewDidMoveToWindow 中设置字体和段宽，
        //    因为此时 convenience init(labels:) 已添加完所有 segment。
        //    在 init 中设置会被 segments 覆盖！
        let miniFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        font = miniFont
        cell?.font = miniFont  // 必须同时设置 cell.font，否则不生效！
        for i in 0..<segmentCount {
            setWidth(36, forSegment: i)  // 固定每个 segment 宽度
        }
        needsLayout = true
    }
}
```

### 使用方式

```swift
private let intervalSegment: MiniSegmentedControl = {
    let seg = MiniSegmentedControl(
        labels: ["1分钟", "3分钟", "5分钟"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    seg.selectedSegment = 2  // 默认选中"5分钟"
    return seg
}()
```

---

## 关键知识点

### 1. 为什么必须同时设置 `font` 和 `cell?.font`？

`NSSegmentedControl` 继承自 `NSControl`，其文字渲染由对应的 `NSCell` 子类（`NSSegmentedCell`）负责。只设置 `control.font` 不一定能覆盖 cell 内部缓存的字体，必须**同时设置 `cell?.font`** 才能确保生效。

这也是为什么之前尝试 `font = NSFont.systemFont(ofSize: 7)` 完全无效的原因——cell 仍然用自己的字体。

### 2. 为什么字体设置要放在 `viewDidMoveToWindow()` 而不是 `init`？

`NSSegmentedControl(labels:...)` 这个 convenience init 在添加 segment 时，会用当前 controlSize 对应的默认字体来配置 cell。如果在 `init` 中提前设了字体，添加 segment 的过程会**覆盖**你的设置。

在 `viewDidMoveToWindow()` 中，所有 segment 已经添加完毕，此时设置字体和段宽不会被覆盖。

### 3. `controlSize = .mini` 做了什么？

`NSControl.ControlSize.mini` 是 macOS 控件系统中最小的尺寸等级。设为 `.mini` 后：
- 控件高度自动缩到约 15-16pt
- 内边距自动减小
- 圆角半径自动适配小尺寸
- 字体默认缩小到约 10pt

再配合手动设置 9pt 字体和固定 36pt 段宽，就能得到非常紧凑的效果。

### 4. 为什么 NSSwitch 可以用 layer transform 而 NSSegmentedControl 不行？

| 控件 | 内部复杂度 | layer 稳定性 | 推荐方案 |
|------|-----------|-------------|---------|
| `NSSwitch` | 简单（一个滑块层 + 背景层） | ✅ 稳定 | layer transform 缩放 |
| `NSSegmentedControl` | 复杂（多 cell、动态 layer 重建） | ❌ 会被重置 | 纯原生 controlSize + font |
| `NSButton` | 中等 | ⚠️ 看 buttonType | 优先原生，必要时 transform |
| `NSTextField` | 中等 | ⚠️ fieldEditor 会干扰 | 原生 font 调整 |
| `NSSlider` | 复杂 | ❌ 会被重置 | 原生 controlSize |

**经验法则**：对于内部由 cell 体系驱动的复杂控件（segmentedControl、slider、popupButton 等），尽量用原生 API 控制尺寸，不要直接改 layer transform。对于简单控件（switch、imageView、box 等），layer transform 是安全的。

### 5. layout() 中的 next-runloop 兜底

参考 MiniSwitch 的防御性写法，如果未来确实需要给某个控件加 layer transform，建议在 `layout()` 中做双重保险：

```swift
override func layout() {
    super.layout()
    applyTransform()
    // AppKit 可能在 layout 同步后重置 layer transform，下一帧再设一次
    DispatchQueue.main.async { [weak self] in
        self?.applyTransform()
    }
}
```

但请注意：**这种兜底方案对于 NSSegmentedControl 仍然不够**，因为它的 layer 重置时机不确定（可能在 layout 之后的任意时刻），所以根本的解决方案还是不用 transform。

---

## 如果真的需要大圆角？

如果产品设计要求胶囊外形（pill shape）的大圆角分段控件，纯原生 API 无法满足（`segmentStyle = .rounded` 的圆角半径由系统决定，不可自定义）。

方案选择优先级：

1. **接受系统圆角**：`.rounded` style 在 `.mini` 尺寸下的圆角已经比较圆润，优先考虑接受
2. **用 `NSSegmentDistribution` 调整**：macOS 10.15+ 支持 `NSSegmentDistribution`，可以影响 segment 的分布方式
3. **容器包裹法**：用一个 `NSView` 作为容器，设置圆角 + masksToBounds，内部放原生 NSSegmentedControl（但高亮背景方角问题仍然存在）
4. **完全自绘**：参考坑 5，用 CALayer 自绘背景 + 滑块 + 文字，但要注意补 accessibility

---

## 总结清单

✅ **做**：
- 用 `controlSize = .mini` 获取最小系统尺寸
- 在 `viewDidMoveToWindow()` 中设置 `font` 和 `cell?.font`
- 用 `setWidth(_:forSegment:)` 固定每个段的宽度
- 用 `appearance = NSAppearance(named: .darkAqua)` 适配暗色模式
- 让 `intrinsicContentSize` 由系统自动计算，不要重写

❌ **不要做**：
- 不要给 NSSegmentedControl 的 layer 设置 `transform`（会被系统重置）
- 不要修改 `anchorPoint`（position 计算容易出错）
- 不要重写 `intrinsicContentSize` 返回硬编码值
- 不要在 `init` 中设置字体（会被 segment 覆盖）
- 不要只设 `font` 不设 `cell?.font`（不生效）
- 不要设置 `layer.cornerRadius` + `masksToBounds`（高亮背景会被裁剪成方角）

---

## 参考代码位置

- MiniSegmentedControl 最终实现：[Panel.swift#L161-L185](file:///Volumes/850Pro_256G/htmls/iBalance/swift/Panel.swift#L161-L185)
- MiniSwitch（layer transform 稳定版参考）：[Panel.swift#L116-L159](file:///Volumes/850Pro_256G/htmls/iBalance/swift/Panel.swift#L116-L159)
- 使用处：[Panel.swift#L840-L845](file:///Volumes/850Pro_256G/htmls/iBalance/swift/Panel.swift#L840-L845)

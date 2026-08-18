# macOS 菜单栏 Template 图标踩坑记

> 场景：iBalance 菜单栏需要显示「多平台图标 + 余额文字」混合内容（NSStatusItem）。
> 目标：图标跟随系统自适应着色（深浅模式 / 屏幕聚焦变淡 / 透明菜单栏 / 菜单打开高亮反色）。
> 结论先行：**把整条标题（图标+文字）烘焙成一张黑形位图 template，赋给 `button.image`**。
> 定稿版本：v2026.8.18.4（2026-08-18）

## 版本演进一览

| 版本 | 方案 | 结果 |
|---|---|---|
| 初版 | SVG 直接 `isTemplate = true` 内嵌 attachment | 主图标变色，平台图标不变色 |
| .73 | 引入 PDF 矢量图标，PDF/SVG 设 template | **PDF 渲染成黑色**（坑 1） |
| .74 | PDF 栅格化成位图 template | PDF 图标正常自适应 |
| .1/.3 | 全平台手动染色（深浅×聚焦，sourceAtop） | 貌似可行但**跟不上真实系统变淡**（坑 3、4） |
| .2 | 按网传「Liquid Glass 规范」全交系统 template | 只有 `button.image` 生效，attachment 依旧死色（坑 2） |
| **.4** | **整条标题烘焙单张位图 template → `button.image`** | **全状态自适应，定稿** |

## 坑 1：矢量表示（PDF/SVG）设 isTemplate 不生效，渲染成黑色

`NSImage.isTemplate` 的 template 语义（只取 alpha 蒙版、由系统着色）**只对位图表示（NSBitmapImageRep）生效**。PDF/SVG 的矢量表示不走这条路，系统直接按原始颜色绘制——黑填充的图形就成了纯黑块。

```swift
// ❌ 无效：PDF/SVG 直接设 template
let img = NSImage(contentsOf: pdfOrSvgURL)
img.isTemplate = true  // 照样按原色渲染

// ✅ 正确：先 3x 栅格化为位图（黑形 + alpha）再设 template
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)
// ... draw source into rep ...
let img = NSImage(); img.addRepresentation(rep)
img.isTemplate = true
```

## 坑 2：`attributedTitle` 里的 NSTextAttachment 根本不进 template 管线

这是最隐蔽的一个坑，Apple 文档没有明说，论坛才挖得到：

- **只有 `button.image` / `NSMenuItem.image` 的 template 走系统状态栏自适应管线**
- `attributedTitle` 里的 `NSTextAttachment` 是**原样绘制位图**——attachment.image 设不设 `isTemplate` 都不会变色，深浅模式、聚焦变淡、高亮反色统统不参与
- 症状：主图标（`button.image`）正常变色，同屏的内嵌图标死色

Apple 论坛（thread/662322）、QuickFiles PR#1 都印证：想要自定义内容自适应，别在 attachment 上找 tint 方案，绕开这条路。

## 坑 3：手动染色补不齐系统变淡的所有时机

attachment 不可变色的直接 workaround 是自己染色：深色模式白色 / 浅色模式黑色 / 会话失活时 55% alpha。

问题：系统的「聚焦变淡」实际触发点很多且无完整公开 API——

- 锁屏 / 屏保 / 快速用户切换（可监听 `NSWorkspace.session*` 通知）
- **菜单栏所属屏幕 vs 前台 app 所在屏幕不一致**（多显示器每屏独立深浅/聚焦）
- 透明菜单栏（Clear 外观）下系统实际用的前景色并不等于「白/黑 × alpha」

监听 `NSApp.isActive` + 8 种焦点通知也只能覆盖一部分场景，视觉上总有对不齐的时刻。

## 坑 4：网传「Liquid Glass 规范」的适用范围

macOS 26/27 时代的建议「位图 template 交给系统、不要手动 tint」本身没错，但**只适用于 `button.image` / `NSMenuItem.image`**。拿着这条规范去改 attachment 渲染（v2026.8.18.2 走过的弯路）会发现根本没生效——因为 attachment 压根不在那条管线里（回到坑 2）。

## 坑 5：macOS 的 DrawingOptions 类型坑

整条 attributed string 烘焙成位图时，绘图选项类型在 macOS 上是：

```swift
// ❌ iOS 写法，macOS 编译不过 / 成员不同
NSAttributedString.DrawingOptions = [.usesLineFragmentMode, ...]

// ✅ macOS：NSString.DrawingOptions，且成员名不同
let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
```

## 最终方案：整条标题烘焙单张位图 template

```
黑色 attributed string
  ├─ 主图标（credit-card-filled，栅格化黑形 attachment）
  ├─ 平台图标 ×N（PDF/SVG 栅格化黑形 attachment）
  └─ 文字（系统字体，黑色）
        │
        ▼ renderTemplateTitleImage()：3x 烘焙为 NSBitmapImageRep
        ▼ isTemplate = true
        ▼
  statusItem.button.image = 烘焙图   ← 唯一走系统自适应管线的入口
  statusItem.button.attributedTitle = ""  （不再用）
```

关键实现（`swift/main.swift`）：

- `menuBarIconShape(named:size:)`：PDF → SVG → PNG 顺序加载，矢量 3x 栅格化为黑形位图，按 iconName 缓存
- `renderTemplateTitleImage(_:)`：`boundingRect` 量尺寸 → 3x `NSBitmapImageRep` → `attr.draw(with:options:)` → `isTemplate = true`，宽度过大（>2000pt）防御性放弃
- `updateTitle()`：每次余额/可见性变化重建 attr 并重新烘焙；聚焦/深浅变化**不需要**任何代码响应，系统自动着色

## 规则速记

1. 菜单栏要自适应 → 只有 `button.image` 的 template 一条路
2. 图标+文字混合内容 → 整体画进一张黑形位图，别用 attributedTitle 显示内容
3. PDF/SVG 想当 template → 必须先栅格化成位图
4. 高分屏锐利 → 栅格化用 3x scale，`rep.size` 设回逻辑 pt 尺寸
5. PNG 品牌色图标烘焙进 template 后颜色会被丢弃，只留 alpha 形状（要品牌色就别走 template）

## 参考

- [Apple Developer Forums — Big Sur: Detect when menu bar is light/dark](https://developer.apple.com/forums/thread/662322)
- [Apple Developer Forums — Create a template image](https://developer.apple.com/forums/thread/106293)
- [QuickFiles PR#1 — Fix icon color customization in status bar](https://github.com/samsontands/QuickFiles/pull/1)
- [jury — MENUBAR-DESIGN.txt](https://github.com/mord58562/jury/blob/main/MENUBAR-DESIGN.txt)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

# iBalance：macOS 26 AppKit 升级结论与风险清单

## 结论

推荐升级到 Xcode 26 / macOS 26 SDK 编译，但暂时不推荐把项目最低支持版本直接改成 macOS 26。

对 iBalance 来说，最稳妥的方案是：

1. 使用 macOS 26 SDK 编译；
2. 保持最低运行版本为 macOS 12；
3. 通过 `if #available(macOS 26.0, *)` 增量使用新 API；
4. 先验证菜单栏状态项、主面板、用量子面板和 Mono 控件，再决定是否放弃旧系统兼容。

“升级 AppKit”并不是把项目重写成另一套框架。AppKit 仍然是同一套系统框架，主要变化来自新的 SDK、系统默认控件行为和 macOS 26 的视觉材质。

Apple 对现有 AppKit 应用的建议也是先用最新版 Xcode 构建并在新系统上观察变化，而不是从头重写界面。[Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)

## 当前项目状态

当前项目在 [`swift/build.sh`](../swift/build.sh) 中使用：

```text
-target arm64-apple-macos12
```

这同时表达了两个事实：

- 目前只构建 Apple Silicon 架构；
- 最低运行系统是 macOS 12。

建议第一阶段只替换 SDK，不修改这个 deployment target。Xcode 26 已包含 macOS 26 SDK，且需要运行在 macOS Sequoia 15.6 或更高版本。[Xcode 26 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes) · [Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)

## 升级时最可能遇到的具体问题

| 风险 | 具体位置 | 可能表现 | 建议 |
|---|---|---|---|
| Liquid Glass 与自定义背景冲突 | `TintedVisualEffectView`、主面板和用量子面板 | 系统材质变亮、箭头颜色不一致、背景渐变/遮罩覆盖系统效果 | 先保留现有视觉作为兼容路径；macOS 26 上优先让系统 popover 控制材质，减少对 popover 根视图的自定义遮罩 |
| 主面板箭头与内容安全区变化 | `NSPopover.hasFullSizeContent`、`safeAreaLayoutGuide` | 箭头颜色正确但内容被裁切，或顶部/左右内边距变化 | 不要直接把滚动视口绑定到 safe area；背景铺满，滚动文档和内容 padding 分开计算 |
| 主面板滚动高度计算变化 | `NSScrollView.contentInsets`、手动 `panel.frame`、`preferredContentSize` | 底部设置项消失、滚动位置错误、面板出现空白区域 | 同时验证文档高度、视口高度、contentInsets 和首次滚动归位；不能只改约束而不调整 `preferredContentSize` |
| 用量子面板定位不稳定 | `NSPopover.show(relativeTo:of:preferredEdge:)` | hover 时子面板不出现、出现后马上关闭、箭头位置漂移 | 定位矩形必须位于仍在窗口中的视图 bounds 内；保留定位失败后的同周期重试，并测试主 popover 为 `.transient`、子 popover 为 `.applicationDefined` 的组合 |
| 标准控件尺寸和间距变化 | `NSSwitch`、`NSSegmentedControl`、`NSTextField`、`NSStackView` | 原来对齐的刷新时间控件、Mono 开关、分段控件发生偏移或裁切 | 以可见字形和控件内容为基准重新做光学对齐；不要只依赖 intrinsicContentSize 或固定宽度 |
| Mono 字体度量变化 | `DepartureMono`、cascade font、`size(withAttributes:)` | 括号被裁切、数字列宽改变、中文回退字体上下偏移 | 在 macOS 12、14、26 分别测量字体宽度/高度；让绘制和 intrinsicContentSize 使用同一份 attributed string |
| 固定 darkAqua 与新系统外观不一致 | `popover.appearance`、`container.appearance` | 系统处于浅色或增强对比度时，面板仍是深色但控件材质、文字对比度不一致 | 面板可以继续固定深色，但标准控件尽量使用语义色；测试降低透明度、增强对比度和减少动态效果 |
| 自定义绘制不自动获得新材质 | `NSBezierPath` 图表、Mono 自绘控件、hover 背景 | 系统控件有新外观，但自绘控件显得突兀或对比度不足 | 不要为了追逐新材质重写图表；只调整颜色、边界和可访问性，保持图表的原生绘制实现 |
| Swift 6.2 并发检查 | `Task`、通知回调、`NSObject` target/action、后台刷新 | 切换到 Swift 6 语言模式后出现 Sendable、MainActor 或闭包捕获错误 | 先保持 Swift 5 语言模式完成 SDK 升级，再单独处理 Swift 6 并发诊断 |
| 菜单栏状态项行为变化 | `NSStatusItem.button`、template image、菜单栏标题烘焙图 | 状态栏图标亮度、缩放、菜单栏拥挤或刘海区域位置变化 | 测试浅色/深色、聚焦/失焦、多显示器和菜单栏空间不足场景 |
| 分发工具链要求 | App Store Connect 上传流程 | 旧 Xcode 构建的版本可能无法提交新的系统版本目标 | 如果项目要上架，应使用 Xcode 26 或更高版本构建；Apple 已公布新的 SDK 构建要求。[Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/) |

## 对当前代码最敏感的区域

### 1. 主面板根视图

主面板目前同时使用了：

- `NSPopover.hasFullSizeContent`；
- `TintedVisualEffectView`；
- `.menu` 毛玻璃材质；
- 自定义 tint overlay；
- 圆角和 `masksToBounds`；
- `NSScrollView` 透明背景；
- 手动 `contentInsets` 和 `preferredContentSize`。

这些机制在 macOS 26 上都可能单独正常，但叠加后容易出现箭头、圆角、safe area 和滚动视口互相影响的问题。升级时应优先验证主面板，不要先替换业务卡片。

### 2. 用量子面板

用量子面板依赖 `NSPopover` 的定位视图和定位矩形。AppKit 会根据定位视图自动调整 popover 的位置，定位矩形还会影响箭头的具体落点。[NSPopover 文档](https://developer.apple.com/documentation/appkit/nspopover)

升级后应重点验证：

- hover 进入每一行是否立即显示；
- 主面板滚动后是否仍然显示；
- 鼠标从主面板移动到子面板时是否被关闭；
- 子面板是否被屏幕边缘重新定位；
- 主面板关闭时子面板是否同步关闭。

### 3. 自定义背景

Apple 对 Liquid Glass 的建议是减少控件和导航区域的自定义背景，让系统决定材质；自定义背景可能覆盖或干扰系统效果。当前项目的 `TintedVisualEffectView` 是视觉核心，因此不建议一次性删除，而应增加系统材质兼容分支，并逐项比较：

- 系统默认 popover；
- `.menu` 材质；
- tint overlay；
- 圆角裁剪；
- 主/子 popover 箭头。

## 推荐迁移步骤

### 阶段一：只切换 SDK

保持：

```text
最低系统版本：macOS 12
架构：arm64
语言模式：Swift 5
```

使用 Xcode 26 工具链和 macOS 26 SDK 编译，先不要引入新视觉 API。

### 阶段二：建立 macOS 26 专用检查

使用可用性判断隔离新行为：

```swift
if #available(macOS 26.0, *) {
    // macOS 26 专用行为
} else {
    // macOS 12+ 兼容路径
}
```

建议先把新行为集中在小范围适配层，不要把 `#available` 散落到所有卡片和设置行中。

### 阶段三：按界面风险验证

至少测试以下组合：

| 系统/设置 | 需要验证 |
|---|---|
| macOS 12 | 现有兼容路径、popover 显示、Mono 控件 |
| macOS 14 | `hasFullSizeContent`、safe area、箭头背景 |
| macOS 26 深色 | Liquid Glass、主/子 popover、渐变背景 |
| macOS 26 浅色 | 固定 darkAqua 与系统控件对比度 |
| macOS 26 降低透明度 | 自定义背景是否仍可读 |
| macOS 26 增强对比度 | 文字、图表、hover 状态是否过亮或消失 |
| 多显示器/屏幕边缘 | 状态栏锚点、主面板和子面板重新定位 |

### 阶段四：再决定是否提高最低版本

只有在以下条件都满足时，才建议将最低版本改为 macOS 26：

- 不再需要 macOS 12–25 用户；
- 不需要保留旧版 popover 和背景兼容逻辑；
- 已完成 macOS 26 的视觉和可访问性测试；
- 已确认目标用户全部使用 Apple Silicon 和 macOS 26；
- 项目不需要旧系统上的本地运行或离线维护。

## 最终建议

对 iBalance 当前阶段，建议采用：

```text
升级 Xcode 26 / macOS 26 SDK：是
最低运行版本改为 macOS 26：暂不
立即重写 AppKit UI：否
先做 popover、背景和滚动布局适配：是
先切换 Swift 6 语言模式：否
```

升级 SDK 可以让项目获得最新编译器、系统框架和新系统行为，同时保留 macOS 12 兼容性。真正需要谨慎的是现有的自定义背景、popover 定位、滚动视口和自绘控件，而不是 AppKit 本身。

## 官方参考

- [Xcode 26 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
- [Xcode 系统要求与 Deployment Target](https://developer.apple.com/xcode/system-requirements)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [AppKit updates](https://developer.apple.com/documentation/updates/appkit)
- [NSPopover](https://developer.apple.com/documentation/appkit/nspopover)
- [macOS Tahoe 26 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
- [App Store Connect Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)

# iBalance 踩坑记：hover 驻留确认切换内容 → 文档高度变化 → 邻居卡假 hover

> 日期：2026-09-06（定稿 v2026.9.6.17）
> 场景：Agent/API 平台卡 hover 驻留确认（0.8s）切换主面板 Token 板块内容。
> 现象：光晕下移动画收尾瞬间，上/下方相邻卡片闪一下 hover 背景——方向不定、时间很短，
> 且 hover 中的平台卡本身毫无异常。
> 结论先行：**「hover 确认驱动的内容切换」是周期性几何变化源，这类内容块的固有高度必须
> 恒定（行数不足留白），否则文档高度伸缩会让滚动位置重锚定、整块内容在静止光标下
> 滑动——滑到谁头上谁就被「真 hover」点亮，并经驻留确认形成自激循环。**
> 相关代码：`swift/TokensPanel.swift`（TokensPanelView.intrinsicContentSize / activityGridTop /
> refreshInlineTokens）、`swift/Controls.swift`（HoverCard mouseEntered / syncHoverState /
> startHoverDwell）、`swift/Panel.swift`（syncHoverAfterScroll / scheduleHoverSync）。

---

## 坑 1（主坑）：Token 板块固有高度随列表行数伸缩 → 内容滑动点亮邻居

### 翻车链路

1. 平台卡 hover 满 0.8s → `confirmTokensHover(source:)` → `refreshInlineTokens()`
   切换 Token 板块数据源；
2. `TokensPanelView.intrinsicContentSize` 的列表区高度按
   **`min(当前平台列表行数, maxListRows=4)`** 计算——不同平台行数不同（少则 2 行），
   切换即整块变矮/变高；
3. 文档高度变化 → 滚动位置重锚定（AppKit 底缘钳制 + `Panel.swift` 观察器再锚定），
   **窗口 frame 不变、光标不动，整块内容在屏幕上平移**（实测按 ±(卡高 40 + 间距) 跳动）；
4. 邻居卡滑到静止的光标下方 → `syncHoverAfterScroll` 的 hitTest 权威路径把它点亮
   ——**这不是假事件，内容真的滑过去了**，`HoverEnterValidation` 事件坐标校验自然拦不住；
5. 自激循环：邻居被点亮 → 它自己的 0.8s 驻留确认 → 又切一次板块 → 高度又变 → 又滑
   → 日志里连续三次 `confirm source=...` 就是这个环。

### 为什么第一轮修复无效

先入为主按「窗口原点平移 → AppKit 补发陈旧坐标 enter」（折叠/展开假 hover 同族）处理，
给 dwell 卡的 `mouseEntered` 加了实时光标校验——没用。方向不定（有时上有时下）本身就是
反证：与光标在卡内位置无关，而是内容整体滑动方向取决于这回变高还是变矮。

### 定位手段（值得复用）

四处埋点 `Logger.log(.layout, "[HoverDbg] ...")`：`mouseEntered` / `mouseExited` /
`syncHoverState` / `confirmTokensHover`，每行带事件坐标、卡片屏幕 rect
（`window.convertToScreen(convert(bounds, to: nil))`）、窗口 frame。一轮复现即可对表：
光标屏幕坐标恒定 + 卡片屏幕 rect 跳动 + 窗口 frame 恒定 ⇒ 滚动位置在跳，不是窗口/事件在骗。

### 修复：列表区恒保留 maxListRows 行，行数不足留白

```swift
// ❌ 翻车写法（TokensPanel.swift intrinsicContentSize）：高度随平台行数伸缩
let active = summary.flatMap { ... } ?? []
let rows = min(active.count, Self.maxListRows)
let height = activityGridTop(rows: rows) + activityGridHeight + activityAxisHeight + insets.bottom

// ✅ 定稿：恒保留 4 行，少则留白；draw 侧热力图锚点同步改（两处必须同源）
override var intrinsicContentSize: NSSize {
    let height: CGFloat = activityGridTop(rows: Self.maxListRows)
        + activityGridHeight + activityAxisHeight + insets.bottom
    return NSSize(width: Self.contentWidth, height: height)
}
// draw 内：gridTop: activityGridTop(rows: Self.maxListRows)   // 原为 rows: projects.count
```

高度零变化 ⇒ 文档不动 ⇒ 滚动不重锚 ⇒ 卡片不滑，链条从根上断掉。

---

## 坑 2（同场加映）：光晕位置动画收尾跳帧——动画终值 ≠ 模型值

光晕下移（dwell 进度视觉，2026-09-06 替换原左→右 mask 填充）第一版用 transform 平移 +
`fillMode = .forwards` + `isRemovedOnCompletion = false`，收尾偶发跳一帧：

1. `forwards` 常驻把 presentation 冻在**动画终值**，dwell 确认（GCD 计时）再移除动画
   回落到**模型值**——GCD 与 CA 时钟的毫秒级偏差、或中途 layout 动过模型，
   两个值一对不上就是一帧跳动；
2. `toValue` 捕获的是 `hoverGlowLayer.position`——面板刚重建就 hover 时 layout 尚未
   把层摆到位，捕获即偏，移除动画必跳。

```swift
// ✅ 定稿（Controls.swift startHoverDwell）：位置动画只驱动 presentation，模型恒终态
let final = CGPoint(x: hoverEffectLayer.bounds.midX, y: hoverEffectLayer.bounds.midY) // 从 bounds 现算
anim.fromValue = NSValue(point: CGPoint(x: final.x, y: final.y + offset))
anim.toValue   = NSValue(point: final)
anim.isRemovedOnCompletion = true   // 结束自动移除，presentation 直接回落模型值
// 确认/取消路径只 removeAnimation(forKey:)，不回写模型 —— 结构上无跳变
```

另：起始偏移必须 ≥ 光晕纵半轴（`0.65 × 卡高`），起始整团在卡外被 `masksToBounds`
裁掉，下移才全程可见——偏移小于半轴时光晕开场就露大半截，动画「没头」。

---

## 教训

- **凡是「驻留/hover 确认驱动内容切换」的块，切换前后固有高度必须恒定。**
  高度一变，滚动重锚定会让全部内容在静止光标下平移；邻居被点亮不是事件造假，
  是几何真的变了——事件层校验（`HoverEnterValidation`）对此无效。
- 假 hover 排查不能只盯事件路径：`syncHoverAfterScroll` 的 hitTest 权威同步
  一样会点亮卡片，而且点得「对」（当时光标确实在那）。
- 方向不定（有时上方有时下方）= 高度有时增有时减，是与光标位置无关的强信号，
  第一时间该怀疑内容整体平移而不是单点事件错位。
- 埋点四件套（enter / exit / sync / confirm）+ 「光标屏幕坐标 vs 卡片屏幕 rect」
  对表法，一轮日志即可区分「事件骗人」与「几何真动」。

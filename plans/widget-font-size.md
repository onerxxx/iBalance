# Widget 字号设计参考（仿 Apple Stocks Widget）

看这张图，整体非常接近 Apple 原生 Stocks（股票）Widget 的排版。以你这张图的视觉尺寸来估算，如果按 macOS / iOS 的 **pt 设计单位** 来还原，我会建议这样设置：

| 元素 | 推荐字号 | 字重 | SF Pro |
| --- | --- | --- | --- |
| AAPL | 26 pt | Semibold / Medium | SF Pro Display |
| ▲ 涨跌图标 | 15–16 pt | — | SF Symbols |
| +0.11 | 22 pt | Regular / Medium | SF Pro Display |
| Apple Inc. | 22 pt | Regular | SF Pro Text |
| +0.04% | 22 pt | Regular / Medium | SF Pro Display |
| 247.77 | 64 pt | Regular | SF Pro Display |

## 如果你是在 AppKit 里复刻

我会直接从这一组开始：

| 元素 | 设置 |
| --- | --- |
| AAPL | 26 pt, `.semibold` |
| Apple Inc. | 22 pt, `.regular` |
| +0.11 | 22 pt, `.medium` |
| +0.04% | 22 pt, `.medium` |
| 247.77 | 64 pt, `.regular` |

其中 **247.77** 是最关键的，它看起来明显不是普通的 56 pt，而是大约 **64 pt** 的 SF Pro Display 数字。

## 容易踩坑的地方

247.77 建议使用 `.monospacedDigit()`，但**不要**使用完整的等宽字体。也就是类似：

```swift
font = NSFont.systemFont(ofSize: 64, weight: .regular)
```

然后开启等宽数字特性。这样数字变化时不会因为 `2` / `4` / `7` 宽度不同导致整个价格左右抖动。

## 总结

如果你是在做你之前那个 macOS 数字滚动 Widget，我会更推荐：

**标题 26 / 辅助信息 22 / 主数字 64**

这一套比例基本就是这张图的核心视觉比例。

# 003 — 点阵淡变位图按原尺寸 1:1 烘焙（消除切换时整网格微位移跳动）

- **Status**: DONE (v2026.9.1.34)
- **Commit**: febc526
- **Severity**: MEDIUM
- **Category**: Performance（位图合成路径的几何副作用）
- **Estimated scope**: 1 文件（swift/TokensPanel.swift），单函数体重写 + 文档注释 2 行

## Problem

点击「每日/每周」切换（或 hover 平台卡触发切换）时，0.6s 点阵交叉淡变的**起止两端整网格有 ≤1px 的位置跳动**：淡变期间点阵走位图 blit 路径，常态走逐点直绘路径，两条路径几何不一致。

根因在 `renderDotsBitmap`（swift/TokensPanel.swift:1424-1454，当前代码原文）：

```swift
// swift/TokensPanel.swift:1434-1453 — current
let w = ceil(region.width), h = ceil(region.height)
let scale: CGFloat = 2
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .calibratedRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
for d in dots {
    let r = NSRect(x: d.rect.minX - region.minX,
                   y: h - (d.rect.maxY - region.minY),
                   width: d.rect.width, height: d.rect.height)
    stamp(level: d.level).draw(in: r, from: .zero, operation: .sourceOver,
                               fraction: 1, respectFlipped: false, hints: nil)
}
NSGraphicsContext.restoreGraphicsState()
guard let cg = rep.cgImage else { return nil }
return (NSImage(cgImage: cg, size: NSSize(width: w, height: h)), region)
```

两处错位：

1. **整图重缩放**：`region` 是分数尺寸（incoming 版 `7 * pitch`、pitch = 版心宽 ÷ 周列数，见 swift/TokensPanel.swift:1160-1162；outgoing 版取点集联合包围盒）。位图点尺寸被 `ceil` 抬到 (w, h)，而 blit 目标 rect 是原分数尺寸 region（swift/TokensPanel.swift:1172-1183 三处 `img.draw(in: region…)`），NSImage 按目标 rect 缩放绘制 → 实际缩放系数 `region.width / w ≤ 1`（约 0.4–1%），点位置误差随距 region 左缘线性增长，最右列可达 ~1px。
2. **垂直镜像用了 ceil 后的 h**（`y: h - (d.rect.maxY - region.minY)`）：位图内容相对 region 顶缘整体偏移 `ceil(h) - h`（0–1px），blit 时不补偿。

直绘路径（swift/TokensPanel.swift:1195-1206）按分数坐标逐点画、无重采样。于是淡变第一帧（直绘→位图）与结束帧（位图→直绘，`releaseDotsImages` 于 swift/TokensPanel.swift:1073/1093 调用）各发生一次整网格（含恒不透明的底点）微跳。

## Target

`renderDotsBitmap` 按 **region 原分数尺寸**烘焙：位图像素数 = 尺寸 × 2 四舍五入取整，`rep.size` 与 `NSImage.size` 恒等于 `region.size`，blit 目标 = 同一 region → 缩放系数恒 1.0；垂直镜像改用 `region.height`。函数签名、返回值结构、调用点全部不变。

替换 1434-1453 行（`let w = ceil…` 到函数尾 `return`）为：

```swift
// 按 region 原分数尺寸烘焙：像素 = 尺寸×2 取整，rep.size / NSImage.size = region 原尺寸，
// blit 回同尺寸 rect 恒 1:1 无重采样，与逐点直绘路径几何严格一致
let scale: CGFloat = 2
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int((region.width * scale).rounded()),
                                 pixelsHigh: Int((region.height * scale).rounded()),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .calibratedRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
rep.size = region.size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
for d in dots {
    let r = NSRect(x: d.rect.minX - region.minX,
                   y: region.height - (d.rect.maxY - region.minY),
                   width: d.rect.width, height: d.rect.height)
    stamp(level: d.level).draw(in: r, from: .zero, operation: .sourceOver,
                               fraction: 1, respectFlipped: false, hints: nil)
}
NSGraphicsContext.restoreGraphicsState()
guard let cg = rep.cgImage else { return nil }
return (NSImage(cgImage: cg, size: region.size), region)
```

同步修正函数文档注释（swift/TokensPanel.swift:1421）中「NSBitmapImageRep 2x」的口径描述为「像素 = region 尺寸 × 2，点尺寸 = region 原分数尺寸，blit 1:1」。

## Repo conventions to follow

- 注释一律中文，说明约束而非叙述代码（参照 swift/TokensPanel.swift:1410 MARK 段风格）。
- 最小改动：只改烘焙尺寸口径，不新增属性、不加防御性兜底（region 恒 ≥ 数 pt，像素数不会为 0）。
- AppKit 原生路径（NSBitmapImageRep / NSImage.draw），与 swift/RollingNumberView.swift 的 DigitWheelView 位图路径同款工具，但**本计划不动那处**。

## Steps

1. swift/TokensPanel.swift `renderDotsBitmap`（1424-1454）：删除 `let w = ceil(region.width), h = ceil(region.height)`，按 Target 代码块替换像素尺寸计算、`rep.size`、镜像 y、`NSImage(size:)` 四处。
2. swift/TokensPanel.swift:1421 文档注释按 Target 更新口径。
3. `cd swift && ./build.sh --fast` 编译（脚本会自动重启 App，属正常流程）。

## Boundaries

- 只改 `renderDotsBitmap` 函数体与其文档注释。DO NOT 触碰：`stamp()`、`rebuildIncomingDotsImages`、`drawActivitySection` 内 blit 调用点与直绘循环、`activityCells()` 几何、月份轴、`dotFadeDuration` / 缓动曲线。
- DigitWheelView（swift/RollingNumberView.swift）存在同款 ceil 烘焙模式，**不在本计划范围**，勿顺手改。
- 若行号/代码与本文摘录不符（相对 febc526 已漂移），STOP 并报告，不要即兴改写。

## Verification

- **Mechanical**: `./build.sh --fast` 输出 `Build complete!`，无新增 warning。
- **Feel check**（跳动 ≤1px，肉眼要看仔细，重点盯**最右 2–3 列**——旧误差随列数线性放大，右缘最明显）：
  1. 打开面板 → Token 板块 → 点「每周」再点「每日」，连点 3–4 轮：淡变全程底点网格（灰色无用量点）必须纹丝不动，只有绿色亮点亮度渐变；淡变结束瞬间（回直绘）不得再有整网格回跳。
  2. hover 另一 Token 平台卡触发平台切换（同一位图路径）：同样网格静止、只淡变。
  3. 系统设置开「减弱动态效果」再点切换：应无淡变直接落定（回归确认未破坏该分支）。
- **Performance**: 淡变期仍为 3 次 blit（像素数变化 <0.5%，无新增开销），切换动画不掉帧。
- **Done when**: 淡变起止两端观察不到位置跳动；直绘帧与淡变帧截图逐列对齐（可用 screencapture 连拍比对最右列点缘）。

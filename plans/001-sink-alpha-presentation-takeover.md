# 001 — staggerSinkOut alpha 从表现层接管（修打断弹亮）

- **Status**: DONE
- **Commit**: febc526（工作区含未提交改动，行号以摘录代码为准）
- **Severity**: HIGH
- **Category**: Interruptibility（可打断性）
- **Estimated scope**: 1 文件，~6 行

## Problem

`swift/PanelLayout.swift` 的 `staggerSinkOut`（子账号 chip 离场交错下沉淡出）中，
alpha 淡出直接从 **model 值**起播：

```swift
// swift/PanelLayout.swift:1188-1193 — current
                let layer = v.layer
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = per
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    v.animator().alphaValue = 0
                })
```

当入场动画 `staggerRiseIn` 在途时被打断（hover 驻留 0.8s 触发换入后、rise 的
0.4s+0.1s/格 播完之前就离开卡片），rise 的 model alpha 已被立即置 1、表现值尚在
0~1 之间。此时 sink 的 animator 动画从 model（1）起播——chip 会先**弹回全亮再淡出**。

同文件 `crossfade`（PanelLayout.swift:1092-1101）已有血泪注释与标准写法：
「模型值可能与在途 animator 动画的表现值脱节，读 presentation 才是权威」。
sink 漏掉了这层处理。

## Target

起播前把 alphaValue 钉到当前表现层值（crossfade 同款写法）：

```swift
// target
                let layer = v.layer
                // alpha 从表现层接管：rise 在途被打断时 model 已是 1、表现值 ~0.5，
                // 直接起播会先弹回全亮再淡出（crossfade 同款标准写法）
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                v.alphaValue = CGFloat(v.layer?.presentation()?.opacity ?? Float(v.alphaValue))
                CATransaction.commit()
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = per
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    v.animator().alphaValue = 0
                })
```

## Repo conventions to follow

- 可打断动画标准写法范式：`swift/PanelLayout.swift:1092-1101`（crossfade）——
  `CATransaction.setDisableActions(true)` 包裹的表现层钉值，`presentation() ?? model` 回退。
- transform 侧同函数内已有同款处理（`layer.presentation()?.transform.m42`）。

## Steps

1. `swift/PanelLayout.swift` staggerSinkOut 内、`NSAnimationContext.runAnimationGroup`
   之前插入表现层钉值块（见 Target）。

## Boundaries

- 不改 staggerRiseIn（其起点硬编码属 finding #4，本 plan 范围外）。
- 不改时长/曲线/幅度参数（用户定稿值）。

## Verification

- **Mechanical**: `swift/build.sh` 构建通过、应用自动重启。
- **Feel check**: hover Agent 卡 0.8s 驻留触发子账号条换入，在 chip 上升途中
  （换入后 ~0.2s）移出卡片——chip 应从当前半透明位置直接淡出下沉，不出现
  「先变全亮再淡出」的闪跳。
- **Done when**: 打断路径无 alpha 回弹；正常离场（无打断）视觉与改前一致。

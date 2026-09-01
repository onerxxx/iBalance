# 002 — chip 交错动效与点阵互换时长收敛进 Motion 取值表

- **Status**: DONE
- **Commit**: febc526（工作区含未提交改动，行号以摘录代码为准）
- **Severity**: MEDIUM
- **Category**: Cohesion & tokens（令牌一致性）
- **Estimated scope**: 2 文件，~20 行

## Problem

`swift/Panel.swift` 的 Motion 表头部声明「时长与曲线只允许从这里取，新增动效不得
再引入裸字面量」，但子账号条交错动效与点阵互换的参数全部散落为调用点字面量：

```swift
// swift/PanelLayout.swift:1127 — current
        let rise: CGFloat = 10
// swift/PanelLayout.swift:1138
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) { [weak v] in
// swift/PanelLayout.swift:1141,1149
                    ctx.duration = 0.4
// swift/PanelLayout.swift:1174-1176
        let sink: CGFloat = -14
        let per: TimeInterval = 0.35
        let gap: TimeInterval = 0.06
```

```swift
// swift/Panel.swift:1956-1957 — current（点阵淡出）
                                        ctx.duration = 0.35
                                        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 1/3, 1/3, 1, 1)
// swift/Panel.swift:2019（点阵恢复）
                                    ctx.duration = 1.0
```

ease-out cubic `cubic(1/3,1/3,1,1)` 在 crossfade（PanelLayout.swift:1105）与
点阵淡出（Panel.swift:1957）两处内联重复。

Motion 表豁免清单（脉冲循环、字符模糊切换 0.35、刷新按钮旋转 0.45）不含
stagger 系参数，属违规裸字面量。crossfade 自身的 0.35 在豁免清单内，不动。

## Target

Motion 表新增（放在 easeOutStrong / easeInOutStrong 之后）：

```swift
    /// ease-out cubic（等价 cubic-bezier(1/3,1/3,1,1)）：crossfade/点阵淡出
    /// 与字符模糊切换同步用（同周期同曲线的曲线半边）
    static let easeOutCubic = CAMediaTimingFunction(controlPoints: 1/3, 1/3, 1, 1)

    /// Agent 卡子账号条 chip 交错入场/离场（用户定稿节奏；入场 0.4s 与 Token
    /// 平台切换同款，豁免 emphasis 0.40 硬顶）
    enum chipStagger {
        /// 入场上移量（非 flipped 视图 -y 平移起步）
        static let riseOffset: CGFloat = 10
        /// 入场单块时长（strong ease-out）
        static let riseDuration: CFTimeInterval = 0.40
        /// 入场行间错峰
        static let riseGap: CFTimeInterval = 0.10
        /// 离场下沉量（调用处取负：-y = 视觉向下）
        static let sinkOffset: CGFloat = 14
        /// 离场单块时长（easeIn 重力感，用户指定）
        static let sinkDuration: CFTimeInterval = 0.35
        /// 离场行间错峰
        static let sinkGap: CFTimeInterval = 0.06
    }

    /// 点阵↔账号条互换的点阵侧时长（与字符模糊切换签名动效同周期）
    enum stripSwap {
        /// 点阵淡出
        static let dotsFade: CFTimeInterval = 0.35
        /// 点阵恢复：放慢与 chip 快速下沉形成节奏差（用户指定，豁免 0.40 硬顶）
        static let dotsRestore: CFTimeInterval = 1.0
    }
```

调用点替换（数值零变化，纯收敛）：

- `staggerRiseIn`：`riseOffset` / `riseGap`（`Double(i) * Motion.chipStagger.riseGap`）/
  `riseDuration`（ctx 与 anim 两处）
- `staggerSinkOut`：`let sink = -Motion.chipStagger.sinkOffset` /
  `per = Motion.chipStagger.sinkDuration` / `gap = Motion.chipStagger.sinkGap`
- Panel.swift 点阵淡出：`ctx.duration = Motion.stripSwap.dotsFade`、
  `ctx.timingFunction = Motion.easeOutCubic`
- Panel.swift 点阵恢复：`ctx.duration = Motion.stripSwap.dotsRestore`
- PanelLayout.swift crossfade（1105）：曲线替换为 `Motion.easeOutCubic`
  （0.35 时长在豁免清单，保留字面量）

## Repo conventions to follow

- Motion 表位于 `swift/Panel.swift:147-176`，曲线 token 范式：
  `easeOutStrong = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)`。
- 嵌套 enum 收纳同族参数的先例：无（首个嵌套命名空间，注释说明豁免口径）。

## Steps

1. `swift/Panel.swift` Motion 表追加 `easeOutCubic`、`chipStagger`、`stripSwap`。
2. `swift/PanelLayout.swift` staggerRiseIn/staggerSinkOut/crossfade 替换字面量。
3. `swift/Panel.swift` 点阵淡出/恢复替换字面量。

## Boundaries

- 数值零变化——本 plan 是纯收敛，任何行为差异都是 bug。
- 不动 crossfade 的 `0.35` 时长（豁免清单内签名动效）。
- 不动 `playCharBlurTransition`（签名动效豁免）。
- 不改 staggerRiseIn 起点硬编码（finding #4 范围外）。

## Verification

- **Mechanical**: `swift/build.sh` 构建通过。
- **Feel check**: 换入/离场的节奏与改前逐帧一致（rise 10pt/0.4s/0.1s、
  sink 14pt/0.35s/0.06s、点阵 0.35s 淡出 + 1.0s 恢复）。
- **Done when**: `grep -n '0\.4\b\| 0\.06\| 1\.0$' swift/PanelLayout.swift` 在
  stagger 两函数内无残留字面量；Motion 表内新增 token 就位。

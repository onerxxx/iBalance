# 006 — 中断态动效重设计：故障感信号断续（glitch flicker + jitter）+ 橙红色

- **Commit**: febc526（2026-09-02）
- **范围**：仅 `swift/PanelLayout.swift` 的 `CardTaskStatusRingView` 中断态分支。
- **目标**：中断态从「心跳双搏」改为「信号断续」故障动效（闪烁 + 抖动 + 掉线感），
  色相调为更饱和的橙红（#FF7333），与进行中蓝 / 完成绿拉开对比。
- **硬约束**：不改动 running / completed 两态的任何代码路径与常量；动画周期约 2.8s、
  位移 ≤1.5pt、透明度不低于 0.05——故障感来自节奏不规律，而非幅度剧烈；
  reduceMotion 路径保持现状（静态柔光两界中值）。

## 现状代码（执行前必读）

文件 `swift/PanelLayout.swift`：

1. **颜色**（`color(for:in:)`，约 1711-1720 行）：
   ```swift
   case .interrupted: ns = NSColor(calibratedRed: 1, green: 0.62, blue: 0.40, alpha: 1)
   ```
   （#FF9C66，偏橙粉，与要求「橙红」对比不足。）

2. **动画分发**（`restartAnimationsIfNeeded()`，约 1596-1598 行）：
   ```swift
   if state == .interrupted {
       addHeartbeat()
       return
   }
   ```

3. **心跳实现**（`addHeartbeat()`，约 1620-1640 行）：opacity + transform.scale
   keyframe 双搏，`beat` 挂 key `"taskGlowPulse"`、`scale` 挂 key `"taskHeartbeat"`。

4. **动画重铺清理**（同函数开头，约 1580-1584 行）已移除
   `"taskGlowPulse"` / `"taskHeartbeat"` / `"taskRipple"` / `"taskSweep"` ——
   新动画的 key 必须落在这些 key 内或新增 remove 行（见方案）。

5. **几何/layout**：中断态 cornerRadius = `side * 0.22`（layout 三分支最后一支），
   `glow.frame = boxRect`，**不动**。

6. **类注释**（约 1408-1422 行）第 ③ 行写「③ 中断 = 心跳双搏（demo D 风格），无涟漪」，
   需同步更新。

## 改动步骤

### Step 1 — 换色

`color(for:in:)` 中 interrupted 分支改为：

```swift
// 中断橙红（2026-09-02 用户要求故障态换更饱和橙红，#FF7333）：
// 与进行中蓝 140/214/255、完成绿 115/242/140 形成色相对比
case .interrupted: ns = NSColor(calibratedRed: 1, green: 0.45, blue: 0.20, alpha: 1)
```

### Step 2 — 动画分发改名

`restartAnimationsIfNeeded()` 中断分支：

```swift
if state == .interrupted {
    addGlitchSignal()
    return
}
```

### Step 3 — 心跳函数整体替换为信号断续

删除 `addHeartbeat()` 整个函数，原位新增：

```swift
/// 中断态 = 信号断续（故障感）：稳亮段中穿插两次「掉线」——
/// 掉线时 opacity 近乎瞬时砸落（84ms 内）、伴随 ±1.5pt 横向抖动，
/// 随即弹回；两次掉线间隔不均（30%→52%→70%），读作「连接时断时续」。
/// 动画只挂 glow（icon 不参与）；周期 2.8s，幅度克制不干扰阅读。
/// 2026-09-02 用户要求替换原心跳双搏（demo D 风格）。
private func addGlitchSignal() {
    let period: CFTimeInterval = 2.8
    // 信号闪烁：稳亮 0.45 → 掉线谷 0.05~0.10（近瞬时降、近瞬时回，
    // 相邻 keyTimes 差 0.03 ≈ 84ms，linear 曲线模拟信号「啪」断；
    // 70%-76% 处是长掉线：短暂回亮一拍再彻底熄灭，抖线感）
    let flicker = CAKeyframeAnimation(keyPath: "opacity")
    flicker.values = [0.45, 0.45, 0.06, 0.45, 0.45, 0.10, 0.45,
                      0.45, 0.05, 0.28, 0.05, 0.45, 0.45]
    flicker.keyTimes = [0, 0.30, 0.33, 0.36, 0.52, 0.55, 0.58,
                        0.70, 0.73, 0.76, 0.80, 0.84, 1.0]
    flicker.duration = period
    flicker.repeatCount = .infinity
    flicker.timingFunction = CAMediaTimingFunction(name: .linear)
    glow.add(flicker, forKey: "taskGlowPulse")
    // 横向抖动：只在两次掉线时刻 ±1.2~1.5pt 快速错位（信号丢失的「挣脱感」），
    // 其余时段归零静止；与闪烁同一周期，掉线点对齐
    let jitter = CAKeyframeAnimation(keyPath: "transform.translation.x")
    jitter.values = [0, 0, -1.5, 1.5, 0, 0, -1.2, 1.2, 0,
                     0, -1.5, 1.5, -0.8, 0.8, 0, 0]
    jitter.keyTimes = [0, 0.30, 0.315, 0.33, 0.345, 0.52, 0.535, 0.55, 0.565,
                       0.70, 0.715, 0.73, 0.745, 0.76, 0.775, 1.0]
    jitter.duration = period
    jitter.repeatCount = .infinity
    jitter.timingFunction = CAMediaTimingFunction(name: .linear)
    glow.add(jitter, forKey: "taskHeartbeat")
}
```

**说明**：
- 复用现有 key `"taskGlowPulse"` / `"taskHeartbeat"`，Step 4 的清理逻辑无需新增行。
- 不做 scale 动画（原心跳的缩放语义与「断线」无关，保持几何静止更冷静）。
- 常量 `coreHigh = 0.45` 与 flicker 稳亮值一致，勿在此处引用 `Self.coreHigh`
  写死数值即可（数组字面量，注释说明对齐关系）。

### Step 4 — 注释同步

1. 类头注释第 ③ 行改为：
   `/// ③ 中断 = 信号断续（故障感：闪烁 + 掉线 + 横向抖动），无涟漪。`
2. `color(for:in:)` 上方/行内注释按 Step 1 示例。

## 不许做

- 不改 `coreLow` / `coreHigh` / `period` 等共享常量（completed 态在用）。
- 不改 running / completed 分支、`addRipple` / `addSweep` / sweep 相关任何代码。
- 不改 layout 几何（中断态保持 `side × 0.22` 圆角）。
- 不新增图层；只复用 glow。

## 验证

1. `bash swift/build.sh` 编译通过（警告与现状一致即可）。
2. App 自动重启后（可用 `--show-panel` 弹面板）hover 到中断态 Agent 卡确认：
   - 颜色为橙红 #FF7333，明显比原橙粉更「警示」；
   - 每约 2.8s 出现两次快速熄灭-回亮 + 轻微横移，节奏不规律但整体平缓；
   - 进行中（蓝扫描）/ 完成（绿涟漪）两态视觉与之前完全一致。
3. reduceMotion（系统设置「减弱动态效果」开启）下仍为静态柔光、无动画。

# iBalance 动效踩坑记：AppKit / Core Animation

> 场景：iBalance 面板 hover 动效体系——子账号 chip 交错入场/离场、点阵（进度条）淡出/恢复、
> crossfade、hover 背景过渡，全部跑在 layer-backed NSView 上。
> 结论先行：**透明度/位移类动画一律用显式 CABasicAnimation + 显式 fromValue + 禁隐式钉 model，
> 不用 `animator()` 路径做可被打断的动画**。
> 定稿版本：v2026.9.1.26（2026-09-01）。相关代码：`swift/Panel.swift`（Motion 表、onHover 换入/换出块）、
> `swift/PanelLayout.swift`（staggerRiseIn / staggerSinkOut / crossfade）、`swift/Controls.swift`（HoverCard / SubAccountItemView）。

---

## 坑 1：animator() 的 fromValue=nil 陷阱——「恢复瞬间亮起」根因

`NSAnimationContext` + `view.animator().alphaValue = x` 底层生成 `CABasicAnimation` 时
**fromValue 不指定**，CA 规则是取 **add 动画那一刻的 presentation 值**。

点阵恢复的真实翻车序列：

1. 淡出播完落藏：`isHidden = true` + `alphaValue = 1`（model opacity 回写为 1）
2. 恢复时同拍执行：`isHidden = false` → `animator().alphaValue = 1`
3. CA 取 fromValue = presentation = **1**（旧 model）→ 动画实际是 **1→1 空转 N 秒**
4. hidden=false 首帧直接以 opacity=1 渲染 → 视觉「瞬间亮起」

**正解：显式 CABasicAnimation，三件套缺一不可**：

```swift
// ❌ 翻车写法：animator 路径，fromValue 由 CA 猜
dotsView.isHidden = false
dotsView.alphaValue = startAlpha
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 1.2
    dotsView.animator().alphaValue = 1   // fromValue=nil → 取 presentation(=旧model 1) → 空转
}

// ✅ 定稿写法（Panel.swift 点阵恢复块同款）
let layer = dotsView.layer!
layer.removeAnimation(forKey: "dotsFadeSwap")
layer.removeAnimation(forKey: "opacity")          // 清隐式动画残留 key
CATransaction.begin()
CATransaction.setDisableActions(true)
layer.opacity = Float(startAlpha)                 // 起播值先钉 model（禁隐式）
CATransaction.commit()
let anim = CABasicAnimation(keyPath: "opacity")
anim.fromValue = Float(startAlpha)                // fromValue 显式钉住，不猜
anim.toValue = Float(1)
anim.duration = Motion.stripSwap.dotsRestore
anim.timingFunction = Motion.stripSwap.dotsRestoreTiming
layer.add(anim, forKey: "dotsRestore")
CATransaction.begin()
CATransaction.setDisableActions(true)
layer.opacity = 1                                 // model 落终位（播完动画移除即停在 1）
CATransaction.commit()
```

配套规则：

- **起播前必须钉 model**：hidden=false 的首帧按 model 渲染，不钉会以旧值全亮一帧。
- **接管前双向 removeAnimation**：淡出↔恢复互清对方的 key，再清 `"opacity"`（隐式动画残留 key），否则同 keyPath 互踩。
- **fillMode `.forwards` 的动画会压住 presentation**：换入时必须 `removeAnimation(forKey:)` 摘掉，否则读到的是残留表现值。

## 坑 2：可打断动画从 model 值起播——「打断弹亮」

`v.animator().alphaValue = 0` 从 **model 值**起播。交错入场（rise）在途被打断时，
model alpha 已是 1、视觉值才 ~0.5 → 离场直接起播会**先弹回全亮再淡出**。

```swift
// ❌ 从 model 起播
NSAnimationContext.runAnimationGroup { ctx in
    v.animator().alphaValue = 0
}

// ✅ 起播前把 model 钉到表现层当前值（crossfade 同款写法，repo 范式）
let current = v.layer?.presentation()?.opacity ?? Float(v.alphaValue)
CATransaction.begin()
CATransaction.setDisableActions(true)
v.alphaValue = CGFloat(current)
CATransaction.commit()
NSAnimationContext.runAnimationGroup { ctx in
    v.animator().alphaValue = 0
}
```

口诀：**model 是「意图」，presentation 是「现实」。可打断的动画永远从现实出发。**

## 坑 3：同事件拍内「先改 model 再读 presentation 冻结」不可靠——「背景一帧拍灭」

需求：离场时冻结 chip 背景在当前视觉色。翻车写法：

```swift
// mouseExited 时序：syncInteractiveHover（setHovered(false) 已把背景 model 改成默认色）
// → performHoverExitVisuals → freezeBackground()
let current = layer.presentation()?.backgroundColor ?? layer.backgroundColor  // ← 回退读到污染后的 model
CATransaction.setDisableActions(true)
layer.backgroundColor = current   // 把默认色钉死 = 亮背景一帧拍灭
```

`presentation()` 只反映**上次提交**的帧；同一事件拍内刚改完 model，presentation 拿不到，
回退分支读到的是**刚被改写的 model**——冻结反而把渐变拍成瞬间消失。

**正解：冻结 = 标志位阻止后续写入，不是事后钉值。**

```swift
// SubAccountItemView：冻结期间 applyState 跳过背景写入，model 天然保持离场前值
private var backgroundFrozen = false
func freezeBackground() { backgroundFrozen = true }
private func applyState(animated: Bool) {
    if !backgroundFrozen {
        layer?.backgroundColor = bg.cgColor   // 冻结期不写，保持原色
    }
    ...
}
```

配套规则：**事件顺序上冻结必须先于状态复位**——`mouseExited` 先 `performHoverExitVisuals`（冻结生效）
再 `syncInteractiveHover`（setHovered(false) 的背景写入被跳过）。

## 坑 4：长时长恢复动画禁用纯 easeIn——「末尾冲刺」

纯 `easeIn`（cubic-bezier 0.42,0,1,1）+ 5s 的亮度分布：前 4s 只到 ~50%，
**最后 1s 集中完成 ~45% 的变化** → 观感 = 憋很久 + 末尾冲刺 = 「瞬间亮起」。
曲线越 in、时长越长，冲刺越集中。

**正解**：末段必须有缓收控制点。定稿曲线 `cubic-bezier(0.5, 0, 0.7, 1)`
（`Motion.stripSwap.dotsRestoreTiming`）：前半慢起步（2.5s 到 30%）、中段加速、末 0.5s 仅 5% 收尾。

## 坑 5：CATransform 方向与矩阵字段

- **非 flipped NSView 的 layer 平移：-y = 视觉向下、+y = 视觉向上**。
  与 Auto Layout centerY 约束的翻转语义（本项目实测：正值=向下）**相反**，别混用两套口径。
  staggerRiseIn 入场 `-rise` 起步 = 下方上收；staggerSinkOut 离场 `sink=-14` = 向下沉。
- **CATransform3D 平移 y 在 `m42`，`m32` 恒为 0**。接管在途动画时读错字段会跳回 0 起点：

```swift
// ❌ m32 恒 0，接管时动画跳回起点
anim.fromValue = layer.presentation()?.transform.m32 ?? 0
// ✅
anim.fromValue = layer.presentation()?.transform.m42 ?? 0
```

## 坑 6：override NSView.alphaValue 写日志 → 堆损坏闪退

为调试在 `UsageDots` override `alphaValue` 打印调用栈 → 离场必现闪退。崩溃形态随机
（attributedString RLE 越界 SIGSEGV / `_xzm_xzone_malloc_freelist` trap，
崩溃点在布局、JSON 解析等**无关分配点**）——典型堆损坏，崩溃点 ≠ 损坏点。

**macOS 27 上不要 override `NSView.alphaValue` 做日志拦截**（AppKit 动画 proxy/KVC 路径与
Swift computed override 存在内存安全冲突）。调试动画写入改用**手动标记日志**（在动画块起止处
显式打一行），或落文件而非 NSLog。

## 坑 7：交错动画的完成判定与取消

- **完成回调按「动画播完」触发，不是「最后一块启动」**：`onAllFinished` 需在
  最后一块启动后再 `asyncAfter(per)`，且回调前重查 `isCancelled`——否则离场动画
  一启动就执行落藏+复位，视觉立即被打断。
- **延迟块必须有取消机制**：每块 `asyncAfter` 里先查 `isCancelled?()`（代际 epoch 校验），
  否则入场/离场快速交替时旧块继续播，新块被压。
- **起播值采集注意隐藏态**：`isHidden == true` 不代表 alpha=0（隐藏前 model 常被回写为 1，
  presentation 也报 1）——隐藏态恢复必须从 0 起淡：

```swift
let dotsAlpha: CGFloat = dotsView.isHidden
    ? 0                                    // 隐藏态：从 0 起淡
    : CGFloat(dotsView.layer?.presentation()?.opacity ?? Float(dotsView.alphaValue))
```

## 速查表

| 症状 | 根因 | 修法 |
|---|---|---|
| 恢复「瞬间亮起」 | animator fromValue=nil 取到旧 model=1，1→1 空转 | 显式 CABasicAnimation 三件套（坑 1） |
| 打断时先弹亮再淡出 | 从 model 起播，model 已是终值 | 起播前钉 presentation（坑 2） |
| 冻结后背景瞬间消失 | 同拍内读 `presentation() ?? model` 读到污染值 | 标志位阻止写入 + 冻结先于复位（坑 3） |
| 长动画末尾「冲刺」 | 纯 easeIn 把大半变化压进末段 | 末段缓收曲线 y2<1（坑 4） |
| 位移方向反了 | CATransform -y=向下，与 AL centerY 相反 | 统一口径（坑 5） |
| 接管动画跳回起点 | transform 平移读了 m32（恒 0） | 读 m42（坑 5） |
| 加日志后随机闪退 | override alphaValue 与动画 proxy 冲突 | 手动标记日志（坑 6） |
| 离场一启动就结束 | 完成回调按「最后块启动」触发 | asyncAfter(per) + 重查取消（坑 7） |
| 隐藏恢复「立即完成」 | 隐藏态 model/presentation 都是 1 | isHidden 时从 0 起淡（坑 7） |

---

相关：`plans/README.md`（未立项的结构重构记录——换入/换出状态机散布 5 处变量是上述多个坑的共同温床）。

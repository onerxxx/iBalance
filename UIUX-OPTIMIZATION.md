# iBalance UI/UX 优化清单

> 基于 Emil Kowalski 设计工程原则（Design Engineering）对 `swift/Panel.swift`（v2026.8.23.27）的逐项审查。
> 每项含：现状定位 → Before/After 对照 → 完整代码 → 参数依据。
> 核心理念：**用户注意不到的细节叠在一起，才构成"手感"**。这份清单只谈那些"每个都小、合起来大"的事。

---

## 0. 优先级速览

| # | 项 | 频次 | 判定 | 工作量 |
| --- | --- | --- | --- | --- |
| 1 | 统一动效计时系统（Motion Tokens） | — | 基建，先做 | 小 |
| 2 | 按压反馈（scale 0.97） | 每次点击 | **P0** | 小 |
| 3 | 数值刷新交叉淡化 | 每轮刷新 | P1 | 小 |
| 5 | 首开面板 stagger 编排 | 仅首次 | P1 | 小 |
| 6 | 区块折叠淡化 | 偶尔 | P1 | 小 |
| 8 | 手动刷新按钮旋转 | 偶尔 | P2 | 极小 |
| 7 | reduced-motion 审计 | 无障碍 | P2 | 中 |
| 9 | 失败态可见性 | 异常时 | P2 | 中 |
| 11 | 表头对比度 | 恒定 | P2 | 极小 |
| 4 | 字重动画时长 | 每次 hover | 争议项 | 极小 |
| 10 / 12 | Tooltip 补全 / 空态 | — | P3 | 小 |

---

## 1. 统一动效计时系统（Motion Tokens）

**现状**：全仓 9 种 duration（0.15 / 0.2 / 0.22×5 / 0.25 / 0.35 / 0.5 / 0.6 / 1.0 / 2.0），easing 全部用系统命名曲线（`easeOut` / `easeInEaseOut`）。问题不是某个值错了，而是**没有体系**——0.22 和 0.2 同时存在就是证据。系统性曲线缺失会让每个新动效都靠拍脑袋。

**建议**：一个 `Motion` 枚举集中管理时长与曲线。所有新动效从取值表里选，不新增数值。

| 用途 | Token | 值 | 依据 |
| --- | --- | --- | --- |
| 按压反馈 | `Motion.press` | 120ms | 100–160ms 区间下沿，越快越"跟手" |
| hover 状态切换 | `Motion.hover` | 150ms | 高频交互，宁短勿长 |
| 布局重排/换位 | `Motion.layout` | 200ms | 屏上位移，ease-out 收尾 |
| 内容揭示/淡入 | `Motion.reveal` | 240ms | 偶发动作可稍从容 |
| 强调/签名动效上限 | `Motion.emphasis` | 400ms | 一切 UI 动画 ≤ 400ms 硬顶 |

```swift
/// 动效统一取值表：时长与曲线只允许从这里取（emil-design-eng 计时规范）
enum Motion {
    static let press:   CFTimeInterval = 0.12
    static let hover:   CFTimeInterval = 0.15
    static let layout:  CFTimeInterval = 0.20
    static let reveal:  CFTimeInterval = 0.24
    static let emphasis: CFTimeInterval = 0.40

    /// 强 ease-out（等价 cubic-bezier(0.23, 1, 0.32, 1)）：入场/反馈用，
    /// 起手快，收尾长——比系统 easeOut 更"有意图"
    static let easeOutStrong = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    /// 强 ease-in-out（等价 cubic-bezier(0.77, 0, 0.175, 1)）：屏上位移用
    static let easeInOutStrong = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
    /// 线性：仅持续运动（旋转/进度）用
    static let linear = CAMediaTimingFunction(name: .linear)
}
```

迁移方式：逐处替换字面量（`ctx.duration = 0.22` → `ctx.duration = Motion.hover`），不改行为只收编数值。**禁用 `easeIn` 家族**（系统 `easeInEaseOut` 中入段偏慢，位移类建议换 `easeInOutStrong`）。

---

## 2. 按压反馈（P0：全控件缺失）

**现状定位**：`HoverCard.mouseDown`（Panel.swift:1883）。点击在 `mouseUp` 且落点在 bounds 内才触发 `onClick`——逻辑正确（防拖出误触），但**从按下到抬起之间零视觉反馈**。磁贴、账号卡片、用量行全部如此。用户按下按钮的瞬间，界面没有"听到"的表示。

**方案**：`mouseDown` 立即 `scale(0.97)`，抬起/取消/转为拖拽时复原。缩放走 layer transform，不动布局。

| Before | After | Why |
| --- | --- | --- |
| 按下无任何状态，抬起点击才生效 | 按下 120ms 内缩至 0.97 并微降亮度 | 按压是最高频交互，反馈必须即时且克制 |
| 拖拽开始时无过渡 | 转拖拽瞬间复原 scale | 拖拽 ghost 与按压态互斥，避免两个"按住"视觉并存 |
| `NSAnimationContext` 动画 alpha | `CABasicAnimation` 动 layer transform | transform 走 GPU 合成，不触发布局；与 hover 渐变子层无冲突 |

```swift
// HoverCard 内新增（wantsLayer 已为 true；hover 渐变/边框均为子层，随宿主 transform 同步缩放属预期）

/// 按压态：scale 0.97（120ms ease-out 进，160ms 回）；拖拽开始前必须复原
private var pressed = false {
    didSet {
        guard pressed != oldValue else { return }
        // 直接写 transform（ Animatable 属性立即生效需关隐式动画 ）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.transform = pressed
            ? CATransform3DMakeScale(0.97, 0.97, 1)
            : CATransform3DIdentity
        CATransaction.commit()
        // 亮度微降：内容整体 alpha 0.92，与 hover 提亮方向一致但幅度更小
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = pressed ? Motion.press : 0.16
            ctx.timingFunction = Motion.easeOutStrong
            self.animator().alphaValue = self.pressedAlphaBaseline * (pressed ? 0.92 : 1)
        }
    }
}

override func mouseDown(with event: NSEvent) {
    guard onDragStarted != nil, let window else { return }
    pressed = true                       // ← 新增：按下即反馈
    let start = event.locationInWindow
    var dragging = false
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                      until: .distantFuture,
                                      inMode: .eventTracking,
                                      dequeue: true) {
        if next.type == .leftMouseDragged {
            if !dragging {
                let current = next.locationInWindow
                let distance = hypot(current.x - start.x, current.y - start.y)
                guard distance >= 3 else { continue }
                dragging = true
                pressed = false          // ← 转拖拽立即复原
                NSCursor.closedHand.push()
                onDragStarted?(current)
            }
            onDragChanged?(next.locationInWindow)
        } else if next.type == .leftMouseUp {
            pressed = false              // ← 抬起复原（无论是否触发 onClick）
            if dragging {
                onDragChanged?(next.locationInWindow)
                onDragEnded?()
                NSCursor.pop()
            } else {
                onClick?()
            }
            return
        }
    }
    pressed = false
    /* …原兜底不变… */
}
```

**参数**：

| 参数 | 值 | 说明 |
| --- | --- | --- |
| scale | **0.97** | 0.95–0.98 之间的克制值；0.9 以下会"塌" |
| 进入 | 120ms `easeOutStrong` | 快进 |
| 复原 | 160ms `easeOutStrong` | 略慢于进入，抬起比按下从容 |
| alpha 叠加 | ×0.92 | 与子账号卡 0.6 弱化区分开；按压是瞬态不是状态 |

**注意**：`pressedAlphaBaseline` 需记录进入按压时的 alpha（子账号卡 0.6 / 正常 1.0 / hover 复亮中的插值），抬起时还原到基准而非硬编码 1，否则会破坏弱化体系。禁用拖拽的卡片（`onDragStarted == nil`）走 `mouseUp` 路径，可在 `mouseUp` 里对 bounds 内点击补同样的 120ms 脉冲。

---

## 3. 数值刷新交叉淡化

**现状定位**：`applyAccountCardData` 直接 `e.valueLabel.stringValue = ac.value ?? "—"`。每轮刷新（1/3/5 分钟）余额数字瞬跳。数据是新的，**变化本身是生硬的**——这正是"防止不和谐变化"类动画的定义场景（偶发、标准动画适用）。

**方案**：值有实际变化时做 150ms 淡化，用**轻模糊掩盖新旧两态重叠**（crossfade 里人眼会同时看到两个数字，短促 blur 让大脑判定为"同一个数字在变"而非"两个数字在换"）。

| Before | After | Why |
| --- | --- | --- |
| `stringValue` 直接覆写，数字瞬跳 | 变化时 150ms：alpha 1→0.35→1，中点换值 + 短 blur | 数字刷新是本 app 的核心节拍，值得打磨 |
| 每次都动 | 仅旧值 ≠ 新值时动 | 无变化不动画，避免每轮刷新全屏闪 |

```swift
extension NSTextField {
    /// 数值安全更新：变化时 150ms 交叉淡化（中点换值 + 2px 短模糊盖住双影）
    /// fade: 是否动效（refresh 节奏调用，低频允许标准动画）
    func setValueAnimated(_ newValue: String) {
        let old = stringValue
        guard old != newValue else { stringValue = newValue; return }
        guard let layer else { stringValue = newValue; return }   // 非 layer 视图直写
        // 中点换值：先淡出到 0.35（70ms），换字符串，再淡回（80ms）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.07
            ctx.timingFunction = Motion.easeOutStrong
            self.animator().alphaValue = 0.35
        }, completionHandler: {
            self.stringValue = newValue
            // 2px 高斯模糊脉冲：盖住新旧字形的重叠残影（≤20px，两帧即散）
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.setValue(2.0, forKey: "inputRadius")
            layer.filters = [blur]
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.08
                ctx.timingFunction = Motion.easeOutStrong
                self.animator().alphaValue = 1
            }, completionHandler: {
                layer.filters = nil
            })
        })
    }
}
```

接入点：`applyAccountCardData` 的 `e.valueLabel.stringValue = …` 改为 `setValueAnimated(…)`；用量行文本因整行动画成本高，暂不动。**节流**：同一 label 350ms 内的连续调用直接覆写（刷新风暴时不叠动画）。

---

## 4. hover 标题字重动画：1.0s（争议项，谨慎）

**现状定位**：`weightAnimDuration: CFTimeInterval = 1.0`（Panel.swift:3629）。余额卡 hover 时标题 400↔800 字重渐变 1s。按频率表，hover 属"每天数十次"档，应"移除或大幅缩减"；1s 是 300ms 上限的 3.3 倍。

**但这不是普通 hover**——它是 Inter 可变字体的**签名展示位**（这个功能本身就是为了展示字重轴），慢速插值是内容而非装饰。两个方向：

| 方案 | 改法 | 理由 |
| --- | --- | --- |
| A. 收敛 | `weightAnimDuration = 0.42`，曲线换 `easeInOutStrong` | 420ms 仍能看清字重轴滑动，回到"可等待"区间 |
| B. 保留 + 不对称 | 进入 500ms `easeOut`，移出 300ms `easeIn` 反曲线 | 进入慢（展示），退出快（让位）——按压慢/响应快的不对称原则 |

```swift
// 方案 B：拆分进入/退出时长（animateTitleWeight 已有方向参数，加 duration 参数即可）
private func animateTitleWeight(label: NSTextField, to target: Double) {
    let entering = target == weightAnimBold
    weightAnimDuration = entering ? 0.5 : 0.3
    /* …其余不变… */
}
```

**建议先 B**：签名感保留，等待感减半。用户对该动画已有多轮调校记录，动之前务必先征求意见。

---

## 5. 首次开面板的 stagger 编排

**现状**：面板打开（含浮窗）时所有区块同帧出现。高频动作（点菜单栏图标）不该有开场动画——**但每次进程启动后的第一次打开**是低频时刻，值得一次编排。

**方案**：仅 `previousSnapshot == nil`（首帧）时，平台卡片组从上到下 40ms 阶梯、每组 240ms「上浮 6pt + 淡入」，`easeOutStrong`；第二次起的打开零动画。

| Before | After | Why |
| --- | --- | --- |
| 所有组同帧硬出 | 首开 40ms 阶梯 × 240ms 上浮淡入 | 元素集体同时出现是审查清单明确项 |
| 每次打开都编排 | 仅首帧 | 高频路径（100+/日）零动画铁律 |
| — | `shouldReduceMotion` 时跳过位移只留透明度 | 减动效≠零动效 |

```swift
// update() 内，余额组重建完成后（balanceGroupContainer 就位）：
if previousSnapshot == nil {          // 仅本进程首帧
    let groups = platformOrder.compactMap { platformCards[$0] }.filter { !$0.isHidden }
    for (i, g) in groups.enumerated() {
        g.wantsLayer = true
        let dy: CGFloat = shouldReduceMotion ? 0 : 6
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        g.layer?.setTransform(CATransform3DMakeTranslation(0, -dy, 0))
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reveal                       // 240ms
            ctx.timingFunction = Motion.easeOutStrong
            // 层位移方向与视图坐标系相反（flipped 内容层 y 向下为正 → 用 -dy 预置）
            g.layer?.add(CABasicAnimation(keyPath: "transform.translation.y"), forKey: nil)
            g.animator().alphaValue = 1
        }, completionHandler: nil)
        // 阶梯延迟：40ms × index（保持 30–80ms 区间）
        g.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.04) {
            Self.reveal(g, dy: dy)
        }
    }
}

private static func reveal(_ v: NSView, dy: CGFloat) {
    let anim = CABasicAnimation(keyPath: "transform.translation.y")
    anim.fromValue = -dy
    anim.toValue = 0
    anim.duration = Motion.reveal
    anim.timingFunction = Motion.easeOutStrong
    anim.isRemovedOnCompletion = true
    v.layer?.add(anim, forKey: "reveal")
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = Motion.reveal
        v.animator().alphaValue = 1
    }
}
```

（示意骨架，落地时合并为单一辅助函数；非 flipped 坐标下 `fromValue` 取 `+dy`，以实测方向为准。）

**参数**：阶梯 40ms（区间 30–80ms，超 80ms 显慢）；单体 240ms；总编排时长 ≤ 240 + 40×组数（5 组 = 440ms 封顶）。编排期间**不阻塞任何交互**。

---

## 6. 区块折叠：瞬切 → 内容淡化

**现状定位**：`collapsibleSectionTitle` 的 `onClick` 直接 `isHidden.toggle()` + `setCustomSpacing` 切换。展开/折叠是内容瞬消瞬现。

**为什么不做高度动画**：本仓历史上高度/布局动画有多个坑（pin 转移闪帧、异步拉回必闪帧、`NSViewController.preferredContentSize` 摘除补丁等，见 IMPROVEMENTS 附录 D）。高度插值会触发布局级联，风险远大于收益。

**方案**：只动透明度——折叠：内容 120ms 淡出 → `isHidden = true`；展开：`isHidden = false` → 150ms 淡入。高度瞬变被淡入淡出"解释"掉了，零布局风险。

```swift
// collapsibleSectionTitle 的折叠路径改造（targets 闭包返回的目标视图集合）：
func setCollapsed(_ collapsed: Bool, animated: Bool) {
    for target in collapseTargets() where !target.isHidden || !collapsed {
        if collapsed {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.hover                 // 150ms 淡出
                ctx.timingFunction = Motion.easeOutStrong
                target.animator().alphaValue = 0
            }, completionHandler: {
                target.isHidden = true
                target.alphaValue = 1                       // 复位，下次展开直接淡入
            })
        } else {
            target.isHidden = false
            target.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.reveal                // 240ms 淡入
                ctx.timingFunction = Motion.easeOutStrong
                target.animator().alphaValue = 1
            })
        }
    }
    // 标题下间距同步（原逻辑）+ chevron 旋转：
    // chevron.image 已有方向切换，补一个 0.15s rotation 过渡更佳（见 §8 的旋转写法）
}
```

连点防抖：`isCollapsed` 切换期间（约 200ms 窗口）忽略再次点击，或用 `NSAnimationContext.current().duration` 检测进行中。

---

## 7. reduced-motion 审计

**现状**：`shouldReduceMotion` 只覆盖两处（平台换位动画、两列切换淡入）。未覆盖的动效：

| 未覆盖项 | 位置 | 减动效策略 |
| --- | --- | --- |
| pin 滑入 0.25s | `togglePanelPin` | 位移取消，保留 alpha |
| 子卡 hover 复亮 0.15s | `HoverCard.onHover` | 保留（透明度类，理解性动效） |
| 切号中透明度脉冲 0.5s 往复 | `rebuildAccountCards` onClick | 保留 alpha、去除往复（改单次 0.4→1） |
| 点阵脉冲 / 签到磁贴脉冲 | `UsageDots` / `setInProgress` | 降频至 1/3 或换静态高亮 |
| 字重动画 1s | `animateTitleWeight` | 位移类没有；字重插值温和可保留但时长减半 |
| QuietScrollView EMA 平滑 | `QuietScrollView` | 已是缓冲非位移动画，保留 |
| 数字淡化（§3 新增） | — | 保留 alpha 分支，去 blur 脉冲 |

统一守卫模式（逐步落到各处）：

```swift
// 位移动画一律包守卫；透明度/颜色保留：
if shouldReduceMotion {
    v.isHidden = collapsed                      // 直接终态
} else {
    setCollapsed(collapsed, animated: true)
}
```

---

## 8. 手动刷新按钮：旋转反馈

**现状定位**：`RefreshIconButton`（16×16，icon `arrow.clockwise`）。点击后除了 footer 文本换「刷新中…」无按钮自身反馈——按钮离视线焦点最近，反馈却最远。

**方案**：点击后 icon 旋转。持续运动用**线性**；时长与真实刷新解耦（不假装进度），转一圈表达"开始了"即可；刷新完成时图标已复位。

```swift
// RefreshIconButton 内：
func spinOnce() {
    guard let layer = ivRef.layer else { return }   // icon imageView，wantsLayer = true
    let anim = CABasicAnimation(keyPath: "transform.rotation")
    anim.fromValue = 0
    anim.toValue = -CGFloat.pi * 2                  // 逆时针 = clock-wise arrow 的自然方向
    anim.duration = 0.6
    anim.timingFunction = Motion.linear             // 持续运动用线性
    layer.add(anim, forKey: "spin")
}
// manualRefreshTapped() 里调用 spinOnce()；isRefreshing 结束前再次点击不叠转
// （key 相同的 CABasicAnimation 重启会从 0 起跳，天然可中断）
```

**参数**：360° / 600ms / linear。不循环（循环=假进度）；刷新通常 >1s，一圈转完即止的"启动确认"比持续空转诚实。

---

## 9. 失败态可见性

**现状**：服务获取失败仅 footer 追加「· x 项失败」（文本），对应平台卡片数值**静默显示旧值**。用户扫一眼卡片区无法发现"这个数是旧的"。

**方案（克制版）**：失败后 60s 内，该平台当前账号卡数值降为 65% 不透明度 + 数值右侧不加任何新元素（不加角标——角标语义已被签到失败占用）。恢复成功即复亮。

```swift
// PanelSnapshot 平台卡片快照加一个字段：
var stale: Bool = false     // 本轮刷新该平台失败（AppDelegate 组快照时按 failedServices 填充）

// applyAccountCardData 内：
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = Motion.hover
    ctx.timingFunction = Motion.easeOutStrong
    e.valueLabel.animator().textColor = ac.stale
        ? NSColor.white.withAlphaComponent(0.65)
        : (ac.isCurrent ? kBalanceForeground : Palette.cardForegroundDimmed)
}
```

**为什么不用红色**：红=签到失败体系的既定语义；网络失败是"不确定"不是"错误"，降透明是可恢复的中性态。60s 超时自动复亮（避免长期半透明被当成弱化）。

---

## 10. Tooltip 补全（P3）

已达标的：10 个操作磁贴全部有 tooltip（HIG 合规）✓。缺口：

| 控件 | 建议 tooltip |
| --- | --- |
| 设置行「余额两列」 | "平台组两列网格排列；两列下不可拖拽排序" |
| 设置行「Mono 风格 / Recursive / Inter」 | 各自标注优先级关系（Mono > Recursive > Inter） |
| 账号卡片 | 完整昵称 + uid 尾 4 位（昵称平时 hover 淡入，tooltip 提供持久副本） |
| 用量表头「1小时」 | "最近 1 小时的用量（滚动窗口）" |

AppKit tooltip 无延迟控制（系统统一），接受即可——本仓 tooltip 均为补充信息非必需信息，默认延迟不构成伤害。

---

## 11. 表头对比度（P2，一行改动）

**现状**：用量表头 10pt `systemGray`（#8E8E93 on 近黑玻璃 ≈ 4.1:1）。小字号（<11pt）下 WCAG AA 要求 4.5:1，当前临界偏低。

| Before | After | Why |
| --- | --- | --- |
| `systemGray` 10pt | `NSColor.white.withAlphaComponent(0.55)` 10pt（≈6.2:1） | 表头是结构信息，可读性优先；仍远弱于数值列前景 |

涉及 `makeUsageHeaderRow` 的三个列名与平台列名（4 处 `textColor = .systemGray`）。

---

## 12. 空态与引导（P3，仅记录）

- 无任何账号时菜单栏 icon 点击后面板近乎空——目前靠用户自己发现磁贴「添加账号」。可选：空态时余额区显示一条 12pt 灰色引导行「从下方「添加账号」开始」+ 磁贴脉冲一次。
- 用量区无数据整卡隐藏 ✓（正确：不占空间不产生疑惑）。
- ZCode/Codex 空容器隐藏 ✓。

---

## 13. 已经做对的（保持，勿回退）

审查同时确认了一批"不可见正确性"的存量实现，它们是这个面板手感的底盘：

| 实现 | 为什么值得保持 |
| --- | --- |
| 拖拽 ghost 用按下时刻的**真实外观快照**（含 hover 态） | 拖起的瞬间视觉连续，无样式闪变 |
| 平台换位动画锁 Y 轴（`transform.translation.y`） | 明确禁止水平漂移，重排只做垂直让位 |
| pin 两段式转移 + 0.25s ease-out 滑入 | origin-aware：面板从原位滑向右上角锚点，空间连续 |
| HoverCard 三态统一（0.8pt white@20% 边框 + 60° 渐变白 8%→5% + 噪点） | 全控件一套 hover 语言，一致性即品质 |
| 趋势 popover 延迟关闭 + 锚定行锁定高亮 | 鼠标行→图往返不误关，是 tooltip 家族的正确泛化 |
| QuietScrollView EMA 平滑 + 顶/底渐隐提示 | 滚动的物理感与"还有内容"的预告 |
| 用量行右对齐 + mono digits + 固定列宽 | 数字列上下严格对齐，扫读零成本 |
| 弹窗 DialogShell 体系 / 说明 12pt 等宽 | 错误与确认的统一容器，文案有固定版式 |

---

## 14. 验证方法（与本仓工具链对接）

1. **慢放**：临时把目标动画 duration ×3–5 跑一遍，看双影/错帧/曲线突变（§3 的 blur 是否盖住交叉残影必须慢放确认）。
2. **次日复查**：动效合入后隔天再看一遍——当天眼睛已经适应，隔天才能看见真实的第一印象。
3. `IBLayoutAutoTest` 跑自动化布局回归（open → pin → resize → collapse），布局类改动防回归闪退。
4. CGWindowList 量浮窗 bounds（无需屏幕录制权限），验证宽度/高度变化符合预期。
5. 每项动效落地时在代码 review 里回答三问：**频率多少？为什么动？为何这个时长？**——答不上来就删。

---

*生成于 2026-08-23，对应 v2026.8.23.27。落地顺序建议：§1 → §2 →（§3/§5/§6 并行）→ 其余按需。*

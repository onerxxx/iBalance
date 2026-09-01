# 005 — 设置/操作区迁 SwiftUI 独立设置窗口：工作分解

- **Status**: PLAN（未开工）
- **Date**: 2026-09-01
- **Scope**: 新增一个独立 SwiftUI 设置窗口（NSWindow + NSHostingController）。首批迁 **操作磁贴 12 个** + **三个弹窗表单**（DeepSeek 设置 / 平台开关 / 关于）。面板内「设置」「操作」区块原样保留，双轨运行。
- **前置**: `plans/004`（面板层整体 SwiftUI 重写评估）——本计划是 004「阶段 1」的独立落地，不依赖 004 其余阶段
- **Deployment target**: macOS 26.0（`swift/Package.swift`），SwiftUI 全能力可用

---

## 结论先行

| 指标 | 数值 |
|---|---|
| 新增 SwiftUI 代码 | **~1,030 行**（6 个新文件 + 接线） |
| 首批可删 AppKit 代码 | ~400 行（`DeepSeekSettingsDialog` / `PlatformAutomationSettingsDialog` / 关于内联） |
| **首批净增** | **~+630 行**（双轨期必然净增，见下方「诚实结论」） |
| 业务逻辑重写量 | **0 行**——全部动作已在 AppDelegate 层，窗口只调用 |
| 工作量 | **5.5–7.5 人日** |
| 触碰 004 的 HIGH 风险 | **否**（popover 尺寸桥、pin 浮窗转移、CIFilter 三处均不涉及） |

**诚实结论：首批不是减代码，是净增 630 行。** 收益不在行数，在三件事：
1. **零业务重写**拿到一套新界面——12 个动作 + 3 个表单的逻辑全部复用现成方法；
2. **沉淀迁移范式**——这是整个工程第一块 SwiftUI 代码，W1/W2 打下的窗口壳与状态通道会被 004 后续阶段直接复用；
3. **可回退**——面板区块保留，出问题把入口摘掉即可，不存在半成品面板。

净减要等 004 后续阶段把面板的「设置/操作」区块删掉后才兑现（届时 -400 行 AppKit 区块 -400 行已删弹窗）。

---

## 1. 为什么这批先迁（结构性利好，逐条已核）

### 1.1 动作层与 UI 已经解耦——零重写

面板的 12 个磁贴、右键菜单的菜单项，调的是同一批 `@objc` 方法：

```
磁贴点击 → Panel.onXxx?() 转发（Panel.swift: openCockpitTapped 等 22 个 @objc 壳）
         → AppDelegate / CheckinManager / AccountSwitcher 的 onXxx()（main.swift / CheckinManager / AccountSwitcher）
菜单栏   → NSMenuItem(action: #selector(onXxx))  ← 同一批方法
```

`Panel.swift` 里 22 个动作壳每个都只有一行 `onXxx?()`。设置窗口只需要调同一个方法，**业务代码一个字不改**。

### 1.2 设置项写入模式统一

`onTogglePanelGradient` / `onToggleLightTheme` / `onToggleMonoFont` / `onToggleValueScrollPreview` / `onToggleUpdateAutoCheck` 全是同一套三行：`config.x.toggle() → ConfigStore.save(config) → syncPanel()`。SwiftUI 侧照抄即可。

### 1.3 绕开 004 的全部 HIGH 风险

| 004 的风险 | 本计划是否触及 | 原因 |
|---|---|---|
| popover 尺寸随内容伸缩（HIGH） | 否 | 设置窗口是固定尺寸独立窗口，不进 popover |
| pin 浮窗内容转移（HIGH） | 否 | 不涉及 floating panel |
| hover 柔边擦除 / 字符模糊 / 渐变（CIFilter 三处） | 否 | 磁贴与表单都不用 CIFilter |
| 卡片拖拽排序 + 右键菜单手势互抢（MEDIUM-HIGH） | 否 | 无卡片 |

---

## 2. 迁移清单

### 2.1 操作磁贴（12 个）

| # | 磁贴 | 图标 | 动作方法（已存在） | 动态状态 |
|---|---|---|---|---|
| 1 | Cockpit | SF `gauge.with.needle` | `onOpenCockpit`（main.swift） | — |
| 2 | 添加账号 | bundle `workbuddy` SVG | `onAddWbAccount`（AccountSwitcher） | `wbOauthInProgress` → 文案变「取消添加」 |
| 3 | 添加账号 | bundle `trae-color` SVG | `onCollectTraeAccount`（AccountSwitcher） | `traeCollectInProgress` → 「采集中…」+ 脉冲禁点 |
| 4 | 添加账号 | bundle `zhipu` SVG（16×0.9） | `onAddZcodeAccount`（AccountSwitcher） | — |
| 5 | 添加账号 | bundle `codex` SVG（16×1.05×0.95） | `onAddCodexAccount`（AccountSwitcher） | — |
| 6 | Key / 额度 | SF `key.fill` | `onSetApiKey`（main.swift） | → W4 表单 |
| 7 | 手动签到 | SF `checkmark.seal` | `onManualCheckin`（CheckinManager） | `manualCheckinInProgress` → 脉冲禁点 |
| 8 | 签到历史 | SF `list.bullet.rectangle` | `onShowCheckinHistory`（CheckinManager） | — |
| 9 | 同步共享 | bundle `workbuddy` SVG | `onShareWbHistory`（WbShare） | — |
| 10 | 平台开关 | SF `circle.grid.2x2.topleft.checkmark.filled` | `onManagePlatformToggles`（main.swift） | → W5 表单 |
| 11 | 检查更新 | SF `arrow.down.circle` | `onCheckForUpdate`（main.swift） | 异步流程 + 进度 |
| 12 | 关于 | SF `info.circle` | `onAbout`（main.swift） | → W6 表单 |

视觉口径（迁移必须 1:1，现实现 `Controls.swift` 的 `ActionTileButton`）：

| 项 | 当前值 |
|---|---|
| 磁贴尺寸 | 52 × 44 |
| 圆角 | 10，`cornerCurve = .continuous`，`masksToBounds = true` |
| 内容 | 纵向 stack：icon（16pt）+ 9pt `systemGray` 文本，`spacing 3`，居中 |
| 文本 | 最多 2 行，尾部截断，`toolTip` 显示完整动作名 |
| icon 来源 | 优先 bundle SVG（`isTemplate = true`，tint = `Palette.cardForeground`），否则 SF Symbol（`.medium`，强制 `size = iconSize` 消除 alignmentRect 顶部留白） |
| hover 背景 / 边框 | 复用 `HoverCard`：背景渐变 + 边框 0 → 0.8 |
| hover icon 光晕 | `shadowOpacity` 0 → 0.45，色 = 中性灰 0.62，`shadowRadius 6`，`offset zero`，时长 `Motion.hover` |
| 进行中 | 背景白 5% ↔ 14% 呼吸，0.55s，`autoreverses + .infinity`，easeInEaseOut；`mouseUp` 层拦截禁点 |
| 容器布局 | 每行 4 个，`spacing 4`，行高 44，行间 4，行内靠左（不满行的末行也靠左），容器在卡片内水平居中 |

### 2.2 弹窗表单（3 个，改为窗口内 sheet）

| 表单 | 现状 | 关键实现点 |
|---|---|---|
| **DeepSeek / ZhiPu / Qwen 设置**（`Dialogs.swift` 的 `DeepSeekSettingsDialog`） | `DialogShell` + 手工 frame 布局的四行表单 | 4 行：API Key / 日常额度（popup 预设 + 自定义输入联动）/ ZhiPu Token / Qwen Ticket。预设 `未设置 / ¥10 / ¥20 / ¥50 / ¥100 / 自定义`。说明区含可点链接（`platform.deepseek.com/api_keys`）。返回 tuple，空串归一为 nil |
| **平台开关**（`PlatformAutomationSettingsDialog`） | `NSGridView` 6 列 × 8 行 | 7 平台 × 4 列（刷新 / 签到 / 卡片 / 用量）+ 行首三态全选。列宽 26 / 116 / 54 / 54 / 54 / 54。不支持签到的平台该列显示「—」占位。三态规则：`RowAllHandler`——全开=勾选、全关=空白、部分=「−」，**且「−」被点击时导向全开**（不是全关）。返回 `AppConfig` |
| **关于**（main.swift 内联） | `DialogShell` + 富文本 | 静态长文 + 版本号 + 配置路径 |

### 2.3 本批不迁（P2，后续或随 004 一起）

- 五个开关（自动签到 / 面板渐变背景 / 浅色主题 / Mono 风格 / 自动检查更新）+ 刷新间隔下拉 + 手动刷新按钮
- 签到历史弹窗内容、添加账号流程里的 `InputDialog`
- **`DialogShell` 本体必须保留**：仍有 15 处调用（AccountSwitcher 6、WbShare 4、main 更新流程 4、CheckinManager 2）。首批删不掉它。

---

## 3. 工作分解

### W1 — 窗口壳与生命周期（0.5–1 人日）

**目标**：能开关一个空的 SwiftUI 窗口，且不与 popover 的激活逻辑打架。

新增 `swift/SettingsWindowController.swift`：

```swift
final class SettingsWindowController: NSWindowController {
    convenience init(root: some View) {
        let window = NSWindow(contentRect: ..., styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: root)
        ...
    }
}
```

硬约束（已核）：
- **不能走 SwiftUI App lifecycle**：`Package.swift` 用 `-parse-as-library`，工程无 `@main`，因此没有 `WindowGroup` / `Settings` scene。必须手写 `NSWindow` + `NSHostingController`。
- **LSUIElement = true**（accessory，无 Dock 图标）：窗口显示需要 `NSApp.activate(ignoringOtherApps: true)` + `makeKey()`；关闭后 `NSApp.hide(nil)` 归还焦点。
- 窗口外观需跟随浅色主题开关（复用 `Palette.panelAppearance`）。

**入口**：菜单栏右键菜单加「设置…」（在「DeepSeek / ZhiPu / Qwen 设置…」上方）+ 面板「操作」区可选（需先解决 R1）。

**验收**：从菜单打开/关闭 5 次不闪不残；`Cmd-W` 与 `Esc` 能关；关闭后焦点回到之前的应用；窗口记忆位置。

---

### W2 — 状态通道 `AppStateStore`（0.5–1 人日）

**为什么必须有**：`syncPanel` 只在 popover / floating 可见时才刷新（`main.swift` 的 `syncPanel` 有 `guard shown`）。设置窗口打开时面板大概率不可见，面板的三个进行中标志（`wbOauthInProgress` / `traeCollectInProgress` / `manualCheckinInProgress`，`main.swift:79/82/84`）不会推送到任何地方。设置窗口要显示「采集中…」就必须有一条独立通道。

新增 `swift/AppStateStore.swift`：

```swift
@MainActor
final class AppStateStore: ObservableObject {
    @Published private(set) var wbOauthInProgress = false
    @Published private(set) var traeCollectInProgress = false
    @Published private(set) var checkinInProgress = false
    // 后续阶段：config 快照、账号列表等
}
```

接线方式（**保持面板行为完全不变**）：
- AppDelegate 的三个 `var` 改为读写 store 的镜像（或加 `didSet` → `store.x = newValue`）；
- `makePanelSnapshot` 改为从 store 读这三个值（现 `s.wbOauthInProgress = wbOauthInProgress` 三行改成从 store 取）；
- 设置窗口 `@EnvironmentObject` 订阅。

**验收**：面板不可见时，从设置窗口触发 TRAE 采集 → 窗口内磁贴变「采集中…」+ 脉冲；采集结束复位；面板行为与改动前逐帧一致。

---

### W3 — 操作磁贴 SwiftUI 组件（1–1.5 人日）

新增 `swift/ActionTileView.swift`：`ActionTile`（单个）+ `ActionTileGrid`（`LazyVGrid` 4 列）。

三个需要换算的点：
1. **hover 检测**：`.onHover` 替代 tracking area。SwiftUI 的 hover 在窗口失焦时的复位行为与 AppKit 不同，需实测。
2. **icon 光晕**：AppKit 是 `CABasicAnimation` 改 `shadowOpacity`。SwiftUI 走 `withAnimation` 改 `@State hovered` 驱动的 `shadow(color:radius:)` —— 注意 SwiftUI 的 `shadow` 在 `masksToBounds` 容器内是否被裁（磁贴有 `masksToBounds = true`，但光晕是给 icon 加的、在容器内，视觉应可对齐，**需实测**）。
3. **进行中呼吸**：AppKit 是 `CABasicAnimation` + `.infinity`。SwiftUI 用 `.animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: pulsing)` 驱动背景色。

**验收**：与面板内现有磁贴同屏对比——hover 边框/背景/光晕、进行中呼吸节奏、文案切换、禁点行为。

---

### W4 — DeepSeek 设置表单（0.75–1 人日）

新增 `swift/DeepSeekSettingsForm.swift`，从设置窗口以 `.sheet` 呈现。

**唯一的真改动是模态语义**：现调用点是同步的——

```swift
// main.swift onSetApiKey
let dialog = DeepSeekSettingsDialog(apiKey: ..., quota: ...)
guard let r = keepPanelAliveDuring({ dialog.present() }) else { return }   // 同步 runModal
config.deepseekApiKey = r.apiKey ?? "" ...
```

SwiftUI sheet 无法同步返回值，需改为两段式：`onSetApiKey` 只负责「请求打开 sheet」，保存逻辑落在 sheet 的 completion 回调里。

**验收**：预设选择 → 自定义框回填；自定义输入优先于预设；空串归一为 nil；Esc 取消不落盘；回车保存；链接可点开浏览器。

---

### W5 — 平台开关表格（1.5–2 人日，本批最难）

新增 `swift/PlatformTogglesForm.swift`。

三个坑：
1. **三态 checkbox**：SwiftUI 的 `Toggle` 只有两态。行首「全选」需要 on/off/mixed。方案二选一：
   - `NSViewRepresentable` 包 `NSButton`（`allowsMixedState = true`）—— 行为 1:1，但引入 AppKit 依赖；
   - 自绘三态按钮 —— 纯 SwiftUI，但「−」符号与系统 checkbox 的视觉一致性要调。
   **建议先走 Representable**，视觉对齐优先，后续再决定要不要纯 SwiftUI 化。
2. **表格对齐**：`NSGridView` 的共享列轨道在 SwiftUI 里要用 `Grid`（macOS 13+，26 可用）或 `LazyVGrid` + 固定列宽。列宽 26/116/54×4 需硬编码对齐（沿用现有数值口径）。
3. **三态联动规则必须照搬** `RowAllHandler`：任一开关变化 → 全选框反算（全开/on、全关/off、部分/mixed）；点击全选框 → off→on、mixed→**全开**（不是全关）、on→off。这是实测出来的系统行为，别凭直觉改。

**验收**：7 行 × 4 列逐格勾选 / 三态反算 / 混合态点击 / 「—」占位列 / 保存后写入 `AppConfig` 全部 11 个字段（现 `present()` 末尾那段逐字段赋值）。

---

### W6 — 关于（0.25 人日）

静态富文本。SwiftUI 里链接用 `Link` 或 `AttributedString`。

---

### W7 — 双轨接线与回归（1 人日）

- 面板「操作」区块保留不动；设置窗口作为**新增入口**，两条通路并存。
- 删除已迁移的 `DeepSeekSettingsDialog`（~180 行）、`PlatformAutomationSettingsDialog`（~208 行）、main.swift 关于内联（~13 行）。
- 回归清单见 §5。

---

## 4. 风险

| ID | 风险 | 级别 | 说明与对策 |
|---|---|---|---|
| **R1** | **打开设置窗口会连带把窗口自己隐藏掉** | **HIGH** | popover 是 `.transient`，新窗口激活 → popover 关闭 → `popoverDidClose` 执行 `NSApp.hide(nil)` → **整个 App（含刚打开的设置窗口）被隐藏**。现 `popoverDidClose` 只有 `isTransferringPanel` 一个早退分支（pin 转移专用）。<br>**对策**：新增 `suppressHideOnClose` 标志位，打开设置窗口前置 true、窗口 `windowDidClose` 复位；同时显式 `popover.performClose(nil)` 再 `activate` + `makeKeyAndOrderFront` 设置窗口。<br>⚠️ `AGENT.md` §3 里已经写着「弹系统设置菜单等场景用 `suppressHideOnClose` 跳过」，但**代码里这个符号不存在**（已 grep 确认）——AGENT.md 记的是历史方案或已删除的实现，本 W1 相当于把它补回来。 |
| **R2** | 模态语义改造 | MEDIUM-HIGH | 三个调用点（`onSetApiKey` / `onManagePlatformToggles` / `onAbout`）都是同步 `present()` 返回值，必须改成异步 completion。改的是 AppDelegate 层，影响面板与菜单栏两条既有通路，**回归时要两条都测**。 |
| **R3** | 三态 checkbox + 表格对齐 | MEDIUM | 见 W5。Representable 是稳妥解，但会让「SwiftUI 化」打折。 |
| **R4** | 磁贴 hover 光晕 / 呼吸动画 | MEDIUM | 见 W3。判据是「与面板内磁贴同屏对比肉眼是否可辨」，不是「能不能做出来」。 |
| **R5** | 双轨状态漂移 | MEDIUM | 面板与设置窗口可能同时可见（从面板打开时）。W2 的 store 是单一真源可解决，但 `syncPanel` 的 `guard shown` 意味着面板侧仍是拉模式，需在窗口关闭后补一次 `syncPanel()`。 |
| **R6** | 键盘快捷键 | LOW-MEDIUM | 原按钮用 `keyEquivalent "\r"` / `"\u{1b}"`（NSAlert 原生）。SwiftUI 的 `.keyboardShortcut(.defaultAction)` / `.cancelAction` 在手写 `NSHostingController` 里的响应链是否生效需实测；不生效则退回 `NSEvent.addLocalMonitorForEvents`。 |

---

## 5. 验收清单

**窗口壳**
- [ ] 菜单 / 面板两个入口都能打开，重复点击不叠开多个窗口
- [ ] `Cmd-W`、`Esc`、关闭按钮均可关闭；关闭后焦点归还前台应用
- [ ] 浅色主题开关下窗口外观跟随

**磁贴（12 个逐一）**
- [ ] 每个磁贴触发的行为与面板内点击完全一致
- [ ] hover 边框 / 背景 / icon 光晕与面板内同屏对比无肉眼差异
- [ ] TRAE 采集中、WB 添加中、手动签到中：文案切换 + 呼吸脉冲 + 禁点
- [ ] 长任务进行中关闭再打开窗口，状态正确
- [ ] tooltip 完整显示

**表单**
- [ ] DeepSeek 设置：预设↔自定义联动、空值归一、Esc 不落盘、回车保存、链接可点
- [ ] 平台开关：7×4 逐格、三态反算、混合态点击=全开、「—」占位、保存后 11 个配置字段全写入
- [ ] 关于：版本号与配置路径正确

**回归（双轨）**
- [ ] 面板「操作」区块 12 个磁贴行为零变化
- [ ] 菜单栏右键菜单全部项行为零变化
- [ ] 面板与设置窗口同时可见时状态一致
- [ ] 关闭设置窗口后面板状态补刷新

---

## 6. 与 plans/004 的关系

本计划 = 004 的「阶段 1」提前独立执行。它同时是 004 的**可行性验证**：

- **W1 的窗口壳** → 004 阶段 0 需要验证的「主题/字体注入」在这里先跑一遍（窗口 appearance + `Palette.panelAppearance`）。
- **W2 的 `AppStateStore`** → 004 后续阶段的状态层地基，卡片/用量/Token 全都要接进来。
- **W3/W5 沉淀的范式**（hover 怎么写、动画怎么换算、三态控件怎么包）→ 写进 `AGENT.md`，后面卡片区直接照抄。
- **如果 W3 的 hover 光晕或 W5 的三态控件明显对不齐** → 说明 SwiftUI 在这套视觉体系里的对齐成本高于预估，004 应重新评估（这正是 004 阶段 0 设 go/no-go 的意义）。

**不做的事**（留给 004）：面板区块本身不改成 SwiftUI、不碰 popover 尺寸桥、不碰 pin 浮窗、不碰卡片/用量/Token 任何一块。

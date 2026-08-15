# iBalance 面板 UI：Mac 原生控件选型与设计规范

> 适用对象：iBalance 菜单栏面板（NSPopover，固定宽 260pt，深色毛玻璃）
> 依据：Apple Human Interface Guidelines（macOS）+ 项目现有实现（`swift/Panel.swift` ~1560 行、`swift/main.swift` ~2226 行）
> 更新日期：2026-08-16

---

## 0. 面板上下文与选型前提

当前面板是一个 **260pt 宽的 NSPopover**，结构为：

```
头部（品牌）
离线横幅（条件显示）
余额卡片 ×N（DeepSeek 用量进度 / TRAE×n / WorkBuddy×n / 千问周%+到期）
设置卡片（分段控件 + 5 个开关行）
操作卡片（磁贴按钮，4×2 网格）
Footer（更新时间 + 退出按钮）
```

这类「菜单栏弹出面板」的控件选型有三个硬约束，后文所有建议都以此为前提：

1. **空间极窄**：260pt 宽、行高 16~22pt，控件必须紧凑（`.mini` / `.small` controlSize），不能照搬窗口应用的 `.regular` 尺寸。
2. **瞬时交互**：popover 失焦即关闭，所有操作必须「一步完成、立即生效」，不适合多步表单、模态确认流。
3. **深色毛玻璃背景**：`TintedVisualEffectView`（`.menu` material + `.behindWindow` blending + `darkAqua` appearance + near-black tint overlay）+ `NSColor` 语义色，不硬编码浅色。

---

## 1. 常用控件类型、适用场景与面板映射

### 1.1 总览表

| 控件      | AppKit 类                              | 适用场景              | 在 iBalance 面板中的位置           | 优先级   |
| ------- | ------------------------------------- | ----------------- | ----------------------- | ----- |
| 开关      | `NSSwitch`                            | 布尔偏好，立即生效         | 设置卡片 5 个开关行             | ★★★★★ |
| 分段控件    | `NSSegmentedControl`                  | 2~4 个互斥选项，选项少且文案短 | 刷新间隔（1/3/5 分钟）          | ★★★★★ |
| 标签文本    | `NSTextField(label)`                  | 只读信息展示            | 余额数值、签到信息、更新时间、设置项标签    | ★★★★★ |
| 无边框图标按钮 | `NSButton(.inline, isBordered=false)` | 工具性单动作            | footer 退出按钮             | ★★★★  |
| 下拉菜单按钮  | `NSPopUpButton`                       | 选项多（>4）或文案长的互斥选择  | *当前未用*，见 §5 备选建议      | ★★★   |
| 滑块      | `NSSlider`                            | 连续数值调节            | **不适用**，见 §6          | ✗     |
| 标签页     | `NSTabView`                           | 平行内容分组切换          | **不适用**，见 §6          | ✗     |
| 表格视图    | `NSTableView`                         | 多行多列结构化数据         | **不适用**（账号卡片已覆盖）      | ✗     |
| 文本输入框   | `NSTextField(editable)`               | 需要用户输入文本          | **不进面板**，放独立 alert/窗口 | ★★    |
| 复选框     | `NSButton(.checkbox)`                 | 多项独立选择 / 协议确认     | **面板内避免**，见 §6        | ✗     |
| 单选按钮    | `NSButton(.radio)`                    | 互斥选择（macOS 已少用）   | **避免**，用分段控件替代        | ✗     |
| 进度指示    | 自绘（`UsageDots`/`UsageBar`/`UsageRing`） | 用量可视化             | 各余额卡片点阵 / 用量条 / 环形图   | ★★★★  |

### 1.2 开关 NSSwitch（面板第一控件）

**现状**：`MiniSwitch`（`.mini` 尺寸 + 0.81 视觉缩放 + `darkAqua` appearance），配合 `HoverRowView` 实现「点击整行切换」。

- **适用**：所有「开/关」且**立即生效**的偏好——自动签到、显示小数位、显示平台昵称、显示菜单栏主图标，全部用对了。
- **颜色控制**：NSSwitch 跟随系统 Accent Color。不要用 KVC 尝试设置 `tintColor`（会导致运行时崩溃）。
- **最佳实践**：
  - 左侧 12pt 标签 + 右侧开关，中间 spacer 撑开，垂直居中。当前实现正确。
  - 「点击整行切换」用 `HoverRowView`（hover 提亮标签文本 + 点击回调），比只点开关本身好得多的交互，保留。
  - 代码内改 `state` 不触发 action——当前 `update()` 里的赋值方式是安全的，不要改成 `performClick`。
  - 深色面板中的开关必须设 `appearance = NSAppearance(named: .darkAqua)`，否则在浅色系统下开关渲染为浅色外观，与深色面板背景冲突。

### 1.3 分段控件 NSSegmentedControl

**现状**：`MiniSegmentedControl`（`.mini` + 0.81 视觉缩放），用于刷新间隔三选一。选中段高亮色通过 `selectedSegmentBezelColor = #666666` 显式设置。

- **适用**：2~4 个互斥选项、每个选项文案 ≤ 4 个字。刷新间隔是教科书级的正确用法。
- **最佳实践**：
  - `trackingMode = .selectOne`（默认即正确）。
  - 段数超过 4 或文案变长时，降级为 `NSPopUpButton`（见 §5）。
  - 宽度用 hugging 约束贴合内容，不要拉伸——当前 `setContentHuggingPriority(.required, for: .horizontal)` 正确。

### 1.4 按钮 NSButton

面板里有三种按钮形态，各有规矩：

| 形态      | 实现                                       | 用法                                                       |
| ------- | ---------------------------------------- | -------------------------------------------------------- |
| 无边框图标按钮 | `HoverIconButton`（`NSButton` 子类）        | footer 退出按钮（22×22，recessed bezel，hover 时显示边框）。配 `toolTip` |
| 磁贴按钮    | 自绘 `ActionTileButton`（icon + 9pt 双行文本）   | 操作卡片。合理，因为原生 NSButton 做不出「icon 上 + 文本下」的网格布局             |
| 文字按钮    | *未用*                                     | API Key / Ticket 输入改走磁贴 → 弹 `DialogShell`（NSAlert），正确   |

- **最佳实践**：
  - 图标按钮必须设 `toolTip`（当前退出按钮已设「退出 iBalance」）。
  - 自绘按钮的 hover 态（5% 白底 + 边框 + icon shadow glow）与卡片 hover 统一，保留这套规范。

### 1.5 下拉菜单 NSPopUpButton

- **当前未用，是正确判断**：刷新间隔只有 3 个短选项，分段控件更直观。
- **何时该换**：若未来刷新间隔扩到 5+ 档（如加「10 分钟/30 分钟/手动」），或设置里新增「主题/语言」这类长文案选项，改用 `NSPopUpButton`（`.small` 尺寸，`pullsDown=false`）。

### 1.6 标签与只读文本 NSTextField(labelWithString:)

- 余额数值用 `monospacedDigitSystemFont`（等宽数字）——数字变化时不抖动，这是金融/计量类显示的硬性最佳实践，当前已做到。
- 层级建议（与现状一致）：
  - 分组标题：系统默认 `systemGray`（跟随 darkAqua 自动适配）
  - 卡片前景色：`Palette.cardForeground`（`#DDDDDD`）
  - 非当前账号前景：`Palette.cardForegroundDimmed`（石墨灰 `0.5`）
  - 辅助信息（签到、更新时间、副标题）：系统 `systemGray`

### 1.7 进度可视化：自绘而非 NSProgressIndicator

当前面板有三种自绘进度控件——**全部是对的**：

- **`UsageDots`**（8 点阵）：主力进度指示，HSB 色阶从红到绿（8 级），支持脉冲动画（额度消耗时最右亮圆闪烁）。深色背景中远优于 NSProgressIndicator。
- **`UsageBar`**：水平圆角填充条，`quaternaryLabelColor` 轨道 + 使用比例填充色（同 UsageDots 色阶）。
- **`UsageRing`**：环形弧线进度（3pt lineWidth，从顶部 -90° 起始），用于紧凑空间的替代展示。

- **规范**：新增进度类视图时复用 `UsageDots` 的 HSB 色阶逻辑（H: 0→0.333, S: 0.80, B: 0.92），保持全面板视觉一致。

### 1.8 表格 / 标签页 / 滑块 / 输入框

详见 §6「避免使用清单」。一句话结论：**这个面板一行都不该出现它们**。多账号余额用动态卡片列表（当前实现）而不是 NSTableView，是完全正确的取舍。

---

## 2. 与 macOS HIG 对齐的要点

### 2.1 容器：NSPopover 的 HIG 约定

- HIG 规定 popover 用于「**与触发元素直接相关的少量补充内容/操作**」。当前 260pt 宽、垂直信息流、只读为主 + 轻设置，完全符合。
- 宽度保持在 220~320pt 区间（HIG 建议 popover 紧凑）；当前 260pt 合理，不建议再加宽。
- 不要在 popover 内再弹 popover。需要输入（API Key、Ticket、日常额度）时用 `DialogShell`（NSAlert + accessoryView，见 §2.5），或临时小型 NSPanel 窗口——这是 HIG 认可的两种升级路径。

### 2.2 菜单栏应用的 HIG 约定

- 菜单栏图标应是 template image（单色 SVG + 透明背景，`isTemplate = true`，系统自动处理深浅色与 active/inactive 状态）。
- 左键弹 popover、右键保留 NSMenu 兜底——与 HIG「菜单栏项主交互为菜单」略有出入，但已是 macOS 生态广泛接受的现代模式（如 Stats、Hidden Bar），保留即可。
- LSUIElement 面板激活陷阱：弹出前必须 `NSApp.activate(ignoringOtherApps: true)` + `makeKey()`，否则 NSPopover 首帧按「非活跃」渲染玻璃材质偏暗，且 `.transient` 不生效。`popoverDidClose` 里 `NSApp.hide` 归还焦点。

### 2.3 颜色与材质

- **Palette 集中管理**：所有自定义颜色在 `Panel.swift` 的 `Palette` 私有枚举中统一定义，避免硬编码散落各处：

| Token | 值 | 用途 |
|---|---|---|
| `cardForeground` | `#DDDDDD` | 卡片 icon/标题/数值/分组标题 |
| `cardForegroundDimmed` | `calibratedWhite 0.5` | 非当前账号前景色 |
| `cardBackground` | `clear` | 卡片底色（透出毛玻璃） |
| `cardBackgroundHover` | `calibratedWhite 51/255, alpha 0.30` | 卡片 hover 高亮 |
| `containerTint` | `calibratedWhite 0.02, alpha 0.30` | 毛玻璃深色遮罩 |
| `cardCornerRadius` | 10pt | 卡片圆角（对齐 Big Sur+ 系统圆角） |
| `cardBorderColor` | `white, alpha 0.10` | 卡片边框/分割线 |
| `dividerColor` | `white, alpha 0.10` | 区块分割线 |
| `cardBorderWidth` | 1pt | 卡片边框宽度 |

- **系统语义色**：`labelColor / secondaryLabelColor / tertiaryLabelColor / quaternaryLabelColor / systemGray / systemGreen/Orange/Red`，自动适配深浅色与「增强对比度」。
- 毛玻璃用 `.menu` material + `behindWindow` blending + `darkAqua` appearance，加上 `TintedVisualEffectView` 的近黑遮罩叠加，是菜单类 UI 的标准做法。
- 品牌 SVG 图标保持原色（`isTemplate=false`）、系统符号用 template + `contentTintColor`——当前的区分处理正确。

### 2.4 动效

- HIG 对动效的态度是「**短、轻、有意义**」：当前 hover 0.22s 提亮、刷新旋转、点阵脉冲都在此范围。
- HoverCard：`animateLayerBg` 做 backgroundColor 过渡（0.22s easeInEaseOut），`animateFillColor` 做高亮框过渡（0.15s）。
- HoverIconButton：进入/退出 mouse tracking 区域时显隐 1pt white@20% 边框。
- 刷新按钮无限旋转必须有明确终止条件（当前 `setRefreshing(false)` 停止），避免「永远转圈」——已实现，保持。

### 2.5 弹窗系统：DialogShell（NSAlert 薄封装）

所有需要用户输入文本或二次确认的交互统一走 `DialogShell`（定义于 `main.swift`），不在 popover 内做内联输入。

- **设计原则**：回归原生 NSAlert 布局——标题/说明用 `messageText` / `informativeText`（系统排版），按钮用 `addButton`（系统按钮行）。仅两类内容放 `accessoryView`：输入控件（输入框/下拉）、含可点链接的富文本说明。
- **API**：`addTitle()` / `addInfo()` / `addIcon()` / `addContent()` / `addButton()` / `present()`，返回点击的按钮索引。
- **布局参数**（`DialogMetrics`）：

| 参数 | 值 | 用途 |
|---|---|---|
| `width` | 240pt | accessoryView 默认内容宽 |
| `inputWidth` | 280pt | 输入类弹窗内容宽（说明文字较长） |
| `sidePadding` | 4pt | 控件区左右边距 |
| `vSpacing` | 8pt | 说明与控件区间距 |
| `iconSize` | 64pt | 图标尺寸（HIG 标准 alert 图标） |

- **使用场景**：配置 Key 输入、千问 Ticket 设置（自动获取按钮）、日常额度设置、手动签到结果汇总、关于弹窗等。
- **模态期间面板保活**：弹出 DialogShell 时通过 `keepPanelAliveDuring<T>` 临时将 popover behavior 切换为 `.applicationDefined`，防止点 alert 按钮时面板被 `.transient` 自动关闭。

---

## 3. 视觉风格、尺寸与间距规范

### 3.1 控件尺寸档位（controlSize）

| 档位         | 高度参考            | 面板内使用建议         |
| ---------- | --------------- | --------------- |
| `.regular` | ~28pt（开关 32×22） | **禁止**在面板内使用    |
| `.small`   | ~24pt（开关 28×18） | —（当前未用）          |
| `.mini`    | ~17pt（开关 24×15） | 开关 + 分段控件基础档（再配 0.81 视觉缩放） |

> 当前的「`.mini` + 0.81 affineTransform 视觉缩放」是在「原生控件渲染」和「面板紧凑度」之间的务实折中。它保留了原生控件的键盘焦点、VoiceOver、系统动画，只缩小视觉——比从头自绘开关/分段控件好得多。**新增同类控件时沿用 `MiniSwitch` / `MiniSegmentedControl` 子类，不要另起炉灶。**

### 3.2 间距标尺（来自现有实现，固化为规范）

```
面板内边距：    左右 7pt
根栈宽度：      246pt（260 - 7×2）
卡片圆角：      10pt
卡片边框：      1pt white@10%
行高：         设置行 ~16pt；磁贴行 48pt；footer 20pt
行内间距：      icon-文本 8pt；卡片间（同平台）0pt，卡片间（跨平台）8pt
磁贴尺寸：      56×48pt
hover 高亮：    HoverCard white@5% + 0.8pt white@14% border（0.22s easeInEaseOut）
               HoverIconButton white@20% border（仅 hover 时显示）
               ActionTileButton white@5% + icon shadow glow
```

规则化建议：**所有间距取 2 的倍数、优先 4 的倍数**（现状基本满足）；新增行/卡片时从上表取已有值，不引入新数值。

### 3.3 字体标尺

| 用途              | 字号/字重                  |
| --------------- | ---------------------- |
| 分组标题            | 系统默认（跟随 darkAqua 自动适配） |
| 设置项/卡片文本        | 12pt regular           |
| 余额数值            | 12pt semibold，**等宽数字** |
| 辅助信息（签到/昵称/副标题） | 系统默认 `systemGray`       |
| 磁贴文本            | 9pt regular，最多 2 行截断   |
| footer 更新时间      | 9pt regular，systemGray   |

---

## 4. 面板布局结构

### 4.1 卡片类型与顺序（从上到下）

```
┌──────────────────────────────────────┐
│  [离线横幅]（条件显示，systemOrange）        │
├──────────────────────────────────────┤
│  ◆ 余额（分组标题）                      │
│  ┌────────────────────────────────┐  │
│  │ DeepSeek 卡片                 │  │
│  │   余额 + 用量进度 (UsageDots)   │  │
│  ├────────────────────────────────┤  │
│  │ TRAE 卡片 ×N（当前账号 + 多号）    │  │
│  │   积分 + 点阵进度 + 签到状态      │  │
│  ├────────────────────────────────┤  │
│  │ WorkBuddy 卡片 ×N（当前 + 多号）   │  │
│  │   额度 + 点阵进度 + 签到状态      │  │
│  ├────────────────────────────────┤  │
│  │ 千问 Token Plan 卡片            │  │
│  │   周% + 5h% + 到期时间 + 点阵     │  │
│  └────────────────────────────────┘  │
├──────────────────────────────────────┤
│  ◆ 设置（分组标题）                      │
│  ┌────────────────────────────────┐  │
│  │ 刷新时间  [1分|3分|5分]          │  │
│  │ 自动签到  ────── [开关]          │  │
│  │           今日签到结果副标题        │  │
│  │ DeepSeek 2位小数 ─── [开关]       │  │
│  │ 显示平台昵称 ────── [开关]        │  │
│  │ 显示菜单栏主图标 ── [开关]         │  │
│  └────────────────────────────────┘  │
├──────────────────────────────────────┤
│  ◆ 操作（分组标题）                      │
│  ┌────────────────────────────────┐  │
│  │ [Cockpit] [添加WB] [添加TRAE] [配置Key] │  │
│  │ [日常额度] [千问账号] [手动签到] [关于]   │  │
│  └────────────────────────────────┘  │
├──────────────────────────────────────┤
│          更新于 HH:mm:ss    [退出]      │
└──────────────────────────────────────┘
```

### 4.2 多账号卡片

- TRAE 和 WorkBuddy 各支持多账号，每个账号独立一张 `HoverCard`。
- 同平台账号卡片之间间距为 0pt（视觉上合并为一组），跨平台间距 8pt。
- 当前登录账号（`isCurrent`）使用全尺寸品牌图标和正常前景色；非当前账号 icon 缩至 50% + 前景降为石墨灰。
- 点击非当前账号卡片触发账号切换（写认证文件 + 杀进程重启）。

### 4.3 数据流

- AppDelegate 从各服务缓存 + 设置状态构建不可变的 **`PanelSnapshot`**，调用 `panel.update(snapshot)` 推给面板。
- 面板不直接读配置/网络，所有交互通过无参回调（`toggleDsDecimals()` / `applyRefreshInterval()` 等）通知 AppDelegate。
- 面板与右键菜单共用同一套回调，勾选态/标题双向同步。
- 刷新采用**先到先显示**：四个服务各自独立请求，任一返回即写缓存并立即重绘，互不等待。

---

## 5. 控件选择优先级（结合面板功能）

按「面板演进时优先考虑谁」排序：

1. **NSSwitch** —— 新增布尔偏好的唯一选择（如「开机启动」「低额度提醒」）。
2. **NSSegmentedControl** —— 新增短文案互斥选项（如「额度显示模式：剩余/已用」）。
3. **自绘卡片/磁贴** —— 新增平台余额 → 复用 `HoverCard` + `UsageDots`；新增操作 → 复用 `ActionTileButton` 网格（每行 4 个的规范不变）。
4. **NSPopUpButton** —— 当某设置选项 >4 个或文案 >6 字时，从分段控件降级替换。
5. **DialogShell（NSAlert）** —— 一切需要输入文本/二次确认的需求（API Key、日常额度、签到结果汇总等）。不要在 popover 里做内联输入或确认区。
6. **独立 NSPanel 窗口** —— 设置项多到一张卡片放不下（>8 行）时，把「设置」整体迁出面板为独立偏好窗口，面板只留高频 2~3 项。这是 HIG 认可的标准演进路径（参考 Stats、iStat Menus）。

---

## 6. 避免使用的控件清单

| 控件                              | 为什么避免                                               | 替代方案                            |
| ------------------------------- | --------------------------------------------------- | ------------------------------- |
| **NSSlider**                    | 260pt 宽内滑块可用行程太短，精度差；且「刷新间隔/小数位」这类离散档位语义用滑块表达不清     | 分段控件（≤4 档）/ NSPopUpButton（>4 档） |
| **NSTabView**                   | popover 高度自适应内容，标签页会引入「看不见的内容」；且标签栏本身吃掉 ~28pt 高度    | 垂直分卡片（当前方案）；内容真的多了 → 独立窗口       |
| **NSTableView / NSOutlineView** | 账号数量级是 1~5 个，卡片列表的信息密度和视觉层次都优于表格；表格的行选区/表头在小面板上是噪音  | 动态卡片（当前方案）                      |
| **NSButton(.checkbox)**         | macOS 上复选框语义是「列表中多选」或「协议确认」，不是偏好开关；HIG 明确偏好用 Switch | NSSwitch                        |
| **NSButton(.radio)**            | macOS 现代 HIG 已基本弃用单选按钮组                             | NSSegmentedControl              |
| **editable NSTextField**        | popover 失焦即关，输入到一半点外面 = 内容丢失，是严重的交互事故               | DialogShell / NSAlert + accessoryView |
| **NSComboBox**                  | 可编辑下拉，popover 内同样有失焦问题，且面板内无「可输入可选」的场景              | 不用                              |
| **NSDatePicker / NSColorWell**  | 重量级控件，popover 内无场景                                  | 不用                              |
| **NSScrollView**                | 面板高度应自适应内容；一旦需要滚动说明内容超纲                             | 超出 → 迁移到独立窗口                    |
| **NSLevelIndicator**            | 样式老旧且不可定制阈值色                                        | 继续自绘 UsageDots/Bar/Ring       |

另外两条**行为层面**的避免项：

- **避免在 popover 里做模态流**（多步向导、内联确认）。所有「确认」升级为 DialogShell。
- **避免常驻动画**。脉冲/旋转只能作为状态指示（刷新中、消耗中、切换中），有明确起止；纯装饰性循环动画在菜单栏面板里是耗电和分心的双重减分项（当前实现合规，保持）。

---

## 7. 自绘控件一览

| 控件 | 基类 | 尺寸/特征 | 核心行为 |
|---|---|---|---|
| `MiniSwitch` | `NSSwitch` | `.mini` + 0.81x 缩放 | 中心锚点修复（`layout()` 里恢复 anchorPoint + 补偿 position） |
| `MiniSegmentedControl` | `NSSegmentedControl` | `.mini` + 0.81x 缩放 | `selectedSegmentBezelColor = #666666`，右中心锚点 |
| `HoverCard` | `NSView` | 自适应高度 | hover: white@5% bg + 0.8pt white@14% border（0.22s ease）；支持 onClick / onHighlightChange |
| `HoverRowView` | `NSView` | 自适应高度 | hover: 文本从 systemGray 提亮到 labelColor；点击回调 |
| `HoverIconButton` | `NSButton` | 22×22 固定 | recessed bezel；进入 mouse tracking 区域时显示 1pt white@20% 边框 |
| `ActionTileButton` | `NSView` | 56×48 | 垂直 icon+label；hover: white@5% bg + border + icon shadow glow（opacity 0→0.45） |
| `UsageDots` | `NSView` | 适配容器宽度 | 8 方形点阵，HSB 色阶（红→绿），支持脉冲动画（最右亮圆闪烁） |
| `UsageBar` | `NSView` | 自适应宽度 | 圆角水平条，`quaternaryLabelColor` 轨道 |
| `UsageRing` | `NSView` | 自适应尺寸 | 环形弧线（3pt lineWidth，-90° 起始） |
| `TintedVisualEffectView` | `NSVisualEffectView` | 全面板 | `.menu` + `.behindWindow` + `darkAqua` + `TintOverlayView` 近黑遮罩 |
| `DialogShell` | `NSAlert` 封装 | 自适应 | 系统标题/说明/按钮行 + accessoryView 输入控件；面板模态期间保活 |

> **新增自绘控件时**：hover 态统一走 `animateLayerBg`（0.22s easeInEaseOut），边框过渡走 `animateFillColor`（0.15s）。不要引入新的动画时序参数。

---

## 8. 可访问性（Accessibility）注意事项

当前面板在可访问性上是「原生控件及格、自绘控件缺失」的状态，按优先级列出：

### 8.1 必做（P0）

1. **自绘可点控件补无障碍属性**：`HoverCard`、`ActionTileButton`、`HoverRowView` 对 VoiceOver 是不可见的。需要：
   ```swift
   setAccessibilityRole(.button)
   setAccessibilityLabel("WorkBuddy 余额卡片，点击打开")
   setAccessibilityEnabled(true)
   ```
   尤其是「点击非当前账号卡片 = 切换账号」这种隐式操作，没有 label 时读屏用户完全无法发现。
2. **开关行的 accessibilityLabel**：`NSSwitch` 本身有声，但「点击整行」的手势区不发声。确保每个 switch 设了 `setAccessibilityLabel("自动签到")` 等（标签文本不会自动关联到开关）。
3. **点阵进度 `UsageDots`**：设 `setAccessibilityRole(.valueIndicator)` + `setAccessibilityValue("剩余 63%")`，否则读屏只能看到无意义色块。

### 8.2 应做（P1）

1. **键盘导航**：popover 默认不支持 Tab 键遍历。若做，用 `keyView` 链把 开关组 → 分段控件 → footer 退出按钮 串起来；自绘磁贴不参与键盘焦点（或用 `NSButton` 重构磁贴获得免费焦点环）。
2. **色彩对比**：`systemGray` 在毛玻璃 + near-black 遮罩上的实际对比度建议用 Accessibility Inspector 实测，目标 ≥ 4.5:1（WCAG AA）。9pt 小字（磁贴文本、签到信息）尤其要测。
3. **「增强对比度」/「减少动态效果」**：
   - 监听 `NSWorkspace.accessibilityDisplayShouldIncreaseContrast` 变化，开启时加强 hover 提亮 + 加描边。
   - `accessibilityDisplayShouldReduceMotion` 为 true 时，停用点阵脉冲和刷新旋转（改为静态「刷新中…」文本），当前无限动画都应接入此开关。

### 8.3 建议（P2）

1. toolTip 继续覆盖所有图标按钮（退出已有，若新增头部刷新按钮同样要加）。
2. 数值变化（余额刷新）不需要主动播报；但签到成功/失败可以用 `NSAccessibilityAnnouncementRequested` 发一条通知。

---

## 9. 落地检查清单（新增/修改控件时过一遍）

- [ ] 控件尺寸档位为 `.mini`，或复用 `MiniSwitch` / `MiniSegmentedControl` 子类
- [ ] 颜色走 `Palette` 枚举或系统语义色；硬编码色有注释说明原因
- [ ] 深色面板内控件设 `appearance = NSAppearance(named: .darkAqua)`
- [ ] 分段控件显式设置 `selectedSegmentBezelColor`
- [ ] 数字显示用 `monospacedDigitSystemFont`
- [ ] 间距取自 §3.2 标尺，字号取自 §3.3 标尺
- [ ] 图标按钮有 toolTip
- [ ] 自绘可点视图补了 accessibilityRole/Label/Value
- [ ] 无限动画接入了「减少动态效果」开关
- [ ] 交互可一步完成；需要输入/确认 → DialogShell
- [ ] hover 态与现有规范一致（5% 白底 / 0.22s easeInEaseOut）
- [ ] 新增卡片复用 `HoverCard`，新增操作复用 `ActionTileButton`
- [ ] `PanelSnapshot` 新字段在 AppDelegate 的 `makePanelSnapshot()` 中赋值

---

*本文档随面板演进更新。控件新增规范先改这里，再改代码。*

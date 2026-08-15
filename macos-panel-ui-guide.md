# iBalance 面板 UI：Mac 原生控件选型与设计规范

> 适用对象：iBalance 菜单栏面板（NSPopover，固定宽 260pt，深色毛玻璃）  
> 依据：Apple Human Interface Guidelines（macOS）+ 项目现有实现（`swift/Panel.swift`）  
> 更新日期：2026-08-14

---

## 0. 面板上下文与选型前提

当前面板是一个 **260pt 宽的 NSPopover**，结构为：

```
头部（品牌）
离线横幅（条件显示）
余额卡片 ×N（DeepSeek / TRAE×n / WorkBuddy×n / 千问）
设置卡片（分段控件 + 5 个开关行）
操作卡片（磁贴按钮，每行 4 个）
Footer（更新时间 + 退出按钮）
```

这类「菜单栏弹出面板」的控件选型有三个硬约束，后文所有建议都以此为前提：

1. **空间极窄**：260pt 宽、行高 16~22pt，控件必须紧凑（`.mini` / `.small` controlSize），不能照搬窗口应用的 `.regular` 尺寸。
2. **瞬时交互**：popover 失焦即关闭，所有操作必须「一步完成、立即生效」，不适合多步表单、模态确认流。
3. **深色毛玻璃背景**：`NSVisualEffectView(.menu)` + 强制 darkAqua，颜色必须用语义色（`labelColor` 等），不能硬编码浅色。

---

## 1. 常用控件类型、适用场景与面板映射

### 1.1 总览表

| 控件      | AppKit 类                              | 适用场景              | 在 iBalance 面板中的位置     | 优先级   |
| ------- | ------------------------------------- | ----------------- | --------------------- | ----- |
| 开关      | `NSSwitch`                            | 布尔偏好，立即生效         | 设置卡片 5 个开关行           | ★★★★★ |
| 分段控件    | `NSSegmentedControl`                  | 2~4 个互斥选项，选项少且文案短 | 刷新间隔（1/3/5 分钟）        | ★★★★★ |
| 标签文本    | `NSTextField(label)`                  | 只读信息展示            | 余额数值、签到信息、更新时间        | ★★★★★ |
| 无边框图标按钮 | `NSButton(.inline, isBordered=false)` | 工具性单动作            | 退出按钮、（已移除的刷新按钮）       | ★★★★  |
| 下拉菜单按钮  | `NSPopUpButton`                       | 选项多（>4）或文案长的互斥选择  | *当前未用*，见 §5 备选建议      | ★★★   |
| 滑块      | `NSSlider`                            | 连续数值调节            | **不适用**，见 §6          | ✗     |
| 标签页     | `NSTabView`                           | 平行内容分组切换          | **不适用**，见 §6          | ✗     |
| 表格视图    | `NSTableView`                         | 多行多列结构化数据         | **不适用**（账号卡片已覆盖）      | ✗     |
| 文本输入框   | `NSTextField(editable)`               | 需要用户输入文本          | **不进面板**，放独立 alert/窗口 | ★★    |
| 复选框     | `NSButton(.checkbox)`                 | 多项独立选择 / 协议确认     | **面板内避免**，见 §6        | ✗     |
| 单选按钮    | `NSButton(.radio)`                    | 互斥选择（macOS 已少用）   | **避免**，用分段控件替代        | ✗     |
| 进度指示    | 自绘（`UsageDots`/`UsageBar`）            | 用量可视化             | 各余额卡片点阵               | ★★★★  |

### 1.2 开关 NSSwitch（面板第一控件）

**现状**：`MiniSwitch`（`.mini` 尺寸 + 0.81 视觉缩放 + `darkAqua` appearance），配合 `switchRow` 实现「点击整行切换」。开关开启色由 App 级 Accent Color 控制（见 §2.3.1），统一为 `.systemGreen`。

- **适用**：所有「开/关」且**立即生效**的偏好——自动签到、显示小数位、隐藏昵称、隐藏主 icon，全部用对了。
- **颜色控制**：NSSwitch 没有公开的 `tintColor` 属性，**不要用 KVC 尝试设置**（会导致运行时崩溃）。开关颜色通过 §2.3.1 的 method swizzling 统一控制，全 App 所有开关自动跟随 App Accent Color。
- **最佳实践**：
  - 左侧 12pt 标签 + 右侧开关，中间 spacer 撑开，垂直居中。当前实现正确。
  - 「点击整行切换」用手势加到行容器（当前用 `NSClickGestureRecognizer` → `performClick`），是比只点开关本身好得多的交互，保留。
  - 代码内改 `state` 不触发 action——当前 `update()` 里的赋值方式是安全的，不要改成 `performClick`。
  - 深色面板中的开关必须设 `appearance = NSAppearance(named: .darkAqua)`，否则在浅色系统下开关渲染为浅色外观，与深色面板背景冲突。
- **避免**：不要用开关表达「非即时生效」或「有中间态」的选项；需要确认的破坏性操作（如删除账号）绝不能用开关。

### 1.3 分段控件 NSSegmentedControl

**现状**：`MiniSegmentedControl`（`.small` + 0.82 视觉缩放 + 右中心锚点），用于刷新间隔三选一。选中段高亮色通过 `selectedSegmentBezelColor = .systemGreen` 显式设置，同时 App 级 Accent Color swizzle（§2.3.1）确保一致。

- **适用**：2~4 个互斥选项、每个选项文案 ≤ 4 个字。刷新间隔是教科书级的正确用法。
- **颜色控制**：macOS 12+ 支持 `selectedSegmentBezelColor` 属性直接设置选中段背景色，这是少数可直接改色的系统控件属性。同时建议配合 §2.3.1 的 swizzle 方案保证全 App 一致。深色面板中需设 `appearance = NSAppearance(named: .darkAqua)`。
- **最佳实践**：
  - `trackingMode = .selectOne`（默认即正确）。
  - 段数超过 4 或文案变长时，降级为 `NSPopUpButton`（见 §5）。
  - 宽度用 hugging 约束贴合内容，不要拉伸——当前 `setContentHuggingPriority(.required, for: .horizontal)` 正确。
- **避免**：不要用分段控件触发「动作」（如「导出/清空」按钮组），那是 `trackingMode = .momentary` 的场景，popover 里不推荐。

### 1.4 按钮 NSButton

面板里有三种按钮形态，各有规矩：

| 形态      | 实现                                       | 用法                                                       |
| ------- | ---------------------------------------- | -------------------------------------------------------- |
| 无边框图标按钮 | `NSButton(.inline)` + `isBordered=false` | footer 退出按钮。配 `toolTip`，这是唯一正确形态——popover 里出现带边框大按钮会显得笨重 |
| 磁贴按钮    | 自绘 `ActionTileButton`（icon + 9pt 双行文本）   | 操作卡片。合理，因为原生 NSButton 做不出「icon 上 + 文本下」的网格布局             |
| 文字按钮    | *未用*                                     | API Key / Ticket 输入改走磁贴 → 弹 `NSAlert` 带 accessoryView，正确 |

- **最佳实践**：
  - 图标按钮必须设 `toolTip`（当前退出按钮已设「退出 iBalance」）。
  - 自绘按钮的 hover 态（8% 白底提亮 + pointingHand 光标 + 0.15s 过渡）已经与卡片 hover 统一，保留这套规范。
  - 破坏性动作（退出）放 footer 边缘、用次要色，不与主要操作同级——当前布局正确。

### 1.5 下拉菜单 NSPopUpButton

- **当前未用，是正确判断**：刷新间隔只有 3 个短选项，分段控件更直观。
- **何时该换**：若未来刷新间隔扩到 5+ 档（如加「10 分钟/30 分钟/手动」），或设置里新增「主题/语言」这类长文案选项，改用 `NSPopUpButton`（`.small` 尺寸，`pullsDown=false`）。
- **避免**：popover 里不要用 `pullsDown=true` 的下拉（标题即第一选项的样式容易误读）；选项 ≤4 且文案短时，不要为了「省空间」把分段控件换成下拉——分段控件一眼可见全部选项，交互成本更低。

### 1.6 标签与只读文本 NSTextField(labelWithString:)

- 余额数值用 `monospacedDigitSystemFont`（等宽数字）——数字变化时不抖动，这是金融/计量类显示的硬性最佳实践，当前已做到。
- 层级建议（与现状一致）：
  - 分组标题：12pt semibold + `secondaryLabelColor`
  - 正文/设置项：12pt regular + `secondaryLabelColor`（hover 提亮到 `labelColor`）
  - 辅助信息（签到、更新时间、昵称）：9~11pt + `secondaryLabelColor`
  - 核心数值：12pt semibold + 主前景色 `#e9e9e9`

### 1.7 进度可视化：自绘而非 NSProgressIndicator

当前 `UsageDots`（5 点阵）/ `UsageBar` / `UsageRing` 都是自绘 NSView——**这是对的选择**：

- `NSProgressIndicator` 的 bar 样式在 5pt 高度、40pt 宽的卡片右侧空间里既不好看也不可定制颜色阈值。
- 自绘实现了「剩余 <30% 红 / <70% 橙 / 否则绿」的阈值着色 + 脉冲动画，原生控件做不到。
- **规范**：继续遵循「画已用/剩余比例、圆角 = 高度/2、背景色 `quaternaryLabelColor`」的现有约定；新增进度类视图时复用 `usageColor()` 的阈值逻辑，保持全面板语义一致。

### 1.8 表格 / 标签页 / 滑块 / 输入框

详见 §6「避免使用清单」。一句话结论：**这个面板一行都不该出现它们**。多账号余额用动态卡片列表（当前实现）而不是 NSTableView，是完全正确的取舍。

---

## 2. 与 macOS HIG 对齐的要点

### 2.1 容器：NSPopover 的 HIG 约定

- HIG 规定 popover 用于「**与触发元素直接相关的少量补充内容/操作**」。当前 260pt 宽、垂直信息流、只读为主 + 轻设置，完全符合。
- 宽度保持在 220~320pt 区间（HIG 建议 popover 紧凑）；当前 260pt 合理，不建议再加宽。
- 不要在 popover 内再弹 popover。需要输入（API Key、Ticket）时用 `NSAlert` + `accessoryView`（当前方案），或临时小型 NSPanel 窗口——这是 HIG 认可的两种升级路径。

### 2.2 菜单栏应用的 HIG 约定

- 菜单栏图标应是 template image（单色、随系统深浅色反色）；「隐藏主 icon」这种偏好用开关立即生效，符合「菜单栏额外项应可配置」的惯例。
- 左键弹 popover、右键保留 NSMenu 兜底——与 HIG「菜单栏项主交互为菜单」略有出入，但已是 macOS 生态广泛接受的现代模式（如 Stats、Hidden Bar），保留即可。

### 2.3 颜色与材质

- **只用语义色**：`labelColor / secondaryLabelColor / tertiaryLabelColor / quaternaryLabelColor / systemGreen/Orange/Red`。它们自动适配深浅色与「增强对比度」辅助设置。当前代码基本做到了，唯一的例外是余额卡片的 `#e9e9e9` 硬编码——因为面板强制深色（`darkAqua`），这是可接受的，但建议包一层常量注释说明「仅在强制深色面板内使用」。
- 毛玻璃用 `.menu` material + `behindWindow` blending 是菜单类 UI 的标准做法，正确。
- 品牌 SVG 图标保持原色（`isTemplate=false`）、系统符号用 template + `contentTintColor`——当前的区分处理正确，且符合 HIG「template 图像用于单色图标」的规范。

#### 2.3.1 App 级 Accent Color：Method Swizzling 方案

**问题**：macOS 没有公开 API 为单个 App 单独设置 Accent Color。系统 Accent Color 由用户在「系统设置 → 外观」中选择，App 通过 `NSColor.controlAccentColor` 读取，正常情况下无法在 App 内覆盖而不影响其他 App。

这意味着 `NSSwitch`（开关）、`NSSegmentedControl`（选中段高亮）、`NSButton`（bezel 按钮）、焦点环等所有系统原生控件的强调色，默认跟随系统 Accent Color，无法通过属性直接修改（`selectedSegmentBezelColor` 是少数例外，macOS 12+ 可用）。

**解决方案**：通过 Objective-C runtime 的 **method swizzling**，在 App 启动时替换 `NSColor` 的两个类方法实现，让所有系统控件读到自定义颜色（本项目为 `.systemGreen`）。

实现代码（位于 `swift/main.swift` 的 `NSColor` extension 中）：

```swift
import ObjectiveC

extension NSColor {
    /// Swizzled replacement for +controlAccentColor — 返回 App 自定义强调色
    @objc static func ibalance_controlAccentColor() -> NSColor {
        return .systemGreen  // 改为其他系统语义色或自定义 NSColor 即可切换
    }

    /// Swizzled replacement for +colorNamed: — 拦截 "AccentColor" 查找
    @objc static func ibalance_colorNamed(_ name: String) -> NSColor? {
        if name == "AccentColor" || name == "Accent Color" {
            return .systemGreen
        }
        // 非 AccentColor 的命名颜色走原始实现（swizzle 后 selector 指向原方法）
        return ibalance_colorNamed(name)
    }

    /// 一次性安装 swizzle（幂等，可安全多次调用）。
    /// 必须在创建任何 UI 控件之前调用，建议放在 applicationDidFinishLaunching 最开头。
    static func installAppAccentColor() {
        struct Once {
            static let done: Void = {
                // 1) Swizzle +controlAccentColor
                if let orig = class_getClassMethod(NSColor.self,
                        #selector(getter: NSColor.controlAccentColor)),
                   let swiz = class_getClassMethod(NSColor.self,
                        #selector(NSColor.ibalance_controlAccentColor)) {
                    method_exchangeImplementations(orig, swiz)
                }
                // 2) Swizzle +colorNamed:（注意 Swift 中 colorNamed(_:) 被标记为
                //    replaced by init(named:)，需用 NSSelectorFromString 构造 selector）
                let origSel = NSSelectorFromString("colorNamed:")
                let swizSel = #selector(NSColor.ibalance_colorNamed(_:))
                if let orig = class_getClassMethod(NSColor.self, origSel),
                   let swiz = class_getClassMethod(NSColor.self, swizSel) {
                    method_exchangeImplementations(orig, swiz)
                }
            }()
        }
        _ = Once.done
    }
}
```

**调用时机**：在 `applicationDidFinishLaunching` 最开头，创建任何 UI 控件之前调用 `NSColor.installAppAccentColor()`。

**关键要点**：

| 要点 | 说明 |
|------|------|
| **作用域** | 仅本 App 进程内生效，不修改系统偏好设置，App 退出后自动恢复 |
| **安全边界** | 不碰任何私有 API，只替换公开类方法的实现；`colorNamed:` 仅拦截 "AccentColor"，其余颜色透传给原始实现 |
| **覆盖范围** | NSSwitch、NSSegmentedControl（选中段）、NSButton（bezel 样式）、焦点环、所有调用 `controlAccentColor` 的 AppKit 控件自动使用自定义色 |
| **语义色仍可用** | `selectedSegmentBezelColor = .systemGreen` 可作为显式 fallback 与 swizzle 并存，互不冲突 |
| **改色成本** | 只需修改两个方法中返回的 `NSColor`（如改为 `.systemBlue` / `NSColor(calibratedRed:green:blue:alpha:)`），全 App 控件统一变色 |
| **不推荐** | 用 KVC 设置 `tintColor`（NSSwitch 无公开 `tintColor` 属性，会导致运行时崩溃）；不要修改 `NSUserDefaults` 中的 `AppleAccentColor`（会影响系统全局） |

### 2.4 动效

- HIG 对动效的态度是「**短、轻、有意义**」：当前 hover 0.15s 提亮、刷新旋转、点阵脉冲都在此范围。
- 刷新按钮无限旋转必须有明确终止条件（当前 `setRefreshing(false)` 停止），避免「永远转圈」让用户以为卡死——已实现，保持。

---

## 3. 视觉风格、尺寸与间距规范

### 3.1 控件尺寸档位（controlSize）

| 档位         | 高度参考            | 面板内使用建议         |
| ---------- | --------------- | --------------- |
| `.regular` | ~28pt（开关 32×22） | **禁止**在面板内使用    |
| `.small`   | ~24pt（开关 28×18） | 分段控件基础档（再配视觉缩放） |
| `.mini`    | ~17pt（开关 24×15） | 开关专用档           |

> 当前的「`.mini/.small` + affineTransform 视觉缩放（0.81/0.82）」是在「原生控件渲染」和「面板紧凑度」之间的务实折中。它保留了原生控件的键盘焦点、VoiceOver、系统动画，只缩小视觉——比从头自绘开关/分段控件好得多。**新增同类控件时沿用 `MiniSwitch` / `MiniSegmentedControl` 子类，不要另起炉灶。**

### 3.2 间距标尺（来自现有实现，固化为规范）

```
面板内边距：  左右 6pt，上 14pt，下 11pt
卡片内边距：  左右 8pt，上下 4~7pt（余额 4，设置/操作 7）
卡片圆角：    8pt
行高：       设置行 16pt；分组标题行 22pt；footer 24pt；磁贴行 44pt
行内间距：    icon-文本 8pt；标题-昵称 6pt；签到三小项 6pt
卡片间距：    root stack 4pt
hover 高亮：  white 8% 圆角背景，0.15s easeInEaseOut
```

规则化建议：**所有间距取 2 的倍数、优先 4 的倍数**（现状基本满足）；新增行/卡片时从上表取已有值，不引入新数值。

### 3.3 字体标尺

| 用途              | 字号/字重                  |
| --------------- | ---------------------- |
| 分组标题            | 12pt semibold          |
| 设置项/正文          | 12pt regular           |
| 余额数值            | 12pt semibold，**等宽数字** |
| 辅助信息（签到/昵称/副标题） | 9~10pt regular，数字等宽    |
| 磁贴文本            | 9pt regular，最多 2 行截断   |
| footer          | 11pt regular           |

---

## 4. 可访问性（Accessibility）注意事项

当前面板在可访问性上是「原生控件及格、自绘控件缺失」的状态，按优先级列出：

### 4.1 必做（P0）

1. **自绘可点控件补无障碍属性**：`HoverCard`、`ActionTileButton`、`HoverRowView` 对 VoiceOver 是不可见的。需要：
   ```swift
   setAccessibilityRole(.button)
   setAccessibilityLabel("WorkBuddy 余额卡片，点击打开")
   setAccessibilityEnabled(true)
   ```
   尤其是「点击非当前账号卡片 = 切换账号」这种隐式操作，没有 label 时读屏用户完全无法发现。
2. **开关行的 accessibilityLabel**：`NSSwitch` 本身有声，但「点击整行」的手势区不发声。确保每个 switch 设了 `setAccessibilityLabel("自动签到")` 等（标签文本不会自动关联到开关）。
3. **点阵进度 `UsageDots`**：设 `setAccessibilityRole(.valueIndicator)` + `setAccessibilityValue("剩余 63%")`，否则读屏只能看到 5 个无意义色块。

### 4.2 应做（P1）

1. **键盘导航**：popover 默认不支持 Tab 键遍历。若做，用 `keyView` 链把 开关组 → 分段控件 → footer 退出按钮 串起来；自绘磁贴不参与键盘焦点（或用 `NSButton` 重构磁贴获得免费焦点环）。
2. **色彩对比**：`secondaryLabelColor` 在毛玻璃 + 42% 黑遮罩上的实际对比度建议用 Accessibility Inspector 实测，目标 ≥ 4.5:1（WCAG AA）。9pt 小字（磁贴文本、签到信息）尤其要测。
3. **「增强对比度」/「减少动态效果」**：
   - 监听 `NSWorkspace.accessibilityDisplayShouldIncreaseContrast` 变化，开启时把 hover 8% 提亮加强到 ~16% + 加 1pt 描边。
   - `accessibilityDisplayShouldReduceMotion` 为 true 时，停用点阵脉冲和刷新旋转（改为静态「刷新中…」文本），当前三个无限动画（spin/pulse/switchingPulse）都应接入此开关。

### 4.3 建议（P2）

1. toolTip 继续覆盖所有图标按钮（退出已有，若恢复头部刷新按钮同样要加）。
2. 数值变化（余额刷新）不需要主动播报；但签到成功/失败可以用 `NSAccessibilityAnnouncementRequested` 发一条通知。

---

## 5. 控件选择优先级（结合面板功能）

按「面板演进时优先考虑谁」排序：

1. **NSSwitch** —— 新增布尔偏好的唯一选择（如「开机启动」「低额度提醒」）。
2. **NSSegmentedControl** —— 新增短文案互斥选项（如「额度显示模式：剩余/已用」）。
3. **自绘卡片/磁贴** —— 新增平台余额 → 复用 `addCard` + `balanceContentRow`；新增操作 → 复用 `ActionTileButton` 网格（每行 4 个的规范不变）。
4. **NSPopUpButton** —— 当某设置选项 >4 个或文案 >6 字时，从分段控件降级替换。
5. **NSAlert + accessoryView** —— 一切需要输入文本/二次确认的需求（API Key 已在用；未来「确认退出」「清空账号」也用 alert，不要在 popover 里做内联确认区）。
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
| **editable NSTextField**        | popover 失焦即关，输入到一半点外面 = 内容丢失，是严重的交互事故               | NSAlert + accessoryView（当前方案）   |
| **NSComboBox**                  | 可编辑下拉，popover 内同样有失焦问题，且面板内无「可输入可选」的场景              | 不用                              |
| **NSDatePicker / NSColorWell**  | 重量级控件，popover 内无场景                                  | 不用                              |
| **NSScrollView**                | 面板高度应自适应内容；一旦需要滚动说明内容超纲                             | 超出 → 迁移到独立窗口                    |
| **NSLevelIndicator**            | 样式老旧且不可定制阈值色                                        | 继续自绘 UsageDots/Bar              |

另外两条**行为层面**的避免项：

- **避免在 popover 里做模态流**（多步向导、内联确认）。所有「确认」升级为 NSAlert。
- **避免常驻动画**。脉冲/旋转只能作为状态指示（刷新中、消耗中、切换中），有明确起止；纯装饰性循环动画在菜单栏面板里是耗电和分心的双重减分项（当前实现合规，保持）。

---

## 7. 落地检查清单（新增/修改控件时过一遍）

- [ ] 控件尺寸档位为 `.mini` / `.small`，或复用 `MiniSwitch` / `MiniSegmentedControl`
- [ ] 颜色全部为语义色；硬编码色仅限强制深色面板内并有注释
- [ ] 系统控件强调色通过 §2.3.1 的 App 级 Accent Color swizzle 统一控制，不要尝试 KVC 改 `tintColor`
- [ ] 分段控件显式设置 `selectedSegmentBezelColor` 作为 fallback（macOS 12+）
- [ ] 深色面板内控件设 `appearance = NSAppearance(named: .darkAqua)`
- [ ] 数字显示用 `monospacedDigitSystemFont`
- [ ] 间距取自 §3.2 标尺，字号取自 §3.3 标尺
- [ ] 图标按钮有 toolTip
- [ ] 自绘可点视图补了 accessibilityRole/Label/Value
- [ ] 无限动画接入了「减少动态效果」开关
- [ ] 交互可一步完成；需要输入/确认 → NSAlert
- [ ] hover 态与现有规范一致（8% 白底 / 0.15s / pointingHand）

---

*本文档随面板演进更新。控件新增规范先改这里，再改代码。*

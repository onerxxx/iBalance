# 004 — 面板层 SwiftUI 重写：代码量评估

- **Status**: ASSESSMENT（未开工，仅评估）
- **Date**: 2026-09-01
- **Scope**: 面板内容层（popover 内容视图 + 其控件/自绘层）迁 SwiftUI；菜单栏 + popover 壳 + 弹窗保持 AppKit
- **Deployment target**: macOS 26.0（`swift/Package.swift:8`），SwiftUI 全能力可用，无版本障碍

---

## 结论先行

| 指标 | 数值 |
|---|---|
| 面板层代码量 | **10,078 行 → ~5,300 行（-47%）** |
| 全项目代码量 | 18,847 → ~14,040 行（**-26%**，删 ~4,800 行） |
| 净新增文件 | SwiftUI/ 下 12–16 个视图文件（行数已含在上表内，只是重新分布） |
| 工作量 | **12.5–17 人日**（单人全职约 3 周），含自测与视觉对齐，不含设计返工 |
| 迁移期临时债 | +300~500 行桥接代码（`NSViewRepresentable` 包装 + 双轨），收尾删除 |

**判断：值得做，但不要在没过「阶段 0」之前全面铺开。** 收益是真实的、且兑现周期就在本季度（你这套面板正在密集迭代）；风险集中在 popover 尺寸桥与 pin 浮窗转移两处，任一处堵死就得重估。

---

## 1. 现状分层（按「是否属于面板层」切分）

live code 18,847 行（已排除 `scratch_tmp_render_test.swift` 119 行与 `RollingNumberView.swift.orig/.tmp_orig` 死文件）。

### A. 面板层 —— 重写目标，10,078 行

| 文件 | 行数 | 内部构成 |
|---|---:|---|
| `Panel.swift` | 2,790 | Palette/Motion/模型 476 + `BalancePanelViewController` 512 + `BalancePanelView` 1,784 |
| `Controls.swift` | 1,880 | 面板控件全量（HoverCard / HoverRow / 开关 / 下拉 / 滚动提示层 / resize 把手） |
| `TokensPanel.swift` | 1,725 | 数据层+热力图自绘 ~1,580 ｜ 面板挂载 extension 145 |
| `PanelLayout.swift` | 1,406 | `extension BalancePanelView`：build 装配 ~550 / 卡片行 ~226 / 动效 ~200 / 工具 ~180 |
| `UsagePanel.swift` | 1,076 | 图表自绘+子弹窗 ~780 ｜ 面板挂载 extension 296 |
| `RollingNumberView.swift` | 879 | 逐位垂直滚动数值（DigitWheel / TextSlot / RollingNumberView 三类） |
| `PanelDrag.swift` | 322 | `extension BalancePanelView`：卡片拖拽排序 + 平台顺序应用 |

### B. 壳 —— 小改，2,728 行

| 文件 | 行数 | 说明 |
|---|---:|---|
| `main.swift` | 2,604 | 菜单栏 + 编排；对 panel 的调用点 **42 处**（`panel.onXxx` 接线 + `panel.update()`） |
| `PinWindow.swift` | 124 | popover ↔ 无边框 NSPanel 内容转移、尺寸恢复 |

### C. 不动 —— 6,041 行

`Services/` 2,323（DeepSeek/智谱/Qwen/WorkBuddy/TRAE/ZCode/Codex/WbShare/BrowserCookie）+
`CheckinManager` 831 + `Config` 795 + `Dialogs` 767（NSAlert 弹窗，保持 AppKit）+
`AccountSwitcher` 381 + `UpdateService` 297 + `WbTokens` 216 + `Network` 134 + `Logger` 107 +
`ProcessUtil` 69 + `Crypto` 49 + `SmallTable` 41 + `Package.swift` 31。

---

## 2. 改后估算（逐文件）

| 文件 | 现状 | 改后 | Δ | 主要依据 |
|---|---:|---:|---:|---|
| `Panel.swift` | 2,790 | ~1,380 | **-1,410** | `BalancePanelView` 1,784→700；VC 512→260（只留 popover 尺寸桥）；模型 476→~400（`NickBadgeTextField` 55 行删，Palette→Color 扩展） |
| `PanelLayout.swift` | 1,406 | ~520 | **-886** | `build()` 550→180；`balanceContentRow` 226→90（20 个参数→进 model）；动效 200→70 |
| `Controls.swift` | 1,880 | ~560 | **-1,320** | `HoverCard` 480→120；`HoverRowView` 250→60；`ScrollFadeHint` 200→70；tracking area 全部删除（23 处） |
| `TokensPanel.swift` | 1,725 | ~1,150 | -575 | 数据层 ~900 全保留；热力图自绘 680→250（Canvas） |
| `UsagePanel.swift` | 1,076 | ~620 | -456 | 图表 511→250（Canvas）；面板挂载 296→110；`UsageDots` 60→20 |
| `PanelDrag.swift` | 322 | ~150 | -172 | 手写 `mouseDragged` 位移 + 落点判定 → `DragGesture` |
| `RollingNumberView.swift` | 879 | ~919 | **+40** | 阶段一加 `NSViewRepresentable` 包装（内部不动） |
| `main.swift` | 2,604 | ~2,560 | -44 | 仅改 42 处接线 → ViewModel |
| `PinWindow.swift` | 124 | ~140 | **+16** | 适配 hosting view 转移 |
| 其余 12 项 | 6,041 | 6,041 | 0 | 不动 |
| **合计** | **18,847** | **~14,040** | **-4,807 (-26%)** | |

### 被 SwiftUI 直接消灭的部分（不必重写，直接删）

| 项 | 行数 | 为什么消失 |
|---|---:|---|
| 手动 diff：`applyAccountCardData` + `CardEntry` 引用表 + 7 组 `xxxCardEntries/xxxCardUids` | ~230 | SwiftUI 按 identity 自动 diff |
| 12 个空壳 `rebuildXxxCards` / `applyXxxCardData` | ~80 | 同一套 `ForEach` |
| 字体传播链：`registerFont` / `registerRollingNumber` / `applyFontPolicy` + 调用点 | ~90 | `.font()` 声明式，Mono 开关不再需要遍历 |
| 外观传播：`viewDidChangeEffectiveAppearance` 转发链（6 处） | ~120 | 动态色在 SwiftUI 原生解析；强制浅色走 `.preferredColorScheme` |
| `NickBadgeTextField` 手动截断保徽章 | ~55 | HStack 里徽章 trailing 固定即可 |
| 布局自测设施（`layoutProbe` / `toggleSectionForAutoTest` / `IBLayoutAutoTest` 时序脚本） | ~80 | 无约束即无回归面；这是**结果**不是目的 |

### 需包 `NSViewRepresentable` 或 Canvas 重写的自绘层

| 自绘体 | 现状 | 选项 A：包装 | 选项 B：Canvas 重写 |
|---|---:|---:|---|
| `UsageHistoryChartView`（折线+面积+今日标注） | 511 | ~40 行包装 | ~250 行，纯声明式 |
| TokensPanel 热力图 + hover 气泡 | 680 | ~40 行包装 | ~250 行 |
| `RollingNumberView`（逐位滚动） | 879 | ~40 行包装 | ~250 行 |
| `TintedVisualEffectView`（毛玻璃） | ~60 | ~40 行包装（推荐） | 无对应 |
| `PanelResizeHandle`（pin 浮窗 resize） | ~100 | **保留不动**（窗口层，非内容层） | — |

**建议**：图表/热力图走 Canvas（一次性还清债，且 MARK 里记过「自绘层不参与字体/外观自动传播」这条坑，重写后这条坑自动消失）；`RollingNumberView` 阶段一先包装、阶段三随卡片区一起重写（SwiftUI 里每位一个 VStack + offset，比 NSView 版简短得多）；毛玻璃保持包装。

---

## 3. 工作量拆解

| 阶段 | 内容 | 人日 |
|---|---|---:|
| 0 | 地基：`@Observable` ViewModel + `NSHostingController` 接入 popover + 尺寸桥 + 主题/字体注入 | 1.5–2 |
| 1 | 设置区（开关/下拉/刷新按钮/滚动提示层/折叠）——最简单，用来验证迁移范式 | 1.5–2 |
| 2 | 用量区（行 + 图表 Canvas + 子弹窗 + 折叠） | 1.5–2 |
| 3 | **卡片区**（多平台卡 + RollingNumberView + hover dwell + 右键菜单 + 拖拽排序） | 3–4 |
| 4 | Token 板块（Canvas 重写） | 1–1.5 |
| 5 | 动效对齐（stagger 入场/离场、数值滚动预览、交叉淡化、hover 渐变） | 1–1.5 |
| 6 | pin 浮窗适配（内容转移 + resize + 拖动 + 尺寸持久化） | 1 |
| 7 | 回归与细节（逐像素对齐、深浅色、Mono、离线态、CPU 实测） | 2–3 |
| | **合计** | **12.5–17** |

---

## 4. 风险清单（按严重度）

| # | 风险 | 严重度 | 说明 |
|---|---|---|---|
| 1 | **popover 尺寸桥** | **HIGH** | 现有 `updateContentSize` / `setMaximumHeight` / `syncDocumentSizeToViewport`（~200 行）是为了让 popover 高度随内容收缩且不被拉伸。SwiftUI 侧需重新实现高度桥（`NSHostingView.fittingSize` 或 `sizeThatFits`）。记忆里的「popover 注入 501 优先级 `preferredContentSize` 约束、可反向驱动窗口尺寸」会以新形式重现。**这是 go/no-go 点。** |
| 2 | **pin 浮窗内容转移** | **HIGH** | 现在把 `vc.view` 直接搬到 `NSPanel`（`PinWindow.swift:59`）。SwiftUI 版搬 hosting view，需验证「转移瞬间不重建、不闪烁、尺寸不弹回」，且浮窗 resize 时 hosting view 的响应不能触发内容重排。 |
| 3 | **卡片上手势叠加** | **MEDIUM-HIGH** | 同一张卡上要叠 hover dwell 计时器 + 拖拽排序 + 右键上下文菜单。SwiftUI 在 macOS 上 `onContinuousHover` + `DragGesture` + `contextMenu` 会互相抢，不如 AppKit 事件链可控。**最可能需要妥协交互细节的地方**（比如 dwell 期间拖动的降级行为）。 |
| 4 | **强制浅色外观** | MEDIUM | 现用 `panelAppearance()` 给面板强加 aqua。SwiftUI 需 `.preferredColorScheme`，且要保证 `NSViewRepresentable` 里的自绘层同步。记忆里「动态色直落 CALayer 按系统外观解算 → 浅色面板拿到深色分支」这条坑会换形式回来。 |
| 5 | **CPU / 帧率** | MEDIUM | 常驻菜单栏 + nonactivating 浮窗 + 数值滚动预览定时触发。SwiftUI 隐式动画可能比手工 CALayer 更耗，且与已调好的 `Motion` token 打架。需实测，不是推理能定。 |
| 6 | **迁移期双轨** | LOW-MEDIUM | 阶段 1–4 期间 AppKit 与 SwiftUI 共存，+300~500 行临时桥接。可控，但要有纪律地删。 |

---

## 5. 动机核对

原始动机两条，核对结果：

1. **「AppKit 约束布局维护成本高」——成立，且量化的收益就在布局文件上。**
   `PanelLayout` -63%、`Controls` -70%。`balanceContentRow` 一个函数 20 个参数、226 行，迁完约 90 行且参数进 model。

2. **「布局回归靠自测设施兜底」——方向对，但量级要修正。**
   自测设施本身只有 ~80 行（`layoutProbe` + `toggleSectionForAutoTest` + main.swift 里的 `IBLayoutAutoTest` 时序脚本），删掉它不是主要收益。真正的收益是**回归源头消失**：无约束、无 `NSStackView.distribution` 的 `fill` 增长不可靠、无记忆里那条「嵌套 stack fill 会把内层余额卡片拉高」的坑。省下的是每次改布局的排查时间，不是那 80 行代码。

**补充一条收益（原始动机未提，但可能是最大的）**：现有的 `PanelSnapshot` / `AccountCardSnapshot` 已经是 `Equatable` 值类型、`main.swift` 侧 `makePanelSnapshot()` 组装后面板只消费不回写——**架构上已经是 SwiftUI 的形状了**。这是这次迁移成本偏低的结构性原因，值得写进决策理由。

---

## 5b. 视觉与功能影响面核查（2026-09-01 补充）

结论：**约 80% 视觉可 1:1 复现；约 15% 需换算后实测对齐；约 5% 有实质降级风险。**
功能上业务逻辑零影响，交互有 3 处需重新实现。

### A. 可 1:1 复现（无可见变化）

| 项 | 依据 | 迁移方式 |
|---|---|---|
| Palette 全量配色 | `Panel.swift:217 enum Palette` | `Color(NSColor:)` 直接复用 |
| 卡片圆角容器 | `PanelLayout.swift:139` `cornerCurve = .continuous` + `masksToBounds` | `.clipShape(RoundedRectangle(cornerRadius:, style: .continuous))` |
| 卡片数值口径 | `CardStyle.iconSize 24` / icon 列宽 24.47 / 行高 16·12 / spacing 1 / 字号 13·9 | 同一组数字搬过去 |
| 深浅色与强制浅色 | `Palette.panelAppearance`（`Panel.swift:299`） | `.preferredColorScheme` |
| Mono 字体 | `MonoFontProvider`（`Panel.swift:432`） | `.custom("JetBrainsMono", size:)` |
| stagger 入场 | `staggerRiseIn`（`PanelLayout.swift:1133`，-14pt 逐行 delay） | `.transition(.offset(y:))` + 显式 delay |
| UsageDots 点阵 | `UsagePanel.swift:645`（~60 行自绘） | HStack 方块，~20 行 |
| 减弱动效 | `shouldReduceMotion`（多处 guard） | `@Environment(\.accessibilityReduceMotion)` |

### B. 需换算或重写、能对齐（低—中风险，须实测）

| # | 项 | 现实现 | SwiftUI 侧要点 |
|---|---|---|---|
| B1 | 面板渐变 | `TintOverlayView.draw`（`Controls.swift:1472`）：isFlipped 语义 + `NSGradient` 纵向 + 起点以上纯色区 | `Gradient(stops:)` 用**相对 location** 复现；需 `GeometryReader` 把 `gradientStartY` 的 pt 值换算成 0~1。换算错一格即见色阶跳变 |
| B2 | 毛玻璃 | `TintedVisualEffectView`（`Controls.swift:1501`）= NSVisualEffectView + 自绘 tint overlay | **必须 `NSViewRepresentable` 包装**。改用 `.background(.regularMaterial)` 会丢 tint 蒙版层次，视觉一定不同 |
| B3 | 数值逐位滚动 | `RollingNumberView` 879 行（DigitWheel / TextSlot） | 包装可 1:1，但 `updateNSView` 会被 SwiftUI 高频调用——**现有 `lastValue` 判据必须搬进 Representable 的 update**，否则反复触发滚动动画 |
| B4 | 用量图表 / Token 热力图 | 自绘 + 位图烘焙 | Canvas 重写时须重新验证 `plans/003` 刚修掉的点阵淡变 ≤1px 跳动几何，否则回归 |
| B5 | 悬浮气泡 | `tipShapePath` 自绘带箭头（`Panel.swift:2452`） | SwiftUI 无原生带箭头气泡（`.popover` 样式/时机不同，nonactivating 浮窗有层级坑）→ 自绘 overlay |
| B6 | 角标 / 菜单栏圆点定位 | `PanelLayout.swift:784-788`，`centerY constant = -imgSize/2` | `overlay(alignment:)` + offset。**AppKit centerY 是翻转语义、SwiftUI offset y 是正常语义，数值需反号** |
| B7 | 滚动提示层 | `ScrollFadeHint`（`Controls.swift:1587`）：mask 渐隐 + bob 浮动 + `CIDarkenBlendMode`（:1703） | macOS 26 有 `.onScrollGeometryChange` 可拿 offset；但 `compositingFilter` 无对应，需 `.blendMode(.darken)` 近似，语义不保证一致 |

### C. 实质降级风险（SwiftUI 无对应能力）—— 3 处，全部落在 CIFilter-on-layer

| # | 项 | 现实现 | 问题 |
|---|---|---|---|
| **C1** | **hover 确认进度的柔边擦除** | `startHoverDwell`（`Controls.swift:1162`）：`CALayer` mask 挂 `CIGaussianBlur(radius:16)`，对 mask 的 `bounds.size.width` 做 0→w 线性动画 = 一条 16pt 柔边横扫卡片 | SwiftUI **没有「给 mask 加 CIFilter」这层能力**。近似写法 `.mask(alignment:.leading){ Rectangle().frame(width: p*w).blur(radius:16) }` 的边缘行为与 radius 语义不保证一致 → 柔边软硬程度可能肉眼可辨 |
| **C1b** | ︎└ 配套的中途取消冻结 | `cancelHoverDwell`（`Controls.swift:1215`）：取消时读 `mask.presentation()?.bounds` 钉在当前宽度 | SwiftUI 无 `presentation()` 可读；且记忆里刚为「同事件拍内冻结视觉值不可靠」做过定案 → **半截进度冻结的手感需要重新设计**（改为自维护 progress state，而非读 layer） |
| **C2** | **字符模糊过渡** | `playCharBlurTransition`（`PanelLayout.swift:1045`）：`layerUsesCoreImageFilters = true` + 每帧重建 `CIGaussianBlur` 实例（注释明确：改 inputRadius 不触发 CA 重合成，必须换实例），60fps Timer 驱动，ease-out cubic，maxRadius 4，0.35s | SwiftUI 有 `.blur(radius:)` 且可动画，但**无 `layerUsesCoreImageFilters`**，模糊是否溢出卡片 bounds 的行为不同；Timer 驱动要换 TimelineView / 显式动画。影响 Mono 开关切换、点阵↔账号条互换的过渡。退路：改写成 opacity/scale 组合（视觉降级） |
| **C3** | **popover 尺寸随内容伸缩** | `updateContentSize` / `setMaximumHeight` / `syncDocumentSizeToViewport`（VC ~200 行）；`main.swift:727` 超限转内部滚动 | **功能 + 视觉双重风险**。SwiftUI 侧要重做高度桥（`fittingSize` / `sizeThatFits` + 手动设 `preferredContentSize`）。做不好即见：折叠后留白、展开时高度跳变/抖动。记忆里有 `hasFullSizeContent` 导致「折叠/展开时面板左右抖动」的回滚史，说明这块本就敏感 |

### D. 功能层面

**会变好的**
- 整卡 `hitTest` 接管 + `interactiveSubview` 手动路由（`Controls.swift:1097` / `1236`）→ SwiftUI 子视图手势天然优先，这套手动路由可删，行为更可预测。
- 字体 / 外观传播链（`registerFont` / `applyFontPolicy` / `viewDidChangeEffectiveAppearance` 6 处转发）→ 声明式自动生效，「自绘层不参与自动传播」这条坑消失。

**需重新实现、可能微调**
- 卡片点击 vs 拖拽的区分：现 `mouseDown` 记位置 + `mouseUp` 在 bounds 内才触发（`Controls.swift:1228` 注释）→ 换 `onTapGesture` + `DragGesture(minimumDistance:)`，**阈值语义不同**，快速小幅抖动的判定会变。
- 右键菜单：`main.swift:673 onRightClickCard → toggleMenuBarVisibility`（传 `NSEvent` 弹菜单）→ `.contextMenu`；在 nonactivating 浮窗里的呈现与消失时机需实测。
- 拖拽排序预览：`configureDragContentView` / `setDragContentOpacity` → DragGesture 重写要自做预览与落位。

**完全不受影响**（不在面板层）
菜单栏标题渲染与顺序、pin 浮窗拖动与 resize（窗口层，保留 AppKit）、NSAlert 弹窗、全部网络 / 签到 / 配置 / 账号切换逻辑。

---

## 6. 建议路径

**分阶段、可回滚、阶段 0 设 go/no-go。**

- **阶段 0（1.5–2 人日）先只做地基**：空 SwiftUI 壳接入 popover，把 1) 尺寸随内容伸缩、2) 主题/字体注入、3) pin 浮窗转移跑通。
  - 过了 → 继续阶段 1。
  - 卡在 #1 或 #2 → 停。说明 SwiftUI 在这个壳里的适配成本高于预估，维持 AppKit 更划算。
- **阶段 0 额外加做一个「三风险最小 demo」**（半人日，与地基并行）：一张假卡片上验证 C1 hover 柔边进度 + C1b 中途取消冻结 + C2 字符模糊过渡，与现有 AppKit 实现同屏对比。
  - 判据不是「能不能做出来」，而是「**柔边软硬程度与模糊溢出行为肉眼是否可辨差异**」。
  - 这三处是唯一有实质降级风险的地方，且全部落在 CIFilter-on-layer 能力上——**先把它们判死，后面 5 个阶段的估算才成立**。
  - 若 C1 无法对齐：降级方案是把 hover 确认从「柔边擦除进度」改为「不透明度渐显」，需用户拍板（这是交互语义变更，不是实现细节）。
- **阶段 1 从设置区开始**（不是卡片区）：最简单的区，用来沉淀 hover/开关/下拉/动效的迁移范式，写进 AGENT.md 供后续区块复用。
- **每阶段结束保留双轨可切换**（一个编译期或 UserDefaults 开关），直到阶段 5 完成再删 AppKit 旧路径。
- **不要一次性大爆炸重写。** 混合期 `NSViewRepresentable` 包装是完全可行的过渡手段。

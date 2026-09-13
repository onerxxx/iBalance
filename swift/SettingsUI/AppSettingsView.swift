// 设置窗口视图：照 macOS 系统设置范式 —— NavigationSplitView 左 sidebar + Form(.grouped) 右表单，
// 全部原生控件；操作类行 = 图标 + 标题/说明 + 行尾按钮的 HStack（原因见 OperationRow）。
// 滑杆一律走 `snapped(_:in:step:)`（连续滑杆 + 写入吸附），不要用 `Slider(step:)` —— 见该函数注释。

import Foundation
import SwiftUI

/// 侧栏条目（2026-09-12 用户拆分定稿：原「操作」的三个栏目 + 「其他」四项各自独立成项；
/// 同日「主题调教」「平台开关」由面板右上角分段控件 / 玻璃弹窗迁入。
/// 2026-09-13 用户要求：「主题外观」提到最前、打开默认第一项；「设置」项撤销 ——
/// 自动签到并入「签到」、自动检查更新迁「关于」，由「签到」顶替其位；
/// 同日「WB 同步」并入「账号」。侧栏顺序 = 枚举声明序）
public enum SettingsSidebarItem: String, CaseIterable, Identifiable, Hashable {
    case appearance
    case checkin
    case platforms
    case accounts
    case keyQuota
    case coinDemo
    case animation
    case about

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .appearance: "主题外观"
        case .platforms: "平台"
        case .accounts: "账号"
        case .checkin: "签到"
        case .keyQuota: "Key / 额度"
        case .coinDemo: "3D 硬币"
        case .animation: "动画"
        case .about: "关于"
        }
    }
    public var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .platforms: "circle.grid.2x2"
        case .accounts: "person.crop.circle.badge.plus"
        case .checkin: "checkmark.seal"
        case .keyQuota: "key.horizontal"
        case .coinDemo: "rotate.3d"
        case .animation: "circle.dotted"
        case .about: "info.circle"
        }
    }
}

/// 窗口主体：左 sidebar（设置/操作）+ 右 pane 切换
/// 注：不使用 `@State` / `#Preview` 等**宏** —— 本机 build.sh 走 CLT 工具链，
/// SwiftUI 的宏（`SwiftUIMacros`）随 Xcode 分发，这里只有属性包装器形态可用；
/// `@State` 在新 SDK 里被宏版本遮蔽，直接报 "StateMacro could not be found"。
/// 需要绑定的值一律走 `@Bindable`（属性包装器，非宏）+ 模型侧的可写属性；
/// `@Bindable` 走 `$model.xxx` / `$model.nested.xxx` 直接出 Binding，无需手写 get/set 桥。
public struct AppSettingsView: View {
    @Bindable var model: AppSettingsModel

    public init(model: AppSettingsModel) {
        self.model = model
    }

    public var body: some View {
        // 侧栏**不可折叠**：columnVisibility 锁死 `.all`（用户 2026-09-12 定稿：不要隐藏功能）。
        // 用 `.constant` 而不是模型属性 —— 没人写它，也就不需要 @Observable 那一层。
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $model.selection) {
                ForEach(SettingsSidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            // 宽度上下限（用户 2026-09-12 定稿）：拖不窄于 180、拖不宽于 240
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            // pane 直接 switch（不再套一层 Group：`detail:` 本身就是 ViewBuilder）
            switch model.selection {
            case .appearance: ThemePane(model: model)
            case .platforms:
                HostedPane(model: model, item: .platforms,
                           fallbackIcon: .symbol("circle.grid.2x2"), fallbackTitle: "平台开关")
            case .accounts: AccountsPane(model: model)
            case .checkin: CheckinPane(model: model)
            case .keyQuota: KeyQuotaPane(model: model)
            case .coinDemo:
                HostedPane(model: model, item: .coinDemo,
                           fallbackIcon: .symbol("rotate.3d"), fallbackTitle: "3D 硬币")
            case .animation: AnimationPane(model: model)
            case .about: AboutPane(model: model)
            }
            // 「后退/前进胶囊 + pane 标题」2026-09-12 暂时去掉（模型侧历史栈保留，
            // 恢复即把 toolbar 块加回，见 BackForwardControl 与 model.navigate*）。
            // ⚠️ toolbar 保持**空的**：同日试过在里面挂「侧栏显隐」按钮，用户当日退回 ——
            // 侧栏固定展开，不给折叠入口（columnVisibility 已锁 `.all`）。
        }
        // grouped 表单样式收口一处：所有 pane 的 Form 都吃它（CoinDemoPane 不是 Form，不受影响）
        .formStyle(.grouped)
        .frame(minWidth: SettingsWindowMetrics.minWidth,
               minHeight: SettingsWindowMetrics.minHeight)
    }
}

// MARK: - 账号 pane（原「操作→账号」栏目）

private struct AccountsPane: View {
    let model: AppSettingsModel

    var body: some View {
        Form {
            Section {
                // 平台品牌 PNG（dark 版，键与面板卡片图标名同源）
                // 四行统一：无小字副标题 + 同一个按钮文案（2026-09-12 用户指定；各平台取账号的
                // 具体方式由按钮文案统一承载，不再逐行区分）
                OperationRow(model: model, icon: .platform("workbuddy"), title: "WorkBuddy",
                             subtitle: nil, actionTitle: "本机JSON导入") { model.actions.addWbAccount() }
                OperationRow(model: model, icon: .platform("trae-color"), title: "TRAE",
                             subtitle: nil, actionTitle: "本机JSON导入") { model.actions.addTraeAccount() }
                OperationRow(model: model, icon: .platform("zhipu"), title: "ZCode",
                             subtitle: nil, actionTitle: "本机JSON导入") { model.actions.addZcodeAccount() }
                OperationRow(model: model, icon: .platform("codex"), title: "Codex",
                             subtitle: nil, actionTitle: "本机JSON导入") { model.actions.addCodexAccount() }
            }
            // 2026-09-13 由独立「WB 同步」pane 并入（原 SingleActionPane 整体删除）
            Section {
                OperationRow(model: model, icon: .symbol("square.and.arrow.up.on.square"), title: "WB 同步",
                             subtitle: "全部历史会话与记忆同步给当前登录的 WorkBuddy 账号",
                             actionTitle: "同步") { model.actions.shareWbHistory() }
            }
        }
    }
}

// MARK: - 签到 pane（原「操作→签到」栏目；2026-09-13 并入原「设置」的自动签到段）

private struct CheckinPane: View {
    let model: AppSettingsModel

    var body: some View {
        Form {
            Section {
                OperationRow(model: model, icon: .symbol("checkmark.seal"), title: "一键签到",
                             subtitle: "手动为全部账号签到", actionTitle: "签到") { model.actions.manualCheckin() }
                OperationRow(model: model, icon: .symbol("list.bullet.rectangle"), title: "签到历史",
                             subtitle: "查看各账号签到记录", actionTitle: "查看") { model.actions.showCheckinHistory() }
            }
            Section {
                Toggle("自动签到", isOn: autoCheckinBinding)
                if !model.snapshot.autoCheckinSub.isEmpty {
                    LabeledContent("今日签到") {
                        Text(model.snapshot.autoCheckinSub).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("WorkBuddy 与 TRAE 账号每日自动错峰签到。")
            }
        }
    }

    // ⚠️ 刻意用闭包 Binding 而不是 `$model.xxx`：写入必须转交宿主动作（落盘 / 推给
    //    菜单栏控制器），keyPath 绑定表达不了这个 transform —— 官方口径里
    //    「没有合适 keyPath 或 subscript 时才用闭包 Binding」的那个例外。
    private var autoCheckinBinding: Binding<Bool> {
        Binding(get: { model.snapshot.autoCheckin }, set: { model.setAutoCheckin($0) })
    }
}

// MARK: - 关于 pane（关于行 + 2026-09-13 由「设置」迁入的自动检查更新段）

private struct AboutPane: View {
    let model: AppSettingsModel

    var body: some View {
        Form {
            Section {
                OperationRow(model: model, icon: .symbol("info.circle"), title: "关于 iBalance",
                             subtitle: "版本与项目信息", actionTitle: "打开") { model.actions.about() }
            }
            Section {
                Toggle("自动检查更新", isOn: autoUpdateBinding)
                // 两个动作合用一行、整体靠右：Button 直接作 Section 行会被 Form 各占一行且左对齐，
                // 所以包进 HStack 并用 Spacer 顶到行尾（两条文案等长，宽度天然一致）
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("立即检查更新") { model.actions.checkForUpdate() }
                    Button("更新窗口演示") { model.actions.runUpdateDemo() }
                }
            } footer: {
                Text("每日静默检查一次 GitHub Releases 新版本；「更新窗口演示」走全流程，但不出网、不真替换。")
            }
        }
    }

    private var autoUpdateBinding: Binding<Bool> {
        Binding(get: { model.snapshot.autoUpdateCheck }, set: { model.setAutoUpdateCheck($0) })
    }
}

// MARK: - Key / 额度 pane（原 AppKit 玻璃弹窗的内联表单版）

/// DeepSeek API Key / 日常额度 + ZhiPu Token / Qwen Ticket 覆盖。
///
/// 无「保存」按钮（2026-09-12 用户移除）：凭据类输入逐键落盘不合适，所以改成
/// **编辑结束即生效** —— 提交时机由模型侧的 `commitKeyQuotaIfDirty()` 统一负责：
/// ① 回车（各输入框 `.onSubmit`）；② 离开本 pane（`selection.didSet`）；
/// ③ 关窗（`SettingsWindowController.windowWillClose`）。
/// ⚠️ 改档位（Picker）不在其中：选「自定义」时输入框还是空的，立刻提交会把额度先写成 0。
/// 草稿存在模型的 `keyQuotaDraft` 里而不是视图 `@State` —— `@State` 是 SwiftUI 宏，本机 CLT
/// 工具链缺 SwiftUIMacros 插件编不过；窗口每次打开 `beginSession()` 仍按真实配置重置草稿。
private struct KeyQuotaPane: View {
    // 官方口径：需要给注入的 @Observable 属性生成 Binding 时用 @Bindable（属性包装器形态），
    // 直接 `$model.keyQuotaDraft.apiKey`；不必再手写 Binding(get:set:) 桥。
    @Bindable var model: AppSettingsModel

    var body: some View {
        Form {
            Section {
                TextField("API Key", text: $model.keyQuotaDraft.apiKey, prompt: Text("sk-…"))
                    .onSubmit { model.commitKeyQuotaIfDirty() }
                Picker("日常额度", selection: $model.keyQuotaDraft.quotaChoice) {
                    // ForEach 走 Identifiable（preset.value 即 id），不用 index；
                    // 选中值是 QuotaChoice 枚举，预设档与「自定义」各有稳定 identity
                    ForEach(KeyQuotaDraft.presets) { preset in
                        Text(preset.title).tag(KeyQuotaDraft.QuotaChoice.preset(preset.value))
                    }
                    Divider()
                    Text("自定义").tag(KeyQuotaDraft.QuotaChoice.custom)
                }
                .pickerStyle(.menu)
                // ⚠️ 刻意**不**在改档位时提交：选「自定义」的瞬间 quotaText 还是空的，
                //    提交会把额度先写成 0（= 不画点阵），要等用户填完再由回车/离开 pane 提交
                // 只有「自定义」档才出现手填框：随选择增删行，符合官方「按状态显示相关输入」的做法
                if model.keyQuotaDraft.quotaChoice == .custom {
                    TextField("自定义额度", text: $model.keyQuotaDraft.quotaText, prompt: Text("¥"))
                        .frame(width: 120)
                        .onSubmit { model.commitKeyQuotaIfDirty() }
                }
            } header: {
                Text("DeepSeek")
            } footer: {
                Text("API Key 只存本机钥匙串，不落明文。日常额度是点阵的分母（0 = 不画点阵）。\n获取 Key：[platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys)")
            }
            Section {
                TextField("ZhiPu Token", text: $model.keyQuotaDraft.zhipuToken, prompt: Text("留空 = 自动读取浏览器登录态"))
                    .onSubmit { model.commitKeyQuotaIfDirty() }
                TextField("Qwen Ticket", text: $model.keyQuotaDraft.qwenTicket, prompt: Text("留空 = 自动读取浏览器登录态"))
                    .onSubmit { model.commitKeyQuotaIfDirty() }
            } header: {
                Text("浏览器登录态覆盖")
            } footer: {
                Text("留空则解密浏览器 Cookies 取登录态，填了以手填值为准（浏览器登出后仍可用）。回车 / 换页 / 关窗即保存。")
            }
        }
    }
}

// MARK: - 动画 pane（菜单栏「进行中」蓝点的小球弹跳参数）

/// 菜单栏状态点弹跳参数：顶部实时预览 + 五项滑杆。改动即时生效并落盘
/// （与「设置」pane 的刷新间隔同口径：不留「保存」按钮）。
private struct AnimationPane: View {
    let model: AppSettingsModel

    var body: some View {
        Form {
            Section {
                BouncePreview(settings: model.snapshot.bounce)
                    .frame(height: 92)
            } header: {
                Text("预览")
            } footer: {
                Text("菜单栏图标前的「进行中」蓝点，按当前参数实时演算。")
            }
            Section {
                sliderRow("弹跳高度", \.amplitude, MenuBarBounceSettings.amplitudeRange, 0.1, "%.1f pt")
                sliderRow("弹跳周期", \.period, MenuBarBounceSettings.periodRange, 0.05, "%.2f s")
                sliderRow("腾空占比", \.airRatio, MenuBarBounceSettings.airRatioRange, 0.01, "%.2f")
                sliderRow("触地压扁", \.squashMin, MenuBarBounceSettings.squashRange, 0.01, "%.2f")
                sliderRow("顶点拉伸", \.stretchMax, MenuBarBounceSettings.stretchRange, 0.01, "%.2f")
            } footer: {
                Text("「腾空占比」越小，落地压扁驻留越久；「触地压扁 / 顶点拉伸」是纵向形变，横向按体积守恒自动反向补偿。参数只影响「进行中」蓝点。")
            }
            Section {
                Button("恢复默认") { model.setBounce(.initial) }
            }
        }
    }

    /// 滑杆行：标签居左，滑杆 + 数值读数居右（数值用等宽数字，拖动时不抖）
    private func sliderRow(_ title: String,
                           _ keyPath: WritableKeyPath<MenuBarBounceSettings, Double>,
                           _ range: ClosedRange<Double>,
                           _ step: Double,
                           _ format: String) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: snapped(binding(keyPath), in: range, step: step), in: range)
                    .frame(width: 190)
                Text(String(format: format, model.snapshot.bounce[keyPath: keyPath]))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<MenuBarBounceSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.snapshot.bounce[keyPath: keyPath] },
            set: { value in
                var next = model.snapshot.bounce
                next[keyPath: keyPath] = value
                model.setBounce(next)
            })
    }
}

/// 小球弹跳预览：直接调 `MenuBarBounceSettings.solve(at:)`（与宿主同一套解算），
/// 样式（本体常亮 + 高斯模糊光晕 + 余弦呼吸）走 `MenuBarStatusDotStyle` 同一规格，
/// 全部 pt 量纲按 `scale` 等比放大 —— 菜单栏那枚点直径仅 ~5pt，1:1 根本看不出形变。
/// `TimelineView(.animation)` 每帧重画即可：这里是普通窗口，不走菜单栏多屏镜像，
/// 不必受「只能写模型值」那条约束（见 MenuBarGlow 的 breathStep 注释）。
private struct BouncePreview: View {
    let settings: MenuBarBounceSettings

    private static let scale: Double = 4          // 预览放大倍数（所有 pt 量纲同乘，观感与实物等比）
    private static let dotDiameter: Double = 5    // 与 MenuBarStatusGlowController 的圆点口径一致
    /// 光晕位图：与宿主同一烘焙管线（剪影 → 高斯模糊 → alpha 增益），按放大倍数烘；
    /// 参数只随倍数变，进程内烘一次复用（Canvas 每帧重画不能现烤）
    private static let glowImage = MenuBarStatusDotStyle.glowBitmap(
        color: MenuBarStatusDotStyle.runningColor,
        dotDiameter: dotDiameter * scale, visualScale: scale)
    private static let dotColor = Color(nsColor: MenuBarStatusDotStyle.runningColor)
    private static let dotOpacity = Double(MenuBarStatusDotStyle.dotOpacity)

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { gc, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let b = settings.solve(at: t)
                let d = Self.dotDiameter * Self.scale
                let w = d * b.sx
                let h = d * b.sy
                let cx = size.width / 2
                let groundY = size.height - 22
                // 静止位底缘抬升 dy（与宿主同口径：底缘为形变支点，压扁贴地、拉伸向上长）
                let baseBottomY = groundY - b.dy * Self.scale
                let baseCenterY = baseBottomY - d / 2

                gc.stroke(Path { p in
                    p.move(to: CGPoint(x: 16, y: groundY))
                    p.addLine(to: CGPoint(x: size.width - 16, y: groundY))
                }, with: .color(.secondary.opacity(0.22)), lineWidth: 0.5)

                // 光晕：宿主同款烘焙位图（柔和高斯晕，非实心圆），呼吸同公式同参数；
                // 尺寸恒定、只跟随位移（与宿主 updateBounce 同口径）
                if let cg = Self.glowImage {
                    gc.opacity = MenuBarStatusDotStyle.breathOpacity(at: t)
                    gc.draw(gc.resolve(Image(decorative: cg, scale: MenuBarStatusDotStyle.bitmapScale)),
                            at: CGPoint(x: cx, y: baseCenterY))
                    gc.opacity = 1
                }

                // 本体：常亮透明度（与宿主 dotOpacity 同源）、底缘支点形变
                gc.fill(Path(ellipseIn: CGRect(x: cx - w / 2, y: baseBottomY - h,
                                               width: w, height: h)),
                        with: .color(Self.dotColor.opacity(Self.dotOpacity)))
            }
        }
    }
}

// MARK: - 主题外观 pane（原面板右上角「主题调教」玻璃弹窗的 SwiftUI 原生版）

/// 点阵主题色 + 面板 / 卡片 / 侧栏玻璃外观。全部即时生效（不留「保存」按钮）——
/// 与「动画」「关于」等 pane 同口径：写入转交宿主动作（落盘 + 触发重绘）后
/// 由模型 `sync()` 回读真实配置，所以这里用闭包 Binding 而不是 keyPath。
private struct ThemePane: View {
    let model: AppSettingsModel

    var body: some View {
        Form {
            Section {
                sliderRow("色相", get: { model.snapshot.heatHue }, set: model.setHeatHue)
                sliderRow("饱和度", get: { model.snapshot.heatSaturation }, set: model.setHeatSaturation)
                sliderRow("亮度", get: { model.snapshot.heatBrightness }, set: model.setHeatBrightness)
            } header: {
                Text("主题色")
            } footer: {
                Text("点阵峰值配色（卡片边框同源）：色相转一圈，饱和度决定鲜艳程度，亮度决定明暗。")
            }
            Section {
                Toggle("高对比背景", isOn: toggle(\.panelGradientEnabled, model.setPanelGradient))
                Toggle("浅色主题", isOn: toggle(\.lightThemeEnabled, model.setLightTheme))
                Toggle("Mono 风格", isOn: toggle(\.monoFontEnabled, model.setMonoFont))
            } header: {
                Text("面板")
            } footer: {
                Text("「高对比背景」= 底色走明暗渐变；「浅色主题」= 强制浅色外观（忽略系统深色）。")
            }
            Section {
                Toggle("图标深浅互换", isOn: toggle(\.iconThemeSwap, model.setIconThemeSwap))
                Toggle("圆形图标", isOn: toggle(\.circularIcon, model.setCircularIcon))
                Toggle("长进度卡片", isOn: toggle(\.longProgressCard, model.setLongProgressCard))
                intSliderRow("主标题字号",
                             get: { model.snapshot.cardTitleFontSize },
                             set: model.setCardTitleFontSize,
                             in: 10...18, unit: "pt")
                Toggle("Sharp Grotesk 字体", isOn: toggle(\.cardTitleSharpGrotesk, model.setCardTitleSharpGrotesk))
                if model.snapshot.cardTitleSharpGrotesk {
                    Picker("字重", selection: intOption(\.cardTitleSGWeight, model.setCardTitleSGWeight)) {
                        Text("Thin").tag(0)
                        Text("Book").tag(1)
                        Text("Light").tag(2)
                        Text("Medium").tag(3)
                        Text("SemiBold").tag(4)
                        Text("Bold").tag(5)
                        Text("Black").tag(6)
                    }
                    Picker("宽度", selection: intOption(\.cardTitleSGWidth, model.setCardTitleSGWidth)) {
                        Text("05（窄）").tag(0)
                        Text("10").tag(1)
                        Text("15").tag(2)
                        Text("20").tag(3)
                        Text("25（宽）").tag(4)
                    }
                }
            } header: {
                Text("卡片")
            } footer: {
                Text("「主标题字号」= 余额卡平台名（数值字号不变）；「Sharp Grotesk 字体」用本机安装的 Sharp Grotesk（字重×宽度任选组合，未装该字重自动回落系统字体）。")
            }
            // 2026-09-12 由「设置」pane 迁入（用户要求：侧栏玻璃属外观，归主题外观）
            Section {
                sliderRow("透明度",
                          get: { model.snapshot.sidebarGlassTransparency },
                          set: model.setSidebarGlassTransparency)
            } header: {
                Text("侧栏玻璃")
            } footer: {
                Text("100% = 系统原生 Liquid Glass（随系统偏好自适应），越低越实。改动立即生效并落盘。")
            }
        }
    }

    /// 滑杆行：标签居左，滑杆 + 百分数读数居右（等宽数字，拖动时不抖）。
    /// get 直读模型快照（不回传渲染时的常量），拖动中滑杆位置与读数都不滞后。
    private func sliderRow(_ title: String, get: @escaping () -> Double,
                           set: @escaping (Double) -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: snapped(Binding(get: get, set: set), in: 0...1, step: 0.01), in: 0...1)
                    .frame(width: 190)
                // 读数与滑杆同源、VoiceOver 会重复播报 → 只当视觉辅助
                Text(get(), format: .percent.precision(.fractionLength(0)))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            Text(title)
        }
    }

    /// 即时生效开关：写入转交宿主动作（落盘 + 重绘 + 快照回读）
    private func toggle(_ keyPath: KeyPath<AppSettingsSnapshot, Bool>,
                        _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { model.snapshot[keyPath: keyPath] }, set: set)
    }

    /// Int 档位选项绑定（Sharp Grotesk 字重/宽度档）：同 toggle 的闭包 Binding 口径
    private func intOption(_ keyPath: KeyPath<AppSettingsSnapshot, Int>,
                           _ set: @escaping (Int) -> Void) -> Binding<Int> {
        Binding(get: { model.snapshot[keyPath: keyPath] }, set: set)
    }

    /// 数值滑杆行：标签居左，滑杆 + 单位读数居右（等宽数字，拖动时不抖）。
    /// 与 sliderRow（0…1 百分比）同款布局，量纲开放为任意区间。
    private func intSliderRow(_ title: String, get: @escaping () -> Double,
                              set: @escaping (Double) -> Void,
                              in range: ClosedRange<Double>, unit: String) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: snapped(Binding(get: get, set: set), in: range, step: 1), in: range)
                    .frame(width: 150)
                Text("\(Int(get()))\(unit)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            Text(title)
        }
    }
}

/// 内嵌 AppKit 内容的 pane（3D 硬币 / 平台）：宿主注入的视图钉在滚动视口顶部
/// （`safeAreaInset` 不参与滚动，窗口再矮也恒可见），下方是页脚说明 + 可选动作按钮。
/// 内容由宿主装配（`AppSettingsModel.hostedPanes`）；未注入只可能是 Xcode 预览，
/// 此时回退成一行说明（无按钮 —— 这几个入口已经没有独立弹窗可开）。
private struct HostedPane: View {
    let model: AppSettingsModel
    let item: SettingsSidebarItem
    /// 未注入内容时的回退行（Xcode 预览用）
    let fallbackIcon: OperationRowIcon
    let fallbackTitle: String

    var body: some View {
        if let content = model.hostedPanes[item] {
            // 分区卡独立置顶：safeAreaInset 钉在滚动视口顶部（不参与滚动，窗口再矮
            // 也恒可见）；卡背景手绘（采样系统设置分区卡：暗 #2B2B2B / 亮 白），
            // 与 Form 分区卡同观感。下方提示行 + 保存按钮为可滚内容
            ScrollView {
                HStack(spacing: 12) {
                    Text(content.footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let actionTitle = content.actionTitle {
                        Button(actionTitle) { content.action?() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    // 分区标题（Form Section header 同位：分区卡外、左对齐；nil = 无标题）
                    if let header = content.header {
                        Text(header)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 7)
                    }
                    HostedContentView(make: content.view)
                        .frame(maxWidth: .infinity)
                        .frame(height: content.height)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(SectionCardColor.background)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, content.header == nil ? 8 : 0)
                        .padding(.bottom, 4)
                }
            }
            // ⚠️ 必须自己铺窗底：设置窗口为了侧栏玻璃是 isOpaque=false + backgroundColor=.clear，
            // 详情区的底色平时由 Form(.grouped) 自己铺 —— 本 pane 是裸 ScrollView，没有 Form，
            // 不铺底就会把窗口后面的东西（桌面/别的窗口）直接透出来，表现为「背景消失」。
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            Form {
                Section {
                    OperationRow(model: model, icon: fallbackIcon, title: fallbackTitle,
                                 subtitle: "内容由宿主装配，此处为预览占位", actionTitle: nil) {}
                }
            }
        }
    }
}

/// AppKit 视图嵌入桥：尺寸完全按 SwiftUI proposal 落（默认实现走 fittingSize，
/// 对手工 frame 布局的宿主面板不可靠）
private struct HostedContentView: NSViewRepresentable {
    let make: () -> NSView

    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width,
               height: proposal.height ?? nsView.fittingSize.height)
    }
}

/// 分区卡背景色（对齐 macOS 26 系统设置 grouped 分区卡，截图采样定值）：
/// 暗 = #2B2B2B（窗底 #222222 上浮一档），亮 = 白卡
private enum SectionCardColor {
    static var background: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDarkAppearance
                ? NSColor(red: 43 / 255.0, green: 43 / 255.0, blue: 43 / 255.0, alpha: 1)
                : .white
        })
    }
}

private extension NSAppearance {
    /// NSAppearance 无 isDark（App 侧 Palette 同款自建），库内独立实现
    var isDarkAppearance: Bool {
        switch bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) {
        case .darkAqua, .vibrantDark: true
        default: false
        }
    }
}

/// 系统设置同款「后退/前进」胶囊：官方 NSSegmentedControl（momentary）+
/// macOS 26 胶囊边框 API（面板 header 分段控件同款），经 NSViewRepresentable 嵌入；
/// 可用性来自 AppSettingsModel 的 pane 导航历史，无历史时按钮原生置灰
private struct BackForwardControl: NSViewRepresentable {
    var canBack: Bool
    var canForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBack: onBack, onForward: onForward)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let seg = NSSegmentedControl(
            images: [
                // SDK 保证存在的系统符号，强解包安全
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回上一页")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "前进下一页")!,
            ],
            trackingMode: .momentary,
            target: context.coordinator,
            action: #selector(Coordinator.clicked(_:)))
        seg.borderShape = .capsule
        seg.controlSize = .small
        seg.setWidth(28, forSegment: 0)
        seg.setWidth(28, forSegment: 1)
        seg.setToolTip("返回", forSegment: 0)
        seg.setToolTip("前进", forSegment: 1)
        return seg
    }

    func updateNSView(_ seg: NSSegmentedControl, context: Context) {
        context.coordinator.onBack = onBack
        context.coordinator.onForward = onForward
        seg.setEnabled(canBack, forSegment: 0)
        seg.setEnabled(canForward, forSegment: 1)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onBack: () -> Void
        var onForward: () -> Void

        init(onBack: @escaping () -> Void, onForward: @escaping () -> Void) {
            self.onBack = onBack
            self.onForward = onForward
        }

        @objc func clicked(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0: onBack()
            case 1: onForward()
            default: break
            }
        }
    }
}

/// 行首图标：symbol = SF Symbol；platform = 平台品牌 PNG（经宿主 iconProvider 解析，
/// 键与面板卡片图标名同源；未注入或缺图回退通用符号）
public enum OperationRowIcon {
    case symbol(String)
    case platform(String)
}

// MARK: - 共享小工具

/// 「有档位、无刻度」的滑杆绑定。
///
/// macOS 的 SwiftUI `Slider` 只要带了 `step:`，就会在滑轨下方画一排刻度线（`Slider(value:in:step:)`
/// 的副作用，官方没给关闭开关）。实测见离线探针 `/tmp/sliderprobe`：0...1 step:0.01 会比连续版
/// 多出 1298 个刻度像素、step:0.1 多 160 个（对照组同视图两次渲染差异为 0）。
/// 所以这里**去掉 `step:` 用连续滑杆，改在写入时把值吸附到档位** —— 档位语义不变、刻度消失。
/// 吸附栅格以 `range.lowerBound` 为原点（与 SwiftUI `step:` 同口径），并夹回区间内。
private func snapped(_ binding: Binding<Double>,
                     in range: ClosedRange<Double>,
                     step: Double) -> Binding<Double> {
    Binding(
        get: { binding.wrappedValue },
        set: { raw in
            let n = ((raw - range.lowerBound) / step).rounded()
            let value = min(max(range.lowerBound + n * step, range.lowerBound), range.upperBound)
            binding.wrappedValue = value
        })
}

/// 操作行：图标 + 标题/说明居左，动作按钮居右（系统设置行式排版）；
/// `subtitle` 为 nil / 空串时不占那一行（账号页四行 2026-09-12 按用户要求去掉小字）；
/// `actionTitle` 为 nil 时只显示说明不挂按钮（预览占位行用）
private struct OperationRow: View {
    let model: AppSettingsModel
    let icon: OperationRowIcon
    let title: String
    let subtitle: String?
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        // 不用 LabeledContent：它在 grouped Form 里按 firstTextBaseline 对齐内容列，
        // 两行 label 会把基线定在标题那行，动作按钮被顶到行上方。HStack 默认 .center 对齐。
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            if let actionTitle {
                Button(actionTitle) { action() }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .frame(width: 18)
                .foregroundStyle(.secondary)
        case .platform(let key):
            if let img = model.iconProvider?(key) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Xcode 预览（PreviewProvider 无宏依赖，CLT / Xcode 工具链均可编）；
/// 在 Xcode 中打开 swift/Package.swift，选中本文件即可预览。
private struct AppSettingsPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            AppSettingsView(model: .preview(selection: .checkin))
                .previewDisplayName("签到")
            AppSettingsView(model: .preview(selection: .accounts))
                .previewDisplayName("账号")
            AppSettingsView(model: .preview(selection: .keyQuota))
                .previewDisplayName("Key / 额度")
            AppSettingsView(model: .preview(selection: .appearance))
                .previewDisplayName("主题外观")
            AppSettingsView(model: .preview(selection: .animation))
                .previewDisplayName("动画")
        }
    }
}

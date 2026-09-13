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
        case .coinDemo: "3D 硬币"
        case .animation: "菜单栏"
        case .about: "关于"
        }
    }
    public var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .platforms: "circle.grid.2x2"
        case .accounts: "person.crop.circle.badge.plus"
        case .checkin: "checkmark.seal"
        case .coinDemo: "rotate.3d"
        // 菜单栏（原 `circle.dotted`，2026-09-13 用户「icon 换掉」）：换成系统那张菜单栏示意图，
        // 与 pane 名「菜单栏」同义
        case .animation: "menubar.rectangle"
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
            // 侧栏宽度**固定 180pt、不可拖动**（2026-09-13 用户要求；原为 min 180 / ideal 200 / max 240）。
            // min = ideal = max 就是锁死：离线取证（/tmp/layoutprobe/sidebar.swift）实测这一条声明式
            // 会把 `NSSplitViewItem.minimumThickness/maximumThickness` 都置成 180，此后强行
            // `setPosition(300)`、`setPosition(120)`、窗口拉宽到 900，侧栏宽度恒为 180。
            // ⚠️ SwiftUI 会重配 split item（见宿主 `pinSidebarItem` 里 canCollapse 被反复打回的现象），
            // 所以宿主侧还在每次变 key / 每帧 resize 时再钉一遍，两处一起才稳
            .navigationSplitViewColumnWidth(min: SettingsWindowMetrics.sidebarWidth,
                                            ideal: SettingsWindowMetrics.sidebarWidth,
                                            max: SettingsWindowMetrics.sidebarWidth)
        } detail: {
            // pane 直接 switch（不再套一层 Group：`detail:` 本身就是 ViewBuilder）
            Group {
                switch model.selection {
                case .appearance: ThemePane(model: model)
                case .platforms:
                    HostedPane(model: model, item: .platforms,
                               fallbackIcon: .symbol("circle.grid.2x2"), fallbackTitle: "平台开关")
                case .accounts: AccountsPane(model: model)
                case .checkin: CheckinPane(model: model)
                case .coinDemo:
                    HostedPane(model: model, item: .coinDemo,
                               fallbackIcon: .symbol("rotate.3d"), fallbackTitle: "3D 硬币")
                case .animation: AnimationPane(model: model)
                case .about: AboutPane(model: model)
                }
            }
            // 首个 Section 标题与侧栏首行同高（2026-09-13 用户要求）：grouped Form 的
            // 顶部自带留白比侧栏 List 多 ~13pt，负 contentMargins 只收详情列这一段
            //（侧栏列不受影响）；只作用滚动内容， pane 想再微调改这一个数
            .contentMargins(.top, -13, for: .scrollContent)
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

// MARK: - 账号 pane（原「操作→账号」栏目；2026-09-13 并入原「Key / 额度」pane）

/// Key/额度草稿提交时机不变（回车 / 离开本 pane / 关窗，见模型 `commitKeyQuotaIfDirty`）。
private struct AccountsPane: View {
    // 官方口径：需要给注入的 @Observable 属性生成 Binding 时用 @Bindable（属性包装器形态），
    // 直接 `$model.keyQuotaDraft.apiKey`；不必再手写 Binding(get:set:) 桥。
    @Bindable var model: AppSettingsModel

    var body: some View {
        Form {
            // 2026-09-13 用户要求：「WB 同步」移到页面第一栏并加标题
            //（原独立「WB 同步」pane 并入本页时无标题，挂在页面中部）
            Section {
                OperationRow(model: model, icon: .symbol("square.and.arrow.up.on.square"), title: "WB 同步",
                             subtitle: "全部历史会话与记忆同步给当前登录的 WorkBuddy 账号",
                             actionTitle: "同步") { model.actions.shareWbHistory() }
            } header: {
                Text("同步")
            }
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
            } header: {
                Text("添加账号")
            }
            // 「已保存账号」（2026-09-13 用户要求）：逐平台列出已保存账号，行内「删除」移除单个账号。
            // 删除转交宿主（二次确认 + 落盘 + 面板/菜单栏刷新），model.deleteAccount 里的 sync() 回读刷新本列表；
            // 空平台不出现，全空时整段不渲染（下方「删除账号」行的副标题会说明当前没有凭据）
            ForEach(model.snapshot.savedAccountGroups) { group in
                Section {
                    ForEach(group.accounts) { acc in
                        OperationRow(model: model, icon: .platform(group.iconKey),
                                     title: acc.name, subtitle: acc.detail,
                                     actionTitle: "删除", destructive: true) {
                            model.deleteAccount(platform: group.id, uid: acc.id)
                        }
                    }
                } header: {
                    Text(group.platform)
                }
            }
            // 2026-09-13 由独立「Key / 额度」pane 并入（原 KeyQuotaPane struct 删除）
            Section {
                // API Key 用 SecureField（2026-09-13 用户「换成密码字符」）：显示圆点不落明文
                SecureField("API Key", text: $model.keyQuotaDraft.apiKey, prompt: Text("sk-…"))
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
            // 2026-09-13 用户要求：底部加「删除账号」——清空已保存的各平台凭据。
            // 破坏性操作：按钮染红 + 置灰（没东西可删时）；二次确认与结果提示都在宿主（见 onDeleteAllAccounts）
            Section {
                OperationRow(model: model, icon: .symbol("trash"), title: "删除账号",
                             subtitle: savedCredentialSummary,
                             actionTitle: "删除",
                             destructive: true,
                             enabled: model.snapshot.savedAccountCount
                                 + model.snapshot.savedOverrideCount > 0) {
                    model.actions.deleteAllAccounts()
                }
            } footer: {
                Text("清除已保存的全部平台凭据：WorkBuddy / TRAE / ZCode / Codex 账号，以及 DeepSeek Key、ZhiPu Token、Qwen Ticket 手填覆盖。\n只删 iBalance 里存的这份，不会退出各平台本机的登录状态。")
            }
        }
    }

    /// 「删除账号」行的副标题：已保存的账号数 + 手填凭据数（都没存时说清楚，免得以为按钮坏了）
    private var savedCredentialSummary: String {
        let accounts = model.snapshot.savedAccountCount
        let overrides = model.snapshot.savedOverrideCount
        var parts: [String] = []
        if accounts > 0 { parts.append("\(accounts) 个账号") }
        if overrides > 0 { parts.append("\(overrides) 项 Key / Token") }
        return parts.isEmpty ? "当前没有已保存的凭据" : "已保存 " + parts.joined(separator: " · ")
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
            } header: {
                Text("手动签到")
            }
            Section {
                // 今日签到结果并入开关行小字（2026-09-13 用户要求：不再单占一行）
                Toggle(isOn: autoCheckinBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动签到")
                        if !model.snapshot.autoCheckinSub.isEmpty {
                            Text(model.snapshot.autoCheckinSub)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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
            } header: {
                Text("应用信息")
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

// MARK: - 菜单栏 pane（菜单栏「进行中」蓝点的小球弹跳参数；侧栏项原叫「动画」，2026-09-13 定名「菜单栏」）

/// 菜单栏状态点弹跳参数：顶部实时预览 + 五项滑杆。改动即时生效并落盘
/// （与「设置」pane 的刷新间隔同口径：不留「保存」按钮）。
/// 2026-09-13 用户要求：侧栏项「动画」→「菜单栏」（图标一并换成 `menubar.rectangle`）、
/// 预览段标题「预览」→「进行中状态动画」、并去掉下方「恢复默认」按钮及其整张 Section 卡。
private struct AnimationPane: View {
    let model: AppSettingsModel

    var body: some View {
        Form {
            Section {
                BouncePreview(settings: model.snapshot.bounce)
                    .frame(height: 92)
            } header: {
                Text("进行中状态动画")
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

/// 点阵主题色 + 面板 / 卡片外观。全部即时生效（不留「保存」按钮）——
/// 与「菜单栏」「关于」等 pane 同口径：写入转交宿主动作（落盘 + 触发重绘）后
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
                // 标题右侧实时色样（2026-09-13 用户要求）：由三根滑杆当前值合成；
                // 滑杆写入都经 sync() 回读快照，拖动中色样同步变色。描边兜底近黑/近白主题色在卡底上的可辨性
                HStack(spacing: 6) {
                    Text("主题色")
                    Circle()
                        .fill(Color(nsColor: NSColor(hue: model.snapshot.heatHue,
                                                     saturation: model.snapshot.heatSaturation,
                                                     brightness: model.snapshot.heatBrightness,
                                                     alpha: 1)))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                }
            } footer: {
                Text("点阵峰值配色（卡片边框同源）：色相转一圈，饱和度决定鲜艳程度，亮度决定明暗。")
            }
            Section {
                // 强度滑杆（0…100%，与下方主题色滑杆同款）：拖动实时回读快照即时生效
                sliderRow("高对比背景",
                          get: { model.snapshot.panelMaskOpacity },
                          set: model.setPanelMaskOpacity)
                Toggle("浅色主题", isOn: toggle(\.lightThemeEnabled, model.setLightTheme))
            } header: {
                Text("面板")
            } footer: {
                Text("「高对比背景」= 底色明暗遮罩强度，0% = 原生玻璃；「浅色主题」= 强制浅色外观（忽略系统深色）。")
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

/// 非首段标题的**上移量**（pt）。macOS grouped Form 会在每段标题上方留一大截（实测 76pt 段间距，
/// 其中标题上方 ~35pt），比系统设置松得多 —— 用户 2026-09-13 看着 3D 硬币那几段说「去掉多余的间隔」。
/// 离线取证 `/tmp/layoutprobe/gapprobe.swift`：段间距 76pt，标题加 `.padding(.top, -20)` 后 → **60pt**，
/// 再往下加（-28 / -36）不再变 —— 60pt 是这套布局能压到的下限，所以取 -20。
///
/// ⚠️ 只压**每块 Form 里的非首段**：负边距会把该段整体往上顶，而首段头顶就是滚动视口的边缘
/// —— 顶上去会被裁掉／被上一块 Form（钉住的预览框）盖住（用户 2026-09-13 第二轮：
/// 「最顶部的间距要加上，不然标题被预览框遮挡」）。所以首段标题一律不动。
private let sectionHeaderPull: CGFloat = 20

/// 内嵌 AppKit 内容的 pane（3D 硬币 / 平台）：宿主注入的视图按**段**铺在滚动视口里，
/// 一段 = 一个 Form Section（各画各的卡片，标题 / 脚注 / 卡底全由 Form 原生绘制）。
/// 段数由宿主装配（`AppSettingsModel.hostedPanes`）——「3D 硬币」给四段，
/// 于是「3D 预览框」与下方「表单框」是分开的卡，前者不包裹后者（2026-09-13 用户要求）。
/// 标了 `pinned` 的段（3D 硬币的「标题 + 预览框」）另走一块**只吃自身内容高度**的 Form，
/// 钉在页面顶部不参与滚动（同日用户要求）。
/// 未注入只可能是 Xcode 预览，此时回退成一行说明（无按钮 —— 这几个入口已经没有独立弹窗可开）。
private struct HostedPane: View {
    let model: AppSettingsModel
    let item: SettingsSidebarItem
    /// 未注入内容时的回退行（Xcode 预览用）
    let fallbackIcon: OperationRowIcon
    let fallbackTitle: String

    var body: some View {
        if let sections = model.hostedPanes[item], !sections.isEmpty {
            // 钉住的段与滚动的段各用一块 Form：两块叠在 VStack 里，
            // 上面那块 `fixedSize(vertical:)` 只吃自身内容高度（离线取证 /tmp/layoutprobe/pinned.swift：
            // 声明 120pt 行 → 该 Form 实测高 245pt，正好是「标题 + 卡片 + 段尾留白」，且不滚动），
            // 下面那块吃满剩余空间并滚动。两块的卡片都由 Form 原生绘制，观感一致
            let pinned = sections.filter { $0.pinned }
            let scrolling = sections.filter { !$0.pinned }
            VStack(spacing: 0) {
                if !pinned.isEmpty {
                    sectionsForm(pinned)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !scrolling.isEmpty {
                    sectionsForm(scrolling)
                }
            }
        } else {
            Form {
                Section {
                    OperationRow(model: model, icon: fallbackIcon, title: fallbackTitle,
                                 subtitle: "内容由宿主装配，此处为预览占位", actionTitle: nil) {}
                }
            }
        }
    }

    /// 一组段 → 一块 Form（每段一个原生 Section）。与普通 pane 同构：标题/脚注/分区卡全部由
    /// Form 原生绘制，位置、字号、卡底与所有 Form 页完全一致（此前 hosted 页手绘钉顶标题与之不齐，
    /// 2026-09-13 用户要求统一）。行内边距清零让宿主视图铺满卡内；内容超高时 Form 整页自然滚动。
    /// **首段标题不动**（每块 Form 各自算）：负边距会把首段往上顶出滚动视口被裁／被上面那块
    /// 钉住的 Form 盖住，见 `sectionHeaderPull` 注释
    private func sectionsForm(_ sections: [SettingsHostedContent]) -> some View {
        Form {
            ForEach(sections.indices, id: \.self) { index in
                let content = sections[index]
                Section {
                    let hosted = HostedContentView(make: content.view)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                    if let height = content.height {
                        hosted.frame(height: height)
                    } else {
                        hosted   // 高度随内容：视图 fittingSize 决定（3D 硬币自然高）
                    }
                } header: {
                    if let header = content.header {
                        if index > 0 {
                            Text(header).padding(.top, -sectionHeaderPull)
                        } else {
                            Text(header)
                        }
                    }
                } footer: {
                    // 空脚注且无按钮 = 不画页脚（分段内嵌时「预览框」那一段就没有脚注）
                    if !content.footnote.isEmpty || content.actionTitle != nil {
                        HStack(spacing: 12) {
                            Text(content.footnote)
                            Spacer()
                            if let actionTitle = content.actionTitle {
                                Button(actionTitle) { content.action?() }
                            }
                        }
                    }
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
    /// 破坏性动作（「删除账号」）：按钮走 destructive 语义 + 显式染红
    var destructive = false
    /// 动作按钮是否可用（如「删除账号」在没有任何已保存凭据时置灰）
    var enabled = true
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
                // macOS 的 push button 文本色由样式主导，role 有时压不住，所以破坏性动作再显式染一层红
                Button(role: destructive ? .destructive : nil) { action() } label: {
                    if destructive {
                        Text(actionTitle).foregroundStyle(Color.red)
                    } else {
                        Text(actionTitle)
                    }
                }
                .disabled(!enabled)
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
            AppSettingsView(model: .preview(selection: .appearance))
                .previewDisplayName("主题外观")
            AppSettingsView(model: .preview(selection: .animation))
                .previewDisplayName("状态栏")
        }
    }
}

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
        // 平台开关（2026-09-16 用户定稿）：`circle.grid.2x2.topleft.checkmark.filled`
        // —— 多平台网格 + 左上角勾选，既表达「多个平台」也表达「开关勾选」。
        // 历史：初版 `circle.grid.2x2`（只有网格，无勾选语义）→ 中途试过 `checkmark.square`（被否）
        case .platforms: "circle.grid.2x2.topleft.checkmark.filled"
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
                               fallbackIcon: .symbol("circle.grid.2x2.topleft.checkmark.filled"),
                               fallbackTitle: "平台开关")
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
            // 空平台不出现，全空时整段不渲染
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
            Section {
                OperationRow(model: model, icon: .symbol("square.and.arrow.up"), title: "导出配置",
                             subtitle: "全部设置与账号凭据打包为 JSON 文件", actionTitle: "导出") {
                    model.actions.exportBackup()
                }
                OperationRow(model: model, icon: .symbol("square.and.arrow.down"), title: "导入配置",
                             subtitle: "从备份文件恢复，导入后自动重启", actionTitle: "导入") {
                    model.actions.importBackup()
                }
            } header: {
                Text("备份")
            } footer: {
                Text("导出文件含明文凭据，请妥善保管。")
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

/// 主题预设 + 用量色 + 面板 / 卡片外观。
/// 除顶部「主题预设」的「保存」按钮外全部即时生效 ——
/// 与「菜单栏」「关于」等 pane 同口径：写入转交宿主动作（落盘 + 触发重绘）后
/// 由模型 `sync()` 回读真实配置，所以这里用闭包 Binding 而不是 keyPath。
private struct ThemePane: View {
    /// 顶部「预设名称」输入框要写回模型草稿 → 需要 `$model.xxx` 取 Binding
    ///（`@Bindable` 是属性包装器，不是宏，本 target 可用；见文件头注）
    @Bindable var model: AppSettingsModel
    // ⚠️ 本 pane **不读 `@Environment(\.colorScheme)`**：图卡的深浅档只由预设自己的
    // 「浅色主题」开关决定（见 `presetThumb`），窗口/系统深浅不许漏进图卡。

    init(model: AppSettingsModel) {
        self.model = model
    }

    var body: some View {
        Form {
            // ── 「主题预设」（2026-09-15 用户要求：本页最上方）──
            // 「保存」= 把本页**当前全部参数**固化成一枚预设（快照里该页那几项，见
            // ThemePreset(name:snapshot:)）；每枚预设是一张**迷你面板**图卡（见 `presetThumb`，
            // 2026-09-16 用户要求：预设不再是一行文字摘要，改成把该组参数画出来）。
            // 预设列表存宿主 UserDefaults（ThemePresetStore），窗口每次打开由 sync() 回读
            Section {
                presetSaveRow
                if model.snapshot.themePresets.isEmpty {
                    Text("还没有预设。把下面的参数调成想要的样子，点「保存」固化一组。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    presetGrid
                }
            } header: {
                Text("主题预设")
            } footer: {
                Text("「保存」把本页当前全部参数（用量色 / 面板背景色 + 顶端不透明度 / 次背景色 / 底端不透明度 / 浅色主题 / 图标深浅互换 / 无边框图标 / 长进度卡片 / 主标题字号 / Sharp Grotesk 字体）连同 3D 硬币的视觉身份（Preset / Style 两档 + 币面色 + 色场色）固化成一组，名字与已有预设重复时会先问是否覆盖；每张图卡就是该组参数的**可视预览**（底色遮罩两端不透明度 / 次背景色 / 用量色 / 主标题字号与字体 / 硬币视觉身份都画在上面），**点图卡即应用**、逐项原样写回（不做任何派生翻转），随时可切回来，蓝框那枚就是当前生效的一组。硬币的尺寸 / 厚度 / 边纹 / 姿态 / 自旋与上传的 logo 不属于主题，不随预设走。")
            }
            Section {
                // 用量色（原「主题色」，2026-09-15 用户改名 —— 它只管用量类可视化那一支色阶，
                // 与同组的「面板背景色 / 次背景色」不是一类，叫「主题色」会让人以为动它改整面板外观）。
                // 2026-09-14 用户要求：原色相/饱和度/亮度三根滑杆 + 标题色样一起撤掉，
                // 收成「面板」组里的一行系统色盘）——
                // 拾色后由模型分解回 HSB 三参落值（下游点阵档位/卡片边框仍读 HSB，口径不变）；
                // 用量色不含透明语义，故不透出不透明度滑杆
                LabeledContent {
                    ColorPicker("用量色", selection: themeColor, supportsOpacity: false)
                        .labelsHidden()
                } label: {
                    Text("用量色")
                }
                // 面板底色（2026-09-14 用户要求：原「高对比背景」强度滑杆改制）——
                // 行尾色块即系统色盘入口，点击弹出系统颜色面板（含「不透明度」滑杆，
                // 即原「强度」语义）；拾色即时落盘重绘，不留「保存」按钮
                LabeledContent {
                    ColorPicker("面板背景色", selection: backgroundColor, supportsOpacity: true)
                        .labelsHidden()
                } label: {
                    Text("面板背景色")
                }
                // 次背景色（2026-09-15 用户要求：把原「点阵背景色」+「hover 背景色」两个参数
                // **合并**成这一个，改名「次背景色」，并归到本「面板」栏）——
                // 覆盖面板内第二层背景：无用量底点 / 进度条轨道底 / 骨架行 / Token 印章底 /
                // 卡片 hover 材质块全部同源，带不透明度
                LabeledContent {
                    ColorPicker("次背景色", selection: secondaryBackgroundColor, supportsOpacity: true)
                        .labelsHidden()
                } label: {
                    Text("次背景色")
                }
                // 遮罩上下两端的不透明度（2026-09-14 用户要求：删掉原「底端 = alpha × 0.65」的自动递减，
                // 两端各给一个滑杆）。顶部滑杆与色盘的不透明度是同一字段的两个入口
                percentSliderRow("顶部不透明度",
                                 get: { model.snapshot.panelBackgroundColor.alpha },
                                 set: { model.setPanelBackgroundColor(
                                     model.snapshot.panelBackgroundColor.withAlpha($0)) })
                percentSliderRow("底部不透明度",
                                 get: { model.snapshot.panelBackgroundBottomAlpha },
                                 set: model.setPanelBackgroundBottomAlpha)
                Toggle("浅色主题", isOn: toggle(\.lightThemeEnabled, model.setLightTheme))
            } header: {
                Text("面板")
            } footer: {
                Text("「用量色」= 用量强弱的色阶基色（原「主题色」，2026-09-15 改名）——卡片竖向点阵 / 长进度卡片进度条 / Token 热力图 / 卡片边框都从它派生出各档；「面板背景色」= 面板底色遮罩（色盘给颜色，其不透明度即顶端值）；「次背景色」= 面板内第二层背景（无用量底点 / 进度条轨道底 / 骨架行 / Token 印章底 / 卡片 hover 材质块同源，2026-09-15 由原「点阵背景色」与「hover 背景色」合并）；「顶部/底部不透明度」= 遮罩纵向两端各管一档，两者相同即纯色、0% 露原生玻璃；「浅色主题」= 强制浅色外观，打开时仅在底色明度 ≤ 50% 时翻转其明度（已是亮底则保持）。")
            }
            Section {
                Toggle("图标深浅互换", isOn: toggle(\.iconThemeSwap, model.setIconThemeSwap))
                // 无边框图标（2026-09-15 用户要求）：卡片品牌 icon 直接用同名 SVG 原图
                Toggle("无边框图标", isOn: toggle(\.iconNoBorder, model.setIconNoBorder))
                Toggle("长进度卡片", isOn: toggle(\.longProgressCard, model.setLongProgressCard))
                // 主标题字号（2026-09-15 用户：区间收到 10…16、步进 0.5 —— 半档用于微调标题墨迹高，
                // 读数同档显示小数）
                ptSliderRow("主标题字号",
                            get: { model.snapshot.cardTitleFontSize },
                            set: model.setCardTitleFontSize,
                            in: 10...16, step: 0.5)
                Toggle("Sharp Grotesk 字体", isOn: toggle(\.cardTitleSharpGrotesk, model.setCardTitleSharpGrotesk))
                // 主副标题行距系数（系统字体 / SG 两档）2026-09-15 用户「固化这两个参数，
                // 然后在 forms 里隐藏调教」：两根滑杆与对应 config 键 / 宿主 setter 一并移除，
                // 定稿值 SF ×0.30 / SG ×0.90（= 移除当刻的读数）写在
                // BalancePanelView.cardTitleGapScaleSFFixed / SGFixed，此处不再暴露调节。
                // 「hover 背景色」同日并入「面板 → 次背景色」，本组不再单列
            } header: {
                Text("卡片")
            } footer: {
                Text("「主标题字号」= 余额卡平台名（数值字号不变）；「Sharp Grotesk 字体」用本机安装版本（固定 Book20），开启后面板内全部文字（卡片 / 用量表 / Token 板块 / 悬浮子面板）统一换用它，中文自动兜底苹方，未安装该字体时回落系统字体。主副标题行距系数已固化（系统字体 ×0.30 / SG ×0.90），不再开放调节。「hover 背景色」已并入「面板 → 次背景色」。")
            }
            // ── 动效（2026-09-16 用户要求：位数变化时整组左右平移的时长口径两种都落地）──
            // 原先平移时长恒等于滚动预算 1.2s、与位移量无关 —— 位数增减时明显拖在滚字后面
            Section {
                // 动效曲线（2026-09-16 用户要求开放为设置项）：原先硬写死 ease-in cubic。
                // 三档并排可比，故走 segmented（滑移时长只有两档且文案长，走 radioGroup）
                Picker("动效曲线", selection: rollCurve) {
                    ForEach(RollCurveOption.allCases) { opt in
                        Text(opt.title).tag(opt.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("滑移时长", selection: rollSlideTiming) {
                    ForEach(RollSlideTimingOption.allCases) { opt in
                        Text(opt.title).tag(opt.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("动效")
            } footer: {
                Text("「动效曲线」= 数值滚动的时间曲线（车轮位置 / 槽宽 / 位数变化平移三条量共用同一条，改一处即整体变）：从慢到快 = 起滚慢、末段最快、落定干脆；从快到慢 = 起手快、收尾长；慢-快-慢 = 两端减速、中段最快。单位换值时字符的滚入 / 滚出仍是另一条 ease-out，不随此项变。\n「滑移时长」= 位数增减（如 999.9 → 1,000.1）时**整组数字左右平移**的时长。原先是固定 1.2s、与移动距离无关。「跟随滚字」= 取本轮数字滚动的实际落定时刻（下限 0.30s），平移与滚字同拍收尾；「跟随位移」= 按实际移动距离在 0.30–0.60s 之间取，挪得少就快、挪得多也封顶。仅影响 Token 总计大数字的周期 / 平台切换；余额卡位数变化仍直接落值。\n两项都是动效参数，不进「主题预设」。")
            }
        }
    }

    // MARK: 主题预设（顶部「保存」+ 逐枚「应用 / 删除」）

    /// 「保存」行：预设名称 + 保存按钮。按钮必须包在 HStack + Spacer 里才靠右 ——
    /// grouped Form 里的裸 `Button` 恒独占一行且左对齐（同「关于」pane 的两个动作按钮）
    private var presetSaveRow: some View {
        HStack(spacing: 10) {
            TextField("预设名称（可留空）", text: $model.themePresetName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Spacer(minLength: 8)
            Button("保存") { model.saveThemePreset() }
        }
    }

    /// 预设图卡网格（2026-09-16 用户要求：预设从「一行文字摘要」改成「一张迷你面板」；
    /// 同日「图卡太大」→ 收成**竖版长方形**）。
    /// 列宽自适应 108…132：默认 680pt 窗口（内容区 ~430）三列、每列 ≈132pt（缩略图 ≈124pt 宽），
    /// 最小窗口三列 ≈122pt。min 取 108 是为了锁住列数 —— 再小就凑出四列、卡片内那句主标题会挤
    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 132), spacing: 12)],
                  alignment: .leading, spacing: 16) {
            ForEach(model.snapshot.themePresets) { preset in
                presetCard(preset)
            }
        }
        .padding(.vertical, 8)
    }

    /// 单枚预设 = 迷你面板缩略图（**点它 = 应用**）+ 名字行（行尾垃圾桶 = 删除）。
    /// 命名与交互照 macOS 系统设置「外观」那套：图缩略图即选项、名字居中在图下、
    /// 当前生效那枚加一圈系统蓝描边（见 `presetThumb` 的 isActive）。
    /// ⚠️ 垃圾桶不能压在缩略图上做 overlay —— 外层是 Button，overlay 里再放 Button 命中判定不可靠；
    /// 放在名字行里，并用同宽占位保持名字居中。
    private func presetCard(_ preset: ThemePreset) -> some View {
        let isActive = preset.matches(model.snapshot)
        return VStack(spacing: 6) {
            Button { model.applyThemePreset(preset) } label: {
                presetThumb(preset, isActive: isActive)
            }
            .buttonStyle(.plain)
            .help("应用这组预设")
            HStack(spacing: 4) {
                Color.clear.frame(width: 16, height: 1)
                Text(preset.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                Button(role: .destructive) { model.deleteThemePreset(id: preset.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.borderless)
                .frame(width: 16)
                .help("删除这组预设")
            }
        }
    }

    /// 迷你面板缩略图（**竖版：约 124×152pt**，2026-09-16 用户「图卡太大 → 改竖版长方形」）：
    /// 把该组预设**看得见的参数**画成一张小面板，自外向内三层 ——
    /// ① 底色遮罩（**铺满整张图卡**：顶端 = `panelBackgroundColor.alpha`、底端 =
    ///    `panelBackgroundBottomAlpha` 的竖直渐变）。卡外**不加任何底**（2026-09-16 用户
    ///    「不要加这层东西 透明就行」）—— 遮罩 alpha < 1 处直接透出设置窗口自己的底，
    ///    所以图卡上那道渐变就是面板真实的「一端实、一端透」；
    /// ② 次背景色卡片（内含卡片 icon + 主标题：**字号 / Sharp Grotesk / 主前景色**都体现在这行字上，
    ///    主前景色按预设的「浅色主题」开关解档 —— 开 = 面板走浅色外观，字就是那档的深色）；
    /// ③ 用量色进度条（轨道仍是次背景色、填充读 `PanelHeatRamp` 与主面板同一条色阶，
    ///    「长进度卡片」开关改它的长度）；
    /// 卡片与进度条贴顶排，**底端居中**另落一枚硬币（见 `miniCoin`），中间那条带即底色遮罩本身。
    /// 高度写死、宽度吃列宽：列宽被网格钉在 108…132，所以恒为竖版长方形。
    /// 选中态 = 系统蓝描边（外扩 5pt、线宽 2.5 ⇒ 与面板留 2.5pt 缝；内容不重叠，
    /// 有无描边都不改缩略图尺寸 ⇒ 网格不跳）。
    private func presetThumb(_ preset: ThemePreset, isActive: Bool) -> some View {
        // 面板外观档：**只由预设自己的「浅色主题」开关决定**（开 = 浅色外观，关 = 深色外观）。
        // ⚠️ 2026-09-16 用户「主题预设的各种主题，需要对当前的深浅色设置做隔离」：
        // 原先写的是 `!lightThemeEnabled && colorScheme == .dark` —— 系统/窗口翻深浅、
        // 当前面板换主题，都会把**所有**图卡重画成另一副样子（连主前景色、图标档、
        // 进度条色阶方向都跟着翻），而图卡上写的参数一个都没变，读起来就是「设置的数字和
        // 图不符」。现在档位完全由预设自带的那一个布尔决定 ⇒ 图卡对当前环境**免疫**：
        // 只有改预设本身的参数才会变。（真实面板确实跟随系统外观，图卡必须挑一档 ——
        // 挑「关 = 深色」这一档，与用户日常看到的观感一致）
        let appearanceDark = !preset.lightThemeEnabled
        let fg = Color(nsColor: PanelForegroundColor.resolved(dark: appearanceDark))
        let bg = preset.panelBackgroundColor
        let maskTop = Color(nsColor: bg.nsColor)
        let maskBottom = Color(nsColor: bg.withAlpha(preset.panelBackgroundBottomAlpha).nsColor)
        let secondary = Color(nsColor: preset.secondaryBackgroundColor.nsColor)
        return ZStack {
            // 面板本体 = 底色遮罩，铺满整张图卡（外面那层「玻璃底」2026-09-16 用户要求删除）
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [maskTop, maskBottom],
                                     startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 9) {
                // 板块大标题（= 主面板每个板块头顶那行「API / Token / Usage / Agent」）：
                // 字号与卡片主标题**同一档**（板块标题跟随 `cardTitleFontSize`，这是预设里那个
                // 字号参数的四个消费点之一，图卡得把它们画出来）；
                // 色是主面板的副前景色 —— 图卡把它近似成主前景色压暗（真解算
                // `Palette.secondaryForeground` 按底色推对比度，在宿主 target，图卡拿不到）
                Text("API")
                    .font(Self.titleFont(preset))
                    .foregroundStyle(fg.opacity(0.62))
                    .lineLimit(1)
                // 余额卡（次背景色）：icon + **平台名**（主面板里那张卡的标题是平台名，
                // 板块大标题才是「API」；icon 用 DeepSeek 当例子，名字就对应用 DeepSeek）
                HStack(spacing: 6) {
                    miniCardIcon(preset, appearanceDark: appearanceDark)
                    Text("DeepSeek")
                        .font(Self.titleFont(preset))
                        .foregroundStyle(fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)   // 16pt + SG 时这名字最宽，别截断
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(secondary))
                // 进度条宽度要按可用宽算（长进度卡片 = 占满），只能借 GeometryReader
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(secondary)
                        Capsule()
                            .fill(LinearGradient(colors: Self.progressStops(preset, dark: appearanceDark),
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * (preset.longProgressCard ? 1 : 0.62))
                    }
                }
                .frame(height: 5)
                Spacer(minLength: 0)
            }
            // 左右内缩进 12 → 8（2026-09-16 用户「mini 面板的左右内缩进缩小」）：
            // 图卡是窄竖版，12pt 两边一挤版心只剩 ~98pt，卡片显得又瘦又空
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            // 硬币落底居中（竖版：上面卡片 + 进度条，中间留出底色遮罩那条带，底下一枚币）
            VStack {
                Spacer(minLength: 0)
                miniCoin(preset, box: 56)
            }
            .padding(.bottom, 10)
        }
        .frame(height: 152)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // 面板自身那道细描边跟着面板走（外圈透明后它就是图卡的边界）。
        // 色取**预设自己那档主前景色**（不是 `Color.primary`）—— 与面板同源，也不吃窗口深浅
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(fg.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 2.5, y: 1)
        // 选中框：外扩 5pt、线宽 2.5（`strokeBorder` 是内描 ⇒ 与面板之间留 **2.5pt**）。
        // 常量占位，有无描边都不改缩略图尺寸 ⇒ 网格不跳
        .padding(5)
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
    }

    /// 卡片品牌 icon 的示例（图卡统一用 **DeepSeek** 的图标当例子）：**两条来源跟预设走** ——
    /// - 「无边框图标」开 = 同名 **SVG 原图**（去 Icon Composer 底板），主机给 template 图，
    ///   这里按该档主前景色着色（与面板 `contentTintColor` 同一档：外观 ⊕ 图标深浅互换）；
    /// - 关 = Icon Composer **PNG**（自带底板，原色直画）。
    /// 深浅档 = 面板外观是否深色 **异或**「图标深浅互换」，与宿主 `brandIconDark` 同一条式子。
    /// 宿主没注入图标（预览环境）时回退成示意方块。
    @ViewBuilder
    private func miniCardIcon(_ preset: ThemePreset, appearanceDark: Bool) -> some View {
        let iconDark = appearanceDark != preset.iconThemeSwap
        let req = BrandIconRequest(key: "deepseek", dark: iconDark, borderless: preset.iconNoBorder)
        if let img = model.iconProvider?(req) {
            if preset.iconNoBorder {
                // template 图：着色取该档主前景色（`PanelForegroundColor` 与宿主同一解算体）。
                // ⚠️ 必须 `.resizable()` —— `Image(nsImage:)` 默认按图自身尺寸（24pt 基准框）绘制，
                // 只给 frame 不会缩，会盖住右边那句主标题
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Color(nsColor: PanelForegroundColor.resolved(dark: iconDark)))
                    .frame(width: 14, height: 14)
            } else {
                Image(nsImage: img).resizable().scaledToFit().frame(width: 14, height: 14)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.45))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(nsColor: PanelForegroundColor.resolved(dark: iconDark)))
                    .frame(width: 6, height: 6)
            }
            .frame(width: 14, height: 14)
        }
    }

    /// 硬币的**真实 3D 渲染**（宿主按视觉身份四项离屏出的那枚币，见 `CoinThumbnailRenderer`）：
    /// 几何 / 工艺 / 姿态都是用户自己在「3D 硬币」pane 里调的那一套，图卡只换币面色 / 色场色 /
    /// 两档视觉身份 —— 即「应用这组预设后面板里那枚币长什么样」。
    /// 宿主没注入（Xcode 预览）或渲染失败 → 回退成同色示意币（平面圆盘 + 色场光晕 + 线稿档）。
    @ViewBuilder
    private func miniCoin(_ preset: ThemePreset, box: CGFloat) -> some View {
        if let img = model.coinThumbnailProvider?(CoinVisualIdentity(preset), box) {
            // 图自然尺寸 = box（含投影轮廓），直接用其 pt 尺寸，不再缩放
            Image(nsImage: img)
        } else {
            Self.drawnCoin(preset, size: box * 0.78).frame(width: box, height: box)
        }
    }

    /// 示意币（**仅预览环境 / 渲染失败时的兜底**）：币面色圆盘 + 斜向高光 + 色场光晕 + 线稿档。
    /// 真机走的是上面那条 3D 渲染，这里只是让 SwiftUI 预览与失败路径有个像样的替身
    private static func drawnCoin(_ preset: ThemePreset, size: CGFloat) -> some View {
        let material = coinColor(preset.coinMaterialColor)
        let field = coinColor(preset.coinFieldColor)
        let outline = preset.coinAppearance != ThemePreset.defaultCoinAppearance
        let hasField = preset.coinPreset != ThemePreset.defaultCoinPreset
        return ZStack {
            if hasField {
                // endRadius = 半径 ⇒ 帧边缘处正好淡到 0，方形帧的四角看不出来（无硬边）
                Circle()
                    .fill(RadialGradient(colors: [field.opacity(0.75), field.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size / 2))
                    .frame(width: size * 1.9, height: size * 1.9)
            }
            if outline {
                Circle().strokeBorder(material, lineWidth: size * 0.07)
                    .frame(width: size, height: size)
                Circle().strokeBorder(material.opacity(0.5), lineWidth: 1)
                    .frame(width: size * 0.62, height: size * 0.62)
                RoundedRectangle(cornerRadius: size * 0.05).fill(material)
                    .frame(width: size * 0.34, height: size * 0.16)
            } else {
                Circle().fill(material).frame(width: size, height: size)
                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.04),
                                                  .black.opacity(0.30)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
                RoundedRectangle(cornerRadius: size * 0.05).fill(Color.black.opacity(0.24))
                    .frame(width: size * 0.36, height: size * 0.34)
            }
        }
        .frame(width: size, height: size)
    }

    /// 缩略图里那两句主标题的字体档（板块大标题 + 卡片标题共用）：主面板字号 **× 0.7** ——
    /// 图卡宽 ≈ 主面板的一半（122 vs 264），文字按比例缩才读得出「这是面板的缩影」；
    /// 原样 13.5pt 塞进 122pt 宽的卡里又大又挤。系数先试过 0.5（2026-09-16 用户「太小了 70%吧」）
    /// —— 0.7 比严格半比例大一档，是**可读性**换来的：13.5 → 9.45pt，档差（10/16pt → 7/11.2pt）更明显。
    /// SG 开关 → 本机 PostScript 名（未装自动回落系统字体），否则系统字体。
    /// ⚠️ 字体名是**字面量**（`PanelFont` 在宿主 target，本 target 引不到）；
    /// 宿主改了 `PanelFont.sgPostScriptName` 就得同步这里。
    /// ⚠️ **只缩字号**：icon 恒 14pt = 主面板图标列 27.75pt 的严格半比例，不跟这个系数走
    private static let thumbnailTypeScale: CGFloat = 0.7
    private static func titleFont(_ preset: ThemePreset) -> Font {
        let pt = CGFloat(preset.cardTitleFontSize) * thumbnailTypeScale
        return preset.cardTitleSharpGrotesk
            ? .custom("SharpGrotesk-Book20", size: pt)
            : .system(size: pt, weight: .medium)
    }

    /// 预设里的用量色**峰值** RGB（HSB → RGB，各 0…1）：解算体与面板点阵 / 本页色盘同一份
    private static func peakRGB(_ preset: ThemePreset) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        PanelThemeColor.rgb(hue: CGFloat(preset.heatHue),
                            saturation: CGFloat(preset.heatSaturation),
                            brightness: CGFloat(preset.heatBrightness))
    }

    /// 图卡进度条的渐变两端：**与主面板「长进度卡片」同一条色阶**（档位序列 + 压暗系数都读
    /// `PanelHeatRamp`）—— 深色 = 左暗端（峰值 ×0.62）→ 右峰值；浅色 = 左峰值 → 右最暗（×0.33）。
    /// ⚠️ 2026-09-16 用户「进度条的渐变颜色还是相反了」：原来是 `[峰值, 峰值@50%]`，
    /// 左强右弱（与面板反向），且右端靠 alpha 朝底色发灰 —— 浅底上那一端反而更亮。
    /// 压暗必须走「峰值 RGB × 系数」，不能叠透明度。
    private static func progressStops(_ preset: ThemePreset, dark: Bool) -> [Color] {
        let peak = peakRGB(preset)
        return PanelHeatRamp.progressLevels(dark: dark).map { level in
            let f = PanelHeatRamp.factor(level: level, dark: dark)
            return Color(nsColor: NSColor(calibratedRed: peak.red * f, green: peak.green * f,
                                          blue: peak.blue * f, alpha: 1))
        }
    }

    /// 预设里的硬币颜色串（`#RRGGBB`，宿主 `CoinRGB` 的落串）→ Color。
    /// 复用 `PanelBackgroundColor(hex:)` 的解析（同一套十六进制口径，6 位按不透明处理），
    /// 解析失败按 sGHO 的币面色兜底 —— 宿主写进预设的一定是合法 hex，走到这一步只可能是手改坏了预设 JSON
    private static func coinColor(_ hex: String) -> Color {
        let fallback = PanelBackgroundColor(hue: 0.33, saturation: 1, brightness: 0.86, alpha: 1)
        return (PanelBackgroundColor(hex: hex) ?? fallback).swiftUIColor
    }

    /// 用量色绑定：读 = 快照 HSB 三参经 `PanelThemeColor.rgb` 合成（与面板点阵同一解算，
    /// 色块所见即面板所得；色盘轮盘/明度也随之定位）；
    /// 写 = 色盘给的颜色分解回 HSB —— 先归一到 sRGB 再读分量，
    /// ⚠️ `hueComponent` 只对 RGB 空间有效（灰度 / 设备空间直接读会抛异常），
    /// 归一失败（色盘给了 pattern 类颜色，正常路径不会发生）就丢弃这次写入
    private var themeColor: Binding<Color> {
        Binding(get: {
            let c = PanelThemeColor.rgb(hue: CGFloat(model.snapshot.heatHue),
                                        saturation: CGFloat(model.snapshot.heatSaturation),
                                        brightness: CGFloat(model.snapshot.heatBrightness))
            // 与 Palette 同装法（calibratedRed）：色块与点阵落在同一色彩空间，屏幕呈现一致
            return Color(nsColor: NSColor(calibratedRed: c.red, green: c.green, blue: c.blue, alpha: 1))
        }, set: { picked in
            guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
            model.setThemeColor(hue: Double(rgb.hueComponent),
                                saturation: Double(rgb.saturationComponent),
                                brightness: Double(rgb.brightnessComponent))
        })
    }

    /// 即时生效开关：写入转交宿主动作（落盘 + 重绘 + 快照回读）
    private func toggle(_ keyPath: KeyPath<AppSettingsSnapshot, Bool>,
                        _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { model.snapshot[keyPath: keyPath] }, set: set)
    }

    /// 面板底色绑定：快照（真实配置）读写，写入转交宿主动作后由 `sync()` 回读；
    /// 色盘给的 alpha 一并带上（`supportsOpacity: true`，即原「高对比背景」强度）
    private var backgroundColor: Binding<Color> {
        Binding(get: { model.snapshot.panelBackgroundColor.swiftUIColor },
                set: { model.setPanelBackgroundColor(PanelBackgroundColor(swiftUIColor: $0)) })
    }

    /// 次背景色绑定（2026-09-15 由「点阵背景色」+「hover 背景色」合并）：
    /// 同底色口径 —— 快照读写 + 宿主落盘后回读
    private var secondaryBackgroundColor: Binding<Color> {
        Binding(get: { model.snapshot.secondaryBackgroundColor.swiftUIColor },
                set: { model.setSecondaryBackgroundColor(PanelBackgroundColor(swiftUIColor: $0)) })
    }

    /// 数值滚动滑移时长口径绑定（单选，跨 target 传 rawValue 字符串）：
    /// 快照读写，写入转交宿主动作（落盘 + 同步 RollingNumberView 静态镜像）后回读
    private var rollSlideTiming: Binding<String> {
        Binding(get: { model.snapshot.rollSlideTiming },
                set: { model.setRollSlideTiming($0) })
    }

    /// 数值滚动时间曲线档位绑定（同滑移时长口径：rawValue 字符串跨 target）
    private var rollCurve: Binding<String> {
        Binding(get: { model.snapshot.rollCurve },
                set: { model.setRollCurve($0) })
    }

    /// 字号滑杆行（pt，步进 0.5）：布局同其他滑杆行，读数为整数不补小数、
    /// 半档才显示一位（16pt / 13.5pt）—— 2026-09-15 用户要求主标题字号收到 10…16、步进 0.5
    private func ptSliderRow(_ title: String, get: @escaping () -> Double,
                             set: @escaping (Double) -> Void,
                             in range: ClosedRange<Double>, step: Double) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: snapped(Binding(get: get, set: set), in: range, step: step), in: range)
                    .frame(width: 150)
                Text(Self.ptText(get()))
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

    /// 字号读数：整数省掉小数位（与常见「16pt」写法一致），半档保留一位
    private static func ptText(_ v: Double) -> String {
        let rounded = (v * 2).rounded() / 2
        return abs(rounded - rounded.rounded()) < 0.01
            ? "\(Int(rounded.rounded()))pt"
            : String(format: "%.1fpt", rounded)
    }

    /// 百分比滑杆行（0…1 量纲，读数取整为 "NN%"）：遮罩上下端不透明度等
    private func percentSliderRow(_ title: String, get: @escaping () -> Double,
                                  set: @escaping (Double) -> Void,
                                  step: Double = 0.05) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: snapped(Binding(get: get, set: set), in: 0...1, step: step), in: 0...1)
                    .frame(width: 150)
                Text("\(Int((get() * 100).rounded()))%")
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
    /// 破坏性动作（逐账号「删除」）：按钮走 destructive 语义 + 显式染红
    var destructive = false
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
            // 深浅档固定取 dark、带边框（账号行历来如此）；「主题预设」图卡另按预设解档
            if let img = model.iconProvider?(BrandIconRequest(key: key, dark: true)) {
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

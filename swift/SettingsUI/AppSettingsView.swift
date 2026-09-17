// 设置窗口视图：照 macOS 系统设置范式 —— NavigationSplitView 左 sidebar + Form(.grouped) 右表单，
// 全部原生控件；操作类行 = 图标 + 标题/说明 + 行尾按钮的 HStack（原因见 OperationRow）。
// 滑杆一律走 `snapped(_:in:step:)`（连续滑杆 + 写入吸附），不要用 `Slider(step:)` —— 见该函数注释。

import Foundation
import SwiftUI

/// 侧栏条目（2026-09-12 用户拆分定稿：原「操作」的三个栏目 + 「其他」四项各自独立成项；
/// 同日「主题调教」「平台开关」由面板右上角分段控件 / 玻璃弹窗迁入。
/// 2026-09-13 用户要求：「主题外观」提到最前、打开默认第一项；「设置」项撤销 ——
/// 自动签到并入「签到」、自动检查更新迁「关于」，由「签到」顶替其位；
/// 同日「WB 同步」并入「账号」。
/// 2026-09-17 用户要求：弹跳参数固化（见 `MenuBarBounceSettings.fixed`）→ 原「菜单栏」项整页移除；
/// 同日「3D 硬币放侧边栏第二个」→ `coinDemo` 挪到 `appearance` 之后（侧栏顺序 = 枚举声明序）。
public enum SettingsSidebarItem: String, CaseIterable, Identifiable, Hashable {
    case appearance
    case coinDemo
    case checkin
    case platforms
    case accounts
    case about

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .appearance: "主题外观"
        case .platforms: "平台"
        case .accounts: "账号"
        case .checkin: "签到"
        case .coinDemo: "3D 硬币"
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

// MARK: - 主题外观 pane（原面板右上角「主题调教」玻璃弹窗的 SwiftUI 原生版）

/// 主题预设 + 用量色 + 面板 / 卡片外观。
/// 除顶部「主题预设」的「保存」按钮外全部即时生效 ——
/// 与「关于」等 pane 同口径：写入转交宿主动作（落盘 + 触发重绘）后
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
            // 每枚预设是一张**迷你面板**图卡（见 `presetThumb`，2026-09-16 用户要求：
            // 预设不再是一行文字摘要，改成把该组参数画出来）。
            // 2026-09-17 用户改版：① 现有六枚**固定为出厂内置**（`ThemePreset.builtIns`，
            // 随包发布、不可删不可改名）；② 新增走**页脚那个「新增主题」**（用户否掉了
            // 「加号浮在图卡上」那一版：「加号似乎不能放在卡片上，不符合逻辑」）；
            // ③ 原「名称 + 保存」那一行整体删除。
            // 用户预设存宿主 UserDefaults（ThemePresetStore），窗口每次打开由 sync() 回读
            Section {
                presetGrid
            } header: {
                Text("主题预设")
            } footer: {
                // ⚠️ 页脚文案控在**两行以内**（2026-09-17 用户「主题外观页面的所有 forms 下的介绍描述，
                // 简化到两行以内」）—— 默认窗口下页脚一行 ≈39 个汉字，超过 ~75 字就会溢成三行。
                // 改这几段时先数字数，别再堆细节（细节看代码注释，这里只留「一眼看懂」）
                Text("点图卡即应用，蓝框那枚是当前生效的一组；内置预设只读，点列表末尾「新增主题」把当前参数存成一枚自己的预设（可改名、可删）。")
            }
            Section {
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
                // 主前景色（2026-09-17 用户「设置里 面板里 开放主前景色参数」）：卡片文字色。
                // 色盘**不透出不透明度**（文字色带 alpha 没意义，宿主按 alpha = 1 落值）。
                // 色盘显示的当前色 = 自选值 ?? 内置两档里「本页浅色主题档」那一支（见 Binding 注释）
                LabeledContent {
                    ColorPicker("主前景色", selection: panelForegroundColor, supportsOpacity: false)
                        .labelsHidden()
                } label: {
                    Text("主前景色")
                }
                // 用量色（原「主题色」，2026-09-15 用户改名 —— 它只管用量类可视化那一支色阶，
                // 与「面板背景色 / 次背景色 / 主前景色」不是一类，叫「主题色」会让人以为动它改整面板外观）。
                // 2026-09-14 用户要求：原色相/饱和度/亮度三根滑杆 + 标题色样一起撤掉，
                // 收成「面板」组里的一行系统色盘。
                // ⚠️ **2026-09-17 用户「用量色排在面板的第四行」**：从本 Section 的**首行**挪到
                // 「主前景色」之后 ⇒ 四行颜色排成 背景色 / 次背景 / 前景色 / 用量色，
                // 上方三行是"面板本体"的四支色，用量色（只管可视化色阶）收在颜色组末尾，不与它们混排；
                // 下面紧跟两条不透明度滑杆 + 浅色主题开关。挪位置只动这一段，其它行不动。
                // 拾色后由模型分解回 HSB 三参落值（下游点阵档位/卡片边框仍读 HSB，口径不变）；
                // 用量色不含透明语义，故不透出不透明度滑杆
                LabeledContent {
                    ColorPicker("用量色", selection: themeColor, supportsOpacity: false)
                        .labelsHidden()
                } label: {
                    Text("用量色")
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
                Text("「用量色」派生出点阵 / 进度条 / 热力图 / 卡片边框的色阶；「面板背景色」是底色遮罩；「次背景色」是面板内第二层背景；「浅色主题」强制浅色外观。")
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
                Text("「主标题字号」只管平台名（数值字号不变）；「Sharp Grotesk」开启后面板内文字统一换用，中文兜底苹方、未安装则回落系统字体。")
            }
            // ── 动效（2026-09-16 用户要求：位数变化时整组左右平移的时长口径两种都落地）──
            // ⚠️ **2026-09-17 用户「动效的参数固化，移除参数开放」：整个 Section 已删除** ——
            // 「动效曲线」定稿「从快到慢」、「滑移时长」定稿「跟随位移」，两个 config 键
            //（roll_curve / roll_slide_timing）、两个单选控件、快照字段 / 动作 / 宿主 setter
            // 与运行镜像一并移除，真值写进 `RollingNumberView.rollEase(_:)` 与 `slideTime()`
            //（与「主副标题行距系数」固化成常量的做法一致）。要改口径去那两个函数。
        }
    }

    // MARK: 主题预设（逐枚「应用 / + 新增 / 改名 / 删除」）

    /// 预设图卡网格（2026-09-16 用户要求：预设从「一行文字摘要」改成「一张迷你面板」；
    /// 同日「图卡太大」→ 收成**竖版长方形**；2026-09-17 用户「卡片宽度缩小 10%」）。
    /// ⚠️ **恒定一行三张**（2026-09-17 用户「固定一行显示三个卡片」）：列 = **3 个固定数量的
    /// `GridItem(.flexible(minimum: <106>, maximum: <121>))`**（都是 `s(...)` 出来的，见下方 thumbScale），
    /// 不再是 `.adaptive` —— adaptive 的列数随可用宽浮动（窗口一宽就凑出第四列、一窄就掉到两列），
    /// 用户要的是恒定三列。
    /// - 上限 = **基准 110 = 面板基准宽 100 + 两侧选中框占位 2×5**（2026-09-17 用户
    ///   「mini 面板 宽度缩小 10pt」：面板基准 109 → 100；更早那一刀是「宽度缩 10%」：132 × 0.9 = 119）
    /// - 下限只负责窗口缩到最小档时三列不被挤爆
    /// - 富余宽度**均分到两侧**、整块水平居中（2026-09-17 用户「红框区域所有预设要水平方向居中」）：
    ///   ⚠️ 居中必须落在**网格自己的 `alignment`** 上 —— `LazyVGrid` 会吃满被提议的宽度，
    ///   列宽到上限后富余宽度留在网格内部，由 `alignment` 决定列往哪靠；留 `.leading` 就是
    ///   「贴左、右边空一大片」（.19 那一版就是这么错的）。外层 `frame(maxWidth: .infinity)`
    ///   负责让网格拿到整行宽度（否则它只按内容宽量），两者缺一不可。
    private static let presetColumnCount = 3
    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: Self.s(96),
                                                              maximum: Self.s(110)),
                                                     spacing: Self.s(12)),
                                 count: Self.presetColumnCount),
                  alignment: .center, spacing: Self.s(16)) {
            ForEach(model.snapshot.themePresets) { preset in
                presetCard(preset)
            }
            // 「新增主题」当**最后一张图卡**排进网格（2026-09-17 用户「需要设计为 mini 面板一样宽高的大按钮形式」）：
            // 与预设卡共用一个列宽，所以它与左右邻卡逐行对齐、同宽同高
            presetAddTile
        }
        .padding(.vertical, Self.s(8))
        .frame(maxWidth: .infinity)      // 网格拿满整行宽度，列由上面的 .center 居中
    }

    /// 单枚预设 = 迷你面板缩略图（**点它 = 应用**）+ 名字行（可改名的名字 / 行尾垃圾桶 = 删除）。
    /// 命名与交互照 macOS 系统设置「外观」那套：图缩略图即选项、名字居中在图下、
    /// 当前生效那枚加一圈系统蓝描边（见 `presetThumb` 的 isActive）。
    ///
    /// 2026-09-17 用户改版 —— **出厂内置那几枚只读、用户自建的可删可改名**：
    /// - 内置：名字行不给垃圾桶、名字点不动（`ThemePreset.builtInIDs` 判断），右侧照样留同宽占位保居中
    /// - 自建：点名字 → 就地变成输入框（Enter 提交 / Esc 放弃，都走模型 `commitPresetRename`
    ///   / `cancelPresetRename`）；行尾垃圾桶 = 删除
    /// - **新增入口在 Section 页脚那个「新增主题」**（`ThemePane.body` 里），**不在这张卡上** ——
    ///   用户否掉了「加号浮在图卡右上角」那一版：「加号似乎不能放在卡片上，不符合逻辑」
    ///   （卡是「应用」语义，上面再挂一个「新增」确实两件事混在一起）
    ///
    /// ⚠️ 垃圾桶不能压在缩略图上做 overlay —— 外层是 Button，overlay 里再放 Button 命中判定不可靠；
    /// 放在名字行里，并用同宽占位保持名字居中
    private func presetCard(_ preset: ThemePreset) -> some View {
        let isActive = preset.matches(model.snapshot)
        let isBuiltIn = ThemePreset.builtInIDs.contains(preset.id)
        // 图卡前景色 = **这枚预设自己记的主前景色**（nil = 内置两档，2026-09-17 随参数开放接入预设）。
        // 提到 presetCard 算好再往下传（而不是让 presetThumb 自己读全局）：参数变化 →
        // 这里的值跟着变 → SwiftUI 重渲染子树，图卡上的文字色才能实时跟上色盘
        let appearanceDark = !preset.lightThemeEnabled
        let fg = Color(nsColor: PanelForegroundColor.resolved(dark: appearanceDark,
                                                              override: preset.panelForegroundColor))
        return VStack(spacing: Self.s(6)) {
            Button { model.applyThemePreset(preset) } label: {
                presetThumb(preset, isActive: isActive, appearanceDark: appearanceDark, fg: fg)
            }
            .buttonStyle(.plain)
            .help("应用这组预设")
            HStack(spacing: Self.s(4)) {
                Color.clear.frame(width: Self.s(16), height: 1)
                presetNameText(preset, isBuiltIn: isBuiltIn)
                if isBuiltIn {
                    Color.clear.frame(width: Self.s(16), height: 1)
                } else {
                    Button(role: .destructive) { model.deleteThemePreset(id: preset.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: Self.s(11)))
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: Self.s(16))
                    .help("删除这组预设")
                }
            }
        }
    }

    /// 「新增主题」= 与一枚预设**同宽同高的大按钮**（2026-09-17 用户
    /// 「需要设计为 mini 面板一样宽高的大按钮形式」），排在网格末尾当最后一张卡：
    /// 上半 = 与 mini 面板等尺寸的虚线框（内含「+」与「新增主题」），下半 = 与预设名字行等高的占位 ——
    /// 于是它与左右邻卡**逐行对齐**，读起来就是「这儿可以再加一枚」。
    /// ⚠️ 尺寸全部走 `Self.s(...)`（同 `presetThumb`）：图卡放大缩小时它跟着走，不会掉队。
    /// ⚠️ 曾试过放进 Section 的 footer（`.buttonStyle(.link)`），**整个不渲染** —— 见 MEMORY 那条坑
    private var presetAddTile: some View {
        VStack(spacing: Self.s(6)) {
            Button { model.addThemePresetFromCurrent() } label: {
                VStack(spacing: Self.s(8)) {
                    Image(systemName: "plus")
                        .font(.system(size: Self.s(18), weight: .light))
                    Text("新增主题")
                        .font(.body)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.s(138))        // 与 mini 面板同高（同日「缩小容器高度」152 → 140 → 138）
                .background {
                    RoundedRectangle(cornerRadius: Self.s(10))
                        .fill(Color.primary.opacity(0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Self.s(10))
                        .strokeBorder(style: StrokeStyle(lineWidth: Self.s(1),
                                                         dash: [Self.s(5), Self.s(4)]))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                }
                // 与图卡那圈选中框占位同宽 ⇒ 虚线框的实际宽度 = mini 面板宽度（逐列对齐）
                .padding(Self.s(5))
            }
            .buttonStyle(.plain)
            .help("按当前参数新增一组预设")
            // 名字行占位：与预设卡那行同字号同高（透明），保证整块高度也一致
            Text("新增主题").font(.body).opacity(0)
        }
    }

    /// 图卡下方那行名字：**内置只读文本 / 自建可点改**（点它就地变成输入框）。
    /// 字号 = `.body`（13pt，与表单正文同规格）—— 详见方法内注释
    @ViewBuilder
    private func presetNameText(_ preset: ThemePreset, isBuiltIn: Bool) -> some View {
        // 与**表单正文同字号**（2026-09-17 用户「mini 面板下的名称字号改为 forms 相同字号」）：
        // macOS 上表单/控件默认正文 = `.body` = 13pt = `NSFont.systemFontSize`
        //（⚠️ 原 `.callout` 是 **12pt**，实测 `NSFont.preferredFont(forTextStyle:)`；
        //  「12 还是 13」靠猜必错，这一条是量出来的）。
        // ⚠️ 名字行**不参与 `thumbScale` 等比**（其余几何照旧跟着缩）：它对齐的是设置窗口
        // 自己的正文，不跟随图卡尺寸
        let font = Font.body
        if isBuiltIn {
            Text(preset.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .help("内置预设，不可改名")
        } else if model.renamingPresetID == preset.id {
            TextField("", text: $model.renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(font)
                .frame(maxWidth: .infinity)
                .onSubmit { model.commitPresetRename() }
                .onExitCommand { model.cancelPresetRename() }   // Esc = 放弃
                .help("回车确认，Esc 取消")
        } else {
            Text(preset.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())        // 整格可点（文字本身的命中区只有墨迹）
                .onTapGesture { model.beginPresetRename(preset) }
                .help("点击改名")
        }
    }

    /// 迷你面板缩略图（**竖版**：基准 100×**138**pt ×`thumbScale`；2026-09-16 用户「图卡太大 → 改竖版长方形」、
    /// 2026-09-17「卡片宽度缩小 10%」→ 同日「宽度缩小 10pt」再收窄一刀、同日「等比放大」整体 ×`thumbScale`、
    /// 同日「缩小 mini 面板的容器高度」高度基准 152 → 140 → 138）：
    /// 把该组预设**看得见的参数**画成一张小面板，自上而下三块 ——
    /// ① 底色遮罩（**铺满整张图卡**：顶端 = `panelBackgroundColor.alpha`、底端 =
    ///    `panelBackgroundBottomAlpha` 的竖直渐变）。卡外**不加任何底**（2026-09-16 用户
    ///    「不要加这层东西 透明就行」）—— 遮罩 alpha < 1 处直接透出设置窗口自己的底，
    ///    所以图卡上那道渐变就是面板真实的「一端实、一端透」；
    /// ② 板块大标题「API」（**左缘与卡片 icon 同列** = 卡内 16pt）+ **两行平台卡**
    ///    （2026-09-17 用户「mini 卡片去掉背景色，第二行显示 mini 卡片的 hover 状态」→
    ///    「第二行改为 zcode 平台」）：第 1 行 = DeepSeek **常态**（不画底 —— 面板里卡片容器
    ///    底色恒 clear），第 2 行 = ZCode **hover 态**（次背景色材质块 + 亮边框，见 `miniCardRow`）。
    ///    卡的 icon 与主标题把**字号 / Sharp Grotesk / 主前景色**都带出来，
    ///    主前景色 = 这枚预设记的那一份（nil = 内置两档，2026-09-17 随参数开放进预设），
    /// ③ 底端一行 = **硬币贴卡左缘**（2026-09-17 用户「硬币的容器去掉内缩进，靠左摆放」，
    ///    本行不留 leading 内缩进）+ 右侧一列两样东西：Token 总计大数字（主面板 Token 板块
    ///    那串千分位数字，字号比主标题再大一档）+ **五格色阶图例**（首格 = 次背景色 =
    ///    面板「无用量底点」那档，其后 L1…L4 逐档取 `PanelHeatRamp` 的压暗系数）；
    ///    中间那条带即底色遮罩本身。
    /// ⚠️ 原 ② 与 ③ 之间那根**用量色进度条 2026-09-17 按用户要求整根删除**（连带
    ///    `progressStops`；「长进度卡片」开关从此只在主面板里看得见）。
    /// 高度写死、宽度吃列宽：列宽被网格钉在 108…119，所以恒为竖版长方形。
    /// 选中态 = 系统蓝描边（外扩 5pt、线宽 2.5 ⇒ 与面板留 2.5pt 缝；内容不重叠，
    /// 有无描边都不改缩略图尺寸 ⇒ 网格不跳）。
    /// - Parameters:
    ///   - fg: 图卡前景色，**由 `presetCard` 按这枚预设记的主前景色算好传入** ——
    ///     放参数而非函数内读全局，色盘一改这里就能驱动重渲染（见 `presetCard`）
    ///   - appearanceDark: 该预设的「浅色主题」开关解出来的外观档（色阶图例方向 / hover 边框用）
    private func presetThumb(_ preset: ThemePreset, isActive: Bool,
                             appearanceDark: Bool, fg: Color) -> some View {
        // 面板外观档：**只由预设自己的「浅色主题」开关决定**（开 = 浅色外观，关 = 深色外观）。
        // ⚠️ 2026-09-16 用户「主题预设的各种主题，需要对当前的深浅色设置做隔离」：
        // 原先写的是 `!lightThemeEnabled && colorScheme == .dark` —— 系统/窗口翻深浅、
        // 当前面板换主题，都会把**所有**图卡重画成另一副样子（连主前景色、图标档、
        // 进度条色阶方向都跟着翻），而图卡上写的参数一个都没变，读起来就是「设置的数字和
        // 图不符」。现在档位完全由预设自带的那一个布尔决定 ⇒ 图卡对当前环境**免疫**：
        // 只有改预设本身的参数才会变。（真实面板确实跟随系统外观，图卡必须挑一档 ——
        // 挑「关 = 深色」这一档，与用户日常看到的观感一致）
        let appearanceDark = !preset.lightThemeEnabled
        // fg 由 `presetCard` 算好传进来（= 这枚预设自己记的主前景色，nil 回落内置两档）——
        // 放参数里是为了让「色盘改前景色」能驱动图卡重渲染（全局读取 SwiftUI 看不见变化）
        let bg = preset.panelBackgroundColor
        let maskTop = Color(nsColor: bg.nsColor)
        let maskBottom = Color(nsColor: bg.withAlpha(preset.panelBackgroundBottomAlpha).nsColor)
        let secondary = Color(nsColor: preset.secondaryBackgroundColor.nsColor)
        return ZStack {
            // 面板本体 = 底色遮罩，铺满整张图卡（外面那层「玻璃底」2026-09-16 用户要求删除）
            RoundedRectangle(cornerRadius: Self.s(10))
                .fill(LinearGradient(colors: [maskTop, maskBottom],
                                     startPoint: .top, endPoint: .bottom))
            // VStack 段间距 9 → **7**（2026-09-17 用户圈出「API 标题 ↔ 第一张平台卡」那道缝，「缩小 2pt」）：
            // 它是「API 标题」与下面「两行平台卡」这一整块之间的间距，只此一处
            VStack(alignment: .leading, spacing: Self.s(7)) {
                // 板块大标题（= 主面板每个板块头顶那行「API / Token / Usage / Agent」）：
                // 字号与卡片主标题**同一档**（板块标题跟随 `cardTitleFontSize`，这是预设里那个
                // 字号参数的四个消费点之一，图卡得把它们画出来）；
                // 色是主面板的副前景色 —— 图卡把它近似成主前景色压暗（真解算
                // `Palette.secondaryForeground` 按底色推对比度，在宿主 target，图卡拿不到）
                Text("API")
                    .font(Self.titleFont(preset))
                    .foregroundStyle(fg.opacity(0.62))
                    .lineLimit(1)
                    // ⚠️ 标题要与下面那排卡片的 **icon 左缘**对齐（2026-09-17 用户「大标题 API 对齐 icon 最左」）——
                    // 主面板里两者同列：标题 = root.leading + 8（`apiTitle` 约束），卡片内容 = root.leading
                    // + 卡内缩进 8（`addCard(horizontalPadding: 8)`，卡容器与 root 同宽）⇒ 都落在 root + 8。
                    // 图卡里 root = 本 VStack 那层缩进，所以标题还要再让 8pt（恒定 = 卡片行自身的内缩进）
                    // 才落回卡片内容那一列 —— ⚠️ 改 VStack 那层缩进**不用**动这里，两者相加
                    .padding(.leading, Self.s(8))
                // 同一张平台卡画两行：常态在上、hover 态在下（2026-09-17 用户要求）——
                // 两行**各是一个平台**（2026-09-17 用户「第二行改为 zcode 平台」），
                // 与主面板 API 板块的真实内容一致：DeepSeek 常态 / ZCode hover
                VStack(alignment: .leading, spacing: Self.s(2)) {
                    miniCardRow(preset, icon: "deepseek", name: "DeepSeek",
                                appearanceDark: appearanceDark, fg: fg,
                                secondary: secondary, hovered: false)
                    miniCardRow(preset, icon: "zhipu", name: "ZCode",
                                appearanceDark: appearanceDark, fg: fg,
                                secondary: secondary, hovered: true)
                }
                Spacer(minLength: 0)
            }
            // 面板内容左右缩进 12 → 8（2026-09-16 用户「mini 面板的左右内缩进缩小」）→ **6**
            //（2026-09-17 用户「缩小 mini 面板的左右缩进」）：图卡是窄竖版，两边一挤版心就显瘦。
            // 这层是**面板级**缩进（≈主面板 root 的 7），卡片行自己那 8 是**卡内**缩进，两层别混
            .padding(.horizontal, Self.s(6))
            .padding(.vertical, Self.s(10))
            // 底端一行 = 主面板 **Token 板块**的缩影（硬币 + 总计大数字 + 色阶图例）。
            // 硬币**贴卡左缘**：本行不留 leading 内缩进（2026-09-17 用户「硬币的容器去掉内缩进，
            // 靠左摆放」）—— 币前的 8pt 内缩进一去掉，币就压在卡片自己的左边界上。
            // 这一行的定尺寸**随卡片宽度同比缩过**（2026-09-17 用户「卡片宽度缩小 10%」）：
            // 币 54 → 49、色格 6.6/3.5 → 5.9/3.2。（色格**间隔**当日再单独收到 2.4，
            // 见下面色阶图例处 —— 那一次只动间隙、没动点边长。）
            // 列间距 6.3 → 2 → **0**（2026-09-17 用户「间距缩小一些」→「改为0」）：币的渲染方框
            // 自带 ~4pt 空边，任何参数都会叠加在这 4pt 上 —— 取 0 后目视间距就是那 4pt 本身。
            // ⚠️ 2026-09-17 再收 2pt（用户圈出「币 ↔ 数值列」那道缝）时**不能再靠 spacing**（已经是 0），
            // 改成在币那一侧挂 **-2pt 的负内边距**：方框重叠 2pt，而图形离方框边缘还有空边 ⇒ 不会碰字。
            // 目视 4 → 2pt 就是这么来的（这个「目视 ≈ spacing + 4」是调它的口径）。
            //（色格恒比文字窄一档，故列宽由上面那串大数字决定）
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 0) {
                    miniCoin(preset, box: Self.s(49))
                        .padding(.trailing, -Self.s(2))
                    VStack(alignment: .leading, spacing: Self.s(5)) {
                        // Token 总计大数字 = 主面板 Token 板块行首那串（硬币右边、逐位滚动的
                        // 千分位数字，格式同 `ZcodeTokenStore.totalDisplay`）。
                        // 面板那边它是**整块面板最大的字**（23.4pt vs 卡片主标题 13pt ≈ 1.8×），
                        // 图卡缩完若与主标题同档就丢了这层主次 —— 故再乘 `tokenValueScale`
                        //（2026-09-17 用户「字号放大」）。⚠️ 列宽只剩 ~50pt（基准 = 面板 100 − 币 49），
                        // 系数再大就会被 `minimumScaleFactor` 缩回去，那是假放大
                        Text(Self.tokenValueSample)
                            .font(Self.titleFont(preset, scale: Self.tokenValueScale))
                            .foregroundStyle(fg)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        // 色阶图例 = 主面板竖排点阵那几格，**首格是次背景色**（档 0 = 「无用量底点」，
                        // 与 `Palette.heatLevelColor` 0 档同源；2026-09-17 用户「进度色前面加上次背景色」），
                        // 其后 L1…L4 逐档取 `PanelHeatRamp`（峰值 × 压暗系数）。
                        // **恒 5 格全亮**（图卡没有 ratio 可依，画的不是「用了多少」而是「这组的档位色」），
                        // 低档在左。边长 5.9 = 主面板竖排点阵的形状口径（点 4.56 : 隙 2.42）。
                        // ⚠️ **2026-09-17 用户「缩小 mini 面板里的进度点阵间隔」：间隔 3.2 → 2.4**
                        //（只收间隙、点边长 5.9 不动；基准值口径照旧，随 `thumbScale` 一起缩放）
                        HStack(spacing: Self.s(2.4)) {
                            RoundedRectangle(cornerRadius: Self.s(1.2))
                                .fill(secondary)
                                .frame(width: Self.s(5.9), height: Self.s(5.9))
                            ForEach(1...4, id: \.self) { level in
                                RoundedRectangle(cornerRadius: Self.s(1.2))
                                    .fill(Self.rampColor(preset, level: level, dark: appearanceDark))
                                    .frame(width: Self.s(5.9), height: Self.s(5.9))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                // 硬币行下缘到卡片下边缘的留白（2026-09-17 用户「缩小标注的间距」）：10 → **8**
                .padding(.bottom, Self.s(8))
            }
        }
        // 面板高度基准 152 → **140**（2026-09-17 用户「缩小 mini 面板的容器高度」）→ **138**
        //（同日再「缩小 2pt」）：上下两块内容之间的富余（两个 `Spacer` 各吃一半）随之收窄 ——
        // 那正是用户圈出的「ZCode 卡片 ↔ 硬币行」那道空隙。⚠️ 别压到内容贴死：两块内容的固定高之和
        //（API 行 + 间距 7 + 两行平台卡 + 间距 2 + 上下 padding 20 ＋ 硬币行 49）约 134 基准 pt，
        // 138 是「明显变矮但仍留一点缝」的值；再往下调要先算这个和。
        .frame(height: Self.s(138))
        .clipShape(RoundedRectangle(cornerRadius: Self.s(10)))
        // 面板自身那道细描边跟着面板走（外圈透明后它就是图卡的边界）。
        // 色取**预设自己那档主前景色**（不是 `Color.primary`）—— 与面板同源，也不吃窗口深浅
        .overlay {
            RoundedRectangle(cornerRadius: Self.s(10))
                .strokeBorder(fg.opacity(0.18), lineWidth: Self.s(1))
        }
        // 「+」曾于 2026-09-17 短暂画在这里（hover 该卡时浮出）—— 用户当天否掉：
        // 「加号似乎不能放在卡片上，不符合逻辑」，新增入口改到 Section 页脚那个「新增主题」
        .shadow(color: .black.opacity(0.30), radius: Self.s(2.5), y: Self.s(1))
        // 选中框：外扩 5pt、线宽 2.5（`strokeBorder` 是内描 ⇒ 与面板之间留 **2.5pt**）。
        // 常量占位，有无描边都不改缩略图尺寸 ⇒ 网格不跳
        .padding(Self.s(5))
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: Self.s(15))
                    .strokeBorder(Color.accentColor, lineWidth: Self.s(2.5))
            }
        }
    }

    /// 迷你面板里那行「平台卡片」（icon + 平台名）：**一个实现画两个状态** ——
    /// - `hovered = false`（常态）**不画任何底**：面板里卡片容器底色恒 clear
    ///   （`Palette.cardBackground`），常态卡片本来就没有背景；
    /// - `hovered = true`（hover 态）画上 hover 材质，与宿主 `HoverMaterialHost` 同源：
    ///   填充 = **次背景色**（`Palette.hoverGradient` 两档同值就是它）、边框 = 最亮档用量色
    ///   （`hoverBorderBright` = `heatLevelColor(4)`）；线宽按图卡比例从面板的 1.2pt 收到 0.7。
    /// `icon` / `name` 逐行给（= `CardStyle.icon` / `CardStyle.name` 那对取值），
    /// **图卡画的必须是真平台**：名字对了图标才不会是「另一个平台的图」。
    /// ⚠️ ZCode 与 ZhiPu **共用 "zhipu" 这张图**（`CardStyle.zcode.icon`），名字仍是 "ZCode"
    private func miniCardRow(_ preset: ThemePreset, icon: String, name: String,
                             appearanceDark: Bool, fg: Color,
                             secondary: Color, hovered: Bool) -> some View {
        HStack(spacing: Self.s(6)) {
            miniCardIcon(preset, key: icon, appearanceDark: appearanceDark)
            // 主面板里那张卡的标题就是**平台名**（板块大标题才是「API」）
            Text(name)
                .font(Self.titleFont(preset))
                .foregroundStyle(fg)
                .lineLimit(1)
                .minimumScaleFactor(0.8)   // 16pt + SG 时这名字最宽，别截断
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.s(8))
        .padding(.vertical, Self.s(6))
        .background {
            if hovered {
                RoundedRectangle(cornerRadius: Self.s(6))
                    .fill(secondary)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.s(6))
                            .strokeBorder(Self.rampColor(preset, level: 4, dark: appearanceDark),
                                          lineWidth: Self.s(0.7))
                    }
            }
        }
    }

    /// 卡片品牌 icon（按行给的 `key` = `CardStyle.icon` 那个图标名）：**两条来源跟预设走** ——
    /// - 「无边框图标」开 = 同名 **SVG 原图**（去 Icon Composer 底板），主机给 template 图，
    ///   这里按该档主前景色着色（与面板 `contentTintColor` 同一档：外观 ⊕ 图标深浅互换）；
    /// - 关 = Icon Composer **PNG**（自带底板，原色直画）。
    /// 深浅档 = 面板外观是否深色 **异或**「图标深浅互换」，与宿主 `brandIconDark` 同一条式子。
    /// 宿主没注入图标（预览环境）时回退成示意方块。
    /// ⚠️ 图标名与资源名不一致的两处（`brandSVGShrink` 注释同源）：ZCode 卡共用 "zhipu"、
    /// TRAE 卡是 "trae-color" —— 图卡传的就是这个图标名，不是平台名
    @ViewBuilder
    private func miniCardIcon(_ preset: ThemePreset, key: String, appearanceDark: Bool) -> some View {
        let iconDark = appearanceDark != preset.iconThemeSwap
        // 着色档主前景色 = **这枚预设记的那一份**（nil 回落内置两档）—— 与文字色同一来源
        let iconTint = PanelForegroundColor.resolved(dark: iconDark,
                                                     override: preset.panelForegroundColor)
        let req = BrandIconRequest(key: key, dark: iconDark, borderless: preset.iconNoBorder)
        if let img = model.iconProvider?(req) {
            if preset.iconNoBorder {
                // template 图：着色取该档主前景色（`PanelForegroundColor` 与宿主同一解算体）。
                // ⚠️ 必须 `.resizable()` —— `Image(nsImage:)` 默认按图自身尺寸（24pt 基准框）绘制，
                // 只给 frame 不会缩，会盖住右边那句主标题
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Color(nsColor: iconTint))
                    .frame(width: Self.s(14), height: Self.s(14))
            } else {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(width: Self.s(14), height: Self.s(14))
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Self.s(3)).fill(Color.black.opacity(0.45))
                RoundedRectangle(cornerRadius: Self.s(1))
                    .fill(Color(nsColor: iconTint))
                    .frame(width: Self.s(6), height: Self.s(6))
            }
            .frame(width: Self.s(14), height: Self.s(14))
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

    /// **图卡几何的统一缩放**（2026-09-17 用户「所有预设等比放大15%」→ 同日「改为放大 10%」）：
    /// 图卡（含名字行与网格本身）上**每一个定尺寸**都写成 `Self.s(基准值)`，
    /// ⚠️ **改放大率只动这一个数**，别再去逐处改字面量。
    /// 基准值 = 1.0 时那张图卡的尺寸，**刻意保持与主面板 pt 一一对应**
    ///（8 = root 内缩进、6 = 卡内上下缩进、49 = Token 行硬币方框、5.9/2.4 = 竖排点阵的点与隙…），
    /// 所以**基准值别改**（改了就与面板对不上号，注释里的「对应关系」全废），要变大变小调 thumbScale。
    /// ⚠️ 唯一的例外是色格**间隔**（2.4，原 3.2）：2026-09-17 用户点名要更紧，就它一个基准值与面板不同源
    /// 字号也跟着走：`thumbnailTypeScale` = 0.7 × thumbScale，所以文字与几何**同比例**（真「等比」）。
    private static let thumbScale: CGFloat = 1.1
    private static func s(_ base: CGFloat) -> CGFloat { base * thumbScale }

    /// 缩略图里各档文字的字体入口（板块大标题 + 卡片标题 + Token 大数字共用）：
    /// 主面板字号 **× 0.7 × scale（= `thumbScale`）** ——
    /// 图卡宽 ≈ 主面板的一半（122 vs 264），文字按比例缩才读得出「这是面板的缩影」；
    /// 原样 13.5pt 塞进 122pt 宽的卡里又大又挤。系数先试过 0.5（2026-09-16 用户「太小了 70%吧」）
    /// —— 0.7 比严格半比例大一档，是**可读性**换来的：13.5 → 9.45pt，档差（10/16pt → 7/11.2pt）更明显。
    /// SG 开关 → 本机 PostScript 名（未装自动回落系统字体），否则系统字体。
    /// ⚠️ 字体名是**字面量**（`PanelFont` 在宿主 target，本 target 引不到）；
    /// 宿主改了 `PanelFont.sgPostScriptName` 就得同步这里。
    /// ⚠️ **只缩字号**：icon 恒 `s(14)` = 主面板图标列 27.75pt 的严格半比例 × 缩放，不跟这个系数走
    private static var thumbnailTypeScale: CGFloat { 0.7 * thumbScale }
    /// Token 总计大数字在图卡里的**额外**放大倍率（2026-09-17 用户「字号放大」）：
    /// 主面板里它是整块面板最大的字（23.4pt vs 卡片主标题 13pt ≈ 1.8×），图卡若与主标题同档
    /// 就只剩「一行普通文字」的观感，层级丢了。1.3 是**列宽换来的上限** —— 硬币 49 之后
    /// 只剩 ~50pt（基准），再大就只能靠 `minimumScaleFactor` 缩回去（假放大）。
    private static let tokenValueScale: CGFloat = 1.3
    /// 图卡里那串 Token 数字的示例值：主面板 Token 板块的**真实格式**
    /// （`ZcodeTokenStore.totalDisplay` 的千分位完整数字档），**定 5 位数**
    ///（2026-09-17 用户「mini 面板 token 数值改为 5 位数」—— 位宽直接决定底端右列的量感）
    private static let tokenValueSample = "12,846"
    private static func titleFont(_ preset: ThemePreset, scale: CGFloat = 1) -> Font {
        let pt = CGFloat(preset.cardTitleFontSize) * thumbnailTypeScale * scale
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

    /// 「五个色阶图例」里 L1…L4 那四格共用的一格色：**档位坡** 上那一档（峰值 RGB × 系数）。
    /// 与宿主 `Palette.heatLevelColor` 同一条算式（那边是「峰值 × 系数」，0 档才取次背景色
    /// —— 图卡首格就是直接取次背景色，见 `presetThumb` 底端那行）；hover 态卡片的边框也读它（档 4）
    private static func rampColor(_ preset: ThemePreset, level: Int, dark: Bool) -> Color {
        let peak = peakRGB(preset)
        let f = PanelHeatRamp.factor(level: level, dark: dark)
        return Color(nsColor: NSColor(calibratedRed: peak.red * f, green: peak.green * f,
                                      blue: peak.blue * f, alpha: 1))
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

    /// **主前景色绑定**（2026-09-17 开放）。快照里是 `PanelBackgroundColor?`（nil = 用内置两档）：
    /// - get：nil 时显示「本页浅色主题档」下内置的那支（`builtIn(dark: !lightThemeEnabled)`）
    ///   —— 与图卡同一套深浅档口径，对设置窗口自身的深浅免疫（同文件头注的隔离铁律）
    /// - set：拾到的色原样交给宿主（alpha = 1，色盘本来就不透出不透明度），
    ///   一经拾色即为「自选」，此后深浅两档共用这个值
    private var panelForegroundColor: Binding<Color> {
        Binding(get: {
            let s = model.snapshot
            let current = s.panelForegroundColor
                ?? PanelBackgroundColor(nsColor: PanelForegroundColor.builtIn(dark: !s.lightThemeEnabled))
            return current.swiftUIColor
        },
        set: { model.setPanelForegroundColor(PanelBackgroundColor(swiftUIColor: $0)) })
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
        }
    }
}

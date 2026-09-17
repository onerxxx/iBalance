// Panel.swift — NSPopover 详情面板（左键点击菜单栏图标弹出）
//
// ─── 本文件速查（改面板 UI 前先看；只写「去哪找」，不写行号——行号必漂移）────────────
// 面板配色         enum Palette（本文件）：cardBackground / cardForeground / tooltip* / heat*
// 卡片字号         主标题 = 设置窗口「主题外观」开放（config.cardTitleFontSize，默认13）
//                  Palette.cardSubFontSize(9，副标题+积分)；数值固定 13pt
//                  ⚠️ 改字号改常量，勿在调用点写数字
// 行距系数         主副标题行距系数（SF/SG）已固化 → BalancePanelView.cardTitleGapScaleSFFixed /
//                  cardTitleGapScaleSGFixed（设置窗口不再开放）
// 卡片 icon 尺寸    CardStyle.iconSize(25)（本文件，全平台统一）
// 行高 / 间距       PanelLayout.swift balanceContentRow：row1 16、row2 12、两行 spacing 1
// 菜单栏指示点      CardMenuBarDotView（PanelLayout.swift，icon 下方 2pt、直径 3.6pt 圆点）；
//                  显隐驱动在 applyAccountCardData（按 ac.inMenuBar），原渐变蒙版已删
// 卡片构建 / 刷新   rebuildAccountCards（重建）/ applyAccountCardData（就地刷新，不重建）
// 用量行            makeUsageRow（UsagePanel.swift）；图表 popover 见 UsageHistoryPopoverController
// hover 卡片        HoverCard（Controls.swift）；账号气泡 showSubAccountTip（本文件，
//                  子账号项 hover / 当前账号积分 chip hover 共用，ChipTipBox 供数据）
// 拖拽排序          begin/update/endPlatformDrag（PanelDrag.swift 扩展）
// 数据快照构建      main.swift（PanelSnapshot 由 AppDelegate 组装，本文件只消费）
//
// ⚠️ 本文件 = 面板视图层（快照类型 + BalancePanelView + VC）。
//    弹窗在 Dialogs.swift，签到在 CheckinManager.swift，账号切换在 AccountSwitcher.swift。
import Cocoa
import CoreImage
import SettingsUI

/// 面板数据快照（由 AppDelegate 从各服务缓存 + 设置状态构建）
struct PanelSnapshot: Equatable {
    /// DeepSeek 卡片数据（单元素，走多号卡片管线；uid 恒 "ds"，无昵称无签到）
    var dsAccounts: [AccountCardSnapshot] = []
    /// ZhiPu（智谱 BigModel）卡片数据（单元素；uid 恒 "zhipu"）
    var zhipuAccounts: [AccountCardSnapshot] = []
    /// Qwen（千问 Token Plan）卡片数据（单元素；uid 恒 "qwen"，值为周剩余百分比）
    var qwenAccounts: [AccountCardSnapshot] = []
    /// 面板余额卡片可见性：key = 平台 ID（"ds" / "zcode" / "codex" / "trae" / "wb"），
    /// value=true 显示、false 隐藏；未记录的平台默认 true。
    var panelCardVisible: [String: Bool] = [:]
    /// 面板用量行可见性：key = 平台 ID，value=true 显示、false 隐藏；未记录的默认 true。
    var panelUsageVisible: [String: Bool] = [:]
    /// TRAE 多账号余额卡片数据（每号一条，当前账号排首位）
    var traeAccounts: [AccountCardSnapshot] = []
    /// WorkBuddy 多账号余额卡片数据（每号一条）
    var wbAccounts: [AccountCardSnapshot] = []
    /// ZCode 多账号余额卡片数据（每号一条，当前账号排首位）
    var zcodeAccounts: [AccountCardSnapshot] = []
    /// Codex 多账号余额卡片数据（本机 auth.json 导入）
    var codexAccounts: [AccountCardSnapshot] = []
    /// 日/周用量行（本地差值，仅当前账号）
    var usageRows: [UsageRowSnapshot] = []
    var offline = false
    var updatedAt = ""
    /// 刷新失败标记（footer「更新于」后追加，如 "TRAE、ZCode 刷新失败"；nil = 本轮全部成功）
    var failedText: String?
    // ── 设置/操作状态 ──
    var traeAutoCheckin = false
    var wbAutoCheckin = false
    /// 今日签到统计文案（如 "8-16 3成功 1失败 2风控"，手动签到计入；空 = 今天尚未产生任何签到结果）
    var lastCheckinTime: String?
    var refreshIntervalSeconds: Int = 300
    /// 面板底色遮罩色（同步自配置；alpha = 0 即无遮罩，露出原生玻璃）
    /// ⚠️ 下面的初值 = `PanelBackgroundColor.factory*`（2026-09-17 出厂默认固化那套）；
    /// 实际值由 `update(config:)` 同步覆盖，初值只兜「尚未同步」的那一瞬
    var panelBackgroundColor: PanelBackgroundColor = .factoryPanelBackground
    /// 遮罩**底端**不透明度（同步自配置；顶端用 panelBackgroundColor 自身的 alpha，两端各自独立）
    var panelBackgroundBottomAlpha: Double = PanelBackgroundColor.factoryPanelBottomAlpha
    /// 浅色主题开关（同步自配置；开启时强制浅色外观，优先级高于渐变开关）
    var lightThemeEnabled = false
    /// 卡片主标题字号（pt，同步自配置；设置窗口「主题外观 → 卡片」开放，10…16 步进 0.5）
    var cardTitleFontSize: Double = 13.5
    /// 卡片主标题 Sharp Grotesk（本机安装的商业字体；未装该字重回落系统字体）。
    /// 字重×宽度**已固定** Book20（见 cardTitleSGPostScriptName），不再开放档位。
    /// ⚠️ 主副标题行距系数（SF/SG）**已固化**（2026-09-15 用户）：不再是快照字段，
    /// 真值只此一处 → `BalancePanelView.cardTitleGapScaleSFFixed / SGFixed`
    var cardTitleSharpGrotesk = false
    /// 数值滚动预览开关（开启后余额卡片周期随机变化，演示逐位滚动动画）
    var valueScrollPreviewEnabled = false
    /// 长进度卡片开关（开启后余额卡片进度条独占整行 + 副标题下移一行）
    var longProgressCard = false
    /// 图标深浅互换开关（开启后卡片品牌 icon ClearDark/ClearLight 版本互换）
    var iconThemeSwap = false
    /// 无边框图标开关（开启后卡片品牌 icon 直接用同名 SVG 原图，不套 Icon Composer 底板）
    var iconNoBorder = false
    /// 自动检查更新开关（GitHub Releases 启动静默检查）
    var updateAutoCheckEnabled = true
    // 数值滚动的滑移时长口径 / 时间曲线档位两字段 2026-09-17 随「动效的参数固化」移除：
    // 定稿值在 `RollingNumberView.slideTime()` 与 `rollEase(_:)` 里，不再随配置同步
}

/// 副标题右侧 meta 的变化方向（2026-09-13）：up/down 选上下箭头；
/// flat = 无数据或无变化，显示右箭头 + 0（用户指定不隐藏）
enum DayDeltaDirection: Equatable {
    case up, down, flat
}

struct AccountCardSnapshot: Equatable {
    var uid: String
    var nickname: String
    var value: String?              // 已格式化的剩余额度
    var usedRatio: Double = 0       // 已用占比（0~1），用于点阵进度
    var isCurrent: Bool = false     // 是否为当前登录账号（非当前仅 Agent 平台存在：用于占位 entry 判定与 hover 账号条数据，不渲染小卡）
    var pulsing: Bool = false       // 额度被消耗（usedRatio 上升）→ 最右亮点阵脉冲
    var expireSegments: [String]?     // 重置/套餐到期倒计时分段（["剩余","x天","HH:MM"] / 单段短语）；段间 3pt 由 stack 布局提供
    var expired: Bool = false       // Start Plan 已到期（expireSegments 显示"套餐已到期"；2026-08-27 起颜色不再标红，与其他到期文本同用副前景灰）
    var checkinDone: Bool = false   // 今日已签到
    var checkinFailed: Bool = false // 签到失败（按 failed_date==today 口径；风控日也置 true 以显示角标）
    var checkinRisk: Bool = false   // 签到失败为风控（TRAE 返回 9074/操作太频繁）→ 角标橙黄色
    var streak: Int = 0             // 连续签到天数
    var reward: Int = 0             // 最近一次签到积分奖励
    var inMenuBar: Bool = false     // 该账号数值显示在菜单栏 → 卡片 icon 叠加透明渐变标记
    var hideDots: Bool = false      // 隐藏点阵（DeepSeek 未配置日常额度时；多号平台恒 false）
    var tokenInvalid: Bool = false  // 令牌失效/账号无套餐（账号级问题）：悬浮气泡 ID 后黄色徽章，不进平台刷新失败
    var taskState: AgentTaskState? = nil  // Agent 任务状态（仅当前账号）：icon 光环（nil = 无）
    var dayDeltaText: String? = nil  // 副标题右侧 meta：过去 24h 积分/余额变化量绝对值（API 卡恒有值，0 = 无数据/无变化）
    var dayDeltaDirection: DayDeltaDirection = .flat  // 变化方向（flat = 右箭头 + 0）
    var speedText: String? = nil  // 副标题右侧 meta：最近 10 次会话均速「x tok/s」（Agent 卡专用；nil = 无会话数据，meta 隐藏）
}

/// 动效统一取值表（UIUX-OPTIMIZATION.md §1）：时长与曲线只允许从这里取，
/// 新增动效不得再引入裸字面量。脉冲循环（0.5/0.55/0.6）与签名动效
/// （字符模糊切换 0.35、刷新按钮旋转 0.45）保留自有参数不进表。
enum Motion {
    /// 按压反馈：100–160ms 区间，越快越跟手
    static let press: CFTimeInterval = 0.12
    /// hover 态切换（文本提亮与背景渐变统一此时长）
    static let hover: CFTimeInterval = 0.25
    /// hover 材质跨卡跟随时长（2026-09-10 用户「边框动画的跟随更快一点」）：
    /// 跟手优先，比常规 hover 切换短——光标在卡片间游走时框要咬得住
    static let hoverFollow: CFTimeInterval = 0.16
    /// 布局重排/换位：屏上位移
    static let layout: CFTimeInterval = 0.20
    /// 内容揭示/淡入：偶发动作稍从容
    static let reveal: CFTimeInterval = 0.24
    /// 强调动效硬顶：一切 UI 动画 ≤ 0.40
    static let emphasis: CFTimeInterval = 0.40
    /// 余额数字滚动（Number Rolling）：数据变化反馈类动效，非 UI 状态切换，
    /// 用户指定加长时长，不适用 0.40 硬顶
    static let roll: CFTimeInterval = 3.0
    /// 数值滚动「滑移」（位数变化时的整组左右平移）时长钳制区间（2026-09-16 用户要求）：
    /// 原先滑移时长恒取 `rollDuration`（1.2s）而与位移量无关，用户反馈「位数左右移动
    /// 花的时间太长」。「距离驱动」档按位移在此区间内插值，「跟随滚字」档用它当下限 ——
    /// 计算唯一入口 `RollingNumberView.slideTime(rollDuration:)`
    static let rollSlideMin: CFTimeInterval = 0.30
    static let rollSlideMax: CFTimeInterval = 0.60
    /// Agent 卡 hover 确认时长：光标驻留此时长才切换 Token 板块，
    /// 子账号积分条换入同此节拍（用户指定 0.8s，滤掉光标快速掠过）
    static let hoverDwell: CFTimeInterval = 0.8
    /// SG 比例数字滚动的槽宽变化启动延迟（用户指定 50ms）：宽度滞后数字起滚
    /// 50ms 再开始跟随，横向位移与滚字起点解耦更柔和；宽度时间轴压缩进 tween
    /// 剩余时长，落定瞬间恰达目标宽——到位后零调整。等宽字体宽度恒定，无效果。
    static let rollWidthDelay: CFTimeInterval = 0.05
    /// 打开面板后滚动数字重滚入场的延迟（用户指定 0.5s）
    static let openRerollDelay: CFTimeInterval = 0.5
    /// 打开面板补发整段时长（用户指定 2s）：从开始到停下恒为此时长——行进最长的
    /// 车轮恰好占满，其余车轮按格数等比提前落定（共享角速度、错峰到达不变）。
    /// 与 roll 的「满 10 格一圈」预算口径不同，走 setText(totalDuration:) 归一通道。
    static let openRerollDuration: CFTimeInterval = 2.0

    /// 强 ease-out（等价 cubic-bezier(0.23,1,0.32,1)）：入场/反馈用，
    /// 起手快收尾长，比系统 easeOut 更有意图
    static let easeOutStrong = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    /// 强 ease-in-out（等价 cubic-bezier(0.77,0,0.175,1)）：屏上位移用
    static let easeInOutStrong = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
    /// ease-out cubic（等价 cubic-bezier(1/3,1/3,1,1)）：crossfade/点阵淡出
    /// 与字符模糊切换同步用（同周期同曲线的曲线半边）
    static let easeOutCubic = CAMediaTimingFunction(controlPoints: 1/3, 1/3, 1, 1)

    /// Agent 卡子账号条 chip 交错入场/离场（用户定稿节奏；入场 0.4s 与 Token
    /// 平台切换同款，豁免 emphasis 0.40 硬顶）
    enum chipStagger {
        /// 入场上移量（非 flipped 视图 -y 平移起步；2026-09-02 缩短行程）
        static let riseOffset: CGFloat = 6
        /// 入场单块时长（strong ease-out）
        static let riseDuration: CFTimeInterval = 0.40
        /// 入场行间错峰
        static let riseGap: CFTimeInterval = 0.10
        /// 离场下沉量（调用处取负：-y = 视觉向下；2026-09-06 用户指定 14 → 10 → 6）
        static let sinkOffset: CGFloat = 6
        /// 离场单块时长（easeIn 重力感，用户指定 0.35 → 2026-09-06 用户「透明度更快的降低」0.2）
        static let sinkDuration: CFTimeInterval = 0.2
        /// 离场行间错峰
        static let sinkGap: CFTimeInterval = 0.06
    }

    /// 单位制切换换值（Token 总计大数字：千分位完整数字 ↔ M 单位）。
    /// 数字轮照常滚动；消失的字符（千分位逗号 / 多余低位数字）先向下滚出，
    /// 随后新增字符（小数点、单位字母 M）从下方滚入 —— 全程只有纵向运动，
    /// 不会出现两串字符交叉叠字（滑移版的问题，2026-09-12 用户反馈）。
    /// 两段**必须错峰**：同下标位置滚出槽与滚入槽重合，同时运动会上下交叉。
    enum unitSwap {
        /// 滚出段：消失字符向下滚出行外（先手，清出位置）
        static let fallOut: CFTimeInterval = 0.14
        /// 滚入段：新增字符自下方升起（错峰在后）
        static let riseIn: CFTimeInterval = 0.26
        /// 两段总时长（= 换值动效整段，同时用作数字轮滚动预算，让收尾同拍）
        static var total: CFTimeInterval { fallOut + riseIn }
    }

    /// 点阵↔账号条互换的点阵侧时长（与字符模糊切换签名动效同周期）
    enum stripSwap {
        /// 点阵淡出
        static let dotsFade: CFTimeInterval = 0.35
        /// 点阵恢复：放慢与 chip 快速下沉形成节奏差（用户指定，豁免 0.40 硬顶）
        static let dotsRestore: CFTimeInterval = 0.65
        /// 点阵恢复专用：先慢后快但末段缓收（cubic-bezier 0.5,0,0.7,1）。
        /// 纯 easeIn + 长时长会把 ~45% 亮度变化压进最后 1s，观感即「瞬间亮起」
        static let dotsRestoreTiming = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.7, 1)
    }
}

extension NSAppearance {
    /// 深色外观判定（动态色分支用）
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// 配色 token：集中管理所有自定义颜色，避免硬编码散落各处
enum Palette {
    /// 卡片前景色（动态解析）：深色外观 #EBEBEB / 浅色外观黑灰（0.13）。
    /// 渐变背景开=面板强制深色外观恒取深色值；关=面板跟随系统外观，浅色主题自动转黑灰。
    /// 动态色按绘制环境外观解算；经 .cgColor 落盘（layer）会定格当时外观，需外观变化时重设。
    static let cardForeground = NSColor(name: nil) { appearance in
        resolvedCardForeground(dark: appearance.isDark)
    }
    /// **主前景色的运行时镜像**（2026-09-17 随参数开放新增，nil = 内置两档）：
    /// 写入点 = AppDelegate 启动载入配置、设置窗口色盘落值、预设应用三处（同 `panelBackgroundActive` 模式）。
    /// `cardForeground` 的 provider 绘制时读它 ⇒ 落值后让视图重绘即换色
    static var foregroundActive: PanelBackgroundColor?

    /// 按**指定深浅档**取主前景色（静态色，不随绘制环境变）：供「无边框图标」的 SVG 模板着色用 ——
    /// 那里要的是「图标深浅互换」解出来的档，可能与视图当前生效外观相反，动态色做不到这件事。
    /// 色号单一定义在 `PanelForegroundColor`（SettingsUI），设置窗口的预设图标读同一份；
    /// 解算时带上**当前生效的自选色**（nil = 内置两档）
    static func resolvedCardForeground(dark: Bool) -> NSColor {
        PanelForegroundColor.resolved(dark: dark, override: foregroundActive)
    }
    /// 非当前账号前景色：深色石墨灰（用户定稿 0.61）/ 浅色 0.42
    static let cardForegroundDimmed = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 0.61, alpha: 1.0)
            : NSColor(calibratedWhite: 0.42, alpha: 1.0)
    }
    /// 副前景色：面板第二层信息（卡片副标题/到期倒计时/meta、小表格行与标题、Token 面板自绘行、
    /// 分组标题、用量子面板表头与坐标轴、header 图标按钮常态 tint）的统一灰。
    ///
    /// **两侧外观都按当前面板底色解算对比度**：面板底色是用户可调的（`panel_background_color`
    /// 的色相/明度/不透明度都会改底的有效亮度），系统灰在近白底上只有 ~3.3:1、
    /// 在亮色底（如亮蓝 @V0.87）上甚至跌到 ~1.5:1 —— 故按 `secondaryForegroundContrastTarget`
    /// 判定：**达标就原样返回系统灰**（默认近黑底 6.1:1、默认近白底与裸玻璃都属达标档），
    /// 不达标才沿「远离底色」方向推到刚好达标（深底 → 提亮，浅底 → 加深），
    /// 且**有上限**：副前景亮度永不越过主前景（提亮侧封顶 / 加深侧托底）。
    ///
    /// 是**动态色**：provider 每次绘制都重新解算（已实测无缓存），所以底色改了只要让视图重绘
    /// 就会跟上 —— 落点见 `Panel.refreshSecondaryForeground` 与 `UsageHistoryPopoverController.applyPanelBackground`。
    static let secondaryForeground = NSColor(name: nil) { appearance in
        resolveSecondaryForeground(in: appearance)
    }
    /// 副前景色对面板底色的对比度下限（唯一口径）：
    /// 浅色侧 = WCAG 2.1 正文 AA（4.5:1，面板小字 9–13pt 走正文档）；
    /// 深色侧只有 2.5:1（比大字号/非文本档的 3:1 再松一档）—— 深色底上光晕与感知对比本就低一档，
    /// 钉太高会把副灰推到比主前景还亮，主次关系反而塌掉。
    static func secondaryForegroundContrastTarget(dark: Bool) -> CGFloat { dark ? 2.5 : 4.5 }
    /// 无遮罩（alpha ≤ 1%）时面板透出的原生玻璃底色（**sRGB 分量**，非亮度）：
    /// 浅色外观取白（1.0）、深色外观取 0.28 —— 都是 HIG 材质的近似值，且**都取偏亮侧**
    /// （把底算得更亮 → 解出的字色对比更强：宁可多调一档，也别漏调出读不清的字）
    private static func bareGlassChannel(dark: Bool) -> CGFloat { dark ? 0.28 : 1.0 }
    /// 副前景色解算（唯一实现；口径见 `secondaryForeground` 注释）
    private static func resolveSecondaryForeground(in appearance: NSAppearance) -> NSColor {
        // 基准灰 / 主前景都按当前外观现取：两者自身也是动态色（systemGray 实测
        // aqua 0.557 / darkAqua 0.596），直读分量会落到系统外观上
        var base = NSColor.systemGray
        var primary = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            base = NSColor.systemGray.usingColorSpace(.sRGB) ?? NSColor.systemGray
            primary = cardForeground.usingColorSpace(.sRGB) ?? NSColor.black
        }
        let dark = appearance.isDark
        let baseLum = relativeLuminance(base)
        let primaryLum = relativeLuminance(primary)
        let bgLum = effectivePanelBackgroundLuminance(dark: dark)
        let target = secondaryForegroundContrastTarget(dark: dark)
        let hi = max(baseLum, bgLum), lo = min(baseLum, bgLum)
        if (hi + 0.05) / (lo + 0.05) >= target { return base }   // 已达标：保持系统灰
        // 两个可行边界：加深到 (底+0.05)/target−0.05 以下、提亮到 target×(底+0.05)−0.05 以上
        // （两端越界 = 该方向无论怎么调都到不了目标，例如中灰底、纯黑底）
        let darkenNeed = (bgLum + 0.05) / target - 0.05
        let lightenNeed = target * (bgLum + 0.05) - 0.05
        // 首选「维持基准灰与底色的明暗关系」那一侧：字比底暗 → 加深、字比底亮 → 提亮。
        // 该侧到不了目标（need 越界）就换另一侧 —— 中灰底上基准灰只比底亮一点点时，
        // 提亮到顶也只有 ~3.3:1，得反过来加深才够
        let brighten: Bool
        var need: CGFloat
        if baseLum < bgLum {
            if darkenNeed >= 0 { brighten = false; need = darkenNeed }
            else if lightenNeed <= 1 { brighten = true; need = lightenNeed }
            else { return NSColor.black }
        } else {
            if lightenNeed <= 1 { brighten = true; need = lightenNeed }
            else if darkenNeed >= 0 { brighten = false; need = darkenNeed }
            else { return NSColor.white }
        }
        // **上限约束**：副前景亮度不得越过主前景（提亮侧封顶、加深侧托底）——
        // 底色偏中灰时单看对比度会把副灰推到与主标题同亮甚至更亮，主次就塌了
        if brighten, primaryLum > bgLum, need > primaryLum {
            need = cappedNeed(need, cap: primaryLum, bgLum: bgLum)
        }
        if !brighten, primaryLum < bgLum, need < primaryLum {
            need = cappedNeed(need, cap: primaryLum, bgLum: bgLum)
        }
        return neutralColor(linearLuminance: need)
    }
    /// 字色与底色的**可见性红线**：低于这条线字基本等于没画（WCAG 无此档，
    /// 取的是「勉强还能分辨」的经验下限），用来给上限约束兜底
    private static let visibilityContrastFloor: CGFloat = 1.5
    /// 上限约束的就地取舍：封到 `cap` 后若跌破可见性红线就不封 —— 底色把主前景也压糊了
    /// （如浅色主题 + 深底，主前景近黑），锚本身不可读，那种底色下先保看得见、层级让位
    private static func cappedNeed(_ need: CGFloat, cap: CGFloat, bgLum: CGFloat) -> CGFloat {
        let cappedContrast = (max(cap, bgLum) + 0.05) / (min(cap, bgLum) + 0.05)
        return cappedContrast >= visibilityContrastFloor ? cap : need
    }
    /// 当前面板底色的有效相对亮度：遮罩按 alpha 合成到玻璃底（`bareGlassChannel`）后取亮度。
    /// 分量合成在 sRGB 域做 —— 与 tintColor 叠在材质上的实际混色口径一致，且底色改动量本来
    /// 就是给眼睛看的近似值，不进线性域反而少一层换算误差
    private static func effectivePanelBackgroundLuminance(dark: Bool) -> CGFloat {
        let bg = panelBackgroundActive
        let bare = bareGlassChannel(dark: dark)
        guard bg.isEffective else { return relativeLuminance(bare, bare, bare) }
        let a = CGFloat(bg.alpha)
        func over(_ channel: Double) -> CGFloat {
            CGFloat(channel) * a + bare * (1 - a)
        }
        return relativeLuminance(over(bg.red), over(bg.green), over(bg.blue))
    }
    /// sRGB 相对亮度（WCAG 2.1 定义）
    private static func relativeLuminance(_ c: NSColor) -> CGFloat {
        relativeLuminance(c.redComponent, c.greenComponent, c.blueComponent)
    }
    private static func relativeLuminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        0.2126 * linearized(r) + 0.7152 * linearized(g) + 0.0722 * linearized(b)
    }
    private static func linearized(_ v: CGFloat) -> CGFloat {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    /// 线性亮度 → 中性灰（线性 → sRGB 传递函数；与 Palette 其余浅色值同装法用 sRGB 直给，
    /// 不走 calibrated 空间，避免最终渲染被 gamma 补偿挪一档）
    private static func neutralColor(linearLuminance y: CGFloat) -> NSColor {
        let v = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
        return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
    }
    /// hover 提亮的「亮色」档（行级 hover）：深色外观纯白 / 浅色外观纯黑，**恒不透明**。
    /// ⚠️ 不要用系统 `NSColor.labelColor` 充当这一档 —— 面板是 vibrant（毛玻璃）外观，
    /// 系统语义色在那里解析成「白 @85%」（实测 1.000/1.000/1.000/**0.85**），叠在深色玻璃上
    /// 偏灰：动画看着亮、落定后暗一档（2026-09-12 用户「先亮后有变暗了」的直接来源），
    /// 与不透明的自定义色并排也会显出两档（同日前一条「好像有两个前景色」）。
    /// 也不同于 `cardForeground`（#EBEBEB = 面板常态前景，不是"亮色"那一档）。
    static let hoverForeground = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 1.0)
            : NSColor(calibratedWhite: 0.0, alpha: 1.0)
    }
    /// 卡片底色：完全透明（露出容器毛玻璃）
    static let cardBackground = NSColor.clear
    /// 卡片 hover 提亮色 #333333 @ 30%
    static let cardBackgroundHover = NSColor(calibratedWhite: 51.0 / 255.0, alpha: 0.3)
    /// hover 底色（2026-09-12 用户定稿，色井设定已移除改固定值）：
    /// 深色 = 黑@30%（「固定30%深灰」，与用量色脱钩——中间态点阵最暗档实色已废）/
    /// 浅色 = 白@90%
    static let hoverCardDefaultDark = NSColor.black.withAlphaComponent(0.30)
    static let hoverCardDefaultLight = NSColor.white.withAlphaComponent(0.90)

    /// 统一 hover 渐变背景（余额卡片/操作磁贴/折叠标题条/用量条目共用）：
    /// 默认深色 = 黑@30%、浅色 = 白@90%；2026-09-15 起改由**次背景色**统一提供 ——
    /// 当天用户要求把原「hover 背景色」与「点阵背景色」合并成一个参数（「次背景色」，归到设置
    /// 窗口「面板」栏）⇒ 两档同值、**不再按外观分档**（浅色主题开关会把明度翻转）。
    /// 值来自运行镜像 `secondaryBackgroundActive`（见下方「次背景色」定义处）；
    /// 材质块颜色是 .cgColor 落 layer 的（定格外观），改值后须逐个材质宿主 `refreshAppearance()`
    /// 重解算 —— 见 `Panel.refreshDotMatrixAndHoverMaterials()`
    static let hoverGradientBright = NSColor(name: nil) { _ in secondaryBackgroundActive.nsColor }
    static let hoverGradientDark = NSColor(name: nil) { _ in secondaryBackgroundActive.nsColor }
    /// 渐变端点数组（CAGradientLayer.colors 直接可用）
    static let hoverGradient: [NSColor] = [hoverGradientBright, hoverGradientDark]
    /// 拖拽幽灵背景定调色（2026-09-06 两段式幽灵：只背景加模糊、叠 hover 强背景色）。
    /// 幽灵底保持半透明——backgroundFilters 的磨砂模糊靠它透出，实色会盖死：
    /// 深色 = 同卡片 hover 底（hoverCardDefaultDark）、浅色 = 点阵峰值色 @0.7。
    /// （原平台卡 hover 强背景/烘焙位图管线已于 2026-09-08 删除，仅幽灵仍用此色）
    static let cardHoverStrongBright = NSColor(name: nil) { appearance in
        appearance.isDark
            ? hoverCardDefaultDark
            : heatPeakColor.withAlphaComponent(0.7)
    }
    /// 渐变视觉角度：水平向右为 0°，顺时针偏移
    static let hoverGradientAngleDeg: CGFloat = 60

    /// 按视觉角度与实际宽高比求渐变端点：取四角在渐变轴上投影的极值角，
    /// 保证任意宽高比下视觉角度恒定（固定单位坐标会因宽高比失真）。
    /// HoverCard 与 HoverRowView 共用，确保两类 hover 渐变方向一致。
    static func gradientEndpoints(angleDeg: CGFloat, in bounds: CGRect) -> (start: CGPoint, end: CGPoint) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)) }
        let rad = angleDeg * .pi / 180
        // CA 单位坐标 y 向上，视觉顺时针 → 方向向量 y 取负
        let dx = cos(rad), dy = -sin(rad)
        var minPt = CGPoint.zero, maxPt = CGPoint.zero
        var minP = Double.infinity, maxP = -Double.infinity
        for cx in [0.0, 1.0] {
            for cy in [0.0, 1.0] {
                let p = (cx - 0.5) * Double(w) * dx + (cy - 0.5) * Double(h) * dy
                if p < minP { minP = p; minPt = CGPoint(x: cx, y: cy) }
                if p > maxP { maxP = p; maxPt = CGPoint(x: cx, y: cy) }
            }
        }
        return (minPt, maxPt)
    }
    /// 主面板容器背景配色（单一事实源）：applyGradient 与各子弹窗（Token/用量）兜底共用。
    ///
    /// 2026-09-14 由「高对比背景」强度滑杆改制：遮罩 = 设置窗口选定的「面板背景色」本身
    /// （RGB 由系统色盘给），纵向自顶向底微微透出；alpha ≤ 1% 视为关（top/bottom 均 nil，
    /// 露出原生 Liquid Glass 毛玻璃）。top/bottom 分别对应 TintedVisualEffectView 的
    /// tintColor / tintBottomColor（TintOverlayView 对 nil 不绘制）。
    ///
    /// 2026-09-14 再改（用户要求「删掉代码残留，开放上下两端的 alpha 在设置里」）：
    /// 原「底端 = alpha × containerBottomAlphaRatio(0.65)」的**自动递减已整体删除** ——
    /// 上下两端现在各由设置窗口一个滑杆显式给值：顶端 = 底色自身的 alpha（色盘 / 顶部滑杆），
    /// 底端 = 独立配置 `panel_background_bottom_alpha`（镜像 `panelBackgroundBottomAlphaActive`）。
    /// 两端同值即纯色遮罩，不再有隐式层次
    static func containerColors(background: PanelBackgroundColor) -> (top: NSColor?, bottom: NSColor?) {
        guard background.isEffective else { return (nil, nil) }
        let top = background.nsColor
        let bottomAlpha = min(max(panelBackgroundBottomAlphaActive, 0), 1)
        return (top, top.withAlphaComponent(CGFloat(bottomAlpha)))
    }

    /// 底端遮罩的不透明度镜像（0…1，config `panel_background_bottom_alpha` 的运行时副本）。
    /// 与 `panelBackgroundActive` 同处写入（启动载入 / 色盘或滑杆落值）；`containerColors` 读它，
    /// 于是各调用点（主面板 / 子弹窗兜底 / 气泡）不必各自传参
    static var panelBackgroundBottomAlphaActive: Double = PanelBackgroundColor.defaultBottomAlpha

    /// 默认遮罩色（未接管前各子弹窗的兜底实色）
    static let defaultContainerColors = containerColors(background: .default)
    /// 面板外观统一解析（唯一事实源，所有容器/popover/子面板必须走这里，禁止散落三元式）：
    /// 浅色主题开 = 强制浅色 aqua（即使系统是深色主题）；其余 = nil 跟随系统深浅色。
    /// 「面板背景色」只控制遮罩配色（containerColors），不影响外观。
    static func panelAppearance(lightTheme: Bool) -> NSAppearance? {
        if lightTheme { return NSAppearance(named: .aqua) }
        return nil
    }
    /// 应用内主题（浅色主题开关）的全局镜像：自建顶层窗口（GlassModalShell 模态壳、
    /// 更新窗口）不挂在面板视图树上，拿不到容器 appearance，只能读这里。
    /// **写入点只有两个**：AppDelegate 启动载入配置处、onToggleLightTheme 切换处。
    static var lightThemeActive = false
    /// 当前生效的「面板背景色」遮罩（config 的运行时镜像）：副前景色按它解算对比度，
    /// 与主面板 applyGradient 画的是同一份取值。**写入点只有两个**（与 lightThemeActive 同处）：
    /// AppDelegate 启动载入配置处、设置窗口色盘落值 / 浅色主题翻转处。
    /// ⚠️ 初值 = 出厂默认那套（`factoryPanelBackground`，2026-09-17 固化）；实际值由启动载入覆盖
    static var panelBackgroundActive: PanelBackgroundColor = .factoryPanelBackground
    /// 自建顶层窗口的统一外观（nil = 跟随系统），与 panelAppearance 同口径
    static var topLevelWindowAppearance: NSAppearance? {
        panelAppearance(lightTheme: lightThemeActive)
    }
    /// 卡片圆角 10pt（对齐 macOS Big Sur+ NSPopover 窗口系统圆角）
    static let cardCornerRadius: CGFloat = 10
    /// 余额卡片/大标题（Agent/用量/操作 hover 标题）的层圆角：2026-09-13 用户「改为9pt」。
    /// 仅卡片与标题层 + 共享材质描边圆角（材质半径取 card.layer.cornerRadius 自动跟随）；
    /// 面板容器/气泡/子面板轮廓/组容器维持 cardCornerRadius=10 不变
    static let hoverCardCornerRadius: CGFloat = 9
    /// header 残留内容色：浅色外观黑色 / 深色外观系统灰。
    /// ⚠️ 2026-09-14 起 header **按钮**（`makeHeaderIconButton` / `RefreshPieButton`）已改用
    /// `secondaryForeground`（系统灰基准 + 按面板底色对比度补偿），本常量只剩两处装饰用途：
    /// 已隐藏的「更新于」label、拖拽槽位指引层（`HeaderSlotGuidesView`）
    static let panelHeaderContentColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.systemGray : NSColor.black
    }
    /// header 下缘分割线色（深色白@10% / 浅色黑@8%），由 PanelSeparatorView 自绘使用。
    static let headerSeparatorColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.08)
    }
    /// 卡片边框色（2026-09-12 用户「点阵主题色也应用在卡片边框颜色上」；同日先取第二亮档，
    /// 2026-09-13 用户改回**最亮**档：沿档位号配对口径——暗色最亮档、浅色对应档位号 4
    /// （浅色阶序与深色互补，即最暗档），alpha 恒 1 档位实色）：即 heatLevelColor(4, dark:)——
    /// 暗色 = 峰值色原色 / 浅色 = 峰值色 × 0.33。走 heatLevelColor 与点阵档位
    /// 严格同源，档位调整边框自动跟随；峰值色解算时现取，色相/饱和度改动后经
    /// applyHeatHueInPlace 重染落盘层。
    static let hoverBorderNormal = NSColor(name: nil) { appearance in
        Palette.heatLevelColor(4, dark: appearance.isDark)
    }
    /// hover 边框色：与 hoverBorderNormal 同值——hover 只动宽度，色动画链路保留，
    /// 日后单独调 hover 色只改此处
    static let hoverBorderBright = NSColor(name: nil) { appearance in
        Palette.heatLevelColor(4, dark: appearance.isDark)
    }
    /// 动态色落 CALayer 前按「视图生效外观」解算（hover 路径必须走这里）。
    /// 事件回调（mouseEntered/Exited）里 NSAppearance.current 是**系统**外观，
    /// 而浅色主题开关（light_theme_enabled）是给面板强制 aqua 的——两者不一致时
    /// 直接取 .cgColor 会解算到深色分支（白@35%），浅色面板上出现近乎不可见的白边。
    static func borderCGColor(_ color: NSColor, in view: NSView) -> CGColor {
        var resolved = NSColor.clear.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    // ── 图表元素（用量趋势子面板 / Token 统计子面板共用）──

    /// 面积图折线（深 0.65 / 浅 0.5 灰）
    static let chartLine = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedWhite: 0.65, alpha: 1) : NSColor(calibratedWhite: 0.5, alpha: 1)
    }
    /// 面积图曲线下方渐变填充（深 白40%→2% / 浅 黑10%→1%，上下端）
    static let chartAreaTop = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.40) : NSColor.black.withAlphaComponent(0.10)
    }
    static let chartAreaBottom = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.02) : NSColor.black.withAlphaComponent(0.01)
    }
    /// 图表当日数值标注（深 0.72 / 浅 0.35）
    static let chartValueColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedWhite: 0.72, alpha: 1) : NSColor(calibratedWhite: 0.35, alpha: 1)
    }
    /// 用量图表当日 Pulse Dot（深 常规 0.75 / 峰值 #EBEBEB；浅 常规 0.40 / 峰值 0x26）。
    /// ⚠️ 与主前景同源定稿（峰值曾硬编码 0xE9，改主前景色时需同步）
    static let pulseDotBase = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedWhite: 0.75, alpha: 1) : NSColor(calibratedWhite: 0.40, alpha: 1)
    }
    static let pulseDotPeak = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0xEB/255.0, green: 0xEB/255.0, blue: 0xEB/255.0, alpha: 1)
            : NSColor(calibratedWhite: 0x26 / 255.0, alpha: 1)
    }
    /// **次背景色**（设置窗口「面板 → 次背景色」）：面板内**第二层背景**的统一色 ——
    /// 无用量底点 / 进度条轨道底 / 骨架行 / Token 印章底 / 卡片 hover 材质块
    /// （后者见上方 `hoverGradientBright/Dark`）全部同源。
    /// 2026-09-15 由原「点阵背景色」+「hover 背景色」两个参数**合并**（用户要求：合并、
    /// 改名「次背景色」、参数归到设置窗口「面板」栏）—— 原两个运行镜像
    /// `heatDotEmptyActive` / `cardHoverBackgroundActive` 一并合并为本变量。
    /// 默认 = 深 #292929 / 浅 #dddddd 系（沿用原「点阵背景色」内置默认，
    /// 2026-09-07 由 #262626 提亮）；浅色主题开关会把明度翻转。
    /// 值来自运行镜像（Config 装载 / 色盘落值时写），动态色只在绘制时解算 ⇒
    /// 改值后靠 `Panel.refreshDotMatrixAndHoverMaterials()` 整树重绘落屏。
    /// ⚠️ 用户改的颜色一律**原样**用（用户选什么就是什么，不再按外观分档）。
    /// 初值 = 出厂默认那套（`factorySecondaryBackground`，2026-09-17 固化）；实际值由启动载入覆盖
    static var secondaryBackgroundActive: PanelBackgroundColor = .factorySecondaryBackground
    static let secondaryBackground = NSColor(name: nil) { _ in secondaryBackgroundActive.nsColor }
    /// Token 热力图 hover 高亮环（深 白@90% / 浅 黑@70%）
    static let heatDotRing = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.7)
    }
    /// Token 热力图有量级配色（按生效外观选择，集中管理勿散落）。
    /// 2026-09-07 用户定稿峰值色 = sRGB (225, 254, 119)（亮黄绿），其余档位 = 同色相
    /// 亮度阶梯（对峰值色等比压暗，色相/饱和走向不变）：
    /// 深色主题 = 4 级离散档（level 1→4）压暗系数 45% / 65% / 82% / 100%
    ///（「前三档过暗提亮」定稿；首版 28/50/73/100 作废）；
    /// 浅色主题 = 两端点线性插值，低用量端 = 峰值色原样、高用量端 = 33% 压暗
    ///（替换 2026-08-29 GitHub 绿阶 #063A16…#56D364 与浅色 #9BE9A8→#216E39 旧档）。
    /// 峰值基准色 HSB 分解：三参由设置窗口「面板 → 用量色」系统色盘拾色后分解写入
    ///（原三根滑杆 2026-09-14 撤掉，落值链路不变）。
    /// 明度默认 = 254/255（弹层圆点取色同用，故 internal）。
    /// 三个默认值一律**引用 `PanelThemeColor` 的常量**（解算体在 SettingsUI）：
    /// 宿主点阵、「主题预设」缺项兜底、设置窗口色盘三者同源，避免各写一遍算式后漂移
    static let heatPeakDefaultBrightness: CGFloat = PanelThemeColor.defaultBrightness
    /// 基准黄绿的色相/饱和（0..1）：峰值 (225,254,119) → hue=(2+(B−R)/Δ)/6、sat=Δ/max。
    static let heatPeakDefaultHue: CGFloat = PanelThemeColor.defaultHue
    static let heatPeakDefaultSaturation: CGFloat = PanelThemeColor.defaultSaturation
    /// 用量色色相（0..1）：设置窗口用量色色盘写入；UserDefaults 持久化跨重启。
    static var heatPeakHue: CGFloat {
        get {
            ((UserDefaults.standard.object(forKey: UDKey.heatDotHue) as? Double).map { CGFloat($0) })
                ?? heatPeakDefaultHue
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: UDKey.heatDotHue) }
    }
    /// 用量色饱和度（0..1）：同上。
    static var heatPeakSaturation: CGFloat {
        get {
            ((UserDefaults.standard.object(forKey: UDKey.heatDotSaturation) as? Double)
                .map { CGFloat($0) }) ?? heatPeakDefaultSaturation
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: UDKey.heatDotSaturation) }
    }
    /// 用量色峰值明度（0..1）：HSB 的 V，同上持久化。
    static var heatPeakBrightness: CGFloat {
        get {
            ((UserDefaults.standard.object(forKey: UDKey.heatDotBrightness) as? Double)
                .map { CGFloat($0) }) ?? heatPeakDefaultBrightness
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: UDKey.heatDotBrightness) }
    }
    /// 当前最终峰值色（level 4 / 弹层圆点实时显色）。
    static var heatPeakColor: NSColor {
        let c = heatPeakRGB()
        return NSColor(calibratedRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
    /// HSB → RGB（0..1）：色相/饱和度调整后推导峰值色的唯一实现（解算体在 `PanelThemeColor`，
    /// 与设置窗口色盘共用一份）
    private static func heatPeakRGB() -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = PanelThemeColor.rgb(hue: heatPeakHue, saturation: heatPeakSaturation,
                                    brightness: heatPeakBrightness)
        return (c.red, c.green, c.blue)
    }
    /// 热力档位 → 实色（0 = 无用量底点；= 峰值色 × 压暗系数）。
    /// 2026-09-07 从 TokensPanel 上收到此集中管理：词元活动热力图与默认卡片竖排点阵四档状态色共用；
    /// **2026-09-16 系数表本身再上收到 `PanelHeatRamp`**（SettingsUI）—— 「主题预设」图卡的进度条
    /// 要画同一条坡，各写一份必然漂移（图卡渐变方向反过一次就是这条）。这里只剩「取峰值 RGB × 系数」
    /// 与「0 档 = 次背景色」两件事。
    /// ⚠️ 本函数是**两处共用**的（卡片竖排点阵 + 词元活动热力图），改档位两处一起变 —— 那是刻意的：
    /// 同一个「用量档位」在两个视图里必须同色，否则同屏出现两套色阶
    static func heatLevelColor(_ level: Int, dark: Bool) -> NSColor {
        if level <= 0 { return secondaryBackground }
        let peak = heatPeakRGB()
        let factor = PanelHeatRamp.factor(level: level, dark: dark)
        return NSColor(calibratedRed: peak.r * factor, green: peak.g * factor,
                       blue: peak.b * factor, alpha: 1)
    }
    /// 悬浮提示气泡（深 近黑@94% + 白@16% 边 / 浅 近白@95% + 黑@15% 边）
    static let tooltipBackground = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 0.10, alpha: 0.94)
            : NSColor(calibratedWhite: 0.98, alpha: 0.95)
    }
    static let tooltipBorder = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.15)
    }
    /// 卡片边框宽度（hover 态那圈发丝描边）：2026-09-12 定稿 1.2pt（沿革 1 → 1.2 → 1.7 → 1.5 → 1.2），
    /// **2026-09-17 用户「卡片 hover 时边框宽度缩小 0.2pt」→ 1.0pt**。
    /// 由共享 hover 材质描边 / 拖拽 ghost / 用量行 / 各预设点统一引用 —— 改这一个数，全站 hover 边框一起走。
    /// ⚠️ `AppSettingsView.presetThumb` 里那圈**图卡**描边不读这里（按图卡尺寸单独折算，见该处注释）
    static let cardBorderWidth: CGFloat = 1.0
    /// 卡片主标题字号：2026-09-13 起由设置窗口「主题外观 → 卡片」开放（config.cardTitleFontSize，
    /// 默认 13pt），经 registerCardTitle/applyCardTitleFont 就地下发，不再走本常量；
    /// 数值字号仍固定 13pt（balanceContentRow 内 registerRollingNumber 字面量）。
    /// 主副标题**行距系数**（SF/SG 两档）2026-09-15 已固化 → `BalancePanelView.cardTitleGapScaleSFFixed / SGFixed`
    /// 卡片副标题（到期/剩余分段）、其余账号积分 chip、气泡积分行：9pt（2026-08-31 统一，原 8pt）
    static let cardSubFontSize: CGFloat = 9
}

// 旧名兼容（逐步迁移到 Palette）
let kCardBackground = Palette.cardBackground
private let kCardBackgroundHover = Palette.cardBackgroundHover

/// 从 App bundle Resources 加载品牌 SVG 图标。
/// ⚠️ 保持文件原始颜色：不设 isTemplate、不加 contentTintColor，
///    否则品牌色（如 TRAE 渐变）会被单色化。调用方如需单色可自行模板化。
func bundleIcon(_ name: String, size: CGFloat) -> NSImage? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: size, height: size)
    return img
}
/// JetBrainsMonoNL-SemiBold（等宽字体，无中文字形）：
/// 拉丁字符用 JetBrainsMono，缺字（中文/特殊符号）通过 cascade 级联自动回退系统字体。
/// 字体文件随 App 打包在 Resources/，首次使用时按进程注册（幂等）。
enum MonoFontProvider {
    /// PostScript 名（实测字体内部命名，NSFont(name:) 需用 PostScript 名）
    private static let postScriptName = "JetBrainsMonoNL-SemiBold"
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        guard let url = Bundle.main.url(forResource: "JetBrainsMonoNL-SemiBold", withExtension: "ttf")
            ?? Bundle.main.url(forResource: "JetBrainsMonoNL-SemiBold", withExtension: "otf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// JetBrainsMono + 系统字体级联：weight 仅作用于中文回退部分
    /// （JetBrainsMonoNL 用 SemiBold 一档，拉丁字符统一等宽 SemiBold 字重）
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        register()
        if let base = NSFont(name: postScriptName, size: size) {
            let cascade = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            let desc = base.fontDescriptor.addingAttributes([.cascadeList: [cascade]])
            if let f = NSFont(descriptor: desc, size: size) { return f }
            return base
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}

/// 主面板字体解析器（2026-09-15）：**主面板内所有文字字体的唯一入口**。
///
/// 两档（设置窗口「主题外观 → 卡片 → Sharp Grotesk 字体」开关）：
/// - 系统档 = 系统字体 / 等宽数字系统字体（原 `uiFont` 口径）；
/// - SG 档 = Sharp Grotesk（固定 Book20）。
///
/// 中文兜底：SG **无中文字形**（实测 `CTFontGetGlyphsForCharacters` 汉字全覆盖
/// 返回 false），走 descriptor 的 `cascadeList` 兜底到 PingFang。两个实测结论定了
/// 这里的两处写法：
/// 1. cascade 必须给**具体 PostScript 名**（PingFangSC-Medium / Semibold）。
///    用 `NSFont.systemFont(ofSize:weight:)` 的 descriptor 作 cascade，中文字重
///    恒落 PingFangSC-Regular（weight trait 不被级联采纳）→ 表头/数值的汉字会偏细；
/// 2. SG 拉丁字重只有 Book 一档 → 字重参数只用来挑中文兜底档（regular/medium/semibold
///    三档），拉丁字母不随 weight 变粗细。
///
/// ⚠️ 面板内新加文字一律走 `font(size:weight:monoDigits:)`，禁止再散写
/// `.systemFont(...)`：散写会绕过 SG 档，切字体时那块文字不跟随。
enum PanelFont {
    /// SG 档运行镜像（与 `Palette.lightThemeActive` 同款全局状态）。
    /// 静态上下文（`SmallTable` / 自绘层）也要能解析字体，故不放视图实例上。
    /// 写入点两处：AppDelegate 启动载入配置处、`BalancePanelView.update` 同步快照处
    /// （开关翻成 true 时顺手注册随包字体，见 `ensureSGRegistered`）
    static var sharpGroteskActive = false {
        didSet { if sharpGroteskActive { ensureSGRegistered() } }
    }
    /// 固定档 PostScript 名（Book20）：字重与宽度档已固定，不再开放（见
    /// `BalancePanelView.cardTitleSGPostScriptName` 注释）
    static let sgPostScriptName = "SharpGrotesk-Book20"
    /// 解析缓存：键 = 字号 | 字重（含 descriptor 属性合并，值得缓存）。
    /// 组合数 = 面板用到的字号 × 3 档字重，量级几十，不需要淘汰
    private static var cache: [String: NSFont] = [:]

    /// SG 随包字体是否已注册（幂等标记）
    private static var sgRegistered = false

    /// **把 SG 字体注册进本进程**（首次取 SG 字体时调一次）。
    ///
    /// 2026-09-17 用户「SG字体需要打包进App里」：此前字体只在**本机字体库装过它的机器**上命中
    ///（`NSFont(name:)` 直接查系统字体库），没装的机器静默回落系统字体 —— 换个机器 SG 开关就失效。
    /// 现在字体文件随包走：`swift/fonts/SharpGrotesk-Book20.otf` → `build.sh` 的 `fonts/*.otf`
    /// 拷贝规则带进 `Resources/` → 这里 `CTFontManagerRegisterFontsForURL(.process)` 注册。
    ///
    /// ⚠️ 与隔壁 `MonoFontProvider.register()` 同一套做法（那里也是 `font()` 里懒调用）：
    /// 放在 `font()` 里而不是启动处，是为了「不开 SG 就不读这份字体」。
    /// ⚠️ 商用字体（Commercial Type 的 Sharp Grotesk）：**随包发布等于再分发**，
    /// 对外发版前确认授权范围（JetBrainsMono 那份是 OFL，无此问题）。
    ///
    /// 调用点两处：`sharpGroteskActive` 的 didSet（开关翻 true）+ 启动时的无条件一次
    ///（`AppDelegate` 启动流程）—— 后者是为了**设置窗口的预设图卡**：它按预设自己记的 SG 开关画字，
    /// 与主面板那个开关无关，只靠 didSet 会在「主面板关着 SG、图卡要画 SG」时命中不了。
    static func ensureSGRegistered() {
        guard !sgRegistered else { return }
        sgRegistered = true
        guard let url = Bundle.main.url(forResource: sgPostScriptName, withExtension: "otf")
            ?? Bundle.main.url(forResource: sgPostScriptName, withExtension: "ttf") else {
            Logger.log(.layout, "[Font] SG 字体不在 bundle 里（fonts/*.otf 没打进 Resources？）")
            return
        }
        var err: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        Logger.log(.layout, "[Font] SG 注册 \(ok ? "成功" : "失败")：\(url.lastPathComponent)"
                   + (ok ? "" : " — \(err.map { String(describing: $0.takeRetainedValue()) } ?? "未知错误")"))
    }

    /// 系统档字体（原 `BalancePanelView.uiFont` 口径；SG 关闭 / 本机未装 SG 时也走这里）
    static func system(size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) -> NSFont {
        monoDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }

    /// 中文兜底字体（只作 SG 的 cascade 项，不单独给视图用）
    private static func cjkFallback(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let name: String
        switch weight.rawValue {
        case ..<0.12: name = "PingFangSC-Regular"
        case ..<0.27: name = "PingFangSC-Medium"
        default:      name = "PingFangSC-Semibold"
        }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// 面板字体（唯一入口）。
    /// `monoDigits` 只在系统档有意义 —— SG 的数字是**比例数字**（实测 "0" 9.035 /
    /// "1" 5.863，且 tnum 特性档不存在），等宽列靠各自右对齐保证对齐
    static func font(size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) -> NSFont {
        guard sharpGroteskActive else {
            return system(size: size, weight: weight, monoDigits: monoDigits)
        }
        // 随包字体先注册（幂等；此前只在装了该字体的机器上能命中，见 ensureSGRegistered）
        ensureSGRegistered()
        guard let base = NSFont(name: sgPostScriptName, size: size) else {
            return system(size: size, weight: weight, monoDigits: monoDigits)
        }
        let key = "\(size)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let desc = base.fontDescriptor.addingAttributes(
            [.cascadeList: [cjkFallback(size: size, weight: weight).fontDescriptor]])
        let font = NSFont(descriptor: desc, size: size) ?? base
        cache[key] = font
        return font
    }
}

/// 四字节 FourCC 轴标签 → 32 位有符号整数（CoreText descriptor .variation 要求整数键）。
/// 'wght' = 0x77676874 = 2003265652；'MONO' / 'CASL' / 'slnt' / 'CRSV' 同理。
/// 通用 layer keypath 过渡（borderWidth / shadowOpacity 等），0.22s easeInEaseOut
func animateLayerKey(_ layer: CALayer?, keyPath: String, to value: Any?, duration: Double = Motion.hover) {
    guard let l = layer else { return }
    let anim = CABasicAnimation(keyPath: keyPath)
    anim.duration = duration
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    anim.fromValue = l.value(forKeyPath: keyPath)
    anim.toValue = value
    l.add(anim, forKey: keyPath + "Transition")
    l.setValue(value, forKeyPath: keyPath)
}

/// 横向滚动禁用 clip view：AppKit 所有滚动路径（滚轮/触控板/scroll(to:)）都经
/// clip view 原点落位，覆写钳 x = 0 即任何事件源都无法左右滚动面板
final class NoHorizontalScrollClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }
}

/// 面板内容控制器：把 BalancePanelView 挂进 popover，宽度 260（主面板宽度增加 20pt），高度受屏幕可用空间限制；
/// 内容超高时通过纵向滚动查看底部设置、操作和更新时间。
final class BalancePanelViewController: NSViewController {
    /// 面板宽度唯一值（用户口中的「面板宽度」即此值）：popover 总宽，含容器左右缩进。
    /// document 宽 = panelWidth − 容器缩进×2，内容按约束压缩/截断自适应承接，
    /// 不再由内容固有宽（fittingSize）反推宽度。用户改宽度只动这一个数。
    /// 操作磁贴行固定宽 4×56+3×2=230：现行 document=242（264 − 11×2，2026-09-06 晚
    /// 268→264、缩进 13→11 同轮调整，内容宽与 268/13 时代完全一致）实测可用。
    static let panelWidth: CGFloat = 264
    /// 满尺寸内容（hasFullSizeContent）下容器铺满整个 popover 窗口，系统原有的
    /// 左右边距带不再存在：由容器层（scrollView 左右约束）统一补回的缩进。
    /// root/footer 自身保留原 7pt 正文缩进，11+7=18pt（2026-09-03 四次调整：
    /// 16 → 8 → 13 → 9；2026-09-06 晚用户 -2pt → 11）；header 按钮对齐、面板宽度下限、
    /// document 宽解算均引用此值。
    static let contentHorizontalInset: CGFloat = 11
    private let panel: BalancePanelView
    private let scrollView = NSScrollView()
    private var fadeObservers: [NSObjectProtocol] = []
    private var maximumHeight: CGFloat = 760
    private var contentSizeDirty = true
    /// 首次打开归位标记：只在 App 启动后第一次弹出时滚到最上方，
    /// 之后开关面板保留用户上次滚动位置
    private var didScrollToTopOnce = false
    /// 置顶浮窗模式：窗口宽高由用户 resize 把手控制（240–480 / 220–屏高），
    /// preferredContentSize 不再驱动窗口尺寸；视口宽高变化同步到 document view
    var isFloatingWindow = false {
        didSet {
            guard oldValue != isFloatingWindow else { return }
            resizeHandle.isHidden = !isFloatingWindow
            if isFloatingWindow {
                // 滚动锚定基准 = 转移时刻的 clip 高度：pin 动画首帧即可正确补偿
                if isViewLoaded {
                    lastFloatingClipHeight = scrollView.contentView.bounds.height
                }
                contentSizeDirty = true
                updateContentSize()
            } else {
                lastFloatingClipHeight = 0
            }
        }
    }
    /// 浮窗 resize 拖动结束（尺寸有变化）：上报最终窗口尺寸，AppDelegate 持久化
    var onFloatingSizeChanged: ((NSSize) -> Void)?
    /// 右下角 resize 把手：贴容器角落，仅浮窗模式显示（popover 尺寸由内容驱动）
    private let resizeHandle = PanelResizeHandle()

    init(panel: BalancePanelView) {
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        fadeObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        // 容器用 NSVisualEffectView 提供更深毛玻璃（.menu 比 .popover 默认更深，仍保留透明质感）
        let container = TintedVisualEffectView()
        container.material = .menu               // 比 popover 默认更深的毛玻璃
        container.blendingMode = .behindWindow   // 合成窗口背后内容，保持玻璃透明
        container.state = .active                // 跟随窗口激活状态
        container.isEmphasized = false
        // 外观统一走 Palette.panelAppearance：浅色主题开=强制浅色（即使系统深色）；
        // 渐变开=强制深色（深色玻璃+浅色字）；都关=跟随系统外观（浅色系统即原生
        // 浅色 Liquid Glass，文本走 Palette 动态色自动转黑灰）
        container.appearance = Palette.panelAppearance(lightTheme: panel.lightThemeEnabled)
        // 叠加半透明遮罩：颜色 = 设置窗口「面板背景色」（含 alpha），顶部原色 → 底部微透；
        // alpha 0 = 无遮罩（原生玻璃）
        let initialColors = Palette.containerColors(background: panel.panelBackgroundColor)
        container.tintColor = initialColors.top
        container.tintBottomColor = initialColors.bottom
        // 容器圆角与系统 popover 窗口对齐（10pt 连续曲率），裁掉遮罩层直角边缘
        container.wantsLayer = true
        container.layer?.cornerRadius = Palette.cardCornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .automatic
        // 面板是单列内容，横向滚动在任何情况下都无意义：elasticity 只压触控板弹性，
        // document 因浮窗旧尺寸/布局瞬态宽于视口时，滚轮横移仍能真实滚动——
        // 换上横向原点恒钳 0 的 clip view 根治（documentView 赋值保留现有 contentView）
        scrollView.contentView = NoHorizontalScrollClipView()
        // ⚠️ 换上的裸 NSClipView 默认 drawsBackground=true、底色 windowBackgroundColor——
        // 一整块不透明底把容器玻璃与遮罩全部盖住：这是面板遮罩开关 body 无反应、
        // 面板看着多一层嵌套的根因（GradProbe 实证遮罩层绘制正常、纯被此层盖住）
        scrollView.contentView.drawsBackground = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            // 滚动视口从安全区顶边开始：满尺寸内容（hasFullSizeContent）下容器会铺满
            // 整个 popover 窗口、顶边伸进三角箭头区，安全区顶边才是正文起始线。
            // 浮窗无箭头，安全区 inset 恒为 0，等价贴容器顶。
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // 左右：满尺寸内容下系统原有的左右边距带不再存在，由这里统一补回
            // （root 自身保留 7pt 正文缩进，9+7=16 视觉口径），正文不贴玻璃边缘
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                constant: Self.contentHorizontalInset),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                 constant: -Self.contentHorizontalInset),
        ])
        // header 不再属于 document view，避免随内容滚动；它仍复用 BalancePanelView
        // 中已有的更新时间、刷新状态动效和快速编译按钮。
        // header 底色层（2026-09-14 用户：「header 与自定义的面板背景色上端同色」）：纯色绘制，
        // 颜色 = 底色顶端色（与 body 渐变起点同值）。滚过的内容按该色（含 alpha）被染色遮挡。
        // 层级插在 scrollView 之上、header 之下（按钮不受影响）
        if let tint = panel.headerTintView {
            tint.translatesAutoresizingMaskIntoConstraints = false
            tint.color = initialColors.top
            container.addSubview(tint)
            NSLayoutConstraint.activate([
                tint.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
                tint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                tint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                tint.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor,
                                             constant: BalancePanelView.headerHeight),
            ])
        }
        if let header = panel.headerView {
            header.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
                header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                header.heightAnchor.constraint(equalToConstant: BalancePanelView.headerHeight),
            ])
        }
        // NSScrollView 的 document view 用 frame 承载完整内容；viewport 高度由 preferredContentSize 控制。
        panel.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = panel
        // 滚动位置 / 内容尺寸变化时刷新底部提示可见性
        scrollView.contentView.postsBoundsChangedNotifications = true
        panel.postsFrameChangedNotifications = true
        fadeObservers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            if let self, UserDefaults.standard.bool(forKey: "IBLayoutAutoTest") {
                let c = self.scrollView.contentView
                Logger.log(.layout, "[scroll] origin.y=\(String(format: "%.1f", c.bounds.origin.y)) clipH=\(String(format: "%.1f", c.bounds.height)) docH=\(String(format: "%.1f", self.panel.bounds.height))")
            }
            // 视口尺寸变化（popover/浮窗高度变化）：重新落地「顶边贴视口顶」不变量。
            // popover 高度变化分两步落地（文档先长/缩，窗口高度延迟百毫秒级才跟随），
            // eager 补偿写入的 origin 在旧视口合法、新视口下越界或不足——越界瞬间
            // clip 显示范围探出文档顶边，内容整体下坠 Δ，光标下方卡片身份错位，
            // AppKit 按错位几何补发 mouseEntered（上方卡片假亮）。视口每变一次就把
            // 不变量重新落地：变化前贴顶 → 回到新 legalMax；否则仅钳入合法范围
            // （不扰用户滚动位置）
            if let self {
                let clip = self.scrollView.contentView
                let size = clip.bounds.size
                if size != self.lastClipViewportSize {
                    let docH = self.panel.bounds.height
                    let legalBefore = max(0, docH - self.lastClipViewportSize.height)
                    let wasTopPinned = self.lastClipOriginY >= legalBefore - 0.5
                    let legalNow = max(0, docH - size.height)
                    let originY = clip.bounds.origin.y
                    let target = wasTopPinned ? legalNow : min(originY, legalNow)
                    self.lastClipViewportSize = size
                    if abs(target - originY) > 0.1 {
                        clip.scroll(to: NSPoint(x: 0, y: target))
                        self.scrollView.reflectScrolledClipView(clip)
                    }
                }
                self.lastClipOriginY = clip.bounds.origin.y
            }
            // 滚动后修正各卡片/按钮的 hover 状态（AppKit 不补发 enter/exit 事件）
            self?.syncHoverAfterScroll()
            // 几何稳定后再校准一次：popover 高度变化分两步落地，窗口落地后
            // 的补发事件可能落在上面即时同步之后
            self?.scheduleHoverSync()
        })
        // 浮窗 resize：视口宽高变化同步 document view（宽度自适应 + 高度拉伸防沉底）
        scrollView.contentView.postsFrameChangedNotifications = true
        fadeObservers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            guard let self, self.isFloatingWindow else { return }
            self.syncDocumentSizeToViewport()
        })
        // resize 把手贴容器右下角；22×22 命中区域（视觉斜线仍贴角落，
        // 自绘按 bounds.maxX/minY 锚定），拖拽 resize 由把手 mouseDown 驱动
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            resizeHandle.widthAnchor.constraint(equalToConstant: 22),
            resizeHandle.heightAnchor.constraint(equalToConstant: 22),
            resizeHandle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        resizeHandle.isHidden = true
        resizeHandle.onResizeEnded = { [weak self] size in
            self?.onFloatingSizeChanged?(size)
        }
        view = container
        // 渐变开关状态变化（update 同步时触发）：立即刷新遮罩绘制
        panel.onPanelGradientChanged = { [weak self] in
            self?.applyGradient()
        }
        // 区块折叠/展开后按新内容高度收缩 popover（与 viewWillAppear 同一套口径），
        // 避免 preferredContentSize 固定不变时根布局把其余区块拉伸填高
        panel.onContentChanged = { [weak self] in
            self?.invalidateContentSize()
        }
        updateContentSize()
    }

    /// 解除 popover 遗留在内容视图上的尺寸锁定（pin 转移时同步调用，不得延后）：
    /// 1) 摘除 'NSViewController.preferredContentSize.*' 宽高约束（优先级 501，
    ///    高于 windowSizeStayPut=500，可反向驱动窗口尺寸）；
    /// 2) 清零 preferredContentSize 属性本身——它是独立的尺寸驱动源：即使约束摘光、
    ///    contentViewController=nil、popover 已释放，只要属性非零，窗口布局时仍会
    ///    被同步回该尺寸（v2026.8.22.81→.82 最小复现：摘约束不清属性，setFrame 仍
    ///    被弹回 250x760；且清零必须在转移当次 runloop 内完成，延后经布局后尺寸
    ///    即被锁死，再清零无效）。
    /// 无副作用：本 VC 在浮窗生命周期内独占使用（浮窗模式 updateContentSize 不回写
    /// preferredContentSize），unpin 时随浮窗释放；popover 模式由预建新 VC 承担。
    func detachPreferredContentSizeConstraints() {
        preferredContentSize = .zero
        guard isViewLoaded else { return }
        let stale = view.constraints.filter {
            $0.identifier?.hasPrefix("NSViewController.preferredContentSize") == true
        }
        if !stale.isEmpty { NSLayoutConstraint.deactivate(stale) }
    }

    /// 在面板展示前设置当前屏幕允许的最大高度；超出的内容保留在 document view 中滚动查看。
    func setMaximumHeight(_ height: CGFloat) {
        let nextHeight = max(1, height)
        guard abs(maximumHeight - nextHeight) > 0.5 else { return }
        maximumHeight = nextHeight
        contentSizeDirty = true
        guard isViewLoaded else { return }
        updateContentSize()
    }

    private func invalidateContentSize() {
        contentSizeDirty = true
        updateContentSize()
    }

    private func updateContentSize() {
        guard contentSizeDirty else { return }
        contentSizeDirty = false
        if isFloatingWindow {
            // 浮窗模式先解除 root 底部上限做一次布局，把卡死在旧高度的 root 收回
            // 内容自然高度（详见 relaxRootToNaturalHeight 注释），否则 root 顶着
            // ≤ 上限时 .fill 会把多余高度灌进余额卡片组拉高卡片
            panel.relaxRootToNaturalHeight()
        }
        // 宽度直给（面板宽度唯一值 = panelWidth，内容适配宽度）：popover 宽恒定，
        // 不再由内容固有宽反推（2026-09-03 的 `- 20`/`- 40` 收窄机制就此废除——
        // 收窄效果由内容自适应压缩天然承接，宽度与内容解耦）。浮窗宽跟随视口。
        // 先落宽度再量高：热力图点距 = 版心可用宽/列数、内容高随宽度变，高度必须
        // 在目标宽度下解出。preferredContentSize 回写时把容器缩进加回
        // （与下方 chevronInset 把箭头带加回同理）。
        let documentWidth = isFloatingWindow
            ? max(PanelResizeHandle.minWidth - Self.contentHorizontalInset * 2,
                  scrollView.contentView.bounds.width)   // 浮窗窗口最小宽 − 容器缩进×2
            : Self.panelWidth - Self.contentHorizontalInset * 2
        if abs(panel.frame.width - documentWidth) > 0.1 {
            panel.frame.size.width = documentWidth
        }
        panel.layoutSubtreeIfNeeded()
        // fittingSize 只取高度（宽度已定数；热力图点阵 pitch/间隙随实际 bounds 等比
        // 自适应，点:隙:格比例不随宽度漂移）
        let contentSize = panel.fittingSize
        // 浮窗模式视口高于内容时把 document 拉伸到视口高：非翻转文档视图
        // 底部对齐，不拉伸会内容沉底、顶部空出一块；root 顶锚后底部留玻璃空区
        let contentHeight = isFloatingWindow
            ? max(contentSize.height, scrollView.contentView.bounds.height)
            : max(1, contentSize.height)
        let nextFrame = NSRect(x: 0, y: 0, width: documentWidth, height: contentHeight)
        let oldDocHeight = panel.frame.height
        if panel.frame != nextFrame { panel.frame = nextFrame }
        // 文档高度变化时补偿滚动原点（浮窗 syncDocumentSizeToViewport 同款顶边锚定口径）：
        // 非翻转文档内容顶边锚定，高度增减若保持 origin 不变，视口内内容会整体视觉位移 δ。
        // 随 δ 平移 origin 把可见内容钉回原位，clamp 到有效滚动范围
        let docHeightDelta = nextFrame.height - oldDocHeight
        if abs(docHeightDelta) > 0.1 {
            let clip = scrollView.contentView
            let maxOrigin = max(0, nextFrame.height - clip.bounds.height)
            let target = min(max(0, clip.bounds.origin.y + docHeightDelta), maxOrigin)
            if abs(target - clip.bounds.origin.y) > 0.1 {
                clip.scroll(to: NSPoint(x: 0, y: target))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        // 满尺寸内容（NSPopover.hasFullSizeContent）：容器铺满整个 popover 窗口、
        // 顶边伸进三角箭头区，safeAreaInsets.top = 箭头带高度。窗口高 = 可视内容高 +
        // 箭头带，所以这里要把箭头带加回去，否则内容会被箭头带吃掉同等高度。
        // 浮窗无箭头（safeAreaInsets 恒 0），加 0 等价。
        let chevronInset = isFloatingWindow ? 0 : view.safeAreaInsets.top
        let viewportHeight = min(contentHeight, max(1, maximumHeight - chevronInset)) + chevronInset
        // 滚动条始终隐藏（初始化 hasVerticalScroller=false，这里不再动态开启）
        // preferredContentSize 驱动的是容器（vc.view）尺寸：宽 = 正文宽 + 左右缩进
        // （scrollView 左右各内缩 16，见 loadView），不加回则正文被左右缩进挤窄 32pt
        let nextContentSize = NSSize(width: documentWidth + Self.contentHorizontalInset * 2,
                                     height: viewportHeight)
        // 浮窗模式不回写 preferredContentSize：窗口宽高由用户 resize 决定，
        // 避免内容变化（折叠/行数变化）把浮窗尺寸拉回内容高度
        if !isFloatingWindow, preferredContentSize != nextContentSize {
            preferredContentSize = nextContentSize
        }
        layoutProbe("ucs", force: true)
        // 折叠/展开、行数增减等高度变化落定后按光标位置校准 hover：
        // 无鼠标移动的几何变化 AppKit 补发的 enter/exit 不可靠（同滚动假 hover），
        // 立即同步一次清场 + 防抖收尾按屏幕坐标 hitTest 权威补亮
        syncHoverAfterScroll()
        scheduleHoverSync()
    }


    // MARK: - 布局探针（诊断余额卡片被拉伸问题）

    private var lastLayoutProbeAt = Date.distantPast

    func layoutProbe(_ tag: String, force: Bool = false) {
        guard isViewLoaded else { return }
        if !force, Date().timeIntervalSince(lastLayoutProbeAt) < 0.3 { return }
        lastLayoutProbeAt = Date()
        let winH = view.window.map { String(format: "%.1f", $0.frame.height) } ?? "nil"
        let clip = scrollView.contentView.bounds
        Logger.log(.layout, "[\(tag)] win=\(winH) clip=\(String(format: "%.1f@%.1f", clip.height, clip.origin.y)) pref=\(String(format: "%.1f", preferredContentSize.height)) float=\(isFloatingWindow)")
        panel.layoutProbe(tag)
    }

    /// 浮窗模式：document view 宽度跟随滚动视口（内容自适应宽度），
    /// 高度不低于视口（窗口拖高时拉伸 document，防止非翻转视图内容沉底），
    /// 拖矮时只要视口仍装得下自然内容就跟随缩矮（先吃掉 footer 上方弹性空白）。
    /// lastFloatingClipHeight：上次 clip 高度（浮窗 resize 时的滚动锚定基准）
    private var lastFloatingClipHeight: CGFloat = 0

    private func syncDocumentSizeToViewport() {
        let clip = scrollView.contentView
        // 视觉顶部锚定：非翻转文档中 clip 高度变化时，NSScrollView 默认保持
        // origin 不变（等价文档底部锚定）——pin 转移动画把窗口缩到保存尺寸时，
        // 顶部内容会被推出视口（内容视觉下滚）。这里补偿 origin.y 使可见区域
        // 顶边（origin.y + clipH）钉住同一文档位置：clip 变小 origin 增大、
        // clip 变大 origin 减小，并 clamp 到有效滚动范围。
        let newClipH = clip.bounds.height
        if lastFloatingClipHeight > 0.1, abs(newClipH - lastFloatingClipHeight) > 0.1 {
            let docH = panel.bounds.height
            if docH > newClipH + 0.5 {  // 仅滚动模式需要校正；全显模式 origin 恒 0
                let oldOrigin = clip.bounds.origin.y
                var target = oldOrigin - (newClipH - lastFloatingClipHeight)
                target = min(max(0, target), max(0, docH - newClipH))
                if abs(target - oldOrigin) > 0.1 {
                    clip.scroll(to: NSPoint(x: 0, y: target))
                    scrollView.reflectScrolledClipView(clip)
                }
            }
        }
        lastFloatingClipHeight = newClipH
        var f = panel.frame
        f.size.width = max(PanelResizeHandle.minWidth - Self.contentHorizontalInset * 2, clip.bounds.width)
        if f.height < clip.bounds.height - 0.5 {
            f.size.height = clip.bounds.height
        } else if let rootH = panel.rootViewRef?.frame.height,
                  f.height > clip.bounds.height + 0.5,
                  clip.bounds.height >= 10 + rootH + 11 {
            // 拖矮方向：视口仍装得下自然内容（root 自然高 + 顶距 + 底边距 11，
            // 与 build() 的 rootTop/底部 cap 常量同源；root 未被拉伸、
            // frame 高即自然高）时，document 跟随视口缩矮——优先收缩 root 与
            // 底边的弹性空白、全程保持全显；空白耗尽才走上方校正的
            // 顶部锚定滚动裁切
            f.size.height = clip.bounds.height
        }
        guard panel.frame != f else { return }
        panel.frame = f
    }

    /// 首次打开把内容归位到最上方：文档视图非翻转（原点在左下），clip view 默认
    /// origin (0,0) 对应内容底部，不显式滚动会先展示底部内容。
    /// 目标点必须按「文档高度 − 视口高度」精确计算：直接滚 (0, docHeight) 会把
    /// origin 推出有效范围，视口整个落在文档上方外部 → 面板只剩背景（内容空白）；
    /// scroll(to:) 并不会自动把越界点收敛到最大滚动位。
    private func scrollToTopIfNeeded() {
        guard !didScrollToTopOnce else { return }
        didScrollToTopOnce = true
        scrollToTopNow()
    }

    private func scrollToTopNow() {
        guard let doc = scrollView.documentView else { return }
        view.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let clipHeight = clip.bounds.height
        guard clipHeight > 0 else {
            // 布局尚未定稿（popover 还没把容器尺寸应用下来，clip 高度为 0）：
            // 下一 runloop 重试，避免此时按满高计算 origin 造成越界空白
            DispatchQueue.main.async { [weak self] in self?.scrollToTopNow() }
            return
        }
        clip.scroll(to: NSPoint(x: 0, y: max(0, doc.bounds.height - clipHeight)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 滚动后修正 hover：内容移动后 AppKit 不补发 mouseEntered/mouseExited，
    /// 用 AppKit hitTest 判定光标当前所在视图（与系统 tracking 同源的命中机制，
    /// popover 与无边框置顶浮窗中都可靠——各视图自行 convert 判定曾在浮窗中
    /// 持续误判造成假 hover），遍历面板视图树按判定结果同步：命中者进入、
    /// 其余（含滚出光标下方的）全部退出
    private func syncHoverAfterScroll() {
        guard isViewLoaded, let window = view.window else { return }
        let p = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        var node = window.contentView?.hitTest(p)
        var target: PanelScrollHoverSync?
        while let v = node {
            if let s = v as? PanelScrollHoverSync { target = s; break }
            node = v.superview
        }
        func walk(_ v: NSView) {
            if let syncable = v as? PanelScrollHoverSync {
                syncable.syncHoverState(syncable === target)
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(panel)
    }

    /// 几何稳定后的 hover 校准（防抖 0.15s）：区块折叠/展开、行数增减等内容位移后
    /// AppKit 补发的 enter/exit 不可靠（同滚动假 hover），且 popover 高度变化分两步
    /// 落地——防抖到几何不再变化后按光标 hitTest 权威同步。只重排日程不叠加调用：
    /// 每次触发重置计时，几何连续变化时只在停稳后执行一次
    private var pendingHoverSync: DispatchWorkItem?
    /// 视口尺寸（clip bounds.size）/ 原点上一次取值：尺寸变化时据上一次原点
    /// 判断「变化前是否顶边贴定」，据此把不变量重新落地（见观察器内注释）
    private var lastClipViewportSize: CGSize = .zero
    private var lastClipOriginY: CGFloat = 0
    /// 上一次布局读到的安全区顶部 inset（popover 顶部三角箭头带高度；浮窗恒 0）。
    /// 初值 -1 保证首次布局必定触发一次带箭头带的内容高度重算。
    private var lastSafeAreaTop: CGFloat = -1

    private func scheduleHoverSync() {
        pendingHoverSync?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.syncHoverAfterScroll()
        }
        pendingHoverSync = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// [GradProbe] 探针去重：状态串不变不重复记日志（viewDidLayout 每次布局都会调用）
    private var gradProbeKey = ""

    /// 按当前「面板背景色」刷新背景遮罩：外观随浅色主题开关走；遮罩色就是用户选的那个色
    /// （含 alpha，alpha >0 即生效；0 = 无遮罩，露出容器原生毛玻璃）
    private func applyGradient() {
        guard let container = view as? TintedVisualEffectView else { return }
        // 外观随开关即时切换：统一走 Palette.panelAppearance（浅色强制浅色，其余跟随系统）
        container.appearance = Palette.panelAppearance(lightTheme: panel.lightThemeEnabled)
        let colors = Palette.containerColors(background: panel.panelBackgroundColor)
        container.tintColor = colors.top
        container.tintBottomColor = colors.bottom
        container.tintGradientStartY = 0
        // header 底色层跟随底色顶端色（底色 / 浅色主题变化即时生效）
        panel.headerTintView?.color = colors.top
        // [GradProbe] 底色/外观/取色/遮罩几何任一变化才记一条
        let probe = "[GradProbe] applyGradient vc=\(ObjectIdentifier(self).hashValue) bg=\(panel.panelBackgroundColor.hexString) dark=\(container.effectiveAppearance.isDark) bodyTop=\(colors.top != nil) bodyBottom=\(colors.bottom != nil) \(container.tintProbe)"
        if probe != gradProbeKey {
            gradProbeKey = probe
            Logger.log(.layout, probe)
        }
        // 自建顶层窗口不挂在本视图树上、拿不到容器 appearance，翻渐变/浅色开关时按全局
        // 镜像重染：非阻塞弹窗（3D 硬币）+ 设置窗口（「主题外观」pane 就在那，不重染的话
        // 当场翻「浅色主题」这个窗口毫无反应，要关掉重开才变）
        GlassModalShell.refreshActiveNonModalAppearance()
        SettingsWindowController.shared.refreshAppearance()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // 让 popover 按内容实际高度撑开；超过屏幕的部分由 scrollView 承载。
        updateContentSize()
        // App 启动后首次弹出：内容归位到最上方（默认会显示底部）
        scrollToTopIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 面板关闭时不保证补发 mouseExited：打开时按光标位置同步，
        // 清掉上一次会话残留的 hover 高亮（光标就在卡片上时则正确点亮）
        syncHoverAfterScroll()
        // 打开面板 0.5s 后统一下发隐藏期间挂起的数值（有变化从旧值滚到新值）
        panel.scheduleOpenReroll()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        panel.dismissUsageHistoryPopover()
        panel.clearTokensHoverOverride()
        panel.dismissSubAccountTip()
        panel.cancelOpenReroll()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 布局变化后同步背景遮罩（顶部全透明 → 底部深灰渐变 / 单色深灰）
        applyGradient()
        // popover 满尺寸内容下，顶部三角箭头带（= safeAreaInsets.top）要等视图入窗
        // 后才落地，而 macOS AppKit **没有** safeAreaInsetsDidChange 回调（只有 iOS 有）。
        // 用最近一次布局的 inset 做比对：变化即重算内容高度，把箭头带补回
        // preferredContentSize，否则面板可视高度会被箭头带吃掉一截。
        // 浮窗无箭头（inset 恒 0），命中「无变化」直接跳过。
        let inset = view.safeAreaInsets.top
        if abs(inset - lastSafeAreaTop) > 0.1 {
            lastSafeAreaTop = inset
            contentSizeDirty = true
            updateContentSize()
        }
        layoutProbe("didLayout")
    }
}

/// 余额平台标识与默认顺序：面板卡片排序与菜单栏条目共用。
enum BalancePlatform: String, CaseIterable {
    case deepSeek = "ds"
    case bigModel = "zhipu"
    case qwen
    case zcode
    case codex
    case trae
    case workBuddy = "wb"

    static let defaultOrder: [String] = allCases.map(\.rawValue)

    /// 归一化已保存的顺序：过滤未知平台，新增平台追加到末尾。
    static func normalizedOrder(from saved: [String]) -> [String] {
        let known = Set(defaultOrder)
        let normalized = saved.filter { known.contains($0) }
        return normalized + defaultOrder.filter { !normalized.contains($0) }
    }
}

final class BalancePanelView: NSView {

    /// 固定在滚动视口顶部的 header 高度。
    /// 2026-09-10 用户指定 +3pt（原 30）。header 内部元素（更新时间 /
    /// 退出按钮）锚在 header **顶** + `panelTopPadding + panelBarHeight/2`，不随此值移动 →
    /// 改大只会让分割线与正文整体下移、header 下缘留白变多。
    static let headerHeight: CGFloat = 33
    /// 由布局构建，随后由 BalancePanelViewController 提升到滚动容器上层固定显示。
    var headerView: NSView?
    /// header 右上角刷新周期饼图按钮（build() 创建；AppDelegate 注入周期数据源与间隔回调）
    var refreshPieButton: RefreshPieButton?
    /// header 原右侧分段按钮组（「主题调教 + 平台开关」）2026-09-12 整组移除：
    /// 两个入口都迁进设置窗口（「主题外观」「平台」两个 pane）；右侧现仅存刷新周期饼图按钮。
    /// header 底色层（2026-09-14 用户「与自定义的面板背景色上端同色」）：纯色绘制层，
    /// 颜色 = 底色顶端色 —— 视觉上是面板背景自身的延续，同时挡住滚过 header 的内容。
    /// （同日历史：`.menu` 毛玻璃 + 顶色遮罩版有色块感 → 只模糊不着色版被「回滚」→ 现在这版）
    var headerTintView: TintOverlayView?

    // MARK: - header 图标拖动换位（逻辑在 PanelDrag.swift）

    /// 参与排序的 header 图标 id 固定清单（= 持久化顺序键；新增 header 按钮须
    /// 同步此清单与 build() 的注册表字面量）
    /// 2026-09-16 加 "platforms"（第六颗：原「平台开关」分段控件 2026-09-12 撤出 header
    /// 迁进设置窗口，今按要求在 header 上补一个直达该 pane 的入口）
    static let headerButtonIdentifiers = ["quit", "settings", "refresh", "github", "cockpit", "platforms"]
    /// id → 按钮视图（build() 填充）
    var headerButtonRegistry: [String: NSView] = [:]
    /// header 图标槽位表：下标 = 槽位序号（0..<headerButtonSlotCount），值 = 该槽的按钮 id
    /// （nil = 空位）。2026-09-14 起按钮可拖到任意槽位且**允许留空** —— 空位是合法状态，
    /// 所以不能用「紧凑 id 序」表达，必须按下标落盘（见 PanelDrag.savedHeaderButtonSlots）。
    var headerButtonSlots: [String?] = []
    /// 拖动中的落点槽位（nil = 无拖拽会话或尚未落到任何槽），供空位指引层高亮
    var headerButtonDropSlot: Int?
    /// 拖动起手时指针相对按钮左缘的偏移（pt）：换槽时保持不变，抓哪儿就还是抓哪儿
    var headerDragGrabOffsetX: CGFloat = 0
    /// 拖动起手时的槽位表**快照**（空 = 无拖拽会话）。换槽每次都从这份快照重算，
    /// 而不是在实时槽位表上反复改 —— 这是「其他按钮不要动」的关键：
    /// 落点是空位 → 拖动的按钮搬过去、起手槽留空；落点被占用 → 中间那一段（含被占位者）
    /// 沿**拖动方向的反方向**各退一位，由起手槽吸收（其余按钮一律不动）。
    /// 若在实时表上连锁交换，拖过 B、C、D 会把三颗全带偏
    var headerDragOriginSlots: [String?] = []
    /// 拖动时的槽位指引层（build() 填充，见 Controls.swift HeaderSlotGuidesView）
    var headerSlotGuidesView: HeaderSlotGuidesView?
    /// header 图标 leading 约束（槽位表变化时整体换装，见 PanelDrag.applyHeaderButtonSlots）
    var headerButtonChainConstraints: [NSLayoutConstraint] = []
    /// 正在拖动的 header 图标 id（nil = 无拖拽会话）
    var draggingHeaderButtonID: String?

    // MARK: - 对外回调（由 AppDelegate 接线到现有处理逻辑）
    // ⚠️ 2026-09-12 移除面板「设置」板块、2026-09-13 移除「操作」板块后，两批专属回调
    //    （onToggleAutoCheckin / onSetInterval / onToggleValueScrollPreview / onCheckForUpdate /
    //    onRunUpdateDemo / onToggleUpdateAutoCheck；onAddWbAccount / onAddZcodeAccount /
    //    onAddCodexAccount / onCollectTraeAccount / onSetApiKey / onAbout / onShowCoinDemo /
    //    onManualCheckin / onShowCheckinHistory / onShareWbHistory）一并删除 —— 这些入口
    //    现在只走设置窗口 / 状态栏菜单（不经过面板），Cockpit 保留（header 第五颗）。

    var onOpenCockpit: (() -> Void)?
    /// 渐变开关状态变化通知（update 同步时触发，VC 据此刷新遮罩绘制）
    var onPanelGradientChanged: (() -> Void)?
    var onQuit: (() -> Void)?
    /// 打开项目 GitHub 页面（header 左侧按钮组第四颗触发）
    var onOpenGitHub: (() -> Void)?
    /// 打开 SwiftUI 设置窗口（header 左上角退出按钮右侧的设置按钮触发）
    var onOpenSettings: (() -> Void)?
    /// 打开设置窗口并直达「平台」pane（2026-09-16 新增的 header 平台开关按钮触发：
    /// 原「平台开关」分段控件 2026-09-12 从 header 撤出后，用户要求补回一个直达入口）
    var onOpenPlatformSettings: (() -> Void)?
    /// header 右上角刷新周期饼图按钮：选中刷新间隔（秒），AppDelegate 落到 applyRefreshInterval
    var onChangeRefreshInterval: ((TimeInterval) -> Void)?
    /// header 右上角刷新周期饼图按钮：左键点击立即手动刷新（顺带重置自动周期与饼图）
    var onManualRefresh: (() -> Void)?
    /// 右上角 pin 按钮：切换面板置顶常驻（内容转移至无边框 NSPanel 浮动窗口，
    /// 无箭头、浮层层级、可自由拖动；取消置顶时装回 popover）
    var onTogglePin: (() -> Void)?
    /// 置顶状态（pin ↔ pin.fill 图标切换）
    private(set) var panelPinned = false
    // 余额卡片点击回调：DeepSeek/ZhiPu/Qwen 打开网页，TRAE / WorkBuddy / ZCode 启动应用
    var onClickDeepSeek: (() -> Void)?
    var onClickZhiPu: (() -> Void)?
    var onClickQwen: (() -> Void)?
    var onClickTrae: (() -> Void)?
    var onClickWorkBuddy: (() -> Void)?
    /// WorkBuddy 非当前账号卡片点击：传入 uid，触发切号重启
    var onSwitchWbAccount: ((String) -> Void)?
    /// TRAE 非当前账号卡片点击：传入 uid，触发切号重启
    var onSwitchTraeAccount: ((String) -> Void)?
    /// ZCode 卡片点击：打开 ZCode 应用
    var onClickZcode: (() -> Void)?
    /// Codex 卡片点击：打开 Codex 应用
    var onClickCodex: (() -> Void)?
    /// ZCode 非当前账号卡片点击：传入 uid，触发切号重启
    var onSwitchZcodeAccount: ((String) -> Void)?
    /// Codex 非当前账号卡片点击：传入 uid，触发切号重启
    var onSwitchCodexAccount: ((String) -> Void)?
    /// 右键点击余额卡片：传入卡片 menuBarId 和事件（用于弹出「在菜单栏显示」上下文菜单）
    var onRightClickCard: ((String, NSEvent) -> Void)?
    /// 平台卡片排序完成：通知 AppDelegate 立即刷新菜单栏标题顺序
    var onPlatformOrderChanged: (([String]) -> Void)?
    /// 内容高度变化回调（区块折叠/展开后由面板调用）：VC 据此重算 preferredContentSize，
    /// 让 popover 高度随内容收缩，其余区块保持自然高度不被拉伸
    var onContentChanged: (() -> Void)?

    // MARK: - 余额展示控件

    let offlineBanner = NSTextField(labelWithString: "⚠︎ 离线，恢复网络后自动刷新")
    // WorkBuddy 多账号卡片容器（动态重建，账号列表变化时刷新）
    var wbCardsContainer: NSStackView!
    private var wbCardEntries: [CardEntry] = []
    private var wbCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）
    // DeepSeek 单账号卡片容器（走多号卡片管线，与 ZCode/Codex 同构）
    var dsCardsContainer: NSStackView!
    private var dsCardEntries: [CardEntry] = []
    private var dsCardUids: [String] = []
    private weak var dsCardRef: NSView?     // DeepSeek 卡片引用，各平台当前账号卡等高基准
    // ZhiPu 单账号卡片容器（同 DeepSeek 管线，置于其后）
    var zhipuCardsContainer: NSStackView!
    private var zhipuCardEntries: [CardEntry] = []
    private var zhipuCardUids: [String] = []
    // Qwen 单账号卡片容器（同 DeepSeek 管线，置于 ZhiPu 下方）
    var qwenCardsContainer: NSStackView!
    private var qwenCardEntries: [CardEntry] = []
    private var qwenCardUids: [String] = []

    /// 单个多号卡片的控件引用（update 时直接赋值，无需重建；WB / TRAE / ZCode 共用）。
    /// 非当前账号的 dots 为占位实例（未加入视图层级，更新时跳过）。
    /// 副标题完整段落数据盒（引用类型）：apply 持续写入最新完整文案；账号条换入/离场
    /// 闭包据此改写精简文案/恢复——跨闭包共享用引用，值类型数组做不到
    final class ExpireSegBox {
        var full: [String] = []
    }

    /// hover 账号条换入期间的副标题精简（2026-09-06 用户指定）：倒计时三段
    /// ["剩余","26天","14:35"] → ["26天"]；无天段保留时间段；单段文案不精简
    private func compactExpireSegments(_ segs: [String]) -> [String] {
        guard segs.count > 1 else { return segs }
        if let day = segs.first(where: { $0.contains("天") }) { return [day] }
        return [segs.last!]
    }

    private struct CardEntry {
        let uid: String
        let valueView: RollingNumberView   // 余额数值（逐位垂直滚动）
        let titleLabel: FadeableTextField  // 平台名主标题（hover 字重动画载体）
        let dots: UsageDots
        let segmentLabels: [NSTextField] // 到期副标题分段 labels（icon + 段落，段间 3pt stack 布局；空数组 = 无第二行）
        /// 到期行图标（随 expired 状态变色，2026-08-27 起统一副前景灰）。
        /// 数组而非单值：TRAE 卡放**三个** xmark（2026-09-15 用户「写 xmark xmark xmark 不要空格」），
        /// 其余平台恒 1 个
        let expireIcons: [NSImageView]
        let badgeView: NSView          // 签到失败角标（icon 右上角，无签到平台恒隐藏）
        let iconView: NSImageView      // 平台 icon
        let statusRing: CardTaskStatusRingView?  // 任务状态光环（Agent 卡挂任务态 / API 卡挂脉冲进行中态，其余 nil）
        let menuBarDot: NSView         // 菜单栏显隐小白点（icon 下方 4pt，inMenuBar 时点亮）
        var lastValue: String = ""     // 上次应用的余额文本（数字滚动判据；空 = 首次赋值直接显示）
        var subAccountsStrip: NSStackView? = nil // Agent 卡 hover 时替换点阵的其余账号条（icon+积分）
        var subValueLabels: [NSTextField] = []   // 其余账号条内积分数值 label（apply 随刷新更新文本）
        var subItems: [SubAccountItemView] = []  // 其余账号条本体（apply 同步 tokenInvalid 等悬浮气泡数据）
        var chipTipBox: ChipTipBox? = nil        // 当前账号积分 chip 气泡数据盒（apply 随刷新更新昵称/签到徽章）
        var segBox: ExpireSegBox? = nil          // 副标题完整段落数据盒（账号条换入期间改写精简文案/离场恢复）
        var dotsAlwaysVisible = false            // 长进度卡片：进度条常驻，不随账号条换入隐藏
        var metaChangeLabel: NSTextField? = nil  // 副标题右侧 meta：24h 变化量（箭头附件+数值富文本，apply 随刷新重建；nil = 不挂）
    }

    /// 各平台卡片差异配置（icon / 标题 / 签到行 / 到期行 / reward 兜底）
    private struct CardStyle {
        let icon: String
        let name: String
        let platformID: String
        let iconSize: CGFloat           // 当前账号 icon 尺寸（全平台统一，见下方注释）
        let checkin: Bool               // 是否显示签到信息行（WB / TRAE）
        let showsExpire: Bool           // 是否显示第二行副标题（ZCode/Codex 到期倒计时、DeepSeek 日常额度）
        let expireIconSymbol: String?   // 第二行图标（nil = 纯文本行；重置倒计时按周期选 "clock-stop-w"=7天 / "clock-stop-m"=月，周期不确定的倒计时（ZCode 套餐到期）用 "clock-stop"，DS/ZhiPu 为 "external-link"，均 bundle SVG）
        let menuBarIdPrefix: String     // 菜单栏 item id 前缀："trae:" / "wb:" / "zcode:"
        // iconSize 已统一（2026-08-31 用户拍板）：所有 API / Agent 卡 icon 宽高一律 24pt
        // （2026-09-02 用户要求 +1pt → 25pt，与图标列宽同宽；
        // 2026-09-05 用户要求 +15% → 27.75pt，与图标列宽同宽）。
        // 非 Agent 平台（DS/ZhiPu/Qwen）恒单账号、Agent 平台非当前账号走 hover 账号条，
        // 不再存在「非当前账号小卡」，secondary 尺寸字段已随死代码清理移除
        static let wb    = CardStyle(icon: "workbuddy", name: "WorkBuddy", platformID: "wb", iconSize: 27.75, checkin: true, showsExpire: true, expireIconSymbol: "clock-stop-m", menuBarIdPrefix: "wb:")
        static let trae  = CardStyle(icon: "trae-color", name: "Trae", platformID: "trae", iconSize: 27.75, checkin: true, showsExpire: true, expireIconSymbol: "xmark", menuBarIdPrefix: "trae:")
        static let zcode = CardStyle(icon: "zhipu", name: "ZCode", platformID: "zcode", iconSize: 27.75, checkin: false, showsExpire: true, expireIconSymbol: "clock-stop", menuBarIdPrefix: "zcode:")
        static let codex = CardStyle(icon: "codex", name: "Codex", platformID: "codex", iconSize: 27.75, checkin: false, showsExpire: true, expireIconSymbol: "clock-stop-m", menuBarIdPrefix: "codex:")
        static let ds    = CardStyle(icon: "deepseek", name: "DeepSeek", platformID: "ds", iconSize: 27.75, checkin: false, showsExpire: true, expireIconSymbol: "external-link", menuBarIdPrefix: "")
        // ZhiPu：与 ds 同构的单账号卡（uid 恒 "zhipu" 无前缀，右键菜单 id 恰为 MenuBarPrefix.zhipu）；副标题带 external-link 图标
        static let zhipu = CardStyle(icon: "zhipu", name: "ZhiPu", platformID: "zhipu", iconSize: 27.75, checkin: false, showsExpire: true, expireIconSymbol: "external-link", menuBarIdPrefix: "")
        // Qwen（千问 Token Plan）：单账号卡，值为周剩余百分比；副标题为 7 天限额重置倒计时（clock-stop-w 图标）
        static let qwen = CardStyle(icon: "qwen", name: "Qwen", platformID: "qwen", iconSize: 27.75, checkin: false, showsExpire: true, expireIconSymbol: "clock-stop-w", menuBarIdPrefix: "")
    }

    // TRAE 多账号卡片容器（动态重建，账号列表变化时刷新）
    var traeCardsContainer: NSStackView!
    private var traeCardEntries: [CardEntry] = []
    private var traeCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）

    // Agent 卡片组容器（统一背景 + 圆角，子卡片透明）
    var balanceGroupContainer: NSStackView!
    // API 卡片组容器（DeepSeek/ZhiPu/Qwen，样式与 Agent 组一致）
    var apiGroupContainer: NSStackView!
    /// 平台容器 == 组宽：单列布局下容器撑满组宽，数值/点阵才能贴右对齐
    /// group 省略时锚定 Agent 组（API 组容器需显式传 apiGroupContainer）
    func pinPlatformWidth(_ container: NSStackView, in group: NSStackView? = nil) {
        container.widthAnchor.constraint(equalTo: (group ?? balanceGroupContainer).widthAnchor).isActive = true
    }

    /// 余额卡片组视觉底边距面板顶部的距离（背景渐变从此处开始；panel 非 flipped，
    /// 视觉底部 = frame.minY，故 = bounds.height - minY；布局前为 0 = 渐变暂从顶部开始）
    var balanceSectionBottomY: CGFloat {
        bounds.height - balanceGroupContainer.frame.minY
    }

    // ZCode 多账号卡片容器（动态重建，账号列表变化时刷新）
    var zcodeCardsContainer: NSStackView!
    private var zcodeCardEntries: [CardEntry] = []
    private var zcodeCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）
    var codexCardsContainer: NSStackView!
    private var codexCardEntries: [CardEntry] = []
    private var codexCardUids: [String] = []
    /// 平台卡片顺序：只在图标拖拽完成后写入，刷新余额不会改变用户排序。
    var platformOrder: [String] = []
    var platformCards: [String: NSView] = [:]
    var draggingPlatform: String?
    /// 当前实际被拖动的账号卡片；用于占位内容，组幽灵的源视图单独记录。
    weak var draggingCard: NSView?
    weak var draggingGhostSourceView: NSView?
    weak var draggingGhostView: NSView?
    var draggingGhostOffset = NSPoint.zero
    /// 当前拖动平台内的其他账号小卡片及其原始内容透明度。
    var draggingSiblingCardOpacities: [(card: HoverCard, opacity: Float)] = []
    /// 拖动期间被隐藏的 icon 状态光环（CardTaskStatusRingView，2026-09-06 用户指定
    /// 「拖动卡片时 icon 的状态层不显示」）：截图前隐藏（幽灵/原卡同步生效），拖拽结束恢复
    var draggingHiddenStatusRings: [CardTaskStatusRingView] = []
    let updatedLabel = NSTextField(labelWithString: "")
    /// 刷新动效状态：true 时 header 的「更新于」区域脉冲显示「刷新中…」
    /// setter 私有，仅 setRefreshing(_:) 可写；getter internal，供 AppDelegate 调试日志用。
    private(set) var isRefreshing: Bool = false
    /// 相同快照只同步一次，避免菜单栏标题刷新时重复遍历和重排整个面板。
    private var lastSnapshot: PanelSnapshot?

    // MARK: - 设置/操作控件

    /// 日/周用量区块：内容行动态重建（随快照变化）
    let usageContentStack = NSStackView()
    /// 用量数据未变化时复用已有行，避免每次余额刷新都销毁/重建 NSView。
    private var renderedUsageRows: [UsageRowSnapshot] = []
    var usageCardRef: NSView?
    var usageTitleRef: NSView?
    /// 平台 id → 用量行视图（拖拽排序时复用实例做位移动画）
    var usageRowViews: [String: NSView] = [:]
    /// 表头行（1小时 / 今日 / 本周 列名），排序时保持在最上
    var usageHeaderRowRef: NSView?
    /// 用量行 hover 右侧一周趋势 popover（单实例复用，避免每行创建窗口）。
    var usageHistoryPopover: NSPopover?
    var usageHistoryController: UsageHistoryPopoverController?
    /// 固定定位锚点：用量标题，而不是当前 hover 的数据行。
    weak var usageHistoryAnchor: NSView?
    /// hover 锁定的用量行（子面板打开期间保持高亮；关闭/换行时解锁）
    weak var usageHistoryAnchorRow: HoverRowView?
    /// 位于主面板内部的透明定位点，保证 NSPopover 始终收到有效的 bounds。
    let usageHistoryPositionAnchor = UsageHistoryPopoverAnchorView(frame: .zero)
    var usageHistoryRowHovered = false
    var usageHistoryChartHovered = false
    var usageHistoryCloseTask: DispatchWorkItem?
    /// 主面板「Token」板块：内嵌 ZCode / WorkBuddy 卡片 hover 同款内容（数据到达前整块隐藏）
    let tokenContentStack = NSStackView()
    var tokenTitleRef: NSView?
    var tokenCardRef: NSView?
    /// 内嵌 Token 内容视图单实例（与卡片 hover 共用 TokensPanelView；
    /// 显示平台 = hover 中的 Agent 卡片优先，未 hover 取组顶平台，由 refreshInlineTokens 动态解析）
    var inlineTokenView: TokensPanelView?
    /// Token 板块低频刷新定时器（间隔 = store 缓存 TTL，fetch 只回缓存零读取）
    var inlineTokensRefreshTimer: Timer?
    /// hover 中的 Agent 卡片 Token 数据源（ZCode / WorkBuddy / Codex；nil = 未 hover，板块回落组顶平台）
    var hoverTokensSource: TokensPanelSource?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 外观切换就地换肤（不重建卡片）：① 品牌 Clear 系图标随生效外观换版
        //（ClearDark ↔ ClearLight，2026-09-06 用户导出浅色资产，按 identifier 标签
        // brandIcon:<键> 识别）；② 预设边框色/hover 渐变经 .cgColor 落盘会定格当时
        // 外观：重解算（hover 中 borderWidth > 0 的层跳过——动画路径每次取当前值。
        // 现仅用量行等仍走 layer 边框；HoverCard 的 hover 材质（渐变背景块 + 描边框）
        // 已由容器共享（HoverMaterialHost，挂 root），由 HoverCard
        // .viewDidChangeEffectiveAppearance 转发宿主 refreshAppearance 重解算，
        // 本轮回写对其无效）。
        let appearance = effectiveAppearance
        var stack = subviews
        while let v = stack.popLast() {
            if let iv = v as? NSImageView, let id = iv.identifier?.rawValue,
               id.hasPrefix("brandIcon:") {
                applyBrandIcon(iv, key: String(id.dropFirst("brandIcon:".count)),
                               appearance: appearance)
            }
            if let layer = v.layer, layer.borderWidth == 0 {
                appearance.performAsCurrentDrawingAppearance {
                    layer.borderColor = Palette.hoverBorderNormal.cgColor
                }
            }
            stack.append(contentsOf: v.subviews)
        }
        // 渐变开时遮罩明暗随生效外观：系统深浅切换重刷遮罩，并同步用量趋势子面板配色
        onPanelGradientChanged?()
        syncUsageHistoryPanelBackground()

    }

    /// 品牌 icon 取版深浅判定：生效外观 ⊕ 图标深浅互换开关（开启即在生效外观上反向取版）
    func brandIconDark(for appearance: NSAppearance) -> Bool {
        appearance.isDark != iconThemeSwapEnabled
    }

    /// 单个品牌 icon 视图就地换图：取图与落图统一收口在 `applyBrandIconImage`
    ///（无边框 = SVG 原图（按互换后深浅档的主前景色着色）/ 默认 = Icon Composer PNG，
    /// 含缺资产回退、identifier 与辉光 maskImage）
    private func applyBrandIcon(_ iv: NSImageView, key: String, appearance: NSAppearance) {
        guard iv.bounds.width > 0 else { return }
        applyBrandIconImage(iv, iconName: key, size: iv.bounds.size, appearance: appearance)
    }

    /// 图标深浅互换 / 无边框图标开关变化：遍历视图树就地换图（与外观切换钩子同一换图逻辑）
    func swapBrandIconsInPlace() {
        var stack = subviews
        while let v = stack.popLast() {
            if let iv = v as? NSImageView, let id = iv.identifier?.rawValue,
               id.hasPrefix("brandIcon:") {
                applyBrandIcon(iv, key: String(id.dropFirst("brandIcon:".count)),
                               appearance: effectiveAppearance)
            }
            stack.append(contentsOf: v.subviews)
        }
    }

    /// 用量行实际宽度（列宽自动分配的预算基准）：用量卡片 horizontalPadding 0、行撑满
    /// 卡片，卡片又撑满 root，故 = document 宽 − root 左右正文缩进 7×2。
    /// 2026-09-03 根治压缩：旧固定 260 预算在窄面板（document < 内容自然宽）下让列宽
    /// 总和超出实际行宽，Auto Layout 被迫破坏约束（卡片宽随数据漂移），hover 渐变层
    /// （frame 首次 hover 定格）随之与卡片错位——预算改按实际宽度现算后自然宽 ≤ document。
    private var usageRowWidth: CGFloat { bounds.width - 14 }
    /// 当前自动分配的两列宽（每次行重建前按内容重算；此为初值兜底）
    var usageColWidths = (week: CGFloat(50), today: CGFloat(44))

    /// 按实际内容自动分配两列宽度：每列 = max(表头, 全部行文本) 宽 + 6pt 呼吸；
    /// 名称列与固定开销先扣，剩余预算不够时按比例收窄（列宽下限保 5 字符值，
    /// 名称列再不够由自身截断兜底）。字体度量取当前 uiFont。
    private func computeUsageColumnLayout(_ rows: [UsageRowSnapshot]) {
        // 度量字体与行渲染同源（小表格口径），避免测量/渲染字重不一致
        let valueFont = SmallTable.rowFont(monoDigits: true)
        let headerFont = SmallTable.titleFont()
        func w(_ s: String, _ f: NSFont) -> CGFloat {
            s.size(withAttributes: [.font: f]).width
        }
        var today = w("1D", headerFont)
        var week = w("1W", headerFont)
        for r in rows {
            today = max(today, w(r.todayText, valueFont))
            week = max(week, w(r.weekText, valueFont))
        }
        today += 6; week += 6
        let nameFont = SmallTable.rowFont()
        let nameW = rows.map { w($0.name, nameFont) }.max() ?? 40
        // 固定开销：左右 inset 16 + icon 14 + icon↔名 4 + 名↔数值区 6 + 两个列间隙 16
        let budget = usageRowWidth - SmallTable.horizontalInset * 2 - 14 - 4 - 6
            - 2 * SmallTable.columnSpacing - nameW
        let total = today + week
        if total > budget, total > 0 {
            let scale = budget / total
            // 列宽下限 38/40：按实际行宽保住 5 字符值不截断
            today = max(38, today * scale)
            week = max(40, week * scale)
        }
        usageColWidths = (week: week, today: today)
    }

    // 用量表样式口径统一走 SmallTable（小表格，与 Token 面板共用）
    var usageColumnSpacing: CGFloat { SmallTable.columnSpacing }
    var usageHorizontalInset: CGFloat { SmallTable.horizontalInset }
    /// 用量行行内垂直缩进（行间距 0，每行上下统一缩进 3pt）
    var usageRowTopInset: CGFloat { SmallTable.rowInset }
    var usageRowBottomInset: CGFloat { SmallTable.rowInset }

    /// 面板底色遮罩色状态（update 同步；VC 读取决定遮罩配色）。
    /// 初值 = 出厂默认（`factoryPanelBackground`，2026-09-17 固化），实际值由 update(config:) 覆盖
    private(set) var panelBackgroundColor: PanelBackgroundColor = .factoryPanelBackground
    /// 遮罩底端不透明度（update 同步；顶端用 panelBackgroundColor.alpha，两端各自独立）
    private(set) var panelBackgroundBottomAlpha: Double = PanelBackgroundColor.factoryPanelBottomAlpha
    /// 浅色主题开关状态（update 同步；优先级高于渐变——开启即强制浅色外观）
    private(set) var lightThemeEnabled = false
    // ── 主副标题行距系数「固化档」（2026-09-15 用户：「固化这两个参数 然后在 forms 里隐藏调教」）──
    // 原为设置窗口「主题外观 → 卡片」的两根滑杆 + 两个 config 键
    //（card_title_gap_scale_sf / card_title_gap_scale_sg），已随固化整体移除。
    // 定稿值 = 移除当刻面板上的读数：SF 0.30 / SG 0.90。
    // 真值只此一处，PanelLayout 直接读下面两个只读属性（不要再从配置里取）
    static let cardTitleGapScaleSFFixed: CGFloat = 0.30
    static let cardTitleGapScaleSGFixed: CGFloat = 0.90
    /// 卡片主标题字号（pt）与 Sharp Grotesk 开关（update 同步；变化时就地重刷标题字体）。
    /// ⚠️ 字号仍由设置窗口「主题外观 → 卡片」开放（10…16、步进 0.5），未固化
    private(set) var cardTitleFontSize: CGFloat = 13
    private(set) var cardTitleSharpGrotesk = false
    /// 主标题↔副标题行距的字体系数（固化两档，按当前字形档取哪一档；见 applyTitleRowGap）
    var cardTitleGapScaleSF: CGFloat { Self.cardTitleGapScaleSFFixed }
    var cardTitleGapScaleSG: CGFloat { Self.cardTitleGapScaleSGFixed }
    /// 行距作用点：每张默认卡片的内容 stack（见 PanelLayout.registerTitleRowGap）。
    /// 卡片重建后旧 stack 的 superview 变 nil，由 register/apply 两处顺带清理
    var cardGapStacks: [NSStackView] = []
    /// 数值滚动预览开关状态（update 同步；开启后周期随机变动余额演示滚动）
    private(set) var valueScrollPreviewEnabled = false
    /// 长进度卡片开关状态（update 同步；卡片第二行结构随卡片重建切换）
    private(set) var longProgressCardEnabled = false
    /// 图标深浅互换开关状态（update 同步；品牌 icon 取深版还是浅版）
    private(set) var iconThemeSwapEnabled = false
    /// 无边框图标开关状态（update 同步；品牌 icon 用 SVG 原图还是 Icon Composer 的 PNG）
    private(set) var iconNoBorderEnabled = false
    // MARK: - 字体（主面板全部文字；两档见 PanelFont）

    /// 取字体：主面板字体解析器（SG 开关关闭 = 系统字体；开启 = Sharp Grotesk + 中文兜底）。
    /// monoDigits = 等宽数字变体（右对齐数字列用；SG 档下无意义，见 PanelFont.font）
    private func uiFont(size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) -> NSFont {
        PanelFont.font(size: size, weight: weight, monoDigits: monoDigits)
    }

    /// 右上角 pin 按钮：悬浮在面板顶部留白带内（不占布局）
    let pinBtn = HoverIconButton()
    /// 拖动示意条（grabber）：置顶浮窗时悬浮在「余额」标题上方居中，
    /// 提示窗口可按住拖动；popover 模式隐藏。绝对定位，不占布局
    let dragGrabber: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        v.layer?.cornerRadius = 2
        v.layer?.cornerCurve = .continuous
        v.isHidden = true
        return v
    }()

    /// 字体注册表：registerFont 的入参留档，SG 档翻转时按它就地重刷主面板全部文字
    /// （与 cardTitleTargets 同款：weak 引用 + 空引用清理，卡片重建不留残项）
    private struct FontTarget {
        weak var label: NSTextField?
        let size: CGFloat
        let weight: NSFont.Weight
        let monoDigits: Bool
    }
    private var fontTargets: [FontTarget] = []

    /// 注册 label 并设置字体（主面板字体档统一入口 `PanelFont`；SG 开关翻转时就地重刷）
    func registerFont(_ label: NSTextField, size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) {
        label.font = uiFont(size: size, weight: weight, monoDigits: monoDigits)
        fontTargets.append(FontTarget(label: label, size: size, weight: weight, monoDigits: monoDigits))
        if fontTargets.count % 64 == 0 { fontTargets.removeAll { $0.label == nil } }
    }

    /// SG 档翻转：主面板全部已注册文字就地换字体（不重建卡片）。
    /// 自绘层（内嵌 Token 板块 / 点阵 / 滚动数值）各自另有刷新入口，见 update。
    /// 两类**派生度量**也必须在这里重算，否则字体换了而它们的旧值还挂着：
    /// 1. 子账号 chip 的右内缩进（末字符墨迹空档 rsb 随字体变 → 背景贴边错位）；
    /// 2. 用量历史子面板图表（全自绘，字体在 draw 内现取，只需标脏重绘）。
    /// ⚠️ 用量表的**列宽**不在这里 —— 它由 `computeUsageColumnLayout` 按 SmallTable 度量算，
    ///    靠 update 里清 `renderedUsageRows` 强制重建整表（列宽是行的定值约束，改不了就地）
    private func applyPanelFonts() {
        for t in fontTargets {
            guard let label = t.label else { continue }
            label.font = uiFont(size: t.size, weight: t.weight, monoDigits: t.monoDigits)
        }
        fontTargets.removeAll { $0.label == nil }
        for e in allCardEntries() {
            for item in e.subItems { item.refreshOpticalPadding() }
        }
        usageHistoryController?.refreshFontStyle()
    }

    // MARK: 卡片主标题字体（字号滑杆 + Sharp Grotesk 字重×宽度，设置窗口「主题外观」开放）

    /// 主标题注册表：size/weight 记注册时的调用方字重（Sharp Grotesk 关闭时的回落字体用）；
    /// rolling/valueWidth 同卡捆注册：数值（积分/金额）与标题同字号联动、列宽等比缩放
    private struct CardTitleTarget {
        weak var label: FadeableTextField?
        let weight: NSFont.Weight
        weak var rolling: RollingNumberView?
        weak var valueWidth: NSLayoutConstraint?
        /// 数值基线锚约束（探针基线 ↔ row1 中心，constant 只由字号决定，随字号就地更新）
        weak var valueBaseline: NSLayoutConstraint?
    }
    private var cardTitleTargets: [CardTitleTarget] = []

    /// 注册卡片主标题（连同数值视图与列宽/基线约束）并立即应用当前字体设置
    func registerCardTitle(_ label: FadeableTextField, weight: NSFont.Weight,
                           rolling: RollingNumberView, valueWidth: NSLayoutConstraint,
                           valueBaseline: NSLayoutConstraint) {
        cardTitleTargets.append(CardTitleTarget(label: label, weight: weight,
                                                rolling: rolling, valueWidth: valueWidth,
                                                valueBaseline: valueBaseline))
        if cardTitleTargets.count % 32 == 0 { cardTitleTargets.removeAll { $0.label == nil } }
        applyCardTitleFont(to: label, weight: weight, rolling: rolling,
                           valueWidth: valueWidth, valueBaseline: valueBaseline)
    }

    /// Sharp Grotesk PostScript 名：**固定 Book20**（2026-09-15 用户先定「固定 Medium + 20」，
    /// 同日再「改为 book 字重」→ 字重 Medium → **Book**，宽度仍 20；字重/宽度两个 Picker
    /// 与对应 config 键已随固定化一并移除）。
    /// 解析已收口到 `PanelFont`（本机未装该档时那里回落系统字体），本属性只作档案注释位
    private var cardTitleSGPostScriptName: String { PanelFont.sgPostScriptName }

    /// Token 面板大数字共用的字体档通知：SG 开关变化时让内嵌 Token 板块重算度量
    /// （字体策略改由 `PanelFont` 全局解析，这里只负责"变化了 → 刷"）
    private func refreshInlineTokensFont() {
        inlineTokenView?.refreshFontStyle()
    }

    private func applyCardTitleFont(to label: FadeableTextField, weight: NSFont.Weight,
                                    rolling: RollingNumberView?, valueWidth: NSLayoutConstraint?,
                                    valueBaseline: NSLayoutConstraint? = nil) {
        // SG 档与中文兜底统一由 PanelFont 解析（未启用 / 本机未装该字重均回落系统字体）
        label.font = uiFont(size: cardTitleFontSize, weight: weight)
        // 数值（积分/金额 + ¥$ 前缀）与标题同字号联动、Sharp Grotesk 同套：
        // setSize 处理字号变化（同字号时 no-op），refreshFont 让字体提供器按当前
        // SG 开关重新解析（开关翻转而字号未变时也要重刷）
        rolling?.setSize(cardTitleFontSize)
        rolling?.refreshFont()
        valueWidth?.constant = cardTitleFontSize * 5
        // 基线锚定（2026-09-13 用户定稿）：探针基线钉 row1 中心下方「系统字体数字
        // 墨迹半高」处——constant 只由字号决定，与当前字体无关（同字号切字体基线恒等
        // 不跳行）。与 balanceContentRow 的 build 路径同公式（systemDigitInkHeight）：
        // 旧 capHeight/2 近似使墨迹中心偏高 (墨迹高−cap)/2，就地联动与重建成两张皮
        valueBaseline?.constant = Self.systemDigitInkHeight(cardTitleFontSize) / 2
    }

    /// 字号/字体档变化时：对所有存活主标题就地重刷
    private func applyCardTitleFont() {
        for t in cardTitleTargets {
            guard let label = t.label else { continue }
            applyCardTitleFont(to: label, weight: t.weight, rolling: t.rolling,
                               valueWidth: t.valueWidth, valueBaseline: t.valueBaseline)
        }
        cardTitleTargets.removeAll { $0.label == nil }
        // 板块（分组）标题字号同源（2026-09-16 用户要求「板块标题跟随卡片主标题字号」）：
        // 一并就地重刷，不重建区块
        for t in sectionTitleTargets {
            guard let label = t.label else { continue }
            label.font = uiFont(size: cardTitleFontSize, weight: t.weight)
        }
        sectionTitleTargets.removeAll { $0.label == nil }
    }

    // MARK: 板块（分组）标题（字号跟随卡片主标题）

    /// 板块/分组标题注册表（`PanelLayout.sectionTitleRow / plainSectionTitle /
    /// collapsibleSectionTitle` 三处标题都登记于此）。字号唯一来源 = `cardTitleFontSize`，
    /// 变化时由 `applyCardTitleFont()` 就地重刷（行高 / 缩进保持固定 24pt / 8pt，
    /// 面板总高不随字号连锁变化）。
    private struct SectionTitleTarget {
        weak var label: NSTextField?
        let weight: NSFont.Weight
    }
    private var sectionTitleTargets: [SectionTitleTarget] = []

    /// 注册板块标题并按**当前**主标题字号立即落字体。
    /// ⚠️ 不走 `registerFont`：那条路径把注册时的 size 固化进 `fontTargets`，字号变化时
    /// 只会换字体重解析、不会换 size —— 这里的诉求恰恰是"跟随主标题字号"
    func registerSectionTitle(_ label: NSTextField, weight: NSFont.Weight = .semibold) {
        sectionTitleTargets.append(SectionTitleTarget(label: label, weight: weight))
        if sectionTitleTargets.count % 32 == 0 { sectionTitleTargets.removeAll { $0.label == nil } }
        label.font = uiFont(size: cardTitleFontSize, weight: weight)
    }

    /// 注册余额滚动数值视图并注入字体策略（走主面板字体解析器：SG 开关下数值同套该字体）
    func registerRollingNumber(_ v: RollingNumberView, size: CGFloat, weight: NSFont.Weight) {
        v.configure(size: size, weight: weight, fontProvider: { [weak self] s, w, mono in
            guard let self else { return PanelFont.system(size: s, weight: w, monoDigits: mono) }
            return self.uiFont(size: s, weight: w, monoDigits: mono)
        })
    }

    override init(frame frameRect: NSRect) {
        let savedOrder = UserDefaults.standard.stringArray(forKey: UDKey.balancePlatformOrder) ?? []
        platformOrder = BalancePlatform.normalizedOrder(from: savedOrder)
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 数据更新

    /// 按快照刷新面板内容。传入 force=true 时跳过「内容未变则去重」的 guard，
    /// 用于 performRefresh 收尾时强制恢复 footer 文本（lastSnapshot 与 snapshot 可能完全相同）。
    func update(_ s: PanelSnapshot, force: Bool = false) {
        let previousSnapshot = lastSnapshot
        let same = s == lastSnapshot
        Logger.log(.refresh, "Panel.update: isRefreshing=\(isRefreshing) updatedAt=\(s.updatedAt) failed=\(s.failedText ?? "nil") same=\(same) force=\(force) prevUpdatedAt=\(previousSnapshot?.updatedAt ?? "nil")")
        guard !same || force else { return }
        lastSnapshot = s
        var contentSizeChanged = previousSnapshot == nil
            || previousSnapshot?.offline != s.offline
            || previousSnapshot?.lastCheckinTime != s.lastCheckinTime

        // 「面板背景色」/浅色主题开关状态同步（VC 通过 onPanelGradientChanged 即时刷新遮罩与外观绘制）
        let maskChanged = s.panelBackgroundColor != panelBackgroundColor
            || s.panelBackgroundBottomAlpha != panelBackgroundBottomAlpha
        panelBackgroundColor = s.panelBackgroundColor
        panelBackgroundBottomAlpha = s.panelBackgroundBottomAlpha
        let lightChanged = s.lightThemeEnabled != lightThemeEnabled
        lightThemeEnabled = s.lightThemeEnabled
        if maskChanged || lightChanged {
            Logger.log(.layout, "[GradProbe] panel.update id=\(ObjectIdentifier(self).hashValue) bg \(panelBackgroundColor.hexString)→\(s.panelBackgroundColor.hexString) light \(lightThemeEnabled)→\(s.lightThemeEnabled)")
            usageHistoryController?.panelBackgroundColor = panelBackgroundColor
            usageHistoryController?.lightThemeEnabled = lightThemeEnabled
            onPanelGradientChanged?()
            // 副前景色按底色解算（动态色只在绘制时解算）：整树标脏才换得上新灰
            refreshSecondaryForeground()
        }
        // 卡片字体档同步（行距系数已固化，不再有"随配置变化"这一路）：
        // ① 先落 PanelFont 全局镜像（本面板已有的与随后重建的卡片都按它解析字体）；
        // ② 变化时：已注册 label 就地换字体（不重建卡片）+ 主标题/数值/内嵌 Token 板块刷新
        let titleFontChanged = s.cardTitleFontSize != cardTitleFontSize
            || s.cardTitleSharpGrotesk != cardTitleSharpGrotesk
        cardTitleFontSize = s.cardTitleFontSize
        cardTitleSharpGrotesk = s.cardTitleSharpGrotesk
        PanelFont.sharpGroteskActive = s.cardTitleSharpGrotesk
        // 滑移时长口径 / 时间曲线档位两处运行镜像 2026-09-17 已随「动效的参数固化」移除
        if titleFontChanged {
            applyCardTitleFont()
            applyPanelFonts()
            // 主面板内嵌 Token 板块（自绘 + 滚动数值）按新字体档重算度量并重绘
            refreshInlineTokensFont()
            // 行距 = 基准 × 系数，而系数按当前字形档取 → 改字号/切字体都要一并重算行距
            applyTitleRowGap()
            // SG 行高比系统字体矮（13pt：13.0 vs 15.31）→ 面板总高会变，通知 VC 重算尺寸
            contentSizeChanged = true
            // 用量表两列宽是**定值约束**（按 SmallTable 字体度量算的），就地换字体改不了它 ——
            // 清空已渲染记录强制下方重建整表，列宽随之按新字体档重新解算
            //（SG 与系统字体的数字 advance 差约 5%，不重建会留出/挤掉几个 pt）
            renderedUsageRows = []
        }
        valueScrollPreviewEnabled = s.valueScrollPreviewEnabled
        // 预览定时器状态与配置保持一致（幂等：无变化不动）
        setValueScrollPreview(s.valueScrollPreviewEnabled)
        // 长进度卡片开关同步：卡片第二行结构（整行进度条+副标题下移）随卡片重建切换，
        // 清全部平台 uid 缓存强制重建
        let longProgressCardChanged = s.longProgressCard != longProgressCardEnabled
        longProgressCardEnabled = s.longProgressCard
        if longProgressCardChanged {
            dsCardUids = []
            zhipuCardUids = []
            qwenCardUids = []
            wbCardUids = []
            zcodeCardUids = []
            traeCardUids = []
            codexCardUids = []
            applyPlatformCardGaps()   // 组内平台卡间距随模式切换（列表态 4 / 长进度 2.5）
            contentSizeChanged = true
        }
        // 图标两开关同步：变化时按当前生效外观就地换图（不重建卡片；
        // 设置段先于卡片构建执行，后续新建卡直接读这两个开关取对图）
        let iconSwapChanged = s.iconThemeSwap != iconThemeSwapEnabled
        iconThemeSwapEnabled = s.iconThemeSwap
        let iconNoBorderChanged = s.iconNoBorder != iconNoBorderEnabled
        iconNoBorderEnabled = s.iconNoBorder
        if iconSwapChanged || iconNoBorderChanged { swapBrandIconsInPlace() }
        offlineBanner.isHidden = !s.offline

        // 行序跟随面板卡片视觉序：API 板块在前、Agent 板块在后，
        // 组内保持 platformOrder 相对序（与菜单栏 balancePlatformOrder 同口径）
        let orderIndex = Dictionary(uniqueKeysWithValues: platformOrder.enumerated().map { ($1, $0) })
        func usageRank(_ id: String) -> (Int, Int) { (isAgentPlatform(id) ? 1 : 0, orderIndex[id] ?? Int.max) }
        let sortedRows = s.usageRows.sorted { usageRank($0.platform) < usageRank($1.platform) }
        if sortedRows != renderedUsageRows {
            computeUsageColumnLayout(sortedRows)
            // 用量数据刷新会重建表格，但用户仍在表格会话内，保留已选周页。
            dismissUsageHistoryPopover(resetWeekSelection: false)
            contentSizeChanged = true
            usageContentStack.arrangedSubviews.forEach {
                usageContentStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            usageRowViews.removeAll()
            usageHeaderRowRef = nil
            if !sortedRows.isEmpty {
                let header = makeUsageHeaderRow()
                usageHeaderRowRef = header
                usageContentStack.addArrangedSubview(header)
            }
            for row in sortedRows {
                let view = makeUsageRow(row)
                usageRowViews[row.platform] = view
                usageContentStack.addArrangedSubview(view)
            }
            renderedUsageRows = sortedRows
        }
        let hasUsage = !s.usageRows.isEmpty
        usageTitleRef?.isHidden = !hasUsage
        if hasUsage {
            usageCardRef?.isHidden = UserDefaults.standard.bool(forKey: UDKey.usageSectionCollapsed)
        } else {
            usageCardRef?.isHidden = true
        }

        // DeepSeek 卡片：走多号卡片管线（uid 恒 "ds"，仅首帧重建，之后就地更新）
        let newDsUids = s.dsAccounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        if newDsUids != dsCardUids {
            rebuildDsCards(s.dsAccounts)
        } else {
            applyDsCardData(s.dsAccounts)
        }

        // ZhiPu 卡片：同 DeepSeek 单账号管线（uid 恒 "zhipu"）
        let newZhiPuUids = s.zhipuAccounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        if newZhiPuUids != zhipuCardUids {
            rebuildZhiPuCards(s.zhipuAccounts)
        } else {
            applyZhiPuCardData(s.zhipuAccounts)
        }

        // Qwen 卡片：同 DeepSeek 单账号管线（uid 恒 "qwen"）
        let newQwenUids = s.qwenAccounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        if newQwenUids != qwenCardUids {
            rebuildQwenCards(s.qwenAccounts)
        } else {
            applyQwenCardData(s.qwenAccounts)
        }

        // ZCode 多账号卡片：uid 或当前账号变化时重建（弱化跟随 isCurrent），否则就地更新数据
        let newZcodeUids = s.zcodeAccounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        if newZcodeUids != zcodeCardUids {
            contentSizeChanged = true
            rebuildZcodeCards(s.zcodeAccounts)
        } else {
            applyZcodeCardData(s.zcodeAccounts)
        }

        // Codex 多账号卡片：uid 或当前账号变化时重建，否则就地更新
        let newCodexUids = s.codexAccounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        if newCodexUids != codexCardUids {
            contentSizeChanged = true
            rebuildCodexCards(s.codexAccounts)
        } else {
            applyCodexCardData(s.codexAccounts)
        }

        // TRAE 多账号卡片：uid 或当前账号变化时重建，否则就地更新数据
        let newTraeUids = s.traeAccounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        if newTraeUids != traeCardUids {
            contentSizeChanged = true
            rebuildTraeCards(s.traeAccounts)
        } else {
            applyTraeCardData(s.traeAccounts)
        }

        // WorkBuddy 多账号卡片：uid 或当前账号变化时重建，否则就地更新数据
        let newUids = s.wbAccounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        if newUids != wbCardUids {
            contentSizeChanged = true
            rebuildWbCards(s.wbAccounts)
        } else {
            applyWbCardData(s.wbAccounts)
        }

        // ── 面板余额卡片显隐（平台开关：用户可强制隐藏某平台整组卡片）──
        // 空账号组（ZCode/Codex 未导入）即使配置为 true 也维持隐藏；
        // 用户配置为 false 时强制隐藏。
        // ⚠️ 空判断用 arrangedSubviews.isEmpty 而非 view.isHidden：后者是上次显隐结果，
        //    用户从关闭→打开时若账号列表未变（不触发 rebuild），isHidden 会卡在上次的 true。
        // DS 是单卡片，永远有内容（标题+value占位），直接按配置切换。
        for pid in [BalancePlatform.deepSeek.rawValue,
                    BalancePlatform.bigModel.rawValue,
                    BalancePlatform.qwen.rawValue,
                    BalancePlatform.zcode.rawValue,
                    BalancePlatform.codex.rawValue,
                    BalancePlatform.trae.rawValue,
                    BalancePlatform.workBuddy.rawValue] {
            guard let view = platformCards[pid] else { continue }
            let userWantsShow = s.panelCardVisible[pid] ?? true
            let shouldHide: Bool
            // DS / ZhiPu / Qwen 是单卡片，永远有内容（标题+value占位），直接按配置切换
            if pid == BalancePlatform.deepSeek.rawValue || pid == BalancePlatform.bigModel.rawValue
                || pid == BalancePlatform.qwen.rawValue {
                shouldHide = !userWantsShow
            } else {
                // 多账号组：空容器（无卡片）即使开关打开也维持隐藏；
                // 非空时按用户开关切换。
                let isEmpty = (view as? NSStackView)?.arrangedSubviews.isEmpty ?? view.isHidden
                shouldHide = !userWantsShow || isEmpty
            }
            if view.isHidden != shouldHide {
                view.isHidden = shouldHide
                contentSizeChanged = true
            }
        }

        // 刷新中时 header 显示「刷新中…」并保持脉冲，刷新完成后恢复更新时间；
        // 有服务获取失败时追加标记，让「旧数据」可被识别（失败时间即本轮更新时间）
        updatedLabel.stringValue = isRefreshing ? "刷新中…"
            : (s.updatedAt.isEmpty ? "尚未更新"
               : "更新于 \(s.updatedAt)" + (s.failedText.map { " · \($0)" } ?? ""))

        // Token 板块跟随快照落定后刷新：账号增删/容器显隐变化会改变「Agent 顶部平台」
        // 的解析结果（fetch 缓存命中同步、零读取，幂等）
        refreshInlineTokens()
        if contentSizeChanged { onContentChanged?() }
    }

    // MARK: - 打开重滚入场

    /// 打开面板延迟重滚的挂起任务（关闭面板即取消，0.5s 内关面板不触发）
    private var openRerollItem: DispatchWorkItem?
    /// 开面板重滚窗口截止时刻 = 打开 + openRerollDelay + openRerollDuration。窗口内
    /// Token 总计的刷新路径派发（开面板触发的 onRefresh 首个完成 ~0.1s 即经 summary
    /// didSet 落进来）按「最长轮恰好落在截止时刻」规划时长——否则 0.9 刷新短预算会在
    /// 0.5s 补发前抢跑消耗掉挂起值的滚动、在补发后又截断在途的 2s 滚动（2026-08-31
    /// [RollTotal] 日志定案）。过期不主动清：派发侧按剩余时间 ≤0 视为窗口已关。
    var openRerollDeadline: Date? {
        didSet { inlineTokenView?.openRerollDeadline = openRerollDeadline }
    }

    /// 打开面板 openRerollDelay 后统一下发挂起的数值：面板隐藏期间数据管线不落值
    /// （applyAccountCardData / syncTotalRoll 挂起，视图保持旧显示），此处以动画一次
    /// 下发——数值有变化从旧值滚到新值，未变化 = 0 格 tween 原地不动（无假滚动）。
    func scheduleOpenReroll() {
        openRerollItem?.cancel()
        guard !valueScrollPreviewEnabled else { return }   // 预览模式显示归预览定时器接管
        openRerollDeadline = Date().addingTimeInterval(Motion.openRerollDelay + Motion.openRerollDuration)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            let animated = !shouldReduceMotion
            for e in self.allCardEntries() {
                e.valueView.setText(e.lastValue, animated: animated, totalDuration: Motion.openRerollDuration)
            }
            self.inlineTokenView?.syncTotalRoll()
        }
        openRerollItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.openRerollDelay, execute: item)
    }

    /// 面板关闭：取消挂起的重滚
    func cancelOpenReroll() {
        openRerollItem?.cancel()
        openRerollItem = nil
        openRerollDeadline = nil
    }

    // MARK: - 多号卡片通用实现（WB / TRAE / ZCode / Codex）

    /// 重建多号卡片（账号列表变化时调用）：
    /// 当前账号全尺寸 icon + 点阵 + 签到/到期信息行；API 板块非当前账号小卡片（仅 icon 标题 + 额度），
    /// Agent 板块非当前账号不建卡片（hover 主卡时在点阵位显示其余账号 icon+积分，2026-08-30 移除）。
    /// 点击当前账号卡片触发 onCurrentClick；非当前账号触发 onSwitch + 「切换中」脉冲
    /// （onSwitch 为 nil 时全部走 onCurrentClick）。
    private func rebuildAccountCards(_ accounts: [AccountCardSnapshot],
                                     style: CardStyle,
                                     container: NSStackView,
                                     entries: inout [CardEntry],
                                     uids: inout [String],
                                     onCurrentClick: (() -> Void)?,
                                     onSwitch: ((String) -> Void)?) {
        // 无账号时隐藏容器：NSStackView 隐藏的 arrangedSubview 不占空间也不产生间距，
        // 避免 DeepSeek 与 TRAE 之间多出一段空白（WB/TRAE 至少有当前账号，恒非空）
        container.isHidden = accounts.isEmpty
        // 清除旧卡片
        for v in container.arrangedSubviews {
            container.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        entries.removeAll()
        // 创建新卡片
        let isAgentCard = isAgentPlatform(style.platformID)
        for ac in accounts {
            let isCurrent = ac.isCurrent
            // Agent 板块：非当前账号不再建小卡片——其余账号信息改为 hover 主卡时在点阵位
            // 显示（icon+积分）。占位 entry 保持 accounts↔entries 下标对齐（apply 按下标应用），
            // 视图均为占位未入层级，apply 写入无视觉副作用
            if !isCurrent && isAgentCard {
                entries.append(CardEntry(uid: ac.uid, valueView: RollingNumberView(),
                                         titleLabel: FadeableTextField(labelWithString: ""),
                                         dots: UsageDots(),
                                         segmentLabels: [], expireIcons: [],
                                         badgeView: makeFailureBadge(),
                                         iconView: NSImageView(),
                                         statusRing: nil,
                                         menuBarDot: NSView()))
                continue
            }
            let valueView = RollingNumberView()   // 初始 "—" 占位（init 内置）
            // 积分下方那条：所有 Agent 平台一律竖向点阵（TRAE 的「三颗 ×」不占这一列，
            // 它走副标题行右侧的 `subtitleMeta` 那一格 = 积分正下方，见下方 metaStack）
            let dots: UsageDots? = UsageDots()
            let uid = ac.uid
            weak var cardRef: NSView?
            // Agent 卡其余账号条：hover 时替换点阵，icon+积分（字号/颜色与副标题统一：9pt 副前景灰）
            var subStrip: NSStackView? = nil
            var subValueLabels: [NSTextField] = []
            var subItems: [SubAccountItemView] = []
            /// 点阵↔账号条互换的代际计数：仅在换入真实落点（SHOW）与离场换出启动时推进；
            /// 换入完成回调据此判断自己是否已被新一轮离场换出作废（被作废则不得落藏点阵）。
            /// ⚠️ 勿改回「任何 hover 事件即 bump」：驻留 0.8s 后 enter≠显示，
            /// 会把在途淡出的落藏吞掉，造成 isHidden/alpha 错位残留（积分按钮误亮根因）
            var subStripSwapEpoch = 0
            /// 账号条换入的挂起计时（Motion.hoverDwell）：hover 不足时长离开即取消不显示
            var stripRevealWork: DispatchWorkItem?
            /// 离场淡出在途标记：isHidden 要等 crossfade 完成（0.35s）才落 true，
            /// 期间重复 exit 事件（滚动补偿/几何校准会补发）若不加拦会重复启动 crossfade，
            /// 动画反复重启 = 观感不连贯的根因之一
            var stripExitInFlight = false
            /// 账号条隐藏期零宽约束（2026-09-06 默认态副标题重叠排查）：条隐藏时若仍占
            /// 自然宽，副标题渐隐视图（尾随钉条前缘）会被无谓压窄。零宽=隐藏不占位，
            /// 换入解除、落藏恢复
            var stripZeroWidth: NSLayoutConstraint?
            if isAgentCard, accounts.contains(where: { !$0.isCurrent }) {
                let strip = NSStackView()
                strip.orientation = .horizontal
                strip.alignment = .centerY
                strip.spacing = 2.5
                strip.heightAnchor.constraint(equalToConstant: 12).isActive = true
                // 隐藏期零宽（见 stripZeroWidth 注释）：初始隐藏即激活
                let zeroWidth = strip.widthAnchor.constraint(equalToConstant: 0)
                zeroWidth.isActive = true
                stripZeroWidth = zeroWidth
                strip.isHidden = true
                for sub in accounts where !sub.isCurrent {
                    let item = SubAccountItemView()
                    item.orientation = .horizontal
                    item.alignment = .centerY
                    item.spacing = ChipStyle.iconTextGap   // icon↔文本间距（chip 统一规格）
                    // 点击切号：复用原小卡片「切换中」脉冲反馈（重建后随旧卡销毁）
                    if let onSwitch {
                        item.onClick = {
                            if let c = cardRef {
                                c.wantsLayer = true
                                let pulseAnim = CABasicAnimation(keyPath: "opacity")
                                pulseAnim.fromValue = 1.0
                                pulseAnim.toValue = 0.4
                                pulseAnim.duration = 0.5
                                pulseAnim.autoreverses = true
                                pulseAnim.repeatCount = .infinity
                                pulseAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                                c.layer?.add(pulseAnim, forKey: "switchingPulse")
                            }
                            onSwitch(sub.uid)
                        }
                    }
                    // hover 提示账号昵称+积分：自绘圆角气泡窗（圆角与卡片统一）,
                    // 锚定整张卡、弹到卡片右侧（贴屏自动翻左缘）;面板侧统一弹/收
                    item.nickname = sub.nickname
                    let displayValue = subAccountDisplayValue(sub.value)
                    item.valueText = displayValue
                    item.tokenInvalid = sub.tokenInvalid
                    item.onTipToggle = { [weak self, weak item] showing in
                        guard let self, let item, item.window != nil, let card = cardRef,
                              card.window != nil else { return }
                        if showing {
                            self.showSubAccountTip(nickname: item.nickname,
                                                   value: item.valueText,
                                                   tokenInvalid: item.tokenInvalid, anchorCard: card)
                        } else {
                            self.dismissSubAccountTip()
                        }
                    }
                    // chip hover 时当前账号积分/数值让位系统灰（含 coin 前缀图标）,离开按
                    // 积分 chip 激活态复原（chip 深色档 / 常规前景）
                    // 之前：hover 时让位系统灰（setDimmed）。用户定稿：当前账号积分 chip
                    // hover 任何子按钮都不改色，保持 chip 前景。删掉 onHoverChanged 挂接即可。
                    let iv = SubAccountIconView()
                    // icon 视觉下偏（与数值文本基线对齐）；2026-09-02 用户要求在统一定稿上
                    // 手动上移 0.6pt（32px 光栅墨迹仍比旧 16px 基准略沉）
                    iv.verticalOffset = ChipStyle.iconVerticalOffset - 0.6 - 0.2
                    iv.image = Self.trimmedBundleSvgIcon("coin", size: ChipStyle.iconSize)
                    iv.image?.isTemplate = true   // 着色跟随 chip 前景色（applyState 统一驱动）
                    iv.imageScaling = .scaleProportionallyUpOrDown
                    iv.widthAnchor.constraint(equalToConstant: ChipStyle.iconSize).isActive = true
                    iv.heightAnchor.constraint(equalToConstant: ChipStyle.iconSize).isActive = true
                    let lbl = NSTextField(labelWithString: displayValue)
                    registerFont(lbl, size: ChipStyle.fontSize, weight: ChipStyle.fontWeight)
                    lbl.textColor = Palette.secondaryForeground
                    // 右内缩进按末字符墨迹回补（背景贴 ink 而非 advance，左右视觉等距）
                    item.valueLabel = lbl
                    item.refreshOpticalPadding()
                    item.addArrangedSubview(iv)
                    item.addArrangedSubview(lbl)
                    strip.addArrangedSubview(item)
                    subValueLabels.append(lbl)
                    subItems.append(item)
                }
                subStrip = strip
            }
            // 第二行信息：到期倒计时/引导文案（time/external-link 图标 + 分段文本，9pt 副前景灰 行高 12）。
            // 段间与 icon↔文本均 3pt，由 stack.spacing 布局提供，不再用空格字符做间隔。
            // TRAE 原签到信息行是恒空的占位容器（文字条目已移除）——已废弃：
            // info=nil 时点阵/账号条仍作第二行入组（标题+积分贴顶，与其他卡对齐）；非当前账号无第二行
            var segLabels: [NSTextField] = []
            let segBox = ExpireSegBox()
            var expireIcons: [NSImageView] = []
            let info: NSStackView?
            if isCurrent && style.showsExpire {
                var rowViews: [NSView] = []
                // 第二行图标可选：重置倒计时按周期用 clock-stop-w（Qwen 7 天）/ clock-stop-m（WB/TRAE/Codex 月），
                // 周期不确定（ZCode 套餐到期）用 clock-stop，DS/ZhiPu 用 external-link 打开页面图标
                if let symbol = style.expireIconSymbol {
                    // TRAE 已停止维护：用原生 xmark（icons 里没有 xmark.svg）。
                    // ⚠️ 这里的图标是**副标题行那颗**，恒 1 个；「积分下方」另有三颗 xmark，
                    // 走 `makeXmarkTriple()` + balanceContentRow 的 trailingMarkView（2026-09-15 用户指定）
                    let icon = NSImageView()
                    icon.image = symbol == "xmark"
                        ? NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
                        : Self.trimmedBundleSvgIcon(symbol, size: 10)
                    icon.image?.isTemplate = true   // 兜底：SVG 路径已置 isTemplate，显式再置一次防裁剪回退分支丢失
                    icon.contentTintColor = Palette.secondaryForeground
                    icon.imageScaling = .scaleProportionallyUpOrDown
                    icon.widthAnchor.constraint(equalToConstant: 10).isActive = true
                    icon.heightAnchor.constraint(equalToConstant: 10).isActive = true
                    rowViews.append(icon)
                    expireIcons.append(icon)
                }
                // 最多 3 段（剩余 / x天 / HH:MM）；apply 按分段数组填充，未用的段 isHidden 收起间距
                for _ in 0..<3 {
                    let lbl = NSTextField(labelWithString: "")
                    registerFont(lbl, size: Palette.cardSubFontSize)
                    lbl.textColor = Palette.secondaryForeground
                    lbl.setContentHuggingPriority(.defaultLow, for: .vertical)
                    lbl.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                    segLabels.append(lbl)
                    rowViews.append(lbl)
                }
                let stack = NSStackView(views: rowViews)
                stack.orientation = .horizontal
                stack.alignment = .centerY
                // icon↔文本、文本段间均 2pt（布局间距，不用空格）；签到行 icon↔文本 6pt
                stack.spacing = 2
                stack.heightAnchor.constraint(equalToConstant: 12).isActive = true
                info = stack
            } else {
                info = nil
            }
            // 副标题右侧 meta（2026-09-13 用户改版）：过去 24h 积分/余额变化 =
            // 方向箭头 + 变化量绝对值，**单 label 内联 NSTextAttachment**（与签到行
            // 徽章同路线——独立 icon 视图三种钉法 centerY/stack firstBaseline/手动钉
            // 基线逐一实测箭头偏低，attachment 画布底贴基线才是 TextKit 原生口径）。
            // 6pt outline 箭头、箭头↔数值 1pt（烘进附件画布右侧，不用空格字符）。
            // 有 info 行的卡片**恒挂**（初值隐藏）——24h 锚点要跨天积累，重建时多半
            // 尚无数据，显隐唯一事实源 = apply。hover 账号条换入时隐藏（同一区域
            // 被条占用）、离场恢复（见换入/离场闭包）
            var metaStack: NSView? = nil
            var metaChangeLabel: NSTextField? = nil
            if info != nil {
                if style.platformID == "trae" {
                    // TRAE：副标题行右侧 = **三颗 ×**（2026-09-15 用户「积分正下方写 xxx」）。
                    // 位置照**别的 Agent 卡**的做法 —— 走同一个 `subtitleMeta` 那一格
                    //（它们的 24h 变化量 / 速度文本就在这儿）：与积分数值同一列、紧贴其下，
                    // 不另起一列、也不动右侧的竖向点阵
                    metaStack = Self.makeTripleX()
                } else {
                    let lbl = NSTextField(labelWithString: "")
                    registerFont(lbl, size: Palette.cardSubFontSize)
                    lbl.textColor = Palette.secondaryForeground
                    lbl.isHidden = true
                    metaChangeLabel = lbl
                    metaStack = lbl
                }
            }
            // 昵称展示已彻底移除（2026-09-02 卡片 hover 昵称改由积分按钮悬浮气泡承载；
            // 2026-09-13 连空占位 nickLabel 一并删除，标题行恒为平台名单分支）
            // 非 Agent 平台恒单账号（main.swift 快照为单元素数组）、Agent 平台非当前账号
            // 走上方占位 continue，能走到这里的卡片必为当前账号——小卡尺寸/降透明等
            // isCurrent 分支已随死代码清理移除（2026-08-31）
            let imgSize: CGFloat = style.iconSize
            // 上下内边距大小卡统一（2026-08-31 → 5.5；2026-09-01 用户指定 → 6；
            // 2026-09-14 用户「默认卡片的上下缩进 +1pt」→ 7；
            // 2026-09-16 用户「卡片上下内缩进 −0.6pt」→ 6.4，真值在 cardVerticalPadding）
            // ⚠️ 本处是**两种卡型共用**的（默认卡片 / 长进度卡片同走这个调用点），改则一起变
            let cardPadTop: CGFloat = BalancePanelView.cardVerticalPadding
            let cardPadBottom: CGFloat = BalancePanelView.cardVerticalPadding
            // 签到失败角标（当日失败时显示；无签到平台仅调试模式，apply 阶段控制显隐）
            let badge = makeFailureBadge()
            // 平台 icon 视图（原渐变 fadeIcon 薄壳已随小白点指示替代而移除）
            let fadeIcon = NSImageView()
            // 任务状态光环引用：全平台卡片挂载——Agent 卡由快照 taskState 驱动（WB/ZCode/
            // Codex 为真实任务态）；API 卡（DS/ZhiPu/Qwen）为脉冲驱动态
            //（pulseDriven：进度条闪烁点亮进行中 + 颜色去饱和），由 apply 按 pulsing 合成
            weak var capturedStatusRing: CardTaskStatusRingView?
            let needsStatusRing = true
            // 标题 label 引用：CardEntry 持有，apply 阶段驱动菜单栏渐变标记（weak 在卡片重建后自动失效）
            weak var capturedTitle: FadeableTextField?
            // 菜单栏显隐小白点引用：icon 下方 4pt，apply 阶段按 inMenuBar 显隐
            weak var capturedMenuBarDot: NSView?
            let card = addCard(rows: [
                balanceContentRow(icon: style.icon, name: style.name, valueView: valueView,
                                  info: info, dots: dots, iconSize: style.iconSize, imageSize: imgSize,
                                  titleWeight: .medium, valueWeight: .medium,
                                  failureBadge: badge,
                                  premadeIconView: fadeIcon,
                                  hoverSubStrip: subStrip,
                                  subtitleMeta: metaStack,
                                  valuePrefixIcon: isAgentCard ? "coin" : nil,
                                  longProgressCard: longProgressCardEnabled,
                                  titleLabelRef: { capturedTitle = $0 },
                                  menuBarDotRef: { capturedMenuBarDot = $0 },
                                  statusRingRef: needsStatusRing
                                      ? { capturedStatusRing = $0; $0.pulseDriven = !isAgentCard }
                                      : nil)
            ], to: container, onClick: {
                // 能建卡的必为当前账号（Agent 非当前走占位 continue），点击恒为主卡行为；
                // 「切换中」透明度脉冲反馈由账号条 SubAccountItemView.onClick 自行实现
                onCurrentClick?()
            }, onRightClick: { [weak self] event in
                self?.onRightClickCard?(style.menuBarIdPrefix + uid, event)
            }, onDragStarted: { [weak self] point in
                self?.beginPlatformDrag(style.platformID, locationInWindow: point)
            }, onDragChanged: { [weak self] point in
                self?.updatePlatformDrag(style.platformID, locationInWindow: point)
            }, onDragEnded: { [weak self] in
                self?.endPlatformDrag()
            }, topPadding: cardPadTop, bottomPadding: cardPadBottom,
               // 卡片左缩进 7pt（2026-09-13 用户「左缩进-1pt」，历史：09-06「+1pt」由 7 改 8，今改回 7）；
               // 右缩进独立档 8（2026-09-13 用户「右间距缩小1pt」，调参史 10→9→8）
               horizontalPadding: 7, trailingPadding: 8,
               cardBackground: nil)
            cardRef = card
            // 当前账号积分 chip 气泡数据盒（hc 块内挂接闭包捕获，append 后存入 entry 供 apply 更新）
            var newChipTipBox: ChipTipBox? = nil
            if let hc = card as? HoverCard {
                hc.hoverDebugLabel = style.menuBarIdPrefix + uid
                // 其余账号切换项注册到卡片：点在项内由卡片 mouseDown 路由转交，
                // 不触发整卡点击/拖拽（整卡 hitTest 接管，项自身收不到事件）
                // 进度条恒常驻不参与互换（2026-09-06 用户指定「卡片 hover 时不再隐藏
                // 进度条」；竖条贴右缘与账号条分居两行无碰撞）：点阵淡出/恢复两条路径
                // 全平台跳过，子账号条落点在副标题行右侧（布局见 balanceContentRow）
                let dotsIndependent = true
                if let strip = subStrip {
                    hc.interactiveSubviews = strip.arrangedSubviews
                }
                hc.onHover = { [weak self, weak card] showing in
                    // Agent 卡：hover 驻留 Motion.hoverDwell 后点阵 ↔ 其余账号条互换
                    // （row2 行高不变，无几何反馈风险），与 Token 板块切换同一节拍；
                    // 时长未满离开则取消挂起计时，账号条不显示。
                    // 入场 = 账号条交错上移（Token 平台切换同款节奏）+ 点阵淡出落藏；
                    // 离场 = 账号条交错下沉淡出（staggerSinkOut 落藏收尾）+ 点阵透明度恢复
                    if let strip = subStrip, let dotsView = dots {
                        // 代际只在「真实换入落点 / 离场换出启动」时推进，enter/exit 事件本身不动
                        // 计数：换入要驻留 0.8s，任何新一轮换入必然晚于在途 0.35s 淡出的完成，
                        // 离场换出的落藏可无条件执行（旧实现 enter 即 bump，快速移出→再移入会把
                        // 淡出完成回调的落藏吞掉，strip 滞留 isHidden=false/alpha=0 错位态，
                        // 之后每次离场 crossfade 把 alpha 复位拉回 1 = 积分按钮无 hover 误亮）。
                        if showing {
                            stripRevealWork?.cancel()
                            let work = DispatchWorkItem { [weak self, weak strip, weak dotsView, weak hc, weak valueView, weak metaView = metaStack] in
                                guard let self, let strip, let dotsView else { return }
                                stripRevealWork = nil
                                // 落点权威校验：快速掠过时真实离开的 exit 可能丢失/被吞
                                // （或面板已收起），光标不在卡上就不换入。
                                // dwell 卡两计时同 tick 触发且 HoverCard 自检先跑（经
                                // onHover(false) 已 cancel 本 work），此处主要兜 TRAE 等非 dwell 卡
                                guard hc?.isPointerInsideNow == true else { return }
                                subStripSwapEpoch += 1
                                let showEp = subStripSwapEpoch
                                strip.isHidden = false
                                strip.alphaValue = 1
                                stripZeroWidth?.isActive = false   // 换入：零宽解除，条按自然宽接管
                                stripExitInFlight = false   // 新一轮换入：离场在途标记复位
                                // 副标题精简让位账号条（2026-09-06 用户指定）：
                                // ["剩余","26天","14:35"] → ["26天"]；离场由落藏回调恢复
                                let shown = compactExpireSegments(segBox.full)
                                for (i, lbl) in segLabels.enumerated() {
                                    if i < shown.count { lbl.stringValue = shown[i]; lbl.isHidden = false }
                                    else { lbl.isHidden = true }
                                }
                                // 副标题右侧 meta（子账号/7日消耗）同区让位：换入隐藏，离场恢复
                                metaView?.isHidden = true
                                // 当前账号积分不再 chip 化（2026-09-06 用户指定「hover 时不改变
                                // 样式」）：值显示恒定，setChipActive 调用已摘除（chip 背景气泡
                                // 入口随之下线，setChipActive 机制保留在 RollingNumberView）
                                // chip 换入落点主动探测：光标可能恰停在积分按钮上静止，
                                // 无 mouseMoved 补发，主动重算否则气泡永不弹出
                                hc?.syncInteractiveHoverFromCursor()
                                // 离场被代际取消时 onAllFinished 不执行，chip 仍处背景冻结：
                                // 解除并按当前 hover 态重铺（chip 在淡入起点，重铺不可见）
                                for case let item as SubAccountItemView in strip.arrangedSubviews {
                                    item.unfreezeBackground()
                                }
                                self.staggerRiseIn(strip.arrangedSubviews,
                                                   isCancelled: { showEp != subStripSwapEpoch })
                                // 长进度卡片：进度条常驻（dotsIndependent），跳过点阵淡出与落藏
                                if !dotsIndependent {
                                    if self.shouldReduceMotion {
                                        dotsView.isHidden = true
                                        dotsView.alphaValue = 1
                                    } else {
                                        // 显式 CABasicAnimation（fromValue 钉表现层当前值）：
                                        // animator 路径 fromValue=nil，CA 会取提交时 presentation，
                                        // 与 restore 的 model 钉值互踩
                                        if let layer = dotsView.layer {
                                            layer.removeAnimation(forKey: "dotsRestore")
                                            layer.removeAnimation(forKey: "opacity")   // 清隐式残留
                                            let anim = CABasicAnimation(keyPath: "opacity")
                                            anim.fromValue = layer.presentation()?.opacity ?? layer.opacity
                                            anim.toValue = Float(0)
                                            anim.duration = Motion.stripSwap.dotsFade
                                            anim.timingFunction = Motion.easeOutCubic
                                            layer.add(anim, forKey: "dotsFadeSwap")
                                            CATransaction.begin()
                                            CATransaction.setDisableActions(true)
                                            layer.opacity = 0
                                            CATransaction.commit()
                                        } else {
                                            dotsView.alphaValue = 0
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.stripSwap.dotsFade) { [weak dotsView] in
                                            // 点阵落藏：期间该换入若已被离场换出作废（换出会推进代际并
                                            // 把点阵回升），过期回调不得藏掉
                                            guard showEp == subStripSwapEpoch, let dotsView else { return }
                                            CATransaction.begin()
                                            CATransaction.setDisableActions(true)
                                            dotsView.isHidden = true
                                            dotsView.alphaValue = 1   // 落藏位 model 回写（禁隐式，防污染 restore 起播）
                                            CATransaction.commit()
                                        }
                                    }
                                }
                            }
                            stripRevealWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.hoverDwell, execute: work)
                        } else {
                            stripRevealWork?.cancel()
                            stripRevealWork = nil
                            // 离开卡片：子账号 hover 态与悬浮气泡一律清掉（2026-09-06）。
                            // 滚动/hitTest 校准走合成事件（window=nil），syncInteractiveHover
                            // 会跳过 → chip 的 hideTip 不执行，已弹气泡残留；此处兜底必清
                            self?.dismissSubAccountTip()
                            for case let item as SubAccountItemView in strip.arrangedSubviews {
                                item.setHovered(false)
                            }
                            // 账号条尚未显示（驻留未满）：无换出对象，点阵保持原样。
                            // 离场 = chip 交错下沉淡出（staggerRiseIn 镜像）+ 点阵透明度恢复
                            if !strip.isHidden, !stripExitInFlight {
                                subStripSwapEpoch += 1   // 作废在途换入的点阵落藏 guard + 在途 stagger 淡入块
                                stripExitInFlight = true
                                let exitEp = subStripSwapEpoch
                                // 积分不再 chip 化：离场无需熄灭（2026-09-06，见换入处注释）
                                let chips = strip.arrangedSubviews
                                // 冻结 chip 背景写入（mouseExited 已改为先离场块、后熄 hover，
                                // 此刻 setHovered(false) 尚未执行，model 仍是离场前颜色），
                                // 背景随后只随 chip 整体 alpha 淡出
                                for case let item as SubAccountItemView in chips {
                                    item.freezeBackground()
                                }
                                self?.staggerSinkOut(chips,
                                                     isCancelled: { exitEp != subStripSwapEpoch },
                                                     onAllFinished: {
                                    // 落藏 + chip 状态复位（alpha/transform/背景归位，供下一轮换入）
                                    guard exitEp == subStripSwapEpoch else { return }
                                    strip.isHidden = true
                                    stripZeroWidth?.isActive = true   // 落藏：恢复零宽，副标题拿回全行宽
                                    // 副标题恢复完整文案（账号条已落藏不可见）
                                    for (i, lbl) in segLabels.enumerated() {
                                        if i < segBox.full.count { lbl.stringValue = segBox.full[i]; lbl.isHidden = false }
                                        else { lbl.isHidden = true }
                                    }
                                    // 副标题右侧 meta（子账号/7日消耗）恢复显示
                                    metaStack?.isHidden = false
                                    for v in chips {
                                        v.alphaValue = 1
                                        if let l = v.layer {
                                            CATransaction.begin()
                                            CATransaction.setDisableActions(true)
                                            l.transform = CATransform3DIdentity
                                            l.removeAnimation(forKey: "staggerSink")
                                            CATransaction.commit()
                                        }
                                    }
                                    // 冻结背景复位默认态（此时已落藏不可见，无跳变）
                                    for case let item as SubAccountItemView in chips {
                                        item.resetVisualState()
                                    }
                                    stripExitInFlight = false
                                })
                                // 长进度卡片：进度条常驻（dotsIndependent），跳过点阵恢复动画
                                if !dotsIndependent {
                                // 点阵恢复放慢（dotsRestore，先慢后快、末段缓收，与 chip
                                // 快速下沉形成节奏差）。必须显式 CABasicAnimation：
                                // 落藏回写过 alpha=1，animator 的 fromValue=nil 会取 presentation(=1)
                                // 造成 1→1 空转 + 首帧全亮（「瞬间亮起」根因）
                                let dotsAlpha: CGFloat = dotsView.isHidden
                                    ? 0
                                    : CGFloat(dotsView.layer?.presentation()?.opacity
                                              ?? Float(dotsView.alphaValue))
                                dotsView.isHidden = false
                                if let layer = dotsView.layer {
                                    layer.removeAnimation(forKey: "dotsFadeSwap")
                                    layer.removeAnimation(forKey: "opacity")   // 清隐式残留
                                    // 起播值钉 model（禁隐式）：否则 hidden=false 首帧以旧 model=1 全亮
                                    CATransaction.begin()
                                    CATransaction.setDisableActions(true)
                                    layer.opacity = Float(dotsAlpha)
                                    CATransaction.commit()
                                    let anim = CABasicAnimation(keyPath: "opacity")
                                    anim.fromValue = Float(dotsAlpha)
                                    anim.toValue = Float(1)
                                    anim.duration = Motion.stripSwap.dotsRestore
                                    anim.timingFunction = Motion.stripSwap.dotsRestoreTiming
                                    layer.add(anim, forKey: "dotsRestore")
                                    CATransaction.begin()
                                    CATransaction.setDisableActions(true)
                                    layer.opacity = 1   // model 落终位（播完动画移除即停在 1）
                                    CATransaction.commit()
                                } else {
                                    dotsView.alphaValue = 1
                                }
                                }
                            }
                        }
                    }
                }
                // 当前账号积分按钮（chip）hover → 弹昵称+积分气泡：与子账号气泡同一实现
                //（showSubAccountTip，锚整卡、箭头贴卡侧缘），数据经 ChipTipBox 由 apply
                // 就地更新昵称/签到徽章，积分文本弹窗时从 valueView.currentText 实时读取；
                // 命中判定由 HoverCard.syncInteractiveHover 统一驱动（chip 无自有 tracking）
                if isAgentCard {
                    let tipBox = ChipTipBox(
                        nickname: ac.nickname,
                        checkin: style.checkin ? (ac.checkinDone, ac.checkinFailed, ac.checkinRisk) : nil)
                    newChipTipBox = tipBox
                    hc.chipHitRectProvider = { [weak valueView, weak cardRef] in
                        guard let card = cardRef else { return nil }
                        return valueView?.chipHitRect(in: card)
                    }
                    hc.onChipHover = { [weak self, weak cardRef, weak valueView] showing in
                        // chip 背景 hover 反馈（bgDefault↔bgHover，ChipStyle 统一档）即时切换
                        valueView?.setChipHovered(showing)
                        guard let self else { return }
                        if showing {
                            guard let card = cardRef, card.window != nil else { return }
                            self.scheduleChipTip { [weak self, weak cardRef, weak valueView, tipBox] in
                                guard let self, let card = cardRef, card.window != nil else { return }
                                self.showSubAccountTip(nickname: tipBox.nickname,
                                                       value: valueView?.currentText ?? "—",
                                                       checkin: tipBox.checkin,
                                                       anchorCard: card)
                            }
                        } else {
                            self.cancelChipTip()
                            self.dismissSubAccountTip()
                        }
                    }
                }
                // ZCode / WorkBuddy / Codex 卡片：hover 确认（背景进度填充撑满）后切换内嵌 Token 板块，
                // 快速掠过不触发（HoverCard.hoverDwellDuration 实现进度与取消）
                if style.platformID == "zcode" || style.platformID == "wb" || style.platformID == "codex" {
                    hc.hoverDwellDuration = Motion.hoverDwell
                    let tokensSource: TokensPanelSource
                    switch style.platformID {
                    case "zcode": tokensSource = .zcode
                    case "codex": tokensSource = .codex
                    default: tokensSource = .workbuddy
                    }
                    hc.onHoverConfirmed = { [weak self] in self?.confirmTokensHover(source: tokensSource) }
                }
            }
            // 当前账号卡片等高于 DeepSeek；非当前账号卡片自适应内容高度（更小）
            if isCurrent, let ds = dsCardRef {
                card.heightAnchor.constraint(equalTo: ds.heightAnchor).isActive = true
            }
            // 非当前账号无 dots/checkinInfo（未加入视图层级），用占位保持 entry 结构一致
            entries.append(CardEntry(uid: ac.uid, valueView: valueView,
                                     titleLabel: capturedTitle ?? FadeableTextField(labelWithString: ""),
                                     dots: dots ?? UsageDots(),
                                     segmentLabels: segLabels,
                                     expireIcons: expireIcons, badgeView: badge,
                                     iconView: fadeIcon,
                                     statusRing: capturedStatusRing,
                                     menuBarDot: capturedMenuBarDot ?? NSView()))
            entries[entries.count - 1].subAccountsStrip = subStrip
            entries[entries.count - 1].dotsAlwaysVisible = true   // 进度条恒常驻（2026-09-06，hover 换入账号条不再隐藏）
            entries[entries.count - 1].subValueLabels = subValueLabels
            entries[entries.count - 1].subItems = subItems
            entries[entries.count - 1].chipTipBox = newChipTipBox
            entries[entries.count - 1].segBox = segBox
            entries[entries.count - 1].metaChangeLabel = metaChangeLabel
        }
        // ⚠️ 必须与 update() 的检测口径一致（uid + isCurrent ✓ 后缀）：
        // 旧实现只存裸 uid，导致每轮刷新都误判「uid 变化」→ 全量重建卡片，
        // 就地更新路径（数字滚动动效等）永远走不到
        uids = accounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        applyAccountCardData(accounts, entries: &entries, style: style)
    }

    /// 子账号 chip 的紧凑额度文案：无数据使用短横线；数值小于等于 0 统一显示 0，
    /// 并去掉百分号，避免出现「0%」和过长的「—」占位。
    private func subAccountDisplayValue(_ value: String?) -> String {
        guard let value else { return "-" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—", trimmed != "-" else { return "-" }
        let numericText = trimmed
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
        if let numeric = Double(numericText), numeric <= 0 {
            return "0"
        }
        return trimmed
    }

    /// 数值滚动动效：终值文本一次下发给 RollingNumberView（setText(animated:true,
    /// rollDuration:)），各位数字轮各自独立 tween 到自己的目标数字后停下（异步落定，
    /// 时长按行进格数从 rollDuration 预算分配）。视图自驱动 displayLink，无需外部
    /// 计数器；本类型只保留文本解析，供「能否滚动」判据与预览格式生成使用。
    enum NumberRollAnimator {
        /// 解析可滚动数值文本：前缀（¥/$）+ 数值 + 小数位 + 后缀（%）；不可解析返回 nil
        static func parse(_ text: String) -> (prefix: String, value: Double, decimals: Int, suffix: String)? {
            var s = text.trimmingCharacters(in: .whitespaces)
            var prefix = ""
            if let f = s.first, f == "¥" || f == "$" {
                prefix = String(f)
                s.removeFirst()
            }
            var suffix = ""
            if s.hasSuffix("%") {
                suffix = "%"
                s.removeLast()
            }
            let core = s.replacingOccurrences(of: ",", with: "")
            guard !core.isEmpty, core.contains(where: { $0.isNumber }),
                  let v = Double(core) else { return nil }
            let parts = core.split(separator: ".", omittingEmptySubsequences: false)
            let decimals = parts.count == 2 ? parts[1].count : 0
            return (prefix, v, decimals, suffix)
        }
    }


    /// 应用多号卡片数据：余额、昵称、点阵、签到信息、到期倒计时（重建后或就地刷新时调用）
    private func applyAccountCardData(_ accounts: [AccountCardSnapshot],
                                      entries: inout [CardEntry],
                                      style: CardStyle) {
        for (i, ac) in accounts.enumerated() where i < entries.count {
            let e = entries[i]
            // 余额数值：就地更新且数值变化 → 数字滚动动效（Number Rolling，逐位车轮垂直滚动）。
            // 首次赋值（重建后 lastValue 为空）/ 减弱动态 / 非数值（—）→ 直接落值；
            // 面板不可见且视图已是真实数值 → 不落值（视图保持旧显示，挂起到下次打开由
            // scheduleOpenReroll 统一下发：有变化从旧值滚到新值，未变化原地不动）；
            // 占位「—」阶段不受挂起闸限制（启动预读）：首次数据到达即直接落位，打开即显示。
            let oldValue = entries[i].lastValue
            let newValue = ac.value ?? "—"
            entries[i].lastValue = newValue
            if oldValue != newValue {
                if valueScrollPreviewEnabled {
                    // 数值滚动预览模式：显示由预览定时器接管（周期随机值 + 滚动），
                    // 这里只维护真实 lastValue，供关闭预览时恢复。
                } else if e.valueView.window == nil, e.valueView.currentText != "—" {
                    // 面板不可见且视图已是真实数值：挂起不下发（见上），lastValue 已维护为最新
                } else {
                    let rollable = !oldValue.isEmpty && oldValue != "—" && newValue != "—"
                        && NumberRollAnimator.parse(oldValue) != nil
                        && NumberRollAnimator.parse(newValue) != nil
                    Logger.log(.layout, "[Roll] \(style.platformID) uid=\(ac.uid.suffix(6)) old=\(oldValue) new=\(newValue) win=\(e.valueView.window != nil) rollable=\(rollable) motion=\(!shouldReduceMotion)")
                    if rollable, !shouldReduceMotion {
                        // 终值一次下发：视图自驱动，各位车轮独立 tween、异步落定
                        e.valueView.setText(newValue, animated: true, rollDuration: Motion.roll)
                    } else {
                        e.valueView.setText(newValue, animated: false)
                    }
                }
            }
            // Agent 卡其余账号条：积分文本随刷新更新（条结构/icon 随卡片重建）
            if !e.subValueLabels.isEmpty {
                let subs = accounts.filter { !$0.isCurrent }
                for (j, lbl) in e.subValueLabels.enumerated() where j < subs.count {
                    lbl.stringValue = subAccountDisplayValue(subs[j].value)
                    // 末字符可能变（rsb 随字符/字体变）：右内缩进重新回补
                    if j < e.subItems.count { e.subItems[j].refreshOpticalPadding() }
                }
                // 悬浮气泡数据同步（tokenInvalid 徽章 + 积分文本，随就地刷新更新）
                for (j, item) in e.subItems.enumerated() where j < subs.count {
                    item.valueText = subAccountDisplayValue(subs[j].value)
                    item.tokenInvalid = subs[j].tokenInvalid
                }
            }
            // 当前账号积分 chip 气泡数据（昵称/签到徽章随刷新就地更新；积分文本
            // 弹窗时从 valueView.currentText 实时读取，不在此缓存）
            e.chipTipBox?.nickname = ac.nickname
            e.chipTipBox?.checkin = style.checkin ? (ac.checkinDone, ac.checkinFailed, ac.checkinRisk) : nil
            // 当日签到失败/风控或调试模式 → icon 右上角显示角标（ZCode 无签到，仅调试模式）；
            // 风控（checkinRisk）角标橙黄色（偏黄），普通失败保持系统红色
            e.badgeView.isHidden = !ac.checkinFailed
            if let badgeImg = e.badgeView as? NSImageView {
                badgeImg.contentTintColor = ac.checkinRisk ? NSColor(calibratedRed: 1, green: 0.78, blue: 0, alpha: 1) : .systemRed
            }
            // 到期副标题分段（无值时全部 isHidden 收起，占位保持行高稳定）；副标题统一中性灰
            // （2026-08-27：「套餐已到期」取消红色警告，与其他到期文本一致用副前景灰）
            // TRAE 已停止维护：副标题固定「官方加密」+ 前面一颗 xmark（2026-09-15 用户「副标题写 x官方加密」），
            // 「积分下方」那三颗 xmark 是另一处（trailingMarkView）
            let segs = style.platformID == "trae" ? ["官方加密"] : (ac.expireSegments ?? [])
            e.segBox?.full = segs
            // 账号条换入期间保持精简文案（单一事实源 = 账号条可见性）：hover 中途刷新
            // 不把完整文案顶回来，破坏副标题给账号条让位的约定
            let shownSegs = (e.subAccountsStrip?.isHidden ?? true) ? segs : compactExpireSegments(segs)
            for (i, lbl) in e.segmentLabels.enumerated() {
                if i < shownSegs.count {
                    lbl.stringValue = shownSegs[i]
                    lbl.isHidden = false
                } else {
                    lbl.isHidden = true
                }
                lbl.textColor = Palette.secondaryForeground
            }
            e.expireIcons.forEach { $0.contentTintColor = Palette.secondaryForeground }
            // 副标题右侧 meta：Agent 卡 = 最近 10 次会话均速「x tok/s」（无会话数据隐藏）；
            // API 卡 = 箭头附件 + 24h 变化量（dayDeltaText 恒有值，2026-09-13 用户指定不隐藏）；
            // 子账号数随重建走（账号增减触发 uid 变化重建），apply 不更新
            if let lbl = e.metaChangeLabel {
                // 兜底走 PanelFont（label 经 registerFont，font 恒非 nil；此处只防 SG 档翻转后取到旧字体）
                let font = lbl.font ?? uiFont(size: Palette.cardSubFontSize)
                if let text = ac.speedText {
                    lbl.attributedStringValue = NSAttributedString(string: text, attributes: [
                        .font: font, .foregroundColor: Palette.secondaryForeground])
                    lbl.isHidden = false
                } else if let text = ac.dayDeltaText {
                    lbl.attributedStringValue = Self.dayDeltaAttributed(
                        direction: ac.dayDeltaDirection, text: text, font: font,
                        appearance: effectiveAppearance)
                    lbl.isHidden = false
                } else {
                    lbl.isHidden = true
                }
            }
            // 菜单栏显隐指示：显示在菜单栏 → icon 下方小白点点亮；原渐变遮罩已移除
            e.menuBarDot.isHidden = !ac.inMenuBar
            // 任务状态光环：Agent 卡 = 快照 taskState（WB/ZCode/Codex 实际任务态/调试轮派）；
            // API 脉冲驱动卡（pulseDriven，taskState 恒 nil）= 进度条闪烁时点亮进行中态
            if let ring = e.statusRing {
                ring.taskState = ac.taskState ?? ((ring.pulseDriven && ac.pulsing) ? .running : nil)
            }
            // 非当前账号卡片无 dots/签到信息（未加入视图层级），跳过更新
            guard ac.isCurrent else { continue }
            // 有余额数据（value 非空）→ 按剩余比例点亮（100% 未用时 usedRatio=0 → 满格绿）；
            // 无数据（value 为空）→ 全灰，避免误显满格
            if ac.value != nil {
                e.dots.ratio = CGFloat(min(1, max(0, 1 - ac.usedRatio)))
            } else {
                e.dots.ratio = 0
            }
            e.dots.pulsing = ac.pulsing
            // DeepSeek 未配置日常额度时隐藏点阵（多号平台恒 false 不受影响）。
            // Agent 卡 hover 期间其余账号条可见（strip 未隐藏）→ 点阵强制保持隐藏：
            // 否则本行每次刷新都按 hideDots 重显点阵，叠在按钮上（点阵「无故冒出」根因
            // =显隐有两个写入方，此处合成两态为单一事实）
            e.dots.isHidden = ac.hideDots || (!e.dotsAlwaysVisible && !(e.subAccountsStrip?.isHidden ?? true))
        }
    }

    // MARK: - 账号气泡（子账号项 / 当前账号积分 chip 共用；用量 hover 子面板同机制的迷你版）

    /// 显示中的账号气泡窗（hover 移开/面板关闭/卡片重建即收）
    private var subAccountTipWindow: NSWindow?
    /// 当前账号积分 chip 的气泡挂起任务（0.3s 防扫过，与子账号 tip 同手感）
    private var chipTipWork: DispatchWorkItem?

    private func scheduleChipTip(_ fire: @escaping () -> Void) {
        chipTipWork?.cancel()
        let item = DispatchWorkItem(block: fire)
        chipTipWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func cancelChipTip() {
        chipTipWork?.cancel()
        chipTipWork = nil
    }

    /// 当前账号积分 chip 气泡数据盒（class：构建闭包捕获 + apply 就地更新的引用语义）：
    /// 副标题 meta 的富文本：方向箭头附件 + 变化量数值（2026-09-13）。
    /// attachment 画布底贴基线是 TextKit 原生口径——独立 icon 视图的
    /// centerY / stack firstBaseline / 手动钉基线三种钉法逐一实测箭头偏低才改此路线；
    /// 箭头↔数值 1pt 间隔烘进附件画布右侧（不用空格字符，U+2007 口径已废）。
    /// 附件高度取位图原高、不做拉伸；基线微调只动 dayDeltaAttachmentBaselineY。
    static func dayDeltaAttributed(direction: DayDeltaDirection, text: String,
                                   font: NSFont, appearance: NSAppearance) -> NSAttributedString {
        let symbol: String
        switch direction {
        case .up: symbol = "arrowtriangle.up"
        case .down: symbol = "arrowtriangle.down"
        case .flat: symbol = "arrowtriangle.right"
        }
        let s = NSMutableAttributedString()
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6.5, weight: .medium)) {
            let tinted = tintedTemplateImage(base, color: Palette.secondaryForeground,
                                             appearance: appearance, rightPad: 1)
            let attachment = NSTextAttachment()
            attachment.image = tinted
            attachment.bounds = CGRect(x: 0, y: Self.dayDeltaAttachmentBaselineY,
                                       width: tinted.size.width, height: tinted.size.height)
            s.append(NSAttributedString(attachment: attachment))
        }
        s.append(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: Palette.secondaryForeground]))
        return s
    }
    /// 附件垂直偏移（0 = SF 画布底贴基线，墨迹底略高于基线为画布留白；负值下移）
    static let dayDeltaAttachmentBaselineY: CGFloat = 0

    /// template 图按色重绘成实色位图（NSTextAttachment 内 template 不随文本前景色）；
    /// rightPad = 画布右侧追加留白（做与后文的间距，图像本身不拉伸）。
    /// ⚠️ 色值必须按**传入视图的外观**解算：lockFocus 里 `NSAppearance.current` 是系统外观，
    /// 浅色主题（面板强制 aqua）下直读动态色会解到深色分支 —— 与 `borderCGColor(_:in:)` 同一条坑
    static func tintedTemplateImage(_ image: NSImage, color: NSColor, appearance: NSAppearance,
                                    rightPad: CGFloat = 0) -> NSImage {
        let size = NSSize(width: image.size.width + rightPad, height: image.size.height)
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        appearance.performAsCurrentDrawingAppearance {
            color.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        }
        out.unlockFocus()
        return out
    }

    /// 昵称 + 签到徽章状态；积分文本弹窗时从 valueView.currentText 实时读取（防陈旧）
    final class ChipTipBox {
        var nickname: String
        /// 签到状态（nil = 无签到平台不挂徽章）
        var checkin: (done: Bool, failed: Bool, risk: Bool)?
        init(nickname: String, checkin: (done: Bool, failed: Bool, risk: Bool)?) {
            self.nickname = nickname
            self.checkin = checkin
        }
    }

    /// SF Symbol 着色位图（模板图 sourceAtop 叠色保留 alpha 形状；徽章附件共用）
    private static func tintedSymbol(_ name: String, size: CGFloat, tint: NSColor) -> NSImage? {
        guard let base = trimmedSymbolImage(name, size: size) else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// 以整张卡片为锚弹出账号气泡（子账号项 hover / 当前账号积分 chip hover 共用）：
    /// 内容两行（2026-09-02 用户定稿）：第一行「昵称:xxx 徽章」、第二行「积分:xxxx」，
    /// 均为 9pt（Palette.cardSubFontSize）+ cardForeground 亮色前景；徽章二选一——
    /// 令牌失效黄胶囊（子账号 tokenInvalid）/ 签到状态 seal 徽章（当前账号，
    /// 绿=已签 / 红=失败 / 橙=风控，原卡片昵称行徽章口径迁移至此）。
    /// 行带 = 文本实际行高（不足 10pt 兜 10）；行距 2、上下内边距 4;
    /// 内容块在气泡内垂直居中,与卡片 content stack 居中规则一致。
    /// 自绘 borderless 窗口替代 NSPopover（系统 popover 圆角不受控、比卡片更圆）：
    /// 背景 = 主面板同款 TintedVisualEffectView 玻璃（.menu/behindWindow）并继承面板
    /// 当前生效遮罩色（用量子面板同口径）,按「圆角矩形+箭头」路径做 layer mask 裁切,
    /// 圆角统一 Palette.cardCornerRadius。默认弹卡片右侧（箭头顶点贴卡右缘）,
    /// 右侧屏幕空间不足时翻到左缘。
    /// **无描边**（2026-09-15 用户：「去掉边框，继承主面板的边框属性」—— 主面板容器
    /// 自身就没有描边，气泡随之一致；原 0.5pt hoverBorderBright 覆盖层已删）
    /// （原 `panelTintSample`：按锚点视图在容器中的高度插值采样遮罩色的实现，
    ///  2026-09-14 用户要求气泡背景「继承面板背景色上端的颜色」后已删除 —— 见 showSubAccountTip）

    private func showSubAccountTip(nickname: String, value: String, tokenInvalid: Bool = false,
                                   checkin: (done: Bool, failed: Bool, risk: Bool)? = nil,
                                   anchorCard: NSView) {
        cancelChipTip()
        guard let anchorWindow = anchorCard.window else { return }
        let nick = NSTextField(labelWithString: "昵称: \(nickname)")
        // 两行统一：小字（cardSubFontSize）+ 亮色前景 cardForeground。
        // ⚠️ 字体**恒走系统档，且不进 registerFont**：
        // ① SG 是拉丁字体，9pt 下 ascender/descender = 7.2/1.8（标称行框 9），而气泡内容是中文
        //    （字形走 cascade 兜底的 PingFang，CTLine 实测行高 12.6）——label 按那套偏矮的度量排版，
        //    会把整块文字在气泡内压低 ~4.3pt（离线 harness 实测：SG 档上留白 14.3 / 下留白 5.7，
        //    同口径系统档 8 / 10）。气泡文字是「中文标签 + 昵称/数字」，度量按系统档取才与字形一致。
        // ② 不注册 = SG 档开关翻转时不会被 applyPanelFonts 改回 SG（气泡是临时视图，无跟随必要）
        nick.font = PanelFont.system(size: Palette.cardSubFontSize, weight: .medium)
        nick.textColor = Palette.cardForeground
        // 徽章挂昵称后（字体取 nick 实际字体，经 registerFont 已生效）
        let line = NSMutableAttributedString(
            string: "昵称: \(nickname)",
            attributes: [.font: nick.font ?? uiFont(size: Palette.cardSubFontSize, weight: .medium),
                         .foregroundColor: Palette.cardForeground])
        if tokenInvalid, let font = nick.font {
            // 令牌失效/账号无套餐（账号级问题，不进刷新失败）：黄色警示胶囊。
            // icon 用 SF Symbol 附件（黄色，随昵称字号等比行内居中）——
            // ⚠︎ 文本字形在 10pt 下渲染不完整且与文字间空隙偏宽，故弃用；
            // icon 紧贴「令牌失效」文本（零字间距），胶囊底色黄@18%
            // 颜色按生效外观分档（2026-09-06 用户指定「浅色主题下加深确保对比度」）：
            // 深色 = 原 #FFC700；浅色 = 加深琥珀 #B87800（原黄在亮玻璃底上对比不足）。
            // 解算口径与品牌图标同源（panelAppearance 强制档优先，浅色主题开关下不漂）
            let tipAppearance = Palette.panelAppearance(lightTheme: lightThemeEnabled)
                ?? NSApp.effectiveAppearance
            let tint = tipAppearance.isDark
                ? NSColor(calibratedRed: 1, green: 0.78, blue: 0, alpha: 1)
                : NSColor(calibratedRed: 0.72, green: 0.47, blue: 0, alpha: 1)
            let badgeBg = NSColor(calibratedRed: 1, green: 0.78, blue: 0, alpha: 0.18)
            line.append(NSAttributedString(string: "\u{2009}"))
            // 胶囊内边距（thin space ≈ 0.8pt @10pt）：首尾 thin space + icon 附件均带背景色，
            // 与文字区段连成完整胶囊
            let padAttrs: [NSAttributedString.Key: Any] = [.font: font, .backgroundColor: badgeBg]
            line.append(NSAttributedString(string: "\u{2009}", attributes: padAttrs))
            // 徽章图标按昵称行字号的 0.85 取（跟随字号变化，避免图标过肥/过瘦）
            let size: CGFloat = round(font.pointSize * 0.85)
            if let colored = Self.tintedSymbol("exclamationmark.triangle.fill", size: size, tint: tint) {
                let att = NSTextAttachment()
                att.image = colored
                att.bounds = NSRect(x: 0, y: (font.ascender + font.descender - size) / 2,
                                    width: size, height: size)
                line.append(NSAttributedString(attachment: att, attributes: padAttrs))
            }
            line.append(NSAttributedString(
                string: "令牌失效",
                attributes: [.font: font, .foregroundColor: tint, .backgroundColor: badgeBg]))
            line.append(NSAttributedString(string: "\u{2009}", attributes: padAttrs))
        } else if let c = checkin, let font = nick.font {
            // 签到状态徽章（checkmark.seal 着色，仅用颜色区分状态；未签/无状态不追加）
            let tint: NSColor? = c.done ? .systemGreen
                : (c.risk ? NSColor(calibratedRed: 1, green: 0.78, blue: 0, alpha: 1)
                   : (c.failed ? .systemRed : nil))
            if let tint, let colored = Self.tintedSymbol("checkmark.seal", size: 10, tint: tint) {
                let att = NSTextAttachment()
                att.image = colored
                // 垂直定位与菜单栏平台图标同一公式：在字体行框内垂直居中
                //（ascender+descender = 行高；size=图标高），全 app 口径统一
                let size: CGFloat = 10
                att.bounds = NSRect(x: 0, y: (font.ascender + font.descender - size) / 2,
                                    width: size, height: size)
                line.append(NSAttributedString(string: "\u{2009}"))
                line.append(NSAttributedString(attachment: att))
            }
        }
        // 单行模式：禁 wraps（label cell 默认折行——宽度一旦低估，尾部徽章被折进
        // 第二行、被单行高裁没，实测「徽章不显示 + 长昵称缺尾」即此根因），超宽 clipping 兜底
        nick.usesSingleLineMode = true
        nick.lineBreakMode = .byClipping
        nick.attributedStringValue = line
        let val = NSTextField(labelWithString: "积分: \(value)")
        // 同上：系统档字体，不注册（理由见 nick 处注释）
        val.font = PanelFont.system(size: Palette.cardSubFontSize, weight: .medium)
        val.textColor = Palette.cardForeground
        val.usesSingleLineMode = true
        val.lineBreakMode = .byClipping
        // 度量：直接量属性串（附件按 attachment.bounds 计入），不信 intrinsicContentSize——
        // 含附件/部分字体组合下 cellSize 低估宽度，正是徽章被裁的根因
        let valLine = NSAttributedString(
            string: "积分: \(value)",
            attributes: [.font: val.font ?? uiFont(size: Palette.cardSubFontSize, weight: .medium),
                         .foregroundColor: Palette.cardForeground])
        val.attributedStringValue = valLine
        let nickSize = line.size()
        let vw = valLine.size()
        let bodyW = ceil(max(nickSize.width, vw.width)) + 20
        // 行带按**字体行高**取，不看 attributedString.size()：昵称行带徽章附件时那个 height
        // 会被附件撑到 14（无徽章的平台只有 11）→ 气泡行距与整体高各差 3pt，正是
        // 2026-09-14 用户「两个平台的悬浮气泡行距不一样」的根因。两行同字号 ⇒ 同一个 bandH。
        // 徽章图标本就按 ascender+descender 在字体行框内居中（见上面 att.bounds），收紧行带不会裁它
        let bandFont = nick.font ?? uiFont(size: Palette.cardSubFontSize, weight: .medium)
        let bandH = ceil(bandFont.ascender - bandFont.descender + bandFont.leading)
        let titleBand: CGFloat = max(10, bandH)
        let infoBand: CGFloat = max(10, bandH)
        // 上下 4pt + 行距 2；气泡高 = max(锚点卡高, 内容自然高)——内容可能
        // 高于卡高，取较大者避免文字溢出裁切
        let rowGap: CGFloat = 2
        let vPad: CGFloat = 4
        let contentH = vPad * 2 + titleBand + rowGap + infoBand
        let h = max(anchorCard.frame.height, contentH)
        let yOff = (h - contentH) / 2
        let arrowLen = SubAccountTipBubbleView.arrowLength
        let totalW = bodyW + arrowLen
        var edge: NSRectEdge = .maxX
        if let visible = anchorWindow.screen?.visibleFrame,
           visible.maxX - anchorWindow.frame.maxX < totalW + 16 {
            edge = .minX
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: h))
        // 玻璃本体：与主面板同材质,继承面板容器当前生效遮罩色（用量子面板同口径）;
        // 按气泡轮廓做 layer mask 裁切（mask 作用于整个子树,含 TintOverlayView 遮罩层）
        let glass = TintedVisualEffectView(frame: container.bounds)
        glass.autoresizingMask = [.width, .height]
        glass.material = .menu
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.isEmphasized = false
        // 背景**继承面板底色上端色**（2026-09-14 用户要求）：顶/底取同一个值 ⇒ 气泡是一整块实色，
        // 不随锚点卡在面板中的高度变色。（面板无遮罩时 top 为 nil ⇒ TintOverlayView 不绘制，
        // 裸露气泡自身的毛玻璃）
        let colors = Palette.containerColors(background: panelBackgroundColor)
        glass.tintColor = colors.top
        glass.tintBottomColor = colors.top
        let shape = SubAccountTipBubbleView.tipShapePath(bounds: container.bounds, edge: edge)
        let maskImage = NSImage(size: container.frame.size)
        maskImage.lockFocus()
        NSColor.white.setFill()
        shape.fill()
        maskImage.unlockFocus()
        let maskLayer = CALayer()
        maskLayer.frame = CGRect(origin: .zero, size: container.frame.size)
        maskLayer.contents = maskImage
        glass.wantsLayer = true
        glass.layer?.masksToBounds = true
        glass.layer?.mask = maskLayer
        container.addSubview(glass)
        // 气泡**不再有描边**（2026-09-15 用户：「去掉卡片子账号悬浮气泡的边框，继承主面板的
        // 边框属性」）—— 主面板容器自身就没有描边（只有 Palette.cardCornerRadius 圆角 +
        // 玻璃 + 系统阴影，见 BalancePanelViewController.loadView），气泡随之一致：
        // 原「轮廓描边覆盖层」（独立于 mask 之外、0.5pt Palette.hoverBorderBright 自绘）
        // 已随之删除。轮廓形状仍由上面 glass 的 layer mask 提供（只是不描边）
        // 非 flipped 容器：y 自底向上——积分行带在下、昵称行带在上,文本在行带内垂直居中;
        // 文本左缘 = 本体左缘 + 10（箭头顶点在窗口左缘时本体右移 arrowLen）
        let textX: CGFloat = (edge == .maxX ? arrowLen : 0) + 10
        val.frame = NSRect(x: textX, y: yOff + vPad + (infoBand - ceil(vw.height)) / 2,
                           width: ceil(vw.width) + 4, height: ceil(vw.height))
        nick.frame = NSRect(x: textX, y: yOff + vPad + infoBand + rowGap + (titleBand - ceil(nickSize.height)) / 2,
                            width: ceil(nickSize.width) + 4, height: ceil(nickSize.height))
        container.addSubview(nick)
        container.addSubview(val)
        let win = NSWindow(contentRect: container.frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true   // 纯提示,不拦截鼠标（避免盖住卡片引发 hover 抖动）
        win.level = NSWindow.Level(rawValue: anchorWindow.level.rawValue + 1)
        win.collectionBehavior = [.transient, .ignoresCycle]
        win.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled)
        win.contentView = container
        // 箭头顶点对准卡片侧边中点（贴边 2pt,与原 popover 锚点口径一致）
        let cardRect = anchorWindow.convertToScreen(anchorCard.convert(anchorCard.bounds, to: nil))
        let originX = edge == .maxX ? cardRect.maxX - 2 : cardRect.minX + 2 - totalW
        win.setFrameOrigin(NSPoint(x: originX, y: cardRect.midY - h / 2))
        subAccountTipWindow?.orderOut(nil)   // 换卡重新锚定
        subAccountTipWindow = win
        win.orderFrontRegardless()
    }

    /// 收起账号气泡（幂等）；顺带取消挂起中的积分 chip 气泡任务
    func dismissSubAccountTip() {
        cancelChipTip()
        subAccountTipWindow?.orderOut(nil)
        subAccountTipWindow = nil
    }

    /// 气泡轮廓（圆角矩形+一侧三角箭头，圆角 = Palette.cardCornerRadius 与卡片统一）。
    /// **只提供 `tipShapePath` 给玻璃层做 layer mask 裁切** —— 气泡不再自绘描边
    /// （2026-09-15 用户：「去掉卡片子账号悬浮气泡的边框，继承主面板的边框属性」：
    ///  主面板容器本身就没有描边，原先那层 0.5pt `hoverBorderBright` 覆盖层已删除；
    ///  故本类型也不再需要 NSView 身份 —— 实例属性 arrowEdge / tipY 与 draw 一并移除）
    private enum SubAccountTipBubbleView {
        static let arrowLength: CGFloat = 8
        static let arrowHalfWidth: CGFloat = 6

        /// 单轮廓路径（bounds 局部坐标）：逆时针 上缘→右上弧→右缘（.minX 嵌箭头）
        /// →右下弧→下缘→左下弧→左缘（.maxX 嵌箭头）→左上弧→闭合。
        /// 箭头顶点恒在垂直中线（原「高气泡/调色弹层」按锚点注入 tipY 的入口已随
        /// 描边层一起删除 —— 气泡现在只此一个消费方）
        static func tipShapePath(bounds: NSRect, edge: NSRectEdge) -> NSBezierPath {
            let r = Palette.cardCornerRadius
            // 轮廓内缩 0.25pt：mask 抗锯齿边缘留余量（原为「描边半宽，防轮廓被裁」，
            // 描边已删，这半像素余量继续用于避免玻璃边缘被切出发丝）
            let inset: CGFloat = 0.25
            let body: NSRect
            let tipX: CGFloat
            if edge == .maxX {
                body = NSRect(x: bounds.minX + arrowLength, y: bounds.minY + inset,
                              width: bounds.width - arrowLength - inset,
                              height: bounds.height - inset * 2)
                tipX = bounds.minX + inset
            } else {
                body = NSRect(x: bounds.minX + inset, y: bounds.minY + inset,
                              width: bounds.width - arrowLength - inset,
                              height: bounds.height - inset * 2)
                tipX = bounds.maxX - inset
            }
            let midY = bounds.midY
            let path = NSBezierPath()
            path.move(to: NSPoint(x: body.minX + r, y: body.maxY))
            path.line(to: NSPoint(x: body.maxX - r, y: body.maxY))
            path.appendArc(withCenter: NSPoint(x: body.maxX - r, y: body.maxY - r),
                           radius: r, startAngle: 90, endAngle: 0, clockwise: true)
            if edge == .minX {
                path.line(to: NSPoint(x: body.maxX, y: midY + arrowHalfWidth))
                path.line(to: NSPoint(x: tipX, y: midY))
                path.line(to: NSPoint(x: body.maxX, y: midY - arrowHalfWidth))
            }
            path.line(to: NSPoint(x: body.maxX, y: body.minY + r))
            path.appendArc(withCenter: NSPoint(x: body.maxX - r, y: body.minY + r),
                           radius: r, startAngle: 0, endAngle: -90, clockwise: true)
            path.line(to: NSPoint(x: body.minX + r, y: body.minY))
            path.appendArc(withCenter: NSPoint(x: body.minX + r, y: body.minY + r),
                           radius: r, startAngle: -90, endAngle: 180, clockwise: true)
            if edge == .maxX {
                path.line(to: NSPoint(x: body.minX, y: midY - arrowHalfWidth))
                path.line(to: NSPoint(x: tipX, y: midY))
                path.line(to: NSPoint(x: body.minX, y: midY + arrowHalfWidth))
            }
            path.line(to: NSPoint(x: body.minX, y: body.maxY - r))
            path.appendArc(withCenter: NSPoint(x: body.minX + r, y: body.maxY - r),
                           radius: r, startAngle: 180, endAngle: 90, clockwise: true)
            path.close()
            return path
        }
    }

    // MARK: - 三平台卡片入口（薄封装，仅绑定容器/样式/回调）

    private func rebuildDsCards(_ accounts: [AccountCardSnapshot]) {
        // DS 卡是全平台等高基准：重建期间清空引用避免自锚定，重建后指向新卡；
        // update() 中 DS 重建先于其他平台，同帧内后续平台的等高约束即锚到新卡
        dsCardRef = nil
        rebuildAccountCards(accounts, style: .ds, container: dsCardsContainer,
                            entries: &dsCardEntries, uids: &dsCardUids,
                            onCurrentClick: { [weak self] in self?.onClickDeepSeek?() },
                            onSwitch: nil)
        dsCardRef = dsCardsContainer.arrangedSubviews.first
    }
    private func applyDsCardData(_ accounts: [AccountCardSnapshot]) {
        applyAccountCardData(accounts, entries: &dsCardEntries, style: .ds)
    }

    private func rebuildZhiPuCards(_ accounts: [AccountCardSnapshot]) {
        rebuildAccountCards(accounts, style: .zhipu, container: zhipuCardsContainer,
                            entries: &zhipuCardEntries, uids: &zhipuCardUids,
                            onCurrentClick: { [weak self] in self?.onClickZhiPu?() },
                            onSwitch: nil)
    }
    private func applyZhiPuCardData(_ accounts: [AccountCardSnapshot]) {
        applyAccountCardData(accounts, entries: &zhipuCardEntries, style: .zhipu)
    }

    private func rebuildQwenCards(_ accounts: [AccountCardSnapshot]) {
        rebuildAccountCards(accounts, style: .qwen, container: qwenCardsContainer,
                            entries: &qwenCardEntries, uids: &qwenCardUids,
                            onCurrentClick: { [weak self] in self?.onClickQwen?() },
                            onSwitch: nil)
    }

    private func applyQwenCardData(_ accounts: [AccountCardSnapshot]) {
        applyAccountCardData(accounts, entries: &qwenCardEntries, style: .qwen)
    }

    private func rebuildZcodeCards(_ accounts: [AccountCardSnapshot]) {
        rebuildAccountCards(accounts, style: .zcode, container: zcodeCardsContainer,
                            entries: &zcodeCardEntries, uids: &zcodeCardUids,
                            onCurrentClick: { [weak self] in self?.onClickZcode?() },
                            onSwitch: { [weak self] uid in self?.onSwitchZcodeAccount?(uid) })
    }
    private func applyZcodeCardData(_ accounts: [AccountCardSnapshot]) {
        applyAccountCardData(accounts, entries: &zcodeCardEntries, style: .zcode)
    }

    private func rebuildCodexCards(_ accounts: [AccountCardSnapshot]) {
        rebuildAccountCards(accounts, style: .codex, container: codexCardsContainer,
                            entries: &codexCardEntries, uids: &codexCardUids,
                            onCurrentClick: { [weak self] in self?.onClickCodex?() },
                            onSwitch: { [weak self] uid in self?.onSwitchCodexAccount?(uid) })
    }
    private func applyCodexCardData(_ accounts: [AccountCardSnapshot]) {
        applyAccountCardData(accounts, entries: &codexCardEntries, style: .codex)
    }

    /// TRAE 卡副标题行右侧的三颗 ×（2026-09-15 用户）：9pt 一颗、`spacing = 0` 紧贴（「不要空格」）、
    /// 色走副前景灰。走**系统字体档** —— SG 是拉丁字体，`✕` 的字符度量会带出莫名的垂直偏移
    ///（同日悬浮气泡踩过同一个坑：SG 的行框装不下中文/符号字形）
    private static func makeTripleX() -> NSView {
        let row = NSStackView(views: (0..<3).map { _ -> NSTextField in
            let lbl = NSTextField(labelWithString: "✕")   // U+2715 MULTIPLICATION X
            lbl.font = PanelFont.system(size: Palette.cardSubFontSize, weight: .medium)
            lbl.textColor = Palette.secondaryForeground
            lbl.usesSingleLineMode = true
            lbl.lineBreakMode = .byClipping
            lbl.setContentHuggingPriority(.required, for: .horizontal)
            lbl.setContentCompressionResistancePriority(.required, for: .horizontal)
            return lbl
        })
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func rebuildTraeCards(_ accounts: [AccountCardSnapshot]) {
        rebuildAccountCards(accounts, style: .trae, container: traeCardsContainer,
                            entries: &traeCardEntries, uids: &traeCardUids,
                            onCurrentClick: { [weak self] in self?.onClickTrae?() },
                            onSwitch: { [weak self] uid in self?.onSwitchTraeAccount?(uid) })
    }
    private func applyTraeCardData(_ accounts: [AccountCardSnapshot]) {
        applyAccountCardData(accounts, entries: &traeCardEntries, style: .trae)
    }

    private func rebuildWbCards(_ accounts: [AccountCardSnapshot]) {
        rebuildAccountCards(accounts, style: .wb, container: wbCardsContainer,
                            entries: &wbCardEntries, uids: &wbCardUids,
                            onCurrentClick: { [weak self] in self?.onClickWorkBuddy?() },
                            onSwitch: { [weak self] uid in self?.onSwitchWbAccount?(uid) })
    }
    private func applyWbCardData(_ accounts: [AccountCardSnapshot]) {
        applyAccountCardData(accounts, entries: &wbCardEntries, style: .wb)
    }

    /// 刷新动效：开始 → header 的「更新于」区域脉冲显示「刷新中…」；结束 → 停止动画并立即恢复真实时间文本。
    /// 设计：刷新收尾快照去重（same=true）时，后续 `Panel.update` 会跳过，header 就会卡在"刷新中…"直到下次快照变化。
    /// 所以 `setRefreshing(false)` **不依赖下一次 update**，直接按 lastSnapshot（或传入快照）把文字写回去。
    func setRefreshing(_ on: Bool, fallback: PanelSnapshot? = nil) {
        guard on != isRefreshing else {
            Logger.log(.refresh, "Panel.setRefreshing(\(on)): no-op (isRefreshing already \(isRefreshing))")
            return
        }
        isRefreshing = on
        if on {
            startPulseAnimation()
            updatedLabel.stringValue = "刷新中…"
            Logger.log(.refresh, "Panel.setRefreshing(true): pulse ON, label set to 刷新中…")
        } else {
            stopRefreshAnimations()
            let snap = lastSnapshot ?? fallback
            let footer: String
            if let s = snap {
                footer = s.updatedAt.isEmpty ? "尚未更新"
                    : "更新于 \(s.updatedAt)" + (s.failedText.map { " · \($0)" } ?? "")
            } else {
                footer = "尚未更新"
            }
            updatedLabel.stringValue = footer
            Logger.log(.refresh, "Panel.setRefreshing(false): pulse OFF, label restored to \"\(footer)\" (snap=\(snap != nil ? "last" : "none"))")
        }
    }

    /// 文字脉冲：透明度在 1 ↔ 0.3 间往复
    private func startPulseAnimation() {
        guard let layer = updatedLabel.layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }

    private func stopRefreshAnimations() {
        updatedLabel.layer?.removeAnimation(forKey: "pulse")
        updatedLabel.layer?.opacity = 1.0
    }

    // MARK: - 布局构建域存储属性（方法在 PanelLayout.swift 的 extension 中）

    // 调试探针：root 引用 + 各折叠区块标题引用（IBLayoutAutoTest 自动复现用）
    weak var rootViewRef: NSStackView?
    var sectionTitleViews: [String: HoverCard] = [:]
    /// root 底部上限约束（≤ panel.bottom-11）：仅为 fittingSize 预留底边距
    /// （原贴底 footer 2026-09-13 移除后从 41 收窄）；日常高度求解不应依赖它
    var rootBottomCap: NSLayoutConstraint?
    /// 字符化开关（MonoCharSwitch）切换模糊→清晰过渡的出帧源（显示器刷新率）
    var charBlurTicker: DisplayTicker?
    /// 进行中模糊过渡的目标图层（ticker 为多调用方共享：新调用接管时旧图层集
    /// 中断在中间模糊半径——不清滤镜会永久停在模糊状态，见 playCharBlurTransition）
    var charBlurLayers: [CALayer] = []

    // MARK: - 控件回调（转发给 AppDelegate 接线）

    @objc func openCockpitTapped() { onOpenCockpit?() }

    // MARK: - 数值滚动预览（保留设置卡片原「调试」开关，功能替换为演示滚动动画）

    private var valuePreviewTimer: Timer?

    /// 与配置同步（幂等）：开启后周期随机变动各卡片余额数值（保持与真实数值相同的
    /// 前缀/后缀/小数位/整数位数 → 结构不变，逐位垂直滚动）；关闭后恢复真实数值
    /// （lastValue 始终由 applyAccountCardData 维护真实值）。
    func setValueScrollPreview(_ on: Bool) {
        let running = valuePreviewTimer != nil
        guard on != running else { return }   // 定时器状态已与目标一致（幂等）
        if on {
            previewTick()   // 立即演示一次
            let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.previewTick()
            }
            RunLoop.main.add(t, forMode: .common)   // 面板交互（菜单/弹窗）期间也持续
            valuePreviewTimer = t
        } else {
            valuePreviewTimer?.invalidate()
            valuePreviewTimer = nil
            for e in allCardEntries() {
                e.valueView.setText(e.lastValue, animated: false)   // 恢复真实数值
            }
        }
    }

    /// 各平台卡片条目汇总（预览遍历 / 打开重滚补发用；值对象为类引用，结构体拷贝共享同一视图）。
    /// 新平台接入必须把它的 entries 数组加进来，漏加 = 隐藏期间挂起的数值打开后无人补发（恒显示「—」）。
    private func allCardEntries() -> [CardEntry] {
        dsCardEntries + zhipuCardEntries + qwenCardEntries + zcodeCardEntries
            + codexCardEntries + traeCardEntries + wbCardEntries
    }

    /// 预览节拍：按每张卡片真实数值的格式（前缀/后缀/小数位/整数位数）生成
    /// 随机新值，结构一致 → 数字位逐位滚动。
    /// 与真实刷新同路径：终值一次下发 + rollDuration 预算（Motion.roll），
    /// 各位车轮独立 tween、异步落定，预览节奏与真实滚动完全一致。
    /// 当前一轮未滚完被新预览值打断时，各位车轮从当前位置重新规划 tween，天然衔接。
    private func previewTick() {
        guard valuePreviewTimer != nil || valueScrollPreviewEnabled else { return }
        for e in allCardEntries() {
            guard let parsed = NumberRollAnimator.parse(e.lastValue) else { continue }
            let intDigits = max(Self.countIntegerDigits(parsed.value), 1)
            let magnitude = pow(10.0, Double(intDigits))
            let scale = pow(10.0, Double(parsed.decimals))
            // [10^(n-1), 10^n) 同整数位数的随机新值（与真实值位数一致 → 结构不变）
            let v = (Double.random(in: (magnitude / 10)...magnitude) * scale).rounded() / scale
            let text = parsed.prefix + Self.previewFormat(v, decimals: parsed.decimals) + parsed.suffix
            if e.valueView.window != nil {
                e.valueView.setText(text, animated: !shouldReduceMotion, rollDuration: Motion.roll)
            }
            // 面板不可见：不落值不启动（打开后由下个节拍续播）
        }
    }

    /// 整数位数（如 0.08 → 1 位；12.34 → 2 位；876.5 → 3 位）
    private static func countIntegerDigits(_ v: Double) -> Int {
        let a = abs(v)
        guard a >= 1 else { return 1 }
        return Int(floor(log10(a))) + 1
    }

    /// 千分位格式化（预览随机值生成用）
    private static func previewFormat(_ v: Double, decimals: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.\(decimals)f", v)
    }

    /// pin 按钮：切换置顶状态（图标/着色即时反馈），
    /// 窗口转移（popover ↔ 无边框 NSPanel 浮动窗）由 AppDelegate 处理
    @objc func pinTapped() {
        panelPinned.toggle()
        pinBtn.image = symbolImage(panelPinned ? "pin.fill" : "pin", size: 11)
        pinBtn.contentTintColor = panelPinned ? Palette.cardForeground : Palette.secondaryForeground
        dragGrabber.isHidden = !panelPinned
        onTogglePin?()
    }

    /// 外部关闭置顶浮动窗（如点击菜单栏图标）时复位 pin 状态，下次打开为普通 popover
    func resetPin() {
        panelPinned = false
        pinBtn.image = symbolImage("pin", size: 11)
        pinBtn.contentTintColor = Palette.secondaryForeground
        dragGrabber.isHidden = true
    }

    /// 置顶后可自由拖动：空白区域按下并拖动移动浮窗（子视图控件各自消费点击，
    /// responder chain 空白点击途经此处）。浮窗 isMovableByWindowBackground=false
    /// （borderless 窗口上该属性会让系统显示灰色拖动示意条），拖动由此自绘；
    /// 未置顶时保持原生行为（popover transient 点击外部关闭）。
    override func mouseDown(with event: NSEvent) {
        guard panelPinned, let window = self.window else {
            super.mouseDown(with: event)
            return
        }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        while true {
            guard let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { continue }
            if ev.type != .leftMouseDragged { break }
            let cur = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: startOrigin.x + cur.x - startMouse.x,
                                          y: startOrigin.y + cur.y - startMouse.y))
        }
    }
    @objc func quitTapped() { onQuit?() }
    @objc func openGitHubTapped() { onOpenGitHub?() }
    @objc func settingsTapped() { onOpenSettings?() }
    /// header 平台开关按钮（第六颗）：直达设置窗口「平台」pane
    @objc func platformSettingsTapped() { onOpenPlatformSettings?() }

    // MARK: - 用量色（设置窗口「主题外观 → 面板 → 用量色」色盘落值）

    /// 用量色落值（HSB 三参一把写）：持久化 + 视图树重绘（按钮图标不着色，2026-09-07 用户定稿）。
    /// 由宿主在设置窗口色盘回调里对当前面板调用。
    /// ⚠️ 三参必须一把写：`applyHeatHueInPlace` 每次调用都要清印章/淡变位图缓存并全树重刷边框，
    /// 分三次写会连着重绘三遍（原三根滑杆各自写是拖动节奏，色盘一次给整色，没必要拆）
    func applyHeatColor(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        Palette.heatPeakHue = hue
        Palette.heatPeakSaturation = saturation
        Palette.heatPeakBrightness = brightness
        applyHeatHueInPlace()
    }
    /// 面板底色遮罩 / 外观变化后重刷副前景色：`Palette.secondaryForeground` 是动态色，
    /// **只在绘制时**按当前底色解算，没进重绘队列的视图会把旧灰一直挂在屏幕上。
    /// 走整树标脏（含自绘视图：TokensPanelView / UsageDots / 用量行）——底色是低频手动改动，
    /// 一次性全刷比逐个登记持有者稳。标签类的例外不用管：卡片数据每次 update 都会重写一遍。
    func refreshSecondaryForeground() {
        var stack: [NSView] = [self]
        while let v = stack.popLast() {
            v.needsDisplay = true
            stack.append(contentsOf: v.subviews)
        }
    }
    /// **主前景色变更后的就地重刷**（2026-09-17 随参数开放新增，与上面的 `refreshSecondaryForeground`
    /// 同一条整树标脏思路）：
    /// - 绝大多数消费点是**动态色**（`Palette.cardForeground` 在绘制时经 provider 重解算
    ///   `PanelForegroundColor.resolved(dark:override:)`，读的就是运行镜像）⇒ 标 `needsDisplay` 即换色；
    /// - 两处是**定格值**，必须显式重灌：① 菜单栏显隐圆点（`CardMenuBarDotView` 的 layer 底色
    ///   cgColor 在 layout 时落 → 标 `needsLayout`）；② 卡片品牌 icon 的着色
    ///   （`resolvedCardForeground` 静态档 → `swapBrandIconsInPlace()` 整树换图）
    func refreshCardForeground() {
        var stack: [NSView] = [self]
        while let v = stack.popLast() {
            // 数字带（卡片余额数值 / Token 总计）是**烘色位图**，标脏不够 → 显式重建
            if let r = v as? RollingNumberView { r.refreshForegroundColor() }
            v.needsDisplay = true
            v.needsLayout = true
            stack.append(contentsOf: v.subviews)
        }
        swapBrandIconsInPlace()
    }

    /// 点阵色相/饱和度/明度变化就地重绘：热力图印章/淡变位图与卡片点阵均烘色，须清缓存重绘
    ///（同外观切换钩子口径）；UsageDots 两形态（横条层/竖点阵）统一走
    /// refreshHeatColors（2026-09-07 长进度卡片进度色泛化后含层路径）。
    /// 2026-09-12 起卡片边框也取用量色（hoverBorderNormal/Bright = 峰值色）：
    /// 每个安装了共享 hover 材质的视图（面板根 / 用量行容器 / Token 板块）各持一个
    /// 独立宿主实例，描边色定格在创建时——遍历逐宿主 refreshAppearance 重解算
    /// （2026-09-13 修复：原只沿 HoverCard 向上查根宿主，行级宿主描边不跟用量色）。
    func applyHeatHueInPlace() {
        refreshDotMatrixAndHoverMaterials()
    }
    /// **点阵 / 材质类颜色变更的统一就地重绘入口**（三类调用点：用量色 `applyHeatHueInPlace`、
    /// 面板底色、**次背景色** —— 三者影响的视图集合完全相同；其中「点阵背景色」与「hover 背景色」
    /// 已于 2026-09-15 合并为次背景色这一个参数）：
    /// 清烘焙缓存（热力图印章/淡变位图）+ 点阵重绘 + 每个 hover 材质宿主重解算（材质块底色 + 描边）。
    func refreshDotMatrixAndHoverMaterials() {
        var stack = subviews
        while let v = stack.popLast() {
            if let d = v as? UsageDots { d.refreshHeatColors() }
            if let t = v as? TokensPanelView { t.refreshHeatPalette() }
            v.installedHoverMaterialHost?.refreshAppearance()
            if let row = v as? HoverRowView, row.enablesHoverBorder {
                row.layer?.borderColor = Palette.borderCGColor(Palette.hoverBorderNormal, in: row)
            }
            stack.append(contentsOf: v.subviews)
        }
    }
}


// Panel.swift — NSPopover 详情面板（左键点击菜单栏图标弹出）
//
// ─── 本文件速查（改面板 UI 前先看；只写「去哪找」，不写行号——行号必漂移）────────────
// 面板配色         enum Palette（本文件）：cardBackground / cardForeground / tooltip* / heat*
// 卡片字号         Palette.cardTitleFontSize(13，主标题+数值) / cardSubFontSize(9，副标题+积分)
//                  ⚠️ 改字号改常量，勿在调用点写数字；Mono 开关走 registerFont/applyFontPolicy
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
    var wbOauthInProgress = false   // 添加账号进行中 → 按钮变「取消添加…」
    /// TRAE 采集进行中 → 按钮变「采集中…」+ 脉冲禁点（对齐 WB 反馈）
    var traeCollectInProgress = false
    /// 手动签到进行中 → 签到磁贴脉冲禁点
    var checkinInProgress = false
    var refreshIntervalSeconds: Int = 300
    /// 面板背景渐变开关（同步自配置，VC 据此决定遮罩渐变/单色）
    var panelGradientEnabled = true
    /// 浅色主题开关（同步自配置；开启时强制浅色外观，优先级高于渐变开关）
    var lightThemeEnabled = false
    /// Mono 字体开关（同步自配置；余额卡片与用量列表 JetBrainsMono ↔ 系统字体）
    var monoFontEnabled = false
    /// 数值滚动预览开关（开启后余额卡片周期随机变化，演示逐位滚动动画）
    var valueScrollPreviewEnabled = false
    /// 状态调试预览开关（开启后三态光环轮派到前三张 Agent 卡，演示进行中/完成/中断动画）
    var statusDebugPreview = false
    /// 自动检查更新开关（GitHub Releases 启动静默检查）
    var updateAutoCheckEnabled = true
}

struct AccountCardSnapshot: Equatable {
    var uid: String
    var nickname: String
    var value: String?              // 已格式化的剩余额度
    var usedRatio: Double = 0       // 已用占比（0~1），用于点阵进度
    var isCurrent: Bool = false     // 是否为当前登录账号（非当前仅 Agent 平台存在：用于占位 entry 判定与 hover 账号条数据，不渲染小卡）
    var pulsing: Bool = false       // 额度被消耗（usedRatio 上升）→ 最右亮点阵脉冲
    var expireSegments: [String]?     // 重置/套餐到期倒计时分段（["剩余","x天","HH:MM"] / 单段短语）；段间 3pt 由 stack 布局提供
    var expired: Bool = false       // Start Plan 已到期（expireSegments 显示"套餐已到期"；2026-08-27 起颜色不再标红，与其他到期文本同用 systemGray）
    var checkinDone: Bool = false   // 今日已签到
    var checkinFailed: Bool = false // 签到失败（按 failed_date==today 口径；风控日也置 true 以显示角标）
    var checkinRisk: Bool = false   // 签到失败为风控（TRAE 返回 9074/操作太频繁）→ 角标橙黄色
    var streak: Int = 0             // 连续签到天数
    var reward: Int = 0             // 最近一次签到积分奖励
    var inMenuBar: Bool = false     // 该账号数值显示在菜单栏 → 卡片 icon 叠加透明渐变标记
    var hideDots: Bool = false      // 隐藏点阵（DeepSeek 未配置日常额度时；多号平台恒 false）
    var tokenInvalid: Bool = false  // 令牌失效/账号无套餐（账号级问题）：悬浮气泡 ID 后黄色徽章，不进平台刷新失败
    var taskState: AgentTaskState? = nil  // Agent 任务状态（仅当前账号）：icon 光环（nil = 无）
}

/// 动效统一取值表（UIUX-OPTIMIZATION.md §1）：时长与曲线只允许从这里取，
/// 新增动效不得再引入裸字面量。脉冲循环（0.5/0.55/0.6）与签名动效
/// （字符模糊切换 0.35、刷新按钮旋转 0.45）保留自有参数不进表。
enum Motion {
    /// 按压反馈：100–160ms 区间，越快越跟手
    static let press: CFTimeInterval = 0.12
    /// hover 态切换（文本提亮与背景渐变统一此时长）
    static let hover: CFTimeInterval = 0.25
    /// 布局重排/换位：屏上位移
    static let layout: CFTimeInterval = 0.20
    /// 内容揭示/淡入：偶发动作稍从容
    static let reveal: CFTimeInterval = 0.24
    /// 强调动效硬顶：一切 UI 动画 ≤ 0.40
    static let emphasis: CFTimeInterval = 0.40
    /// 余额数字滚动（Number Rolling）：数据变化反馈类动效，非 UI 状态切换，
    /// 用户指定加长时长，不适用 0.40 硬顶
    static let roll: CFTimeInterval = 3.0
    /// Agent 卡 hover 确认时长：背景进度条从左到右撑满的时长，撑满才切换 Token 板块，
    /// 子账号积分条换入同此节拍（用户指定 0.8s，滤掉光标快速掠过；确认交互非装饰动效，不适用 0.40 硬顶）
    static let hoverDwell: CFTimeInterval = 0.8
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
        /// 离场下沉量（调用处取负：-y = 视觉向下）
        static let sinkOffset: CGFloat = 14
        /// 离场单块时长（easeIn 重力感，用户指定）
        static let sinkDuration: CFTimeInterval = 0.35
        /// 离场行间错峰
        static let sinkGap: CFTimeInterval = 0.06
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
        appearance.isDark
            ? NSColor(calibratedRed: 0xEB/255.0, green: 0xEB/255.0, blue: 0xEB/255.0, alpha: 1)
            : NSColor(calibratedWhite: 0.13, alpha: 1)
    }
    /// 非当前账号前景色：深色石墨灰（用户定稿 0.61）/ 浅色 0.42
    static let cardForegroundDimmed = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 0.61, alpha: 1.0)
            : NSColor(calibratedWhite: 0.42, alpha: 1.0)
    }
    /// 卡片底色：完全透明（露出容器毛玻璃）
    static let cardBackground = NSColor.clear
    /// 卡片 hover 提亮色 #333333 @ 30%
    static let cardBackgroundHover = NSColor(calibratedWhite: 51.0 / 255.0, alpha: 0.3)
    /// 统一 hover 渐变背景（余额卡片/操作磁贴/折叠标题条/用量条目共用）：
    /// 深/浅色外观动态解析——深色 = 白色提亮 8%→5%，浅色 = 黑色压暗 5%→3%。改色只动这四个分支。
    static let hoverGradientBright = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.05)
    }
    static let hoverGradientDark = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.black.withAlphaComponent(0.03)
    }
    /// 渐变端点数组（CAGradientLayer.colors 直接可用）
    static let hoverGradient: [NSColor] = [hoverGradientBright, hoverGradientDark]
    /// Agent/API 平台卡 hover 强背景（用户指定）：深色 = 黑 @50%，浅色 = 白 @80%。
    /// 两端点同色 = 视觉纯色；平台卡 HoverCard 经 hoverGradientOverride 套用，
    /// 余额卡/磁贴/折叠标题条/用量条仍走上面的淡渐变，互不影响。
    static let cardHoverStrongBright = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.black.withAlphaComponent(0.4)
            : NSColor.white.withAlphaComponent(0.8)
    }
    static let cardHoverStrongDark = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.black.withAlphaComponent(0.4)
            : NSColor.white.withAlphaComponent(0.8)
    }
    static let cardHoverStrong: [NSColor] = [cardHoverStrongBright, cardHoverStrongDark]
    /// 平台卡 hover 强背景边缘渐隐宽度（用户指定 5pt）：中心纯色、四边向内渐变到透明。
    /// 位图渲染用，clamp 到 min(W,H)/2 防扁卡越界
    static let cardHoverEdgeFade: CGFloat = 5
    /// 暗色主题下平台卡 hover 渐隐带的外缘 alpha：系统灰 @50%，再向中心
    /// 当前 hover 颜色/alpha 做 premultiplied 线性过渡。
    /// 浅色主题不受影响，边缘仍渐隐到透明。
    static let cardHoverEdgeAlpha: CGFloat = 0.50
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
    /// 容器玻璃遮罩色（近黑半透明，加深毛玻璃底色；深色主题统一增强）
    static let containerTint = NSColor(calibratedWhite: 0.02, alpha: 0.55)
    /// 容器玻璃渐变底色（中灰半透明）：与 containerTint 组成纵向渐变，顶部近黑 → 底部中灰
    static let containerTintBottom = NSColor(calibratedWhite: 0.25, alpha: 0.55)

    /// 浅色主题渐变遮罩两端：顶部亮白 → 底部全透明（统一增强浅色毛玻璃提亮，
    /// 与深色遮罩方向互补——深色是顶部透明 → 底部近黑）
    static let containerTintLightTop = NSColor.white.withAlphaComponent(0.55)
    static let containerTintLightBottom = NSColor.white.withAlphaComponent(0)

    /// 主面板容器背景配色（单一事实源）：applyGradient 与各子弹窗（Token/用量）兜底共用。
    /// 渐变开：深色遮罩（加深黑）= 顶部全透明 → 底部近黑（containerTint 系）；
    /// 浅色遮罩（提亮白）= 顶部亮白 → 底部全透明（containerTintLight 两端）。
    /// lightTint 由调用方按「浅色主题开关开或生效外观为浅色」传入——遮罩明暗跟随系统深浅色。
    /// 关 = 无任何遮罩（top/bottom 均 nil，露出原生 Liquid Glass 毛玻璃）。
    /// top/bottom 分别对应 TintedVisualEffectView 的 tintColor / tintBottomColor
    /// （TintOverlayView 对 nil 不绘制）。
    static func containerColors(lightTint: Bool, gradientOn: Bool) -> (top: NSColor?, bottom: NSColor?) {
        guard gradientOn else { return (nil, nil) }
        return lightTint
            ? (containerTintLightTop, containerTintLightBottom)
            : (containerTint, containerTint.withAlphaComponent(0))
    }
    /// 面板外观统一解析（唯一事实源，所有容器/popover/子面板必须走这里，禁止散落三元式）：
    /// 浅色主题开 = 强制浅色 aqua（即使系统是深色主题）；其余（含渐变开）= nil 跟随系统
    /// 深浅色。渐变只控制遮罩配色，遮罩明暗由 containerColors 按生效外观选择。
    static func panelAppearance(lightTheme: Bool, gradientOn: Bool) -> NSAppearance? {
        _ = gradientOn
        if lightTheme { return NSAppearance(named: .aqua) }
        return nil
    }
    /// 渐变遮罩是否生效：渐变开关开即生效（浅色主题用亮白→透明遮罩，深色用深灰遮罩）
    static func gradientEffective(lightTheme: Bool, gradientOn: Bool) -> Bool {
        gradientOn
    }
    /// 卡片圆角 10pt（对齐 macOS Big Sur+ NSPopover 窗口系统圆角）
    static let cardCornerRadius: CGFloat = 10
    /// 固定 header 的内容色：浅色外观黑色，深色外观沿用辅助灰。
    static let panelHeaderContentColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.systemGray : NSColor.black
    }
    /// header 下缘分割线色（深色白@10% / 浅色黑@8%），由 PanelSeparatorView 自绘使用。
    static let headerSeparatorColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.08)
    }
    /// 卡片边框色/分割线色（暗主题：浅灰半透明，1px 描边，统一白@10%）
    static let cardBorderColor = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    /// hover 边框常态色（深色白@10% / 浅色黑@6%）：卡片预设边框色，非 hover 时使用
    static let hoverBorderNormal = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.06)
    }
    /// hover 边框提亮色（深色白@18% / 浅色黑@40%）：hover 时边框色随宽度一起动画到此色
    static let hoverBorderBright = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.40)
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

    // ── 图表与提示元素（用量趋势子面板 / Token 统计子面板 / 滚动渐隐提示共用）──

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
    /// Token 热力图无用量底点（深 中性灰 #262626（去饱和定稿，亮度取自 #1E262E 中值）/ 浅 sRGB 210,210,210 中性浅灰）。
    /// 浅色值必须用 sRGB 定义：calibratedWhite 是 gamma1.8 校准空间，合成到 sRGB 屏幕时
    /// 做 gamma 补偿会把 215 渲染成 223（取色实测），sRGB 定义则所见即所得。
    static let heatDotEmpty = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0x26/255.0, green: 0x26/255.0, blue: 0x26/255.0, alpha: 1)
            : NSColor(srgbRed: 210/255.0, green: 210/255.0, blue: 210/255.0, alpha: 1)
    }
    /// Token 热力图 hover 高亮环（深 白@90% / 浅 黑@70%）
    static let heatDotRing = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.7)
    }
    /// Token 热力图有量级配色（按生效外观选择，集中管理勿散落）：
    /// 深色主题 = GitHub 暗色绿阶 4 级离散色（用户定稿 2026-08-29）：
    /// #063A16 / #196C2E / #2EA043 / #56D364（level 1→4），见 heatLevelsDark；
    /// 浅色主题沿用两端点线性插值 #b9eac5 → #2cc859（浅底由浅到深，4 级对比）。
    static let heatLevelsLight: (from: (r: Int, g: Int, b: Int), to: (r: Int, g: Int, b: Int)) =
        ((185, 234, 197), (44, 200, 89))
    /// 深色主题热力图 4 级离散色（level 1→4），levelColor 直取不做插值
    static let heatLevelsDark: [(r: Int, g: Int, b: Int)] = [
        (6, 58, 22), (25, 108, 46), (46, 160, 67), (86, 211, 100)
    ]
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
    /// 滚动渐隐提示底色（深 近黑@22% / 浅 亮白@55%——浅色主题提示为亮色渐变）：
    /// 经 tintMask 渐变蒙版呈现「贴靠边最浓 → 对侧透明」的渐变；须比容器底更透，避免发重
    static let scrollHintTint = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 0.02, alpha: 0.22)
            : NSColor.white.withAlphaComponent(0.55)
    }
    /// 点阵进度未点亮方块（深 系统灰压暗 25% / 浅 系统灰；均为系统色，较原定稿更深）
    static let dotsDim = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.systemGray.withAlphaComponent(0.75)
            : NSColor.systemGray
    }
    /// 卡片边框宽度 1pt
    static let cardBorderWidth: CGFloat = 1
    /// 卡片主标题（平台名）/ 数值字号：13pt。气泡 ID 行与之同号（2026-08-31 用户要求）
    static let cardTitleFontSize: CGFloat = 13
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

/// 面板内容控制器：把 BalancePanelView 挂进 popover，宽度 260（主面板宽度增加 20pt），高度受屏幕可用空间限制；
/// 内容超高时通过纵向滚动查看底部设置、操作和更新时间。
final class BalancePanelViewController: NSViewController {
    /// 面板宽度唯一值（用户口中的「面板宽度」即此值）：popover 总宽，含容器左右缩进。
    /// document 宽 = panelWidth − 容器缩进×2，内容按约束压缩/截断自适应承接，
    /// 不再由内容固有宽（fittingSize）反推宽度。用户改宽度只动这一个数。
    /// ⚠️ 硬下限 270：操作磁贴行固定宽 4×56+3×2=230，要求 document ≥ 244
    /// （230 + root 缩进 14），低于此值磁贴行被压、Auto Layout 破坏约束。
    static let panelWidth: CGFloat = 276
    /// 满尺寸内容（hasFullSizeContent）下容器铺满整个 popover 窗口，系统原有的
    /// 左右边距带不再存在：由容器层（scrollView 左右约束）统一补回的缩进。
    /// root/footer 自身保留原 7pt 正文缩进，9+7=16pt（2026-09-03 四次调整：
    /// 16 → 8 → 13 → 9）；header 按钮对齐、面板宽度下限、
    /// document 宽解算均引用此值。
    static let contentHorizontalInset: CGFloat = 9
    private let panel: BalancePanelView
    private let scrollView = NSScrollView()
    /// 底部「下方还有内容」提示层（磨砂 + 渐变 + 箭头），盖在 scrollView 之上
    private let fadeHint = ScrollFadeHint(edge: .bottom)
    /// 顶部「上方还有内容」提示层，与底缘对称
    private let topHint = ScrollFadeHint(edge: .top)
    /// 提示层参数（AppDelegate 启动时从 config 写入）
    var fadeHintParams = FadeHintParams()
    /// 提示层高度约束（bandHeight 参数实时调整用）
    private var fadeHintHeightConstraint: NSLayoutConstraint?
    private var topHintHeightConstraint: NSLayoutConstraint?
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
        container.appearance = Palette.panelAppearance(lightTheme: panel.lightThemeEnabled,
                                                       gradientOn: panel.panelGradientEnabled)
        // 叠加半透明遮罩：生效外观深色=顶部透明→底部深灰；浅色=顶部亮白→底部透明；
        // 关闭时无遮罩（原生玻璃）
        let initialColors = Palette.containerColors(
            lightTint: panel.lightThemeEnabled || !NSApp.effectiveAppearance.isDark,
            gradientOn: panel.panelGradientEnabled)
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
        // 底部「下方还有内容」提示层：底色渐变遮罩 + 高光渐变 + 下箭头，内容超高且未滚到底时显示
        fadeHint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fadeHint)
        fadeHintHeightConstraint = fadeHint.heightAnchor.constraint(equalToConstant: fadeHintParams.bandHeight)
        NSLayoutConstraint.activate([
            fadeHint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fadeHint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fadeHint.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fadeHintHeightConstraint!,
        ])
        // 顶部「上方还有内容」提示层：与底缘对称，未滚到顶时显示
        topHint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topHint)
        topHintHeightConstraint = topHint.heightAnchor.constraint(equalToConstant: fadeHintParams.bandHeight)
        NSLayoutConstraint.activate([
            topHint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topHint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // header 固定在正文最顶部，顶部滚动提示从 header 下方开始，避免遮挡更新时间和操作按钮。
            topHint.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor,
                                         constant: BalancePanelView.headerHeight),
            topHintHeightConstraint!,
        ])
        // 初始参数（可能由 AppDelegate 在 view 加载前写入）：应用到两个提示层
        fadeHint.params = fadeHintParams
        topHint.params = fadeHintParams
        // header 不再属于 document view，避免随内容滚动；它仍复用 BalancePanelView
        // 中已有的更新时间、刷新状态动效和快速编译按钮。
        if let backdrop = panel.headerBackdropView {
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            // 与容器同款毛玻璃：header 没有自己的色块，看起来就是面板背景本身；
            // 遮罩取顶部色（header 位于渐变最顶端），滚动时内容仍被完整遮住。
            backdrop.material = .menu
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.isEmphasized = false
            backdrop.appearance = container.appearance
            backdrop.tintColor = initialColors.top
            backdrop.tintBottomColor = initialColors.top
            container.addSubview(backdrop)
            // 顶边贴窗口绝对顶部（= 伸进三角箭头区），header 的毛玻璃由此一直铺到
            // 三角里，箭头与 header 同色；底边落在 header 下缘（安全区顶 + header 高）。
            // 窗口整体仍由系统按 popover 轮廓（圆角矩形 + 三角）裁切。
            NSLayoutConstraint.activate([
                backdrop.topAnchor.constraint(equalTo: container.topAnchor),
                backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                backdrop.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor,
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
            self?.updateFadeHint()
            // 滚动后修正各卡片/按钮的 hover 状态（AppKit 不补发 enter/exit 事件）
            self?.syncHoverAfterScroll()
            // 几何稳定后再校准一次：popover 高度变化分两步落地，窗口落地后
            // 的补发事件可能落在上面即时同步之后
            self?.scheduleHoverSync()
        })
        fadeObservers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.updateFadeHint() })
        // 浮窗 resize：视口宽高变化同步 document view（宽度自适应 + 高度拉伸防沉底）
        scrollView.contentView.postsFrameChangedNotifications = true
        fadeObservers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            guard let self, self.isFloatingWindow else { return }
            self.syncDocumentSizeToViewport()
        })
        // resize 把手盖在提示层之上，贴容器右下角；22×22 命中区域（视觉斜线仍贴角落，
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
        updateFadeHint()
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
                  clip.bounds.height >= 10 + rootH + 41 {
            // 拖矮方向：视口仍装得下自然内容（root 自然高 + 顶距 14 + footer
            // 预留 41，与 build() 的 rootTop/底部 cap 常量同源；root 未被拉伸、
            // frame 高即自然高）时，document 跟随视口缩矮——优先收缩 root 与
            // footer 之间的弹性空白、全程保持全显；空白耗尽才走上方校正的
            // 顶部锚定滚动裁切
            f.size.height = clip.bounds.height
        }
        guard panel.frame != f else { return }
        panel.frame = f
        updateFadeHint()
    }

    /// 提示层参数实时生效（调参弹窗滑杆拖动时由 AppDelegate 调用）：
    /// 参数下发到两个提示层 + 高度约束同步
    func applyFadeHintParams(_ p: FadeHintParams) {
        fadeHintParams = p
        guard isViewLoaded else { return }
        fadeHint.params = p
        topHint.params = p
        fadeHintHeightConstraint?.constant = p.bandHeight
        topHintHeightConstraint?.constant = p.bandHeight
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        updateFadeHint()
    }

    /// 顶/底提示可见性：仅当内容超出视口（可滚动）且未滚到对应边缘时显示
    private func updateFadeHint() {
        guard isViewLoaded else { return }
        let clip = scrollView.contentView
        let viewportHeight = clip.bounds.height
        let contentHeight = panel.bounds.height
        guard contentHeight > viewportHeight + 0.5 else {
            fadeHint.setShown(false)
            topHint.setShown(false)
            return
        }
        let visible = clip.documentVisibleRect
        // 文档视图非翻转（原点在左下）：滚到底部时可见区域 minY ≈ 0，
        // 滚到顶部时可见区域 maxY ≈ 内容高度
        let atBottom = panel.isFlipped
            ? visible.maxY >= contentHeight - 0.5
            : visible.minY <= 0.5
        let atTop = panel.isFlipped
            ? visible.minY <= 0.5
            : visible.maxY >= contentHeight - 0.5
        fadeHint.setShown(!atBottom)
        topHint.setShown(!atTop)
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
        updateFadeHint()
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

    /// 按当前开关与生效外观刷新背景遮罩：浅色主题强制浅色；渐变生效时按生效外观
    /// 取深灰（深）或亮白（浅）的纵向渐变遮罩；否则无遮罩（原生玻璃）
    private func applyGradient() {
        guard let container = view as? TintedVisualEffectView else { return }
        // 外观随开关即时切换：统一走 Palette.panelAppearance（浅色强制浅色，其余跟随系统）
        container.appearance = Palette.panelAppearance(lightTheme: panel.lightThemeEnabled,
                                                       gradientOn: panel.panelGradientEnabled)
        let colors = Palette.containerColors(
            lightTint: !container.effectiveAppearance.isDark,
            gradientOn: panel.panelGradientEnabled)
        container.tintColor = colors.top
        container.tintBottomColor = colors.bottom
        container.tintGradientStartY = 0
        // header 背景层同步同一套外观与遮罩（渐变开关/浅色主题切换即时生效）
        if let backdrop = panel.headerBackdropView {
            backdrop.appearance = Palette.panelAppearance(lightTheme: panel.lightThemeEnabled,
                                                          gradientOn: panel.panelGradientEnabled)
            backdrop.tintColor = colors.top
            backdrop.tintBottomColor = colors.top
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // 让 popover 按内容实际高度撑开；超过屏幕的部分由 scrollView 承载。
        updateContentSize()
        // App 启动后首次弹出：内容归位到最上方（默认会显示底部）
        scrollToTopIfNeeded()
        // 首次展示前预置阶梯入场（必须在可见前执行，避免先整屏闪现再重置）
        panel.staggerRevealBalanceGroupsIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 弹出动画可能调整视口尺寸，展示完成后按最终布局刷新一次提示状态
        updateFadeHint()
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
        // 面板关闭后停止箭头浮动动画，避免不可见时持续渲染
        fadeHint.setShown(false)
        topHint.setShown(false)
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
        updateFadeHint()
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
    static let headerHeight: CGFloat = 30
    /// 由布局构建，随后由 BalancePanelViewController 提升到滚动容器上层固定显示。
    var headerView: NSView?
    /// header 独立背景层：固定在滚动内容上方，不承载文字/按钮，只负责
    /// 复刻面板容器的毛玻璃（遮住滚到 header 下方的内容）+ 承载下缘分割线。
    var headerBackdropView: TintedVisualEffectView?

    // MARK: - 对外回调（由 AppDelegate 接线到现有处理逻辑）

    var onOpenCockpit: (() -> Void)?
    var onToggleAutoCheckin: (() -> Void)?
    var onAddWbAccount: (() -> Void)?
    var onSetInterval: ((Int) -> Void)?          // 秒数：60 / 180 / 300
    /// 手动刷新（刷新时间行内的刷新按钮触发）
    var onManualRefresh: (() -> Void)?
    /// 快速编译（header 右侧按钮触发，后台静默执行 swift/build.sh）
    var onQuickBuild: (() -> Void)?
    var onSetApiKey: (() -> Void)?
    /// 面板渐变背景开关（设置卡片开关触发）
    var onTogglePanelGradient: (() -> Void)?
    /// 浅色主题开关（设置卡片开关触发：强制浅色外观，即使系统是深色主题）
    var onToggleLightTheme: (() -> Void)?
    /// Mono 字体开关（设置卡片开关触发：余额卡片与用量列表切换 JetBrainsMono）
    var onToggleMonoFont: (() -> Void)?
    /// 数值滚动预览开关（设置卡片开关触发：余额数值周期随机变化演示滚动）
    var onToggleValueScrollPreview: (() -> Void)?
    /// 状态调试预览开关（设置卡片开关触发：三态光环轮派前三张 Agent 卡演示动画）
    var onToggleStatusDebugPreview: (() -> Void)?
    /// 渐变开关状态变化通知（update 同步时触发，VC 据此刷新遮罩绘制）
    var onPanelGradientChanged: (() -> Void)?
    var onAbout: (() -> Void)?
    /// 手动检查更新（操作磁贴触发：GitHub Releases 检查 + 可选下载替换）
    var onCheckForUpdate: (() -> Void)?
    /// 自动检查更新开关（设置卡片开关触发）
    var onToggleUpdateAutoCheck: (() -> Void)?
    /// 管理各平台刷新、自动签到、卡片与用量显示开关
    var onManagePlatformToggles: (() -> Void)?
    var onManualCheckin: (() -> Void)?
    /// 查看签到历史（各账号签到记录列表）
    var onShowCheckinHistory: (() -> Void)?
    /// 同步共享（WorkBuddy 多账号对话/记忆同步到当前登录账号）
    var onShareWbHistory: (() -> Void)?
    var onQuit: (() -> Void)?
    /// 打开项目 GitHub 页面（footer 右侧按钮触发）
    var onOpenGitHub: (() -> Void)?
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
    /// TRAE 账号采集（菜单按钮触发）
    var onCollectTraeAccount: (() -> Void)?
    /// TRAE 非当前账号卡片点击：传入 uid，触发切号重启
    var onSwitchTraeAccount: ((String) -> Void)?
    /// ZCode 添加账号（JSON 导入 ~/.zcode/v2/config.json）
    var onAddZcodeAccount: (() -> Void)?
    /// Codex 添加账号（JSON 导入 ~/.codex/auth.json）
    var onAddCodexAccount: (() -> Void)?
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
    private struct CardEntry {
        let uid: String
        let valueView: RollingNumberView   // 余额数值（逐位垂直滚动）
        let titleLabel: FadeableTextField  // 平台名主标题（hover 字重动画载体）
        let dots: UsageDots
        let nickLabel: NSTextField
        let segmentLabels: [NSTextField] // 到期副标题分段 labels（icon + 段落，段间 3pt stack 布局；空数组 = 无第二行）
        let expireIcon: NSImageView?   // 到期行倒计时图标 time（随 expired 状态变色，2026-08-27 起统一 systemGray）
        let badgeView: NSView          // 签到失败角标（icon 右上角，无签到平台恒隐藏）
        let iconView: NSImageView      // 平台 icon
        let statusRing: CardTaskStatusRingView?  // 任务状态光环（Agent 卡挂任务态 / API 卡挂脉冲进行中态，其余 nil）
        let menuBarDot: NSView         // 菜单栏显隐小白点（icon 下方 4pt，inMenuBar 时点亮）
        var lastValue: String = ""     // 上次应用的余额文本（数字滚动判据；空 = 首次赋值直接显示）
        var subAccountsStrip: NSStackView? = nil // Agent 卡 hover 时替换点阵的其余账号条（icon+积分）
        var subValueLabels: [NSTextField] = []   // 其余账号条内积分数值 label（apply 随刷新更新文本）
        var subItems: [SubAccountItemView] = []  // 其余账号条本体（apply 同步 tokenInvalid 等悬浮气泡数据）
        var chipTipBox: ChipTipBox? = nil        // 当前账号积分 chip 气泡数据盒（apply 随刷新更新昵称/签到徽章）
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
        // （2026-09-02 用户要求 +1pt → 25pt，与图标列宽同宽）。
        // 非 Agent 平台（DS/ZhiPu/Qwen）恒单账号、Agent 平台非当前账号走 hover 账号条，
        // 不再存在「非当前账号小卡」，secondary 尺寸字段已随死代码清理移除
        static let wb    = CardStyle(icon: "workbuddy", name: "WorkBuddy", platformID: "wb", iconSize: 25, checkin: true, showsExpire: true, expireIconSymbol: "clock-stop-m", menuBarIdPrefix: "wb:")
        static let trae  = CardStyle(icon: "trae-color", name: "Trae", platformID: "trae", iconSize: 25, checkin: true, showsExpire: true, expireIconSymbol: "xmark", menuBarIdPrefix: "trae:")
        static let zcode = CardStyle(icon: "zhipu", name: "ZCode", platformID: "zcode", iconSize: 25, checkin: false, showsExpire: true, expireIconSymbol: "clock-stop", menuBarIdPrefix: "zcode:")
        static let codex = CardStyle(icon: "codex", name: "Codex", platformID: "codex", iconSize: 25, checkin: false, showsExpire: true, expireIconSymbol: "clock-stop-m", menuBarIdPrefix: "codex:")
        static let ds    = CardStyle(icon: "deepseek", name: "DeepSeek", platformID: "ds", iconSize: 25, checkin: false, showsExpire: true, expireIconSymbol: "external-link", menuBarIdPrefix: "")
        // ZhiPu：与 ds 同构的单账号卡（uid 恒 "zhipu" 无前缀，右键菜单 id 恰为 MenuBarPrefix.zhipu）；副标题带 external-link 图标
        static let zhipu = CardStyle(icon: "zhipu", name: "ZhiPu", platformID: "zhipu", iconSize: 25, checkin: false, showsExpire: true, expireIconSymbol: "external-link", menuBarIdPrefix: "")
        // Qwen（千问 Token Plan）：单账号卡，值为周剩余百分比；副标题为 7 天限额重置倒计时（clock-stop-w 图标）
        static let qwen = CardStyle(icon: "qwen", name: "Qwen", platformID: "qwen", iconSize: 25, checkin: false, showsExpire: true, expireIconSymbol: "clock-stop-w", menuBarIdPrefix: "")
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
        let c = container.widthAnchor.constraint(equalTo: (group ?? balanceGroupContainer).widthAnchor)
        c.isActive = true
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
    weak var draggingGhostView: NSImageView?
    var draggingGhostOffset = NSPoint.zero
    /// 当前拖动平台内的其他账号小卡片及其原始内容透明度。
    var draggingSiblingCardOpacities: [(card: HoverCard, opacity: Float)] = []
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
        // 预设边框色/hover 渐变经 .cgColor 落盘会定格当时外观：外观变化时重解算。
        // hover 中（borderWidth > 0）的层跳过——其动画路径每次都取当前解算值。
        let appearance = effectiveAppearance
        var stack = subviews
        while let v = stack.popLast() {
            if let layer = v.layer, layer.borderWidth == 0 {
                appearance.performAsCurrentDrawingAppearance {
                    layer.borderColor = Palette.hoverBorderNormal.cgColor
                }
            }
            stack.append(contentsOf: v.subviews)
        }        // 渐变开时遮罩明暗随生效外观：系统深浅切换重刷遮罩，并同步用量趋势子面板配色
        onPanelGradientChanged?()
        syncUsageHistoryPanelBackground()

    }
    /// 用量行实际宽度（列宽自动分配的预算基准）：用量卡片 horizontalPadding 0、行撑满
    /// 卡片，卡片又撑满 root，故 = document 宽 − root 左右正文缩进 7×2。
    /// 2026-09-03 根治压缩：旧固定 260 预算在窄面板（document < 内容自然宽）下让列宽
    /// 总和超出实际行宽，Auto Layout 被迫破坏约束（卡片宽随数据漂移），hover 渐变层
    /// （frame 首次 hover 定格）随之与卡片错位——预算改按实际宽度现算后自然宽 ≤ document。
    private var usageRowWidth: CGFloat { bounds.width - 14 }
    /// 当前自动分配的三列宽（每次行重建前按内容重算；此为初值兜底）
    var usageColWidths = (week: CGFloat(50), today: CGFloat(44), hour: CGFloat(40))

    /// 按实际内容自动分配三列宽度：每列 = max(表头, 全部行文本) 宽 + 6pt 呼吸；
    /// 名称列与固定开销先扣，剩余预算不够时按比例收窄（列宽下限保 5 字符值，
    /// 名称列再不够由自身截断兜底）。字体度量取当前 uiFont——字体开关切换后
    /// applyFontPolicy 强制清空 renderedUsageRows 触发重建重算。
    private func computeUsageColumnLayout(_ rows: [UsageRowSnapshot]) {
        // 度量字体与行渲染同源（小表格口径），避免测量/渲染字重不一致
        let valueFont = SmallTable.rowFont(mono: monoFontEnabled, monoDigits: true)
        let headerFont = SmallTable.titleFont(mono: monoFontEnabled)
        func w(_ s: String, _ f: NSFont) -> CGFloat {
            s.size(withAttributes: [.font: f]).width
        }
        var hour = w("1H", headerFont)
        var today = w("1D", headerFont)
        var week = w("1W", headerFont)
        for r in rows {
            hour = max(hour, w(r.hourText, valueFont))
            today = max(today, w(r.todayText, valueFont))
            week = max(week, w(r.weekText, valueFont))
        }
        hour += 6; today += 6; week += 6
        let nameFont = SmallTable.rowFont(mono: monoFontEnabled)
        let nameW = rows.map { w($0.name, nameFont) }.max() ?? 40
        // 固定开销：左右 inset 16 + icon 14 + icon↔名 4 + 名↔数值区 6 + 三个列间隙 24
        let budget = usageRowWidth - SmallTable.horizontalInset * 2 - 14 - 4 - 6
            - 3 * SmallTable.columnSpacing - nameW
        let total = hour + today + week
        if total > budget, total > 0 {
            let scale = budget / total
            // 列宽下限 34/38/40：按实际行宽保住 5 字符值不截断
            hour = max(34, hour * scale)
            today = max(38, today * scale)
            week = max(40, week * scale)
        }
        usageColWidths = (week: week, today: today, hour: hour)
    }

    // 用量表样式口径统一走 SmallTable（小表格，与 Token 面板共用）
    var usageColumnSpacing: CGFloat { SmallTable.columnSpacing }
    var usageHorizontalInset: CGFloat { SmallTable.horizontalInset }
    /// 用量行行内垂直缩进（行间距 0，每行上下统一缩进 3pt）
    var usageRowTopInset: CGFloat { SmallTable.rowInset }
    var usageRowBottomInset: CGFloat { SmallTable.rowInset }

    let autoCheckinSwitch = MiniSwitch()
    let autoCheckinSub = NSTextField(labelWithString: "")
    let wbAddBtn = ActionTileButton(bundleIcon: "workbuddy",
                                           title: "添加账号", target: nil, action: nil)
    /// 同步共享磁贴：WorkBuddy 多账号对话/记忆同步到当前登录账号（见 WbShare.swift）
    let wbShareBtn = ActionTileButton(bundleIcon: "workbuddy",
                                           title: "同步共享", target: nil, action: nil)
    let traeAddBtn = ActionTileButton(bundleIcon: "trae-color",
                                             title: "添加账号", target: nil, action: nil)
    /// 手动签到磁贴：进行中由 update() 驱动脉冲 + 禁点
    let checkinBtn = ActionTileButton(symbol: "checkmark.seal",
                                              title: "手动签到", target: nil, action: nil)
    let zcodeAddBtn = ActionTileButton(bundleIcon: "zhipu",
                                               title: "添加账号", target: nil, action: nil,
                                               svgIconSize: 14.45)  // SVG 微调 ≈0.9×基准（16）；Mono 用标称 16
    // 刷新间隔：原生 NSPopUpButton 下拉菜单（视觉整体缩至 0.8，见 CompactPopUpButton；
    // 选项 tag 直接携带秒数）
    let intervalPopup: CompactPopUpButton = {
        let popup = CompactPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.appearance = NSAppearance(named: .darkAqua)
        for (title, seconds) in [("1分钟", 60), ("3分钟", 180), ("5分钟", 300)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = seconds
            popup.menu?.addItem(item)
        }
        // 弹出菜单内容与按钮同步缩小：.small 按钮 11pt × 0.8 ≈ 9pt（原分段控件字号），
        // NSMenu.font 驱动行高与宽度整体收窄，无法对菜单窗口做 transform
        popup.menu?.font = NSFont.systemFont(ofSize: 9)
        return popup
    }()
    /// 面板渐变背景开关（update 时随快照同步状态）
    let gradientSwitch = MiniSwitch()
    /// 浅色主题开关（update 时随快照同步状态）
    let lightThemeSwitch = MiniSwitch()
    /// 自动检查更新开关（update 时随快照同步状态）
    let updateAutoSwitch = MiniSwitch()
    /// 渐变开关状态（update 同步；VC 读取决定遮罩渐变/单色）
    private(set) var panelGradientEnabled = true
    /// 浅色主题开关状态（update 同步；优先级高于渐变——开启即强制浅色外观）
    private(set) var lightThemeEnabled = false
    /// Mono 字体开关（update 时随快照同步状态）
    let monoSwitch = MiniSwitch()
    /// Mono 字体开关状态（update 同步；变化时对已注册 label 就地切换字体，不重建卡片）
    private(set) var monoFontEnabled = false
    /// 数值滚动预览开关状态（update 同步；开启后周期随机变动余额演示滚动）
    let valuePreviewSwitch = MiniSwitch()
    /// 「滚动预览」行副标题（静态文案；switchRow 默认隐藏，build 中统一显示）
    let valuePreviewSub = NSTextField(labelWithString: "余额数值周期随机变化")
    private(set) var valueScrollPreviewEnabled = false
    /// 状态调试预览开关（设置卡片开关：三态光环轮派前三张 Agent 卡，演示进行中/完成/中断动画）
    let statusDebugSwitch = MiniSwitch()
    /// 状态调试副标题（开发调试行）：2026-09-01 加 90pt 宽度上限——原文案 ≈138pt 把
    /// 设置卡 fittingSize 撑到 256（popover 撑宽元凶之一）；上限约束参与 fittingSize，
    /// 防止开发调试行影响面板宽度
    let statusDebugSub: NSTextField = {
        let l = NSTextField(labelWithString: "三态光环轮派前三张 Agent 卡")
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 90).isActive = true
        return l
    }()
    private(set) var statusDebugPreviewEnabled = false
    /// 设置卡片各开关行注册表（Mono 模式切换时统一显隐原生/字符开关）。
    /// handler 必须一并强持有：NSClickGestureRecognizer 的 target 是弱引用，
    /// 不持有则手势触发时 target 已释放，整行点击失效。
    var switchRows: [(row: NSView, sw: MiniSwitch, char: MonoCharSwitch, handler: SwitchRowTapHandler)] = []

    // MARK: - 字体策略（Mono 开关：余额卡片 + 用量列表）

    /// 需跟随 Mono 开关切换字体的 label 注册项（weak：卡片重建后旧 label 释放自动失效）
    private struct FontTarget {
        weak var label: NSTextField?
        let size: CGFloat
        let weight: NSFont.Weight
        /// 关闭 Mono 时是否用等宽数字系统字体（余额数值等右对齐数字列）
        let monoDigits: Bool
    }
    private var fontTargets: [FontTarget] = []

    /// 按当前字体开关状态取字体（优先级：Mono 风格 > 系统字体）。
    /// Mono = JetBrainsMono（中文级联回退系统字体），
    /// 关 = 系统字体（等宽数字列可选，余额数值右对齐用）。
    private func uiFont(size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) -> NSFont {
        if monoFontEnabled { return MonoFontProvider.font(size: size, weight: weight) }
        return monoDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
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

    /// 注册 label 并立即应用当前字体策略（开关切换时 applyFontPolicy() 就地更新，不重建视图）
    func registerFont(_ label: NSTextField, size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) {
        label.font = uiFont(size: size, weight: weight, monoDigits: monoDigits)
        fontTargets.append(FontTarget(label: label, size: size, weight: weight, monoDigits: monoDigits))
        if fontTargets.count % 32 == 0 { fontTargets.removeAll { $0.label == nil } }
    }

    /// 余额滚动数值视图注册表（weak：卡片重建后自动失效）。
    /// RollingNumberView 非 NSTextField、不进 fontTargets，Mono 开关切换时单独就地刷字体
    private let rollingTargets = NSHashTable<RollingNumberView>()
    /// 子账号 chip 注册表（weak：卡片重建后自动失效）——字体策略切换时按新字体重算右内缩进
    private let chipItems = NSHashTable<SubAccountItemView>.weakObjects()

    /// 注册余额滚动数值视图并注入字体策略（uiFont：Mono/系统 + 等宽数字）
    func registerRollingNumber(_ v: RollingNumberView, size: CGFloat, weight: NSFont.Weight) {
        v.configure(size: size, weight: weight, fontProvider: { [weak self] s, w, mono in
            guard let self else { return .monospacedDigitSystemFont(ofSize: s, weight: w) }
            return self.uiFont(size: s, weight: w, monoDigits: mono)
        })
        rollingTargets.add(v)
    }

    /// Mono 开关变化：对所有存活 label 就地切换字体（保留点阵脉冲等动画状态）
    private func applyFontPolicy() {
        for t in fontTargets {
            guard let label = t.label else { continue }
            label.font = uiFont(size: t.size, weight: t.weight, monoDigits: t.monoDigits)
        }
        fontTargets.removeAll { $0.label == nil }
        // 余额滚动数值（非 NSTextField）：单独就地刷新字体，滚动状态保留
        for v in rollingTargets.allObjects {
            v.refreshFont()
        }
        // chip 右内缩进按末字符墨迹回补：字体换了 rsb 也变，按新字体重算
        for item in chipItems.allObjects { item.refreshOpticalPadding() }
        // 用量列宽按字体度量自动分配：清空行缓存，本次 update 随即按新字体重建重算
        renderedUsageRows = []
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

        // 渐变/浅色主题开关状态同步（VC 通过 onPanelGradientChanged 即时刷新遮罩与外观绘制）
        let gradientChanged = s.panelGradientEnabled != panelGradientEnabled
        panelGradientEnabled = s.panelGradientEnabled
        gradientSwitch.state = s.panelGradientEnabled ? .on : .off
        let lightChanged = s.lightThemeEnabled != lightThemeEnabled
        lightThemeEnabled = s.lightThemeEnabled
        lightThemeSwitch.state = s.lightThemeEnabled ? .on : .off
        if gradientChanged || lightChanged {
            usageHistoryController?.panelGradientEnabled = panelGradientEnabled
            usageHistoryController?.lightThemeEnabled = lightThemeEnabled
            onPanelGradientChanged?()
            // 自带深色外观的自绘控件（MiniSwitch/MiniSegmented）需显式换肤（不继承容器外观）
            if lightChanged { applyControlsTheme() }
        }
        // Mono 字体开关状态同步：变化时对已注册 label 就地切换字体（不重建卡片）
        let monoChanged = s.monoFontEnabled != monoFontEnabled
        monoFontEnabled = s.monoFontEnabled
        monoSwitch.state = s.monoFontEnabled ? .on : .off
        if monoChanged {
            applyFontPolicy()
            // 用量子弹窗（图表）跟随同一开关：文本和数值切换 Mono 风格
            usageHistoryController?.monoFontEnabled = monoFontEnabled
            // 主面板内嵌 Token 板块跟随同一开关（就地刷字体）
            inlineTokenView?.monoFontEnabled = monoFontEnabled
        }
        valueScrollPreviewEnabled = s.valueScrollPreviewEnabled
        valuePreviewSwitch.state = s.valueScrollPreviewEnabled ? .on : .off
        // 预览定时器状态与配置保持一致（幂等：无变化不动）
        setValueScrollPreview(s.valueScrollPreviewEnabled)
        // 状态调试预览开关同步；变化时清空 Agent 各平台 uid 缓存 → 强制重建卡片
        //（状态光环现在全平台挂载；清缓存保留用于让调试预览切换时重置动画实例）
        let statusDebugChanged = s.statusDebugPreview != statusDebugPreviewEnabled
        statusDebugPreviewEnabled = s.statusDebugPreview
        statusDebugSwitch.state = s.statusDebugPreview ? .on : .off
        if statusDebugChanged {
            wbCardUids = []
            zcodeCardUids = []
            traeCardUids = []
            codexCardUids = []
            contentSizeChanged = true
        }
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

        // ── 设置/操作状态（代码设置 state 不会触发 action，安全）──
        let autoOn = s.traeAutoCheckin || s.wbAutoCheckin
        autoCheckinSwitch.state = autoOn ? .on : .off
        updateAutoSwitch.state = s.updateAutoCheckEnabled ? .on : .off
        // sub 显示统一签到时间（取 TRAE / WB 最近一次签到的最晚时间，格式 M-d HH:mm）
        autoCheckinSub.stringValue = s.lastCheckinTime ?? ""
        autoCheckinSub.isHidden = autoCheckinSub.stringValue.isEmpty

        wbAddBtn.setTitle(s.wbOauthInProgress ? "取消添加" : "添加账号")
        // 进行中反馈：签到磁贴背景脉冲 + 禁点；TRAE 采集对齐 WB 的文案切换 + 同款脉冲
        checkinBtn.setInProgress(s.checkinInProgress)
        traeAddBtn.setTitle(s.traeCollectInProgress ? "采集中…" : "添加账号")
        traeAddBtn.setInProgress(s.traeCollectInProgress)

        // 非 60/180 的存量配置统一回退 5 分钟（与原分段默认段一致）
        intervalPopup.selectItem(withTag: s.refreshIntervalSeconds)
        if intervalPopup.selectedItem == nil {
            intervalPopup.selectItem(withTag: 300)
        }

        // Mono 模式切换设置开关外观（字符开关 [×]/[▪] ↔ 原生 NSSwitch）
        applySwitchVisuals(animated: monoChanged)
        // Token 板块跟随快照落定后刷新：账号增删/容器显隐变化会改变「Agent 顶部平台」
        // 的解析结果（fetch 缓存命中同步、零读取，幂等）
        refreshInlineTokens()
        if contentSizeChanged { onContentChanged?() }
    }

    // MARK: - 首开阶梯入场（UIUX-OPTIMIZATION.md §5）

    /// 进程级一次性：只有本进程第一次面板展示编排入场，之后所有开面板零动画
    ///（菜单栏面板是高频动作，首帧低频时刻才值得编排）
    private static var didStaggerReveal = false

    func staggerRevealBalanceGroupsIfNeeded() {
        guard !Self.didStaggerReveal else { return }
        Self.didStaggerReveal = true
        let groups = (apiGroupContainer.arrangedSubviews + balanceGroupContainer.arrangedSubviews)
            .filter { !$0.isHidden }
        guard groups.count > 1 else { return }
        // 平台组自上而下 40ms 阶梯（30–80ms 区间），每组 240ms「上浮 6pt + 淡入」。
        // 编排总时长 ≤ 240 + 40×组数；纯视觉层动画，不阻塞任何交互。
        // reduced-motion：去位移只留淡入。NSStackView 非 flipped（y 向上），
        // 终位上方 dy = +y 平移。
        let dy: CGFloat = shouldReduceMotion ? 0 : 6
        for (i, g) in groups.enumerated() {
            g.wantsLayer = true
            g.alphaValue = 0
            if dy > 0, let layer = g.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DMakeTranslation(0, dy, 0)
                CATransaction.commit()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.04) { [weak g] in
                guard let g else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.reveal
                    ctx.timingFunction = Motion.easeOutStrong
                    g.animator().alphaValue = 1
                }
                guard dy > 0, let layer = g.layer else { return }
                let anim = CABasicAnimation(keyPath: "transform.translation.y")
                anim.fromValue = dy
                anim.toValue = 0
                anim.duration = Motion.reveal
                anim.timingFunction = Motion.easeOutStrong
                layer.add(anim, forKey: "staggerReveal")
                // model 立即归位（播放期间 presentation 覆盖 model，结束即无缝停在终位）
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
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
                                         nickLabel: NSTextField(labelWithString: ""),
                                         segmentLabels: [], expireIcon: nil,
                                         badgeView: makeFailureBadge(),
                                         iconView: NSImageView(),
                                         statusRing: nil,
                                         menuBarDot: NSView()))
                continue
            }
            let valueView = RollingNumberView()   // 初始 "—" 占位（init 内置）
            let dots: UsageDots? = UsageDots()
            let uid = ac.uid
            weak var cardRef: NSView?
            // Agent 卡其余账号条：hover 时替换点阵，icon+积分（字号/颜色与副标题统一：9pt systemGray）
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
            if isAgentCard, accounts.contains(where: { !$0.isCurrent }) {
                let strip = NSStackView()
                strip.orientation = .horizontal
                strip.alignment = .centerY
                strip.spacing = 2.5
                strip.heightAnchor.constraint(equalToConstant: 12).isActive = true
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
                    lbl.textColor = .systemGray
                    // 右内缩进按末字符墨迹回补（背景贴 ink 而非 advance，左右视觉等距）
                    item.valueLabel = lbl
                    item.refreshOpticalPadding()
                    chipItems.add(item)
                    item.addArrangedSubview(iv)
                    item.addArrangedSubview(lbl)
                    strip.addArrangedSubview(item)
                    subValueLabels.append(lbl)
                    subItems.append(item)
                }
                subStrip = strip
            }
            // 第二行信息：到期倒计时/引导文案（time/external-link 图标 + 分段文本，9pt systemGray 行高 12）。
            // 段间与 icon↔文本均 3pt，由 stack.spacing 布局提供，不再用空格字符做间隔。
            // TRAE 原签到信息行是恒空的占位容器（文字条目已移除）——已废弃：
            // info=nil 时点阵/账号条仍作第二行入组（标题+积分贴顶，与其他卡对齐）；非当前账号无第二行
            var segLabels: [NSTextField] = []
            var expireIcon: NSImageView? = nil
            let info: NSStackView?
            if isCurrent && style.showsExpire {
                var rowViews: [NSView] = []
                // 第二行图标可选：重置倒计时按周期用 clock-stop-w（Qwen 7 天）/ clock-stop-m（WB/TRAE/Codex 月），
                // 周期不确定（ZCode 套餐到期）用 clock-stop，DS/ZhiPu 用 external-link 打开页面图标
                if let symbol = style.expireIconSymbol {
                    let icon = NSImageView()
                    // TRAE 已停止维护，使用原生 xmark；其他平台继续使用既有 SVG 图标。
                    // SVG 裁剪后墨迹最大边精确 10pt，与 SF Symbol 口径一致。
                    icon.image = symbol == "xmark"
                        ? NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
                        : Self.trimmedBundleSvgIcon(symbol, size: 10)
                    icon.image?.isTemplate = true   // 兜底：SVG 路径已置 isTemplate，显式再置一次防裁剪回退分支丢失
                    icon.contentTintColor = .systemGray
                    icon.imageScaling = .scaleProportionallyUpOrDown
                    icon.widthAnchor.constraint(equalToConstant: 10).isActive = true
                    icon.heightAnchor.constraint(equalToConstant: 10).isActive = true
                    rowViews.append(icon)
                    expireIcon = icon
                }
                // 最多 3 段（剩余 / x天 / HH:MM）；apply 按分段数组填充，未用的段 isHidden 收起间距
                for _ in 0..<3 {
                    let lbl = NSTextField(labelWithString: "")
                    registerFont(lbl, size: Palette.cardSubFontSize)
                    lbl.textColor = .systemGray
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
            // 昵称 label：2026-09-02 移除卡片 hover 昵称展示——昵称/徽章改由积分按钮
            // 悬浮气泡承载（showSubAccountTip）。label 仅作透明占位参与标题行布局
            //（保持既有行几何不变），恒不显示
            let nickLabel = NSTextField(labelWithString: "")
            // 非 Agent 平台恒单账号（main.swift 快照为单元素数组）、Agent 平台非当前账号
            // 走上方占位 continue，能走到这里的卡片必为当前账号——小卡尺寸/降透明等
            // isCurrent 分支已随死代码清理移除（2026-08-31）
            let imgSize: CGFloat = style.iconSize
            // 上下内边距大小卡统一 6pt（2026-08-31 → 5.5；2026-09-01 用户指定 → 6）
            let cardPadTop: CGFloat = 6
            let cardPadBottom: CGFloat = 6
            // 签到失败角标（当日失败时显示；无签到平台仅调试模式，apply 阶段控制显隐）
            let badge = makeFailureBadge()
            // 平台 icon 视图（原渐变 fadeIcon 薄壳已随小白点指示替代而移除）
            let fadeIcon = NSImageView()
            // 任务状态光环引用：全平台卡片挂载——Agent 卡由快照 taskState 驱动（WB/ZCode/
            // Codex 为真实任务态，状态调试开关三态轮派）；API 卡（DS/ZhiPu/Qwen）为脉冲驱动态
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
                                  nickLabel: nickLabel,
                                  titleWeight: .medium, valueWeight: .medium,
                                  failureBadge: badge,
                                  premadeIconView: fadeIcon,
                                  hoverSubStrip: subStrip,
                                  valuePrefixIcon: isAgentCard ? "coin" : nil,
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
            }, topPadding: cardPadTop, bottomPadding: cardPadBottom, horizontalPadding: 8, trailingPadding: 10,
               cardBackground: nil, hoverGradientOverride: Palette.cardHoverStrong)
            cardRef = card
            // 当前账号积分 chip 气泡数据盒（hc 块内挂接闭包捕获，append 后存入 entry 供 apply 更新）
            var newChipTipBox: ChipTipBox? = nil
            if let hc = card as? HoverCard {
                // 其余账号切换项注册到卡片：点在项内由卡片 mouseDown 路由转交，
                // 不触发整卡点击/拖拽（整卡 hitTest 接管，项自身收不到事件）
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
                            let work = DispatchWorkItem { [weak self, weak strip, weak dotsView, weak hc, weak valueView] in
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
                                stripExitInFlight = false   // 新一轮换入：离场在途标记复位
                                // 当前账号积分同步 chip 化（cardForeground 背景 + 反向前景，2026-09-02 用户定稿）
                                valueView?.setChipActive(true)
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
                            stripRevealWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.hoverDwell, execute: work)
                        } else {
                            stripRevealWork?.cancel()
                            stripRevealWork = nil
                            // 账号条尚未显示（驻留未满）：无换出对象，点阵保持原样。
                            // 离场 = chip 交错下沉淡出（staggerRiseIn 镜像）+ 点阵透明度恢复
                            if !strip.isHidden, !stripExitInFlight {
                                subStripSwapEpoch += 1   // 作废在途换入的点阵落藏 guard + 在途 stagger 淡入块
                                stripExitInFlight = true
                                let exitEp = subStripSwapEpoch
                                // 积分 chip 同步熄灭（与 chip 交错下沉同拍淡出）
                                valueView.setChipActive(false)
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
                                     nickLabel: nickLabel, segmentLabels: segLabels,
                                     expireIcon: expireIcon, badgeView: badge,
                                     iconView: fadeIcon,
                                     statusRing: capturedStatusRing,
                                     menuBarDot: capturedMenuBarDot ?? NSView()))
            entries[entries.count - 1].subAccountsStrip = subStrip
            entries[entries.count - 1].subValueLabels = subValueLabels
            entries[entries.count - 1].subItems = subItems
            entries[entries.count - 1].chipTipBox = newChipTipBox
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
            // （2026-08-27：「套餐已到期」取消红色警告，与其他到期文本一致用 systemGray）
            // TRAE 已停止维护：固定显示 xmark +「此平台不再维护」，不再显示套餐重置时间。
            let segs = style.platformID == "trae" ? ["此平台不再维护"] : (ac.expireSegments ?? [])
            for (i, lbl) in e.segmentLabels.enumerated() {
                if i < segs.count {
                    lbl.stringValue = segs[i]
                    lbl.isHidden = false
                } else {
                    lbl.isHidden = true
                }
                lbl.textColor = .systemGray
            }
            e.expireIcon?.contentTintColor = .systemGray
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
            e.dots.isHidden = ac.hideDots || !(e.subAccountsStrip?.isHidden ?? true)
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
    private func showSubAccountTip(nickname: String, value: String, tokenInvalid: Bool = false,
                                   checkin: (done: Bool, failed: Bool, risk: Bool)? = nil,
                                   anchorCard: NSView) {
        cancelChipTip()
        guard let anchorWindow = anchorCard.window else { return }
        let nick = NSTextField(labelWithString: "昵称: \(nickname)")
        // 两行统一：小字（cardSubFontSize）+ 亮色前景 cardForeground
        registerFont(nick, size: Palette.cardSubFontSize, weight: .medium)
        nick.textColor = Palette.cardForeground
        // 徽章挂昵称后（字体取 nick 实际字体：Mono 开关等字体策略经 registerFont 已生效）
        let line = NSMutableAttributedString(
            string: "昵称: \(nickname)",
            attributes: [.font: nick.font ?? .systemFont(ofSize: Palette.cardSubFontSize),
                         .foregroundColor: Palette.cardForeground])
        if tokenInvalid, let font = nick.font {
            // 令牌失效/账号无套餐（账号级问题，不进刷新失败）：黄色警示胶囊。
            // icon 用 SF Symbol 附件（黄色，随昵称字号等比行内居中）——
            // ⚠︎ 文本字形在 10pt 下渲染不完整且与文字间空隙偏宽，故弃用；
            // icon 紧贴「令牌失效」文本（零字间距），胶囊底色黄@18%
            let tint = NSColor(calibratedRed: 1, green: 0.78, blue: 0, alpha: 1)
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
        let val = NSTextField(labelWithString: "积分:\(value)")
        registerFont(val, size: Palette.cardSubFontSize, weight: .medium)
        val.textColor = Palette.cardForeground
        val.usesSingleLineMode = true
        val.lineBreakMode = .byClipping
        // 度量：直接量属性串（附件按 attachment.bounds 计入），不信 intrinsicContentSize——
        // 含附件/部分字体组合下 cellSize 低估宽度，正是徽章被裁的根因
        let valLine = NSAttributedString(
            string: "积分:\(value)",
            attributes: [.font: val.font ?? .systemFont(ofSize: Palette.cardSubFontSize),
                         .foregroundColor: Palette.cardForeground])
        val.attributedStringValue = valLine
        let nickSize = line.size()
        let vw = valLine.size()
        let bodyW = ceil(max(nickSize.width, vw.width)) + 20
        // 行带按文本实际行高取（两行同号 ≈ 11，不足 10 兜底），
        // 上下 4pt + 行距 2；气泡高 = max(锚点卡高, 内容自然高)——内容可能
        // 高于卡高，取较大者避免文字溢出裁切
        let titleBand: CGFloat = max(10, ceil(nickSize.height))
        let infoBand: CGFloat = max(10, ceil(vw.height))
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
        if let pc = Self.findPanelContainer(from: self) {
            glass.tintColor = pc.tintColor
            glass.tintBottomColor = pc.tintBottomColor
        } else {
            let colors = Palette.containerColors(
                lightTint: lightThemeEnabled || !effectiveAppearance.isDark,
                gradientOn: panelGradientEnabled)
            glass.tintColor = colors.top
            glass.tintBottomColor = colors.bottom
        }
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
        // 轮廓描边（独立覆盖层,不受 mask 裁切）
        let outline = SubAccountTipBubbleView(frame: container.bounds)
        outline.autoresizingMask = [.width, .height]
        outline.arrowEdge = edge
        container.addSubview(outline)
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
        win.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                 gradientOn: panelGradientEnabled)
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

    /// 气泡轮廓（圆角矩形+一侧三角箭头,圆角=Palette.cardCornerRadius 与卡片统一）：
    /// 同一份 tipShapePath 供两处消费——玻璃层 layer mask 裁切 + 本视图描边覆盖层
    private final class SubAccountTipBubbleView: NSView {
        /// 箭头方向：.maxX=箭头在本体左侧指向左（气泡在锚点右侧）;.minX 反向
        var arrowEdge: NSRectEdge = .maxX
        static let arrowLength: CGFloat = 8
        static let arrowHalfWidth: CGFloat = 6

        /// 单轮廓路径（bounds 局部坐标）：逆时针 上缘→右上弧→右缘（.minX 嵌箭头）
        /// →右下弧→下缘→左下弧→左缘（.maxX 嵌箭头）→左上弧→闭合
        static func tipShapePath(bounds: NSRect, edge: NSRectEdge) -> NSBezierPath {
            let r = Palette.cardCornerRadius
            let inset: CGFloat = 0.25   // 描边半宽,防轮廓被裁
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

        override func draw(_ dirtyRect: NSRect) {
            // 只描边（玻璃填充由 mask 后的 TintedVisualEffectView 承担）
            let path = Self.tipShapePath(bounds: bounds, edge: arrowEdge)
            Palette.tooltipBorder.setStroke()
            path.lineWidth = 0.5
            path.stroke()
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
    /// root 底部上限约束（≤ panel.bottom-41）：仅为 fittingSize 预留 footer 区、
    /// 防止内容与贴底 footer 重叠服务；日常高度求解不应依赖它
    var rootBottomCap: NSLayoutConstraint?
    /// 字符化开关（MonoCharSwitch）切换模糊→清晰过渡的计时器
    var charBlurTimer: Timer?
    /// 进行中模糊过渡的目标图层（timer 为多调用方共享：新调用接管时旧图层集
    /// 中断在中间模糊半径——不清滤镜会永久停在模糊状态，见 playCharBlurTransition）
    var charBlurLayers: [CALayer] = []

    // MARK: - 控件回调（转发给 AppDelegate 接线）

    @objc func openCockpitTapped() { onOpenCockpit?() }
    @objc func autoCheckinToggled() { onToggleAutoCheckin?() }
    @objc func addWbAccountTapped() { onAddWbAccount?() }
    @objc func addZcodeAccountTapped() { onAddZcodeAccount?() }
    @objc func addCodexAccountTapped() { onAddCodexAccount?() }
    @objc func addTraeAccountTapped() { onCollectTraeAccount?() }
    @objc func panelGradientToggled() { onTogglePanelGradient?() }
    @objc func lightThemeToggled() { onToggleLightTheme?() }

    /// 浅色主题切换时对自带深色外观的自绘控件换肤（MiniSwitch/MiniSegmented
    /// 各自持有 appearance、不继承容器外观，必须显式设置；其余自绘控件用动态色自动跟随）
    private func applyControlsTheme() {
        let light = lightThemeEnabled
        for entry in switchRows { entry.sw.applyThemeAppearance(light: light) }
        // 下拉菜单与开关一样自带 appearance（不继承容器），浅色主题时显式切浅色
        intervalPopup.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }
    @objc func monoFontToggled() { onToggleMonoFont?() }
    @objc func valueScrollPreviewToggled() { onToggleValueScrollPreview?() }
    @objc func statusDebugPreviewToggled() { onToggleStatusDebugPreview?() }
    @objc func checkUpdateTapped() { onCheckForUpdate?() }
    @objc func updateAutoCheckToggled() { onToggleUpdateAutoCheck?() }

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
        pinBtn.contentTintColor = panelPinned ? Palette.cardForeground : .systemGray
        dragGrabber.isHidden = !panelPinned
        onTogglePin?()
    }

    /// 外部关闭置顶浮动窗（如点击菜单栏图标）时复位 pin 状态，下次打开为普通 popover
    func resetPin() {
        panelPinned = false
        pinBtn.image = symbolImage("pin", size: 11)
        pinBtn.contentTintColor = .systemGray
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
    @objc func setApiKeyTapped() { onSetApiKey?() }

    @objc func platformTogglesTapped() { onManagePlatformToggles?() }

    @objc func aboutTapped() { onAbout?() }
    @objc func manualCheckinTapped() { onManualCheckin?() }
    @objc func checkinHistoryTapped() { onShowCheckinHistory?() }
    @objc func shareWbHistoryTapped() { onShareWbHistory?() }
    @objc func quitTapped() { onQuit?() }
    @objc func openGitHubTapped() { onOpenGitHub?() }
    @objc func intervalChanged() {
        // 选项 tag 即秒数（60/180/300）
        onSetInterval?(intervalPopup.selectedItem?.tag ?? 300)
    }
    @objc func manualRefreshTapped() { onManualRefresh?() }
    @objc func quickBuildTapped() { onQuickBuild?() }
}

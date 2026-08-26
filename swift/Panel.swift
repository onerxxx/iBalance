// Panel.swift — NSPopover 详情面板（左键点击菜单栏图标弹出）
//
// 布局（宽 240pt）：
//   头部    iBalance + 刷新按钮
//   横幅    离线提示（条件显示）
//   卡片 ×4 DeepSeek / ZCode / TRAE（含用量进度条）/ WorkBuddy
//   设置卡片  自动签到开关 / 刷新间隔 / 昵称开关 / 调试
//   操作卡片  Cockpit / 添加账号 / API Key / 平台开关 / 关于
//   底部    更新于 HH:mm:ss + 退出按钮
//
// v1.1：原右键菜单的全部选项搬入弹窗；右键菜单保留作为兜底。
import Cocoa
import CoreImage

/// 面板数据快照（由 AppDelegate 从各服务缓存 + 设置状态构建）
struct PanelSnapshot: Equatable {
    /// DeepSeek 卡片数据（单元素，走多号卡片管线；uid 恒 "ds"，无昵称无签到）
    var dsAccounts: [AccountCardSnapshot] = []
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
    /// Mono 字体开关（同步自配置；余额卡片与用量列表 JetBrainsMono ↔ 系统字体）
    var monoFontEnabled = false
    /// Inter 字体开关（同步自配置；面板文本 Inter ↔ 系统字体，优先级 Mono > Inter）
    var interFontEnabled = false
    /// 数值滚动预览开关（开启后余额卡片周期随机变化，演示逐位滚动动画）
    var valueScrollPreviewEnabled = false
}

struct AccountCardSnapshot: Equatable {
    var uid: String
    var nickname: String
    var value: String?              // 已格式化的剩余额度
    var usedRatio: Double = 0       // 已用占比（0~1），用于点阵进度
    var isCurrent: Bool = false     // 是否为当前登录账号（主账号 icon 全尺寸，其余缩小）
    var pulsing: Bool = false       // 额度被消耗（usedRatio 上升）→ 最右亮点阵脉冲
    var expireText: String?         // 重置/套餐到期倒计时（Codex / ZCode 当前账号）
    var expired: Bool = false       // Start Plan 已到期（expireText 显示"套餐已到期"红色警告）
    var checkinDone: Bool = false   // 今日已签到
    var checkinFailed: Bool = false // 签到失败（按 failed_date==today 口径；风控日也置 true 以显示角标）
    var checkinRisk: Bool = false   // 签到失败为风控（TRAE 返回 9074/操作太频繁）→ 角标橙黄色
    var streak: Int = 0             // 连续签到天数
    var reward: Int = 0             // 最近一次签到积分奖励
    var inMenuBar: Bool = false     // 该账号数值显示在菜单栏 → 卡片 icon 叠加透明渐变标记
    var hideDots: Bool = false      // 隐藏点阵（DeepSeek 未配置日常额度时；多号平台恒 false）
}

/// 动效统一取值表（UIUX-OPTIMIZATION.md §1）：时长与曲线只允许从这里取，
/// 新增动效不得再引入裸字面量。脉冲循环（0.5/0.55/0.6）与签名动效
/// （字重渐变 1s、字符模糊切换 0.35、刷新按钮旋转 0.45）保留自有参数不进表。
enum Motion {
    /// 按压反馈：100–160ms 区间，越快越跟手
    static let press: CFTimeInterval = 0.12
    /// hover 态切换（文本提亮与背景渐变统一此时长）
    static let hover: CFTimeInterval = 0.25
    /// 布局重排/换位：屏上位移
    static let layout: CFTimeInterval = 0.20
    /// 标题 hover 字重动画（Inter 500↔900）：跟手优先（用户定稿 0.16s）
    static let weight: CFTimeInterval = 0.16
    /// 内容揭示/淡入：偶发动作稍从容
    static let reveal: CFTimeInterval = 0.24
    /// 强调动效硬顶：一切 UI 动画 ≤ 0.40
    static let emphasis: CFTimeInterval = 0.40
    /// 余额数字滚动（Number Rolling）：数据变化反馈类动效，非 UI 状态切换，
    /// 用户指定加长时长，不适用 0.40 硬顶
    static let roll: CFTimeInterval = 2.0

    /// 强 ease-out（等价 cubic-bezier(0.23,1,0.32,1)）：入场/反馈用，
    /// 起手快收尾长，比系统 easeOut 更有意图
    static let easeOutStrong = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    /// 强 ease-in-out（等价 cubic-bezier(0.77,0,0.175,1)）：屏上位移用
    static let easeInOutStrong = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
}

/// 配色 token：集中管理所有自定义颜色，避免硬编码散落各处
enum Palette {
    /// 卡片前景色 #DDDDDD（余额卡片 icon/标题/数值、三大分组标题统一使用）
    static let cardForeground = NSColor(calibratedRed: 0xE9/255.0, green: 0xE9/255.0, blue: 0xE9/255.0, alpha: 1)
    /// 非当前账号前景色：石墨灰（不透明；用户定稿 0.61）
    static let cardForegroundDimmed = NSColor(calibratedWhite: 0.61, alpha: 1.0)
    /// 卡片底色：完全透明（露出容器毛玻璃）
    static let cardBackground = NSColor.clear
    /// 卡片 hover 提亮色 #333333 @ 30%
    static let cardBackgroundHover = NSColor(calibratedWhite: 51.0 / 255.0, alpha: 0.3)
    /// 统一 hover 渐变背景（余额卡片/操作磁贴/折叠标题条/用量条目共用）：
    /// 沿 60° 方向从亮到暗的白色渐变。改色只动这两个端点。
    static let hoverGradientBright = NSColor.white.withAlphaComponent(0.08)
    static let hoverGradientDark = NSColor.white.withAlphaComponent(0.05)
    /// 渐变端点数组（CAGradientLayer.colors 直接可用）
    static let hoverGradient: [NSColor] = [hoverGradientBright, hoverGradientDark]
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
    /// 容器玻璃遮罩色（近黑半透明，加深毛玻璃底色）
    static let containerTint = NSColor(calibratedWhite: 0.02, alpha: 0.45)
    /// 容器玻璃渐变底色（中灰半透明）：与 containerTint 组成纵向渐变，顶部近黑 → 底部中灰
    static let containerTintBottom = NSColor(calibratedWhite: 0.25, alpha: 0.45)
    /// 卡片圆角 10pt（对齐 macOS Big Sur+ NSPopover 窗口系统圆角）
    static let cardCornerRadius: CGFloat = 10
    /// 卡片边框色/分割线色（暗主题：浅灰半透明，1px 描边，统一白@10%）
    static let cardBorderColor = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    /// hover 边框常态色（白@20%）：卡片预设边框色，非 hover 时使用
    static let hoverBorderNormal = NSColor.white.withAlphaComponent(0.20)
    /// hover 边框提亮色（白@35%）：hover 时边框色随宽度一起动画到此色
    static let hoverBorderBright = NSColor.white.withAlphaComponent(0.35)
    /// 卡片边框宽度 1pt
    static let cardBorderWidth: CGFloat = 1
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
private func axisTag(_ s: String) -> Int {
    let b = Array(s.utf8)
    let v = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    return Int(Int32(bitPattern: v))
}

/// Inter（Inter Variable 可变字体，无中文字形）：拉丁字符用 Inter，缺字（中文/特殊符号）
/// 通过 cascade 级联自动回退系统字体。字体文件随 App 打包在 Resources/，首次使用时按进程注册（幂等）。
/// 双轴：wght（100..900，默认 400）+ opsz（14..32，默认 14）。这里**只连续写 wght 轴**（Light→Black
/// 无极可调），opsz 固定在 14（正文观感），中文级联回退系统字体。
enum InterFontProvider {
    /// 基础实例：所有变体从同一 PostScript 名派生，wght 由 .variation 覆盖
    private static let basePostScript = "InterVariable"
    private static var registeredInstance = false

    static func register() {
        guard !registeredInstance else { return }
        registeredInstance = true
        guard let url = Bundle.main.url(forResource: "InterVariable", withExtension: "ttf")
            ?? Bundle.main.url(forResource: "InterVariable", withExtension: "otf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// NSFont.Weight → Inter wght 轴连续值（100..900）：
    /// 用标准 CSS 字重刻度锚点映射，非 NSFont.Weight.rawValue 线性（regular=0 若线性会落到 550 偏粗）。
    private static func wghtValue(for weight: NSFont.Weight) -> Double {
        switch weight {
        case .ultraLight: return 100
        case .thin:       return 100
        case .light:      return 300
        case .regular:    return 400
        case .medium:     return 500
        case .semibold:   return 600
        case .bold:       return 700
        case .heavy:      return 800
        case .black:      return 900
        default:          return 400
        }
    }

    /// Inter + 系统字体级联：wght 无级写入（opsz 固定），中文回退系统字体
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(size: size, wght: wghtValue(for: weight))
    }

    /// 按任意 wght 值（100..900）生成 Inter 字体（opsz 固定 14，中文级联回退系统字体）。
    /// 供 hover 字重动画逐帧驱动（接受连续插值，如 400→800）。
    static func font(size: CGFloat, wght: Double) -> NSFont {
        register()
        guard let base = NSFont(name: basePostScript, size: size) else {
            return .systemFont(ofSize: size, weight: .regular)
        }
        let variations: [Int: Double] = [
            axisTag("wght"): wght,
            axisTag("opsz"): 14,
        ]
        let cascade = NSFont.systemFont(ofSize: size, weight: .regular).fontDescriptor
        let desc = base.fontDescriptor.addingAttributes([
            .variation: variations,
            .cascadeList: [cascade],
        ])
        if let f = NSFont(descriptor: desc, size: size) { return f }
        return base
    }
}

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

/// 面板内容控制器：把 BalancePanelView 挂进 popover，宽度固定 250，高度受屏幕可用空间限制；
/// 内容超高时通过纵向滚动查看底部设置、操作和更新时间。
final class BalancePanelViewController: NSViewController {
    private let panel: BalancePanelView
    private let scrollView = QuietScrollView()
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
        container.appearance = NSAppearance(named: .darkAqua)  // 强制深色外观加深底色
        // 叠加半透明遮罩：渐变开启时顶部 100% 透明 → 底部深灰；关闭时整面单色深灰
        container.tintColor = panel.panelGradientEnabled ? Palette.containerTint.withAlphaComponent(0) : Palette.containerTint
        container.tintBottomColor = panel.panelGradientEnabled ? Palette.containerTint : nil
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
            // 滚动视口直接铺满内容区域（非满尺寸模式，容器本身已在箭头下方）
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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
            topHint.topAnchor.constraint(equalTo: container.topAnchor),
            topHintHeightConstraint!,
        ])
        // 初始参数（可能由 AppDelegate 在 view 加载前写入）：应用到两个提示层
        fadeHint.params = fadeHintParams
        topHint.params = fadeHintParams
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
            self?.updateFadeHint()
            // 滚动后修正各卡片/按钮的 hover 状态（AppKit 不补发 enter/exit 事件）
            self?.syncHoverAfterScroll()
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
        panel.layoutSubtreeIfNeeded()
        let contentSize = panel.fittingSize
        // 浮窗模式宽度跟随视口（用户 resize 结果）；popover 模式按内容固有宽（≥250）
        let documentWidth = isFloatingWindow
            ? max(PanelResizeHandle.minWidth, scrollView.contentView.bounds.width)
            : max(250, contentSize.width)
        // 浮窗模式视口高于内容时把 document 拉伸到视口高：非翻转文档视图
        // 底部对齐，不拉伸会内容沉底、顶部空出一块；root 顶锚后底部留玻璃空区
        let contentHeight = isFloatingWindow
            ? max(contentSize.height, scrollView.contentView.bounds.height)
            : max(1, contentSize.height)
        let nextFrame = NSRect(x: 0, y: 0, width: documentWidth, height: contentHeight)
        if panel.frame != nextFrame { panel.frame = nextFrame }
        let viewportHeight = min(contentHeight, maximumHeight)
        // 滚动条始终隐藏（初始化 hasVerticalScroller=false，这里不再动态开启）
        let nextContentSize = NSSize(width: documentWidth, height: viewportHeight)
        // 浮窗模式不回写 preferredContentSize：窗口宽高由用户 resize 决定，
        // 避免内容变化（折叠/行数变化）把浮窗尺寸拉回内容高度
        if !isFloatingWindow, preferredContentSize != nextContentSize {
            preferredContentSize = nextContentSize
        }
        updateFadeHint()
        layoutProbe("ucs", force: true)
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
    /// 高度不低于视口（窗口拖高时拉伸 document，防止非翻转视图内容沉底）。
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
        f.size.width = max(PanelResizeHandle.minWidth, clip.bounds.width)
        if f.height < clip.bounds.height - 0.5 { f.size.height = clip.bounds.height }
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

    /// 按当前开关状态刷新背景遮罩：顶部全透明 → 底部深灰的纵向渐变，或单色深灰
    private func applyGradient() {
        guard let container = view as? TintedVisualEffectView else { return }
        container.tintColor = panel.panelGradientEnabled ? Palette.containerTint.withAlphaComponent(0) : Palette.containerTint
        container.tintBottomColor = panel.panelGradientEnabled ? Palette.containerTint : nil
        container.tintGradientStartY = 0
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
        // NSScrollView 在内容尺寸更新后可能立即显示 overlay scroller，弹出完成后再明确隐藏一次。
        scrollView.hideScrollers()
        // 弹出动画可能调整视口尺寸，展示完成后按最终布局刷新一次提示状态
        updateFadeHint()
        // 面板关闭时不保证补发 mouseExited：打开时按光标位置同步，
        // 清掉上一次会话残留的 hover 高亮（光标就在卡片上时则正确点亮）
        syncHoverAfterScroll()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        panel.dismissUsageHistoryPopover()
        // 面板关闭后停止箭头浮动动画，避免不可见时持续渲染
        fadeHint.setShown(false)
        topHint.setShown(false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 布局变化后同步背景遮罩（顶部全透明 → 底部深灰渐变 / 单色深灰）
        applyGradient()
        updateFadeHint()
        layoutProbe("didLayout")
    }
}

/// 余额平台标识与默认顺序：面板卡片排序与菜单栏条目共用。
enum BalancePlatform: String, CaseIterable {
    case deepSeek = "ds"
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

    // MARK: - 对外回调（由 AppDelegate 接线到现有处理逻辑）

    var onOpenCockpit: (() -> Void)?
    var onToggleAutoCheckin: (() -> Void)?
    var onAddWbAccount: (() -> Void)?
    var onSetInterval: ((Int) -> Void)?          // 秒数：60 / 180 / 300
    /// 手动刷新（刷新时间行内的刷新按钮触发）
    var onManualRefresh: (() -> Void)?
    var onSetApiKey: (() -> Void)?
    /// 面板渐变背景开关（设置卡片开关触发）
    var onTogglePanelGradient: (() -> Void)?
    /// Mono 字体开关（设置卡片开关触发：余额卡片与用量列表切换 JetBrainsMono）
    var onToggleMonoFont: (() -> Void)?
    /// Inter 字体开关（设置卡片开关触发：面板文本切换 Inter，优先级 Mono > Inter）
    var onToggleInterFont: (() -> Void)?
    /// 数值滚动预览开关（设置卡片开关触发：余额数值周期随机变化演示滚动）
    var onToggleValueScrollPreview: (() -> Void)?
    /// 渐变开关状态变化通知（update 同步时触发，VC 据此刷新遮罩绘制）
    var onPanelGradientChanged: (() -> Void)?
    var onAbout: (() -> Void)?
    /// 管理各平台刷新、自动签到、卡片与用量显示开关
    var onManagePlatformToggles: (() -> Void)?
    var onManualCheckin: (() -> Void)?
    /// 查看签到历史（各账号签到记录列表）
    var onShowCheckinHistory: (() -> Void)?
    var onQuit: (() -> Void)?
    /// 右上角 pin 按钮：切换面板置顶常驻（内容转移至无边框 NSPanel 浮动窗口，
    /// 无箭头、浮层层级、可自由拖动；取消置顶时装回 popover）
    var onTogglePin: (() -> Void)?
    /// 置顶状态（pin ↔ pin.fill 图标切换）
    private(set) var panelPinned = false
    // 余额卡片点击回调：DeepSeek 打开网页，TRAE / WorkBuddy / ZCode 启动应用
    var onClickDeepSeek: (() -> Void)?
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

    /// 单个多号卡片的控件引用（update 时直接赋值，无需重建；WB / TRAE / ZCode 共用）。
    /// 非当前账号的 dots/checkinInfo 为占位实例（未加入视图层级，更新时跳过）。
    private struct CardEntry {
        let uid: String
        let valueView: RollingNumberView   // 余额数值（逐位垂直滚动）
        let dots: UsageDots
        let checkinInfo: NSStackView   // 副标题信息行容器（签到文字条目已移除，暂时留空）
        let nickLabel: NSTextField
        let infoLabel: NSTextField?    // 到期倒计时副标题（仅 ZCode 当前账号卡片有）
        let expireIcon: NSImageView?   // 到期行 timer 图标（随 expired 状态变色）
        let badgeView: NSView          // 签到失败角标（icon 右上角，无签到平台恒隐藏）
        let iconView: MenuBarFadeIconView  // 平台 icon（未上菜单栏时叠加垂直透明渐变）
        var nickKey: String = ""       // 昵称+签到状态组合缓存 key（附件重建判据）
        var lastValue: String = ""     // 上次应用的余额文本（数字滚动判据；空 = 首次赋值直接显示）
        var roller: NumberRollAnimator?  // 数字滚动驱动器（引用类型，结构体拷贝共享同一动画）
    }

    /// 各平台卡片差异配置（icon / 标题 / 签到行 / 到期行 / reward 兜底）
    private struct CardStyle {
        let icon: String
        let name: String
        let platformID: String
        let iconSize: CGFloat           // 当前账号 icon 尺寸（SVG 视觉微调）
        let secondaryIconSize: CGFloat  // 非当前账号小卡片 icon 尺寸（SVG 视觉微调）
        // Mono 模式 ASCII icon 标称尺寸：不做 SVG 视觉微调，各平台统一，
        // 保证像素字母（D/W/T/Z/C）在卡片间显示大小一致
        let monoIconSize: CGFloat           // Mono 当前账号标称尺寸
        let monoSecondaryIconSize: CGFloat  // Mono 非当前账号标称尺寸
        let checkin: Bool               // 是否显示签到信息行（WB / TRAE）
        let showsExpire: Bool           // 是否显示第二行副标题（ZCode/Codex 到期倒计时、DeepSeek 日常额度）
        let expireIconSymbol: String?   // 第二行图标（nil = 纯文本行，DeepSeek；ZCode/Codex 为 "timer"）
        let menuBarIdPrefix: String     // 菜单栏 item id 前缀："trae:" / "wb:" / "zcode:"
        // iconSize 为「视觉补偿尺寸」：统一图标列宽后，按各 SVG 图形实测留白
        //（视觉宽占 viewBox 比例：wb 92% / trae 72% / zhipu 86% / codex 满幅 / deepseek 75%）
        // 放大留白多的图标，使「图标视觉右缘 → 标题」的间距各卡一致（≈10-11pt）
        static let wb    = CardStyle(icon: "workbuddy", name: "WorkBuddy", platformID: "wb", iconSize: 20.47, secondaryIconSize: 12.65, monoIconSize: 20.47, monoSecondaryIconSize: 12.65, checkin: true, showsExpire: true, expireIconSymbol: "timer", menuBarIdPrefix: "wb:")
        static let trae  = CardStyle(icon: "trae-color", name: "TRAE", platformID: "trae", iconSize: 22, secondaryIconSize: 12.65, monoIconSize: 20.47, monoSecondaryIconSize: 12.65, checkin: true, showsExpire: false, expireIconSymbol: nil, menuBarIdPrefix: "trae:")
        static let zcode = CardStyle(icon: "zhipu", name: "ZCode", platformID: "zcode", iconSize: 19, secondaryIconSize: 12.02, monoIconSize: 20.47, monoSecondaryIconSize: 12.65, checkin: false, showsExpire: true, expireIconSymbol: "timer", menuBarIdPrefix: "zcode:")
        static let codex = CardStyle(icon: "codex", name: "Codex", platformID: "codex", iconSize: 19.45, secondaryIconSize: 12.02, monoIconSize: 20.47, monoSecondaryIconSize: 12.65, checkin: false, showsExpire: true, expireIconSymbol: "timer", menuBarIdPrefix: "codex:")
        static let ds    = CardStyle(icon: "deepseek", name: "DeepSeek", platformID: "ds", iconSize: 22, secondaryIconSize: 12.65, monoIconSize: 20.47, monoSecondaryIconSize: 12.65, checkin: false, showsExpire: true, expireIconSymbol: nil, menuBarIdPrefix: "")
    }

    // TRAE 多账号卡片容器（动态重建，账号列表变化时刷新）
    var traeCardsContainer: NSStackView!
    private var traeCardEntries: [CardEntry] = []
    private var traeCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）

    // 余额卡片组容器（统一背景 + 圆角，子卡片透明）；背景渐变起点定位依据
    var balanceGroupContainer: NSStackView!
    /// 平台容器 == 组宽：单列布局下容器撑满组宽，数值/点阵才能贴右对齐
    func pinPlatformWidth(_ container: NSStackView) {
        let c = container.widthAnchor.constraint(equalTo: balanceGroupContainer.widthAnchor)
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
    /// 刷新动效状态：true 时「更新于」区域脉冲显示「刷新中…」
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
    /// 用量行最大内容宽度（列宽自动分配的预算上限）
    private let usageMaxRowWidth: CGFloat = 240
    /// 当前自动分配的三列宽（每次行重建前按内容重算；此为初值兜底）
    var usageColWidths = (week: CGFloat(50), today: CGFloat(44), hour: CGFloat(40))

    /// 按实际内容自动分配三列宽度：每列 = max(表头, 全部行文本) 宽 + 6pt 呼吸；
    /// 名称列与固定开销先扣，剩余预算不够时按比例收窄（列宽下限保 5 字符值，
    /// 名称列再不够由自身截断兜底）。字体度量取当前 uiFont——字体开关切换后
    /// applyFontPolicy 强制清空 renderedUsageRows 触发重建重算。
    private func computeUsageColumnLayout(_ rows: [UsageRowSnapshot]) {
        let valueFont = uiFont(size: 10, weight: .regular, monoDigits: true)
        let headerFont = uiFont(size: 10, weight: .semibold)
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
        let nameFont = uiFont(size: 10)
        let nameW = rows.map { w($0.name, nameFont) }.max() ?? 40
        // 固定开销：左右 inset 16 + icon 14 + icon↔名 4 + 名↔数值区 6 + 三个列间隙 24
        let budget = usageMaxRowWidth - 16 - 14 - 4 - 6 - 24 - nameW
        let total = hour + today + week
        if total > budget, total > 0 {
            let scale = budget / total
            hour = max(34, hour * scale)
            today = max(38, today * scale)
            week = max(40, week * scale)
        }
        usageColWidths = (week: week, today: today, hour: hour)
    }

    let usageColumnSpacing: CGFloat = 8
    let usageHorizontalInset: CGFloat = 8
    /// 用量行行内垂直缩进（行间距 0，每行上下统一缩进 4pt）
    let usageRowTopInset: CGFloat = 4
    let usageRowBottomInset: CGFloat = 4

    let autoCheckinSwitch = MiniSwitch()
    let autoCheckinSub = NSTextField(labelWithString: "")
    let wbAddBtn = ActionTileButton(bundleIcon: "workbuddy",
                                           title: "添加账号", target: nil, action: nil)
    let traeAddBtn = ActionTileButton(bundleIcon: "trae-color",
                                             title: "添加账号", target: nil, action: nil)
    /// 手动签到磁贴：进行中由 update() 驱动脉冲 + 禁点
    let checkinBtn = ActionTileButton(symbol: "checkmark.seal",
                                              title: "手动签到", target: nil, action: nil)
    let zcodeAddBtn = ActionTileButton(bundleIcon: "zhipu",
                                               title: "添加账号", target: nil, action: nil,
                                               svgIconSize: 14.45)  // SVG 微调 ≈0.9×基准（16）；Mono 用标称 16
    // 刷新间隔：MiniSegmentedControl（原生 .mini 尺寸，紧凑稳定）
    let intervalSegment: MiniSegmentedControl = {
        let seg = MiniSegmentedControl(labels: ["1分钟", "3分钟", "5分钟"], trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = 2
        return seg
    }()
    /// 刷新间隔 Mono 字符段（Mono 模式替代原生分段控件，同框显隐切换）
    let monoSegment: MonoSegmentedControl = {
        let seg = MonoSegmentedControl(titles: ["1", "3", "5"], target: nil, action: nil)
        seg.selectedSegment = 2
        return seg
    }()
    /// Mono 字符段容器：控件右缘直接贴设置行尾，控件自身纯内容渲染；
    /// applySwitchVisuals 通过本容器控制显隐（与原生分段同框切换）
    let monoSegmentBox = NSView()
    /// 面板渐变背景开关（update 时随快照同步状态）
    let gradientSwitch = MiniSwitch()
    /// 渐变开关状态（update 同步；VC 读取决定遮罩渐变/单色）
    private(set) var panelGradientEnabled = true
    /// Mono 字体开关（update 时随快照同步状态）
    let monoSwitch = MiniSwitch()
    /// Mono 字体开关状态（update 同步；变化时对已注册 label 就地切换字体，不重建卡片）
    private(set) var monoFontEnabled = false
    /// Inter 字体开关（update 时随快照同步状态）
    let interSwitch = MiniSwitch()
    /// Inter 字体开关状态（update 同步；变化时对已注册 label 就地切换字体，不重建卡片）
    private(set) var interFontEnabled = false
    /// 非当前账号弱化透明度（已固化为默认行为：整卡降透明、悬停复亮）
    private static let subCardDimAlpha: CGFloat = 0.6
    /// 数值滚动预览开关状态（update 同步；开启后周期随机变动余额演示滚动）
    let valuePreviewSwitch = MiniSwitch()
    /// 「滚动预览」行副标题（静态文案；switchRow 默认隐藏，build 中统一显示）
    let valuePreviewSub = NSTextField(labelWithString: "余额数值周期随机变化")
    private(set) var valueScrollPreviewEnabled = false
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

    /// 按当前字体开关状态取字体（优先级：Mono 风格 > Inter > 系统字体）。
    /// Mono = JetBrainsMono（中文级联回退系统字体），Inter = Inter（中文级联回退系统字体），
    /// 关 = 系统字体（等宽数字列可选，余额数值右对齐用）。
    private func uiFont(size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) -> NSFont {
        if monoFontEnabled { return MonoFontProvider.font(size: size, weight: weight) }
        if interFontEnabled { return InterFontProvider.font(size: size, weight: weight) }
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
    /// RollingNumberView 非 NSTextField、不进 fontTargets，Mono/Inter 开关切换时单独就地刷字体
    private let rollingTargets = NSHashTable<RollingNumberView>()

    /// 注册余额滚动数值视图并注入字体策略（uiFont：Mono/Inter/系统 + 等宽数字）
    func registerRollingNumber(_ v: RollingNumberView, size: CGFloat, weight: NSFont.Weight) {
        v.configure(size: size, weight: weight, fontProvider: { [weak self] s, w, mono in
            guard let self else { return .monospacedDigitSystemFont(ofSize: s, weight: w) }
            return self.uiFont(size: s, weight: w, monoDigits: mono)
        })
        rollingTargets.add(v)
    }

    // MARK: - 标题 hover 字重动画（Inter：500↔800，1s 平滑）

    /// 单个标题的进行中动画参数（weak label：卡片重建后自动失效，tick 时清扫）
    private struct WeightAnimState {
        weak var label: NSTextField?
        var from: Double
        var to: Double
        var start: CFTimeInterval
    }
    /// 进行中的标题动画（按 label 索引，**多卡并存**）：
    /// 鼠标扫过多张卡时前一张的回落不能被后一张的进入抢占，否则前一张停在中间字重不释放
    private var weightAnims: [ObjectIdentifier: WeightAnimState] = [:]
    /// 字重动画时长（Motion.weight = 0.16s）
    private let weightAnimDuration: CFTimeInterval = Motion.weight
    /// 帧驱动：随屏幕刷新（单实例驱动 weightAnims 全部条目，空表即停）
    private var weightAnimLink: CADisplayLink?
    /// 字重动画加粗端（进入 800）
    private let weightAnimBold: Double = 800

    /// 启动/刷新标题字重动画。同一 label 在动画中被打断时从当前插值续走（平滑不跳变）；
    /// 新动画从**确定性基准**起步——进入恒从 light 起、移出恒从 800 起，
    /// 保证任何情况下移出都可靠恢复基准（不依赖可能失配的 per-label 持久状态）。
    /// light = 该卡标题的常规基准 wght（当前统一 500 medium）
    private func animateTitleWeight(label: NSTextField, to target: Double, light: Double) {
        let key = ObjectIdentifier(label)
        var from: Double
        if let s = weightAnims[key], s.label === label {
            // 同一张卡方向反转（如进入动画中途移出）：从当前插值继续，避免回跳
            from = weightAnimValue(s, at: CACurrentMediaTime())
        } else {
            from = (target == weightAnimBold) ? light : weightAnimBold
        }
        if from == target {
            // 恰在基准（如进入动画 t=0 即移出）：直接落终值并清条目
            label.font = titleWeightFont(size: label.font?.pointSize ?? 13, wght: target)
            weightAnims[key] = nil
        } else {
            weightAnims[key] = WeightAnimState(label: label, from: from, to: target, start: CACurrentMediaTime())
        }
        guard !weightAnims.isEmpty else { return }
        if weightAnimLink == nil {
            let link = displayLink(target: self, selector: #selector(onWeightAnimTick(_:)))
            // ⚠️ 必须 add 到 RunLoop mode：否则 CADisplayLink 不派发回调，动画永不渲染
            //（与 QuietScrollView、UsageHistoryChartView 的 displayLink 用法一致）
            link.add(to: .main, forMode: .common)
            weightAnimLink = link
        }
        weightAnimLink?.isPaused = false
    }

    /// 某条目在时刻 t 的 wght 插值（clamp 到 [from, to] 区间）
    private func weightAnimValue(_ s: WeightAnimState, at t: CFTimeInterval) -> Double {
        let p = min(1, max(0, (t - s.start) / weightAnimDuration))
        return s.from + (s.to - s.from) * p
    }

    /// 字重动画帧回调：逐条目逐帧改 label.font（wght = 插值），全部到位后停
    @objc private func onWeightAnimTick(_ link: CADisplayLink) {
        // Inter 中途关闭：清表停驱动，字体由 applyFontPolicy 归位
        guard interFontEnabled else {
            weightAnims.removeAll()
            link.isPaused = true
            return
        }
        let now = link.timestamp
        for (key, s) in weightAnims {
            guard let label = s.label else {
                weightAnims[key] = nil
                continue
            }
            let w = weightAnimValue(s, at: now)
            label.font = titleWeightFont(size: label.font?.pointSize ?? 13, wght: w)
            if now - s.start >= weightAnimDuration { weightAnims[key] = nil }
        }
        if weightAnims.isEmpty { link.isPaused = true }
    }

    /// 按当前字体开关取标题字体（动画用：任意 wght 插值；字号取 label 当前值——
    /// 两列压缩版式标题 11pt，沿用 13pt 会在 hover 动画时把字号顶回大号）
    private func titleWeightFont(size: CGFloat, wght: Double) -> NSFont {
        if interFontEnabled { return InterFontProvider.font(size: size, wght: wght) }
        return .systemFont(ofSize: size, weight: .regular)
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

        // 渐变开关状态同步（VC 通过 onPanelGradientChanged 即时刷新遮罩绘制）
        let gradientChanged = s.panelGradientEnabled != panelGradientEnabled
        panelGradientEnabled = s.panelGradientEnabled
        gradientSwitch.state = s.panelGradientEnabled ? .on : .off
        if gradientChanged {
            usageHistoryController?.panelGradientEnabled = panelGradientEnabled
            onPanelGradientChanged?()
        }
        // Mono 字体开关状态同步：变化时对已注册 label 就地切换字体（不重建卡片）
        let monoChanged = s.monoFontEnabled != monoFontEnabled
        monoFontEnabled = s.monoFontEnabled
        monoSwitch.state = s.monoFontEnabled ? .on : .off
        if monoChanged {
            applyFontPolicy()
            // 用量子弹窗（图表）跟随同一开关：文本和数值切换 Mono 风格
            usageHistoryController?.monoFontEnabled = monoFontEnabled
        }
        // Inter 字体开关状态同步：优先级 Mono 风格 > Inter，Mono 开启时本开关不生效
        let interChanged = s.interFontEnabled != interFontEnabled
        interFontEnabled = s.interFontEnabled
        interSwitch.state = s.interFontEnabled ? .on : .off
        if interChanged {
            applyFontPolicy()
            usageHistoryController?.interFontEnabled = interFontEnabled
        }
        valueScrollPreviewEnabled = s.valueScrollPreviewEnabled
        valuePreviewSwitch.state = s.valueScrollPreviewEnabled ? .on : .off
        // 预览定时器状态与配置保持一致（幂等：无变化不动）
        setValueScrollPreview(s.valueScrollPreviewEnabled)
        offlineBanner.isHidden = !s.offline

        // 行序跟随平台卡片顺序（拖拽排序持久化于 platformOrder）
        let orderIndex = Dictionary(uniqueKeysWithValues: platformOrder.enumerated().map { ($1, $0) })
        let sortedRows = s.usageRows.sorted {
            (orderIndex[$0.platform] ?? Int.max) < (orderIndex[$1.platform] ?? Int.max)
        }
        if sortedRows != renderedUsageRows {
            computeUsageColumnLayout(sortedRows)
            dismissUsageHistoryPopover()
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
                    BalancePlatform.zcode.rawValue,
                    BalancePlatform.codex.rawValue,
                    BalancePlatform.trae.rawValue,
                    BalancePlatform.workBuddy.rawValue] {
            guard let view = platformCards[pid] else { continue }
            let userWantsShow = s.panelCardVisible[pid] ?? true
            let shouldHide: Bool
            if pid == BalancePlatform.deepSeek.rawValue {
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

        // 刷新中时底部显示「刷新中…」并保持脉冲，刷新完成后恢复更新时间；
        // 有服务获取失败时追加标记，让「旧数据」可被识别（失败时间即本轮更新时间）
        updatedLabel.stringValue = isRefreshing ? "刷新中…"
            : (s.updatedAt.isEmpty ? "尚未更新"
               : "更新于 \(s.updatedAt)" + (s.failedText.map { " · \($0)" } ?? ""))

        // ── 设置/操作状态（代码设置 state 不会触发 action，安全）──
        let autoOn = s.traeAutoCheckin || s.wbAutoCheckin
        autoCheckinSwitch.state = autoOn ? .on : .off
        // sub 显示统一签到时间（取 TRAE / WB 最近一次签到的最晚时间，格式 M-d HH:mm）
        autoCheckinSub.stringValue = s.lastCheckinTime ?? ""
        autoCheckinSub.isHidden = autoCheckinSub.stringValue.isEmpty

        wbAddBtn.setTitle(s.wbOauthInProgress ? "取消添加" : "添加账号")
        // 进行中反馈：签到磁贴背景脉冲 + 禁点；TRAE 采集对齐 WB 的文案切换 + 同款脉冲
        checkinBtn.setInProgress(s.checkinInProgress)
        traeAddBtn.setTitle(s.traeCollectInProgress ? "采集中…" : "添加账号")
        traeAddBtn.setInProgress(s.traeCollectInProgress)

        switch s.refreshIntervalSeconds {
        case 60:
            intervalSegment.selectedSegment = 0
            monoSegment.selectedSegment = 0
        case 180:
            intervalSegment.selectedSegment = 1
            monoSegment.selectedSegment = 1
        default:
            intervalSegment.selectedSegment = 2
            monoSegment.selectedSegment = 2
        }

        // Mono 模式切换设置开关外观（字符开关 [×]/[▪] ↔ 原生 NSSwitch）
        applySwitchVisuals(animated: monoChanged)
        if contentSizeChanged { onContentChanged?() }
    }

    // MARK: - 首开阶梯入场（UIUX-OPTIMIZATION.md §5）

    /// 进程级一次性：只有本进程第一次面板展示编排入场，之后所有开面板零动画
    ///（菜单栏面板是高频动作，首帧低频时刻才值得编排）
    private static var didStaggerReveal = false

    func staggerRevealBalanceGroupsIfNeeded() {
        guard !Self.didStaggerReveal else { return }
        Self.didStaggerReveal = true
        let groups = platformOrder.compactMap { platformCards[$0] }.filter { !$0.isHidden }
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

    // MARK: - 多号卡片通用实现（WB / TRAE / ZCode / Codex）

    /// 重建多号卡片（账号列表变化时调用）：
    /// 当前账号全尺寸 icon + 点阵 + 签到/到期信息行；非当前账号小卡片（仅 icon 标题 + 额度）。
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
        for ac in accounts {
            let valueView = RollingNumberView()   // 初始 "—" 占位（init 内置）
            let isCurrent = ac.isCurrent
            let dots: UsageDots? = isCurrent ? UsageDots() : nil
            let checkinInfo = NSStackView()
            // 第二行信息：ZCode 当前账号为到期倒计时（timer 图标 + 文本，10pt systemGray 行高 12），
            // WB/TRAE 当前账号为签到信息行（空容器，由 updateCheckinInfo 填充）；非当前账号无第二行
            var expireLabel: NSTextField? = nil
            var expireIcon: NSImageView? = nil
            let info: NSStackView?
            if isCurrent && style.showsExpire {
                let label = NSTextField(labelWithString: "")
                registerFont(label, size: 10)
                label.textColor = .systemGray
                label.setContentHuggingPriority(.defaultLow, for: .vertical)
                label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                // 第二行图标可选：ZCode/Codex 为 timer 倒计时图标，DeepSeek 为纯文本副标题
                var rowViews: [NSView] = [label]
                if let symbol = style.expireIconSymbol {
                    let icon = NSImageView()
                    icon.image = symbolImage(symbol, size: 10)
                    icon.contentTintColor = .systemGray
                    icon.imageScaling = .scaleProportionallyUpOrDown
                    rowViews.insert(icon, at: 0)
                    expireIcon = icon
                }
                let stack = NSStackView(views: rowViews)
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 0
                stack.heightAnchor.constraint(equalToConstant: 12).isActive = true
                expireLabel = label
                info = stack
            } else if isCurrent && style.checkin {
                info = checkinInfo
            } else {
                info = nil
            }
            // 昵称 label：始终创建，alpha=0 保留占位（避免切换时标题位置跳动）；
            // 悬停卡片时淡入显示，离开淡出（已固化为默认行为，不再有开关控制）
            let nickLabel: NSTextField = {
                let nl = NSTextField(labelWithString: ac.nickname)
                nl.textColor = isCurrent ? .systemGray : Palette.cardForegroundDimmed
                nl.alphaValue = 0
                return nl
            }()
            // 非当前账号 icon 尺寸按平台由 CardStyle 指定（约大 icon 的 1/1.618，Codex/ZCode 再缩 5%），列宽不变
            let imgSize: CGFloat = isCurrent ? style.iconSize : style.secondaryIconSize
            let fgColor: NSColor = isCurrent ? Palette.cardForeground : Palette.cardForegroundDimmed
            // 上下内边距大小卡统一 4pt
            let cardPadTop: CGFloat = 4
            let cardPadBottom: CGFloat = 4
            let uid = ac.uid
            weak var cardRef: NSView?
            // 签到失败角标（当日失败时显示；无签到平台仅调试模式，apply 阶段控制显隐）
            let badge = makeFailureBadge()
            // 渐变 icon：未上菜单栏的账号由 apply 阶段开启垂直透明渐变（底部 20% → 顶部 100%）
            let fadeIcon = MenuBarFadeIconView()
            // 标题 label 引用：供 hover 字重动画逐帧驱动（weak 在卡片重建后自动失效）
            weak var capturedTitle: NSTextField?
            let card = addCard(rows: [
                balanceContentRow(icon: style.icon, name: style.name, valueView: valueView,
                                  info: info, dots: dots, iconSize: style.iconSize, imageSize: imgSize,
                                  monoSize: isCurrent ? style.monoIconSize : style.monoSecondaryIconSize,
                                  iconTopAligned: !isCurrent, iconTint: fgColor, nickLabel: nickLabel,
                                  titleWeight: .medium, valueWeight: .semibold,
                                  textColor: fgColor, failureBadge: badge,
                                  premadeIconView: fadeIcon,
                                  titleLabelRef: { capturedTitle = $0 })
            ], to: container, onClick: {
                if isCurrent || onSwitch == nil {
                    onCurrentClick?()
                } else {
                    // 立即给被点击卡片「切换中」视觉反馈：透明度脉冲（1.0 ↔ 0.4，0.5s 往复）
                    // 只用单一 CABasicAnimation，避免与 NSAnimationContext.alphaValue 冲突导致周期错乱
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
                    onSwitch?(uid)
                }
            }, onRightClick: { [weak self] event in
                self?.onRightClickCard?(style.menuBarIdPrefix + uid, event)
            }, onDragStarted: isCurrent ? { [weak self] point in
                self?.beginPlatformDrag(style.platformID, locationInWindow: point)
            } : nil, onDragChanged: isCurrent ? { [weak self] point in
                self?.updatePlatformDrag(style.platformID, locationInWindow: point)
            } : nil, onDragEnded: isCurrent ? { [weak self] in
                self?.endPlatformDrag()
            } : nil, topPadding: cardPadTop, bottomPadding: cardPadBottom, cardBackground: nil)
            cardRef = card
            // 弱化非当前账号（已固化默认行为）：整卡降透明，悬停复亮
            if !isCurrent {
                card.alphaValue = Self.subCardDimAlpha
            }
            // 悬停卡片时昵称淡入、离开淡出（已固化为默认行为）；
            // 非当前账号卡片同时复亮/回暗（悬停复亮保持「可点击切换账号」的可交互暗示），
            // 内容前景同步提亮：文字/图标由 dimmed 升至主卡前景色（hover 提亮后模型色已是
            // Palette.cardForeground，匹配两种色态保证可往返）
            if let hc = card as? HoverCard {
                hc.onHover = { [weak self, weak card, weak label = nickLabel, weak title = capturedTitle] showing in
                    // 标题字重动画（仅 Inter）：hover 进入 500→800，离开 800→500
                    //（标题基准统一 500 medium，峰值 800）
                    if self?.interFontEnabled == true, let title {
                        self?.animateTitleWeight(label: title, to: showing ? 800 : 500, light: 500)
                    }
                    if let label {
                        // 昵称（含签到状态附件）淡入与卡片背景/边框统一时长与曲线；
                        // 子卡昵称不进全亮提亮（scan 排除）——昵称是次级信息，hover 时
                        // 只从 dimmed 升到 systemGray（与主卡昵称一致），不到 #E9E9E9
                        NSAnimationContext.runAnimationGroup { ctx in
                            ctx.duration = Motion.hover
                            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                            label.animator().alphaValue = showing ? 1 : 0
                            if !isCurrent {
                                label.animator().textColor = showing ? .systemGray : Palette.cardForegroundDimmed
                            }
                        }
                    }
                    guard let card, !isCurrent else { return }
                    let target: CGFloat = showing ? 1 : Self.subCardDimAlpha
                    let fg: NSColor = showing ? Palette.cardForeground : Palette.cardForegroundDimmed
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = Motion.hover
                        card.animator().alphaValue = target
                        func scan(_ v: NSView) {
                            if let tf = v as? NSTextField, tf !== label,
                               tf.textColor == Palette.cardForegroundDimmed || tf.textColor == Palette.cardForeground {
                                tf.animator().textColor = fg
                            } else if let iv = v as? NSImageView,
                                      iv.contentTintColor == Palette.cardForegroundDimmed || iv.contentTintColor == Palette.cardForeground {
                                iv.animator().contentTintColor = fg
                            }
                            for sub in v.subviews { scan(sub) }
                        }
                        scan(card)
                    }
                }
            }
            // 当前账号卡片等高于 DeepSeek；非当前账号卡片自适应内容高度（更小）
            if isCurrent, let ds = dsCardRef {
                card.heightAnchor.constraint(equalTo: ds.heightAnchor).isActive = true
            }
            // 非当前账号无 dots/checkinInfo（未加入视图层级），用占位保持 entry 结构一致
            entries.append(CardEntry(uid: ac.uid, valueView: valueView,
                                     dots: dots ?? UsageDots(), checkinInfo: checkinInfo,
                                     nickLabel: nickLabel, infoLabel: expireLabel,
                                     expireIcon: expireIcon, badgeView: badge,
                                     iconView: fadeIcon))
        }
        // ⚠️ 必须与 update() 的检测口径一致（uid + isCurrent ✓ 后缀）：
        // 旧实现只存裸 uid，导致每轮刷新都误判「uid 变化」→ 全量重建卡片，
        // 就地更新路径（数字滚动动效等）永远走不到
        uids = accounts.map { $0.uid + ($0.isCurrent ? "✓" : "") }
        applyAccountCardData(accounts, entries: &entries, style: style)
    }

    /// 昵称 + 行内签到状态附件（TRAE/WB）：统一 checkmark.seal 图标、在字体行框内
    /// 垂直居中（与菜单栏平台图标同款公式）；颜色按状态：绿=已签 / 红=失败 / 橙=风控，未签不追加
    private static func nickString(_ ac: AccountCardSnapshot, label: NSTextField) -> NSAttributedString {
        let font = label.font ?? .systemFont(ofSize: 10)
        let color = label.textColor ?? .systemGray
        let mas = NSMutableAttributedString(string: ac.nickname,
                                            attributes: [.font: font, .foregroundColor: color])
        // 图标统一用「已签到」的 checkmark.seal，仅用颜色区分状态：
        // 绿=已签 / 红=失败 / 橙=风控；未签到不追加
        let tint: NSColor? = ac.checkinDone ? .systemGreen
            : (ac.checkinRisk ? NSColor(calibratedRed: 1, green: 0.78, blue: 0, alpha: 1)
               : (ac.checkinFailed ? .systemRed : nil))
        if let tint,
           let base = NSImage(systemSymbolName: "checkmark.seal", accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) {
            // NSImage 无 withTintColor：源图 sourceAtop 叠色（保留 alpha 形状）
            let colored = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                tint.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            let att = NSTextAttachment()
            att.image = colored
            // 垂直定位与菜单栏平台图标同一公式：在字体行框内垂直居中
            //（ascender+descender = 行高；size=图标高），全 app 口径统一
            let size: CGFloat = 10
            att.bounds = NSRect(x: 0, y: (font.ascender + font.descender - size) / 2,
                                width: size, height: size)
            mas.append(NSAttributedString(string: "\u{2009}"))
            mas.append(NSAttributedString(attachment: att))
        }
        return mas
    }

    /// 余额数字滚动动效（Number Rolling）：面板打开期间余额更新时，数值从旧值
    /// 平滑滚动到新值（ease-out，时长 Motion.roll）。中间帧沿用目标值的小数位与
    /// 千分位格式，逐帧交给 RollingNumberView——数字位车轮平滑追赶目标数字
    ///（垂直滚动），货币符号/千分位/小数点等静态位随文本就地更新。
    /// 覆盖格式：可选前缀（¥/$）+ 千分位数字（可选小数）+ 可选后缀（%）。
    /// 驱动：CADisplayLink 每显示帧回调，步进用真实时间戳 dt —— 速率自动跟随
    /// 屏幕刷新率（ProMotion 120Hz 跑 120、普通屏 60，不空转、无漂移）。
    /// 120Hz 可行的前提：DigitWheelView 字形已缓存（滚动 draw 无分配），
    /// 单帧成本足够低；若后续再卡，回落 60Hz 即可。
    private final class NumberRollAnimator {
        private weak var view: RollingNumberView?
        private var timer: Timer?
        private var lastTS: CFTimeInterval = 0
        private var prefix = ""
        private var suffix = ""
        private var decimals = 0
        private var start: Double = 0
        private var end: Double = 0
        private var duration: CFTimeInterval = Motion.roll
        private var elapsed: CFTimeInterval = 0

        /// 千分位格式化器（复用实例，每帧按 decimals 配置；仅主线程调用）
        private static let formatter: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.groupingSeparator = ","
            f.decimalSeparator = "."
            f.usesGroupingSeparator = true
            return f
        }()

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

        /// 启动（或接续）滚动：from/to 为旧/新余额文本。解析失败 → 直接落值不滚动。
        func start(view: RollingNumberView, from oldValue: String, to newValue: String,
                   duration: CFTimeInterval) {
            guard let old = Self.parse(oldValue), let new = Self.parse(newValue) else {
                stop()
                view.setText(newValue, animated: false)
                return
            }
            stop()
            self.view = view
            self.duration = duration
            prefix = new.prefix
            suffix = new.suffix
            decimals = new.decimals
            end = new.value
            // 起点取旧值；若上一轮滚动未完成被新数据打断，从当前屏显值续滚避免跳变
            var from = old.value
            if let showing = Self.parse(view.currentText) {
                from = showing.value
            }
            start = from
            elapsed = 0
            // 60Hz 计数（z 定稿基线：实测流畅稳定）。高于此的频率（120/屏刷新对齐）
            // 均实测卡顿，不再调整。
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            // .common：滚动期间面板处于 event tracking（如菜单/popover 交互）也不停帧
            RunLoop.main.add(t, forMode: .common)
            timer = t
            lastTS = 0
            Logger.log(.layout, "[Roll] start uid≈\(String(newValue.suffix(8))) \(start)→\(end) dur=\(duration)")
        }

        private func tick() {
            let t0 = CFAbsoluteTimeGetCurrent()
            defer {
                Self.perfFrames += 1
                if Self.perfFrames <= 90 {
                    Self.perfCosts.append(CFAbsoluteTimeGetCurrent() - t0)
                    if Self.perfFrames == 90 {
                        let avg = Self.perfCosts.reduce(0, +) / 90
                        let mx = Self.perfCosts.max() ?? 0
                        Logger.log(.layout, String(format: "[RollPerf] animatorTick 90帧: 回调avg=%.2fms max=%.2fms", avg * 1000, mx * 1000))
                    }
                }
            }
            guard let view else { stop(); return }
            // ⚠️ 面板不可见（popover 关闭/隐藏，view 脱离 window）时**跳过本帧**——
            // 此前这里直接 stop + 落终值，导致预览滚动秒瞬跳（无动效根因）；
            // 跳过则动画冻结于隐藏期，面板打开后从当前进度续滚。
            guard view.window != nil else {
                if Self.windowNilLogs < 5 {
                    Self.windowNilLogs += 1
                    Logger.log(.layout, "[RollDbg] skip: window nil (面板不可见时滚动挂起)")
                }
                return
            }
            // ⚠️ 墙钟计时（非 l.timestamp）：低刷新率屏上 display link 同帧重复回调
            // 时间戳不变，用 timestamp 累计 elapsed 会导致动画拖不动（卡顿根因）。
            let now = CACurrentMediaTime()
            if lastTS == 0 { lastTS = now }
            let dt = max(0, now - lastTS)
            lastTS = now
            elapsed += dt
            let p = min(1, elapsed / duration)
            // TODO(性能诊断): 进度里程碑（首个滚动）——验证滚动在可见时真实推进
            if Self.milestone < 3 {
                let thresholds: [Double] = [0.1, 0.5, 0.9]
                if p >= thresholds[Self.milestone] {
                    Self.milestone += 1
                    Logger.log(.layout, String(format: "[RollDbg] 里程碑 p=%.2f text='%@'", p, prefix + formatted(end) + suffix))
                }
            }
            // ease-out cubic：起手快、收尾缓，余额「落到新值」的观感
            let eased = 1 - pow(1 - p, 3)
            if p >= 1 {
                stop()
                view.setText(prefix + formatted(end) + suffix, animated: false)
                return
            }
            let v = start + (end - start) * eased
            // TODO(性能诊断): 前 10 帧逐步文本（判断动画是否产出中间帧/是否触发重建）
            if Self.logCount < 10 {
                Self.logCount += 1
                Logger.log(.layout, "[RollDbg] cb#\(Self.logCount) p=\(String(format: "%.3f", p)) text='\(prefix + formatted(v) + suffix)'")
            }
            view.setText(prefix + formatted(v) + suffix, animated: true)
        }

        private func formatted(_ v: Double) -> String {
            // 快路径：整数千分位 + 固定小数位（NumberFormatter 每帧调用开销大，
            // 是滚动动画的主线程大头之一；见 Apple「keep display link callbacks short」）
            let scale = pow(10.0, Double(decimals))
            var scaled = Int64((v * scale).rounded())
            var sign = ""
            if scaled < 0 { sign = "-"; scaled = -scaled }
            let div = Int64(scale)
            let intPart = scaled / div
            var digits = String(intPart)
            if digits.count > 3 {
                var out = ""
                var c = 0
                for ch in digits.reversed() {
                    out.insert(ch, at: out.startIndex)
                    c += 1
                    if c % 3 == 0 && c < digits.count { out.insert(",", at: out.startIndex) }
                }
                digits = out
            }
            var result = sign + digits
            if decimals > 0 {
                let frac = scaled % div
                result += "." + String(format: "%0\(decimals)lld", frac)
            }
            return result
        }

        private func stop() {
            timer?.invalidate()
            timer = nil
            lastTS = 0
        }

        deinit { stop() }

        // TODO(性能诊断): 首批滚动 90 帧的耗时统计（定位卡顿来源，确认后移除）
        private static var perfFrames = 0
        private static var perfCosts: [CFTimeInterval] = []
        private static var logCount = 0
        private static var windowNilLogs = 0
        private static var milestone = 0
    }

    /// 应用多号卡片数据：余额、昵称、点阵、签到信息、到期倒计时（重建后或就地刷新时调用）
    private func applyAccountCardData(_ accounts: [AccountCardSnapshot],
                                      entries: inout [CardEntry],
                                      style: CardStyle) {
        for (i, ac) in accounts.enumerated() where i < entries.count {
            let e = entries[i]
            // 余额数值：就地更新且数值变化 → 数字滚动动效（Number Rolling，逐位车轮垂直滚动）。
            // 首次赋值（重建后 lastValue 为空）/ 面板不可见 / 减弱动态 / 非数值（—）→ 直接落值。
            let oldValue = entries[i].lastValue
            let newValue = ac.value ?? "—"
            entries[i].lastValue = newValue
            if oldValue != newValue {
                if valueScrollPreviewEnabled {
                    // 数值滚动预览模式：显示由预览定时器接管（周期随机值 + 2s 滚动），
                    // 这里只维护真实 lastValue，供关闭预览时恢复。roller 保留（预览滚动用）。
                } else {
                    let rollable = !oldValue.isEmpty && oldValue != "—" && newValue != "—"
                        && NumberRollAnimator.parse(oldValue) != nil
                        && NumberRollAnimator.parse(newValue) != nil
                    Logger.log(.layout, "[Roll] \(style.platformID) uid=\(ac.uid.suffix(6)) old=\(oldValue) new=\(newValue) win=\(e.valueView.window != nil) rollable=\(rollable) motion=\(!shouldReduceMotion)")
                    if rollable, !shouldReduceMotion, e.valueView.window != nil {
                        if entries[i].roller == nil { entries[i].roller = NumberRollAnimator() }
                        entries[i].roller?.start(view: e.valueView, from: oldValue, to: newValue,
                                                 duration: Motion.roll)
                    } else {
                        entries[i].roller = nil   // 打断未完成的滚动，直接落终值
                        e.valueView.setText(newValue, animated: false)
                    }
                }
            }
            // 就地更新昵称显示（用户在平台内改昵称后无需 rebuild 卡片）。
            // TRAE/WB：昵称尾部内联签到状态 icon（NSTextAttachment，与文字同行同基线、
            // hover 随昵称整体淡入——附件是文本字形，天然同容器；绿=已签/红=失败/橙=风控
            if style.checkin {
                let key = "\(ac.nickname)|\(ac.checkinDone)|\(ac.checkinFailed)|\(ac.checkinRisk)"
                if e.nickKey != key {
                    entries[i].nickKey = key
                    e.nickLabel.attributedStringValue = Self.nickString(ac, label: e.nickLabel)
                }
            } else {
                e.nickLabel.stringValue = ac.nickname
            }
            // 当日签到失败/风控或调试模式 → icon 右上角显示角标（ZCode 无签到，仅调试模式）；
            // 风控（checkinRisk）角标橙黄色（偏黄），普通失败保持系统红色
            e.badgeView.isHidden = !ac.checkinFailed
            if let badgeImg = e.badgeView as? NSImageView {
                badgeImg.contentTintColor = ac.checkinRisk ? NSColor(calibratedRed: 1, green: 0.78, blue: 0, alpha: 1) : .systemRed
            }
            // 到期倒计时（无值时清空文本，占位保持行高稳定）；套餐已到期 → 文本与图标转红警告
            e.infoLabel?.stringValue = ac.expireText ?? ""
            let expireColor: NSColor = ac.expired ? .systemRed : .systemGray
            e.infoLabel?.textColor = expireColor
            e.expireIcon?.contentTintColor = expireColor
            // 未上菜单栏账号的 icon 叠加垂直透明渐变（底部 20% → 顶部 100% 可见）；
            // 右键「在菜单栏显示」切换后 syncPanel 就地开/关渐变，无需重建卡片
            e.iconView.usesMenuBarFade = !ac.inMenuBar
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
            // DeepSeek 未配置日常额度时隐藏点阵（多号平台恒 false 不受影响）
            e.dots.isHidden = ac.hideDots
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

    /// 刷新动效：开始 → 「更新于」区域脉冲显示「刷新中…」；结束 → 停止动画并立即恢复真实时间文本。
    /// 设计：刷新收尾快照去重（same=true）时，后续 `Panel.update` 会跳过，footer 就会卡在"刷新中…"直到下次快照变化。
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
    /// 字符化控件（MonoCharSwitch / MonoSegmentedControl）切换模糊→清晰过渡的计时器
    var charBlurTimer: Timer?

    // MARK: - 控件回调（转发给 AppDelegate 接线）

    @objc func openCockpitTapped() { onOpenCockpit?() }
    @objc func autoCheckinToggled() { onToggleAutoCheckin?() }
    @objc func addWbAccountTapped() { onAddWbAccount?() }
    @objc func addZcodeAccountTapped() { onAddZcodeAccount?() }
    @objc func addCodexAccountTapped() { onAddCodexAccount?() }
    @objc func addTraeAccountTapped() { onCollectTraeAccount?() }
    @objc func panelGradientToggled() { onTogglePanelGradient?() }
    @objc func monoFontToggled() { onToggleMonoFont?() }
    @objc func interFontToggled() { onToggleInterFont?() }
    @objc func valueScrollPreviewToggled() { onToggleValueScrollPreview?() }

    // MARK: - 数值滚动预览（保留设置卡片原「调试」开关，功能替换为演示滚动动画）

    private var valuePreviewTimer: Timer?

    /// 预览滚动动画器（key = 视图标识；CardEntry 是结构体，不能原地改 roller 字段）
    private var previewRollers: [ObjectIdentifier: NumberRollAnimator] = [:]

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
            previewRollers = [:]   // 释放动画器 → 定时器停止
            for e in allCardEntries() {
                e.valueView.setText(e.lastValue, animated: false)   // 恢复真实数值
            }
        }
    }

    /// 各平台卡片条目汇总（预览遍历用；值对象为类引用，结构体拷贝共享同一视图）
    private func allCardEntries() -> [CardEntry] {
        dsCardEntries + zcodeCardEntries + codexCardEntries + traeCardEntries + wbCardEntries
    }

    /// 预览节拍：按每张卡片真实数值的格式（前缀/后缀/小数位/整数位数）生成
    /// 随机新值，结构一致 → 数字位逐位滚动。
    /// 与真实刷新同路径：走 NumberRollAnimator（2.0s ease-out 计数），
    /// 预览节奏与真实滚动完全一致（直接 setText 只有 ~0.3s 车轮追位，观感偏快）。
    /// 当前一轮未滚完被新预览值打断时，动画器从屏显值续滚，天然衔接。
    private func previewTick() {
        guard valuePreviewTimer != nil || valueScrollPreviewEnabled else { return }
        // 卡片重建后清理已失效视图的动画器
        let live = Set(allCardEntries().map { ObjectIdentifier($0.valueView) })
        previewRollers = previewRollers.filter { live.contains($0.key) }
        for e in allCardEntries() {
            guard let parsed = NumberRollAnimator.parse(e.lastValue) else { continue }
            let intDigits = max(Self.countIntegerDigits(parsed.value), 1)
            let magnitude = pow(10.0, Double(intDigits))
            let scale = pow(10.0, Double(parsed.decimals))
            // [10^(n-1), 10^n) 同整数位数的随机新值（与真实值位数一致 → 结构不变）
            let v = (Double.random(in: (magnitude / 10)...magnitude) * scale).rounded() / scale
            let text = parsed.prefix + Self.previewFormat(v, decimals: parsed.decimals) + parsed.suffix
            if e.valueView.window != nil {
                let key = ObjectIdentifier(e.valueView)
                if previewRollers[key] == nil { previewRollers[key] = NumberRollAnimator() }
                previewRollers[key]?.start(view: e.valueView, from: e.valueView.currentText,
                                           to: text, duration: Motion.roll)
            }
            // 面板不可见：不落值不启动（动画挂起，打开后由下个节拍续播）
        }
    }

    /// 整数位数（如 0.08 → 1 位；12.34 → 2 位；876.5 → 3 位）
    private static func countIntegerDigits(_ v: Double) -> Int {
        let a = abs(v)
        guard a >= 1 else { return 1 }
        return Int(floor(log10(a))) + 1
    }

    /// 千分位格式化（与 NumberRollAnimator.formatted 同口径）
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
    @objc func quitTapped() { onQuit?() }
    @objc func intervalChanged() {
        // Mono 模式下只有字符段可见，读可见控件（避免依赖隐藏控件的旧状态）
        let selected = intervalSegment.isHidden ? monoSegment.selectedSegment : intervalSegment.selectedSegment
        let seconds: Int
        switch selected {
        case 0: seconds = 60
        case 1: seconds = 180
        default: seconds = 300
        }
        onSetInterval?(seconds)
    }
    @objc func manualRefreshTapped() { onManualRefresh?() }
}

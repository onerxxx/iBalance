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
    var ds: String?                 // DeepSeek 余额（已格式化，含货币符号）
    var dsUsedRatio: Double = 0     // DeepSeek 已用占比（0~1），基于常用充值额度计算；0=未设置不显示点阵
    var dsPulsing: Bool = false     // DeepSeek 余额被消耗（usedRatio 上升）→ 点阵脉冲
    var dsInfoText: String?         // DeepSeek 副标题文字（nil 显示默认提示）
    /// 面板余额卡片可见性：key = 平台 ID（"ds" / "zcode" / "codex" / "trae" / "wb"），
    /// value=true 显示、false 隐藏；未记录的平台默认 true。
    var panelCardVisible: [String: Bool] = [:]
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
    /// 今日签到统计文案（如 "8-16 3成功 1失败"，手动签到计入；空 = 今天尚未产生任何签到结果）
    var lastCheckinTime: String?
    var wbOauthInProgress = false   // 添加账号进行中 → 按钮变「取消添加…」
    /// TRAE 采集进行中 → 按钮变「采集中…」+ 脉冲禁点（对齐 WB 反馈）
    var traeCollectInProgress = false
    /// 手动签到进行中 → 签到磁贴脉冲禁点
    var checkinInProgress = false
    var refreshIntervalSeconds: Int = 300
    var hideWbNickname = true
    /// 面板背景渐变开关（同步自配置，VC 据此决定遮罩渐变/单色）
    var panelGradientEnabled = true
    /// Mono 字体开关（同步自配置；余额卡片与用量列表 DepartureMono ↔ 系统字体）
    var monoFontEnabled = false
}

/// 日/周用量行快照：icon + 平台名 + 已格式化的今日/本周用量文本
struct UsageRowSnapshot: Equatable {
    var platform: String
    var icon: String
    var name: String
    var todayText: String
    var weekText: String
}

/// 多号余额卡片统一快照（WorkBuddy / TRAE / ZCode 共用，复用同一套卡片渲染逻辑）。
/// 无签到平台（ZCode / Codex）的 checkin 字段保持默认；expireText 为当前账号重置/到期副标题。
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
    var checkinFailed: Bool = false // 签到失败（按 failed_date==today 口径）
    var streak: Int = 0             // 连续签到天数
    var reward: Int = 0             // 最近一次签到积分奖励
}

/// 配色 token：集中管理所有自定义颜色，避免硬编码散落各处
private enum Palette {
    /// 卡片前景色 #DDDDDD（余额卡片 icon/标题/数值、三大分组标题统一使用）
    static let cardForeground = NSColor(calibratedRed: 0xE9/255.0, green: 0xE9/255.0, blue: 0xE9/255.0, alpha: 1)
    /// 非当前账号前景色：石墨灰（不透明）
    static let cardForegroundDimmed = NSColor(calibratedWhite: 0.5, alpha: 1.0)
    /// 卡片底色：完全透明（露出容器毛玻璃）
    static let cardBackground = NSColor.clear
    /// 卡片 hover 提亮色 #333333 @ 30%
    static let cardBackgroundHover = NSColor(calibratedWhite: 51.0 / 255.0, alpha: 0.3)
    /// 容器玻璃遮罩色（近黑半透明，加深毛玻璃底色）
    static let containerTint = NSColor(calibratedWhite: 0.02, alpha: 0.30)
    /// 容器玻璃渐变底色（中灰半透明）：与 containerTint 组成纵向渐变，顶部近黑 → 底部中灰
    static let containerTintBottom = NSColor(calibratedWhite: 0.25, alpha: 0.30)
    /// 卡片圆角 10pt（对齐 macOS Big Sur+ NSPopover 窗口系统圆角）
    static let cardCornerRadius: CGFloat = 10
    /// 卡片边框色/分割线色（暗主题：浅灰半透明，1px 描边，统一白@10%）
    static let cardBorderColor = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    /// 卡片边框宽度 1pt
    static let cardBorderWidth: CGFloat = 1
}

// 旧名兼容（逐步迁移到 Palette）
private let kBalanceForeground = Palette.cardForeground
private let kCardBackground = Palette.cardBackground
private let kCardBackgroundHover = Palette.cardBackgroundHover
/// 用量行 hover 背景色（#8aa78880：青灰绿，50% 半透明）
private let kUsageHoverBackground = NSColor(srgbRed: 0x8a / 255.0, green: 0xa7 / 255.0,
                                            blue: 0x88 / 255.0, alpha: 0.5)

/// DepartureMono（像素风等宽字体，无中文字形）：
/// 拉丁字符用 DepartureMono，缺字（中文/特殊符号）通过 cascade 级联自动回退系统字体。
/// 字体文件随 App 打包在 Resources/，首次使用时按进程注册（幂等）。
enum MonoFontProvider {
    /// PostScript 名（实测字体内部命名，NSFont(name:) 需用 PostScript 名）
    private static let postScriptName = "DepartureMono-Regular"
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        guard let url = Bundle.main.url(forResource: "DepartureMono-Regular", withExtension: "otf")
            ?? Bundle.main.url(forResource: "DepartureMono-Regular", withExtension: "ttf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// DepartureMono + 系统字体级联：weight 仅作用于中文回退部分
    /// （DepartureMono 只有 Regular 一档，拉丁字符统一常规字重）
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

/// 通用 layer keypath 过渡（borderWidth / shadowOpacity 等），0.22s easeInEaseOut
private func animateLayerKey(_ layer: CALayer?, keyPath: String, to value: Any?, duration: Double = 0.22) {
    guard let l = layer else { return }
    let anim = CABasicAnimation(keyPath: keyPath)
    anim.duration = duration
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    anim.fromValue = l.value(forKeyPath: keyPath)
    anim.toValue = value
    l.add(anim, forKey: keyPath + "Transition")
    l.setValue(value, forKeyPath: keyPath)
}

/// 视觉缩放开关：在 .mini 基础上通过 affineTransform 缩至 0.81 倍，使整体更紧凑。
/// AppKit layer-backed 视图经 Auto Layout 同步会把 anchorPoint 重置为 (0,0)，
/// 直接 setAffineTransform 会从左下角缩放导致偏移；这里在 layout() / viewDidMoveToWindow()
/// 里恢复中心锚点 + 补偿 position + 应用缩放，保持开关视觉居中、点击区域不变（frame 不缩小）。
final class MiniSwitch: NSSwitch {
    private let visualScale: CGFloat = 0.81

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlSize = .mini
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTransform()
    }

    override func layout() {
        super.layout()
        applyTransform()
        // AppKit 可能在 layout 同步后重置 layer transform，下一帧再设一次
        DispatchQueue.main.async { [weak self] in
            self?.applyTransform()
        }
    }

    private func applyTransform() {
        guard let l = layer, l.bounds.width > 0 else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        let target = CGAffineTransform(scaleX: visualScale, y: visualScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if l.anchorPoint != center {
            var p = l.position
            p.x += l.bounds.width * (center.x - l.anchorPoint.x)
            p.y += l.bounds.height * (center.y - l.anchorPoint.y)
            l.anchorPoint = center
            l.position = p
        }
        if l.affineTransform() != target {
            l.setAffineTransform(target)
        }
        CATransaction.commit()
    }
}

/// 紧凑分段控件：纯使用 AppKit 原生 controlSize/font/segmentWidth 控制尺寸，
/// 不使用任何 layer transform（AppKit 复杂控件会在首次显示时重置 layer 属性导致缩放失效）。
/// 选中段高亮色固定为 #7F7F7F。
/// NSSegmentedControl 的自定义 cell：收窄每段标题的水平内边距。
/// 系统 .mini 分段控件每段内边距约 7pt/侧，「3分钟」@9pt 宽约 25pt，38pt 段下
/// 25 + 14 ≈ 39pt 仍会溢出被省略号截断。这里改由 cell 自绘标题：
/// 水平余量均分居中（约 6.5pt/侧，等价于收窄内边距），38pt 段即可稳定容纳。
final class CompactSegmentedCell: NSSegmentedCell {
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with view: NSView) {
        // 临时清空标题让 super 只画背景/选中 bezel（选中态由 isSelected(forSegment:)
        // 驱动，与标题内容无关），随后按收窄内边距自绘标题，避免双层文字。
        let originalLabel = self.label(forSegment: segment)
        setLabel("", forSegment: segment)
        super.drawSegment(segment, inFrame: frame, with: view)
        setLabel(originalLabel ?? "", forSegment: segment)
        guard let label = originalLabel, !label.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.controlTextColor,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        // 水平：段内余量均分居中；垂直：draw(in:) 实测不垂直居中（偏上约 3pt），
        // 需手动以 (midY - 文本高/2) 定位用 draw(at:)。
        let origin = NSPoint(x: frame.midX - size.width / 2,
                             y: frame.midY - size.height / 2)
        (label as NSString).draw(at: origin, withAttributes: attrs)
    }
}

final class MiniSegmentedControl: NSSegmentedControl {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlSize = .mini
        segmentStyle = .rounded
        appearance = NSAppearance(named: .darkAqua)
        // 选中段高亮色 = #666666（AppKit bezel 会提亮渐变，填暗一档补偿）
        selectedSegmentBezelColor = NSColor(calibratedRed: 0x66/255.0, green: 0x66/255.0, blue: 0x66/255.0, alpha: 1)
        // 监听系统颜色变化通知，在主题色切换时更新 bezel 颜色
        NotificationCenter.default.addObserver(self, selector: #selector(accentColorChanged),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func accentColorChanged() {
        selectedSegmentBezelColor = NSColor(calibratedRed: 0x66/255.0, green: 0x66/255.0, blue: 0x66/255.0, alpha: 1)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 首次进窗口时换成 CompactSegmentedCell（收窄内边距）。此刻 segment 已由
        // init(labels:...) 配置完毕，直接复制配置；target/action/segmentStyle 等状态
        // 在 NSControl/NSSegmentedControl 层，换 cell 不受影响。
        if !(cell is CompactSegmentedCell), let old = cell as? NSSegmentedCell {
            let compact = CompactSegmentedCell()
            compact.segmentCount = old.segmentCount
            compact.trackingMode = old.trackingMode
            compact.controlSize = .mini
            for i in 0..<old.segmentCount {
                compact.setLabel(old.label(forSegment: i) ?? "", forSegment: i)
            }
            // selectedSegment 状态存储在 cell 上，换 cell 会丢失（新 cell 默认 -1 无选中），
            // 首次打开会视觉上"没选中任何段"，必须显式迁移。
            compact.selectedSegment = old.selectedSegment
            cell = compact
        }
        let miniFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        font = miniFont
        cell?.font = miniFont
        for i in 0..<segmentCount {
            setWidth(38, forSegment: i)
        }
        needsLayout = true
    }
}

/// 面板滚动 hover 同步：内容滚动后 AppKit 不会补发 mouseEntered/mouseExited，
/// 面板控制器在滚动时遍历视图树，让所有可 hover 视图按当前光标位置重算状态。
protocol PanelScrollHoverSync: AnyObject {
    func syncHoverForCurrentPointer()
}

/// 设置卡片行容器：hover 时仅提亮文本颜色（secondaryLabel/tertiaryLabel → hoverTextColor），
/// switch/radio 等控件保持不变；无背景变化。光标变为 pointingHand 提示可点击。
final class HoverRowView: NSView, PanelScrollHoverSync {
    private var trackingArea: NSTrackingArea?
    /// 当前 hover 状态（滚动同步时用于判断是否需要切换）
    private var isMouseInside = false
    private var labels: [NSTextField] = []
    private var highlightedLabels: [NSTextField] = []
    var hoverTextColor: NSColor = .labelColor
    /// hover 时行背景色（nil = 不绘制背景，保持原文本/tint 提亮行为）
    var hoverBackgroundColor: NSColor? = nil
    /// 行背景圆角（hoverBackgroundColor 非 nil 时生效）
    var backgroundCornerRadius: CGFloat = 6
    /// hover 时是否对灰色文本/tint 做提亮（false = 仅背景变化，用于用量行等）
    var enablesTextBrightening: Bool = true
    /// 需要 hover 提亮的 tint 控件 setter：contentTintColor 为 systemGray 的 NSImageView / NSButton
    /// 跟随整行 hover 提亮为 labelColor，行为与下方选项小字（systemGray 文字）一致。
    /// 用闭包捕获具体类型，使 animator().contentTintColor 能正确解析（NSControl 父类不暴露该属性）。
    private var tintables: [(NSColor) -> Void] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    private func collectLabels() {
        labels = []
        tintables = []
        func scan(_ v: NSView) {
            if let tf = v as? NSTextField { labels.append(tf) }
            else if let iv = v as? NSImageView, iv.contentTintColor == NSColor.systemGray {
                tintables.append({ [weak iv] c in iv?.animator().contentTintColor = c })
            }
            else if let btn = v as? NSButton, btn.contentTintColor == NSColor.systemGray {
                tintables.append({ [weak btn] c in btn?.animator().contentTintColor = c })
            }
            for sub in v.subviews { scan(sub) }
        }
        scan(self)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        if let bg = hoverBackgroundColor {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            wantsLayer = true
            layer?.cornerRadius = backgroundCornerRadius
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = bg.cgColor
            CATransaction.commit()
        }
        guard enablesTextBrightening else { return }
        collectLabels()
        highlightedLabels = labels.filter {
            $0.textColor == NSColor.systemGray || $0.textColor == NSColor.tertiaryLabelColor
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for l in highlightedLabels { l.animator().textColor = self.hoverTextColor }
            for setter in tintables { setter(NSColor.labelColor) }
        }, completionHandler: nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        if hoverBackgroundColor != nil {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            layer?.backgroundColor = nil
            CATransaction.commit()
        }
        guard enablesTextBrightening else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for l in highlightedLabels { l.animator().textColor = NSColor.systemGray }
            for setter in tintables { setter(NSColor.systemGray) }
        }, completionHandler: nil)
        highlightedLabels.removeAll()
    }

    // MARK: - 面板滚动 hover 同步
    func syncHoverForCurrentPointer() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // visibleRect 已被滚动视口裁剪：滚出可视区的行不再参与 hover
        let inside = visibleRect.contains(p)
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }
}

/// 刷新时间行容器：点击整行（排除分段控件区域）触发刷新按钮，等价于点按钮（含旋转动画）。
/// hitTest 把分段控件放行给自身处理选择，其余区域（label/按钮/spacer/空白）拦截到 self，
/// mouseDown 转发 triggerButton.performClick → 触发 RefreshIconButton 的 sendAction（旋转 + 刷新）。
final class RefreshRow: NSStackView {
    /// 排除的控件：点击其区域不触发刷新，交给分段控件处理选择
    var segmentView: NSView?
    /// 触发目标：performClick 等价于点按钮
    var triggerButton: NSButton?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let candidate = super.hitTest(point) else { return nil }
        // 命中分段控件（或其子树）→ 放行，交给分段控件处理选择
        if let seg = segmentView, candidate === seg || candidate.isDescendant(of: seg) {
            return candidate
        }
        // 命中刷新按钮本身 → 交给按钮（保留原生高亮反馈）
        if let btn = triggerButton, candidate === btn || candidate.isDescendant(of: btn) {
            return candidate
        }
        // 其余区域（label/spacer/空白）→ 拦截到 self，mouseDown 时触发刷新
        return self
    }

    override func mouseDown(with event: NSEvent) {
        triggerButton?.performClick(nil)
    }
}

/// 无边框图标按钮：使用 macOS 原生 bezelStyle 实现 hover 时自动显示圆角背景，
/// 系统自动处理背景绘制，仅用 tracking area 管理图标颜色变化。
/// hover 时系统渲染浅色圆角背景（略大于图标），图标同步提亮为 labelColor。
final class HoverIconButton: NSButton, PanelScrollHoverSync {
    /// 按钮容器尺寸（正方形）
    static let buttonSize: CGFloat = 22
    private var trackingArea: NSTrackingArea?
    /// 当前 hover 状态（滚动同步时用于判断是否需要切换）
    private var isMouseInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 无边框按钮：hover 背景自绘（大圆角容器，替代系统 recessed 的小圆角底）
        isBordered = false
        setButtonType(.momentaryPushIn)         // 点击时有按下效果
        imagePosition = .imageOnly
        title = ""
        imageScaling = .scaleProportionallyDown
        contentTintColor = .systemGray
        wantsLayer = true
        layer?.cornerRadius = Self.buttonSize / 2  // 圆角拉满：22×22 容器 → 11pt 正圆
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        contentTintColor = .labelColor
        // hover 背景：极淡白底淡入（0.22s，同全项目过渡节奏）
        animateLayerKey(layer, keyPath: "backgroundColor",
                        to: NSColor.white.withAlphaComponent(0.08).cgColor)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        contentTintColor = .systemGray
        animateLayerKey(layer, keyPath: "backgroundColor", to: NSColor.clear.cgColor)
    }

    // MARK: - 面板滚动 hover 同步
    func syncHoverForCurrentPointer() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = visibleRect.contains(p)
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }
}

/// 手动刷新按钮：点击时图标顺时针旋转一圈。
/// AppKit layer-backed 视图经 Auto Layout 同步会把 anchorPoint 重置为 (0,0)，
/// 直接旋转会绕左下角转；需在 layout() 里恢复中心锚点 + 补偿 position（同 MiniSwitch 思路）。
/// hover 提亮交由外层 HoverRowView 统一驱动（contentTintColor==systemGray 时跟随提亮）。
final class RefreshIconButton: NSButton {
    private var isSpinning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        title = ""
        imageScaling = .scaleProportionallyDown
        contentTintColor = .systemGray
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreCenterAnchor()
    }

    override func layout() {
        super.layout()
        restoreCenterAnchor()
        // AppKit 可能在 layout 同步后重置 layer 属性，下一帧再修一次
        DispatchQueue.main.async { [weak self] in self?.restoreCenterAnchor() }
    }

    /// 恢复 layer 锚点 + 补偿 position，使旋转绕图标视觉圆心。
    /// y=0.41（低于几何中心 0.5）：arrow.clockwise 圆环视觉圆心偏下，
    /// 绕几何中心旋转会偏高，向下偏移对齐视觉圆心。
    private func restoreCenterAnchor() {
        guard let l = layer, l.bounds.width > 0 else { return }
        let center = CGPoint(x: 0.5, y: 0.41)
        guard l.anchorPoint != center else { return }
        var p = l.position
        p.x += l.bounds.width * (center.x - l.anchorPoint.x)
        p.y += l.bounds.height * (center.y - l.anchorPoint.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.anchorPoint = center
        l.position = p
        CATransaction.commit()
    }

    /// 点击发送 action 时顺时针旋转一圈（-2π，0.45s ease-in-out）
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        spinOnce()
        return super.sendAction(action, to: target)
    }

    private func spinOnce() {
        guard let l = layer, !isSpinning else { return }
        restoreCenterAnchor()
        isSpinning = true
        // macOS NSView（isFlipped=false）layer 坐标系 y 向上，rotation.z 正值=屏幕逆时针；
        // arrow.clockwise 箭头朝顺时针，故用负角 -2π 让屏幕上呈顺时针旋转。
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = -CGFloat.pi * 2
        anim.duration = 0.45
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = true
        anim.delegate = self
        l.add(anim, forKey: "spinOnce")
    }
}

extension RefreshIconButton: CAAnimationDelegate {
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        isSpinning = false
    }
}

/// 余额卡片容器：hover 时显示 8% 背景圆角，并切换签到信息子视图颜色。
/// 点击卡片触发 onClick 回调（如打开对应平台主页或应用）。
class HoverCard: NSView, PanelScrollHoverSync {
    private var trackingArea: NSTrackingArea?
    private weak var dragContentView: NSView?
    private var dragNormalBackgroundColor: CGColor?
    private var hasCapturedDragBackground = false
    private var isMouseInside = false
    private var isDragHoverLocked = false
    /// 点击回调：由外部设置，mouseUp 时触发
    var onClick: (() -> Void)?
    /// 右键点击回调：由外部设置，rightMouseDown 时触发（参数为事件，可用于弹出菜单定位）
    var onRightClick: ((NSEvent) -> Void)?
    /// 拖拽回调：设置后，整张卡片都可用于排序拖拽。
    var onDragStarted: ((NSPoint) -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    /// hover 状态回调：true=进入，false=离开（如「悬停显示昵称」）
    var onHover: ((Bool) -> Void)?
    /// hover 效果容器：渐变 + 噪点统一淡入淡出
    private let hoverEffectLayer = CALayer()
    /// hover 渐变背景层：沿渐变方向从亮到暗（白色 alpha 递减）
    private let hoverGradientLayer = CAGradientLayer()
    /// 白色噪点层：叠加在渐变上提供颗粒质感，自身再按同方向渐变遮罩（亮端明显、暗端渐隐）
    private let noiseLayer = CALayer()
    /// 噪点层渐变遮罩：alpha 白→透明，端点与背景渐变同步
    private let noiseMaskLayer = CAGradientLayer()
    /// 噪点图当前尺寸（尺寸变化才重新生成，固定种子保证内容稳定不闪）
    private var noiseSize = CGSize.zero
    /// 渐变方向：水平向右为 0°，视觉顺时针偏移量（度）
    private let gradientAngleDeg: CGFloat = 60

    var dragContentLayer: CALayer? { dragContentView?.layer }

    func configureDragContentView(_ view: NSView) {
        view.wantsLayer = true
        dragContentView = view
        if !hasCapturedDragBackground {
            dragNormalBackgroundColor = layer?.backgroundColor
            hasCapturedDragBackground = true
        }
    }

    func setDragContentOpacity(_ opacity: Float) {
        dragContentView?.wantsLayer = true
        dragContentView?.layer?.opacity = opacity
    }

    /// 幽灵卡片移除后，实际卡片可能没有收到新的 mouseEntered/mouseExited，
    /// 因此归位时必须用窗口当前光标位置重新判断 hover，而不是只依赖旧状态。
    private func isPointerInsideCard() -> Bool {
        guard let window else { return isMouseInside }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    // MARK: - 面板滚动 hover 同步
    /// 滚动后 AppKit 不补发 enter/exit：按当前光标位置重算 hover（visibleRect 已按滚动视口裁剪）。
    /// 拖拽锁定期间跳过（材质由 setDragHoverLocked 全权管理）。
    func syncHoverForCurrentPointer() {
        guard let window, !isDragHoverLocked else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = visibleRect.contains(p)
        if inside == isMouseInside { return }
        if inside { mouseEntered(with: NSEvent()) } else { mouseExited(with: NSEvent()) }
    }

    /// 拖拽期间锁住 hover 材质，避免卡片随幽灵位置移动到光标下方时重新淡入变亮。
    /// 归位交接时传入 animated=false，直接切换到最终状态，避免与幽灵卡片重叠一帧。
    func setDragHoverLocked(_ locked: Bool, animated: Bool = true) {
        guard isDragHoverLocked != locked else { return }
        isDragHoverLocked = locked
        if locked {
            hoverEffectLayer.removeAnimation(forKey: "opacityTransition")
            layer?.removeAnimation(forKey: "borderWidthTransition")
            // 占位卡片只保留静态内容，不继承按下拖动前已经存在的 hover 材质。
            // 关闭隐式动画，避免从 hover 状态切到占位状态时再闪一帧。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverEffectLayer.opacity = 0
            hoverEffectLayer.isHidden = true
            layer?.backgroundColor = dragNormalBackgroundColor ?? kCardBackground.cgColor
            layer?.borderWidth = 0
            CATransaction.commit()
            return
        }

        let showing = isPointerInsideCard()
        isMouseInside = showing
        hoverEffectLayer.isHidden = false
        layer?.backgroundColor = dragNormalBackgroundColor ?? kCardBackground.cgColor
        if !animated {
            hoverEffectLayer.removeAnimation(forKey: "opacityTransition")
            layer?.removeAnimation(forKey: "borderWidthTransition")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverEffectLayer.opacity = showing ? 1 : 0
            layer?.borderWidth = showing ? 0.8 : 0
            CATransaction.commit()
            onHover?(showing)
            return
        }
        animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: showing ? 1 : 0)
        animateLayerKey(layer, keyPath: "borderWidth", to: showing ? 0.8 : 0)
        onHover?(showing)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHoverGradient()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupHoverGradient() {
        wantsLayer = true
        hoverGradientLayer.colors = [NSColor.white.withAlphaComponent(0.08).cgColor,
                                     NSColor.white.withAlphaComponent(0.05).cgColor]
        noiseMaskLayer.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
        noiseLayer.mask = noiseMaskLayer
        noiseLayer.opacity = 0.7
        hoverEffectLayer.opacity = 0
        hoverEffectLayer.addSublayer(hoverGradientLayer)
        hoverEffectLayer.addSublayer(noiseLayer)
        layer?.addSublayer(hoverEffectLayer)
    }

    /// 子层 frame 不随 AutoLayout 同步，布局时手动贴满 bounds（圆角由父 layer masksToBounds 裁出）
    override func layout() {
        super.layout()
        hoverEffectLayer.frame = bounds
        hoverGradientLayer.frame = hoverEffectLayer.bounds
        noiseLayer.frame = hoverEffectLayer.bounds
        noiseMaskLayer.frame = noiseLayer.bounds
        updateGradientEndpoints()
        if bounds.size != noiseSize {
            noiseSize = bounds.size
            noiseLayer.contents = makeNoiseImage(width: Int(bounds.width), height: Int(bounds.height))
        }
    }

    /// 按角度与实际宽高比求渐变端点：取四角在渐变轴上投影的极值角，
    /// 保证任意宽高比下视觉角度恒定（固定单位坐标会因宽高比失真）
    private func updateGradientEndpoints() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let rad = gradientAngleDeg * .pi / 180
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
        hoverGradientLayer.startPoint = minPt
        hoverGradientLayer.endPoint = maxPt
        // 噪点遮罩与背景渐变同方向同端点，颗粒感随明暗渐变一起衰减
        noiseMaskLayer.startPoint = minPt
        noiseMaskLayer.endPoint = maxPt
    }

    /// 生成白色噪点图：约 22% 像素随机白点（alpha 0~0.2），固定种子（同类同尺寸噪点稳定）
    private func makeNoiseImage(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        // 线性同余伪随机：每次调用进程内一致，避免噪点图随重建变化
        func rnd() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        for i in 0..<(width * height) {
            if rnd() < 55 {
                px[i * 4] = 255; px[i * 4 + 1] = 255; px[i * 4 + 2] = 255
                px[i * 4 + 3] = rnd() / 5
            }
        }
        return px.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    /// 点击后鼠标通常仍停留在卡片内，AppKit 不会重新派发 mouseExited；
    /// 主动清除 hover 材质，避免点击可折叠标题后高亮一直残留。
    func clearHoverEffect(animated: Bool = true) {
        isMouseInside = false
        guard !isDragHoverLocked else { return }
        if animated {
            animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: 0)
            animateLayerKey(layer, keyPath: "borderWidth", to: 0)
        } else {
            hoverEffectLayer.removeAnimation(forKey: "opacityTransition")
            layer?.removeAnimation(forKey: "borderWidthTransition")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverEffectLayer.opacity = 0
            layer?.borderWidth = 0
            CATransaction.commit()
        }
        onHover?(false)
    }

    /// 可排序卡片不把事件命中交给内部 label、图标等子视图，确保整张卡片都能开始拖拽。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if onDragStarted != nil, bounds.contains(point) {
            return self
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onDragStarted != nil {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        if isDragHoverLocked { return }
        // 渐变 + 噪点背景淡入：顺时针偏 60°（从亮到暗，端点随宽高比自适应）
        animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: 1)
        // 发丝边框淡入：0.8pt white@20%（色值由 addCard 预设）
        animateLayerKey(layer, keyPath: "borderWidth", to: 0.8)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        if isDragHoverLocked { return }
        // 渐变 + 噪点淡出，露出容器统一背景
        animateLayerKey(hoverEffectLayer, keyPath: "opacity", to: 0)
        animateLayerKey(layer, keyPath: "borderWidth", to: 0)
        onHover?(false)
    }

    /// 点击卡片：mouseDown 记录按下位置，mouseUp 在 bounds 内时触发回调（避免拖出后误触）
    override func mouseDown(with event: NSEvent) {
        guard onDragStarted != nil, let window else {
            // 不调用 super：避免被当作无意义点击传给父视图
            return
        }

        let start = event.locationInWindow
        var dragging = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture,
                                          inMode: .eventTracking,
                                          dequeue: true) {
            if next.type == .leftMouseDragged {
                if !dragging {
                    let current = next.locationInWindow
                    let distance = hypot(current.x - start.x, current.y - start.y)
                    guard distance >= 3 else { continue }
                    dragging = true
                    NSCursor.closedHand.push()
                    onDragStarted?(current)
                }
                onDragChanged?(next.locationInWindow)
            } else if next.type == .leftMouseUp {
                if dragging {
                    onDragChanged?(next.locationInWindow)
                    onDragEnded?()
                    NSCursor.pop()
                } else {
                    onClick?()
                }
                return
            }
        }

        // 窗口关闭等异常情况下也要恢复拖拽状态，避免光标栈残留。
        if dragging {
            onDragEnded?()
            NSCursor.pop()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 不调用 super：由 onRightClick 接管，弹出上下文菜单
        onRightClick?(event)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) {
            onClick?()
        }
    }
}

/// 操作磁贴按钮：纵向 icon + 多行文本（最多两行）。
/// 继承 HoverCard：hover 效果与余额卡片完全统一（渐变+噪点背景、0.8pt white@20% 发丝边框、
/// bounds 内 mouseUp 触发），叠加磁贴特有的 icon 软光晕。
final class ActionTileButton: HoverCard {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// 目标-动作（与 NSButton 兼容，支持后续赋值）
    var target: AnyObject?
    var action: Selector?
    /// 进行中（脉冲 + 禁点）状态标记
    private var isInProgress = false
    /// icon 固定尺寸
    private let iconSize: CGFloat

    init(symbol: String? = nil, bundleIcon iconName: String? = nil, title: String, target: AnyObject?, action: Selector?, iconSize: CGFloat = 16) {
        self.iconSize = iconSize
        super.init(frame: .zero)
        self.target = target
        self.action = action
        // 点击经 HoverCard.onClick 触发（target/action 可在 init 后再赋值，闭包点击时取最新值）
        onClick = { [weak self] in
            guard let self, let action = self.action else { return }
            _ = self.target?.perform(action, with: self)
        }
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // 边框色与卡片统一 white@20%（hover 时由 HoverCard 动画 borderWidth 到 0.8）
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        layer?.borderWidth = 0

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.masksToBounds = false
        // icon 软光晕：hover 时淡入阴影，营造高级质感（硬编码中性灰，不随系统强调色）
        iconView.layer?.shadowColor = NSColor(calibratedWhite: 0.62, alpha: 1.0).cgColor
        iconView.layer?.shadowRadius = 6
        iconView.layer?.shadowOffset = .zero
        iconView.layer?.shadowOpacity = 0.0
        // 优先使用 bundle 内自定义 SVG（stroke=currentColor，isTemplate 跟随 tint 变色）
        if let name = iconName, let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            img.size = NSSize(width: iconSize, height: iconSize)
            iconView.image = img
            iconView.contentTintColor = kBalanceForeground
        } else if let s = symbol, let sym = NSImage(systemSymbolName: s, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
            sym.isTemplate = true
            // 强制 size = iconSize，避免 SF Symbol 的 alignmentRect 顶部留白导致视觉偏上
            sym.size = NSSize(width: iconSize, height: iconSize)
            iconView.image = sym
            iconView.contentTintColor = kBalanceForeground
        }
        label.font = .systemFont(ofSize: 9)
        // 文本用石墨灰系统语义色（弱于 icon 的 kBalanceForeground，降低存在感）
        label.textColor = .systemGray
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = true
        label.setContentHuggingPriority(.defaultLow, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false

        // 纵向 stack：icon + label 垂直居中
        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
        ])

        setTitle(title)
        // 磁贴文本最多两行且会截断，toolTip 展示完整动作名（HIG：图标类控件应有悬停提示）
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) {
        // 文本始终石墨灰、icon 始终 kBalanceForeground，无高亮态
        label.stringValue = title
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)  // 卡片同款：渐变+噪点背景、发丝边框
        // 磁贴特有：icon 软光晕
        animateLayerKey(iconView.layer, keyPath: "shadowOpacity", to: 0.45, duration: 0.22)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        animateLayerKey(iconView.layer, keyPath: "shadowOpacity", to: 0.0, duration: 0.22)
    }

    override func mouseUp(with event: NSEvent) {
        // 进行中不可重复触发（主流程侧另有状态守卫，这里拦掉视觉层点击）
        guard !isInProgress else { return }
        super.mouseUp(with: event)  // HoverCard：bounds 内触发 onClick
    }

    /// 进行中状态：true 时禁点 + 背景呼吸脉冲（手动签到/账号采集等长任务的通用反馈）
    func setInProgress(_ on: Bool) {
        guard on != isInProgress else { return }
        isInProgress = on
        if on {
            // 背景在白 5%↔14% 间呼吸（与 hover 底色同族，避免视觉突兀），
            // autoreverses + infinity 持续到任务结束；模型值先落 5% 保证动画移除后不闪清
            let pulse = CABasicAnimation(keyPath: "backgroundColor")
            pulse.fromValue = NSColor.white.withAlphaComponent(0.05).cgColor
            pulse.toValue = NSColor.white.withAlphaComponent(0.14).cgColor
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            layer?.add(pulse, forKey: "progressPulse")
        } else {
            layer?.removeAnimation(forKey: "progressPulse")
            // 恢复常态底色（若此刻正悬停，hover 渐变层照常覆盖在上）
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// 半透明遮罩视图：用 draw(_:) 而非 layer.backgroundColor 渲染色块。
/// NSView 的 backing layer 在加入 window 前可能为 nil，直接 set backgroundColor 会失效；
/// draw 由 AppKit 在确定进入渲染层级后调用，能可靠地呈现颜色。
/// 设置 bottomColor 后改为纵向渐变绘制：顶部 color（暗）→ 底部 bottomColor（中灰），
/// gradientStartY 指定渐变起点（距顶部 pt，起点以上保持纯暗色，与渐变起点无缝衔接）。
final class TintOverlayView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }
    var bottomColor: NSColor? { didSet { needsDisplay = true } }
    /// 渐变起始位置（距视觉顶部的 pt 数，isFlipped 语义：顶部为 0）；默认 0 = 从顶部渐变
    var gradientStartY: CGFloat = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = color else { return }
        if let b = bottomColor {
            let startY = min(max(bounds.minY + gradientStartY, bounds.minY), bounds.maxY)

            // 固定区域只绘制到渐变起点。不能先填满整个 bounds 再绘制渐变，
            // 否则渐变起点的半透明 c 会叠加在已有的 c 上，导致起点比上方固定区域更深。
            if startY > bounds.minY {
                c.setFill()
                NSBezierPath(rect: NSRect(x: bounds.minX,
                                           y: bounds.minY,
                                           width: bounds.width,
                                           height: startY - bounds.minY)).fill()
            }

            guard startY < bounds.maxY else { return }
            // isFlipped=true 时 minY 在顶部：colors[0]（暗）→ 渐变起点，colors[1]（中灰）→ 底部
            NSGradient(colors: [c, b])?.draw(from: NSPoint(x: bounds.midX, y: startY),
                                             to: NSPoint(x: bounds.midX, y: bounds.maxY),
                                             options: [])
        } else {
            c.setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }
}

/// 带遮罩的毛玻璃容器：在 NSVisualEffectView 毛玻璃之上叠一层半透明 NSView，
/// 用 draw(_:) 渲染，保留玻璃透明质感的同时加深底色（无色相）。
final class TintedVisualEffectView: NSVisualEffectView {
    private let tintView = TintOverlayView()

    var tintColor: NSColor? {
        didSet { tintView.color = tintColor }
    }

    /// 渐变底部色：设置后遮罩从 tintColor（顶部，暗）纵向渐变到此色（底部，中灰）
    var tintBottomColor: NSColor? {
        didSet { tintView.bottomColor = tintBottomColor }
    }

    /// 渐变起始位置（距容器顶部的 pt 数，0 = 从顶部渐变；起点以上保持纯暗色）
    var tintGradientStartY: CGFloat = 0 {
        didSet {
            guard abs(oldValue - tintGradientStartY) > 0.5 else { return }
            tintView.gradientStartY = tintGradientStartY
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTintView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTintView()
    }

    private func setupTintView() {
        tintView.translatesAutoresizingMaskIntoConstraints = false
        // 作为第一个子视图插入（在 panel 内容之下，毛玻璃之上）
        addSubview(tintView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// 手动签到结果行状态：成功 / 失败 / 跳过（token 失效、退避中等）
enum CheckinRowState { case ok, fail, skipped }

/// 手动签到结果行中的 SF Symbol 信息项，与余额卡片副标题保持一致。
struct CheckinInfoItem {
    let symbol: String
    let text: String
}

/// 手动签到结果行：状态符号 + 文本（由手动签到结果弹窗渲染）
struct CheckinResultRow {
    let text: String
    let state: CheckinRowState
    let infoItems: [CheckinInfoItem]

    init(text: String, state: CheckinRowState, infoItems: [CheckinInfoItem] = []) {
        self.text = text
        self.state = state
        self.infoItems = infoItems
    }
}

/// 隐藏原生滚动条；使用 Chrome 经典冲量-速度（Velocity-Impulse）物理模型 + CVDisplayLink 帧同步。
/// 普通鼠标滚轮：同向输入直接累加速度（越连滚越快）、阻尼滑行至停止；触控板精确滚动交系统原生。
private final class QuietScrollView: NSScrollView {

    // MARK: - 平滑参数（调手感只改这里）
    /// 单格滚轮的目标速度冲量（pt/s）：越大每格滑行越远；同向连滚线性叠加。
    /// 1 ≈ 单格最终滑行 ~0.2~0.5pt；必须连续滚几十格才看得出动。
    private let impulseGain: Double = 1
    /// 同向叠加时的额外加速度系数：1.0 = 纯线性叠加（滚 N 格 = N×冲量，最线性稳定）；
    /// >1 = 连滚额外提一下爆发力；<1 = 连滚衰减（几乎不用）
    private let accelerateFactor: Double = 1.0
    /// 最小步长（pt）：低于该阈值的小输入对齐到此值，避免滚轮"最小一格"的细碎抖动
    private let minStep: Double = 6
    /// 最小归一化行单位：每次输入步长 / 36 得到 normalizedLines，若 < 此值则夹到此值。
    /// 调小可让"单格"冲量更小（极端精细）；标准单格（3 line ≈ 36pt）normalizedLines=1.0 不受影响。
    private let minNormalizedLines: Double = 0.1
    /// 【延迟感核心】60fps 下每帧 velocity 向 targetVelocity 逼近的跟随率：
    /// 越小 → 延迟越重、越"沉"、越油润，滚轮不会一下猛冲；
    /// 0.12 → 强延迟（~14 帧才追上目标的 80%，前 220ms 几乎感觉不到速度爬上去）
    /// 0.20 → 中强延迟（~8 帧追上 80%）
    /// 1.00 → 完全无延迟（= 旧直接 velocity=冲量 模型）
    private let followPerFrameAt60fps: Double = 0.12
    /// 60fps 基准下每帧 targetVelocity 阻尼（目标速度自己先衰减，velocity 跟着慢慢追 → 全程油润延迟感）：
    /// 0.993 → 衰减极慢，小冲量下（impulseGain=1）单格总滑行约 3 秒
    /// 0.990 → 约 2 秒（之前默认）
    /// 0.978 → 约 1.0~1.3s
    private let dampingPerFrameAt60fps: Double = 0.993
    /// 停手阈值（pt/帧）：速度 < 此值直接收尾。对应 pt/s 要乘 60：
    /// 0.002 pt/帧 ≈ 0.12 pt/s，几乎完全停下来才收尾，保证滑行尾巴拖得更久。
    private let minVelocityPerFrame: Double = 0.002
    /// 判定是否进入收尾的"无新输入"等待（秒）：防止用户中间停顿 0.1~0.2s 时被误收尾
    private let settleIdle: CFTimeInterval = 0.4
    /// 目标速度硬上限（pt/s）：防止疯狂连滚几十格时速度爆掉，飞出天际
    private let maxTargetVelocity: Double = 1500

    // MARK: - 滚动状态
    /// CVDisplayLink：与显示器刷新率（60/120/144Hz ProMotion）同步帧输出
    private var displayLink: CVDisplayLink?
    /// 上一次 CVDisplayLink 回调到达时间（秒），用于按真实 dt 归一化阻尼/跟随率
    private var lastFrameTime: CFTimeInterval = 0
    /// 目标速度：每格滚轮直接写到这里，它先衰减（pt/s）
    private var targetVelocity: Double = 0
    /// 实际速度：通过 EMA 低通慢慢向 targetVelocity 靠拢（延迟感的核心）
    private var velocity: Double = 0
    /// 最近一次滚轮事件到达时间，用于检测"停手无新输入"时可以进入收尾
    private var lastEventTime: CFTimeInterval = 0
    /// 【原始滚动能漏网的最后一道防线】
    /// 我们记录期望的 contentView.bounds.origin.y；每帧先校验，发现与真实值差 >0.5pt 就强拉回来。
    /// （防止 super.scrollWheel 的隐式 CA 动画下一帧才执行，导致 3~40pt 的原生大跳被用户看见）
    /// -1 = 尚未初始化（首次从 clip 读）。
    private var expectedOriginY: CGFloat = -1
    private var linkRunning: Bool { displayLink.map { CVDisplayLinkIsRunning($0) } ?? false }

    func hideScrollers() {
        verticalScroller?.alphaValue = 0
        horizontalScroller?.alphaValue = 0
    }

    // MARK: - 滚轮拦截：彻底接管非精确滚轮
    override func scrollWheel(with event: NSEvent) {
        // 触控板 / Magic Mouse（hasPreciseScrollingDeltas=true）：
        // 自带连续滚动 + 系统惯性 + 相位字段，直接透传
        if event.hasPreciseScrollingDeltas {
            stopPipelineImmediately()
            super.scrollWheel(with: event)
            return
        }

        let clip = contentView
        // 1) 让系统按默认逻辑滚一次原始步长 → 拿到"系统对该滚轮事件换算后的真实像素位移 + 方向"
        //    【关键】包在禁用隐式动画的 CATransaction 里，确保 AppKit/NSScrollView 的 bounds 修改同步生效，
        //    不会因为有 CA 动画下一帧才改 bounds → 读不到 rawStep → 导致原始阶梯大跳漏网！
        let beforeY = clip.bounds.origin.y
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        super.scrollWheel(with: event)
        CATransaction.commit()
        var rawStep = Double(clip.bounds.origin.y - beforeY)

        // 2) 立即撤销原始"阶梯跳"——接下来的滚动全部由我们的 CVDisplayLink 平滑管线按帧吐出
        if rawStep != 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var origin = clip.bounds.origin
            origin.y = beforeY
            clip.setBoundsOrigin(origin)
            reflectScrolledClipView(clip)
            CATransaction.commit()
        }

        // 3) 兜底：如果 CATransaction 同步仍没拿到 rawStep（极少见的 AppKit 差异），
        //    手动按 deltaY × 行高估算，保证不会因为 rawStep==0 return 漏掉一格原生大跳
        if rawStep == 0 {
            let ls = lineScroll > 0 ? lineScroll : 16.0  // 每行 ~16pt 兜底
            let perEvent = CGFloat(event.deltaY) * ls     // event.deltaY 通常一格 = 3 line
            // 自然滚动偏好已经体现在 deltaY 符号上，这里按"向上/向下"手动对齐 NSScrollView 方向：
            // 内容向下走（滚到后面）= origin.y 增大，正常 macOS 普通滚轮 deltaY<0 = 滚下 = 内容向上 = origin.y 增大
            rawStep = Double(-perEvent)
            if rawStep != 0 {
                // 确保 bounds 在兜底分支里也维持 beforeY（防止 super 异步动画下一帧把内容翻过去）
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                var origin = clip.bounds.origin
                origin.y = beforeY
                clip.setBoundsOrigin(origin)
                reflectScrolledClipView(clip)
                CATransaction.commit()
            }
        }
        guard rawStep != 0 else { return }

        // 4) 最小步长归一化
        if abs(rawStep) < minStep {
            rawStep = (rawStep > 0 ? 1.0 : -1.0) * minStep
        }

        // 4) 计算本次冲量：以步长绝对值做权重（多 line 事件更大）× 基准冲量
        //    rawStep 典型值：3 line ≈ 36~48pt，除以 36pt 归一化到"标准单格 = 1 倍冲量"
        let normalizedLines = abs(rawStep) / 36.0
        let sign: Double = rawStep > 0 ? 1.0 : -1.0
        let impulse = sign * impulseGain * max(minNormalizedLines, normalizedLines)

        // 5) 写入 targetVelocity（不直接动 velocity——它会通过 EMA 低通慢慢向 target 靠拢 = 延迟感）
        if targetVelocity == 0 {
            targetVelocity = impulse
        } else {
            let movingSameDir = (targetVelocity > 0) == (impulse > 0)
            if movingSameDir {
                // 同向：accelerateFactor=1.0 纯线性叠加 → 连滚速度线性累加不爆炸，滚很多格输出也稳定
                targetVelocity = targetVelocity * accelerateFactor + impulse
            } else {
                // 方向翻转：直接用新冲量替换，避免左右互搏猛减速再反向
                targetVelocity = impulse
                velocity = 0  // 反向同时把当前实际速度清零，防止旧方向尾巴拖
            }
        }
        // 6) 防止连滚过多格速度爆掉：夹到 ±maxTargetVelocity 硬上限
        if targetVelocity > maxTargetVelocity { targetVelocity = maxTargetVelocity }
        if targetVelocity < -maxTargetVelocity { targetVelocity = -maxTargetVelocity }
        lastEventTime = CFAbsoluteTimeGetCurrent()
        // 7) 同步记录 expectedOriginY：此时我们已经把原始大跳撤销了，bounds 停在 beforeY
        //    后面 CVDisplayLink 的 applyDelta 会从这个基准慢慢推进，兜底对齐也从这里开始判
        expectedOriginY = beforeY

        ensureDisplayLink()
    }

    // MARK: - CVDisplayLink 生命周期
    private func ensureDisplayLink() {
        if linkRunning { return }
        if displayLink == nil {
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link = link else { return }
            displayLink = link
            // CVDisplayLink 回调是后台高优线程；Unmanaged 传 self 避免循环引用
            let selfOpaque = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
                guard let info = userInfo else { return kCVReturnError }
                let obj = Unmanaged<QuietScrollView>.fromOpaque(info).takeUnretainedValue()
                obj.onLinkTick()
                return kCVReturnSuccess
            }, selfOpaque)
        }
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        CVDisplayLinkStart(displayLink!)
    }

    /// 立刻关停管线 + 清空所有状态（触控板事件进来时调用，避免两者抢滚动控制权）
    private func stopPipelineImmediately() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
        targetVelocity = 0
        velocity = 0
        lastFrameTime = 0
        lastEventTime = 0
        expectedOriginY = -1
    }

    /// CVDisplayLink 后台线程回调：跳回主线程再操作 AppKit
    private func onLinkTick() {
        if Thread.isMainThread { mainTick() }
        else { DispatchQueue.main.async { self.mainTick() } }
    }

    // MARK: - 主循环（EMA 低通跟随 + 双变量衰减 = 全程油润延迟感）
    private func mainTick() {
        let clip = contentView
        // ★ 兜底对齐：每一帧先校验真实 origin.y 和我们期望的值。任何 AppKit 异步动画/原生大跳漏网都会被这里立即拉回来。
        if expectedOriginY >= 0 {
            let actualY = clip.bounds.origin.y
            let drift = abs(actualY - expectedOriginY)
            if drift > 0.5 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                var origin = clip.bounds.origin
                origin.y = expectedOriginY
                clip.setBoundsOrigin(origin)
                reflectScrolledClipView(clip)
                CATransaction.commit()
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = lastFrameTime > 0 ? now - lastFrameTime : (1.0 / 60.0)
        lastFrameTime = now
        guard dt > 0 else { return }

        // 0) 真实 dt 归一化：把"每 1/60 秒的基准系数"换算到当前帧长下
        let baselineFrame: Double = 1.0 / 60.0
        let framesEquiv = dt / baselineFrame

        // 1) targetVelocity 先阻尼衰减（它总是在前面先"瘦下去"）
        let dampingThisFrame = pow(dampingPerFrameAt60fps, framesEquiv)
        targetVelocity *= dampingThisFrame

        // 2) velocity EMA 向 targetVelocity 逼近——**延迟感的核心**
        //    归一化公式：follow = 1 - (1 - follow60)^(framesEquiv)
        //    跟随率不会直接加到 1，而是一步步靠拢 → 起步有爬升、停止有拖尾
        let followThisFrame = 1.0 - pow(1.0 - followPerFrameAt60fps, framesEquiv)
        velocity = velocity * (1.0 - followThisFrame) + targetVelocity * followThisFrame

        // 3) 本帧位移 = 实际速度 × dt，并写到 NSScrollView
        let deltaPt = velocity * dt
        let moved = applyDelta(CGFloat(deltaPt))

        // 4) 到达边界（moved 没写满）或"长时间无新输入 + 两者都足够小" → 直接收尾停止
        let sinceLastEvent = now - lastEventTime
        let vPerFrame = abs(velocity) * baselineFrame      // 统一成"每帧 pt"便于判断
        let tPerFrame = abs(targetVelocity) * baselineFrame
        let idleSettled = sinceLastEvent >= settleIdle
            && vPerFrame < minVelocityPerFrame
            && tPerFrame < minVelocityPerFrame
        if idleSettled {
            targetVelocity = 0
            velocity = 0
        }
        let blocked = abs(moved - CGFloat(deltaPt)) > 0.01   // 到达边界被钳制
        if blocked {
            targetVelocity = 0
            velocity = 0
        }
        if velocity == 0 && targetVelocity == 0 {
            if let link = displayLink, CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStop(link)
            }
            return
        }
    }

    /// 真正把一帧位移写到 NSScrollView（含边界钳制），返回实际生效位移；同步更新 expectedOriginY
    @discardableResult
    private func applyDelta(_ dy: CGFloat) -> CGFloat {
        let clip = contentView
        var origin = clip.bounds.origin
        let docH = documentView?.frame.height ?? 0
        let maxY = max(0, docH - clip.bounds.height)
        let oldY = origin.y
        let newY = origin.y + dy
        origin.y = max(0, min(maxY, newY))
        // 禁用隐式动画直接写，避免任何 AppKit 层的补间抢走控制权
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.setBoundsOrigin(origin)
        reflectScrolledClipView(clip)
        CATransaction.commit()
        expectedOriginY = origin.y
        return origin.y - oldY
    }
}

/// 提示层贴靠边：bottom = 面板底缘（下方还有内容），top = 面板顶缘（上方还有内容）
enum FadeHintEdge { case top, bottom }

/// 滚动提示层可调参数（config.json 持久化；「滚动提示」弹窗滑杆实时预览）
struct FadeHintParams: Equatable {
    /// 提示条带高度（pt）
    var bandHeight: Double = 54
    /// 贴靠边高光渐变最亮处 alpha
    var highlightAlpha: Double = -0.6
    /// 底色遮罩 50% 处 alpha（贴靠边恒为 1）
    var maskMidAlpha: Double = 0.45
    /// 箭头描边 alpha
    var arrowAlpha: Double = 0.75
    /// 箭头浮动幅度（pt，2s 周期）
    var bobAmplitude: Double = 2
}

/// 面板顶/底缘「还有内容」提示层：半透明底色渐变遮罩 + 透明白高光
/// 渐变 + 指向箭头（2s 周期轻微浮动，top 指上 / bottom 指下）。
/// 由控制器在内容超出视口且未滚到对应边缘时显示；纯视觉层，鼠标/滚轮事件全部穿透。
/// （原磨砂快照 + CIGaussianBlur 方案已移除，现为纯静态遮罩，无需滚动时刷新）
private final class ScrollFadeHint: NSView {
    override var isFlipped: Bool { true }

    let edge: FadeHintEdge

    /// 可调参数（调参弹窗滑杆拖动时实时赋值 → applyParams 即时生效）
    var params = FadeHintParams() {
        didSet {
            guard oldValue != params else { return }
            applyParams()
        }
    }

    /// 底色遮罩层：半透明容器色，mask 控制不透明度渐变（贴靠边最深 → 对侧透明）
    private let tintLayer = CALayer()
    private let tintMaskLayer = CAGradientLayer()
    private let gradientLayer = CAGradientLayer()
    /// darken 蒙版：负值高光时作为 gradientLayer 的 mask，控制透明度渐变；
    /// 灰阶本身均匀无 RGB 插值，渐变只发生在蒙版 alpha，避免渐变带状/ muddy。
    private let gradientMaskLayer = CAGradientLayer()
    private let arrowLayer = CAShapeLayer()
    private var isShown = false

    init(edge: FadeHintEdge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        // 本视图翻转坐标系（y=0 在顶）；贴靠边的 y：top=0，bottom=1
        let nearY: CGFloat = edge == .top ? 0 : 1
        let farY: CGFloat = edge == .top ? 1 : 0
        // 底色遮罩层最底：半透明容器色打底
        tintLayer.backgroundColor = Palette.containerTint.cgColor
        tintMaskLayer.locations = [0, 0.5, 1]
        tintMaskLayer.startPoint = CGPoint(x: 0.5, y: farY)
        tintMaskLayer.endPoint = CGPoint(x: 0.5, y: nearY)
        tintLayer.mask = tintMaskLayer
        layer?.addSublayer(tintLayer)
        gradientLayer.locations = [0, 0.5, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: farY)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: nearY)
        layer?.addSublayer(gradientLayer)
        // darken 蒙版：与高光同向（对侧透明 → 贴靠边满），applyParams 负值分支挂到 gradientLayer.mask
        gradientMaskLayer.locations = [0, 0.5, 1]
        gradientMaskLayer.startPoint = CGPoint(x: 0.5, y: farY)
        gradientMaskLayer.endPoint = CGPoint(x: 0.5, y: nearY)
        // 箭头：圆角折线 chevron，bottom 指下 / top 指上（路径 y 向下，以 bounds 左上为原点）
        arrowLayer.fillColor = nil
        arrowLayer.lineWidth = 1.8
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round
        arrowLayer.bounds = CGRect(x: 0, y: 0, width: 9, height: 4.2)
        let tipY: CGFloat = edge == .top ? 0 : 4.2
        let baseY: CGFloat = edge == .top ? 4.2 : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: baseY))
        path.addLine(to: CGPoint(x: 4.5, y: tipY))
        path.addLine(to: CGPoint(x: 9, y: baseY))
        arrowLayer.path = path
        layer?.addSublayer(arrowLayer)
        applyParams()
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 参数变化即时生效：颜色/渐变重设 + 浮动动画按新幅度重建
    /// （bandHeight 由 VC 的约束更新）
    private func applyParams() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 底色遮罩不透明度：0（对侧）→ maskMidAlpha（50%）→ 1（贴靠边）
        tintMaskLayer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(params.maskMidAlpha).cgColor,
            NSColor.white.cgColor,
        ]
        // 高光渐变：
        //  · 正值 → 白色高光，Normal 混合（常规提亮）：透明度直接编码在渐变颜色 alpha 里。
        //  · 负值 → 灰阶 + Photoshop「变暗 Darken」混合模式：逐通道取 min(底色, 灰阶)，
        //           已暗通道保持原样、仅压暗亮于灰阶的通道，因此比直接叠黑色更保留内容色相。
        //    关键：darken 的透明度渐变放进 gradientMaskLayer（纯 alpha 蒙版，无 RGB 插值），
        //          gradientLayer 本身只铺均匀灰阶（backgroundColor）+ compositingFilter，
        //          避免渐变颜色插值与混合模式叠加产生带状/ muddy。
        //    灰阶：darken 即「变暗」，源灰阶本应偏暗——不再是 1−|alpha| 的近白灰，
        //          取 0.3×(1−|alpha|)（下限 0.05，−0.7 → 0.09），始终落在暗灰区间。
        //    强度：由蒙版 alpha 随 |alpha| 缩放（对侧 0 → 贴靠边 |alpha|），曲线 0 → 0.39 → 1 同高光形状；
        //          |alpha| 越大、灰阶越暗 + 蒙版越满，效果越深。
        //    说明：纯黑源在 Darken 下与 Normal 等价（min(底,0)=0），故下限保留 0.05 而非 0。
        let hiAbs = abs(params.highlightAlpha)
        if params.highlightAlpha >= 0 {
            gradientLayer.compositingFilter = nil
            gradientLayer.mask = nil
            gradientLayer.backgroundColor = nil
            gradientLayer.colors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(hiAbs * 0.39).cgColor,
                NSColor.white.withAlphaComponent(hiAbs).cgColor,
            ]
        } else {
            gradientLayer.compositingFilter = CIFilter(name: "CIDarkenBlendMode")
            // 均匀暗灰铺底（无渐变颜色），透明度交给蒙版
            let grayLevel = CGFloat(max(0.05, 0.3 * (1 - hiAbs)))
            gradientLayer.colors = nil
            gradientLayer.backgroundColor = NSColor(white: grayLevel, alpha: 1).cgColor
            // darken 蒙版：对侧透明 → 贴靠边，强度随 |alpha| 缩放（曲线 0 → 0.39 → 1 同高光形状）
            let peak = min(1, hiAbs)
            gradientMaskLayer.colors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0.39 * peak).cgColor,
                NSColor.white.withAlphaComponent(peak).cgColor,
            ]
            gradientLayer.mask = gradientMaskLayer
        }
        arrowLayer.strokeColor = NSColor.white.withAlphaComponent(params.arrowAlpha).cgColor
        CATransaction.commit()
        // 浮动幅度变化：重建动画（正在显示时立即以新幅度浮动）
        arrowLayer.removeAnimation(forKey: "fadeHintBob")
        updateBobAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        tintMaskLayer.frame = CGRect(origin: .zero, size: bounds.size)
        gradientLayer.frame = bounds
        gradientMaskLayer.frame = CGRect(origin: .zero, size: bounds.size)
        // 箭头偏向贴靠边：top 层放 0.36 高度处（靠上），bottom 层放 0.64（靠下）
        let yRatio = edge == .top ? 0.36 : 0.64
        arrowLayer.position = CGPoint(x: bounds.midX, y: bounds.height * yRatio)
        CATransaction.commit()
    }

    private func updateBobAnimation() {
        let key = "fadeHintBob"
        if isShown && arrowLayer.animation(forKey: key) == nil {
            // 1s 单程 + 自动回返 = 2s 完整周期，与全局脉冲节奏一致；
            // 浮动方向朝贴靠边外：bottom 向下(+)，top 向上(−)
            let amp = CGFloat(params.bobAmplitude)
            guard amp > 0 else { return }
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0
            bob.toValue = edge == .top ? -amp : amp
            bob.duration = 1.0
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arrowLayer.add(bob, forKey: key)
        } else if !isShown {
            arrowLayer.removeAnimation(forKey: key)
        }
    }

    /// 显示/隐藏提示层（0.22s easeInEaseOut，与全局 hover 过渡一致）
    func setShown(_ shown: Bool) {
        guard isShown != shown else { return }
        isShown = shown
        updateBobAnimation()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = shown ? 1 : 0
        }
    }

    /// 纯指示层：不参与命中测试，滚轮与点击穿透到下方滚动内容
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 面板内容控制器：把 BalancePanelView 挂进 popover，宽度固定 250，高度受屏幕可用空间限制；
/// 内容超高时通过纵向滚动查看底部设置、操作和更新时间。
final class BalancePanelViewController: NSViewController {
    /// 面板顶部暗色区域的固定高度；在原 300pt 基础上缩短 30%，从 210pt 开始渐变。
    private let panelDarkRegionHeight: CGFloat = 210
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
    private var maximumHeight: CGFloat = 750
    private var contentSizeDirty = true
    /// 首次打开归位标记：只在 App 启动后第一次弹出时滚到最上方，
    /// 之后开关面板保留用户上次滚动位置
    private var didScrollToTopOnce = false

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
        // 叠加近黑半透明遮罩：降低 alpha 让玻璃质感更通透（底色更浅），不引入色相
        container.tintColor = Palette.containerTint
        // 背景纵向渐变（默认开启）：顶部保持近黑（暗）→ 底部中灰；开关关闭时恢复单色近黑
        container.tintBottomColor = panel.panelGradientEnabled ? Palette.containerTintBottom : nil
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
            self?.updateFadeHint()
            // 滚动后修正各卡片/按钮的 hover 状态（AppKit 不补发 enter/exit 事件）
            self?.syncHoverAfterScroll()
        })
        fadeObservers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.updateFadeHint() })
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
        panel.layoutSubtreeIfNeeded()
        let contentSize = panel.fittingSize
        let width = max(250, contentSize.width)
        let contentHeight = max(1, contentSize.height)
        let nextFrame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        if panel.frame != nextFrame { panel.frame = nextFrame }
        let viewportHeight = min(contentHeight, maximumHeight)
        // 滚动条始终隐藏（初始化 hasVerticalScroller=false，这里不再动态开启）
        let nextContentSize = NSSize(width: width, height: viewportHeight)
        if preferredContentSize != nextContentSize { preferredContentSize = nextContentSize }
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
    /// 遍历面板视图树，让所有可 hover 视图按当前光标位置重算状态
    private func syncHoverAfterScroll() {
        guard isViewLoaded, view.window != nil else { return }
        func walk(_ v: NSView) {
            if let syncable = v as? PanelScrollHoverSync { syncable.syncHoverForCurrentPointer() }
            for sub in v.subviews { walk(sub) }
        }
        walk(panel)
    }

    /// 按当前开关状态刷新背景遮罩：渐变（起点=面板顶部 210pt）或单色近黑
    private func applyGradient() {
        guard let container = view as? TintedVisualEffectView else { return }
        container.tintBottomColor = panel.panelGradientEnabled ? Palette.containerTintBottom : nil
        container.tintGradientStartY = panelDarkRegionHeight
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
        // 面板关闭后停止箭头浮动动画，避免不可见时持续渲染
        fadeHint.setShown(false)
        topHint.setShown(false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 背景渐变从面板顶部固定 210pt 开始；布局变化后同步背景状态
        applyGradient()
        updateFadeHint()
    }
}

/// 点阵进度：8 个方块横排，已用部分着色，剩余灰色。ratio 表示剩余比例。
/// pulsing=true 时最右的亮点阵以 2s 周期脉冲闪烁（透明度 0.55 ↔ 1.0 + 峰值白色闪烁，点大小不变），示意额度正在被消耗。
/// 脉冲状态由外部（makePanelSnapshot）传入，UsageDots 不自行比较，避免被面板操作重置。
final class UsageDots: NSView {
    var ratio: CGFloat = 0 { didSet { updateDots() } }
    var pulsing: Bool = false {
        didSet {
            guard oldValue != pulsing else { return }
            updatePulse()
        }
    }
    /// 点亮N个点时的颜色：8个点从绿→绿黄→黄→橙→橙红→红算术平均渐变（HSB空间线性插值）
    /// levelColors[0]=红(1个点亮)，levelColors[7]=绿(8个点亮)
    private let levelColors: [NSColor] = generateLevelColors()
    private static func generateLevelColors() -> [NSColor] {
        let count = 8
        var colors: [NSColor] = []
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1) // 0=红, 1=绿
            let h = t * 0.333 // 红(H:0) → 绿(H:120°=0.333)
            let s: CGFloat = 0.80
            let b: CGFloat = 0.92
            colors.append(NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: 1.0))
        }
        return colors
    }
    private let dotCount = 8
    private let dotWidth: CGFloat = 5.06  // 正方形宽高（4.6 × 1.1 ≈ 5.06）
    private let dotGap: CGFloat = 0.0     // 点间距
    private let dotRadius: CGFloat = 0.0  // 圆角 0（直角方块）
    /// 未点亮点的颜色：不透明石墨灰
    private static let dotDimColor = NSColor(calibratedWhite: 0.32, alpha: 1.0)
    private var dotLayers: [CALayer] = []
    private var lastActiveCount: Int = -1   // 上次亮起点数，-1 = 未初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        wantsLayer = true
        setupDotLayersIfNeeded()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupDotLayersIfNeeded()
    }
    private func setupDotLayersIfNeeded() {
        guard dotLayers.isEmpty, let rootLayer = layer else { return }
        for _ in 0..<dotCount {
            let l = CALayer()
            l.cornerRadius = dotRadius
            l.backgroundColor = Self.dotDimColor.cgColor
            rootLayer.addSublayer(l)
            dotLayers.append(l)
        }
        layoutDots()
        updateDots()
    }
    override func layout() {
        super.layout()
        layoutDots()
    }
    private func layoutDots() {
        guard !dotLayers.isEmpty else { return }
        let totalWidth = CGFloat(dotCount) * dotWidth + CGFloat(dotCount - 1) * dotGap
        let startX = (bounds.width - totalWidth) / 2
        // 正方形：高度 = 宽度，垂直居中
        let dotHeight = dotWidth
        let startY = (bounds.height - dotHeight) / 2
        let step = dotWidth + dotGap
        for (i, l) in dotLayers.enumerated() {
            let x = startX + CGFloat(i) * step
            // 宽度多 0.25pt 产生微小重叠，消除亚像素抗锯齿导致的视觉缝隙
            // （非整数像素位置边缘抗锯齿会产生半透明间隙）
            l.frame = CGRect(x: x, y: startY, width: dotWidth + 0.25, height: dotHeight)
        }
    }
    private func updateDots() {
        guard !dotLayers.isEmpty else { return }
        let activeCount = ratio > 0 ? Int(ceil(CGFloat(dotCount) * ratio)) : 0
        // 点亮的点统一着色：activeCount 对应 levelColors[activeCount-1]
        let activeColor: NSColor? = activeCount > 0 ? levelColors[activeCount - 1] : nil
        for (i, l) in dotLayers.enumerated() {
            l.backgroundColor = (i < activeCount ? activeColor : Self.dotDimColor)?.cgColor
        }
        // 仅在亮起点数变化时才重设脉冲目标，避免 ratio 微调（activeCount 不变）重置动画周期
        if lastActiveCount != activeCount {
            lastActiveCount = activeCount
            updatePulse()
        }
    }
    private func updatePulse() {
        for l in dotLayers {
            l.removeAnimation(forKey: "pulseGroup")
            // 重置为正常状态
            l.opacity = 1.0
        }
        guard pulsing, !dotLayers.isEmpty else { return }
        let activeCount = ratio > 0 ? Int(ceil(CGFloat(dotCount) * ratio)) : 0
        guard activeCount > 0 else { return }
        // 最右亮点阵脉冲：2s 周期，透明度呼吸 + 峰值白色闪烁
        let target = dotLayers[activeCount - 1]
        let baseColor = target.backgroundColor ?? NSColor.systemGreen.cgColor
        let whiteColor = NSColor.white.cgColor

        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.values = [0.55, 1.0, 0.55]
        opacityAnim.keyTimes = [0, 0.5, 1.0]

        let colorAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
        colorAnim.values = [baseColor, whiteColor, baseColor]
        colorAnim.keyTimes = [0, 0.5, 1.0]

        let group = CAAnimationGroup()
        group.animations = [opacityAnim, colorAnim]
        group.duration = 2.0
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(group, forKey: "pulseGroup")
    }
    override var intrinsicContentSize: NSSize {
        let w = CGFloat(dotCount) * dotWidth + CGFloat(dotCount - 1) * dotGap
        // 高度默认返回 7.0pt，实际由外部 heightAnchor 约束决定
        return NSSize(width: w, height: 7.0)
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
    var onToggleHideWbNickname: (() -> Void)?
    /// 面板渐变背景开关（设置卡片开关触发）
    var onTogglePanelGradient: (() -> Void)?
    /// Mono 字体开关（设置卡片开关触发：余额卡片与用量列表切换 DepartureMono）
    var onToggleMonoFont: (() -> Void)?
    /// 渐变开关状态变化通知（update 同步时触发，VC 据此刷新遮罩绘制）
    var onPanelGradientChanged: (() -> Void)?
    var onAbout: (() -> Void)?
    /// 管理各平台刷新与自动签到开关
    var onManagePlatformToggles: (() -> Void)?
    var onManualCheckin: (() -> Void)?
    /// 查看签到历史（各账号签到记录列表）
    var onShowCheckinHistory: (() -> Void)?
    var onQuit: (() -> Void)?
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

    // MARK: - 余额展示控件

    private let offlineBanner = NSTextField(labelWithString: "⚠︎ 离线，恢复网络后自动刷新")
    private let dsValueLabel = NSTextField(labelWithString: "—")
    private let dsDots = UsageDots()
    /// DeepSeek 卡片副标题标签（可更新文本，如显示日常额度信息）
    private let dsInfoLabel = NSTextField(labelWithString: "打开官网 usage 页面")
    private lazy var dsInfo: NSStackView = {
        registerFont(dsInfoLabel, size: 9)
        dsInfoLabel.textColor = .systemGray
        // 固定行高与 TRAE/WB 签到信息（icon+label 组合）一致：给 stackView 设高度约束，
        // 并降低 label 垂直拥抱优先级，让约束优先于 intrinsicContentSize（9pt 字体固有行高约 11pt）
        dsInfoLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        dsInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let stack = NSStackView(views: [dsInfoLabel])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return stack
    }()
    // WorkBuddy 多账号卡片容器（动态重建，账号列表变化时刷新）
    private var wbCardsContainer: NSStackView!
    private var wbCardEntries: [CardEntry] = []
    private var wbCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）
    private var hideWbNickname = true   // 隐藏平台昵称（变化时只切换 nickLabel alpha，不重建卡片）
    private weak var dsCardRef: NSView?     // DeepSeek 卡片引用，WB 卡片等高用

    /// 单个多号卡片的控件引用（update 时直接赋值，无需重建；WB / TRAE / ZCode 共用）。
    /// 非当前账号的 dots/checkinInfo 为占位实例（未加入视图层级，更新时跳过）。
    private struct CardEntry {
        let uid: String
        let valueLabel: NSTextField
        let dots: UsageDots
        let checkinInfo: NSStackView   // 签到信息行（每张当前账号卡片独立持有，避免跨重建复用导致布局错位）
        let nickLabel: NSTextField
        let infoLabel: NSTextField?    // 到期倒计时副标题（仅 ZCode 当前账号卡片有）
        let expireIcon: NSImageView?   // 到期行 timer 图标（随 expired 状态变色）
        var checkinKey: String = ""
        let badgeView: NSView          // 签到失败角标（icon 右上角，无签到平台恒隐藏）
    }

    /// 各平台卡片差异配置（icon / 标题 / 签到行 / 到期行 / reward 兜底）
    private struct CardStyle {
        let icon: String
        let name: String
        let platformID: String
        let iconSize: CGFloat           // 当前账号 icon 尺寸
        let secondaryIconSize: CGFloat  // 非当前账号小卡片 icon 尺寸
        let checkin: Bool               // 是否显示签到信息行（WB / TRAE）
        let showsExpire: Bool           // 是否显示重置/到期倒计时行（ZCode / Codex）
        let fallbackReward: Int         // reward 为 0 时的兜底值（WB 固定 +100，TRAE 显示 +???）
        let menuBarIdPrefix: String     // 菜单栏 item id 前缀："trae:" / "wb:" / "zcode:"
        static let wb    = CardStyle(icon: "workbuddy", name: "WorkBuddy", platformID: "wb", iconSize: 20.47, secondaryIconSize: 12.65, checkin: true, showsExpire: false, fallbackReward: 100, menuBarIdPrefix: "wb:")
        static let trae  = CardStyle(icon: "trae-color", name: "TRAE", platformID: "trae", iconSize: 20.47, secondaryIconSize: 12.65, checkin: true, showsExpire: false, fallbackReward: 0, menuBarIdPrefix: "trae:")
        static let zcode = CardStyle(icon: "zhipu", name: "ZCode", platformID: "zcode", iconSize: 17.55, secondaryIconSize: 12.02, checkin: false, showsExpire: true, fallbackReward: 0, menuBarIdPrefix: "zcode:")
        // Codex 余额卡片图标整体缩小 5%（大卡片与小卡片统一口径）。
        static let codex = CardStyle(icon: "codex", name: "Codex", platformID: "codex", iconSize: 19.45, secondaryIconSize: 12.02, checkin: false, showsExpire: true, fallbackReward: 0, menuBarIdPrefix: "codex:")
    }

    // TRAE 多账号卡片容器（动态重建，账号列表变化时刷新）
    private var traeCardsContainer: NSStackView!
    private var traeCardEntries: [CardEntry] = []
    private var traeCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）

    // 余额卡片组容器（统一背景 + 圆角，子卡片透明）；背景渐变起点定位依据
    private var balanceGroupContainer: NSStackView!
    /// 余额卡片组视觉底边距面板顶部的距离（背景渐变从此处开始；panel 非 flipped，
    /// 视觉底部 = frame.minY，故 = bounds.height - minY；布局前为 0 = 渐变暂从顶部开始）
    var balanceSectionBottomY: CGFloat {
        bounds.height - balanceGroupContainer.frame.minY
    }

    // ZCode 多账号卡片容器（动态重建，账号列表变化时刷新）
    private var zcodeCardsContainer: NSStackView!
    private var zcodeCardEntries: [CardEntry] = []
    private var zcodeCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）
    private var codexCardsContainer: NSStackView!
    private var codexCardEntries: [CardEntry] = []
    private var codexCardUids: [String] = []
    /// 平台卡片顺序：只在图标拖拽完成后写入，刷新余额不会改变用户排序。
    private var platformOrder: [String] = []
    private var platformCards: [String: NSView] = [:]
    private var draggingPlatform: String?
    /// 当前实际被拖动的账号卡片；用于占位内容，组幽灵的源视图单独记录。
    private weak var draggingCard: NSView?
    private weak var draggingGhostSourceView: NSView?
    private weak var draggingGhostView: NSImageView?
    private var draggingGhostOffset = NSPoint.zero
    /// 当前拖动平台内的其他账号小卡片及其原始内容透明度。
    private var draggingSiblingCardOpacities: [(card: HoverCard, opacity: Float)] = []
    private let updatedLabel = NSTextField(labelWithString: "")
    /// 刷新动效状态：true 时「更新于」区域脉冲显示「刷新中…」
    /// setter 私有，仅 setRefreshing(_:) 可写；getter internal，供 AppDelegate 调试日志用。
    private(set) var isRefreshing: Bool = false
    /// 相同快照只同步一次，避免菜单栏标题刷新时重复遍历和重排整个面板。
    private var lastSnapshot: PanelSnapshot?

    // MARK: - 设置/操作控件

    /// 日/周用量区块：内容行动态重建（随快照变化）
    private let usageContentStack = NSStackView()
    /// 用量数据未变化时复用已有行，避免每次余额刷新都销毁/重建 NSView。
    private var renderedUsageRows: [UsageRowSnapshot] = []
    private var usageCardRef: NSView?
    private var usageTitleRef: NSView?
    /// 平台 id → 用量行视图（拖拽排序时复用实例做位移动画）
    private var usageRowViews: [String: NSView] = [:]
    /// 表头行（今日 / 本周 列名），排序时保持在最上
    private var usageHeaderRowRef: NSView?
    /// 用量数值列宽（表头与数值行共用，保证上下对齐）
    private let usageColumnWidth: CGFloat = 56
    private let usageColumnSpacing: CGFloat = 8
    private let usageHorizontalInset: CGFloat = 8
    /// 用量行行内垂直缩进（原行间距 6pt 移入行内：行间距 0，每行上下统一缩进 2pt）
    private let usageRowTopInset: CGFloat = 2
    private let usageRowBottomInset: CGFloat = 2

    private let autoCheckinSwitch = MiniSwitch()
    private let autoCheckinSub = NSTextField(labelWithString: "")
    private let wbAddBtn = ActionTileButton(bundleIcon: "workbuddy",
                                           title: "添加账号", target: nil, action: nil)
    private let traeAddBtn = ActionTileButton(bundleIcon: "trae-color",
                                             title: "添加账号", target: nil, action: nil)
    /// 手动签到磁贴：进行中由 update() 驱动脉冲 + 禁点
    private let checkinBtn = ActionTileButton(symbol: "checkmark.seal",
                                              title: "手动签到", target: nil, action: nil)
    private let zcodeAddBtn = ActionTileButton(bundleIcon: "zhipu",
                                               title: "添加账号", target: nil, action: nil,
                                               iconSize: 14.45)  // 保持与基准 icon（16）的 ≈0.9 比例
    // 刷新间隔：MiniSegmentedControl（原生 .mini 尺寸，紧凑稳定）
    private let intervalSegment: MiniSegmentedControl = {
        let seg = MiniSegmentedControl(labels: ["1分钟", "3分钟", "5分钟"], trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = 2
        return seg
    }()
    private let hideWbNickSwitch = MiniSwitch()
    /// 面板渐变背景开关（update 时随快照同步状态）
    private let gradientSwitch = MiniSwitch()
    /// 渐变开关状态（update 同步；VC 读取决定遮罩渐变/单色）
    private(set) var panelGradientEnabled = true
    /// Mono 字体开关（update 时随快照同步状态）
    private let monoSwitch = MiniSwitch()
    /// Mono 字体开关状态（update 同步；变化时对已注册 label 就地切换字体，不重建卡片）
    private(set) var monoFontEnabled = false

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

    /// 按当前 Mono 开关状态取字体：开 = DepartureMono（中文级联回退系统字体），关 = 系统字体
    private func uiFont(size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) -> NSFont {
        if monoFontEnabled { return MonoFontProvider.font(size: size, weight: weight) }
        return monoDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }

    /// 注册 label 并立即应用当前字体策略（开关切换时 applyFontPolicy() 就地更新，不重建视图）
    private func registerFont(_ label: NSTextField, size: CGFloat, weight: NSFont.Weight = .regular, monoDigits: Bool = false) {
        label.font = uiFont(size: size, weight: weight, monoDigits: monoDigits)
        fontTargets.append(FontTarget(label: label, size: size, weight: weight, monoDigits: monoDigits))
        if fontTargets.count % 32 == 0 { fontTargets.removeAll { $0.label == nil } }
    }

    /// Mono 开关变化：对所有存活 label 就地切换字体（保留点阵脉冲等动画状态）
    private func applyFontPolicy() {
        for t in fontTargets {
            t.label?.font = uiFont(size: t.size, weight: t.weight, monoDigits: t.monoDigits)
        }
        fontTargets.removeAll { $0.label == nil }
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
        if gradientChanged { onPanelGradientChanged?() }
        // Mono 字体开关状态同步：变化时对已注册 label 就地切换字体（不重建卡片）
        let monoChanged = s.monoFontEnabled != monoFontEnabled
        monoFontEnabled = s.monoFontEnabled
        monoSwitch.state = s.monoFontEnabled ? .on : .off
        if monoChanged { applyFontPolicy() }
        offlineBanner.isHidden = !s.offline

        // 行序跟随平台卡片顺序（拖拽排序持久化于 platformOrder）
        let orderIndex = Dictionary(uniqueKeysWithValues: platformOrder.enumerated().map { ($1, $0) })
        let sortedRows = s.usageRows.sorted {
            (orderIndex[$0.platform] ?? Int.max) < (orderIndex[$1.platform] ?? Int.max)
        }
        if sortedRows != renderedUsageRows {
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

        dsValueLabel.stringValue = s.ds ?? "—"
        dsInfoLabel.stringValue = s.dsInfoText ?? "打开官网 usage 页面"
        if s.dsUsedRatio > 0 {
            let remainRatio = CGFloat(min(1, max(0, 1 - s.dsUsedRatio)))
            dsDots.ratio = remainRatio
            dsDots.isHidden = false
        } else {
            dsDots.ratio = 0
            dsDots.isHidden = true
        }
        dsDots.pulsing = s.dsPulsing

        // 昵称开关变化：昵称仅 hover 时显示，平时恒隐藏（不 rebuild 卡片，避免点阵脉冲动画被打断）；
        // 切换时把 alpha 复位为 0（可能正悬停中）
        let nickVisibilityChanged = s.hideWbNickname != hideWbNickname
        hideWbNickname = s.hideWbNickname
        if nickVisibilityChanged {
            for e in traeCardEntries { e.nickLabel.animator().alphaValue = 0 }
            for e in wbCardEntries { e.nickLabel.animator().alphaValue = 0 }
            for e in zcodeCardEntries { e.nickLabel.animator().alphaValue = 0 }
        }

        // ZCode 多账号卡片：uid 列表变化时重建，否则就地更新数据
        let newZcodeUids = s.zcodeAccounts.map(\.uid)
        if newZcodeUids != zcodeCardUids {
            contentSizeChanged = true
            rebuildZcodeCards(s.zcodeAccounts)
        } else {
            applyZcodeCardData(s.zcodeAccounts)
        }

        // Codex 多账号卡片：uid 列表变化时重建，否则就地更新
        let newCodexUids = s.codexAccounts.map(\.uid)
        if newCodexUids != codexCardUids {
            contentSizeChanged = true
            rebuildCodexCards(s.codexAccounts)
        } else {
            applyCodexCardData(s.codexAccounts)
        }

        // TRAE 多账号卡片：uid 列表变化 时重建，否则就地更新数据
        let newTraeUids = s.traeAccounts.map(\.uid)
        if newTraeUids != traeCardUids {
            contentSizeChanged = true
            rebuildTraeCards(s.traeAccounts)
        } else {
            applyTraeCardData(s.traeAccounts)
        }

        // WorkBuddy 多账号卡片：uid 列表变化 时重建，否则就地更新数据
        let newUids = s.wbAccounts.map(\.uid)
        if newUids != wbCardUids {
            contentSizeChanged = true
            rebuildWbCards(s.wbAccounts)
        } else {
            applyWbCardData(s.wbAccounts)
        }

        // ── 面板余额卡片显隐（平台开关：用户可强制隐藏某平台整组卡片）──
        // 空账号组（ZCode/Codex 未导入）即使配置为 true 也维持隐藏；
        // 用户配置为 false 时，无论容器重建后的状态如何，一律强制隐藏。
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
                // 多账号组：空容器由重建逻辑设为 isHidden=true，用户开关为 true 时不打扰；
                // 用户开关为 false 时强制隐藏，覆盖重建结果
                shouldHide = !userWantsShow || view.isHidden
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
        case 60: intervalSegment.selectedSegment = 0
        case 180: intervalSegment.selectedSegment = 1
        default: intervalSegment.selectedSegment = 2
        }

        hideWbNickSwitch.state = s.hideWbNickname ? .off : .on
        if contentSizeChanged { onContentChanged?() }
    }

    // MARK: - 平台卡片排序

    private var shouldReduceMotion: Bool {
        if #available(macOS 10.12, *) {
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        return false
    }

    private func visiblePlatformIDs() -> [String] {
        platformOrder.filter { id in
            guard let card = platformCards[id] else { return false }
            return !card.isHidden && card.frame.height > 0
        }
    }

    private func makeDragSnapshot(of card: NSView) -> NSImage? {
        guard !card.bounds.isEmpty,
              let representation = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return nil }
        // 先缓存拖动开始时的真实外观，让幽灵保留大卡片当前的 hover 样式；
        // 原卡片随后才会切成无 hover 占位，避免两者同时显示 hover 背景。
        card.cacheDisplay(in: card.bounds, to: representation)
        let image = NSImage(size: card.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    /// 平台排序对象与实际账号卡片并非总是同一层：DeepSeek 直接存卡片，
    /// 多账号平台存的是账号卡片容器。拖动视觉必须统一取当前账号卡片。
    private func draggableCard(for platformID: String) -> NSView? {
        guard let platformView = platformCards[platformID] else { return nil }
        if platformView is HoverCard { return platformView }
        if let container = platformView as? NSStackView {
            return container.arrangedSubviews.first(where: { $0 is HoverCard })
        }
        return platformView
    }

    /// 多账号平台有小卡片时，幽灵应覆盖整个账号组；单账号平台仍只显示当前卡片。
    private func dragGhostSourceView(for platformView: NSView, card: NSView) -> NSView {
        guard let container = platformView as? NSStackView,
              container.arrangedSubviews.contains(where: { view in
                  view is HoverCard && view !== card
              }) else { return card }
        return container
    }

    private func restoreDraggingSiblingCards() {
        for item in draggingSiblingCardOpacities {
            item.card.setDragContentOpacity(item.opacity)
        }
        draggingSiblingCardOpacities.removeAll()
    }

    private func beginPlatformDrag(_ id: String, locationInWindow: NSPoint) {
        guard draggingPlatform == nil, let platformView = platformCards[id] else { return }
        balanceGroupContainer.layoutSubtreeIfNeeded()

        guard let card = draggableCard(for: id) else { return }
        draggingPlatform = id
        draggingCard = card

        // 多账号平台的容器内还有非当前账号小卡片，它们同样属于占位组，
        // 一起降低内容透明度，避免拖动时同组卡片仍保持满亮。
        if let container = platformCards[id] as? NSStackView {
            for sibling in container.arrangedSubviews.compactMap({ $0 as? HoverCard }) where sibling !== card {
                let opacity = sibling.dragContentLayer?.opacity ?? 1
                draggingSiblingCardOpacities.append((card: sibling, opacity: opacity))
            }
        }
        let hoverCard = card as? HoverCard
        let ghostSourceView = dragGhostSourceView(for: platformView, card: card)
        draggingGhostSourceView = ghostSourceView
        let ghostFrame = ghostSourceView.convert(ghostSourceView.bounds, to: self)
        let pointer = convert(locationInWindow, from: nil)
        draggingGhostOffset = NSPoint(x: pointer.x - ghostFrame.minX, y: pointer.y - ghostFrame.minY)

        // 必须在锁住 hover 之前截图：幽灵保留按下瞬间的大卡片 hover 外观，
        // 原卡片则继续留在排序流中并切成无 hover 占位。
        var ghostReady = false
        if let image = makeDragSnapshot(of: ghostSourceView) {
            let ghost = NSImageView(frame: ghostFrame)
            ghost.image = image
            ghost.imageScaling = .scaleAxesIndependently
            ghost.imageAlignment = .alignCenter
            ghost.wantsLayer = true
            ghost.layer?.cornerRadius = Palette.cardCornerRadius
            ghost.layer?.cornerCurve = .continuous
            ghost.layer?.shadowColor = NSColor.black.cgColor
            ghost.layer?.shadowOffset = CGSize(width: 0, height: -3)
            ghost.layer?.shadowRadius = 10
            ghost.layer?.shadowOpacity = shouldReduceMotion ? 0.35 : 0.48
            // 拖拽开始时直接显示到最终透明度，避免幽灵卡片从 0 淡入造成起手闪烁。
            ghost.alphaValue = 0.96
            addSubview(ghost, positioned: .above, relativeTo: nil)
            draggingGhostView = ghost
            movePlatformGhost(to: locationInWindow)
            ghostReady = true
        }
        hoverCard?.setDragHoverLocked(true)

        // 原卡片保留在排序流中作为轻量占位，避免其他卡片在拖动时失去节奏。
        if let hoverCard = card as? HoverCard {
            // 只降低内容层，保持卡片背景/hover 材质稳定，避免归位时背景闪亮。
            hoverCard.setDragContentOpacity(ghostReady ? 0.18 : 0.88)
        } else {
            card.wantsLayer = true
            card.layer?.opacity = ghostReady ? 0.18 : 0.88
        }
        // 小卡片仍需承担同组结构提示，不能和主拖动卡片一样降到几乎不可见。
        let siblingOpacity: Float = ghostReady ? 0.4 : 0.88
        for item in draggingSiblingCardOpacities {
            item.card.setDragContentOpacity(siblingOpacity)
        }
    }

    private func movePlatformGhost(to locationInWindow: NSPoint) {
        guard let ghost = draggingGhostView else { return }
        let pointer = convert(locationInWindow, from: nil)
        ghost.frame.origin = NSPoint(x: pointer.x - draggingGhostOffset.x,
                                     y: pointer.y - draggingGhostOffset.y)
    }

    private func updatePlatformDrag(_ id: String, locationInWindow: NSPoint) {
        guard draggingPlatform == id else { return }
        movePlatformGhost(to: locationInWindow)
        balanceGroupContainer.layoutSubtreeIfNeeded()

        let visibleIDs = Set(visiblePlatformIDs())
        let remaining = platformOrder.filter { $0 != id && visibleIDs.contains($0) }
        let targetIndex = min(remaining.count,
                             remaining.reduce(into: 0) { result, candidate in
                                 guard let card = platformCards[candidate] else { return }
                                 let center = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
                                 // 面板是非 flipped 坐标：y 越大越靠上。
                                 if center.y > locationInWindow.y { result += 1 }
                             })
        let targetID = targetIndex < remaining.count ? remaining[targetIndex] : nil

        var nextOrder = platformOrder.filter { $0 != id }
        if let targetID, let anchorIndex = nextOrder.firstIndex(of: targetID) {
            nextOrder.insert(id, at: anchorIndex)
        } else if let last = remaining.last, let lastIndex = nextOrder.firstIndex(of: last) {
            nextOrder.insert(id, at: lastIndex + 1)
        } else {
            nextOrder.append(id)
        }

        if nextOrder != platformOrder {
            platformOrder = nextOrder
            applyPlatformOrder(animated: true)
            applyUsageOrder(animated: true)
        }
    }

    /// 用量行跟随平台卡片顺序：重排 arrangedSubview 并用 Y 轴位移动画让行平滑让位（同 applyPlatformOrder 口径）
    private func applyUsageOrder(animated: Bool) {
        let orderedViews = platformOrder.compactMap { usageRowViews[$0] }
        let dataRows = usageContentStack.arrangedSubviews.filter { $0 !== usageHeaderRowRef }
        guard !orderedViews.isEmpty, orderedViews.count == dataRows.count else { return }
        let oldFrames = Dictionary(uniqueKeysWithValues: orderedViews.map {
            (ObjectIdentifier($0), $0.frame)
        })
        // 表头保持最上，数据行按平台顺序重排
        let desired = (usageHeaderRowRef.map { [$0] } ?? []) + orderedViews
        for (index, view) in desired.enumerated() {
            guard let currentIndex = usageContentStack.arrangedSubviews.firstIndex(of: view),
                  currentIndex != index else { continue }
            usageContentStack.removeArrangedSubview(view)
            usageContentStack.insertArrangedSubview(view, at: index)
        }
        usageContentStack.layoutSubtreeIfNeeded()
        guard animated, !shouldReduceMotion else { return }
        for view in orderedViews {
            guard let oldFrame = oldFrames[ObjectIdentifier(view)],
                  oldFrame != view.frame,
                  let layer = view.layer else { continue }
            let animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.fromValue = oldFrame.midY - view.frame.midY
            animation.toValue = 0
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "usageReorder")
        }
    }

    private func endPlatformDrag() {
        guard let id = draggingPlatform else { return }
        draggingPlatform = nil
        guard let platformView = platformCards[id] else {
            draggingCard = nil
            draggingGhostSourceView = nil
            restoreDraggingSiblingCards()
            draggingGhostView?.removeFromSuperview()
            draggingGhostView = nil
            return
        }
        let card = draggingCard ?? draggableCard(for: id) ?? platformView
        draggingCard = nil
        let hoverCard = card as? HoverCard

        let ghost = draggingGhostView
        draggingGhostView = nil
        let ghostSourceView = draggingGhostSourceView ?? card
        draggingGhostSourceView = nil
        // 释放时以当前 arrangedSubview 的最终坐标为准，确保幽灵卡片归位到真实卡片位置。
        balanceGroupContainer.layoutSubtreeIfNeeded()
        platformView.layer?.removeAnimation(forKey: "platformReorder")
        let finalFrame = ghostSourceView.convert(ghostSourceView.bounds, to: self)
        if let ghost, !shouldReduceMotion {
            // 归位阶段先隐藏占位卡片内容，避免幽灵卡片与占位卡片半透明叠加变亮。
            let placeholderLayer = (card as? HoverCard)?.dragContentLayer ?? card.layer

            // 拖动过程中一直使用 NSView.frame，这里也用同一坐标系做吸附，
            // 避免在 frame 与 CALayer.position 之间切换时出现右上方跳动。
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ghost.animator().frame = finalFrame
            } completionHandler: { [weak self, weak ghost] in
                // 归位完成后做一次原子交接：占位内容直接接管并移除幽灵，
                // 避免额外的淡入动画在两层之间制造闪烁帧。
                placeholderLayer?.removeAnimation(forKey: "platformDropRestore")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                placeholderLayer?.opacity = 1
                ghost?.alphaValue = 0
                ghost?.removeFromSuperview()
                // 幽灵与占位在同一个交接事务内恢复最终 hover 状态，
                // 光标若已在卡片内则直接显示，避免多余的 hover 淡入闪烁。
                hoverCard?.setDragHoverLocked(false, animated: false)
                CATransaction.commit()
                self?.restoreDraggingSiblingCards()
                self?.draggingGhostOffset = .zero
            }
        } else {
            ghost?.removeFromSuperview()
            if let hoverCard = card as? HoverCard {
                hoverCard.setDragContentOpacity(1)
            } else {
                card.layer?.opacity = 1
            }
            restoreDraggingSiblingCards()
            hoverCard?.setDragHoverLocked(false, animated: false)
            draggingGhostOffset = .zero
        }
        UserDefaults.standard.set(platformOrder, forKey: UDKey.balancePlatformOrder)
        onPlatformOrderChanged?(platformOrder)
    }

    /// 调整 arrangedSubview 顺序，并仅用 Y 轴位移动画让相邻平台卡片平滑让位。
    private func applyPlatformOrder(animated: Bool) {
        let orderedViews = platformOrder.compactMap { platformCards[$0] }
        guard orderedViews.count == platformCards.count else { return }

        let oldFrames = Dictionary(uniqueKeysWithValues: orderedViews.map {
            (ObjectIdentifier($0), $0.frame)
        })
        for (index, view) in orderedViews.enumerated() {
            guard let currentIndex = balanceGroupContainer.arrangedSubviews.firstIndex(of: view),
                  currentIndex != index else { continue }
            balanceGroupContainer.removeArrangedSubview(view)
            balanceGroupContainer.insertArrangedSubview(view, at: index)
        }
        for view in orderedViews {
            balanceGroupContainer.setCustomSpacing(4, after: view)
        }
        balanceGroupContainer.layoutSubtreeIfNeeded()

        guard animated, !shouldReduceMotion else { return }
        for view in orderedViews {
            guard let oldFrame = oldFrames[ObjectIdentifier(view)],
                  oldFrame != view.frame,
                  let layer = view.layer else { continue }
            // 使用 transform.translation.y，明确锁住 X 轴，避免重排时出现水平漂移。
            let animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.fromValue = oldFrame.midY - view.frame.midY
            animation.toValue = 0
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "platformReorder")
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
            let valueLabel = NSTextField(labelWithString: "—")
            let isCurrent = ac.isCurrent
            let dots: UsageDots? = isCurrent ? UsageDots() : nil
            let checkinInfo = NSStackView()
            // 第二行信息：ZCode 当前账号为到期倒计时（timer 图标 + 文本，9pt systemGray 行高 12），
            // WB/TRAE 当前账号为签到信息行（空容器，由 updateCheckinInfo 填充）；非当前账号无第二行
            var expireLabel: NSTextField? = nil
            var expireIcon: NSImageView? = nil
            let info: NSStackView?
            if isCurrent && style.showsExpire {
                let label = NSTextField(labelWithString: "")
                registerFont(label, size: 9)
                label.textColor = .systemGray
                label.setContentHuggingPriority(.defaultLow, for: .vertical)
                label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                let icon = NSImageView()
                icon.image = symbolImage("timer", size: 9)
                icon.contentTintColor = .systemGray
                icon.imageScaling = .scaleProportionallyUpOrDown
                let stack = NSStackView(views: [icon, label])
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 0
                stack.heightAnchor.constraint(equalToConstant: 12).isActive = true
                expireLabel = label
                expireIcon = icon
                info = stack
            } else if isCurrent && style.checkin {
                info = checkinInfo
            } else {
                info = nil
            }
            // 昵称 label：始终创建，alpha=0 保留占位（避免切换时标题位置跳动）；
            // 复用 hideWbNickname 开关（语义为「显示平台昵称」，同时控制三个平台）：
            // 开启后仅在该卡片 hover 时淡入显示，关闭则完全不显示
            let nickLabel: NSTextField = {
                let nl = NSTextField(labelWithString: ac.nickname)
                nl.textColor = isCurrent ? .systemGray : Palette.cardForegroundDimmed
                nl.alphaValue = 0
                return nl
            }()
            // 非当前账号 icon 尺寸按平台由 CardStyle 指定（约大 icon 的 1/1.618，Codex/ZCode 再缩 5%），列宽不变
            let imgSize: CGFloat = isCurrent ? style.iconSize : style.secondaryIconSize
            let fgColor: NSColor = isCurrent ? kBalanceForeground : Palette.cardForegroundDimmed
            // 上下内边距大小卡统一 4pt
            let cardPadTop: CGFloat = 4
            let cardPadBottom: CGFloat = 4
            let uid = ac.uid
            weak var cardRef: NSView?
            // 签到失败角标（当日失败时显示；无签到平台仅调试模式，apply 阶段控制显隐）
            let badge = makeFailureBadge()
            let card = addCard(rows: [
                balanceContentRow(icon: style.icon, name: style.name, valueLabel: valueLabel,
                                  info: info, dots: dots, iconSize: style.iconSize, imageSize: imgSize,
                                  iconTopAligned: !isCurrent, iconTint: fgColor, nickLabel: nickLabel,
                                  titleWeight: .semibold, textColor: fgColor, failureBadge: badge)
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
            // 悬停卡片时昵称淡入、离开淡出（设置关闭时完全不显示）
            if let hc = card as? HoverCard {
                hc.onHover = { [weak self, weak label = nickLabel] showing in
                    guard let self, let label, !self.hideWbNickname else { return }
                    label.animator().alphaValue = showing ? 1 : 0
                }
            }
            // 当前账号卡片等高于 DeepSeek；非当前账号卡片自适应内容高度（更小）
            if isCurrent, let ds = dsCardRef {
                card.heightAnchor.constraint(equalTo: ds.heightAnchor).isActive = true
            }
            // 非当前账号无 dots/checkinInfo（未加入视图层级），用占位保持 entry 结构一致
            entries.append(CardEntry(uid: ac.uid, valueLabel: valueLabel,
                                     dots: dots ?? UsageDots(), checkinInfo: checkinInfo,
                                     nickLabel: nickLabel, infoLabel: expireLabel,
                                     expireIcon: expireIcon, badgeView: badge))
        }
        uids = accounts.map(\.uid)
        applyAccountCardData(accounts, entries: &entries, style: style)
    }

    /// 应用多号卡片数据：余额、昵称、点阵、签到信息、到期倒计时（重建后或就地刷新时调用）
    private func applyAccountCardData(_ accounts: [AccountCardSnapshot],
                                      entries: inout [CardEntry],
                                      style: CardStyle) {
        for (i, ac) in accounts.enumerated() where i < entries.count {
            let e = entries[i]
            e.valueLabel.stringValue = ac.value ?? "—"
            // 就地更新昵称显示（用户在平台内改昵称后无需 rebuild 卡片）
            e.nickLabel.stringValue = ac.nickname
            // 当日签到失败或调试模式 → icon 右上角显示失败角标（ZCode 无签到，仅调试模式）
            e.badgeView.isHidden = !ac.checkinFailed
            // 到期倒计时（无值时清空文本，占位保持行高稳定）；套餐已到期 → 文本与图标转红警告
            e.infoLabel?.stringValue = ac.expireText ?? ""
            let expireColor: NSColor = ac.expired ? .systemRed : .systemGray
            e.infoLabel?.textColor = expireColor
            e.expireIcon?.contentTintColor = expireColor
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
            if style.checkin {
                updateCheckinInfo(e.checkinInfo, cacheKey: &entries[i].checkinKey,
                                  done: ac.checkinDone, failed: ac.checkinFailed,
                                  streak: ac.streak, reward: ac.reward,
                                  fallbackReward: style.fallbackReward)
            }
        }
    }

    // MARK: - 三平台卡片入口（薄封装，仅绑定容器/样式/回调）

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

    /// 重建签到信息行（数据未变时跳过，避免 syncPanel 时布局抖动）：
    /// - 已签到：checkmark.seal 已签到  flame x天  gift +X
    /// - 签到失败：wrongwaysign 未签到
    /// - 未签到/未知：不显示
    /// - icon 与文本之间用细空格（U+2009），每项之间用 6pt 间距（同 headerRow 的 spacing）
    /// - fallbackReward：reward 为 0（未获取详细积分）时使用的兜底值。
    ///   WorkBuddy 签到响应不含 reward 字段，固定 +100；TRAE 无兜底显示 +???。
    private func updateCheckinInfo(_ stack: NSStackView, cacheKey: inout String, done: Bool, failed: Bool, streak: Int, reward: Int, fallbackReward: Int = 0) {
        let key = "\(done)|\(failed)|\(streak)|\(reward)|\(fallbackReward)"
        if key == cacheKey { return }
        cacheKey = key
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        // 清空旧子视图：先复制 arrangedSubviews 快照再逐一 remove，避免遍历中数组变化
        let oldSubviews = stack.arrangedSubviews
        for v in oldSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        var items: [NSView] = []
        if failed && !done {
            items.append(makeInfoItem(symbol: "wrongwaysign", text: "未签到"))
        } else if done {
            items.append(makeInfoItem(symbol: "checkmark.seal", text: "已签到"))
            items.append(makeInfoItem(symbol: "flame", text: "\(streak)\u{2009}天"))
            let displayReward = reward > 0 ? reward : fallbackReward
            items.append(makeInfoItem(symbol: "gift", text: displayReward > 0 ? "+\(displayReward)" : "+???"))
        }

        guard !items.isEmpty else { return }
        items.forEach { stack.addArrangedSubview($0) }
    }

    /// 用量表头行：「今日 / 本周」列名，右对齐固定列宽，与下方数值上下对齐
    private func makeUsageHeaderRow() -> NSView {
        func headerLabel(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            registerFont(l, size: 10, weight: .semibold)
            l.textColor = .systemGray
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: usageColumnWidth).isActive = true
            return l
        }
        // 左列名「平台」左对齐（与下方 icon 左缘同起点），右两列列名右对齐
        let platformHeader = NSTextField(labelWithString: "平台")
        registerFont(platformHeader, size: 10, weight: .semibold)
        platformHeader.textColor = .systemGray
        let row = NSStackView(views: [platformHeader, stretchSpacer(), headerLabel("今日"), headerLabel("本周")])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = usageColumnSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: usageHorizontalInset),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -usageHorizontalInset),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: usageRowTopInset),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -usageRowBottomInset),
        ])
        return container
    }

    /// 日/周用量行：品牌 icon + 平台名 + 右侧两列数值（固定列宽右对齐，对齐表头）
    private func makeUsageRow(_ row: UsageRowSnapshot) -> NSView {
        let usageIconSize: CGFloat = 13
        let iconView = NSImageView()
        iconView.image = bundleIcon(row.icon, size: usageIconSize) ?? symbolImage("app.fill", size: usageIconSize)
        iconView.image?.isTemplate = true
        iconView.contentTintColor = kBalanceForeground
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let nameLabel = NSTextField(labelWithString: row.name)
        registerFont(nameLabel, size: 12, weight: .semibold)
        nameLabel.textColor = kBalanceForeground
        func valueLabel(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            registerFont(l, size: 11, weight: .semibold, monoDigits: true)
            l.textColor = kBalanceForeground
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: usageColumnWidth).isActive = true
            return l
        }
        let rowStack = NSStackView(views: [iconView, nameLabel, stretchSpacer(),
                                           valueLabel(row.todayText), valueLabel(row.weekText)])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = usageColumnSpacing
        // icon↔标题 6pt（比列距略紧），其余保持列距 8pt
        rowStack.setCustomSpacing(6, after: iconView)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        // 位移动画需要 layer-backed
        rowStack.wantsLayer = true
        // 用量条目 hover：不做文本提亮，改为整行背景色变化（#8aa788aa 圆角底）
        let hoverRow = wrapHoverRow(rowStack, hoverTextColor: kBalanceForeground,
                                    horizontalPadding: usageHorizontalInset,
                                    topInset: usageRowTopInset,
                                    bottomInset: usageRowBottomInset)
        hoverRow.hoverBackgroundColor = kUsageHoverBackground
        hoverRow.enablesTextBrightening = false
        hoverRow.wantsLayer = true
        return hoverRow
    }

    /// 单项：SF Symbol icon + 文本，中间细空格
    private func makeInfoItem(symbol: String, text: String) -> NSView {
        let iconView = NSImageView()
        iconView.image = symbolImage(symbol, size: 9)
        iconView.contentTintColor = .systemGray
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "\u{2009}\(text)")
        registerFont(label, size: 9, weight: .regular)
        label.textColor = .systemGray
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [iconView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        return row
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

    // MARK: - 布局构建

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // 内在宽度 250：独立（未挂到窗口）时 fittingSize 也能解出正确高度
        widthAnchor.constraint(equalToConstant: 250).isActive = true

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.distribution = .fill
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            root.widthAnchor.constraint(equalToConstant: 250 - 14),
        ])

        // 底部更新时间标签启用 layer 供脉冲动效使用
        updatedLabel.wantsLayer = true

        // ── 离线横幅 ──
        offlineBanner.font = .systemFont(ofSize: 12)
        offlineBanner.textColor = .systemOrange
        offlineBanner.isHidden = true
        root.addArrangedSubview(offlineBanner)
        pinFullWidth(offlineBanner, in: root)

        // ── 余额分组标题（12pt bold + systemGray 石墨灰）──
        let balanceTitle = sectionTitleRow(name: "余额")
        balanceTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(balanceTitle)
        // 对齐到卡片内标题的左边界（root.leading + 8pt）
        balanceTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8).isActive = true
        // 上下间距统一 6pt（离线横幅→标题、标题→卡片）
        root.setCustomSpacing(6, after: offlineBanner)
        root.setCustomSpacing(0, after: balanceTitle)

        // ── 余额卡片组容器：统一 kCardBackground 背景 + 圆角，子卡片透明 ──
        let balanceGroupContainer = NSStackView()
        balanceGroupContainer.orientation = .vertical
        balanceGroupContainer.alignment = .width
        balanceGroupContainer.distribution = .fill
        balanceGroupContainer.spacing = 0
        balanceGroupContainer.translatesAutoresizingMaskIntoConstraints = false
        balanceGroupContainer.wantsLayer = true
        balanceGroupContainer.layer?.cornerRadius = Palette.cardCornerRadius
        balanceGroupContainer.layer?.cornerCurve = .continuous
        balanceGroupContainer.layer?.masksToBounds = true
        balanceGroupContainer.layer?.backgroundColor = kCardBackground.cgColor
        self.balanceGroupContainer = balanceGroupContainer
        root.addArrangedSubview(balanceGroupContainer)
        balanceGroupContainer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── DeepSeek 卡片（中间仅标题）──
        let dsCard = addCard(rows: [
            balanceContentRow(icon: "deepseek", name: "DeepSeek", valueLabel: dsValueLabel, info: dsInfo, dots: dsDots)
        ], to: balanceGroupContainer, onClick: { [weak self] in self?.onClickDeepSeek?() }, onRightClick: { [weak self] event in
            self?.onRightClickCard?("ds", event)
        }, onDragStarted: { [weak self] point in
            self?.beginPlatformDrag("ds", locationInWindow: point)
        }, onDragChanged: { [weak self] point in
            self?.updatePlatformDrag("ds", locationInWindow: point)
        }, onDragEnded: { [weak self] in
            self?.endPlatformDrag()
        }, topPadding: 4, bottomPadding: 4, cardBackground: nil)
        dsCardRef = dsCard
        platformCards[BalancePlatform.deepSeek.rawValue] = dsCard
        // 平台间间隔 4pt（同平台内 trae/wb 容器内部 spacing=0 不加间隔）
        balanceGroupContainer.setCustomSpacing(4, after: dsCard)

        // ── ZCode 多账号卡片容器（动态创建，账号列表变化时重建；置于 DeepSeek 卡片下方）──
        zcodeCardsContainer = NSStackView(views: [])
        zcodeCardsContainer.orientation = .vertical
        zcodeCardsContainer.alignment = .leading
        zcodeCardsContainer.distribution = .fill
        zcodeCardsContainer.spacing = 0
        zcodeCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        // 默认隐藏：无账号时 update() 的 uid 对比（空==空）不会触发 rebuild，
        // 若不默认隐藏，空容器会在 DeepSeek 与 TRAE 间多占 8pt 间距
        zcodeCardsContainer.isHidden = true
        balanceGroupContainer.addArrangedSubview(zcodeCardsContainer)
        zcodeCardsContainer.widthAnchor.constraint(equalTo: balanceGroupContainer.widthAnchor).isActive = true
        platformCards[BalancePlatform.zcode.rawValue] = zcodeCardsContainer
        balanceGroupContainer.setCustomSpacing(4, after: zcodeCardsContainer)

        // ── Codex 多账号卡片容器（本机 auth.json 导入）──
        codexCardsContainer = NSStackView(views: [])
        codexCardsContainer.orientation = .vertical
        codexCardsContainer.alignment = .leading
        codexCardsContainer.distribution = .fill
        codexCardsContainer.spacing = 0
        codexCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        codexCardsContainer.isHidden = true
        balanceGroupContainer.addArrangedSubview(codexCardsContainer)
        codexCardsContainer.widthAnchor.constraint(equalTo: balanceGroupContainer.widthAnchor).isActive = true
        platformCards[BalancePlatform.codex.rawValue] = codexCardsContainer
        balanceGroupContainer.setCustomSpacing(4, after: codexCardsContainer)

        // ── TRAE 多账号卡片容器（动态创建，账号列表变化时重建）──
        // 单账号时也走容器：保证布局与 WB 多账号卡片一致
        traeCardsContainer = NSStackView(views: [])
        traeCardsContainer.orientation = .vertical
        traeCardsContainer.alignment = .leading
        traeCardsContainer.distribution = .fill
        traeCardsContainer.spacing = 0
        traeCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        traeCardsContainer.wantsLayer = true
        traeCardsContainer.layer?.masksToBounds = true
        balanceGroupContainer.addArrangedSubview(traeCardsContainer)
        traeCardsContainer.widthAnchor.constraint(equalTo: balanceGroupContainer.widthAnchor).isActive = true
        platformCards[BalancePlatform.trae.rawValue] = traeCardsContainer
        balanceGroupContainer.setCustomSpacing(4, after: traeCardsContainer)

        // ── WorkBuddy 多账号卡片容器（动态创建，账号列表变化时重建）──
        wbCardsContainer = NSStackView(views: [])
        wbCardsContainer.orientation = .vertical
        wbCardsContainer.alignment = .leading
        wbCardsContainer.distribution = .fill
        wbCardsContainer.spacing = 0
        wbCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        balanceGroupContainer.addArrangedSubview(wbCardsContainer)
        wbCardsContainer.widthAnchor.constraint(equalTo: balanceGroupContainer.widthAnchor).isActive = true
        platformCards[BalancePlatform.workBuddy.rawValue] = wbCardsContainer
        balanceGroupContainer.setCustomSpacing(4, after: wbCardsContainer)

        // 应用上次拖拽保存的平台顺序；隐藏的账号组仍保留位置，之后重新出现时顺序不跳变。
        applyPlatformOrder(animated: false)

        // 余额区块 → 用量区块（分割线已移除，用区块间距分隔）
        root.setCustomSpacing(10, after: balanceGroupContainer)

        // ── 日/周用量区块（可折叠；行内容随快照重建）──
        var usageCollapseTargets: [NSView] = []
        let usageTitle = collapsibleSectionTitle(name: "用量", key: UDKey.usageSectionCollapsed,
                                                 titleWeight: .semibold,
                                                 targets: { usageCollapseTargets })
        root.addArrangedSubview(usageTitle)
        pinFullWidth(usageTitle, in: root)
        root.setCustomSpacing(0, after: usageTitle)
        usageTitleRef = usageTitle
        usageContentStack.orientation = .vertical
        usageContentStack.alignment = .width
        usageContentStack.distribution = .fill
        usageContentStack.spacing = 0
        usageContentStack.translatesAutoresizingMaskIntoConstraints = false
        let usageCard = addCard(rows: [usageContentStack], to: root, spacing: 6, topPadding: 2, horizontalPadding: 0)
        usageCardRef = usageCard
        usageCollapseTargets = [usageCard]
        let usageCollapsed = UserDefaults.standard.bool(forKey: UDKey.usageSectionCollapsed)
        usageCard.isHidden = usageCollapsed
        root.setCustomSpacing(usageCollapsed ? 6 : 0, after: usageTitle)
        // 用量区块 → 设置区块
        root.setCustomSpacing(10, after: usageCard)

        // ── 设置卡片 ──
        autoCheckinSwitch.target = self
        autoCheckinSwitch.action = #selector(autoCheckinToggled)
        hideWbNickSwitch.target = self
        hideWbNickSwitch.action = #selector(hideWbNicknameToggled)
        gradientSwitch.target = self
        gradientSwitch.action = #selector(panelGradientToggled)
        monoSwitch.target = self
        monoSwitch.action = #selector(monoFontToggled)
        // 刷新间隔行：标题 + 手动刷新按钮 + spacer + NSSegmentedControl
        intervalSegment.target = self
        intervalSegment.action = #selector(intervalChanged)
        intervalSegment.setContentHuggingPriority(.required, for: .horizontal)
        intervalSegment.setContentHuggingPriority(.defaultLow, for: .vertical)
        intervalSegment.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // 钉死分段控件宽度（3 × 38，与 viewDidMoveToWindow 中 setWidth 一致）：
        // NSSegmentedControl 的 intrinsic 尺寸由 cell 按系统版本计算，setWidth 在
        // viewDidMoveToWindow 才生效、且未必被 intrinsic 采纳，行内余量会被它吃掉，
        // 导致低压缩阻力的 label 先被压窄、文字被裁剪。显式约束不受版本/时序影响。
        // 内边距已由 CompactSegmentedCell 收窄，38pt/段足以容纳「3分钟」@9pt（约 25pt）。
        intervalSegment.widthAnchor.constraint(equalToConstant: 114).isActive = true
        let intervalLabel = NSTextField(labelWithString: "刷新时间")
        intervalLabel.font = .systemFont(ofSize: 12)
        intervalLabel.textColor = kBalanceForeground
        // label 压缩阻力提到 required：行空间不足时优先让其它视图让步，label 永远不被压窄
        intervalLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 手动刷新按钮：arrow.clockwise 图标，石墨灰（systemGray），size 10（小于选项文本 12pt，更紧凑）。
        // 点击时图标顺时针旋转一圈（RefreshIconButton 内部 sendAction 触发）。
        // 无独立 hover 背景——整行被 HoverRowView 包裹，hover 时图标 contentTintColor 跟随
        // 下方选项小字一起提亮为 labelColor（systemGray→labelColor），样式一致。
        let manualRefreshBtn = RefreshIconButton()
        manualRefreshBtn.image = symbolImage("arrow.clockwise", size: 10)
        manualRefreshBtn.target = self
        manualRefreshBtn.action = #selector(manualRefreshTapped)
        manualRefreshBtn.setContentHuggingPriority(.required, for: .horizontal)
        manualRefreshBtn.setContentHuggingPriority(.defaultLow, for: .vertical)
        manualRefreshBtn.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let intervalRow = RefreshRow()
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 6
        intervalRow.setViews([intervalLabel, manualRefreshBtn, stretchSpacer(), intervalSegment], in: .leading)
        intervalRow.segmentView = intervalSegment
        intervalRow.triggerButton = manualRefreshBtn

        let settingRows = [
            intervalRow,
            switchRow(title: "自动签到", sub: autoCheckinSub, sw: autoCheckinSwitch),
            switchRow(title: "悬停卡片时显示昵称", sub: nil, sw: hideWbNickSwitch),
            switchRow(title: "面板渐变背景", sub: nil, sw: gradientSwitch),
            switchRow(title: "Mono 字体", sub: nil, sw: monoSwitch),
        ].map { wrapHoverRow($0) }
        // 「设置」标题：可折叠标题条（hover 余额卡片样式，点击折叠整个设置卡片）
        var settingCollapseTargets: [NSView] = []
        let settingTitle = collapsibleSectionTitle(name: "设置", key: UDKey.settingsSectionCollapsed,
                                                    targets: { settingCollapseTargets })
        root.addArrangedSubview(settingTitle)
        pinFullWidth(settingTitle, in: root)
        root.setCustomSpacing(0, after: settingTitle)
        let settingCard = addCard(rows: settingRows, to: root, spacing: 8)
        // 折叠目标接线 + 初始态（内容隐藏与标题下间距，展开时间距 0 贴卡片）
        settingCollapseTargets = [settingCard]
        let settingsCollapsed = UserDefaults.standard.bool(forKey: UDKey.settingsSectionCollapsed)
        settingCard.isHidden = settingsCollapsed
        root.setCustomSpacing(settingsCollapsed ? 6 : 0, after: settingTitle)

        // ── 操作卡片：磁贴按钮（每行 4 个，超出换行）──
        wbAddBtn.target = self
        wbAddBtn.action = #selector(addWbAccountTapped)
        traeAddBtn.target = self
        traeAddBtn.action = #selector(addTraeAccountTapped)
        zcodeAddBtn.target = self
        zcodeAddBtn.action = #selector(addZcodeAccountTapped)
        // Codex 操作按钮图标与余额卡片保持同样的 5% 缩放口径。
        let codexAddBtn = ActionTileButton(bundleIcon: "codex", title: "添加账号", target: self, action: #selector(addCodexAccountTapped), iconSize: 16.05)
        checkinBtn.target = self
        checkinBtn.action = #selector(manualCheckinTapped)

        let cockpitBtn = ActionTileButton(symbol: "gauge.with.needle", title: "Cockpit", target: self, action: #selector(openCockpitTapped))
        let deepSeekSettingsBtn = ActionTileButton(bundleIcon: "deepseek", title: "Key / 额度", target: self, action: #selector(setApiKeyTapped))
        let aboutBtn = ActionTileButton(symbol: "info.circle", title: "关于", target: self, action: #selector(aboutTapped))
        let platformTogglesBtn = ActionTileButton(symbol: "circle.grid.2x2.topleft.checkmark.filled", title: "平台开关", target: self, action: #selector(platformTogglesTapped))
        let actionTiles = [
            cockpitBtn,
            wbAddBtn,
            traeAddBtn,
            zcodeAddBtn,
            codexAddBtn,
            deepSeekSettingsBtn,
            checkinBtn,
            ActionTileButton(symbol: "list.bullet.rectangle", title: "签到历史", target: self, action: #selector(checkinHistoryTapped)),
            platformTogglesBtn,
            aboutBtn,
        ]
        // 各按钮悬停提示（HIG：图标类控件应有 tooltip）
        cockpitBtn.toolTip = "打开 Cockpit"
        wbAddBtn.toolTip = "添加 WorkBuddy 账号"
        traeAddBtn.toolTip = "添加 TRAE 账号"
        zcodeAddBtn.toolTip = "添加 ZCode 账号（JSON 导入）"
        codexAddBtn.toolTip = "添加 Codex 账号（JSON 导入 ~/.codex/auth.json）"
        deepSeekSettingsBtn.toolTip = "配置 DeepSeek API Key 和日常额度"
        platformTogglesBtn.toolTip = "管理各平台刷新与自动签到开关"
        let buildVer = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        aboutBtn.toolTip = "关于 iBalance（v\(buildVer)）"
        // 按钮间水平间距 4pt（4×52 + 3×4 = 220 ≤ 内容宽 236，整体靠左）
        let tileSpacing: CGFloat = 4
        for tile in actionTiles {
            tile.widthAnchor.constraint(equalToConstant: 52).isActive = true
            tile.heightAnchor.constraint(equalToConstant: 44).isActive = true
            tile.setContentHuggingPriority(.required, for: .horizontal)
            tile.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // 按每行 4 个切分；.fill + 固定间距：不满一行的行也按同样间距从左到右排列（不居中/不撑开）
        let maxPerRow = 4
        let rows: [[ActionTileButton]] = stride(from: 0, to: actionTiles.count, by: maxPerRow).map {
            Array(actionTiles[$0..<min($0 + maxPerRow, actionTiles.count)])
        }
        let tileRows: [NSStackView] = rows.map { rowTiles in
            let row = NSStackView(views: rowTiles)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = tileSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
            return row
        }
        // 设置区块 → 操作区块（分割线已移除，用区块间距分隔）
        root.setCustomSpacing(10, after: settingCard)
        // 「操作」标题：可折叠标题条（折叠时内容整体隐藏）
        var actionCollapseTargets: [NSView] = []
        let actionTitle = collapsibleSectionTitle(name: "操作", key: UDKey.actionsSectionCollapsed,
                                                  targets: { actionCollapseTargets })
        root.addArrangedSubview(actionTitle)
        pinFullWidth(actionTitle, in: root)
        root.setCustomSpacing(0, after: actionTitle)
        // App 宫格样式：行内容器内靠左（不满一行的末行也靠左），整个容器在卡片内水平居中；
        // 左右内边距 0（容器宽 220 ≤ 内容宽 236），行间垂直间距 4pt
        let tilesContainer = NSStackView(views: tileRows)
        tilesContainer.orientation = .vertical
        tilesContainer.alignment = .leading
        tilesContainer.distribution = .fill
        tilesContainer.spacing = 4
        tilesContainer.translatesAutoresizingMaskIntoConstraints = false
        let actionCard = addCard(rows: [tilesContainer], to: root, bottomPadding: 7, horizontalPadding: 0, stretchRows: false, centerRows: true)

        // 操作区块 → footer（分割线已移除，用区块间距分隔）
        root.setCustomSpacing(10, after: actionCard)
        // 折叠目标接线 + 初始态
        actionCollapseTargets = [actionCard]
        let actionsCollapsed = UserDefaults.standard.bool(forKey: UDKey.actionsSectionCollapsed)
        actionCard.isHidden = actionsCollapsed
        root.setCustomSpacing(actionsCollapsed ? 6 : 0, after: actionTitle)

        // ── 底部：更新时间（严格水平居中）+ 退出按钮（贴右）──
        updatedLabel.font = .systemFont(ofSize: 9, weight: .regular)
        updatedLabel.textColor = .systemGray
        let quitBtn = HoverIconButton()
        quitBtn.image = symbolImage("power", size: 11)
        quitBtn.target = self
        quitBtn.action = #selector(quitTapped)
        quitBtn.toolTip = "退出 iBalance"
        // 用 Auto Layout 让 updatedLabel 严格居中、quitBtn 贴右，避免 spacer 造成的偏移
        // ⚠️ 子控件必须显式关闭 translatesAutoresizingMaskIntoConstraints，否则 Auto Layout 约束
        //    被忽略、控件堆在 footer 左上角 {0,0}（updatedLabel 宽度退化成 intrinsicContentSize）
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        updatedLabel.translatesAutoresizingMaskIntoConstraints = false
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(updatedLabel)
        footer.addSubview(quitBtn)
        root.addArrangedSubview(footer)
        pinFullWidth(footer, in: root)
        // 固定 footer 高度，避免子控件 intrinsicContentSize 变化时重新布局导致错位
        let footerHeight: CGFloat = 20
        NSLayoutConstraint.activate([
            footer.heightAnchor.constraint(equalToConstant: footerHeight),
            updatedLabel.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            updatedLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            updatedLabel.heightAnchor.constraint(lessThanOrEqualToConstant: footerHeight),
            quitBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            quitBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            // 容器固定 22×22（HoverIconButton.buttonSize）；无边框按钮，
            // hover 时自绘大圆角淡白背景（圆角与卡片统一）
            quitBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            quitBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
        ])
    }

    /// 卡片容器：NSVisualEffectView（自动适配深浅色）+ 圆角 + 内边距，宽度撑满 root。
    /// title 非空时在顶部加一行小标题；spacing 为行距（设置/操作卡片用 12，余额卡片用默认 6）。
    /// 有点击、右键或拖拽回调时卡片使用 HoverCard；设置/操作卡片用普通 NSView。
    /// bottomPadding: 卡片底部内边距（默认 7，操作卡片可减小以消除与 footer 间的空白）
    @discardableResult
    private func addCard(rows: [NSView], to root: NSStackView, title: String? = nil, spacing: CGFloat = 6, onClick: (() -> Void)? = nil, onRightClick: ((NSEvent) -> Void)? = nil, onDragStarted: ((NSPoint) -> Void)? = nil, onDragChanged: ((NSPoint) -> Void)? = nil, onDragEnded: (() -> Void)? = nil, topPadding: CGFloat = 7, bottomPadding: CGFloat = 7, horizontalPadding: CGFloat = 8, titleColor: NSColor = .systemGray, cardBackground: NSColor? = kCardBackground, stretchRows: Bool = true, centerRows: Bool = false) -> NSView {
        var all = rows
        if let t = title {
            all.insert(sectionTitleRow(name: t, color: titleColor), at: 0)
        }
        let stack = NSStackView(views: all)
        stack.orientation = .vertical
        stack.alignment = centerRows ? .centerX : .leading
        stack.distribution = .fill
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 子行横向撑满，数值靠行内 spacer 推到右端；
        // stretchRows=false 的行（如操作磁贴行）按内容宽度靠左排：
        // 不满一行的磁贴行若被拉到全宽，行内 .fill 会打破固定宽约束把末尾磁贴撑满
        if stretchRows {
            all.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }

        // 卡片透明背景（露出 popover 原生玻璃），仅保留圆角 + 细边框区分
        // 余额卡片使用 HoverCard 获得 hover 高亮 + 点击回调；设置/操作卡片用普通 NSView
        let card: NSView
        if onClick != nil || onRightClick != nil || onDragStarted != nil {
            let hc = HoverCard()
            hc.onClick = onClick
            hc.onRightClick = onRightClick
            hc.onDragStarted = onDragStarted
            hc.onDragChanged = onDragChanged
            hc.onDragEnded = onDragEnded
            card = hc
        } else {
            card = NSView()
        }
        card.wantsLayer = true
        card.layer?.cornerRadius = Palette.cardCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        // 预设边框色（hover 时由 HoverCard/ActionTileButton 动画 borderWidth 显示）
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        card.layer?.borderWidth = 0
        // 卡片底色：cardBackground=nil 表示子卡片透明（由外层容器统一提供背景）
        if let bg = cardBackground {
            card.layer?.backgroundColor = bg.cgColor
        }
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        if let hc = card as? HoverCard {
            hc.configureDragContentView(stack)
        }
        // ⚠️ 必须先加入层级：跨视图约束（card vs root）在激活时要求二者已有公共祖先，
        //    否则抛 NSGenericException "no common ancestor"
        root.addArrangedSubview(card)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -horizontalPadding),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: topPadding),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -bottomPadding),
            card.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        return card
    }

    /// 分组标题行：标题，12pt bold + systemGray（石墨灰），左对齐，固定行高 24pt
    private func sectionTitleRow(name: String, color: NSColor = .systemGray) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = color
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    /// 内容高度变化回调（区块折叠/展开后由面板调用）：VC 据此重算 preferredContentSize，
    /// 让 popover 高度随内容收缩，其余区块保持自然高度不被拉伸
    var onContentChanged: (() -> Void)?

    /// 可折叠区块标题条：hover 复用余额卡片样式（HoverCard 渐变+噪点+0.8pt 发丝边框），
    /// 点击切换折叠并持久化（UserDefaults，key 走 UDKey）。整条撑满 root 宽：
    /// 标题文字左对齐余额标题（内边距 8），箭头（▸ 折叠 / ▾ 展开）靠右贴卡片内边界。
    /// targets 闭包返回随折叠一起隐藏的视图（build 在区块内容创建后才会填充，闭包按引用取最新值）；
    /// 初始折叠态由 build 在填完 targets 后自行应用（isHidden + 间距）。
    private func collapsibleSectionTitle(name: String, key: String, titleWeight: NSFont.Weight = .bold,
                                         targets: @escaping () -> [NSView]) -> HoverCard {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12, weight: titleWeight)
        label.textColor = .systemGray
        let chevron = NSImageView()
        chevron.contentTintColor = .systemGray
        chevron.imageScaling = .scaleProportionallyUpOrDown

        func apply(_ collapsed: Bool) {
            targets().forEach { $0.isHidden = collapsed }
            chevron.image = symbolImage(collapsed ? "chevron.right" : "chevron.down", size: 8)
            // 折叠后标题下方无卡片可贴（间距 0 会贴住下一元素），补 6pt；展开恢复 0 贴卡片
            (hc.superview as? NSStackView)?.setCustomSpacing(collapsed ? 6 : 0, after: hc)
            // 通知 VC 按新内容高度收缩 popover，避免固定高度把其余区块拉伸
            onContentChanged?()
        }

        let hc = HoverCard()
        hc.onClick = {
            let collapsed = !UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(collapsed, forKey: key)
            // 点击时鼠标仍在标题范围内，主动清掉 HoverCard 的 hover 材质。
            hc.clearHoverEffect(animated: false)
            apply(collapsed)
        }
        hc.wantsLayer = true
        // 圆角与余额卡片统一（Palette.cardCornerRadius = 10pt）
        hc.layer?.cornerRadius = Palette.cardCornerRadius
        hc.layer?.cornerCurve = .continuous
        hc.layer?.masksToBounds = true
        // 边框色预设（HoverCard mouseEntered 只动画 borderWidth，色值由此处提供）
        hc.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        hc.layer?.borderWidth = 0
        // label 与箭头直接锚到标题条两端——不经 NSStackView（默认 .gravityAreas
        // 会把子视图全堆在 leading 重力区，行撑满也没法把箭头推到最右）
        hc.addSubview(label)
        hc.addSubview(chevron)
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hc.heightAnchor.constraint(equalToConstant: 24),
            // 标题文字距左 8（与余额标题对齐），垂直居中
            label.leadingAnchor.constraint(equalTo: hc.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: hc.centerYAnchor),
            // 箭头钉在最右（距右 8，与卡片右内边界对齐），垂直居中
            chevron.trailingAnchor.constraint(equalTo: hc.trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: hc.centerYAnchor),
        ])
        // 初始箭头方向（内容显隐由 build 在 targets 就绪后应用）
        chevron.image = symbolImage(UserDefaults.standard.bool(forKey: key) ? "chevron.right" : "chevron.down", size: 8)
        return hc
    }

    /// 余额卡片内容行：左大 icon + 中间纵向（标题/签到信息）+ 右纵向（额度值/点阵）
    /// 三列撑满整行：icon 26pt / middle ≥ 70% / right 40pt
    /// 中间内容垂直居中；点阵进度放右侧额度值下方（DeepSeek 无点阵）
    /// failureBadge：外部创建的签到失败角标视图，叠加在 icon 右上角（显隐由调用方控制）
    private func balanceContentRow(icon iconName: String, name: String, valueLabel: NSTextField, info: NSStackView?, dots: UsageDots?, iconSize: CGFloat = 20.47, imageSize: CGFloat? = nil, iconTopAligned: Bool = false, iconTint: NSColor = kBalanceForeground, nickLabel: NSTextField? = nil, titleWeight: NSFont.Weight = .semibold, textColor: NSColor = kBalanceForeground, failureBadge: NSView? = nil) -> NSView {
        let imgSize = imageSize ?? iconSize
        // 左：大 icon（固定列宽 = iconSize + 4，image 居中显示，imageSize 可独立缩小）
        let iconView = NSImageView()
        iconView.image = bundleIcon(iconName, size: imgSize) ?? symbolImage("app.fill", size: imgSize)
        iconView.image?.isTemplate = true
        iconView.contentTintColor = iconTint
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // iconContainer：撑满 row 高度，iconView 在内 centerY 居中。
        // 拖拽由外层 HoverCard 接管，因此整张卡片而非仅 icon 可触发排序。
        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)
        let iconCenterY = iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor)
        let iconCenterX = iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor)
        if iconTopAligned && imgSize < iconSize {
            iconCenterY.constant = -(iconSize - imgSize) / 2 - 4 + 8
            iconCenterX.constant = 4
        }
        NSLayoutConstraint.activate([
            iconCenterX,
            iconContainer.widthAnchor.constraint(equalToConstant: iconSize + 4),
            iconCenterY,
        ])
        // 签到失败角标：贴 icon 右上角（跟随 iconView 偏移），默认隐藏由调用方按需显示
        if let badge = failureBadge {
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.isHidden = true
            iconContainer.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 11),
                badge.heightAnchor.constraint(equalToConstant: 11),
                badge.centerXAnchor.constraint(equalTo: iconView.centerXAnchor, constant: imgSize / 2 - 1),
                badge.centerYAnchor.constraint(equalTo: iconView.centerYAnchor, constant: -imgSize / 2),
            ])
        }

        // 标题行：nameLabel（平台名，kBalanceForeground）+ 可选 nickLabel（昵称，systemGray 石墨灰）
        let nameLabel = NSTextField(labelWithString: name)
        registerFont(nameLabel, size: 12, weight: titleWeight)
        nameLabel.textColor = textColor
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 平台标题优先保持完整，昵称在有限空间内使用省略号。
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 12pt 字体需要略高于字号本身的行框，避免字形下沿被裁切。
        nameLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let titleRow: NSView
        if let nick = nickLabel {
            // 昵称放标题后：使用标题行剩余空间，单行尾部省略。
            registerFont(nick, size: 10)
            nick.maximumNumberOfLines = 1
            nick.lineBreakMode = .byTruncatingTail
            nick.cell?.truncatesLastVisibleLine = true
            nick.cell?.wraps = false
            nick.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nick.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // 用 firstBaseline 对齐：10pt 与 12pt 文字基线对齐，视觉居中
            let row = NSStackView(views: [nameLabel, nick])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 4
            titleRow = row
        } else {
            titleRow = nameLabel
        }
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 额度值（固定宽 60pt，右对齐，字号 12pt semibold）
        registerFont(valueLabel, size: 12, weight: .semibold, monoDigits: true)
        valueLabel.textColor = textColor
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byClipping
        valueLabel.maximumNumberOfLines = 1
        valueLabel.cell?.truncatesLastVisibleLine = true
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        // 第一行：标题（左）+ 数值（右）同一行
        // 用普通 NSView + 显式约束，避免 NSStackView gravity 分布歧义
        let row1 = NSView()
        row1.translatesAutoresizingMaskIntoConstraints = false
        row1.addSubview(titleRow)
        row1.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: row1.leadingAnchor),
            titleRow.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -4),
            valueLabel.trailingAnchor.constraint(equalTo: row1.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: row1.centerYAnchor),
            row1.heightAnchor.constraint(equalToConstant: 16),
        ])

        // 第二行：小项目（左）+ 点阵（右）同一行
        // 用普通 NSView + 显式约束，避免 NSStackView gravity 分布歧义
        // 点阵高度与小项目字号（9pt）等高，视觉对齐
        let row2 = NSView()
        row2.translatesAutoresizingMaskIntoConstraints = false
        var row2HasContent = false
        if let info = info {
            info.setContentHuggingPriority(.required, for: .horizontal)
            info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            info.translatesAutoresizingMaskIntoConstraints = false
            row2.addSubview(info)
            NSLayoutConstraint.activate([
                info.leadingAnchor.constraint(equalTo: row2.leadingAnchor),
                info.centerYAnchor.constraint(equalTo: row2.centerYAnchor),
            ])
            row2HasContent = true
        }
        if let dots = dots {
            dots.translatesAutoresizingMaskIntoConstraints = false
            dots.setContentHuggingPriority(.required, for: .horizontal)
            dots.heightAnchor.constraint(equalToConstant: 7.0).isActive = true
            row2.addSubview(dots)
            NSLayoutConstraint.activate([
                dots.trailingAnchor.constraint(equalTo: row2.trailingAnchor),
                dots.centerYAnchor.constraint(equalTo: row2.centerYAnchor),
            ])
            row2HasContent = true
        }
        // row2 高度由内容撑开（取 info 和 dots 中较高的）
        if row2HasContent {
            row2.heightAnchor.constraint(equalToConstant: 12).isActive = true
        }

        // 内容纵向 stack：[row1, row2]（row2 有内容才加入）
        var contentViews: [NSView] = [row1]
        if row2HasContent {
            contentViews.append(row2)
        }
        let content = NSStackView(views: contentViews)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 2
        content.distribution = .fill
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.translatesAutoresizingMaskIntoConstraints = false
        // 让两行撑满 content 宽度：这样行内 .trailing gravity 的元素（数值/点阵）才会贴右对齐
        for v in contentViews {
            v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        // 容器包裹 content：撑满 row 高度，内容垂直居中
        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor),
        ])

        let row = NSStackView(views: [iconContainer, contentContainer])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY   // icon 与内容垂直居中
        // .fill：iconContainer 有 required 固定宽约束保持原宽，
        // contentContainer（低拥抱优先级）撑满剩余宽度到行尾，数值/点阵才能右对齐贴边
        row.distribution = .fill
        iconContainer.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        contentContainer.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        return row
    }

    /// 用 HoverRowView 包裹行视图：获得 hover 时 8% 背景圆角 + pointingHand 光标
    private func wrapHoverRow(_ row: NSView, hoverTextColor: NSColor = .labelColor,
                              horizontalPadding: CGFloat = 0, topInset: CGFloat = 0,
                              bottomInset: CGFloat = 0) -> HoverRowView {
        let hover = HoverRowView()
        hover.hoverTextColor = hoverTextColor
        hover.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        hover.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: horizontalPadding),
            row.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -horizontalPadding),
            row.topAnchor.constraint(equalTo: hover.topAnchor, constant: topInset),
            row.bottomAnchor.constraint(equalTo: hover.bottomAnchor, constant: -bottomInset),
        ])
        return hover
    }

    /// 开关行：标题（可选副标题）+ 右侧 NSSwitch（.mini 尺寸，紧凑）
    /// 点击整行任意位置都能切换开关状态
    private func switchRow(title: String, sub: NSTextField?, sw: NSSwitch) -> NSView {
        sw.controlSize = .mini
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = kBalanceForeground
        sw.setContentHuggingPriority(.required, for: .horizontal)
        // 降低垂直拥抱/压缩阻力：让外部固定行高约束能压住开关高度
        sw.setContentHuggingPriority(.defaultLow, for: .vertical)
        sw.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        var views: [NSView] = [label]
        if let s = sub {
            // 字号/颜色对齐余额卡片签到信息（10pt + systemGray 石墨灰）
            s.font = .systemFont(ofSize: 10, weight: .regular)
            s.textColor = .systemGray
            s.isHidden = true
            views.append(s)
        }
        views.append(stretchSpacer())
        views.append(sw)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        // 点击整行任意位置触发开关切换：手势加到行容器上，覆盖 label/spacer/switch 全区域
        let tap = NSClickGestureRecognizer(target: sw, action: #selector(NSSwitch.performClick))
        row.addGestureRecognizer(tap)
        return row
    }

    /// 可拉伸占位（把右侧元素推到行尾）
    private func stretchSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(50), for: .horizontal)
        return v
    }

    /// 让子视图撑满 root 宽度（root alignment 为 centerX，需显式等宽）
    private func pinFullWidth(_ v: NSView, in root: NSStackView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func symbolImage(_ name: String, size: CGFloat = 14) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return img.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    /// 从 App bundle Resources 加载品牌 SVG 图标。
    /// ⚠️ 保持文件原始颜色：不设 isTemplate、不加 contentTintColor，
    ///    否则品牌色（如 TRAE 渐变）会被单色化。
    private func bundleIcon(_ name: String, size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = false
        img.size = NSSize(width: size, height: size)
        return img
    }

    /// 签到失败角标：exclamationmark.message.fill（系统红色，无底框），叠加在卡片 icon 右上角。
    /// 默认隐藏，由 apply*CardData 按当日签到失败状态显隐。
    private func makeFailureBadge() -> NSView {
        let img = NSImageView()
        img.image = symbolImage("exclamationmark.message.fill", size: 11)
        img.contentTintColor = .systemRed
        img.imageScaling = .scaleProportionallyUpOrDown
        return img
    }

    // MARK: - 控件回调（转发给 AppDelegate 接线）

    @objc private func openCockpitTapped() { onOpenCockpit?() }
    @objc private func autoCheckinToggled() { onToggleAutoCheckin?() }
    @objc private func addWbAccountTapped() { onAddWbAccount?() }
    @objc private func addZcodeAccountTapped() { onAddZcodeAccount?() }
    @objc private func addCodexAccountTapped() { onAddCodexAccount?() }
    @objc private func addTraeAccountTapped() { onCollectTraeAccount?() }
    @objc private func hideWbNicknameToggled() { onToggleHideWbNickname?() }
    @objc private func panelGradientToggled() { onTogglePanelGradient?() }
    @objc private func monoFontToggled() { onToggleMonoFont?() }
    @objc private func setApiKeyTapped() { onSetApiKey?() }

    @objc private func platformTogglesTapped() { onManagePlatformToggles?() }

    @objc private func aboutTapped() { onAbout?() }
    @objc private func manualCheckinTapped() { onManualCheckin?() }
    @objc private func checkinHistoryTapped() { onShowCheckinHistory?() }
    @objc private func quitTapped() { onQuit?() }
    @objc private func intervalChanged() {
        let seconds: Int
        switch intervalSegment.selectedSegment {
        case 0: seconds = 60
        case 1: seconds = 180
        default: seconds = 300
        }
        onSetInterval?(seconds)
    }
    @objc private func manualRefreshTapped() { onManualRefresh?() }
}

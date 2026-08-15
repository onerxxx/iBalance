// Panel.swift — NSPopover 详情面板（左键点击菜单栏图标弹出）
//
// 布局（宽 250pt）：
//   头部    iBalance + 刷新按钮
//   横幅    离线提示（条件显示）
//   卡片 ×4 DeepSeek / TRAE（含用量进度条）/ 千问（周%+5h 明细）/ WorkBuddy
//   设置卡片  自动签到开关 / 刷新间隔 / 小数位 / 隐藏主icon
//   操作卡片  Cockpit / 添加 WB 账号 / API Key / 千问 Ticket / 关于
//   底部    更新于 HH:mm:ss + 退出按钮
//
// v1.1：原右键菜单的全部选项搬入弹窗；右键菜单保留作为兜底。
import Cocoa

/// 面板数据快照（由 AppDelegate 从各服务缓存 + 设置状态构建）
struct PanelSnapshot {
    var ds: String?                 // DeepSeek 余额（已格式化，含货币符号）
    var dsUsedRatio: Double = 0     // DeepSeek 已用占比（0~1），基于常用充值额度计算；0=未设置不显示点阵
    var dsPulsing: Bool = false     // DeepSeek 余额被消耗（usedRatio 上升）→ 点阵脉冲
    var dsInfoText: String?         // DeepSeek 副标题文字（nil 显示默认提示）
    var traeValue: String?          // TRAE 剩余积分（当前账号）
    var traeUsed: Double = 0
    var traeLimit: Double = 0
    /// TRAE 多账号余额卡片数据（每号一条，当前账号排首位）
    var traeAccounts: [TraeAccountSnapshot] = []
    var qwWeek: String?             // 千问周剩余百分比（如 "63%"）
    var qwH5: String?               // 千问 5h 窗口剩余百分比
    var qwWeekUsedRatio: Double = 0 // 周已用占比（进度条用）
    var qwPulsing: Bool = false     // 周额度被消耗 → 点阵脉冲
    var qwExpireText: String?       // 套餐到期时间（格式：到期日: 00-00 00:00）
    /// WorkBuddy 多账号余额卡片数据（每号一条）
    var wbAccounts: [WBAccountSnapshot] = []
    var offline = false
    var updatedAt = ""
    // ── 设置/操作状态 ──
    var traeAutoCheckin = false
    var traeCheckinTime: String?    // 最近 TRAE 签到时间
    var traeCheckinDone = false     // 今日已签到
    var traeCheckinFailed = false   // 最近一次签到失败
    var traeCheckinStreak = 0       // 连续签到天数
    var traeCheckinReward = 0       // 最近一次签到积分奖励
    var wbAutoCheckin = false
    var wbCheckinDesc: String?      // 如 "2/3 12:01"
    /// 统一签到时间：TRAE / WB 最近一次签到的最晚时间（M-d HH:mm），显示在自动签到开关下方
    var lastCheckinTime: String?
    var wbOauthInProgress = false   // 添加账号进行中 → 按钮变「取消添加…」
    var refreshIntervalSeconds: Int = 300
    var deepseekDecimals = 2
    var qianwenDecimals = 1
    var hideMainIcon = true
    var hideWbNickname = true
}

/// WorkBuddy 单账号余额卡片快照
struct WBAccountSnapshot {
    var uid: String
    var nickname: String
    var value: String?              // 已格式化的剩余额度
    var usedRatio: Double = 0       // 已用占比（0~1），用于点阵进度
    var isCurrent: Bool = false     // 是否为当前登录账号（主账号 icon 全尺寸，其余 50%）
    var checkinDone: Bool = false
    var checkinFailed: Bool = false
    var streak: Int = 0
    var reward: Int = 0
    var pulsing: Bool = false       // 额度被消耗（usedRatio 上升）→ 最右亮点阵脉冲
}

/// TRAE 单账号余额卡片快照（结构对齐 WBAccountSnapshot，复用同一套卡片渲染逻辑）
struct TraeAccountSnapshot {
    var uid: String
    var nickname: String
    var value: String?              // 已格式化的剩余积分
    var usedRatio: Double = 0       // 已用占比（0~1），用于点阵进度
    var isCurrent: Bool = false     // 是否为当前登录账号（主账号 icon 全尺寸，其余 50%）
    var checkinDone: Bool = false   // 今日已签到
    var checkinFailed: Bool = false // 签到失败
    var checkinStreak: Int = 0      // 连续签到天数
    var checkinReward: Int = 0      // 签到奖励积分
    var pulsing: Bool = false       // 额度被消耗（usedRatio 上升）→ 最右亮点阵脉冲
}

/// 配色 token：集中管理所有自定义颜色，避免硬编码散落各处
private enum Palette {
    /// 卡片前景色 #DDDDDD（余额卡片 icon/标题/数值、三大分组标题统一使用）
    static let cardForeground = NSColor(calibratedRed: 0xDD/255.0, green: 0xDD/255.0, blue: 0xDD/255.0, alpha: 1)
    /// 非当前账号前景色：石墨灰（不透明）
    static let cardForegroundDimmed = NSColor(calibratedWhite: 0.5, alpha: 1.0)
    /// 卡片底色：完全透明（露出容器毛玻璃）
    static let cardBackground = NSColor.clear
    /// 卡片 hover 提亮色 #333333 @ 30%
    static let cardBackgroundHover = NSColor(calibratedWhite: 51.0 / 255.0, alpha: 0.3)
    /// 容器玻璃遮罩色（近黑半透明，加深毛玻璃底色）
    static let containerTint = NSColor(calibratedWhite: 0.02, alpha: 0.30)
    /// 卡片圆角 10pt（对齐 macOS Big Sur+ NSPopover 窗口系统圆角）
    static let cardCornerRadius: CGFloat = 10
    /// 卡片边框色/分割线色（暗主题：浅灰半透明，1px 描边，统一白@10%）
    static let cardBorderColor = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    /// 区块分割线色（与卡片边框统一）
    static let dividerColor = NSColor(calibratedWhite: 1.0, alpha: 0.10)
    /// 卡片边框宽度 1pt
    static let cardBorderWidth: CGFloat = 1
}

// 旧名兼容（逐步迁移到 Palette）
private let kBalanceForeground = Palette.cardForeground
private let kCardBackground = Palette.cardBackground
private let kCardBackgroundHover = Palette.cardBackgroundHover

/// 给 layer.backgroundColor 加 0.22s 过渡动画（hover 背景提亮/恢复）
private func animateLayerBg(_ layer: CALayer?, to color: CGColor) {
    guard let l = layer else { return }
    let anim = CABasicAnimation(keyPath: "backgroundColor")
    anim.duration = 0.22
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    anim.fromValue = l.backgroundColor
    anim.toValue = color
    l.add(anim, forKey: "backgroundColorTransition")
    l.backgroundColor = color
}

/// 与 animateLayerBg 同款过渡，但作用于 CAShapeLayer 的 fillColor（高亮框）
private func animateFillColor(_ layer: CAShapeLayer, to color: CGColor) {
    let anim = CABasicAnimation(keyPath: "fillColor")
    anim.duration = 0.15
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    anim.fromValue = layer.fillColor
    anim.toValue = color
    layer.add(anim, forKey: "fillColorTransition")
    layer.fillColor = color
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
        let miniFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        font = miniFont
        cell?.font = miniFont
        for i in 0..<segmentCount {
            setWidth(36, forSegment: i)
        }
        needsLayout = true
    }
}

/// 设置卡片行容器：hover 时仅提亮文本颜色（secondaryLabel/tertiaryLabel → labelColor），
/// switch/radio 等控件保持不变；无背景变化。光标变为 pointingHand 提示可点击。
final class HoverRowView: NSView {
    private var trackingArea: NSTrackingArea?
    private var labels: [NSTextField] = []

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
        func scan(_ v: NSView) {
            if let tf = v as? NSTextField { labels.append(tf) }
            for sub in v.subviews { scan(sub) }
        }
        scan(self)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        collectLabels()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for l in labels {
                if l.textColor == NSColor.systemGray || l.textColor == NSColor.tertiaryLabelColor {
                    l.animator().textColor = NSColor.labelColor
                }
            }
        }, completionHandler: nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for l in labels {
                if l.textColor == NSColor.labelColor {
                    l.animator().textColor = NSColor.systemGray
                }
            }
        }, completionHandler: nil)
    }

    /// hover 时光标变为 pointingHand（手指指针），提示可点击
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 无边框图标按钮：使用 macOS 原生 bezelStyle 实现 hover 时自动显示圆角背景，
/// 系统自动处理背景绘制，仅用 tracking area 管理图标颜色变化和手指光标。
/// hover 时系统渲染浅色圆角背景（略大于图标），图标同步提亮为 labelColor。
final class HoverIconButton: NSButton {
    /// 按钮容器尺寸（正方形）
    static let buttonSize: CGFloat = 22
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .recessed                  // macOS 原生凹槽按钮：hover 时自动显示圆角背景
        isBordered = true
        showsBorderOnlyWhileMouseInside = true  // 仅鼠标悬停时显示边框/背景
        imagePosition = .imageOnly              // 仅显示图标，不显示标题
        title = ""
        setButtonType(.momentaryPushIn)         // 点击时有按下效果
        imageScaling = .scaleProportionallyDown
        contentTintColor = .systemGray
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
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        contentTintColor = .systemGray
    }

    /// hover 时光标变为 pointingHand（手指指针），提示可点击
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 余额卡片容器：hover 时显示 8% 背景圆角，并切换签到信息子视图颜色。
/// 点击卡片触发 onClick 回调（如打开对应平台主页或应用）。
final class HoverCard: NSView {
    private var trackingArea: NSTrackingArea?
    /// hover 时需要提亮的签到信息 stack 列表（由外部 setInfoStacks 设置）
    private(set) var infoStacks: [NSStackView] = []
    /// 点击回调：由外部设置，mouseUp 时触发
    var onClick: (() -> Void)?
    /// hover 状态变化回调（如更新标题中昵称部分的颜色）
    var onHighlightChange: ((Bool) -> Void)?

    func setInfoStacks(_ stacks: [NSStackView]) {
        infoStacks = stacks
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // 背景：极淡白底（与操作磁贴一致）
        animateLayerBg(layer, to: NSColor.white.withAlphaComponent(0.05).cgColor)
        // 发丝边框淡入（与操作磁贴一致：0.8pt white@14%）
        animateLayerKey(layer, keyPath: "borderWidth", to: 0.8)
        onHighlightChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // 恢复透明，露出容器统一背景
        animateLayerBg(layer, to: NSColor.clear.cgColor)
        animateLayerKey(layer, keyPath: "borderWidth", to: 0)
        onHighlightChange?(false)
    }

    /// 点击卡片：mouseDown 记录按下位置，mouseUp 在 bounds 内时触发回调（避免拖出后误触）
    override func mouseDown(with event: NSEvent) {
        // 不调用 super：避免被当作无意义点击传给父视图
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) {
            onClick?()
        }
    }

    /// hover 时光标变为 pointingHand（手指指针），提示可点击
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// 切换签到信息子视图颜色：icon contentTintColor + label textColor
    /// 递归遍历 stack 内所有子视图，兼容直接子视图与嵌套 row 两种结构
    /// 用 NSAnimationContext 对 textColor/contentTintColor 做 0.22s 过渡
    private func setInfoHighlighted(_ highlighted: Bool) {
        let color = highlighted ? NSColor.labelColor : NSColor.systemGray
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for stack in infoStacks {
                applyInfoColor(to: stack, color: color)
            }
        }, completionHandler: nil)
    }

    private func applyInfoColor(to view: NSView, color: NSColor) {
        if let iv = view as? NSImageView {
            iv.animator().contentTintColor = color
        } else if let tf = view as? NSTextField {
            tf.animator().textColor = color
        }
        if let stack = view as? NSStackView {
            for sub in stack.arrangedSubviews {
                applyInfoColor(to: sub, color: color)
            }
        }
    }
}

/// 操作磁贴按钮：纵向 icon + 多行文本（最多两行），矩形带 hover 背景
final class ActionTileButton: NSView {
    private var trackingArea: NSTrackingArea?
    private var _titleText: String = ""
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// 目标-动作（与 NSButton 兼容，支持后续赋值）
    var target: AnyObject?
    var action: Selector?
    /// icon 固定尺寸
    private let iconSize: CGFloat = 18

    init(symbol: String? = nil, bundleIcon iconName: String? = nil, title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        // hover 时淡入的发丝边框（颜色预设，width 默认 0，hover 时动画到 0.5pt）
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

        setTitle(title, highlighted: false)
        // 磁贴文本最多两行且会截断，toolTip 展示完整动作名（HIG：图标类控件应有悬停提示）
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String, highlighted: Bool) {
        _titleText = title
        label.stringValue = title
        let textColor = highlighted ? NSColor.labelColor : NSColor.systemGray
        // icon 始终使用 cardForeground（#DDDDDD），高亮时不提亮（由软光晕提供层次）
        let iconColor = kBalanceForeground
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            label.animator().textColor = textColor
            iconView.animator().contentTintColor = iconColor
        }, completionHandler: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // 背景：极淡白底（更轻，留给发丝边框定义边缘层次）
        animateLayerBg(layer, to: NSColor.white.withAlphaComponent(0.05).cgColor)
        // 发丝边框淡入
        animateLayerKey(layer, keyPath: "borderWidth", to: 0.8, duration: 0.22)
        // icon 软光晕淡入
        animateLayerKey(iconView.layer, keyPath: "shadowOpacity", to: 0.45, duration: 0.22)
        setTitle(_titleText, highlighted: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        animateLayerBg(layer, to: NSColor.clear.cgColor)
        animateLayerKey(layer, keyPath: "borderWidth", to: 0, duration: 0.22)
        animateLayerKey(iconView.layer, keyPath: "shadowOpacity", to: 0.0, duration: 0.22)
        setTitle(_titleText, highlighted: false)
    }

    override func mouseDown(with event: NSEvent) {
        // 不调用 super：避免被当作无意义点击传给父视图
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) {
            _ = target?.perform(action, with: self)
        }
    }

    /// hover 时光标变为 pointingHand（手指指针），提示可点击
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 半透明遮罩视图：用 draw(_:) 而非 layer.backgroundColor 渲染色块。
/// NSView 的 backing layer 在加入 window 前可能为 nil，直接 set backgroundColor 会失效；
/// draw 由 AppKit 在确定进入渲染层级后调用，能可靠地呈现颜色。
final class TintOverlayView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let c = color { c.setFill(); NSBezierPath(rect: bounds).fill() }
    }
}

/// 带遮罩的毛玻璃容器：在 NSVisualEffectView 毛玻璃之上叠一层半透明 NSView，
/// 用 draw(_:) 渲染，保留玻璃透明质感的同时加深底色（无色相）。
final class TintedVisualEffectView: NSVisualEffectView {
    private let tintView = TintOverlayView()

    var tintColor: NSColor? {
        didSet { tintView.color = tintColor }
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

/// 手动签到结果行：状态符号 + 文本（由手动签到结果弹窗渲染）
struct CheckinResultRow {
    let text: String
    let state: CheckinRowState
}

/// 面板内容控制器：把 BalancePanelView 挂进 popover，宽度固定 245、高度自适应
final class BalancePanelViewController: NSViewController {
    private let panel: BalancePanelView

    init(panel: BalancePanelView) {
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // 让 popover 按内容实际高度撑开
        preferredContentSize = NSSize(width: 257, height: panel.fittingSize.height + 24)
    }
}

/// 圆角用量进度条（画「已用占比」，颜色由调用方按阈值设置）
final class UsageBar: NSView {
    var ratio: CGFloat = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2).fill()
        guard ratio > 0 else { return }
        let w = min(bounds.width, max(h, bounds.width * ratio))
        barColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                     xRadius: h / 2, yRadius: h / 2).fill()
    }
}

/// 环形进度：背景环 + 前景弧，中心留空显示额度值。
/// valueLabel 由外部 addArrangedSubview 加入并居中。
final class UsageRing: NSView {
    var ratio: CGFloat = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = .systemGreen { didSet { needsDisplay = true } }
    /// 环粗细（原进度条 4pt，环形缩小 1pt → 3pt）
    private let lineWidth: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        let inset = lineWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) / 2
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        // 背景环
        NSColor.quaternaryLabelColor.setStroke()
        let bg = NSBezierPath()
        bg.lineWidth = lineWidth
        bg.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        bg.stroke()
        // 前景弧：从顶部 -90° 开始顺时针，比例为 0 时绘制完整圆（兼容旧 API 语义）
        guard ratio > 0 else { return }
        let endAngle = -90 + 360 * CGFloat(ratio)
        barColor.setStroke()
        let fg = NSBezierPath()
        fg.lineWidth = lineWidth
        fg.lineCapStyle = .round
        fg.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: endAngle)
        fg.stroke()
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

final class BalancePanelView: NSView {

    // MARK: - 对外回调（由 AppDelegate 接线到现有处理逻辑）

    var onOpenCockpit: (() -> Void)?
    var onToggleAutoCheckin: (() -> Void)?
    var onAddWbAccount: (() -> Void)?
    var onSetDsQuota: (() -> Void)?           // 设置 DeepSeek 常用充值额度
    var onSetInterval: ((Int) -> Void)?          // 秒数：60 / 180 / 300
    var onToggleDsDecimals: (() -> Void)?
    var onToggleQwDecimals: (() -> Void)?
    var onSetApiKey: (() -> Void)?
    var onSetQwTicket: (() -> Void)?
    var onToggleHideIcon: (() -> Void)?
    var onToggleHideWbNickname: (() -> Void)?
    var onAbout: (() -> Void)?
    var onManualCheckin: (() -> Void)?
    var onQuit: (() -> Void)?
    // 余额卡片点击回调：DeepSeek / TRAE / WorkBuddy / 千问
    var onClickDeepSeek: (() -> Void)?
    var onClickTrae: (() -> Void)?
    var onClickWorkBuddy: (() -> Void)?
    var onClickQianwen: (() -> Void)?
    /// WorkBuddy 非当前账号卡片点击：传入 uid，触发切号重启
    var onSwitchWbAccount: ((String) -> Void)?
    /// TRAE 账号采集（菜单按钮触发）
    var onCollectTraeAccount: (() -> Void)?
    /// TRAE 非当前账号卡片点击：传入 uid，触发切号重启
    var onSwitchTraeAccount: ((String) -> Void)?

    // MARK: - 余额展示控件

    private let offlineBanner = NSTextField(labelWithString: "⚠︎ 离线，恢复网络后自动刷新")
    private let dsValueLabel = NSTextField(labelWithString: "—")
    private let dsDots = UsageDots()
    /// DeepSeek 卡片副标题标签（可更新文本，如显示日常额度信息）
    private let dsInfoLabel = NSTextField(labelWithString: "打开官网 usage 页面")
    private lazy var dsInfo: NSStackView = {
        dsInfoLabel.font = .systemFont(ofSize: 9)
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
    private let qwValueLabel = NSTextField(labelWithString: "—")
    private let qwDots = UsageDots()
    /// 千问卡片副标题标签（显示「x天后到期」，字符串前自带细空格用于与 timer icon 对齐）
    private let qwInfoLabel = NSTextField(labelWithString: "")
    private lazy var qwInfoIcon: NSImageView = {
        let v = NSImageView()
        v.image = symbolImage("timer", size: 9)
        v.contentTintColor = .systemGray
        v.imageScaling = .scaleProportionallyUpOrDown
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private lazy var qwInfo: NSStackView = {
        qwInfoLabel.font = .systemFont(ofSize: 9)
        qwInfoLabel.textColor = .systemGray
        qwInfoLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        qwInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        qwInfoLabel.setContentHuggingPriority(.required, for: .horizontal)
        qwInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [qwInfoIcon, qwInfoLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.heightAnchor.constraint(equalToConstant: 12).isActive = true
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }()
    // WorkBuddy 多账号卡片容器（动态重建，账号列表变化时刷新）
    private var wbCardsContainer: NSStackView!
    private var wbCardEntries: [WBCardEntry] = []
    private var wbCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）
    private var hideWbNickname = true   // 隐藏平台昵称（变化时只切换 nickLabel alpha，不重建卡片）
    private weak var dsCardRef: NSView?     // DeepSeek 卡片引用，WB 卡片等高用

    /// 单个 WB 卡片的控件引用（update 时直接赋值，无需重建）
    private struct WBCardEntry {
        let uid: String
        let valueLabel: NSTextField
        let dots: UsageDots
        let checkinInfo: NSStackView
        let nickLabel: NSTextField?
        var checkinKey: String = ""
    }

    // TRAE 多账号卡片容器（动态重建，账号列表变化时刷新）
    private var traeCardsContainer: NSStackView!
    private var traeCardEntries: [TraeCardEntry] = []
    private var traeCardUids: [String] = []  // 当前已渲染卡片的 uid 列表（检测变化）

    /// 单个 TRAE 卡片的控件引用（update 时直接赋值，无需重建）
    private struct TraeCardEntry {
        let uid: String
        let valueLabel: NSTextField
        let dots: UsageDots
        let checkinInfo: NSStackView   // 每张当前账号卡片独立持有，避免跨重建复用导致布局错位
        let nickLabel: NSTextField?
        var checkinKey: String = ""
    }
    private let updatedLabel = NSTextField(labelWithString: "")
    /// 刷新动效状态：true 时「更新于」区域脉冲显示「刷新中…」
    private var isRefreshing = false

    // MARK: - 设置/操作控件

    private let autoCheckinSwitch = MiniSwitch()
    private let autoCheckinSub = NSTextField(labelWithString: "")
    private let wbAddBtn = ActionTileButton(bundleIcon: "workbuddy",
                                           title: "添加账号", target: nil, action: nil)
    private let traeAddBtn = ActionTileButton(bundleIcon: "trae-color",
                                             title: "添加账号", target: nil, action: nil)
    // 刷新间隔：MiniSegmentedControl（原生 .mini 尺寸，紧凑稳定）
    private let intervalSegment: MiniSegmentedControl = {
        let seg = MiniSegmentedControl(labels: ["1分钟", "3分钟", "5分钟"], trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = 2
        return seg
    }()
    private let dsDecimalsSwitch = MiniSwitch()
    private let hideIconSwitch = MiniSwitch()
    private let hideWbNickSwitch = MiniSwitch()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 数据更新

    func update(_ s: PanelSnapshot) {
        offlineBanner.isHidden = !s.offline

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

        // 昵称开关变化：只切换 nickLabel alpha（不 rebuild 卡片，避免点阵脉冲动画被打断）
        let nickVisibilityChanged = s.hideWbNickname != hideWbNickname
        hideWbNickname = s.hideWbNickname
        if nickVisibilityChanged {
            let targetAlpha: CGFloat = hideWbNickname ? 0 : 1
            for e in traeCardEntries { e.nickLabel?.animator().alphaValue = targetAlpha }
            for e in wbCardEntries { e.nickLabel?.animator().alphaValue = targetAlpha }
        }

        // TRAE 多账号卡片：uid 列表变化 时重建，否则就地更新数据
        let newTraeUids = s.traeAccounts.map(\.uid)
        if newTraeUids != traeCardUids {
            rebuildTraeCards(s.traeAccounts)
        } else {
            applyTraeCardData(s.traeAccounts)
        }

        qwValueLabel.stringValue = s.qwWeek ?? "—"
        qwInfoLabel.stringValue = s.qwExpireText ?? ""
        if s.qwWeekUsedRatio > 0 {
            let qwRatio = CGFloat(min(1, max(0, 1 - s.qwWeekUsedRatio)))
            qwDots.ratio = qwRatio
        } else {
            qwDots.ratio = 0
        }
        qwDots.pulsing = s.qwPulsing

        // WorkBuddy 多账号卡片：uid 列表变化 时重建，否则就地更新数据
        let newUids = s.wbAccounts.map(\.uid)
        if newUids != wbCardUids {
            rebuildWbCards(s.wbAccounts)
        } else {
            applyWbCardData(s.wbAccounts)
        }

        // 刷新中时底部显示「刷新中…」并保持脉冲，刷新完成后恢复更新时间
        updatedLabel.stringValue = isRefreshing ? "刷新中…"
            : (s.updatedAt.isEmpty ? "尚未更新" : "更新于 \(s.updatedAt)")

        // ── 设置/操作状态（代码设置 state 不会触发 action，安全）──
        let autoOn = s.traeAutoCheckin || s.wbAutoCheckin
        autoCheckinSwitch.state = autoOn ? .on : .off
        // sub 显示统一签到时间（取 TRAE / WB 最近一次签到的最晚时间，格式 M-d HH:mm）
        autoCheckinSub.stringValue = s.lastCheckinTime ?? ""
        autoCheckinSub.isHidden = autoCheckinSub.stringValue.isEmpty

        wbAddBtn.setTitle(s.wbOauthInProgress ? "取消添加" : "添加账号",
                          highlighted: false)

        switch s.refreshIntervalSeconds {
        case 60: intervalSegment.selectedSegment = 0
        case 180: intervalSegment.selectedSegment = 1
        default: intervalSegment.selectedSegment = 2
        }

        dsDecimalsSwitch.state = (s.deepseekDecimals == 2) ? .on : .off
        hideIconSwitch.state = s.hideMainIcon ? .off : .on
        hideWbNickSwitch.state = s.hideWbNickname ? .off : .on
    }

    /// 重建 WorkBuddy 多账号卡片（账号列表变化时调用）
    /// 切换账号时已由点击卡片即时显示脉冲反馈，这里仅做无动画重建
    private func rebuildWbCards(_ accounts: [WBAccountSnapshot]) {
        // 清除旧卡片
        for v in wbCardsContainer.arrangedSubviews {
            wbCardsContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        wbCardEntries.removeAll()
        // 创建新卡片
        for ac in accounts {
            let valueLabel = NSTextField(labelWithString: "—")
            // 非当前账号卡片仅显示标题与额度，不显示三小项和点阵
            let isCurrent = ac.isCurrent
            let dots: UsageDots? = isCurrent ? UsageDots() : nil
            let checkinInfo: NSStackView? = isCurrent ? NSStackView() : nil
            // 昵称 label：始终创建，隐藏时 alpha=0 保留占位，避免切换时标题位置跳动
            // 颜色与签到信息一致（systemGray 石墨灰），hover 时随卡片提亮为 labelColor
            // 昵称前的间隔由 titleRow 的 spacing 控制（6pt，同签到信息三小项间距）
            let nickLabel: NSTextField = {
                let display = Self.displayNickname(ac.nickname)
                let nl = NSTextField(labelWithString: display)
                nl.textColor = isCurrent ? .systemGray : Palette.cardForegroundDimmed
                nl.alphaValue = hideWbNickname ? 0 : 1
                return nl
            }()
            // 非当前账号 icon 缩小至 12.65pt（约为大 icon 的 1/1.618），列宽不变
            let imgSize: CGFloat = isCurrent ? 20.47 : 12.65
            // 非当前账号前景色使用石墨灰，内边距加大 4pt 增加卡片高度
            let fgColor: NSColor = isCurrent ? kBalanceForeground : Palette.cardForegroundDimmed
            let cardPadTop: CGFloat = isCurrent ? 4 : 6
            let cardPadBottom: CGFloat = isCurrent ? 4 : 6
            let uid = ac.uid
            weak var cardRef: NSView?
            let card = addCard(rows: [
                balanceContentRow(icon: "workbuddy", name: "WorkBuddy", valueLabel: valueLabel,
                                  info: checkinInfo, dots: dots, iconSize: 20.47, imageSize: imgSize,
                                  iconTopAligned: !isCurrent, iconTint: fgColor, nickLabel: nickLabel,
                                  titleWeight: isCurrent ? .semibold : .regular, textColor: fgColor)
            ], to: wbCardsContainer, hoverInfos: isCurrent ? [checkinInfo!] : nil, onClick: { [weak self] in
                if isCurrent {
                    self?.onClickWorkBuddy?()
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
                        c.layer?.add(pulseAnim, forKey: "wbSwitchingPulse")
                    }
                    self?.onSwitchWbAccount?(uid)
                }
            }, onHoverChange: { _ in
                // hover 时仅切换背景色，不再改变文本颜色
            }, topPadding: cardPadTop, bottomPadding: cardPadBottom, cardBackground: nil)
            cardRef = card
            // 当前账号卡片等高于 DeepSeek；非当前账号卡片自适应内容高度（更小）
            if isCurrent, let ds = dsCardRef {
                card.heightAnchor.constraint(equalTo: ds.heightAnchor).isActive = true
            }
            // 非当前账号无 dots/checkinInfo，用占位保持 WBCardEntry 结构一致
            wbCardEntries.append(WBCardEntry(uid: ac.uid, valueLabel: valueLabel,
                                             dots: dots ?? UsageDots(), checkinInfo: checkinInfo ?? NSStackView(),
                                             nickLabel: nickLabel))
        }
        wbCardUids = accounts.map(\.uid)
        // 应用数据（valueLabel / dots / 签到信息）
        applyWbCardData(accounts)
    }

    /// 应用 WorkBuddy 卡片数据：余额、点阵、签到信息（重建后或就地刷新时调用）
    private func applyWbCardData(_ accounts: [WBAccountSnapshot]) {
        for (i, wb) in accounts.enumerated() where i < wbCardEntries.count {
            let e = wbCardEntries[i]
            e.valueLabel.stringValue = wb.value ?? "—"
            // 非当前账号卡片无 dots/checkinInfo（未加入视图层级），跳过更新
            guard wb.isCurrent else { continue }
            if wb.usedRatio > 0 {
                let remain = CGFloat(min(1, max(0, 1 - wb.usedRatio)))
                e.dots.ratio = remain
            } else {
                e.dots.ratio = 0
            }
            e.dots.pulsing = wb.pulsing
            updateCheckinInfo(e.checkinInfo, cacheKey: &wbCardEntries[i].checkinKey,
                             done: wb.checkinDone, failed: wb.checkinFailed,
                             streak: wb.streak, reward: wb.reward, fallbackReward: 100)
        }
    }

    // MARK: - TRAE 多账号卡片

    /// 重建 TRAE 多账号卡片（账号列表变化时调用）
    /// 仿 rebuildWbCards：当前账号显示签到信息 + 点阵；非当前账号仅显示 icon 标题 + 额度
    private func rebuildTraeCards(_ accounts: [TraeAccountSnapshot]) {
        // 清除旧卡片
        for v in traeCardsContainer.arrangedSubviews {
            traeCardsContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        traeCardEntries.removeAll()
        // 创建新卡片
        for ac in accounts {
            let valueLabel = NSTextField(labelWithString: "—")
            let isCurrent = ac.isCurrent
            // 当前账号显示点阵 + 签到信息；非当前账号仅显示额度
            // 每张当前账号卡片独立创建签到信息容器，避免跨重建复用共享实例导致布局错位（同 WB 逻辑）
            let dots: UsageDots? = isCurrent ? UsageDots() : nil
            let checkinInfo: NSStackView? = isCurrent ? NSStackView() : nil
            let imgSize: CGFloat = isCurrent ? 20.47 : 12.65
            let uid = ac.uid
            // 昵称 label：复用 WB 逻辑（中文取首字，颜色 systemGray 石墨灰，hover 提亮）
            // 复用 hideWbNickname 开关（语义为「隐藏平台昵称」，同时控制 TRAE 和 WB）
            let nickLabel: NSTextField = {
                let display = Self.displayNickname(ac.nickname)
                let nl = NSTextField(labelWithString: display)
                nl.textColor = isCurrent ? .systemGray : Palette.cardForegroundDimmed
                nl.alphaValue = hideWbNickname ? 0 : 1
                return nl
            }()
            // 非当前账号前景色使用石墨灰，内边距加大 4pt 增加卡片高度
            let fgColor: NSColor = isCurrent ? kBalanceForeground : Palette.cardForegroundDimmed
            let cardPadTop: CGFloat = isCurrent ? 4 : 6
            let cardPadBottom: CGFloat = isCurrent ? 4 : 6
            weak var cardRef: NSView?
            let card = addCard(rows: [
                balanceContentRow(icon: "trae-color", name: "TRAE", valueLabel: valueLabel,
                                  info: checkinInfo, dots: dots, iconSize: 20.47, imageSize: imgSize,
                                  iconTopAligned: !isCurrent, iconTint: fgColor, nickLabel: nickLabel,
                                  titleWeight: isCurrent ? .semibold : .regular, textColor: fgColor)
            ], to: traeCardsContainer, hoverInfos: isCurrent ? [checkinInfo!] : nil, onClick: { [weak self] in
                if isCurrent {
                    self?.onClickTrae?()
                } else {
                    // 切换中脉冲反馈（单一 CABasicAnimation，避免周期错乱）
                    if let c = cardRef {
                        c.wantsLayer = true
                        let pulseAnim = CABasicAnimation(keyPath: "opacity")
                        pulseAnim.fromValue = 1.0
                        pulseAnim.toValue = 0.4
                        pulseAnim.duration = 0.5
                        pulseAnim.autoreverses = true
                        pulseAnim.repeatCount = .infinity
                        pulseAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        c.layer?.add(pulseAnim, forKey: "traeSwitchingPulse")
                    }
                    self?.onSwitchTraeAccount?(uid)
                }
            }, onHoverChange: { _ in
                // hover 时仅切换背景色，不再改变文本颜色
            }, topPadding: cardPadTop, bottomPadding: cardPadBottom, cardBackground: nil)
            cardRef = card
            // 当前账号卡片等高于 DeepSeek；非当前账号卡片自适应内容高度
            if isCurrent, let ds = dsCardRef {
                card.heightAnchor.constraint(equalTo: ds.heightAnchor).isActive = true
            }
            traeCardEntries.append(TraeCardEntry(uid: ac.uid, valueLabel: valueLabel, dots: dots ?? UsageDots(), checkinInfo: checkinInfo ?? NSStackView(), nickLabel: nickLabel))
        }
        traeCardUids = accounts.map(\.uid)
        applyTraeCardData(accounts)
    }

    /// 应用 TRAE 卡片数据：余额、点阵（重建后或就地刷新时调用）
    private func applyTraeCardData(_ accounts: [TraeAccountSnapshot]) {
        for (i, ac) in accounts.enumerated() where i < traeCardEntries.count {
            let e = traeCardEntries[i]
            e.valueLabel.stringValue = ac.value ?? "—"
            // 就地更新昵称显示（用户在 TRAE 内改昵称后无需 rebuild 卡片）
            e.nickLabel?.stringValue = Self.displayNickname(ac.nickname)
            guard ac.isCurrent else { continue }
            if ac.usedRatio > 0 {
                let remain = CGFloat(min(1, max(0, 1 - ac.usedRatio)))
                e.dots.ratio = remain
            } else {
                e.dots.ratio = 0
            }
            e.dots.pulsing = ac.pulsing
            updateCheckinInfo(e.checkinInfo, cacheKey: &traeCardEntries[i].checkinKey,
                             done: ac.checkinDone, failed: ac.checkinFailed,
                             streak: ac.checkinStreak, reward: ac.checkinReward)
        }
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

    /// 单项：SF Symbol icon + 文本，中间细空格
    private func makeInfoItem(symbol: String, text: String) -> NSView {
        let iconView = NSImageView()
        iconView.image = symbolImage(symbol, size: 9)
        iconView.contentTintColor = .systemGray
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "\u{2009}\(text)")
        label.font = .systemFont(ofSize: 9, weight: .regular)
        label.textColor = .systemGray
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [iconView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        return row
    }

    /// 刷新动效：开始 → 「更新于」区域脉冲显示「刷新中…」；结束 → 停止动画（文字由 update() 恢复）。
    /// 由 AppDelegate 在 onRefresh/performRefresh 完成时调用。
    func setRefreshing(_ on: Bool) {
        guard on != isRefreshing else { return }
        isRefreshing = on
        if on {
            startPulseAnimation()
            updatedLabel.stringValue = "刷新中…"
        } else {
            stopRefreshAnimations()
            // 恢复文字交由下一次 update() 写入真实更新时间
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

    /// 昵称显示规则：中文只取第一个汉字（避免过长），非中文保留原值。
    /// rebuild 和 apply 均复用，确保改昵称后就地刷新也能正确更新显示文本。
    private static func displayNickname(_ nick: String) -> String {
        for ch in nick.unicodeScalars {
            if 0x4E00...0x9FFF ~= ch.value { return String(ch) }
        }
        return nick
    }

    // MARK: - 布局构建

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // 内在宽度 260：独立（未挂到窗口）时 fittingSize 也能解出正确高度
        widthAnchor.constraint(equalToConstant: 260).isActive = true

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
            root.widthAnchor.constraint(equalToConstant: 260 - 14),
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
        balanceGroupContainer.layer?.masksToBounds = true
        balanceGroupContainer.layer?.backgroundColor = kCardBackground.cgColor
        root.addArrangedSubview(balanceGroupContainer)
        balanceGroupContainer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── DeepSeek 卡片（中间仅标题）──
        let dsCard = addCard(rows: [
            balanceContentRow(icon: "deepseek", name: "DeepSeek", valueLabel: dsValueLabel, info: dsInfo, dots: dsDots)
        ], to: balanceGroupContainer, hoverInfos: [dsInfo], onClick: { [weak self] in self?.onClickDeepSeek?() }, topPadding: 4, bottomPadding: 4, cardBackground: nil)
        dsCardRef = dsCard
        // 平台间间隔 8pt（同平台内 trae/wb 容器内部 spacing=0 不加间隔）
        balanceGroupContainer.setCustomSpacing(8, after: dsCard)

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
        balanceGroupContainer.setCustomSpacing(8, after: traeCardsContainer)

        // ── WorkBuddy 多账号卡片容器（动态创建，账号列表变化时重建）──
        wbCardsContainer = NSStackView(views: [])
        wbCardsContainer.orientation = .vertical
        wbCardsContainer.alignment = .leading
        wbCardsContainer.distribution = .fill
        wbCardsContainer.spacing = 0
        wbCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        balanceGroupContainer.addArrangedSubview(wbCardsContainer)
        wbCardsContainer.widthAnchor.constraint(equalTo: balanceGroupContainer.widthAnchor).isActive = true
        balanceGroupContainer.setCustomSpacing(8, after: wbCardsContainer)

        // ── 千问卡片（标题 + 到期时间 + 点阵进度）──
        let qwCard = addCard(rows: [
            balanceContentRow(icon: "qwen-color", name: "千问 Token Plan", valueLabel: qwValueLabel, info: qwInfo, dots: qwDots, iconTint: .white)
        ], to: balanceGroupContainer, hoverInfos: [qwInfo], onClick: { [weak self] in self?.onClickQianwen?() }, topPadding: 4, bottomPadding: 4, cardBackground: nil)

        // 千问卡片等高于 DeepSeek（TRAE / WB 卡片动态等高，在 rebuildTraeCards / rebuildWbCards 中设置）
        qwCard.heightAnchor.constraint(equalTo: dsCard.heightAnchor).isActive = true
        // 分割线①：余额区块 → 设置区块
        root.setCustomSpacing(8, after: balanceGroupContainer)
        let divider1 = sectionDivider(in: root)
        root.setCustomSpacing(8, after: divider1)

        // ── 设置卡片 ──
        autoCheckinSwitch.target = self
        autoCheckinSwitch.action = #selector(autoCheckinToggled)
        dsDecimalsSwitch.target = self
        dsDecimalsSwitch.action = #selector(dsDecimalsToggled)
        hideIconSwitch.target = self
        hideIconSwitch.action = #selector(hideIconToggled)
        hideWbNickSwitch.target = self
        hideWbNickSwitch.action = #selector(hideWbNicknameToggled)
        // 刷新间隔行：标题 + spacer + NSSegmentedControl
        intervalSegment.target = self
        intervalSegment.action = #selector(intervalChanged)
        intervalSegment.setContentHuggingPriority(.required, for: .horizontal)
        intervalSegment.setContentHuggingPriority(.defaultLow, for: .vertical)
        intervalSegment.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let intervalLabel = NSTextField(labelWithString: "刷新时间")
        intervalLabel.font = .systemFont(ofSize: 12)
        intervalLabel.textColor = kBalanceForeground
        let intervalRow = NSStackView(views: [
            intervalLabel, stretchSpacer(), intervalSegment
        ])
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 6

        let settingRows = [
            intervalRow,
            switchRow(title: "自动签到", sub: autoCheckinSub, sw: autoCheckinSwitch),
            switchRow(title: "DeepSeek 显示 2 位小数", sub: nil, sw: dsDecimalsSwitch),
            switchRow(title: "显示平台昵称", sub: nil, sw: hideWbNickSwitch),
            switchRow(title: "显示菜单栏主图标", sub: nil, sw: hideIconSwitch),
        ].map { wrapHoverRow($0) }
        // 「设置」标题独立置于卡片上方，左对齐到卡片内标题边界（root.leading + 8）
        let settingTitle = sectionTitleRow(name: "设置")
        root.addArrangedSubview(settingTitle)
        settingTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8).isActive = true
        root.setCustomSpacing(0, after: settingTitle)
        let settingCard = addCard(rows: settingRows, to: root, spacing: 8)

        // ── 操作卡片：磁贴按钮（每行 4 个，超出换行）──
        wbAddBtn.target = self
        wbAddBtn.action = #selector(addWbAccountTapped)
        traeAddBtn.target = self
        traeAddBtn.action = #selector(addTraeAccountTapped)

        let cockpitBtn = ActionTileButton(symbol: "gauge.with.needle", title: "Cockpit", target: self, action: #selector(openCockpitTapped))
        let apiKeyBtn = ActionTileButton(bundleIcon: "deepseek", title: "配置Key", target: self, action: #selector(setApiKeyTapped))
        let actionTiles = [
            cockpitBtn,
            wbAddBtn,
            traeAddBtn,
            apiKeyBtn,
            ActionTileButton(bundleIcon: "deepseek", title: "日常额度", target: self, action: #selector(setDsQuotaTapped)),
            ActionTileButton(bundleIcon: "qwen-color", title: "千问账号", target: self, action: #selector(setQwTicketTapped)),
            ActionTileButton(symbol: "checkmark.seal", title: "手动签到", target: self, action: #selector(manualCheckinTapped)),
            ActionTileButton(symbol: "info.circle", title: "关于", target: self, action: #selector(aboutTapped)),
        ]
        // 各按钮悬停提示（HIG：图标类控件应有 tooltip）
        cockpitBtn.toolTip = "打开 Cockpit"
        wbAddBtn.toolTip = "添加 WorkBuddy 账号"
        traeAddBtn.toolTip = "添加 TRAE 账号"
        apiKeyBtn.toolTip = "配置 API Key"
        // 每个按钮固定 44×44pt，按钮间留间距，整行居中撑满
        let tileSpacing: CGFloat = 0
        for tile in actionTiles {
            tile.widthAnchor.constraint(equalToConstant: 56).isActive = true
            tile.heightAnchor.constraint(equalToConstant: 48).isActive = true
            tile.setContentHuggingPriority(.required, for: .horizontal)
            tile.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // 按每行 4 个切分，按钮间用 spacing 均匀间隔，不足 4 个的行居中排列
        let maxPerRow = 4
        let rows: [[ActionTileButton]] = stride(from: 0, to: actionTiles.count, by: maxPerRow).map {
            Array(actionTiles[$0..<min($0 + maxPerRow, actionTiles.count)])
        }
        let tileRows: [NSStackView] = rows.map { rowTiles in
            let row = NSStackView(views: rowTiles)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .equalSpacing
            row.spacing = tileSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 48).isActive = true
            return row
        }
        // 分割线②：设置区块 → 操作区块
        root.setCustomSpacing(8, after: settingCard)
        let divider2 = sectionDivider(in: root)
        root.setCustomSpacing(8, after: divider2)
        // 「操作」标题独立置于卡片上方，左对齐到卡片内标题边界（root.leading + 8）
        let actionTitle = sectionTitleRow(name: "操作")
        root.addArrangedSubview(actionTitle)
        actionTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8).isActive = true
        root.setCustomSpacing(0, after: actionTitle)
        let actionCard = addCard(rows: tileRows, to: root, spacing: 0, bottomPadding: 7)

        // 分割线③：操作区块 → footer
        root.setCustomSpacing(8, after: actionCard)
        let divider3 = sectionDivider(in: root)
        root.setCustomSpacing(8, after: divider3)

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
            quitBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -4),
            quitBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            // 容器固定 22×22（HoverIconButton.buttonSize）；使用 macOS 原生 recessed 按钮，
            // hover 时系统自动绘制圆角背景（略大于图标），符合 macOS 设计规范
            quitBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            quitBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
        ])
    }

    /// 卡片容器：NSVisualEffectView（自动适配深浅色）+ 圆角 + 内边距，宽度撑满 root。
    /// title 非空时在顶部加一行小标题；spacing 为行距（设置/操作卡片用 12，余额卡片用默认 6）。
    /// hoverInfos 非空时卡片使用 HoverCard，hover 时切换签到信息子视图颜色。
    /// onClick 非空时同样使用 HoverCard，点击卡片触发回调。
    /// bottomPadding: 卡片底部内边距（默认 7，操作卡片可减小以消除与 footer 间的空白）
    @discardableResult
    private func addCard(rows: [NSView], to root: NSStackView, title: String? = nil, spacing: CGFloat = 6, hoverInfos: [NSStackView]? = nil, onClick: (() -> Void)? = nil, onHoverChange: ((Bool) -> Void)? = nil, topPadding: CGFloat = 7, bottomPadding: CGFloat = 7, horizontalPadding: CGFloat = 8, titleColor: NSColor = .systemGray, cardBackground: NSColor? = kCardBackground) -> NSView {
        var all = rows
        if let t = title {
            all.insert(sectionTitleRow(name: t, color: titleColor), at: 0)
        }
        let stack = NSStackView(views: all)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 子行横向撑满，数值靠行内 spacer 推到右端
        all.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        // 卡片透明背景（露出 popover 原生玻璃），仅保留圆角 + 细边框区分
        // 余额卡片使用 HoverCard 获得 hover 高亮 + 点击回调；设置/操作卡片用普通 NSView
        let card: NSView
        let useHover = (hoverInfos?.isEmpty == false) || onClick != nil
        if useHover {
            let hc = HoverCard()
            if let infos = hoverInfos { hc.setInfoStacks(infos) }
            hc.onClick = onClick
            hc.onHighlightChange = onHoverChange
            card = hc
        } else {
            card = NSView()
        }
        card.wantsLayer = true
        card.layer?.cornerRadius = Palette.cardCornerRadius
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

    /// 区块分割线：1pt 高，撑满 root 宽度，使用暗主题分割色
    private func sectionDivider(in root: NSStackView) -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = Palette.dividerColor.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(line)
        // 撑满父级容器宽度（忽略 root 的左右内边距）：锚到 panel 的 leading/trailing
        if let panel = root.superview {
            line.leadingAnchor.constraint(equalTo: panel.leadingAnchor).isActive = true
            line.trailingAnchor.constraint(equalTo: panel.trailingAnchor).isActive = true
        } else {
            pinFullWidth(line, in: root)
        }
        return line
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

    /// 余额卡片内容行：左大 icon + 中间纵向（标题/签到信息）+ 右纵向（额度值/点阵）
    /// 三列撑满整行：icon 26pt / middle ≥ 70% / right 40pt
    /// 中间内容垂直居中；点阵进度放右侧额度值下方（DeepSeek 无点阵）
    private func balanceContentRow(icon iconName: String, name: String, valueLabel: NSTextField, info: NSStackView?, dots: UsageDots?, iconSize: CGFloat = 20.47, imageSize: CGFloat? = nil, iconTopAligned: Bool = false, iconTint: NSColor = kBalanceForeground, nickLabel: NSTextField? = nil, titleWeight: NSFont.Weight = .semibold, textColor: NSColor = kBalanceForeground) -> NSView {
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

        // iconContainer：撑满 row 高度，iconView 在内 centerY 居中
        // iconTopAligned=true 时小 icon 向右上偏移（右4pt、上4pt），与大 icon 顶部对齐且视觉与标题同行
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

        // 标题行：nameLabel（平台名，kBalanceForeground）+ 可选 nickLabel（昵称，systemGray 石墨灰）
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: titleWeight)
        nameLabel.textColor = textColor
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let titleRow: NSView
        if let nick = nickLabel {
            // 昵称放标题后：10pt 字号（同三小项），6pt 间距
            nick.font = .systemFont(ofSize: 10)
            nick.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nick.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // 用 firstBaseline 对齐：10pt 与 12pt 文字基线对齐，视觉居中
            let row = NSStackView(views: [nameLabel, nick])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            titleRow = row
        } else {
            titleRow = nameLabel
        }
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 额度值（固定宽 60pt，右对齐，字号 12pt semibold）
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
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
            valueLabel.trailingAnchor.constraint(equalTo: row1.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: row1.centerYAnchor),
            row1.heightAnchor.constraint(equalToConstant: 14),
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
    private func wrapHoverRow(_ row: NSView) -> HoverRowView {
        let hover = HoverRowView()
        hover.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        hover.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: hover.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: hover.trailingAnchor),
            row.topAnchor.constraint(equalTo: hover.topAnchor),
            row.bottomAnchor.constraint(equalTo: hover.bottomAnchor),
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
    ///    否则品牌色（如千问渐变）会被单色化。
    private func bundleIcon(_ name: String, size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = false
        img.size = NSSize(width: size, height: size)
        return img
    }

    // MARK: - 控件回调（转发给 AppDelegate 接线）

    @objc private func openCockpitTapped() { onOpenCockpit?() }
    @objc private func autoCheckinToggled() { onToggleAutoCheckin?() }
    @objc private func addWbAccountTapped() { onAddWbAccount?() }
    @objc private func addTraeAccountTapped() { onCollectTraeAccount?() }
    @objc private func dsDecimalsToggled() { onToggleDsDecimals?() }
    @objc private func hideIconToggled() { onToggleHideIcon?() }
    @objc private func hideWbNicknameToggled() { onToggleHideWbNickname?() }
    @objc private func setApiKeyTapped() { onSetApiKey?() }
    @objc private func setDsQuotaTapped() { onSetDsQuota?() }
    @objc private func setQwTicketTapped() { onSetQwTicket?() }
    @objc private func aboutTapped() { onAbout?() }
    @objc private func manualCheckinTapped() { onManualCheckin?() }
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
}

// Panel.swift — NSPopover 详情面板（左键点击菜单栏图标弹出）
//
// 布局（宽 240pt）：
//   头部    iBalance + 刷新按钮
//   横幅    离线提示（条件显示）
//   卡片 ×4 DeepSeek / ZCode / TRAE（含用量进度条）/ WorkBuddy
//   设置卡片  自动签到开关 / 刷新间隔 / 昵称开关 / 调试
//   操作卡片  Cockpit / 添加 WB 账号 / API Key / 关于
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
}

/// 日/周用量行快照：icon + 平台名 + 已格式化的今日/本周用量文本
struct UsageRowSnapshot {
    var platform: String
    var icon: String
    var name: String
    var todayText: String
    var weekText: String
}

/// 多号余额卡片统一快照（WorkBuddy / TRAE / ZCode 共用，复用同一套卡片渲染逻辑）。
/// 无签到平台（ZCode / Codex）的 checkin 字段保持默认；expireText 为当前账号重置/到期副标题。
struct AccountCardSnapshot {
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

/// 设置卡片行容器：hover 时仅提亮文本颜色（secondaryLabel/tertiaryLabel → labelColor），
/// switch/radio 等控件保持不变；无背景变化。光标变为 pointingHand 提示可点击。
final class HoverRowView: NSView {
    private var trackingArea: NSTrackingArea?
    private var labels: [NSTextField] = []
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
        collectLabels()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for l in labels {
                if l.textColor == NSColor.systemGray || l.textColor == NSColor.tertiaryLabelColor {
                    l.animator().textColor = NSColor.labelColor
                }
            }
            for setter in tintables { setter(NSColor.labelColor) }
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
            for setter in tintables { setter(NSColor.systemGray) }
        }, completionHandler: nil)
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
final class HoverIconButton: NSButton {
    /// 按钮容器尺寸（正方形）
    static let buttonSize: CGFloat = 22
    private var trackingArea: NSTrackingArea?

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
        contentTintColor = .labelColor
        // hover 背景：极淡白底淡入（0.22s，同全项目过渡节奏）
        animateLayerKey(layer, keyPath: "backgroundColor",
                        to: NSColor.white.withAlphaComponent(0.08).cgColor)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        contentTintColor = .systemGray
        animateLayerKey(layer, keyPath: "backgroundColor", to: NSColor.clear.cgColor)
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
class HoverCard: NSView {
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

/// 面板内容控制器：把 BalancePanelView 挂进 popover，宽度固定 245、高度自适应
final class BalancePanelViewController: NSViewController {
    /// 面板顶部暗色区域的固定高度；超过此位置后才开始向底部的渐变。
    private let panelDarkRegionHeight: CGFloat = 300
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
        // 背景纵向渐变（默认开启）：顶部保持近黑（暗）→ 底部中灰；开关关闭时恢复单色近黑
        container.tintBottomColor = panel.panelGradientEnabled ? Palette.containerTintBottom : nil
        // 容器圆角与系统 popover 窗口对齐（10pt 连续曲率），裁掉遮罩层直角边缘
        container.wantsLayer = true
        container.layer?.cornerRadius = Palette.cardCornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
        // 渐变开关状态变化（update 同步时触发）：立即刷新遮罩绘制
        panel.onPanelGradientChanged = { [weak self] in
            self?.applyGradient()
        }
        // 区块折叠/展开后按新内容高度收缩 popover（与 viewWillAppear 同一套口径），
        // 避免 preferredContentSize 固定不变时根布局把其余区块拉伸填高
        panel.onContentChanged = { [weak self] in
            guard let self else { return }
            self.panel.layoutSubtreeIfNeeded()
            self.preferredContentSize = NSSize(width: 247, height: self.panel.fittingSize.height + 24)
        }
    }

    /// 按当前开关状态刷新背景遮罩：渐变（起点=面板顶部 300pt）或单色近黑
    private func applyGradient() {
        guard let container = view as? TintedVisualEffectView else { return }
        container.tintBottomColor = panel.panelGradientEnabled ? Palette.containerTintBottom : nil
        container.tintGradientStartY = panelDarkRegionHeight
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // 让 popover 按内容实际高度撑开
        preferredContentSize = NSSize(width: 247, height: panel.fittingSize.height + 24)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 背景渐变从面板顶部固定 300pt 开始；布局变化后同步背景状态
        applyGradient()
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
    /// 渐变开关状态变化通知（update 同步时触发，VC 据此刷新遮罩绘制）
    var onPanelGradientChanged: (() -> Void)?
    var onAbout: (() -> Void)?
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
    private var isRefreshing = false

    // MARK: - 设置/操作控件

    /// 日/周用量区块：内容行动态重建（随快照变化）
    private let usageContentStack = NSStackView()
    private var usageCardRef: NSView?
    private var usageTitleRef: NSView?
    /// 平台 id → 用量行视图（拖拽排序时复用实例做位移动画）
    private var usageRowViews: [String: NSView] = [:]
    /// 表头行（今日 / 本周 列名），排序时保持在最上
    private var usageHeaderRowRef: NSView?
    /// 用量数值列宽（表头与数值行共用，保证上下对齐）
    private let usageColumnWidth: CGFloat = 56
    private let usageColumnSpacing: CGFloat = 8

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

    override init(frame frameRect: NSRect) {
        let savedOrder = UserDefaults.standard.stringArray(forKey: UDKey.balancePlatformOrder) ?? []
        platformOrder = BalancePlatform.normalizedOrder(from: savedOrder)
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 数据更新

    func update(_ s: PanelSnapshot) {
        // 渐变开关状态同步（VC 通过 onPanelGradientChanged 即时刷新遮罩绘制）
        let gradientChanged = s.panelGradientEnabled != panelGradientEnabled
        panelGradientEnabled = s.panelGradientEnabled
        gradientSwitch.state = s.panelGradientEnabled ? .on : .off
        if gradientChanged { onPanelGradientChanged?() }
        offlineBanner.isHidden = !s.offline

        // 日/周用量行重建（无数据时整个区块隐藏）
        usageContentStack.arrangedSubviews.forEach {
            usageContentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        usageRowViews.removeAll()
        usageHeaderRowRef = nil
        // 行序跟随平台卡片顺序（拖拽排序持久化于 platformOrder）
        let orderIndex = Dictionary(uniqueKeysWithValues: platformOrder.enumerated().map { ($1, $0) })
        let sortedRows = s.usageRows.sorted {
            (orderIndex[$0.platform] ?? Int.max) < (orderIndex[$1.platform] ?? Int.max)
        }
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
            rebuildZcodeCards(s.zcodeAccounts)
        } else {
            applyZcodeCardData(s.zcodeAccounts)
        }

        // Codex 多账号卡片：uid 列表变化时重建，否则就地更新
        let newCodexUids = s.codexAccounts.map(\.uid)
        if newCodexUids != codexCardUids {
            rebuildCodexCards(s.codexAccounts)
        } else {
            applyCodexCardData(s.codexAccounts)
        }

        // TRAE 多账号卡片：uid 列表变化 时重建，否则就地更新数据
        let newTraeUids = s.traeAccounts.map(\.uid)
        if newTraeUids != traeCardUids {
            rebuildTraeCards(s.traeAccounts)
        } else {
            applyTraeCardData(s.traeAccounts)
        }

        // WorkBuddy 多账号卡片：uid 列表变化 时重建，否则就地更新数据
        let newUids = s.wbAccounts.map(\.uid)
        if newUids != wbCardUids {
            rebuildWbCards(s.wbAccounts)
        } else {
            applyWbCardData(s.wbAccounts)
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
                label.font = .systemFont(ofSize: 9)
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
            l.font = .systemFont(ofSize: 9)
            l.textColor = .systemGray
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: usageColumnWidth).isActive = true
            return l
        }
        // 左列名「平台」左对齐（与下方 icon 左缘同起点），右两列列名右对齐
        let platformHeader = NSTextField(labelWithString: "平台")
        platformHeader.font = .systemFont(ofSize: 9)
        platformHeader.textColor = .systemGray
        let row = NSStackView(views: [platformHeader, stretchSpacer(), headerLabel("今日"), headerLabel("本周")])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = usageColumnSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// 日/周用量行：品牌 icon + 平台名 + 右侧两列数值（固定列宽右对齐，对齐表头）
    private func makeUsageRow(_ row: UsageRowSnapshot) -> NSView {
        let iconView = NSImageView()
        iconView.image = bundleIcon(row.icon, size: 14) ?? symbolImage("app.fill", size: 14)
        iconView.image?.isTemplate = true
        iconView.contentTintColor = kBalanceForeground
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let nameLabel = NSTextField(labelWithString: row.name)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = kBalanceForeground
        func valueLabel(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 10)
            l.textColor = .systemGray
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
        return rowStack
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
            // 底部留给独立 footer 带：0（贴底）+ 24（footer 高）+ 10（与操作区块间距）
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -34),
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
                                                 targets: { usageCollapseTargets })
        root.addArrangedSubview(usageTitle)
        pinFullWidth(usageTitle, in: root)
        root.setCustomSpacing(0, after: usageTitle)
        usageTitleRef = usageTitle
        usageContentStack.orientation = .vertical
        usageContentStack.alignment = .width
        usageContentStack.distribution = .fill
        usageContentStack.spacing = 6
        usageContentStack.translatesAutoresizingMaskIntoConstraints = false
        let usageCard = addCard(rows: [usageContentStack], to: root, spacing: 6)
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
        let actionTiles = [
            cockpitBtn,
            wbAddBtn,
            traeAddBtn,
            zcodeAddBtn,
            codexAddBtn,
            deepSeekSettingsBtn,
            checkinBtn,
            ActionTileButton(symbol: "list.bullet.rectangle", title: "签到历史", target: self, action: #selector(checkinHistoryTapped)),
            aboutBtn,
        ]
        // 各按钮悬停提示（HIG：图标类控件应有 tooltip）
        cockpitBtn.toolTip = "打开 Cockpit"
        wbAddBtn.toolTip = "添加 WorkBuddy 账号"
        traeAddBtn.toolTip = "添加 TRAE 账号"
        zcodeAddBtn.toolTip = "添加 ZCode 账号（JSON 导入）"
        codexAddBtn.toolTip = "添加 Codex 账号（JSON 导入 ~/.codex/auth.json）"
        deepSeekSettingsBtn.toolTip = "配置 DeepSeek API Key 和日常额度"
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
        // footer 不进 root：背景带单独提亮，且宽度忽略容器左右内边距擑满面板
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        footer.layer?.cornerRadius = Palette.cardCornerRadius
        footer.layer?.cornerCurve = .continuous
        footer.layer?.masksToBounds = true
        addSubview(footer)
        // 固定 footer 高度，避免子控件 intrinsicContentSize 变化时重新布局导致错位
        let footerHeight: CGFloat = 24
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            // 贴面板底边（底边距 0），底角圆角与 popover 系统圆角吻合
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerHeight),
            updatedLabel.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            updatedLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            updatedLabel.heightAnchor.constraint(lessThanOrEqualToConstant: footerHeight),
            // 背景带擑满面板但按钮对齐内容右缘（root 左右内边距 7pt）
            quitBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -7),
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
    private func collapsibleSectionTitle(name: String, key: String, targets: @escaping () -> [NSView]) -> HoverCard {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12, weight: .bold)
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
        nameLabel.font = .systemFont(ofSize: 12, weight: titleWeight)
        nameLabel.textColor = textColor
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 平台标题优先保持完整，昵称在有限空间内使用省略号。
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 12pt 字体需要略高于字号本身的行框，避免字形下沿被裁切。
        nameLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let titleRow: NSView
        if let nick = nickLabel {
            // 昵称放标题后：使用标题行剩余空间，单行尾部省略。
            nick.font = .systemFont(ofSize: 10)
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
    @objc private func setApiKeyTapped() { onSetApiKey?() }

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

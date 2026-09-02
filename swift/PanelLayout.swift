// PanelLayout.swift — iBalance
// 面板布局构建:build() 主装配 + 卡片/设置行/操作磁贴等行构建器
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 主装配      build()（面板所有区段的组装入口；改整体结构先读它）
// 卡片容器     addCard(rows:to:...)（圆角背景 + hover + 点击/右键/拖拽回调都在这挂）
// 卡片内容     balanceContentRow(...)（两行：标题+数值 / 副标题+点阵）
//              ⚠️ **卡片字号·行高·icon 列宽的数值权威就在这一个方法里**（字号走 Palette 常量）
// 设置行      switchRow(title:sub:sw:)（原生 NSSwitch 与 Mono 字符开关同框切换）
// 行包裹      wrapHoverRow（给任意行加 hover 背景 + pointingHand 光标）
// 动效        playCharBlurTransition / crossfade / staggerRiseIn / applySwitchVisuals
// 指示点      CardMenuBarDotView（菜单栏显隐圆点，按生效外观解算 cardForeground）
// 工具        symbolImage / makeFailureBadge / stretchSpacer
//            （原 refreshAnchors/syncLayout 属已删的 MenuBarFadeMask，勿再找）
//
// ⚠️ 本文件是 extension BalancePanelView = Panel.swift 同一类型拆出的「布局部分」。
//    状态与数据在 Panel.swift，行的数值在这里——改数值来这里，改状态机去 Panel.swift。

import Cocoa
import CoreImage

/// Agent 卡副标题的可用空间不足时，在右侧渐隐，避免被子账号按钮条硬截断。
private final class SubtitleFadeView: NSView {
    private let contentView: NSView
    private let fadeMask = CAGradientLayer()

    init(contentView: NSView) {
        self.contentView = contentView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        fadeMask.colors = [NSColor.white.cgColor,
                           NSColor.white.cgColor,
                           NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.72, 1]
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // 每次布局重新测量，支持副标题文本随余额刷新变长/变短。
        let shouldFade = contentView.intrinsicContentSize.width > bounds.width + 0.5
        if shouldFade {
            fadeMask.frame = bounds
            layer?.mask = fadeMask
        } else {
            layer?.mask = nil
        }
    }
}

/// 1pt 分割线：动态色（深色白@10% / 浅色黑@8%），走 draw(_:) 而非 layer
/// 背景色——CALayer 的 backgroundColor 在外观切换后不会重新解算动态色。
final class PanelSeparatorView: NSView {
    /// 线宽（pt）
    static let thickness: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 纯自绘，不要 layer（layer 背景色不跟随外观）
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.headerSeparatorColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

extension BalancePanelView {

    // MARK: - 布局构建

    /// 浮窗模式内容变化后强制 root 回到内容自然高度。
    /// NSStackView 隐藏 arranged 子视图后，链上留下可伸缩空隙；约束求解器按
    /// 「最小改动」语义不会主动收缩 root —— root 一旦因 panel 拉高（updateContentSize
    /// 把 document 撑到视口高）顶到 ≤ 上限，就会卡死在旧高度不再回落，.fill 随即把
    /// 多余高度灌进余额卡片组，卡片被拉高。这里临时解除上限做一次布局，让内容
    /// hugging 把 root 收回自然高度，再恢复上限（此时 root ≤ 上限恒成立：
    /// panel 高度 ≥ fittingSize = 自然内容 + 55）。
    func relaxRootToNaturalHeight() {
        guard let cap = rootBottomCap else { return }
        cap.isActive = false
        layoutSubtreeIfNeeded()
        cap.isActive = true
    }

    /// 布局探针：把面板关键层级高度写入 /tmp/iBalance_layout.log
    func layoutProbe(_ tag: String) {
        var parts: [String] = []
        parts.append("panel=\(String(format: "%.1f", frame.height))")
        if let r = rootViewRef {
            parts.append("root=\(String(format: "%.1f", r.frame.height))")
            let vis = r.arrangedSubviews.filter { !$0.isHidden }
            parts.append("rootChildren=" + vis.map { String(format: "%.1f", $0.frame.height) }.joined(separator: ","))
        }
        for (name, group) in [("bgc", balanceGroupContainer), ("agc", apiGroupContainer)] {
            if let g = group {
                parts.append("\(name)=\(String(format: "%.1f", g.frame.height))")
                let containers = platformCards.values
                    .compactMap { $0 as? NSStackView }
                    .filter { g.arrangedSubviews.contains($0) }
                    .sorted { $0.frame.minY < $1.frame.minY }
                for c in containers {
                    let hs = c.arrangedSubviews.filter { !$0.isHidden }
                        .map { String(format: "%.1f", $0.frame.height) }
                    if !hs.isEmpty { parts.append("[\(hs.joined(separator: ","))]") }
                }
            }
        }
        Logger.log(.layout, "[\(tag)] \(parts.joined(separator: " "))")
    }

    /// 自动测试：模拟点击折叠标题（与真实点击同一代码路径）
    func toggleSectionForAutoTest(_ section: String) {
        guard let hc = sectionTitleViews[section] else {
            Logger.log(.layout, "[AutoTest] section '\(section)' not found")
            return
        }
        Logger.log(.layout, "[AutoTest] toggle section '\(section)'")
        hc.onClick?()
    }

    func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // 宽度下限随面板宽度唯一值推导（document 宽 = VC.panelWidth − 容器缩进×2）：
        // fittingSize 在该宽度下解出内容自然高（宽度本身不再由 fittingSize 反推）。
        // 浮窗 resize 最小宽 240 由 PanelResizeHandle.minWidth 独立管理（窗口口径），与此无关。
        // 独立（未挂到窗口）时 fittingSize 也能解出高度
        widthAnchor.constraint(greaterThanOrEqualToConstant:
            BalancePanelViewController.panelWidth
                - BalancePanelViewController.contentHorizontalInset * 2).isActive = true

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.distribution = .fill
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        usageHistoryPositionAnchor.translatesAutoresizingMaskIntoConstraints = true
        usageHistoryPositionAnchor.alphaValue = 0
        addSubview(usageHistoryPositionAnchor)

        // ── 顶部 header：更新时间严格居中，和 footer 使用同一高度 ──
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        // header 背景层：与面板容器同款毛玻璃（material/遮罩配色由 VC 同步），
        // 视觉上就是面板背景本身、没有独立色块，但仍是实心的——滚动时内容
        // 从 header 下方穿过也不会透到「更新于」和按钮背后。
        headerBackdropView = TintedVisualEffectView()
        updatedLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(updatedLabel)
        let quickBuildBtn = HoverIconButton()
        quickBuildBtn.image = symbolImage("hammer", size: 11)
        quickBuildBtn.normalTintColor = Palette.panelHeaderContentColor
        quickBuildBtn.target = self
        quickBuildBtn.action = #selector(quickBuildTapped)
        quickBuildBtn.toolTip = "快速编译（后台静默执行）"
        quickBuildBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(quickBuildBtn)
        let quitBtn = HoverIconButton()
        quitBtn.image = symbolImage("power", size: 11)
        quitBtn.normalTintColor = Palette.panelHeaderContentColor
        quitBtn.hoverTintColor = .systemRed
        quitBtn.target = self
        quitBtn.action = #selector(quitTapped)
        quitBtn.toolTip = "退出 iBalance"
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(quitBtn)
        let headerSeparator = PanelSeparatorView()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerSeparator)
        let panelBarHeight: CGFloat = 20
        let panelTopPadding: CGFloat = 6
        headerView = header
        NSLayoutConstraint.activate([
            updatedLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            updatedLabel.centerYAnchor.constraint(equalTo: header.topAnchor,
                                                  constant: panelTopPadding + panelBarHeight / 2),
            updatedLabel.heightAnchor.constraint(lessThanOrEqualToConstant: panelBarHeight),
            quickBuildBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            quickBuildBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            // 距容器缘 = 容器缩进 + 正文缩进 7，与 root 内容左右缘对齐（见下方 root 约束）
            quickBuildBtn.trailingAnchor.constraint(
                equalTo: header.trailingAnchor,
                constant: -(BalancePanelViewController.contentHorizontalInset + 7)),
            quickBuildBtn.centerYAnchor.constraint(equalTo: updatedLabel.centerYAnchor),
            quitBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            quitBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            quitBtn.leadingAnchor.constraint(
                equalTo: header.leadingAnchor,
                constant: BalancePanelViewController.contentHorizontalInset + 7),
            quitBtn.centerYAnchor.constraint(equalTo: updatedLabel.centerYAnchor),
            // ── header 下缘分割线：贴 header 底边，通栏 ──
            headerSeparator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerSeparator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: PanelSeparatorView.thickness),
        ])

        NSLayoutConstraint.activate([
            // 左右正文缩进 7pt（原始口径）。满尺寸内容下被系统吃掉的左右边距带由
            // VC 容器层统一补回（BalancePanelViewController.contentHorizontalInset
            // = 9（2026-09-03 四次调整 16→8→13→9），scrollView 左右约束），9+7=16pt
            // 视觉口径，本层不重复承担边距替代。
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            // header 总高度保持 30pt；header 内部上边距不变，API 标题上方间距单独收紧 4pt。
            root.topAnchor.constraint(equalTo: topAnchor,
                                      constant: BalancePanelView.headerHeight + 4),
        // 底部用 ≤：root 顶锚、保持内容自然高度（永不被拉伸）。footer 已移出 root、
        // 单独贴 panel 底部，故 root 底部预留 footer(20)+底边距(11)+最小间隙(10)=41pt，
        // 避免与贴底 footer 重叠；浮窗拖高时多出的高度自然成为 root 与 footer 间的空白
        ])
        rootBottomCap = root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -41)
        rootBottomCap?.isActive = true
        rootViewRef = root

        // header 更新时间标签启用 layer 供脉冲动效使用
        updatedLabel.wantsLayer = true

        // ── 离线横幅 ──
        offlineBanner.font = .systemFont(ofSize: 12)
        offlineBanner.textColor = .systemOrange
        offlineBanner.isHidden = true
        root.addArrangedSubview(offlineBanner)
        pinFullWidth(offlineBanner, in: root)

        // ── API 分组标题（12pt bold + systemGray 石墨灰）+ 行尾 pin 置顶按钮 ──
        // DeepSeek/ZhiPu API 余额板块，置于面板最上；pin 随首行标题
        let apiTitle = sectionTitleRow(name: "API")
        apiTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(apiTitle)
        // 对齐到卡片内标题的左边界（root.leading + 8pt）
        apiTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8).isActive = true
        // 行撑满宽，pin 按钮贴行尾（与标题同一行）：点击切换置顶常驻
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        apiTitle.addArrangedSubview(titleSpacer)
        apiTitle.addArrangedSubview(pinBtn)
        apiTitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6).isActive = true
        // 上下间距统一 6pt（离线横幅→标题、标题→卡片）
        root.setCustomSpacing(6, after: offlineBanner)
        root.setCustomSpacing(0, after: apiTitle)

        // ── API 卡片组容器：统一 kCardBackground 背景 + 圆角，子卡片透明 ──
        let apiGroupContainer = NSStackView()
        apiGroupContainer.orientation = .vertical
        apiGroupContainer.alignment = .width
        apiGroupContainer.distribution = .fill
        apiGroupContainer.spacing = 0
        apiGroupContainer.translatesAutoresizingMaskIntoConstraints = false
        apiGroupContainer.wantsLayer = true
        apiGroupContainer.layer?.cornerRadius = Palette.cardCornerRadius
        apiGroupContainer.layer?.cornerCurve = .continuous
        apiGroupContainer.layer?.masksToBounds = true
        apiGroupContainer.layer?.backgroundColor = kCardBackground.cgColor
        self.apiGroupContainer = apiGroupContainer
        root.addArrangedSubview(apiGroupContainer)
        apiGroupContainer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // ── DeepSeek 单账号卡片容器（动态创建，走多号卡片管线；置于 API 组首位）──
        dsCardsContainer = NSStackView(views: [])
        dsCardsContainer.orientation = .vertical
        dsCardsContainer.alignment = .leading
        dsCardsContainer.distribution = .fill
        dsCardsContainer.spacing = 0
        dsCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        apiGroupContainer.addArrangedSubview(dsCardsContainer)
        pinPlatformWidth(dsCardsContainer, in: apiGroupContainer)
        platformCards[BalancePlatform.deepSeek.rawValue] = dsCardsContainer
        // 平台间间隔 4pt（同平台内各容器内部 spacing=0 不加间隔）
        apiGroupContainer.setCustomSpacing(4, after: dsCardsContainer)

        // ── ZhiPu 单账号卡片容器（智谱 BigModel，同 DS 管线；置于 DeepSeek 卡片下方）──
        zhipuCardsContainer = NSStackView(views: [])
        zhipuCardsContainer.orientation = .vertical
        zhipuCardsContainer.alignment = .leading
        zhipuCardsContainer.distribution = .fill
        zhipuCardsContainer.spacing = 0
        zhipuCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        apiGroupContainer.addArrangedSubview(zhipuCardsContainer)
        pinPlatformWidth(zhipuCardsContainer, in: apiGroupContainer)
        platformCards[BalancePlatform.bigModel.rawValue] = zhipuCardsContainer
        apiGroupContainer.setCustomSpacing(4, after: zhipuCardsContainer)

        // ── Qwen 单账号卡片容器（千问 Token Plan 周额度，同 DS 管线；置于 ZhiPu 卡片下方）──
        qwenCardsContainer = NSStackView(views: [])
        qwenCardsContainer.orientation = .vertical
        qwenCardsContainer.alignment = .leading
        qwenCardsContainer.distribution = .fill
        qwenCardsContainer.spacing = 0
        qwenCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        apiGroupContainer.addArrangedSubview(qwenCardsContainer)
        pinPlatformWidth(qwenCardsContainer, in: apiGroupContainer)
        platformCards[BalancePlatform.qwen.rawValue] = qwenCardsContainer
        apiGroupContainer.setCustomSpacing(4, after: qwenCardsContainer)

        // API 区块 → Agent 区块（分割线已移除，用区块间距分隔）
        root.setCustomSpacing(10, after: apiGroupContainer)

        // ── Agent 分组标题（原「余额」板块改名；ZCode/Codex/TRAE/WB 等 Agent 平台）──
        let balanceTitle = sectionTitleRow(name: "Agent")
        balanceTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(balanceTitle)
        // 对齐到卡片内标题的左边界（root.leading + 8pt）
        balanceTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8).isActive = true
        root.setCustomSpacing(0, after: balanceTitle)

        // ── Agent 卡片组容器：统一 kCardBackground 背景 + 圆角，子卡片透明 ──
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

        // ── ZCode 多账号卡片容器（动态创建，账号列表变化时重建）──
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
        pinPlatformWidth(zcodeCardsContainer)
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
        pinPlatformWidth(codexCardsContainer)
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
        pinPlatformWidth(traeCardsContainer)
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
        pinPlatformWidth(wbCardsContainer)
        platformCards[BalancePlatform.workBuddy.rawValue] = wbCardsContainer
        balanceGroupContainer.setCustomSpacing(4, after: wbCardsContainer)

        // 应用上次拖拽保存的平台顺序；隐藏的账号组仍保留位置，之后重新出现时顺序不跳变。
        // 须在两组容器都建好后调用：重排按组内过滤进行
        applyPlatformOrder(animated: false)

        // Agent 区块 → Token 板块（分割线已移除，用区块间距分隔）
        root.setCustomSpacing(10, after: balanceGroupContainer)

        // ── Token 板块（内嵌 ZCode / WorkBuddy 卡片 hover 子面板同款内容，单实例，
        // 只显示 Agent 组最顶上平台的 Token；可折叠。顶部平台无 Token 数据源或无数据时整块隐藏）──
        var tokenCollapseTargets: [NSView] = []
        let tokenTitle = collapsibleSectionTitle(name: "Token", key: UDKey.tokenSectionCollapsed,
                                                 targets: { tokenCollapseTargets })
        root.addArrangedSubview(tokenTitle)
        pinFullWidth(tokenTitle, in: root)
        root.setCustomSpacing(0, after: tokenTitle)
        tokenTitleRef = tokenTitle
        sectionTitleViews["token"] = tokenTitle
        tokenContentStack.orientation = .vertical
        tokenContentStack.alignment = .width
        tokenContentStack.distribution = .fill
        tokenContentStack.spacing = 0
        tokenContentStack.translatesAutoresizingMaskIntoConstraints = false
        // 内容视图撑满版心（宽随卡片），自身左右缩进 8 对齐其他板块；热力图按实际宽
        // 等比放大，所有字号不变
        let tokenCard = addCard(rows: [tokenContentStack], to: root, spacing: 6, topPadding: 2,
                                bottomPadding: 2, horizontalPadding: 0)
        tokenCardRef = tokenCard
        tokenCollapseTargets = [tokenCard]
        // 初始隐藏：数据异步到达后由 applyInlineTokensVisibility 统一裁决显隐（含折叠态）
        tokenCard.isHidden = true
        tokenTitle.isHidden = true
        // Token 板块 → 用量区块
        root.setCustomSpacing(10, after: tokenCard)
        // 填充内嵌内容并启动低频刷新（数据源 60s 后台缓存，fetch 只回缓存零读取）
        setupInlineTokens()

        // ── 日/周用量区块（可折叠；行内容随快照重建）──
        var usageCollapseTargets: [NSView] = []
        let usageTitle = collapsibleSectionTitle(name: "用量", key: UDKey.usageSectionCollapsed,
                                                 targets: { usageCollapseTargets })
        root.addArrangedSubview(usageTitle)
        pinFullWidth(usageTitle, in: root)
        root.setCustomSpacing(0, after: usageTitle)
        usageTitleRef = usageTitle
        sectionTitleViews["usage"] = usageTitle
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
        gradientSwitch.target = self
        gradientSwitch.action = #selector(panelGradientToggled)
        lightThemeSwitch.target = self
        lightThemeSwitch.action = #selector(lightThemeToggled)
        monoSwitch.target = self
        monoSwitch.action = #selector(monoFontToggled)
        valuePreviewSwitch.target = self
        valuePreviewSwitch.action = #selector(valueScrollPreviewToggled)
        statusDebugSwitch.target = self
        statusDebugSwitch.action = #selector(statusDebugPreviewToggled)
        updateAutoSwitch.target = self
        updateAutoSwitch.action = #selector(updateAutoCheckToggled)
        // 刷新间隔行：标题 + 手动刷新按钮 + spacer + 原生下拉菜单
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        intervalPopup.setContentHuggingPriority(.required, for: .horizontal)
        intervalPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        let intervalLabel = NSTextField(labelWithString: "刷新时间")
        intervalLabel.font = .systemFont(ofSize: 12)
        intervalLabel.textColor = Palette.cardForeground
        // label 压缩阻力提到 required：行空间不足时优先让其它视图让步，label 永远不被压窄
        intervalLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 手动刷新按钮：arrow.clockwise 图标，石墨灰（systemGray），size 10（小于选项文本 12pt，更紧凑）。
        // 点击时图标顺时针旋转一圈（RefreshIconButton 内部 sendAction 触发）。
        // hover 时按钮自绘圆形白@8% 背景 + 图标 tint 提亮（16×16 容器），
        // 仅自身 hover 生效；行 hover 不驱动任何提亮（见下方 enablesTextBrightening = false）。
        // 视觉整体向左下偏移 1pt（与设置行文字基线对齐微调），容器/命中区不动。
        let manualRefreshBtn = RefreshIconButton()
        manualRefreshBtn.image = symbolImage("arrow.clockwise", size: 10)
        manualRefreshBtn.target = self
        manualRefreshBtn.action = #selector(manualRefreshTapped)
        // 固定 16×16 方形容器（与设置行高一致）：撑起圆形 hover 背景的绘制区域
        manualRefreshBtn.widthAnchor.constraint(equalToConstant: 16).isActive = true
        manualRefreshBtn.heightAnchor.constraint(equalToConstant: 16).isActive = true
        manualRefreshBtn.setContentHuggingPriority(.required, for: .horizontal)
        manualRefreshBtn.setContentHuggingPriority(.defaultLow, for: .vertical)
        manualRefreshBtn.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let intervalRow = NSStackView()
        intervalRow.orientation = .horizontal
        intervalRow.distribution = .fill
        intervalRow.alignment = .centerY
        intervalRow.spacing = 6
        // spacer 吃掉按钮后的剩余空白，下拉菜单贴行尾（原生控件自身命中区即可）
        intervalRow.setViews([intervalLabel, manualRefreshBtn, stretchSpacer(), intervalPopup], in: .leading)

        let settingRows = [
            intervalRow,
            switchRow(title: "自动签到", sub: autoCheckinSub, sw: autoCheckinSwitch),
            switchRow(title: "面板渐变背景", sub: nil, sw: gradientSwitch),
            switchRow(title: "浅色主题", sub: nil, sw: lightThemeSwitch),
            switchRow(title: "Mono 风格", sub: nil, sw: monoSwitch),
            // 「滚动预览」暂时隐藏（2026-08-28）：恢复时把 switchRow 加回此处，
            // 并同步恢复下方 valuePreviewSub.isHidden = false
            // switchRow(title: "滚动预览", sub: valuePreviewSub, sw: valuePreviewSwitch),
            switchRow(title: "状态调试", sub: statusDebugSub, sw: statusDebugSwitch),
            switchRow(title: "自动检查更新", sub: nil, sw: updateAutoSwitch),
        ].map {
            let hover = wrapHoverRow($0)
            // 行 hover 不提亮小字与图标 tint：小字保持常态颜色，
            // 刷新按钮仅自身 hover 时提亮（RefreshIconButton 内部处理）
            hover.enablesTextBrightening = false
            return hover
        }
        // 副标题默认隐藏（switchRow 内统一设置），静态文案行直接显示
        // valuePreviewSub.isHidden = false
        statusDebugSub.isHidden = false
        // 「设置」标题：可折叠标题条（hover 余额卡片样式，点击折叠整个设置卡片）
        var settingCollapseTargets: [NSView] = []
        let settingTitle = collapsibleSectionTitle(name: "设置", key: UDKey.settingsSectionCollapsed,
                                                    targets: { settingCollapseTargets })
        root.addArrangedSubview(settingTitle)
        pinFullWidth(settingTitle, in: root)
        root.setCustomSpacing(0, after: settingTitle)
        sectionTitleViews["settings"] = settingTitle
        let settingCard = addCard(rows: settingRows, to: root, spacing: 8)
        // 折叠目标接线 + 初始态（内容隐藏与标题下间距，展开时间距 0 贴卡片）
        settingCollapseTargets = [settingCard]
        let settingsCollapsed = UserDefaults.standard.bool(forKey: UDKey.settingsSectionCollapsed)
        settingCard.isHidden = settingsCollapsed
        root.setCustomSpacing(settingsCollapsed ? 6 : 0, after: settingTitle)
        // 设置卡片初始开关外观（Mono 开启时直接以字符开关呈现，避免启动瞬间闪原生开关）
        applySwitchVisuals(animated: false)

        // ── 操作卡片：磁贴按钮（每行 4 个，超出换行）──
        wbAddBtn.target = self
        wbAddBtn.action = #selector(addWbAccountTapped)
        traeAddBtn.target = self
        traeAddBtn.action = #selector(addTraeAccountTapped)
        zcodeAddBtn.target = self
        zcodeAddBtn.action = #selector(addZcodeAccountTapped)
        // Codex 操作按钮图标与余额卡片保持同样的 5% 缩放口径。
        let codexAddBtn = ActionTileButton(bundleIcon: "codex", title: "添加账号", target: self, action: #selector(addCodexAccountTapped), svgIconSize: 16.05)
        checkinBtn.target = self
        checkinBtn.action = #selector(manualCheckinTapped)
        wbShareBtn.target = self
        wbShareBtn.action = #selector(shareWbHistoryTapped)

        let cockpitBtn = ActionTileButton(symbol: "gauge.with.needle", title: "Cockpit", target: self, action: #selector(openCockpitTapped))
        // Key/额度磁贴：DeepSeek + ZhiPu 设置弹窗统一入口，icon 用 SF Symbol 钥匙
        let deepSeekSettingsBtn = ActionTileButton(symbol: "key.fill", title: "Key / 额度", target: self, action: #selector(setApiKeyTapped))
        let aboutBtn = ActionTileButton(symbol: "info.circle", title: "关于", target: self, action: #selector(aboutTapped))
        let platformTogglesBtn = ActionTileButton(symbol: "circle.grid.2x2.topleft.checkmark.filled", title: "平台开关", target: self, action: #selector(platformTogglesTapped))
        let checkUpdateBtn = ActionTileButton(symbol: "arrow.down.circle", title: "检查更新", target: self, action: #selector(checkUpdateTapped))
        let actionTiles = [
            cockpitBtn,
            wbAddBtn,
            traeAddBtn,
            zcodeAddBtn,
            codexAddBtn,
            deepSeekSettingsBtn,
            checkinBtn,
            ActionTileButton(symbol: "list.bullet.rectangle", title: "签到历史", target: self, action: #selector(checkinHistoryTapped)),
            wbShareBtn,
            platformTogglesBtn,
            checkUpdateBtn,
            aboutBtn,
        ]
        // 各按钮悬停提示（HIG：图标类控件应有 tooltip）
        cockpitBtn.toolTip = "打开 Cockpit"
        wbAddBtn.toolTip = "添加 WorkBuddy 账号"
        traeAddBtn.toolTip = "添加 TRAE 账号"
        zcodeAddBtn.toolTip = "添加 ZCode 账号（JSON 导入）"
        codexAddBtn.toolTip = "添加 Codex 账号（JSON 导入 ~/.codex/auth.json）"
        deepSeekSettingsBtn.toolTip = "配置 DeepSeek API Key、日常额度与 ZhiPu Token"
        wbShareBtn.toolTip = "将全部历史会话与记忆同步给当前登录的 WorkBuddy 账号（切换账号后可再次执行）"
        platformTogglesBtn.toolTip = "管理各平台刷新、自动签到、卡片与用量显示开关"
        checkUpdateBtn.toolTip = "检查 GitHub Releases 上的新版本（发现后可直接更新重启）"
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
        sectionTitleViews["actions"] = actionTitle
        // App 宫格样式：行内容器内靠左（不满一行的末行也靠左），整个容器在卡片内水平居中；
        // 左右内边距 0（容器宽 220 ≤ 内容宽 236），行间垂直间距 4pt
        let tilesContainer = NSStackView(views: tileRows)
        tilesContainer.orientation = .vertical
        tilesContainer.alignment = .leading
        tilesContainer.distribution = .fill
        tilesContainer.spacing = 4
        tilesContainer.translatesAutoresizingMaskIntoConstraints = false
        let actionCard = addCard(rows: [tilesContainer], to: root, bottomPadding: 3, horizontalPadding: 0, stretchRows: false, centerRows: true)

        // 操作区块 → footer（分割线已移除，用区块间距分隔）
        root.setCustomSpacing(10, after: actionCard)
        // 折叠目标接线 + 初始态
        actionCollapseTargets = [actionCard]
        let actionsCollapsed = UserDefaults.standard.bool(forKey: UDKey.actionsSectionCollapsed)
        actionCard.isHidden = actionsCollapsed
        root.setCustomSpacing(actionsCollapsed ? 6 : 0, after: actionTitle)

        // ── 底部：退出按钮（贴右）──
        // pin 按钮（挂 API 标题行尾，面板首行标题）：属性在此配置，布局见 apiTitle 段
        pinBtn.image = symbolImage("pin", size: 11)
        pinBtn.target = self
        pinBtn.action = #selector(pinTapped)
        pinBtn.toolTip = "置顶面板（置顶后可自由拖动）"
        // 拖动示意条：固定在 header 上方留白带内居中
        header.addSubview(dragGrabber)
        dragGrabber.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dragGrabber.widthAnchor.constraint(equalToConstant: 36),
            dragGrabber.heightAnchor.constraint(equalToConstant: 4),
            dragGrabber.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            dragGrabber.topAnchor.constraint(equalTo: header.topAnchor, constant: panelTopPadding + 3),
        ])

        updatedLabel.font = .systemFont(ofSize: 9, weight: .regular)
        updatedLabel.textColor = Palette.panelHeaderContentColor
        let githubBtn = HoverIconButton()
        if let githubImage = bundleIcon("github", size: 11) {
            githubImage.isTemplate = true
            githubBtn.image = githubImage
        } else {
            githubBtn.image = symbolImage("globe", size: 11)
        }
        githubBtn.normalTintColor = Palette.panelHeaderContentColor
        githubBtn.target = self
        githubBtn.action = #selector(openGitHubTapped)
        githubBtn.toolTip = "打开 iBalance GitHub 项目"
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        githubBtn.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(githubBtn)
        // footer 移出 root、直接挂 panel 并贴底：root 用 ≤ 底约束保持内容自然高度
        // （永不被拉伸），浮窗拖高时多出的高度成为 root 与 footer 间的空白，footer 始终贴底。
        // 宽度与 root 对齐（左右各内缩 7pt 正文缩进；容器层缩进由 VC scrollView
        // 统一表达，不在此重复），底部留 11pt 边距
        addSubview(footer)
        // 固定 footer 高度，避免子控件 intrinsicContentSize 变化时重新布局导致错位
        NSLayoutConstraint.activate([
            footer.heightAnchor.constraint(equalToConstant: panelBarHeight),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            githubBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            githubBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            // 容器固定 22×22（HoverIconButton.buttonSize）；无边框按钮，
            // hover 时自绘大圆角淡白背景（圆角与卡片统一）
            githubBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            githubBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
        ])
    }

    /// 卡片容器：NSVisualEffectView（自动适配深浅色）+ 圆角 + 内边距，宽度撑满 root。
    /// title 非空时在顶部加一行小标题；spacing 为行距（设置/操作卡片用 12，余额卡片用默认 6）。
    /// 有点击、右键或拖拽回调时卡片使用 HoverCard；设置/操作卡片用普通 NSView。
    /// bottomPadding: 卡片底部内边距（默认 7，操作卡片可减小以消除与 footer 间的空白）
    @discardableResult
    func addCard(rows: [NSView], to root: NSStackView, title: String? = nil, spacing: CGFloat = 6, onClick: (() -> Void)? = nil, onRightClick: ((NSEvent) -> Void)? = nil, onDragStarted: ((NSPoint) -> Void)? = nil, onDragChanged: ((NSPoint) -> Void)? = nil, onDragEnded: (() -> Void)? = nil, topPadding: CGFloat = 7, bottomPadding: CGFloat = 7, horizontalPadding: CGFloat = 8, trailingPadding: CGFloat? = nil, titleColor: NSColor = .systemGray, cardBackground: NSColor? = kCardBackground, stretchRows: Bool = true, centerRows: Bool = false, hoverGradientOverride: [NSColor]? = nil) -> NSView {
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
            // 强背景必须在卡片加入面板层级前配置，避免初始化阶段的默认 60° 渐变
            // 被首次 layout / display / 拖拽截图捕获。
            hc.hoverGradientOverride = hoverGradientOverride
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
        card.layer?.borderColor = Palette.borderCGColor(Palette.hoverBorderNormal, in: card)
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
            // trailingPadding 独立档（nil = 跟随 horizontalPadding）：余额卡片右缩进单独收紧
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                            constant: -(trailingPadding ?? horizontalPadding)),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: topPadding),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -bottomPadding),
            card.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        return card
    }

    /// 分组标题行：标题，13pt semibold + systemGray（石墨灰），左对齐，固定行高 24pt
    private func sectionTitleRow(name: String, color: NSColor = .systemGray) -> NSStackView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = color
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    /// 可折叠区块标题条：hover 复用余额卡片样式（HoverCard hover 背景色+0.8pt 发丝边框），
    /// 点击切换折叠并持久化（UserDefaults，key 走 UDKey）。整条撑满 root 宽：
    /// 标题文字左对齐余额标题（内边距 8），箭头（▸ 折叠 / ▾ 展开）靠右贴卡片内边界。
    /// targets 闭包返回随折叠一起隐藏的视图（build 在区块内容创建后才会填充，闭包按引用取最新值）；
    /// 初始折叠态由 build 在填完 targets 后自行应用（isHidden + 间距）。
    private func collapsibleSectionTitle(name: String, key: String,
                                         targets: @escaping () -> [NSView]) -> HoverCard {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
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
        hc.layer?.borderColor = Palette.borderCGColor(Palette.hoverBorderNormal, in: hc)
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

    /// 品牌「macOS 27 ClearDark」图标资产（ictool 从 *.icon 源包预导出的 PNG，
    /// macOS 平台 ClearDark rendition 256@1x，--design-generation 27 设计语言）。
    /// Icon Composer 的 .icon 源包 NSImage 无法运行时加载、也无公开变体选择 API，
    /// 故构建期按 rendition 导出 PNG 随 Resources 分发；保持原色非 template。
    /// 表里没有的条目（资产缺失，如旧 bundle）由调用方回退 SVG template。
    /// 键 = CardStyle.icon 图标名；ZCode 与 ZhiPu 共用 "zhipu" 品牌图标名，两卡同时生效。
    private static let brandClearDarkImages: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        // 资产统一按「平台名.png」命名（macOS27 ClearDark 256@1x 重导出）；
        // 键名与资源名不一致的仅两处：ZCode/ZhiPu 共用 "zhipu"、TRAE 卡 icon 名为 "trae-color"。
        for (iconName, resource) in [
            "workbuddy": "workbuddy",
            "zhipu": "zcode",
            "deepseek": "deepseek",
            "qwen": "qwen",
            "trae-color": "trae",
            "codex": "codex",
        ] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
                  let img = NSImage(contentsOf: url) else { continue }
            img.isTemplate = false
            images[iconName] = img
        }
        return images
    }()

    /// 余额卡片内容行：左大 icon + 中间纵向（标题/签到信息）+ 右纵向（额度值/点阵）
    /// 三列撑满整行：icon 24pt（2026-08-31 全平台统一） / middle ≥ 70% / right 40pt
    /// 中间内容垂直居中；点阵进度放右侧额度值下方（DeepSeek 无点阵）
    /// failureBadge：外部创建的签到失败角标视图，叠加在 icon 右上角（显隐由调用方控制）
    func balanceContentRow(icon iconName: String, name: String, valueView: RollingNumberView, info: NSStackView?, dots: UsageDots?, iconSize: CGFloat = 24, imageSize: CGFloat? = nil, iconTint: NSColor = Palette.cardForeground, nickLabel: NSTextField? = nil, titleWeight: NSFont.Weight = .semibold, valueWeight: NSFont.Weight = .medium, textColor: NSColor = Palette.cardForeground, failureBadge: NSView? = nil, premadeIconView: NSImageView? = nil, hoverSubStrip: NSView? = nil, valuePrefixIcon: String? = nil, titleLabelRef: ((FadeableTextField) -> Void)? = nil, menuBarDotRef: ((NSView) -> Void)? = nil, statusRingRef: ((CardTaskStatusRingView) -> Void)? = nil) -> NSView {
        var imgSize = imageSize ?? iconSize
        // 左：大 icon（统一图标列宽 = 25pt，2026-09-01 用户指定；
        // 约束写死不随 iconSize 变；image 在列内居中显示，imageSize 可独立缩小）；
        // premadeIconView 由外部传入（多号卡片预建 icon 视图，普通 NSImageView 即可）
        let iconView = premadeIconView ?? NSImageView()
        // 品牌卡特例（WorkBuddy / ZCode+ZhiPu / DeepSeek）：macOS 26 ClearDark 品牌图（整图自带配色，保持原色非 template 不着色）
        if let clearDark = Self.brandClearDarkImages[iconName] {
            let scaled = clearDark.copy() as! NSImage
            scaled.size = NSSize(width: imgSize, height: imgSize)
            iconView.image = scaled
        } else {
            iconView.image = bundleIcon(iconName, size: imgSize) ?? symbolImage("app.fill", size: imgSize)
            iconView.image?.isTemplate = true
            iconView.contentTintColor = iconTint
        }
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // iconContainer：撑满 row 高度，iconView 在内 centerY 居中。
        // 拖拽由外层 HoverCard 接管，因此整张卡片而非仅 icon 可触发排序。
        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        if let ringRef = statusRingRef {
            // 任务状态发光底层（WB / ZCode 当前账号卡）：撑满 iconContainer（尽可能大），
            // icon 叠加其上居中；menuBarDot / 失败角标仍锚定 iconView，位置不变
            let ring = CardTaskStatusRingView()
            ring.translatesAutoresizingMaskIntoConstraints = false
            iconContainer.addSubview(ring)
            iconContainer.addSubview(iconView)
            NSLayoutConstraint.activate([
                ring.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
                ring.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
                ring.topAnchor.constraint(equalTo: iconContainer.topAnchor),
                ring.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
                iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
                // 统一图标列宽（不再随各平台 iconSize 变化）：所有卡标题严格左对齐
                iconContainer.widthAnchor.constraint(equalToConstant: 25),
            ])
            ringRef(ring)
        } else {
            iconContainer.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
                // 统一图标列宽（不再随各平台 iconSize 变化）：所有卡标题严格左对齐；
                // 各图标视觉尺寸差异（SVG 留白不同）由 CardStyle.iconSize 单独补偿
                iconContainer.widthAnchor.constraint(equalToConstant: 25),
                iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            ])
        }

        // 菜单栏显隐指示点：icon 底边下方 2pt，居中；显示在菜单栏时由调用方点亮（syncPanel）。
        // 直径 3.6pt 圆点，cardForeground 跟随卡片前景色（2026-08-31 用户要求弃用白色）；
        // 颜色由 CardMenuBarDotView 在 layout 时按生效外观解算（动态色直落 .cgColor 会定格外观）
        let menuBarDot = CardMenuBarDotView()
        menuBarDot.translatesAutoresizingMaskIntoConstraints = false
        menuBarDot.isHidden = true
        iconContainer.addSubview(menuBarDot)
        NSLayoutConstraint.activate([
            menuBarDot.widthAnchor.constraint(equalToConstant: 3.2),
            menuBarDot.heightAnchor.constraint(equalToConstant: 3.2),
            menuBarDot.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            menuBarDot.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
        ])
        menuBarDotRef?(menuBarDot)

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

        // 标题行：nameLabel（平台名，Palette.cardForeground）+ 可选 nickLabel（昵称，systemGray 石墨灰）
        // FadeableTextField：wantsLayer 承载 hover 字重动画
        let nameLabel = FadeableTextField(labelWithString: name)
        registerFont(nameLabel, size: Palette.cardTitleFontSize, weight: titleWeight)
        nameLabel.textColor = textColor
        // 暴露 nameLabel 给调用方（如 hover 字重动画驱动）
        titleLabelRef?(nameLabel)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 平台标题优先保持完整，昵称在有限空间内使用省略号
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 13pt 字体需要略高于字号本身的行框（+3），避免字形下沿被裁切。
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
            // 与多账号卡同构：空 stack 包裹（裸 nameLabel 直接挂行实测起点偏 -2pt，
            // stack 包裹后与 WB/TRAE 等卡起点一致）
            let row = NSStackView(views: [nameLabel])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            titleRow = row
        }
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 额度值（右对齐，13pt semibold；逐位数字垂直滚动 RollingNumberView），
        // 与标题冲突时数值优先（required），标题尾部省略；
        // 基线对齐用视图内置探针（同字体隐藏 label 的 firstBaselineAnchor）
        registerRollingNumber(valueView, size: 13, weight: valueWeight)
        valueView.setTextColor(textColor)
        // 数值前缀图标（Agent 卡积分前的 coin）：贴数字左侧、随槽位右对齐成组。
        // 按常规态边长烘焙（2× 光栅），chip 态由视图缩小绘制，离开 hover 无损复原
        if let pfx = valuePrefixIcon {
            valueView.prefixIcon = Self.trimmedBundleSvgIcon(pfx, size: RollingNumberView.baseIconSize)
        }
        valueView.setContentHuggingPriority(.required, for: .horizontal)
        valueView.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueView.translatesAutoresizingMaskIntoConstraints = false
        valueView.widthAnchor.constraint(equalToConstant: 65).isActive = true

        // 第一行：标题（左）+ 数值（右）同一行
        // 用普通 NSView + 显式约束，避免 NSStackView gravity 分布歧义
        let row1 = NSView()
        row1.translatesAutoresizingMaskIntoConstraints = false
        row1.addSubview(titleRow)
        row1.addSubview(valueView)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: row1.leadingAnchor),
            titleRow.firstBaselineAnchor.constraint(equalTo: valueView.baselineAnchor),
            // 昵称行允许向数值区多占 12pt（-4 → +8）：为昵称尾部签到徽章
            //（10pt 图标 + 薄空格）预留显示空间；数值右对齐（右锚 bounds-2.5），
            // 常规数值宽度下左侧有富余，不会与数字字形重叠
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: valueView.leadingAnchor,
                                               constant: nickLabel != nil ? 8 : -4),
            // 数值容器右锚 +0.7pt（2026-09-02 用户要求向右偏移，视觉更贴卡片内边界）
            valueView.trailingAnchor.constraint(equalTo: row1.trailingAnchor, constant: 0.7),
            valueView.centerYAnchor.constraint(equalTo: row1.centerYAnchor),
            row1.heightAnchor.constraint(equalToConstant: 16),
        ])

        // 第二行：小项目（左）+ 点阵（右）同一行
        // 用普通 NSView + 显式约束，避免 NSStackView gravity 分布歧义
        // 点阵高度与小项目字号（9pt）等高，视觉对齐
        let row2 = NSView()
        row2.translatesAutoresizingMaskIntoConstraints = false
        var row2HasContent = false
        var subtitleFadeView: SubtitleFadeView?
        if let info = info {
            info.setContentHuggingPriority(.required, for: .horizontal)
            info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            info.translatesAutoresizingMaskIntoConstraints = false
            let subtitle = hoverSubStrip == nil ? nil : SubtitleFadeView(contentView: info)
            subtitleFadeView = subtitle
            let subtitleView = subtitle ?? info
            row2.addSubview(subtitleView)
            NSLayoutConstraint.activate([
                subtitleView.leadingAnchor.constraint(equalTo: row2.leadingAnchor),
                subtitleView.centerYAnchor.constraint(equalTo: row2.centerYAnchor),
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
        // hover 其余账号条：与点阵同槽（trailing 叠放），hover 时由卡片 onHover 互换显隐
        if let strip = hoverSubStrip {
            strip.translatesAutoresizingMaskIntoConstraints = false
            row2.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.trailingAnchor.constraint(equalTo: row2.trailingAnchor),
                strip.centerYAnchor.constraint(equalTo: row2.centerYAnchor),
            ])
            if let subtitleFadeView {
                // 副标题最多占到子账号条左缘；超出部分由 SubtitleFadeView 渐隐。
                subtitleFadeView.trailingAnchor.constraint(equalTo: strip.leadingAnchor,
                                                            constant: -3).isActive = true
            }
        }
        // row2 高度由内容撑开（取 info 和 dots 中较高的）
        if row2HasContent {
            row2.heightAnchor.constraint(equalToConstant: 12).isActive = true
        }

        // 纵向 stack：row1（标题+数值）与第二行（副标题/点阵/账号条）成组垂直居中。
        // 无文字副标题仅有点阵/账号条时（TRAE：签到行占位已移除）第二行照常入组——
        // 容器恒绑定 DS 等高基准，组高=容器高，成组居中即标题行贴顶，
        // 当前账号积分与其他卡对齐靠上。
        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        var contentViews: [NSView] = [row1]
        if row2HasContent {
            contentViews.append(row2)
        }
        let content = NSStackView(views: contentViews)
        content.orientation = .vertical
        content.alignment = .leading
        // 主副标题行间距 = 数值↔点阵间距（同一竖向 stack）：2 → 1（2026-08-31 用户要求 -1pt）
        // → 0（2026-09-02 用户要求贴紧，保留 content.spacing 参数）
        content.spacing = 0
        content.distribution = .fill
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.translatesAutoresizingMaskIntoConstraints = false
        // 让两行撑满 content 宽度：这样行内 .trailing gravity 的元素（数值/点阵）才会贴右对齐
        for v in contentViews {
            v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
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
        // icon 列↔标题区间距：8→5（2026-08-31 用户要求左侧整带统一 -3pt）→ 6.5（同日 +1.5pt 回调；
        // 不动卡片 horizontalPadding 以免右缘数值/点阵列同步位移）
        row.spacing = 6.5
        row.alignment = .centerY   // icon 与内容垂直居中
        // .fill：iconContainer 有 required 固定宽约束保持原宽，
        // contentContainer（低拥抱优先级）撑满剩余宽度到行尾，数值/点阵才能右对齐贴边
        row.distribution = .fill
        iconContainer.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        contentContainer.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        return row
    }

    /// 用 HoverRowView 包裹行视图：获得 hover 时 8% 背景圆角 + pointingHand 光标
    func wrapHoverRow(_ row: NSView, hoverTextColor: NSColor = .labelColor,
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

    /// 开关行：标题（可选副标题）+ 右侧开关。
    /// 默认用原生 NSSwitch（.mini 尺寸，紧凑）；Mono 模式开启时切换为字符开关 [×]/[▪]。
    /// 两个控件装入同一容器同框显隐切换（不重建行）；容器和可见控件右缘均贴行尾，
    /// 点击整行任意位置都能切换开关状态。
    private func switchRow(title: String, sub: NSTextField?, sw: MiniSwitch) -> NSView {
        sw.controlSize = .mini
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Palette.cardForeground
        sw.setContentHuggingPriority(.required, for: .horizontal)
        // 降低垂直拥抱/压缩阻力：让外部固定行高约束能压住开关高度
        sw.setContentHuggingPriority(.defaultLow, for: .vertical)
        sw.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let charSw = MonoCharSwitch()
        charSw.state = sw.state
        // 复用原生开关的 target/action，保证字符开关翻转后能触发同样的业务回调
        charSw.target = sw.target
        charSw.action = sw.action
        // 字符开关保持固有尺寸，不被外部约束压扁/拉伸
        charSw.setContentHuggingPriority(.required, for: .horizontal)
        charSw.setContentHuggingPriority(.required, for: .vertical)
        charSw.setContentCompressionResistancePriority(.required, for: .horizontal)
        charSw.setContentCompressionResistancePriority(.required, for: .vertical)
        // 同框容器：装载原生开关 + 字符开关（Mono 模式显隐切换）。
        // 容器右缘贴行尾。MonoCharSwitch 是全自绘控件，
        // 把控件 trailing 直接约束到容器 trailing，即可让两者的 `]` 视觉右缘一致。
        // box 宽度固定容纳原生开关（NSSwitch .mini frame 宽约 32pt，留余量到 40）；不跟 charSw
        // intrinsic（自绘后仅 ~25pt，放不下原生开关）。
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 40).isActive = true
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        box.setContentHuggingPriority(.required, for: .horizontal)
        charSw.translatesAutoresizingMaskIntoConstraints = false
        sw.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(charSw)
        box.addSubview(sw)
        NSLayoutConstraint.activate([
            charSw.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            charSw.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            sw.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            sw.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        var views: [NSView] = [label]
        if let s = sub {
            // 字号/颜色对齐余额卡片签到信息（10pt + systemGray 石墨灰）
            s.font = .systemFont(ofSize: 10, weight: .regular)
            s.textColor = .systemGray
            s.isHidden = true
            views.append(s)
        }
        views.append(stretchSpacer())
        views.append(box)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 6
        // 点击整行任意位置触发开关切换：手势加到行容器上，覆盖 label/spacer/switch 全区域。
        // ⚠️ handler 必须被 switchRows 强持有：gesture 的 target 是弱引用，
        //    若仅作局部变量会立即释放，导致整行点击完全失效。
        let handler = SwitchRowTapHandler(sw: sw, char: charSw)
        let tap = NSClickGestureRecognizer(target: handler, action: #selector(SwitchRowTapHandler.toggle(_:)))
        row.addGestureRecognizer(tap)
        switchRows.append((row: row, sw: sw, char: charSw, handler: handler))
        return row
    }

    /// 字符化开关（MonoCharSwitch）切换时的模糊→清晰过渡，
    /// 模拟 CSS `filter: blur()` transition：入场/退场时从模糊聚焦成形，仅作用于控件自身。
    /// ⚠️ 只能用 layer.filters（作用于自身内容，macOS 有效）；
    /// backgroundFilters 在 macOS 被渲染服务端忽略（勿再尝试）。
    /// 每帧重建 CIFilter 实例——改 inputRadius 不触发 CA 重合成，必须换实例。
    /// Mono 开关与 Agent 卡「点阵↔其余账号条」互换共用（internal 供 Panel.swift 调用）。
    func playCharBlurTransition(on views: [NSView]) {
        guard !shouldReduceMotion else { return }
        var layers: [CALayer] = []
        for v in views {
            v.wantsLayer = true
            v.layerUsesCoreImageFilters = true
            if let l = v.layer { layers.append(l) }
        }
        guard !layers.isEmpty else { return }
        // 接管共享 timer：上一轮过渡被打断在中间模糊半径。同一图层集重启（点阵↔条
        // 快速进出）无需清理（新 timer 立即重新模糊）；不同图层集（Mono 开关 ↔ 卡片
        // 互换互相打断）必须清旧集滤镜——它的 timer 已被夺走，无人收尾会永久停在模糊态
        let sameSet = charBlurLayers.map(ObjectIdentifier.init) == layers.map(ObjectIdentifier.init)
        if !sameSet {
            for l in charBlurLayers { l.filters = nil }
        }
        charBlurLayers = layers
        charBlurTimer?.invalidate()
        let duration = 0.35
        let maxRadius: Double = 4
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            // ease-out cubic：前段快速收拢，尾段缓慢聚焦
            let eased = 1 - pow(1 - p, 3)
            let radius = max(0, maxRadius * (1 - eased))
            for layer in layers {
                if radius > 0.05 {
                    let f = CIFilter(name: "CIGaussianBlur") ?? CIFilter()
                    f.setValue(radius, forKey: "inputRadius")
                    layer.filters = [f]
                } else {
                    layer.filters = nil
                }
            }
            if p >= 1 {
                t.invalidate()
                self?.charBlurTimer = nil
            }
        }
        charBlurTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 在同一容器内交叉淡入淡出两个控件，避免 Mono 开关切换时控件瞬间跳变。
    /// hideOutgoingOnFinish=false 时由调用方在 completion 里自行收尾
    /// （Agent 卡点阵↔账号条互换用：快速进出时按代际守卫决定是否落藏）。
    func crossfade(_ outgoing: NSView, to incoming: NSView, animated: Bool,
                   hideOutgoingOnFinish: Bool = true, completion: (() -> Void)? = nil) {
        guard animated, !shouldReduceMotion else {
            outgoing.isHidden = true
            outgoing.alphaValue = 1
            incoming.isHidden = false
            incoming.alphaValue = 1
            completion?()
            return
        }

        // 从当前**表现层**透明度起播（可打断动画标准写法）：上一次淡出/淡入在途时
        // 再次触发，从视觉现状无缝接管；若强制复位 1/0，快速进出会看到 alpha 回弹闪跳。
        // 模型值可能与在途 animator 动画的表现值脱节，读 presentation 才是权威。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.isHidden = false
        incoming.isHidden = false
        outgoing.alphaValue = CGFloat(outgoing.layer?.presentation()?.opacity ?? Float(outgoing.alphaValue))
        incoming.alphaValue = CGFloat(incoming.layer?.presentation()?.opacity ?? Float(incoming.alphaValue))
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup({ context in
            // 与 playCharBlurTransition 同周期同曲线：透明度与模糊聚焦严格同步
            context.duration = 0.35
            context.timingFunction = Motion.easeOutCubic
            outgoing.animator().alphaValue = 0
            incoming.animator().alphaValue = 1
        }, completionHandler: { [weak outgoing, weak incoming] in
            if hideOutgoingOnFinish { outgoing?.isHidden = true }
            outgoing?.alphaValue = 1
            incoming?.alphaValue = 1
            completion?()
        })
    }

    /// 交错上移入场（Agent 卡其余账号条 chip 用）：节奏 = Token 平台切换动效同口径
    /// （行间 0.1s / 单行 0.4s / 上移 6pt，豁免 Motion.emphasis 0.40 硬顶）。
    /// 视图非 flipped：起点在终位下方 6pt（-y 平移）上移 + 淡入；
    /// 减弱动态效果：直接落定仅复位透明度。
    /// isCancelled：每次延迟块触发前轮询（换入↔换出代际守卫由调用方闭包），
    /// 序列中途被打断时剩余块不再启动，避免「容器已在淡出、内容还在各自入场」。
    func staggerRiseIn(_ views: [NSView], isCancelled: (() -> Bool)? = nil) {
        guard !shouldReduceMotion else {
            for v in views { v.alphaValue = 1 }
            return
        }
        let rise = Motion.chipStagger.riseOffset
        for (i, v) in views.enumerated() {
            v.wantsLayer = true
            v.alphaValue = 0
            if let layer = v.layer {
                layer.removeAnimation(forKey: "staggerSink")   // 清掉在途/残留的离场下沉动画（forwards 会压住 presentation）
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DMakeTranslation(0, -rise, 0)
                CATransaction.commit()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * Motion.chipStagger.riseGap) { [weak v] in
                guard let v, isCancelled?() != true else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.chipStagger.riseDuration
                    ctx.timingFunction = Motion.easeOutStrong
                    v.animator().alphaValue = 1
                }
                guard let layer = v.layer else { return }
                let anim = CABasicAnimation(keyPath: "transform.translation.y")
                anim.fromValue = -rise
                anim.toValue = 0
                anim.duration = Motion.chipStagger.riseDuration
                anim.timingFunction = Motion.easeOutStrong
                layer.add(anim, forKey: "staggerRise")
                // model 立即归位（presentation 覆盖期间播完即无缝停在终位）
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
    }

    /// 交错下沉淡出（Agent 卡其余账号条离场，staggerRiseIn 的镜像）：从当前表现值接管
    /// （含被打断的在途入场动画），各 chip 依次（0.06s/格）视觉下移 14pt + 淡出 0.35s。
    /// isCancelled：每块启动前轮询（换入重启时调用方代际校验），剩余块不再启动。
    /// onAllFinished：全部块自然播完（未被取消）后回调一次，调用方落藏/复位；
    /// 被取消时不回调——复位责任归新一轮换入路径。
    func staggerSinkOut(_ views: [NSView], isCancelled: (() -> Bool)? = nil,
                        onAllFinished: (() -> Void)? = nil) {
        guard !shouldReduceMotion, !views.isEmpty else {
            for v in views { v.alphaValue = 0 }
            onAllFinished?()
            return
        }
        // 视图非 flipped：-y = 视觉下方（与 staggerRiseIn 入场 -rise 起步同口径），下沉为负
        let sink = -Motion.chipStagger.sinkOffset
        let per = Motion.chipStagger.sinkDuration
        let gap = Motion.chipStagger.sinkGap
        var pending = views.count
        var allCancelled = false
        for (i, v) in views.enumerated() {
            v.wantsLayer = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * gap) { [weak v] in
                pending -= 1
                if isCancelled?() == true { allCancelled = true }
                guard let v, !allCancelled else {
                    if pending == 0, !allCancelled { onAllFinished?() }
                    return
                }
                let layer = v.layer
                // alpha 从表现层接管：rise 在途被打断时 model 已是 1、表现值 ~0.5，
                // 直接起播会先弹回全亮再淡出（crossfade 同款标准写法）
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                v.alphaValue = CGFloat(v.layer?.presentation()?.opacity ?? Float(v.alphaValue))
                CATransaction.commit()
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = per
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    v.animator().alphaValue = 0
                })
                if let layer {
                    let anim = CABasicAnimation(keyPath: "transform.translation.y")
                    // 平移 y 在 m42（m32 恒 0，旧写法接管在途动画会跳回 0 起点）
                    anim.fromValue = layer.presentation()?.transform.m42 ?? 0
                    anim.toValue = sink
                    anim.duration = per
                    anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    anim.isRemovedOnCompletion = false
                    anim.fillMode = .forwards
                    layer.add(anim, forKey: "staggerSink")
                    // model 立即落到下沉终位（presentation 覆盖期间播完即无缝停住）
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.transform = CATransform3DMakeTranslation(0, sink, 0)
                    CATransaction.commit()
                }
                if pending == 0 {
                    // 等最后一块动画播完（per）再回调落藏——回调时机在启动点会提前
                    // per 秒掐断淡出（0.06s 即 isHidden，正是「离场立即被打断」的根因）
                    DispatchQueue.main.asyncAfter(deadline: .now() + per) {
                        guard !allCancelled, isCancelled?() != true else { return }
                        onAllFinished?()
                    }
                }
            }
        }
    }

    /// 按 Mono 模式切换设置开关控件外观：Mono 开 = 字符开关 [×]/[▪]，关 = 原生 NSSwitch。
    /// 调用时机：build() 初始布局后、update() 每次快照同步后（monoFontEnabled 已更新）。
    func applySwitchVisuals(animated: Bool) {
        let useChar = monoFontEnabled
        for entry in switchRows {
            entry.char.state = entry.sw.state
            if !useChar {
                // 原生开关从隐藏恢复显示：NSStackView detach/reattach 会重置 layer transform，
                // 尺寸未变 layout() 不触发，需手动补 0.81 缩放
                entry.sw.applyVisualScale()
            }
            crossfade(useChar ? entry.sw : entry.char,
                      to: useChar ? entry.char : entry.sw,
                      animated: animated)
        }
        // 切换的两组开关（原生 ↔ 字符化）都叠加模糊→清晰过渡（CSS blur 式）
        if animated {
            playCharBlurTransition(on: switchRows.map { $0.char })
            playCharBlurTransition(on: switchRows.map { $0.sw })
        }
    }

    /// 可拉伸占位（把右侧元素推到行尾）
    func stretchSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(50), for: .horizontal)
        return v
    }

    /// 让子视图撑满 root 宽度（root alignment 为 centerX，需显式等宽）
    private func pinFullWidth(_ v: NSView, in root: NSStackView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    func symbolImage(_ name: String, size: CGFloat = 14) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return img.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    /// 裁掉 SF Symbol 位图四周透明留白：返回墨迹紧贴边缘的 NSImage。
    /// SF Symbol 的 pointSize 生成的位图自带画布留白（如 pointSize 9 → 12×12，
    /// 墨迹 9.5×9.5），且各 symbol 墨迹占比不同（timer 106% / checkmark.seal 117%），
    /// 同 pointSize 视觉大小不一致；裁剪后 image.size = 墨迹实际尺寸，
    /// 配合固定显示框即可精确控制视觉大小（全卡口径统一）。
    static func trimmedSymbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let buf = CFDataGetBytePtr(data) else { return img }
        let w = cg.width, h = cg.height, bpr = cg.bytesPerRow
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where buf[y * bpr + x * 4 + 3] > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY,
                                                   width: maxX - minX + 1, height: maxY - minY + 1))
        else { return img }
        // cgImage 分辨率可能是 1x/2x，按像素→点换算保持尺寸语义
        let scale = img.size.width / CGFloat(cg.width)
        return NSImage(cgImage: cropped,
                       size: NSSize(width: CGFloat(maxX - minX + 1) * scale,
                                   height: CGFloat(maxY - minY + 1) * scale))
    }

    /// 从 bundle 加载 SVG 图标，裁掉四周透明留白后按「墨迹最大边 = size」返回模板图。
    /// 与 trimmedSymbolImage 同口径：各 SVG viewBox 留白不同（tabler 24×24
    /// 实际墨迹占比各异），裁剪后 ink 最大边精确 = size，配合固定显示框让不同来源
    /// 图标视觉大小一致（副标题 timer/calendar/external-link 全卡口径统一）。
    /// isTemplate=true：调用方用 contentTintColor 统一着色（副标题用 systemGray）。
    static func trimmedBundleSvgIcon(_ name: String, size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let src = NSImage(contentsOf: url) else { return nil }
        // 光栅画布下限 32px：小图标（<16pt）固定 2× 画布太小，alpha>0 墨迹阈值会把
        // 边缘行列吃掉（coin 在 16px 画布量出 14×12、20px 量出 16×16，量测失真且
        // 上屏变上采样发糊）；≥32px 量测稳定、上屏恒为降采样（更锐）。
        // 大图标（≥16pt）2× 画布本就 ≥32px，行为不变
        let px = max(32, Int(ceil(size * 2)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            src.isTemplate = true
            src.size = NSSize(width: size, height: size)
            return src
        }
        let ctxSize = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(origin: .zero, size: ctxSize))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage,
              let data = cg.dataProvider?.data, let buf = CFDataGetBytePtr(data) else {
            src.isTemplate = true
            src.size = NSSize(width: size, height: size)
            return src
        }
        let w = cg.width, h = cg.height, bpr = cg.bytesPerRow
        var minX = w, maxX = -1, minY = h, maxY = -1
        // 阈值 64（25%）：alpha>0 会把不可见的 AA 边缘行/列量进 bbox（32px 画布比
        // 低分辨率多出一两行），icon 可见实体相对 bbox 下沉 → 视觉偏下；按可见度
        // 收紧 bbox，各尺寸光栅量出的墨迹几何才一致
        for y in 0..<h {
            for x in 0..<w where buf[y * bpr + x * 4 + 3] > 64 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // 裁剪框向外补齐到偶数像素：奇数边裁剪会得到非整 pt 位图（如 15px→7.5pt），
        // 放进 size×size 视图触发缩放 + 居中亚像素重采样（子账号 coin 静止发糊根因）。
        // 2× 光栅下偶数边 = 位图与设备像素 1:1 对齐；外扩优先（补 1px 透明，不损失
        // 墨迹采样），两侧都无余量（奇数光栅且墨迹贴满边）时保持原样
        var cx = minX, cy = minY, cw = maxX - minX + 1, ch = maxY - minY + 1
        if cw % 2 == 1 {
            if cx > 0 { cx -= 1; cw += 1 } else if maxX + 1 < w { cw += 1 }
        }
        if ch % 2 == 1 {
            if cy > 0 { cy -= 1; ch += 1 } else if maxY + 1 < h { ch += 1 }
        }
        guard let cropped = cg.cropping(to: CGRect(x: cx, y: cy,
                                                   width: cw, height: ch))
        else { return nil }
        // 像素 → 点：以墨迹最大边对齐 size（保持长宽比；tabler 图标近正方形 → ≈ size×size）
        let inkW = CGFloat(cw), inkH = CGFloat(ch)
        let maxDim = max(inkW, inkH)
        let out = NSImage(cgImage: cropped,
                          size: NSSize(width: inkW / maxDim * size,
                                       height: inkH / maxDim * size))
        out.isTemplate = true
        return out
    }

    /// 签到失败角标：exclamationmark.message.fill（普通失败系统红色 / 风控橙黄色，无底框），叠加在卡片 icon 右上角。
    /// 默认隐藏，由 apply*CardData 按当日签到失败/风控状态显隐与变色。
    func makeFailureBadge() -> NSView {
        let img = NSImageView()
        img.image = symbolImage("exclamationmark.message.fill", size: 11)
        img.contentTintColor = .systemRed
        img.imageScaling = .scaleProportionallyUpOrDown
        return img
    }

    /// 余额卡片主标题 label：wantsLayer 承载 hover 字重动画（只改字形宽度不改行框）。
    /// 行框高 16pt 由外部约束固定；原菜单栏渐变蒙版已随小白点指示替代而移除（2026-08-31）。
    final class FadeableTextField: NSTextField {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    /// Agent 卡任务状态发光底层（icon 下方垫底）——按态分风格：
    /// ① 进行中 = X · 光晕旋转（雷达扫描，范例 plans/status-glow-versions.html X 行）：
    ///    静态弱底光（opacity .10）+ 静止圆角方裁切框（masksToBounds）内，
    ///    1.41×（√2 对角）圆盘载 conic 彗尾光束顺时针匀速自转（3.2s linear）；
    ///    进行中态几何整体放大 10%（底光/裁切框/圆盘同心 side×1.10，layout 按 taskState 分支）；
    ///    彗尾铺满整圈 360°、仅亮头处硬断；彗尾 alpha 为提亮档
    ///    （.14/.32/.68/.92/.98，范例原档 .04/.12/.42/.75/.92）+ 亮带向尾侧展宽 9°（≈2pt 弧长）；
    ///    2pt 高斯模糊挂**裁切框父层**（sweepBlur）：blur 与 masksToBounds 同层时弥散边
    ///    会被自家裁剪吃掉（先糊后裁=视觉无模糊），父层壳才能先裁后糊（CSS filter 语义）；
    ///    ⚠ 贴图镜像后 alpha 沿顺时针爬升 → 盘体负向旋转（屏幕顺时针，用户定案）才「头前尾后」；
    /// ② 完成 = 「雷达涟漪」风格：柔光呼吸 + 双圈涟漪错相扩散（详见下方常量注释）；
    /// ③ 中断 = 信号断续（故障感：闪烁掉线 + 随机缩放闪动），无位移、无涟漪。
    /// 三态色：进行中=蓝 / 完成=绿 / 中断=橙红；nil = 全隐藏（仅占位）。
    /// 颜色为动态色，layout 时按生效外观解算（同 CardMenuBarDotView 口径）；
    /// reduceMotion 时只留静态柔光（两界中值），涟漪/扫描不铺。
    final class CardTaskStatusRingView: NSView, CAAnimationDelegate {
        /// API 卡（DS/ZhiPu/Qwen）脉冲驱动态：taskState 由进度条闪烁（额度消耗脉冲）点亮
        /// 进行中；进行中态的颜色/动画代码完全复用，仅状态层全链路挂移除饱和度滤镜
        ///（灰阶保留亮度），与 Agent 任务态的彩色光环区分
        var pulseDriven = false {
            didSet {
                guard oldValue != pulseDriven else { return }
                applyDesaturationFilters()
            }
        }
        /// 柔光呼吸两界（用户调档：峰值 0.6 → 0.45，2026-09-01）；呼吸与涟漪同拍（period）
        static let coreLow: Float = 0.0
        static let coreHigh: Float = 0.45
        static let period: CFTimeInterval = 3.0
        /// 进行中态（X 扫描）转一圈的时间：1.6s
        static let runningPeriod: CFTimeInterval = 1.6
        /// 进行中态（X 扫描）圆角：7pt 用户指定（2026-09-01），独立于完成/中断的 side×0.22 等比口径
        static let runningCornerRadius: CGFloat = 7
        /// 完成态（双圈涟漪）圆角：7pt 用户指定（2026-09-01，先 +0.4 偏置到 6.34 再直接定为 7），
        /// 独立于中断态的 side×0.22
        static let completedCornerRadius: CGFloat = 7

        var taskState: AgentTaskState? {
            didSet {
                guard oldValue != taskState else { return }
                // 状态切换后清理中断态残留的缩放 transform，避免下一次进入时继承旧状态。
                if taskState != .interrupted || oldValue != .interrupted {
                    resetGlitchTransform()
                }
                needsLayout = true
            }
        }

        /// 柔光载体（icon 之下）：纯色圆角块 + 高斯模糊 = 柔和光晕
        private let glow = CALayer()
        /// icon 光晕基础模糊；中断态在此基础上增加 2pt
        private var glowBlur: CIFilter?
        /// 涟漪双圈：同色描边、无填充，scale+opacity 扩散（完成态）
        private let ring1 = CALayer()
        private let ring2 = CALayer()
        /// X 雷达扫描（进行中）：外层 = 静止圆角方裁切框（overflow 裁切口径）
        private let sweepClip = CALayer()
        /// X 雷达扫描：模糊壳 = 裁切框的父层。2pt 高斯模糊挂这里而非 sweepClip 自身——
        /// CALayer 的 masksToBounds 会裁掉本层 filter 的弥散输出（先糊后裁），视觉上等于没加；
        /// 挂父层才「先裁圆角方、再整体柔化」，等价 CSS 元素 overflow:hidden + filter:blur（2026-09-01 实测修复）
        private let sweepBlur = CALayer()
        /// X 雷达扫描：内层 = 1.41× 对角圆盘，载 conic 彗尾光束自转（contents = 贴图）
        private let sweepDisc = CALayer()
        /// 彗尾贴图缓存键（尺寸变化时重渲染）
        private var sweepImageKey: String?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(1, forKey: kCIInputRadiusKey)
                glow.filters = [blur]
                glowBlur = blur
            }
            glow.opacity = Self.coreLow
            for ring in [ring1, ring2] {
                // 涟漪描边 4.75 → 3.75pt（2026-09-02 用户要求 -1pt 两圈同步）
                ring.borderWidth = 3.75
                ring.backgroundColor = NSColor.clear.cgColor
                // 涟漪描边高斯模糊 0.5 → 1.5pt（2026-09-02 用户要求 +1pt，边缘更柔）（每层独立滤镜实例）
                if let blur = CIFilter(name: "CIGaussianBlur") {
                    blur.setValue(1.5, forKey: kCIInputRadiusKey)
                    ring.filters = [blur]
                }
            }
            // 连续曲率圆角（超椭圆，同 macOS/iOS 图标口径）——CALayer 默认 .circular 是圆弧角
            glow.cornerCurve = .continuous
            ring1.cornerCurve = .continuous
            ring2.cornerCurve = .continuous
            sweepClip.cornerCurve = .continuous
            // 裁切框：内容溢出裁掉（光束只在圆角方内可见）；模糊挂父层 sweepBlur（见其注释）
            sweepClip.masksToBounds = true
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(2, forKey: kCIInputRadiusKey)
                sweepBlur.filters = [blur]
            }
            layer?.addSublayer(glow)
            layer?.addSublayer(sweepBlur)
            sweepBlur.addSublayer(sweepClip)
            layer?.addSublayer(ring1)
            layer?.addSublayer(ring2)
            sweepClip.addSublayer(sweepDisc)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// 有色层挂 CIColorControls(saturation=0) 实现移除饱和度：柔光/双涟漪层
        ///（各自已有高斯模糊，追加进同数组，滤镜实例每层独立）+ 扫描模糊壳
        ///（filters 作用于层内容含子层，彗尾贴图一并去饱和）。
        /// 颜色与动画完全复用进行中态代码，滤镜只在显示端收饱和度
        private func applyDesaturationFilters() {
            for l in [glow, ring1, ring2, sweepBlur] {
                guard let f = CIFilter(name: "CIColorControls") else { continue }
                f.setValue(0, forKey: kCIInputSaturationKey)
                l.filters = (l.filters ?? []) + [f]
            }
        }

        override func layout() {
            super.layout()
            guard bounds.width > 1, bounds.height > 1 else { return }
            // 与 icon 同形的圆角正方形：居中、边长取图标列宽、圆角比例 0.22（app 图标口径），
            // 外扩 3pt 让 halo 更明显。涟漪圈与柔光同基准方（scale 动画向外扩散）
            let inset: CGFloat = 0.5
            let side = min(bounds.width, bounds.height) - inset * 2 + 3
            // 视觉补偿上移 1pt 已移除（2026-09-01 用户要求去掉状态层向上偏移）
            let rect = CGRect(x: (bounds.width - side) / 2,
                              y: (bounds.height - side) / 2,
                              width: side, height: side)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // 进行中态整体放大 10%（2026-09-01 用户要求）：底光/扫描框/圆盘同心扩至 side×1.10；
            // 中断态整体放大 5%（2026-09-02 用户要求，由 15% 收敛）；完成保持原尺寸
            let stateScale: CGFloat = taskState == .running ? 1.10
                                    : taskState == .interrupted ? 1.05 : 1.0
            let boxSide = side * stateScale
            let boxRect = CGRect(x: (bounds.width - boxSide) / 2,
                                 y: (bounds.height - boxSide) / 2,
                                 width: boxSide, height: boxSide)
            glow.frame = boxRect
            // 圆角：进行中 7pt / 完成 7pt（各自独立常量）；中断态 boxSide×0.22
            //（随放大底数走，形状比例与未放大时一致）
            let corner = taskState == .running ? Self.runningCornerRadius
                        : taskState == .completed ? Self.completedCornerRadius
                        : boxSide * 0.22
            glow.cornerRadius = corner
            for layer in [ring1, ring2] {
                layer.frame = rect
                layer.cornerRadius = corner
            }
            CATransaction.commit()
            // 中断态 icon 光晕增加 2pt 模糊（1pt → 3pt）；无状态/其它状态恢复基础值。
            glowBlur?.setValue(taskState == .interrupted ? 3 : 1, forKey: kCIInputRadiusKey)
            if let state = taskState {
                let color = Self.color(for: state, in: self)
                glow.backgroundColor = color
                ring1.borderColor = color
                ring2.borderColor = color
                // X 扫描：模糊壳外扩 6pt（≥2×blur 半径）给弥散边留渲染空间；
                // 裁切框在壳坐标系内回移 6pt，屏幕位置与柔光同基准方。
                // 光束圆盘按对角线放大 √2，自转扫到四角不留空洞
                sweepBlur.frame = boxRect.insetBy(dx: -6, dy: -6)
                sweepClip.frame = CGRect(x: 6, y: 6, width: boxSide, height: boxSide)
                sweepClip.cornerRadius = Self.runningCornerRadius
                let discSide = boxSide * 1.4142
                sweepDisc.frame = CGRect(x: (boxSide - discSide) / 2, y: (boxSide - discSide) / 2,
                                         width: discSide, height: discSide)
                if state == .running {
                    let key = "sweep-\(Int(discSide * 2))"
                    if key != sweepImageKey {
                        sweepDisc.contents = Self.cometTailImage(color: color, pixels: Int(discSide * 2))
                        sweepImageKey = key
                    }
                }
                glow.isHidden = false
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                // 进行中 = X 雷达扫描 / 完成 = 双圈涟漪 / 中断 = 信号断续（动画见 restartAnimationsIfNeeded）
                sweepBlur.isHidden = state != .running || reduceMotion
                sweepClip.isHidden = state != .running || reduceMotion
                let ripple = state == .completed && !reduceMotion
                ring1.isHidden = !ripple
                ring2.isHidden = !ripple
            } else {
                glow.isHidden = true
                sweepBlur.isHidden = true
                sweepClip.isHidden = true
                ring1.isHidden = true
                ring2.isHidden = true
            }
            restartAnimationsIfNeeded()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }

        /// 视图（重新）进入窗口后动画不会自动续播：接管挂载时机重铺
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restartAnimationsIfNeeded()
        }

        /// 重铺全部动画（按态分流）：
        /// 进行/完成 = 柔光呼吸 + 双圈涟漪（错相半周期）；中断 = 光晕信号断续（无涟漪）。
        /// 无状态/无窗口/reduceMotion 时收回静态态（glow 钉两界中值、圈隐藏）。
        private func restartAnimationsIfNeeded() {
            glow.removeAnimation(forKey: "taskGlowPulse")
            glow.removeAnimation(forKey: "taskGlitchScale")
            ring1.removeAnimation(forKey: "taskRipple")
            ring2.removeAnimation(forKey: "taskRipple")
            sweepDisc.removeAnimation(forKey: "taskSweep")
            // 视图离窗后也会复用同一个状态层；没有窗口时清理中断态残留的 transform。
            if taskState != .interrupted || window == nil {
                resetGlitchTransform()
            }
            guard let state = taskState, window != nil else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                glow.opacity = (Self.coreLow + Self.coreHigh) / 2
                return
            }
            if state == .running {
                // X 雷达扫描：底光静态弱亮（范例 base opacity .10，不呼吸），光束匀速自转
                glow.opacity = 0.10
                addSweep()
                return
            }
            if state == .interrupted {
                addGlitchSignal()
                return
            }
            // 完成态：静谧微光打底：opacity 呼吸 1.5s（period/2，涟漪两拍对一波）。
            // 光晕尺寸保持静态——缩放的光晕方块会被误读为"从中心扩散的第三圈涟漪"（2026-09-01 实测）
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [Self.coreLow, Self.coreHigh, Self.coreLow]
            pulse.keyTimes = [0, 0.5, 1.0]
            pulse.duration = Self.period / 2
            pulse.repeatCount = .infinity
            // 两头快中间慢：升段 easeOut（急速离谷、近峰放缓）+ 降段 easeIn（峰上驻留、
            // 急速回落）→ 亮相是宽平台、暗相一掠而过，脉冲节奏感（keyframe 逐段曲线数组）
            pulse.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn),
            ]
            // 负 beginTime = 以"已播 0.45s 进行态"接入循环（相位提前 0.45s，重铺时无静默段）
            pulse.beginTime = CACurrentMediaTime() - 0.45
            glow.add(pulse, forKey: "taskGlowPulse")
            addRipple(to: ring1, phase: 0)
            addRipple(to: ring2, phase: Self.period / 2)
        }

        /// 中断态 = 信号断续（故障感）：稳亮段中穿插两次「掉线」——
        /// opacity 近乎瞬时闪断，并同步做随机缩放闪动；不再产生任何 X/Y 位移。
        /// 两次掉线间隔不均（30%→52%→70%），周期播完重新随机缩放，避免机械重复。
        /// 动画只挂 glow（icon 不参与）；周期 2.8s，幅度克制不干扰阅读。
        /// 2026-09-02 用户要求移除中断态位移动效，仅保留随机缩闪。
        /// 清除中断态缩放，并同步清理 CALayer model transform。
        /// 仅在状态复位/离窗时调用；连续中断周期之间保留动画连续性。
        private func resetGlitchTransform() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.setAffineTransform(.identity)
            CATransaction.commit()
        }

        private func addGlitchSignal() {
            let period: CFTimeInterval = 2.8
            // 信号闪烁（2026-09-02 用户定档：稳亮 opacity 0.7，谷值保掉线感）：
            // 掉线谷 0.06~0.12 近瞬时降、近瞬时回，
            // 相邻 keyTimes 差 0.03 ≈ 84ms，linear 曲线模拟信号「啪」断；
            // 70%-80% 处是长掉线：短暂回亮一拍再彻底熄灭，抖线感
            let flicker = CAKeyframeAnimation(keyPath: "opacity")
            flicker.values = [0.7, 0.7, 0.08, 0.7, 0.7, 0.12, 0.7,
                              0.7, 0.06, 0.35, 0.06, 0.7, 0.7]
            flicker.keyTimes = [0, 0.30, 0.33, 0.36, 0.52, 0.55, 0.58,
                                0.70, 0.73, 0.76, 0.80, 0.84, 1.0]
            flicker.duration = period
            flicker.repeatCount = .infinity
            flicker.timingFunction = CAMediaTimingFunction(name: .linear)
            glow.add(flicker, forKey: "taskGlowPulse")
            // 随机缩闪：与掉线时间点对齐，但不改变位置；每周期重新抽样，避免机械重复。
            let shrink1 = CGFloat.random(in: 0.78...0.90)
            let shrink2 = CGFloat.random(in: 0.82...0.94)
            let shrink3 = CGFloat.random(in: 0.72...0.88)
            let shrink4 = CGFloat.random(in: 0.80...0.92)
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [1, 1, shrink1, 1, 1, shrink2, 1,
                            1, shrink3, shrink4, shrink3, 1, 1]
            scale.keyTimes = flicker.keyTimes
            scale.duration = period
            scale.repeatCount = 1
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scale.delegate = self
            glow.add(scale, forKey: "taskGlitchScale")
        }

        /// 掉线单周期播完（finished=true）→ 重新随机归位落点续播下一周期；
        /// 主动移除（态切换/重排）触发 finished=false，交回 restartAnimationsIfNeeded 分管
        func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
            guard flag, taskState == .interrupted, window != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            addGlitchSignal()
            CATransaction.commit()
        }

        /// 单圈涟漪：scale 0.92→1.57 + opacity 淡出（keyframe：起泡清晰、外缘提前衰减），group 错相（负 beginTime = 已播进行态）
        private func addRipple(to ring: CALayer, phase: CFTimeInterval) {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.92
            scale.toValue = 1.554 // 2026-09-01 用户要求整体 scale 上限 +10%（1.413 → 1.554，起泡 0.92 不变）
            // 外边缘透明度降低（2026-09-01 用户要求）：原线性 0.75→0 扩散到外圈仍有余亮；
            // keyframe 提前衰减——起泡段保持清晰 0.75，中段 0.6，外圈 0.22，
            // 归零提前到 78% 扩散处（原 100%），最后 1/4 扩散纯隐形、外缘干净消失
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.75, 0.6, 0.22, 0.0]
            fade.keyTimes = [0, 0.35, 0.6, 0.78]
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = Self.period
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.3, 1)
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() - phase
            ring.add(group, forKey: "taskRipple")
        }

        /// X 雷达扫描：光束圆盘匀速自转一圈（1.6s linear）。
        /// 方向定案（2026-09-01 用户目检二次修正）：屏幕**顺时针**扫。
        /// 贴图已镜像（alpha 沿顺时针爬升、彗尾拖在逆时针侧），盘体**负向**旋转（-2π）头前尾后。
        private func addSweep() {
            let spin = CABasicAnimation(keyPath: "transform.rotation")
            spin.fromValue = 0
            spin.toValue = -CGFloat.pi * 2
            spin.duration = Self.runningPeriod
            spin.repeatCount = .infinity
            sweepDisc.add(spin, forKey: "taskSweep")
        }

        /// 彗尾 conic 光束贴图：全圈 360° alpha 爬升、仅亮头处硬断。
        /// alpha 档位（2026-09-01 两轮上调）：范例原档 .04/.12/.42/.75/.92 →
        /// 加粗档 .08/.22/.55/.85/.95 → 提亮档 .14/.32/.68/.92/.98；
        /// 加粗 2pt = 亮带向尾侧展宽 9°（前四档前移、头侧 348°/360° 锚定）。
        /// 贴图按 (1-loc, alpha) 镜像：alpha 沿**顺时针**爬升（亮头后拖尾），配合 -2π 旋转头前尾后。
        /// pixels = 贴图边长像素（2x 渲染保证清晰）；颜色用调用方已按外观解算的 CGColor。
        /// ⚠ 必须用纯 CGContext 位图（makeImage）——NSImage lockFocus 未 unlock 前
        /// cgImage(forProposedRect:) 恒返回 nil，contents 落空 = 整层不可见（2026-09-01 实测踩坑）
        private static func cometTailImage(color: CGColor, pixels: Int) -> CGImage? {
            let comps = color.components ?? [0, 0, 0, 1]
            guard comps.count >= 3 else { return nil }
            let (r, g, b) = (comps[0], comps[1], comps[2])
            // 提亮档：各段 alpha 上调（.08/.22/.55/.85/.95 → .14/.32/.68/.92/.98），头 1.0/尾 0 不变；
            // 加粗 2pt（≈9° 弧）：亮带向尾侧展宽——头侧锚点 348°/360° 钉死，仅前四个档位前移 9°
            // ⚠ 五档等量平移只是旋转渐变、不改任何带宽（2026-09-01 踩坑，视觉零变化）
            let stops: [(loc: CGFloat, alpha: CGFloat)] = [
                (0, 0), (87.0 / 360, 0.14), (171.0 / 360, 0.32), (243.0 / 360, 0.68),
                (303.0 / 360, 0.92), (348.0 / 360, 0.98), (1, 1),
            ]
            // 镜像到顺时针爬升：特征 (loc, a) → (1-loc, a)，硬断仍在 loc 0/1 回绕处
            let mirrored = stops.map { (loc: 1 - $0.loc, alpha: $0.alpha) }
                .sorted { $0.loc < $1.loc }
            var components: [CGFloat] = []
            components.reserveCapacity(mirrored.count * 4)
            for m in mirrored {
                components.append(contentsOf: [r, g, b, m.alpha])
            }
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(colorSpace: cs, colorComponents: components,
                                            locations: mirrored.map { $0.loc }, count: mirrored.count),
                  let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            CGContextDrawConicGradient(ctx, gradient, CGPoint(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2), 0)
            return ctx.makeImage()
        }

        private static func color(for state: AgentTaskState, in view: NSView) -> CGColor {
            let ns: NSColor
            switch state {
            // 进行中蓝（2026-09-01 提亮一档：115/199/255 → 140/214/255）
            case .running: ns = NSColor(calibratedRed: 0.55, green: 0.84, blue: 1.0, alpha: 1)
            case .completed: ns = NSColor(calibratedRed: 0.45, green: 0.95, blue: 0.55, alpha: 1)
            // 中断橙红（2026-09-02 用户要求故障态换橙红 #FF7333 → #FF4514 → 更亮更红 #FF3300）：
            // 与进行中蓝 140/214/255、完成绿 115/242/140 形成色相对比
            case .interrupted: ns = NSColor(calibratedRed: 1, green: 0.20, blue: 0, alpha: 1)
            }
            return Palette.borderCGColor(ns, in: view)
        }
    }

    /// 菜单栏显隐指示点（icon 下方 2pt 的 3.6pt 圆点）：
    /// 颜色 = cardForeground 按「视图生效外观」解算——动态色直取 .cgColor 会定格
    /// 创建时外观（浅色主题开关强制面板 aqua 时会拿错分支），故在 layout 时重设，
    /// 外观变化经 viewDidChangeEffectiveAppearance 触发重排刷新。
    final class CardMenuBarDotView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.width / 2
            layer?.backgroundColor = Palette.borderCGColor(Palette.cardForeground, in: self)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }
    }

}

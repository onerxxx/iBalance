// PanelLayout.swift — iBalance
// 面板布局构建:build() 主装配 + 卡片/区块行构建器
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 主装配      build()（面板所有区段的组装入口；改整体结构先读它）
// header      左上角六颗图标按钮（退出/设置/饼图/GitHub/Cockpit/平台开关；拖动换位，逻辑在 PanelDrag.swift）
// 卡片容器     addCard(rows:to:...)（圆角背景 + hover + 点击/右键/拖拽回调都在这挂）
// 卡片内容     balanceContentRow(...)（两行：标题+数值 / 副标题+点阵）
//              ⚠️ **卡片字号·行高·icon 列宽的数值权威就在这一个方法里**（字号走 Palette 常量）
// 行包裹      wrapHoverRow（给任意行加 hover 背景 + pointingHand 光标）
// 动效        playCharBlurTransition / crossfade / staggerRiseIn
// 指示点      CardMenuBarDotView（菜单栏显隐圆点，按生效外观解算 cardForeground）
// 工具        symbolImage / makeFailureBadge / stretchSpacer
//            （原 refreshAnchors/syncLayout 属已删的 MenuBarFadeMask，勿再找）
//            ⚠️ 原「设置行 switchRow / 设置行图标 settingsRowIcon / applySwitchVisuals」随
//              面板「设置」板块 2026-09-12 移除 —— 设置项已全部在设置窗口；要加回面板先想清楚归属。
//
// ⚠️ 本文件是 extension BalancePanelView = Panel.swift 同一类型拆出的「布局部分」。
//    状态与数据在 Panel.swift，行的数值在这里——改数值来这里，改状态机去 Panel.swift。

import Cocoa
import CoreImage
import CoreText
import SettingsUI          // BrandIconRequest（设置窗口「主题预设」图卡的品牌 icon 取图口径）

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
            // 内容只钉前缘（2026-09-06 定案）：视图宽度可随外部约束自由收窄，超宽部分
            // 由 masksToBounds 裁切 + layout() 渐隐 mask 淡出。任何形式的尾随钉扎
            // （= 或 ≤）都会让视图宽度被内容自然宽托底，「渐隐让位」失效并反压账号条。
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

        // ── 顶部 header：左侧按钮组（退出/设置/刷新周期饼图/GitHub/Cockpit）──
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        // header 底色层（2026-09-14 用户：「header 与自定义的面板背景色上端同色」）：
        // 用**纯色绘制层** `TintOverlayView`（不挂毛玻璃 —— 材质必经合成、会带色偏），
        // 颜色 = 面板底色的**顶端色**（与 body 渐变起点同值 ⇒ 接缝无缝、观感同色）。
        // 覆盖 header 整条：滚过的内容被它按该色（含 alpha）染色遮挡。
        // 顶边贴安全区顶 —— 上方箭头区由容器自身遮罩覆盖，颜色同源。
        // 历史：同日先试过 `.menu` 毛玻璃 + 顶色遮罩（有色块感）、再试过只模糊不着色的
        // `headerBlurView`（用户「回滚操作」），现为纯色方案
        headerTintView = TintOverlayView()
        // header 中间的「更新于 / 刷新中…」文字 2026-09-13 按用户要求移除：刷新节奏
        // 由饼图按钮表达。label 对象与全部写入点（setRefreshing 脉冲、footer 收尾
        // 回写等）保留不动，继续安全写这个隐藏视图。
        updatedLabel.translatesAutoresizingMaskIntoConstraints = false
        updatedLabel.isHidden = true
        header.addSubview(updatedLabel)
        // 右上角按钮组 2026-09-12 整组移除（原「主题调教 + 平台开关」NSSegmentedControl）：
        // 两个入口迁进设置窗口（「主题外观」「平台」pane），header 右侧因此不再挂任何控件。
        // 五颗 HoverIconButton（退出/设置/GitHub/Cockpit/平台开关）全部走 makeHeaderIconButton 这
        // 一个入口：尺寸、图标口径、常态色、hover 提亮与 hover 底全同源，差异只有
        // 图标 / 动作 / 提示 —— 同组的 hover 观感由构造保证一致。
        // 2026-09-14 收齐：退出按钮此前是这几颗里唯一的特例（单独把 hover 提亮改成红色 →
        // 「hover 跟别人不一样」）。现在全部同构，且**不做任何单颗视觉偏移** ——
        // 曾试过给 power 加 +0.75pt「把圆环顶到圆心」，结果整颗墨迹外框比同组高 0.75pt，
        // 用户看到的就是「退出按钮偏高了」；同组对齐只认一条规则：裁墨迹后按墨迹外框居中。
        let quitBtn = makeHeaderIconButton(in: header, symbol: "power",
                                           action: #selector(quitTapped), tooltip: "退出 iBalance")
        // 设置窗口入口：header 左上角、退出按钮右侧（SwiftUI 设置窗口，系统设置式侧栏+表单）
        let settingsBtn = makeHeaderIconButton(in: header, symbol: "gearshape",
                                               action: #selector(settingsTapped), tooltip: "打开设置")
        // header 左侧按钮组第三颗（退出/设置右侧 +2pt）：刷新周期饼图按钮（圆形饼图
        // 走满一圈 = 一个自动刷新周期，每秒推进；左键立即刷新，右键弹间隔单选菜单）。
        // 大小/配色对齐同组 HoverIconButton
        let refreshPieBtn = RefreshPieButton(frame: .zero)
        refreshPieBtn.onSelectInterval = { [weak self] seconds in
            self?.onChangeRefreshInterval?(seconds)
        }
        refreshPieBtn.onSelectRefresh = { [weak self] in
            self?.onManualRefresh?()
        }
        refreshPieBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(refreshPieBtn)
        refreshPieButton = refreshPieBtn
        // 第四颗：GitHub 项目页（原贴底 footer 按钮 2026-09-13 迁入 header）：
        // bundle 品牌 SVG 优先，缺失回退 globe
        let githubBtn = makeHeaderIconButton(in: header, symbol: "globe", svgIcon: "github",
                                             action: #selector(openGitHubTapped),
                                             tooltip: "打开 iBalance GitHub")
        // 第五颗：打开 Cockpit（原操作板块首磁贴 2026-09-13 迁入 header，板块整体移除）
        let cockpitBtn = makeHeaderIconButton(in: header, symbol: "list.bullet.rectangle.portrait",
                                              action: #selector(openCockpitTapped),
                                              tooltip: "打开 Cockpit")
        // 第六颗（2026-09-16 用户要求）：平台开关 —— 直接打开设置窗口并落到「平台」pane
        // （原 header 右上角的「平台开关」分段控件 2026-09-12 撤出迁进设置窗口，此处补回直达入口；
        //  图标用 circle.grid.2x2.topleft.checkmark.filled，与设置侧栏「平台」项同款）
        let platformsBtn = makeHeaderIconButton(in: header, symbol: "circle.grid.2x2.topleft.checkmark.filled",
                                               action: #selector(platformSettingsTapped),
                                               tooltip: "平台开关")
        let headerSeparator = PanelSeparatorView()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerSeparator)
        let panelBarHeight: CGFloat = 20
        let panelTopPadding: CGFloat = 6
        headerView = header
        let headerRowCenterY = panelTopPadding + panelBarHeight / 2
        // header 图标按下拖动换位（2026-09-13 起无需按住 Cmd，逻辑在 PanelDrag.swift）：
        // 注册 id → 视图、还原落盘槽位表、给每颗按钮挂起手回调；leading 由
        // applyHeaderButtonSlots 按槽位下标统一装配（落位 = 整组重装），这里只钉尺寸与垂直居中
        headerButtonRegistry = ["quit": quitBtn, "settings": settingsBtn, "refresh": refreshPieBtn,
                                "github": githubBtn, "cockpit": cockpitBtn,
                                "platforms": platformsBtn]
        headerButtonSlots = savedHeaderButtonSlots()
        for (id, view) in headerButtonRegistry {
            (view as? HeaderIconDraggable)?.onDragStart = { [weak self] event in
                self?.beginHeaderIconDrag(for: id, event: event)
            }
        }
        // 拖动时的槽位指引层：画在按钮**之上**（以 stroke 为主，不遮字形），
        // 整条钉死在槽位条上；非拖拽会话恒 hidden。占用表由 applyHeaderButtonSlots 同步
        let slotGuides = HeaderSlotGuidesView()
        slotGuides.translatesAutoresizingMaskIntoConstraints = false
        slotGuides.isHidden = true
        header.addSubview(slotGuides, positioned: .above, relativeTo: nil)
        headerSlotGuidesView = slotGuides
        NSLayoutConstraint.activate([
            quitBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            quitBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            quitBtn.centerYAnchor.constraint(equalTo: header.topAnchor, constant: headerRowCenterY),
            settingsBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            settingsBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            settingsBtn.centerYAnchor.constraint(equalTo: header.topAnchor, constant: headerRowCenterY),
            refreshPieBtn.widthAnchor.constraint(equalToConstant: RefreshPieButton.buttonSize),
            refreshPieBtn.heightAnchor.constraint(equalToConstant: RefreshPieButton.buttonSize),
            refreshPieBtn.centerYAnchor.constraint(equalTo: header.topAnchor, constant: headerRowCenterY),
            githubBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            githubBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            githubBtn.centerYAnchor.constraint(equalTo: header.topAnchor, constant: headerRowCenterY),
            cockpitBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            cockpitBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            cockpitBtn.centerYAnchor.constraint(equalTo: header.topAnchor, constant: headerRowCenterY),
            platformsBtn.widthAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            platformsBtn.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            platformsBtn.centerYAnchor.constraint(equalTo: header.topAnchor, constant: headerRowCenterY),
            // ── 槽位指引层：整条 = 全部槽位，左缘与首槽同起点、右缘与末槽同终点 ──
            // 垂直方向钉在**按钮带**上（height = 按钮边长 + centerY 与按钮同轴），
            // 而不是 header 上下缘：按钮中心距 header 顶 16pt、header 几何中心 16.5pt，
            // 差 0.5pt；钉按钮带才能保证指引圆与按钮正同心
            slotGuides.leadingAnchor.constraint(equalTo: header.leadingAnchor,
                                                constant: BalancePanelView.headerSlotStripLeading),
            slotGuides.widthAnchor.constraint(equalToConstant: BalancePanelView.headerSlotStripWidth),
            slotGuides.heightAnchor.constraint(equalToConstant: HoverIconButton.buttonSize),
            slotGuides.centerYAnchor.constraint(equalTo: quitBtn.centerYAnchor),
            // ── header 下缘分割线：贴 header 底边，通栏 ──
            headerSeparator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerSeparator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: PanelSeparatorView.thickness),
        ])
        applyHeaderButtonSlots(animated: false)

        NSLayoutConstraint.activate([
            // 左右正文缩进 7pt（原始口径）。满尺寸内容下被系统吃掉的左右边距带由
            // VC 容器层统一补回（BalancePanelViewController.contentHorizontalInset
            // = 11（2026-09-03 四次调整 16→8→13→9；09-06 晚再 -2 → 11），scrollView 左右约束），
            // 11+7=18pt 视觉口径，本层不重复承担边距替代。
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            // header 总高度吃 BalancePanelView.headerHeight（2026-09-10 由用户指定 30→33）；
            // header 内部上边距不变，API 标题上方间距单独收紧（2026-09-13 用户「统一-1pt」4→3）。
            root.topAnchor.constraint(equalTo: topAnchor,
                                      constant: BalancePanelView.headerHeight + 3),
        // 底部用 ≤：root 顶锚、保持内容自然高度（永不被拉伸）。原贴底 footer
        // 2026-09-13 已整体移除（GitHub 按钮迁入 header），root 底部只留 11pt 底边距；
        // 浮窗拖高时多出的高度自然成为底部空白
        ])
        rootBottomCap = root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -11)
        rootBottomCap?.isActive = true
        rootViewRef = root
        // 共享 hover 材质的统一宿主：材质（渐变背景块 + 发丝描边框）挂在滚动内容根上
        //（随内容滚动），卡片 hover 时向上找到它 → 材质在卡片之间整块移动并停住
        //（见 HoverMaterial.swift；背景块画在卡片之下，见该文件说明）
        root.installHoverMaterialHost()

        // header 更新时间标签启用 layer 供脉冲动效使用
        updatedLabel.wantsLayer = true

        // ── 离线横幅 ──
        registerFont(offlineBanner, size: 12)
        offlineBanner.textColor = .systemOrange
        offlineBanner.isHidden = true
        root.addArrangedSubview(offlineBanner)
        pinFullWidth(offlineBanner, in: root)

        // ── API 分组标题（字号 = 卡片主标题字号 + semibold + 副前景灰，行高固定 24pt）
        //    + 行尾 pin 置顶按钮 ──
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
        // 暂时隐藏 pin 按钮（2026-09-06 用户要求，代码保留；恢复 = 删除此行）
        pinBtn.isHidden = true
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
        // 平台间间隔 platformCardGap（列表态 4 / 长进度 2.5；同平台内各容器内部 spacing=0 不加间隔）
        apiGroupContainer.setCustomSpacing(platformCardGap, after: dsCardsContainer)

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
        apiGroupContainer.setCustomSpacing(platformCardGap, after: zhipuCardsContainer)

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
        apiGroupContainer.setCustomSpacing(platformCardGap, after: qwenCardsContainer)

        // API 区块 → Agent 区块（分割线已移除，用区块间距分隔；09-13 统一-1pt；
        // 2026-09-14 用户「各个板块间隔缩小 2pt」9 → 7）
        root.setCustomSpacing(7, after: apiGroupContainer)

        // ── Agent 分组标题（原「余额」板块改名；ZCode/Codex/TRAE/WB 等 Agent 平台）──
        // HoverCard 驻留：hover 背景常规淡入，驻留 Motion.hoverDwell 与平台卡同触发
        // 时长 → Token 板块切到 .aggregate 三平台聚合视图；离开/快速掠过取消，
        // 确认后不回落（同平台卡口径）
        let balanceTitle = HoverCard()
        balanceTitle.wantsLayer = true
        // 圆角与余额卡片统一（hoverCardCornerRadius = 9pt，2026-09-13 由 10 改）
        balanceTitle.layer?.cornerRadius = Palette.hoverCardCornerRadius
        balanceTitle.layer?.cornerCurve = .continuous
        balanceTitle.layer?.masksToBounds = true
        // hover 材质（背景 + 框）由容器共享（HoverMaterialHost），卡片自身恒无边框
        // ⚠️ 本标题因要挂 hover 驻留（→ Token 板块切 .aggregate）而手写，不走
        // `sectionTitleRow` —— 字号/字重/颜色/左缩进/行高必须与其他三处板块标题
        // （API / Token / Usage）**逐项一致**：字号走 `registerSectionTitle`（跟随卡片
        // 主标题字号，2026-09-16 用户要求），其余参数同 `sectionTitleRow` 的口径
        let balanceTitleLabel = NSTextField(labelWithString: "Agent")
        registerSectionTitle(balanceTitleLabel)
        balanceTitleLabel.textColor = Palette.secondaryForeground
        balanceTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        balanceTitle.addSubview(balanceTitleLabel)
        NSLayoutConstraint.activate([
            balanceTitle.heightAnchor.constraint(equalToConstant: 24),
            // 标题文字距左 8（与卡片内标题/API 标题对齐），垂直居中
            balanceTitleLabel.leadingAnchor.constraint(equalTo: balanceTitle.leadingAnchor, constant: 8),
            balanceTitleLabel.centerYAnchor.constraint(equalTo: balanceTitle.centerYAnchor),
        ])
        balanceTitle.hoverDwellDuration = Motion.hoverDwell
        balanceTitle.hoverDebugLabel = "AgentTitle"
        balanceTitle.onHoverConfirmed = { [weak self] in self?.confirmTokensHover(source: .aggregate) }
        balanceTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(balanceTitle)
        pinFullWidth(balanceTitle, in: root)
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
        balanceGroupContainer.setCustomSpacing(platformCardGap, after: zcodeCardsContainer)

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
        balanceGroupContainer.setCustomSpacing(platformCardGap, after: codexCardsContainer)

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
        balanceGroupContainer.setCustomSpacing(platformCardGap, after: traeCardsContainer)

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
        balanceGroupContainer.setCustomSpacing(platformCardGap, after: wbCardsContainer)

        // 应用上次拖拽保存的平台顺序；隐藏的账号组仍保留位置，之后重新出现时顺序不跳变。
        // 须在两组容器都建好后调用：重排按组内过滤进行
        applyPlatformOrder(animated: false)

        // Agent 区块 → Token 板块（分割线已移除，用区块间距分隔；09-13 统一-1pt；
        // 2026-09-14 用户「各个板块间隔缩小 2pt」9 → 7）
        root.setCustomSpacing(7, after: balanceGroupContainer)

        // ── Token 板块（内嵌 ZCode / WorkBuddy 卡片 hover 子面板同款内容，单实例，
        // 只显示 Agent 组最顶上平台的 Token；不可折叠。顶部平台无 Token 数据源或无数据时整块隐藏）──
        let tokenTitle = plainSectionTitle(name: "Token")
        root.addArrangedSubview(tokenTitle)
        pinFullWidth(tokenTitle, in: root)
        root.setCustomSpacing(0, after: tokenTitle)
        tokenTitleRef = tokenTitle
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
        // 初始隐藏：数据异步到达后由 applyInlineTokensVisibility 统一裁决显隐
        tokenCard.isHidden = true
        tokenTitle.isHidden = true
        // Token 板块 → 用量区块（09-13 统一-1pt；2026-09-14 用户「各板块间隔缩小 2pt」9 → 7）
        root.setCustomSpacing(7, after: tokenCard)
        // 填充内嵌内容并启动低频刷新（数据源 60s 后台缓存，fetch 只回缓存零读取）
        setupInlineTokens()

        // ── 日/周用量区块（可折叠；行内容随快照重建）──
        var usageCollapseTargets: [NSView] = []
        // 标题英文（与 API / Token 两个区块标题同口径，2026-09-16 用户要求）
        let usageTitle = collapsibleSectionTitle(name: "Usage", key: UDKey.usageSectionCollapsed,
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
        // 列表行共享 hover 材质宿主（渐变背景+描边行间整块滑动，与卡片同款；
        // 装在稳定容器上——行随数据刷新重建，宿主不跟着重建）
        usageContentStack.installHoverMaterialHost()
        let usageCard = addCard(rows: [usageContentStack], to: root, spacing: 6, topPadding: 2, horizontalPadding: 0)
        usageCardRef = usageCard
        usageCollapseTargets = [usageCard]
        let usageCollapsed = UserDefaults.standard.bool(forKey: UDKey.usageSectionCollapsed)
        usageCard.isHidden = usageCollapsed
        root.setCustomSpacing(usageCollapsed ? 6 : 0, after: usageTitle)
        // 操作区块 2026-09-13 整体移除（磁贴功能各奔前程：Cockpit → header 第五颗，
        // 添加账号/Key额度/签到历史/同步共享/关于 → 设置窗口与状态栏菜单；3D 硬币演示、
        // 手动签到随板块退场）：用量为面板最后一个区块，其下 9pt 即收尾间距
        root.setCustomSpacing(9, after: usageCard)

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

        registerFont(updatedLabel, size: 9, weight: .regular)
        updatedLabel.textColor = Palette.panelHeaderContentColor
        // 原贴底 footer（GitHub 按钮）2026-09-13 整体移除：按钮迁入 header 左侧按钮组，
        // 底部不再有固定区，root 底部 cap 同步收窄到底边距 11pt（见上方 rootBottomCap）
    }

    /// 卡片容器：NSVisualEffectView（自动适配深浅色）+ 圆角 + 内边距，宽度撑满 root。
    /// title 非空时在顶部加一行小标题；spacing 为行距（设置卡片用 12，余额卡片用默认 6）。
    /// 有点击、右键或拖拽回调时卡片使用 HoverCard；设置卡片用普通 NSView。
    /// bottomPadding: 卡片底部内边距（默认 7，Token/用量卡片给 2 以收紧与相邻板块的间距；原
    /// `stretchRows: false` 的「不满一行」特例随操作磁贴行 2026-09-13 退场，行内恒定撑满整宽）
    @discardableResult
    func addCard(rows: [NSView], to root: NSStackView, title: String? = nil, spacing: CGFloat = 6, onClick: (() -> Void)? = nil, onRightClick: ((NSEvent) -> Void)? = nil, onDragStarted: ((NSPoint) -> Void)? = nil, onDragChanged: ((NSPoint) -> Void)? = nil, onDragEnded: (() -> Void)? = nil, topPadding: CGFloat = 7, bottomPadding: CGFloat = 7, horizontalPadding: CGFloat = 8, trailingPadding: CGFloat? = nil, titleColor: NSColor = Palette.secondaryForeground, cardBackground: NSColor? = kCardBackground) -> NSView {
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
        // 子行横向撑满，数值靠行内 spacer 推到右端（面板里已无「行内元素各自定宽、按内容排」的行）
        all.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        // 卡片透明背景（露出 popover 原生玻璃），仅保留圆角 + 细边框区分
        // 余额卡片使用 HoverCard 获得 hover 高亮 + 点击回调；设置卡片用普通 NSView
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
        card.layer?.cornerRadius = Palette.hoverCardCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        // 卡片自身恒无边框：HoverCard 的 hover 材质由容器共享（HoverMaterialHost），
        // 普通 NSView 卡片本就不画边框
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

    /// 分组标题行：标题字号 = **卡片主标题字号**（2026-09-16 用户要求「板块标题跟随卡片
    /// 主标题字号」；原先硬编码 13pt，见 `registerSectionTitle`）+ 副前景灰，左对齐，
    /// 固定行高 24pt（10…16pt 都装得下，版心高不随字号连锁变化）
    private func sectionTitleRow(name: String, color: NSColor = Palette.secondaryForeground) -> NSStackView {
        let label = NSTextField(labelWithString: name)
        registerSectionTitle(label)
        label.textColor = color
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    /// 静态区块标题条（不可折叠）：与可折叠标题同字号、同左缩进、同高，无箭头无点击无 hover。
    private func plainSectionTitle(name: String) -> NSView {
        let label = NSTextField(labelWithString: name)
        registerSectionTitle(label)
        label.textColor = Palette.secondaryForeground
        label.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            v.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    /// 可折叠区块标题条：hover 复用余额卡片样式（HoverCard hover 背景色+统一 1.2pt 发丝边框），
    /// 点击切换折叠并持久化（UserDefaults，key 走 UDKey）。整条撑满 root 宽：
    /// 标题文字左对齐余额标题（内边距 8），箭头（▸ 折叠 / ▾ 展开）靠右贴卡片内边界。
    /// targets 闭包返回随折叠一起隐藏的视图（build 在区块内容创建后才会填充，闭包按引用取最新值）；
    /// 初始折叠态由 build 在填完 targets 后自行应用（isHidden + 间距）。
    private func collapsibleSectionTitle(name: String, key: String,
                                         targets: @escaping () -> [NSView]) -> HoverCard {
        let label = NSTextField(labelWithString: name)
        registerSectionTitle(label)
        label.textColor = Palette.secondaryForeground
        let chevron = NSImageView()
        chevron.contentTintColor = Palette.secondaryForeground
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
            hc.clearHoverEffect()
            apply(collapsed)
        }
        hc.wantsLayer = true
        // 圆角与余额卡片统一（hoverCardCornerRadius = 9pt，2026-09-13 由 10 改）
        hc.layer?.cornerRadius = Palette.hoverCardCornerRadius
        hc.layer?.cornerCurve = .continuous
        hc.layer?.masksToBounds = true
        // hover 材质（背景 + 框）由容器共享（HoverMaterialHost），卡片自身恒无边框
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

    /// 品牌图标资产（ictool 从 *.icon 源包预导出的 PNG，256@1x）。
    /// Icon Composer 的 .icon 源包 NSImage 无法运行时加载、也无公开变体选择 API，
    /// 故构建期按 rendition 导出 PNG 随 Resources 分发；保持原色非 template。
    /// 表里没有的条目（资产缺失，如旧 bundle）由调用方回退 SVG template。
    /// 键 = CardStyle.icon 图标名；ZCode 与 ZhiPu 共用 "zhipu" 品牌图标名，两卡同时生效。
    /// 深色 = `<平台>.png`（macOS Dark，--design-generation 26；早期各卡为 ClearDark），
    /// 浅色 = `<平台>-light.png`（macOS Default，--design-generation 27；
    /// 2026-09-06 初版误用 ClearLight 已重导为 Default）。
    /// 键名与资源名不一致的仅两处：ZCode/ZhiPu 共用 "zhipu"、TRAE 卡 icon 名为 "trae-color"。
    /// 命中即用、非 template 不着色；对应外观资产缺失时回退另一版，再无则回退原 SVG template
    private static let brandDarkImages: [String: NSImage] = BalancePanelView.loadBrandImages(suffix: "")
    private static let brandLightImages: [String: NSImage] = BalancePanelView.loadBrandImages(suffix: "-light")

    private static func loadBrandImages(suffix: String) -> [String: NSImage] {
        var images: [String: NSImage] = [:]
        for (iconName, resource) in [
            "workbuddy": "workbuddy",
            "zhipu": "zcode",
            "deepseek": "deepseek",
            "qwen": "qwen",
            "trae-color": "trae",
            "codex": "codex",
        ] {
            guard let url = Bundle.main.url(forResource: resource + suffix, withExtension: "png"),
                  let img = NSImage(contentsOf: url) else { continue }
            img.isTemplate = false
            images[iconName] = img
        }
        return images
    }

    /// 按生效外观取品牌 icon（深/浅缺资产时回退另一版；都缺返回 nil → 调用方走 SVG
    /// template）。internal：主题/系统外观切换时 BalancePanelView 就地换图标
    ///（CardEntry.brandIconKey）
    static func brandIconImage(_ iconName: String, dark: Bool) -> NSImage? {
        let preferred = dark ? brandDarkImages : brandLightImages
        let fallback = dark ? brandLightImages : brandDarkImages
        return preferred[iconName] ?? fallback[iconName]
    }

    /// 卡片品牌 icon 取图（含深色主题浅色版压暗）：
    /// appearanceIsDark 且取的是浅色版（dark=false）→ 叠黑@10% 降亮度（2026-09-14 用户指定，
    /// sourceAtop 只作用于既有像素、alpha 不变，即 RGB 逐通道 ×0.90）。变体静态缓存
    /// （键名 × 深浅 × 压暗）。
    private static var brandImageVariants: [String: NSImage] = [:]
    static func cardBrandImage(_ iconName: String, dark: Bool,
                               appearanceIsDark: Bool) -> NSImage? {
        guard let base = brandIconImage(iconName, dark: dark) else { return nil }
        let dim = appearanceIsDark && !dark
        guard dim else { return base }
        let key = "\(iconName)|\(dark)|\(dim)"
        if let hit = brandImageVariants[key] { return hit }
        let dimmed = NSImage(size: base.size)
        dimmed.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        NSColor.black.withAlphaComponent(0.10).setFill()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        dimmed.unlockFocus()
        brandImageVariants[key] = dimmed
        return dimmed
    }

    /// 品牌 SVG 原图（「无边框图标」开关用）：资源名与 `CardStyle.icon` 图标名同名
    ///（workbuddy / zhipu / deepseek / qwen / trae-color / codex —— 全部对得上，无需映射表）。
    /// 静态缓存：`bundleIcon` 每次读盘，卡片构建与开关切换都是高频路径，不能直呼。
    /// 这里只负责取**未着色的原图**：template / 前景色着色由 `applyBrandIconImage` 统一设。
    /// 缺资源 / 解析失败返回 nil → 调用方回落 PNG（开关关闭态）或系统符号
    private static var brandSVGImages: [String: NSImage] = [:]
    static func cardBrandSVG(_ iconName: String) -> NSImage? {
        if let hit = brandSVGImages[iconName] { return hit }
        guard let img = bundleIcon(iconName, size: 24) else { return nil }
        brandSVGImages[iconName] = img
        return img
    }

    /// 品牌 icon 取图（设置窗口「主题预设」图卡用）：与卡片**同一条取图口径**，差别只在「谁上色」。
    /// - 无边框（`iconNoBorder`）= 同名 **SVG 原图**，返回 **template** 图 —— 着色交给调用方
    ///   （SwiftUI `Image.renderingMode(.template)` + 该档主前景色；面板那边是 NSImageView +
    ///   `contentTintColor`，两侧读同一档色）。SVG 自带 fill 是写死单色（见 `brandSVGShrink` 上方注释），
    ///   不 template 化必有一半主题下隐形；并按 `brandSVGShrink` 微缩 —— 做法与
    ///   `applyBrandIconImage` 一致：**把内容绘进基准 24pt 画布**（不是改 image.size）。
    /// - 默认 = Icon Composer **PNG**（`brandIconImage` 按深浅档选版），原色直画，不着色。
    static func brandIcon(_ req: BrandIconRequest) -> NSImage? {
        guard req.borderless, let svg = cardBrandSVG(req.key) else {
            return brandIconImage(req.key, dark: req.dark)
        }
        let box: CGFloat = 24                       // SVG 基准框（`bundleIcon(_:size:)` 同口径）
        let ratio = brandSVGShrink[req.key] ?? 1
        let inner = box * ratio
        let canvas = NSImage(size: NSSize(width: box, height: box), flipped: false) { rect in
            svg.draw(in: NSRect(x: rect.midX - inner / 2, y: rect.midY - inner / 2,
                                width: inner, height: inner))
            return true
        }
        canvas.isTemplate = true
        return canvas
    }

    /// 「无边框图标」下的**按平台微缩比例**（表外 = 1 不缩）。
    /// 由来：SVG 是满框裸 logo，而 PNG 里的 logo 只占 Icon Composer 底板的一部分 ——
    /// 同一个 size 下 SVG 显得更大。这三个平台的图形最满，缩 7% 后与其余平台视觉等大
    ///（2026-09-15 用户指定 zcode / codex / trae 缩 7%）。
    /// ⚠️ 键是 `CardStyle.icon` 的图标名：zcode 卡共用 "zhipu"（智谱同图，一并生效）、
    /// trae 卡是 "trae-color"，不是平台名
    private static let brandSVGShrink: [String: CGFloat] = [
        "zhipu": 0.93,
        "codex": 0.93,
        "trae-color": 0.93,
    ]

    /// 「无边框图标」下 SVG 一律按**主要前景色**着色（`Palette.cardForeground`：深色外观 #EBEBEB /
    /// 浅色外观 0.13 黑灰，动态色随生效外观解算）。
    /// 不用 SVG 自带填充色的原因（离线实测）：那些 fill 是**写死的单色** ——
    /// workbuddy / deepseek / qwen / trae-color = `#e9e9e9`（浅灰，为深色底设计）、
    /// zhipu 无 fill（= 黑，浅色底设计）、codex 是渐变彩色；原样直画必有一半平台在对应主题下隐形。
    /// codex 的渐变也一并归到同一口径（2026-09-15 用户指定「svg 需要使用深浅主题的主要前景色」），
    /// 免得同一排图标出现「彩色 + 单色」混排

    /// 品牌 icon 落图：**两条取图来源的唯一收口**（无边框 = 同名 SVG 原图 / 默认 = Icon Composer
    /// 的 PNG），建卡（`balanceContentRow`）与开关/外观变化的就地换图（`applyBrandIcon`）共用。
    /// 同时负责 identifier 标签（`brandIcon:<键>`，就地换图按它找视图）与长进度卡片菜单栏辉光的
    /// maskImage（以 icon 为蒙版，必须随图同步）。
    /// - Parameters:
    ///   - size: 目标显示尺寸（长进度卡片与列表态不同，由调用方按当前版式给）
    ///   - appearance: 取版/着色的生效外观。建卡时传**与容器同源解算**的那份
    ///     （`Palette.panelAppearance(lightTheme:)`，首建未挂窗时 `effectiveAppearance` 会误取系统档），
    ///     换图时传视图自己的 `effectiveAppearance`
    /// - Returns: 是否取到图；两条来源都缺资产时返回 false，由调用方回落 SVG/系统符号
    @discardableResult
    func applyBrandIconImage(_ iv: NSImageView, iconName: String, size: NSSize,
                             appearance: NSAppearance) -> Bool {
        let noBorder = iconNoBorderEnabled
        let targetDark = brandIconDark(for: appearance)
        let source = noBorder
            ? Self.cardBrandSVG(iconName)
            : Self.cardBrandImage(iconName, dark: targetDark, appearanceIsDark: appearance.isDark)
        guard let source else { return false }
        let scaled = source.copy() as! NSImage
        scaled.size = size
        // 无边框：SVG 是**满框裸 logo**（PNG 的 logo 只占 Icon Composer 底板的一部分），
        // 同一尺寸下 SVG 视觉更大 → 按平台微缩（见 brandSVGShrink）。
        // ⚠️ 做法是**把内容绘进一张基准 size 的画布**，不是改 image.size：后者会让 iconView 的
        // intrinsicContentSize 跟着缩，而就地换图路径是拿 `iv.bounds.size` 当基准的 →
        // 换一次缩一次，越换越小。画布用 drawingHandler 形式（按目标 context 实时重绘，
        // 矢量不糊）；别用 `lockFocus`（那是 1x 位图，Retina 上会糊）。
        let shrink = noBorder ? Self.brandSVGShrink[iconName] : nil
        let drawn: NSImage
        if let r = shrink, r < 1 {
            let inner = NSSize(width: size.width * r, height: size.height * r)
            drawn = NSImage(size: size, flipped: false) { rect in
                scaled.draw(in: NSRect(x: rect.midX - inner.width / 2,
                                       y: rect.midY - inner.height / 2,
                                       width: inner.width, height: inner.height))
                return true
            }
        } else {
            drawn = scaled
        }
        // 无边框：SVG 一律当模板，色 = **互换后深浅档**的主前景色 —— 这是「图标深浅互换」
        //（`iconThemeSwap`，语义 = 在生效外观上反向取版）在 SVG 路径上的落点；
        // 用动态色而非静态色：provider 每次绘制按当前外观重解，外观变了不必等换图钩子。
        // 默认 PNG：自带深浅两版资产（按 targetDark 选版），原色直画，tint 必须清掉（残留会污染原色图）
        drawn.isTemplate = noBorder
        iv.identifier = NSUserInterfaceItemIdentifier("brandIcon:" + iconName)
        if noBorder {
            let swap = iconThemeSwapEnabled
            iv.contentTintColor = NSColor(name: nil) { appearance in
                Palette.resolvedCardForeground(dark: appearance.isDark != swap)
            }
        } else {
            iv.contentTintColor = nil
        }
        iv.image = drawn
        iv.superview?.subviews.compactMap { $0 as? CardMenuBarGlowView }.forEach {
            $0.maskImage = drawn
        }
        // 状态层「中心让位」同步（同「附属物随图更新」的口径）：切开关 / 换深浅版 / 外观变化
        // 三条换图路径都经这里（建卡路径由 balanceContentRow 建好后补设同一入口）
        syncStatusRingCarve(iv)
        return true
    }

    /// 状态层「中心让位」的唯一入口（建卡处与换图处共用，别两处各写一份）：
    /// 形状源 = 「无边框图标」开关（SVG 原图 ⇒ `.circle`：圆形轨迹 + 与 icon 内切的圆形挖空；
    /// PNG 底板 ⇒ `.squircle`：不挖），位置源 = iconView（frame 每次 layout 现算）。
    func syncStatusRingCarve(_ iv: NSImageView) {
        iv.superview?.subviews.compactMap { $0 as? CardTaskStatusRingView }.forEach {
            $0.carveIconView = iv
            $0.shape = iconNoBorderEnabled ? .circle : .squircle
        }
    }

    /// 余额卡片内容行：左大 icon + 中间纵向（标题/签到信息）+ 右纵向（额度值/点阵）
    /// 三列撑满整行：icon 与图标列宽同宽（27.75pt，2026-09-05 由 25pt +15%） / middle ≥ 70% / right 40pt
    /// 中间内容垂直居中；点阵进度放右侧额度值下方（DeepSeek 无点阵）
    /// failureBadge：外部创建的签到失败角标视图，叠加在 icon 右上角（显隐由调用方控制）
    /// 组内平台卡间距：2026-09-10 用户指定 2pt（原「列表态 4 / 长进度 2.5」档位差取消，
    /// 统一 2）；调间距只改这一个常量，建组 4 处 setCustomSpacing + applyPlatformCardGaps() 会跟着走
    var platformCardGap: CGFloat { 2 }
    /// 按当前模式刷新两组组内平台卡间距（开关切换时调用；
    /// 与建组时口径一致：每对前后都预置，任意拖拽顺序通吃）
    func applyPlatformCardGaps() {
        guard let api = apiGroupContainer, let agent = balanceGroupContainer else { return }
        // 容器为隐式解包可选，显式标注元素类型走 IUO 自动解包（建组后恒非空）
        let apiCards: [NSStackView] = [dsCardsContainer, zhipuCardsContainer, qwenCardsContainer]
        let agentCards: [NSStackView] = [zcodeCardsContainer, codexCardsContainer, traeCardsContainer, wbCardsContainer]
        for c in apiCards { api.setCustomSpacing(platformCardGap, after: c) }
        for c in agentCards { agent.setCustomSpacing(platformCardGap, after: c) }
    }

    /// 副标题行固定行高（列表态 row2 / 长进度卡 subRow 共用，历史三处写死 12，2026-09-14 收口）。
    /// 也是默认卡片竖向进度条的高度基准之一：条高 = 主标题行高 + 本值
    static let subRowHeight: CGFloat = 12

    /// 默认卡片「主标题行 ↔ 副标题行」的**基准行距**（2026-09-06 用户指定 +1.5pt 的定稿值）。
    /// 实际行距 = 本值 × 字体系数（`cardTitleGapScaleSF/SG`，两档已**固化**：2026-09-15 起
    /// 常量在 `BalancePanelView.cardTitleGapScaleSFFixed / SGFixed`，设置窗口不再开放）：
    /// 主标题去掉硬行框高度后由字体自然行高决定，SG（字面 em 恒 1.0em、更扁）与 SF 的
    /// 字形框疏密不同，同一系数兼顾不了，故两档分设
    static let titleRowBaseGap: CGFloat = 1.5

    /// 系统字体数字墨迹高（CTLine glyph path bounds，取「0」字形实测）：
    /// 数值基线锚 offset = 数字墨迹半高，墨迹中心与行中心精确重合——capHeight 是
    /// 大写字高，与数字字形高有固有差且误差随字号放大（见 valueBaseline 创建处注释）。
    /// balanceContentRow（build）与 applyCardTitleFont（就地联动）两处共用，internal。
    /// ⚠️ 这里的 `NSFont.systemFont` 是**刻意的**，不是漏改 —— 它量的是「基线该放哪」这个
    /// 与字形无关的锚点，只由字号决定；若改走 `PanelFont`，SG 档下 offset 会随字体变，
    /// 切字体时数值整行上下跳一次（正是 2026-09-13 定稿要避免的）。SG 全覆盖不含这一处。
    static func systemDigitInkHeight(_ size: CGFloat) -> CGFloat {
        let attr = NSAttributedString(string: "0", attributes: [.font: NSFont.systemFont(ofSize: size)])
        return CTLineGetBoundsWithOptions(
            CTLineCreateWithAttributedString(attr), [.useGlyphPathBounds]).height
    }

    func balanceContentRow(icon iconName: String, name: String, valueView: RollingNumberView, info: NSStackView?, dots: UsageDots?, iconSize: CGFloat = 24, imageSize: CGFloat? = nil, iconTint: NSColor = Palette.cardForeground, titleWeight: NSFont.Weight = .semibold, valueWeight: NSFont.Weight = .medium, textColor: NSColor = Palette.cardForeground, failureBadge: NSView? = nil, premadeIconView: NSImageView? = nil, hoverSubStrip: NSView? = nil, subtitleMeta: NSView? = nil, valuePrefixIcon: String? = nil, longProgressCard: Bool = false, titleLabelRef: ((FadeableTextField) -> Void)? = nil, menuBarDotRef: ((NSView) -> Void)? = nil, statusRingRef: ((CardTaskStatusRingView) -> Void)? = nil) -> NSView {
        var imgSize = imageSize ?? iconSize
        // 长进度卡片：icon 缩小 40% 与主标题同行（2026-09-06 用户指定），
        // 2026-09-13 再「缩小2pt」→ 27.75×0.6−2 = 14.65；图标列（长进度 = icon 见方）随之；
        // 普通样式：icon 直定 25pt（2026-09-13 用户终版，调参史 09-06 −2 → 09-13 −4 → −3 → 25），
        // 仍居中于 27.75 图标列（CardStyle.iconSize 与列宽不变，差值由列内留白承接）
        if longProgressCard {
            imgSize = imgSize * 0.6 - 2
        } else {
            imgSize = 25
        }
        // 左：大 icon（统一图标列宽 = 27.75pt，2026-09-05 由 25pt +15%，与 icon 等宽；
        // 约束写死不随 iconSize 变；image 在列内居中显示，imageSize 可独立缩小）；
        // premadeIconView 由外部传入（多号卡片预建 icon 视图，普通 NSImageView 即可）
        let iconView = premadeIconView ?? NSImageView()
        // 品牌卡特例（WorkBuddy / ZCode+ZhiPu / DeepSeek / Qwen / TRAE / Codex）：macOS27
        // Clear 系列（深 ClearDark / 浅 ClearLight 按生效外观），整图自带配色非 template 不着色；
        // identifier 标签供外观切换时就地换版（见 viewDidChangeEffectiveAppearance）
        // ⚠️ 首建时本视图尚未挂窗，effectiveAppearance 回落系统外观：浅色主题开关
        // （容器强制 aqua）下会误取深色版，且初次挂载不补发外观钩子、错版图标常驻。
        // 与容器同源解算（panelAppearance 强制档），未强制时才回落系统外观
        let brandAppearance = Palette.panelAppearance(lightTheme: lightThemeEnabled)
            ?? NSApp.effectiveAppearance
        // brandIconDark：生效外观 ⊕ 图标深浅互换开关（开关开启时深浅版互换）
        // 无边框图标开关（2026-09-15 用户要求）：跳过 Icon Composer 导出的 PNG（自带 squircle
        // 底板），改用同名 SVG 原图；两条来源统一在 applyBrandIconImage 里落图
        if !applyBrandIconImage(iconView, iconName: iconName,
                                size: NSSize(width: imgSize, height: imgSize),
                                appearance: brandAppearance) {
            // 两条来源都缺资产（旧 bundle / SVG 解析失败）：回落同名 SVG 或系统符号，按 template 着色
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
        // 长进度卡片：图标列取消，iconContainer 缩为 icon 见方（左侧点位 lane 已随指示
        // 改为 icon 辉光而取消）、直接进标题行前缘（行宽让给进度条 → 进度条贯穿整卡内容宽）
        let iconColumnWidth: CGFloat = longProgressCard ? imgSize : 27.75
        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        if let ringRef = statusRingRef {
            // 任务状态发光底层（WB / ZCode 当前账号卡）：撑满 iconContainer（尽可能大），
            // icon 叠加其上居中；menuBarDot / 失败角标仍锚定 iconView，位置不变
            let ring = CardTaskStatusRingView()
            ring.translatesAutoresizingMaskIntoConstraints = false
            iconContainer.addSubview(ring)
            iconContainer.addSubview(iconView)            // 长进度卡片：host 含左侧点位 lane，光环钉 icon 本体（钉容器会整体偏左）
            let ringBounds = longProgressCard ? iconView : iconContainer
            NSLayoutConstraint.activate([
                ring.leadingAnchor.constraint(equalTo: ringBounds.leadingAnchor),
                ring.trailingAnchor.constraint(equalTo: ringBounds.trailingAnchor),
                ring.topAnchor.constraint(equalTo: ringBounds.topAnchor),
                ring.bottomAnchor.constraint(equalTo: ringBounds.bottomAnchor),
                longProgressCard
                    ? iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor)
                    : iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
                // 统一图标列宽（不再随各平台 iconSize 变化）：所有卡标题严格左对齐
                iconContainer.widthAnchor.constraint(equalToConstant: iconColumnWidth),
            ])
            // 状态层「中心让位」：SVG 原图 icon ⇒ 圆形轨迹 + 圆形挖空（见 syncStatusRingCarve）
            syncStatusRingCarve(iconView)
            ringRef(ring)
        } else {
            iconContainer.addSubview(iconView)
            NSLayoutConstraint.activate([
                longProgressCard
                    ? iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor)
                    : iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
                // 统一图标列宽（不再随各平台 iconSize 变化）：所有卡标题严格左对齐；
                // 各图标视觉尺寸差异（SVG 留白不同）由 CardStyle.iconSize 单独补偿
                iconContainer.widthAnchor.constraint(equalToConstant: iconColumnWidth),
                iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            ])
        }

        // 菜单栏显隐指示：列表态 = icon 下方 2pt 圆点（直径 3.2，cardForeground 跟随前景色）；
        // 长进度卡片 = icon 四缘描边。显隐由调用方点亮（syncPanel 按 inMenuBar）；
        // 颜色按生效外观解算（动态色直落 .cgColor 会定格外观）
        let menuBarIndicator: NSView
        if longProgressCard {
            let glow = CardMenuBarGlowView()
            glow.translatesAutoresizingMaskIntoConstraints = false
            glow.isHidden = true
            // 以 icon 为蒙版：辉光只透出在 icon 图案的不透明像素上，绝不溢出
            //（2026-09-06 用户指定）。与 iconView 同大小、叠加其上（仍低于后建的签到失败角标）
            glow.maskImage = iconView.image
            iconContainer.addSubview(glow)
            NSLayoutConstraint.activate([
                glow.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
                glow.trailingAnchor.constraint(equalTo: iconView.trailingAnchor),
                glow.topAnchor.constraint(equalTo: iconView.topAnchor),
                glow.bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
            ])
            menuBarIndicator = glow
        } else {
            let dot = CardMenuBarDotView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.isHidden = true
            iconContainer.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 3.2),
                dot.heightAnchor.constraint(equalToConstant: 3.2),
                dot.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
                dot.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
            ])
            menuBarIndicator = dot
        }
        menuBarDotRef?(menuBarIndicator)

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

        // 标题行：nameLabel（平台名，Palette.cardForeground）单 label（昵称展示 2026-09-02
        // 移除、透明占位 2026-09-13 一并删除，昵称/徽章由积分按钮悬浮气泡承载）
        // FadeableTextField：wantsLayer 承载 hover 字重动画
        let nameLabel = FadeableTextField(labelWithString: name)
        nameLabel.textColor = textColor
        // 暴露 nameLabel 给调用方（如 hover 字重动画驱动）
        titleLabelRef?(nameLabel)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 平台标题优先保持完整；压缩阻力 998（标题右缘让位约束 999 最后兜底）：
        // 字号/Sharp Grotesk 放大后横向放不下时标题尾部省略，且明确禁折行
        // —— 标题与积分/金额恒在同一行
        nameLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(998), for: .horizontal)
        nameLabel.cell?.wraps = false
        nameLabel.lineBreakMode = .byTruncatingTail
        // 2026-09-14 用户要求：**主标题不再写死行框高度**（原 cardTitleFontSize + 3）——
        // 交给字体自然行高（SG 字面 em 框恒 1.0em、比 SF 扁，硬编码的 +3 对它恒多出 2pt，
        // 会顶到 row1 之外）；行内垂直位置仍由下方 baseline 约束锚定，视觉基线不变，
        // 主副标题的疏密交给「行距 = 基准 × 字体系数」（见 content.spacing 与设置窗口「卡片」栏）

        // 与多账号卡同构：空 stack 包裹（裸 nameLabel 直接挂行实测起点偏 -2pt，
        // stack 包裹后与其他卡起点一致）
        let titleRow = NSStackView(views: [nameLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 额度值（右对齐；逐位数字垂直滚动 RollingNumberView），
        // 与标题冲突时数值优先（required），标题尾部省略；
        // 基线对齐用视图内置探针（同字体隐藏 label 的 firstBaselineAnchor）。
        // 字号与主标题同档（2026-09-06 用户指定「余额跟主标题同一行, 字号一样」；
        // 2026-09-13 起随主标题字号设置联动，积分/金额 + ¥$ 前缀一并缩放）
        registerRollingNumber(valueView, size: cardTitleFontSize, weight: valueWeight)
        valueView.setTextColor(textColor)
        // 数值前缀图标（Agent 卡积分前的 coin）：贴数字左侧、底边落数字基线（见 RollingNumberView
        // relayoutSlots），随槽位右对齐成组。按**烘焙基准**边长烤（2× 光栅，覆盖最大字号的绘制尺寸
        // = 字号/2），绘制时按需缩放，离开 hover 无损复原
        if let pfx = valuePrefixIcon {
            valueView.prefixIcon = Self.trimmedBundleSvgIcon(pfx, size: RollingNumberView.baseIconSize)
        }
        valueView.setContentHuggingPriority(.required, for: .horizontal)
        valueView.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueView.translatesAutoresizingMaskIntoConstraints = false
        // 数值列宽随字号等比缩放（65 = 13pt × 5 的定稿比例，2026-09-06 定稿口径）；
        // 约束引用交 registerCardTitle，字号设置变化时就地调
        let valueWidth = valueView.widthAnchor.constraint(equalToConstant: cardTitleFontSize * 5)
        valueWidth.isActive = true

        // 第一行：标题（左）+ 数值（右）同一行（两种卡型同构，2026-09-06 默认卡片改版回位）
        // 用普通 NSView + 显式约束，避免 NSStackView gravity 分布歧义
        let row1 = NSView()
        row1.translatesAutoresizingMaskIntoConstraints = false
        row1.addSubview(titleRow)
        if longProgressCard {
            row1.addSubview(iconContainer)
            NSLayoutConstraint.activate([
                iconContainer.leadingAnchor.constraint(equalTo: row1.leadingAnchor),
                iconContainer.centerYAnchor.constraint(equalTo: row1.centerYAnchor),
            ])
        }
        row1.addSubview(valueView)
        // 标题右缘 ≤ 数值**内容前缘**（999，全场唯一可让位约束）：空间不足时标题先截断，
        // 数值列宽/行高（required）永不让位 —— 标题与积分/金额恒在同一行。
        // 钉 contentLeadingGuide（数字墨迹组最左缘，随 setText/字号/位数实时更新）而非
        // 数值列前缘：列宽为最宽数字组合预留，短数值右锚后列内留白大——标题可借用
        // 留白尽量完整显示（2026-09-13 用户「大字号下 WorkBuddy 显示不完整」；此前
        // 恒挡列前缘，间隙档 −4/0/+8/4 历史均废）。guide 未布局时回退列前缘（保守）
        let titleTrailingLimit = titleRow.trailingAnchor.constraint(
            lessThanOrEqualTo: valueView.contentLeadingGuide.leadingAnchor, constant: -3)
        titleTrailingLimit.priority = NSLayoutConstraint.Priority(999)
        // 数值垂直锚 = 基线（2026-09-13 用户定稿：不用按各字体度量反推的补偿）：
        // 探针基线钉 row1 中心下方「系统字体**数字墨迹半高**」处——offset 只由字号决定，
        // 同字号下任何字体（SF / Sharp Grotesk / Mono）基线位置恒等，切字体整行不跳。
        // 2026-09-13 二次校准：旧公式 capHeight/2 用大写字高近似数字墨迹高，两者有固有
        // 差（CTLine glyph bounds 实测差 ~2%），误差随字号放大 → 15pt 下数值微偏上；
        // 改实测「0」字形墨迹高，墨迹中心与行中心精确重合。字号变化时由
        // applyCardTitleFont 就地更新 constant
        let valueBaseline = valueView.baselineAnchor.constraint(
            equalTo: row1.centerYAnchor,
            constant: Self.systemDigitInkHeight(cardTitleFontSize) / 2)
        // 主标题注册（label + 数值视图 + 列宽/基线约束捆成一组，字号设置变化时就地联动重刷）
        registerCardTitle(nameLabel, weight: titleWeight, rolling: valueView,
                          valueWidth: valueWidth, valueBaseline: valueBaseline)
        NSLayoutConstraint.activate([
            // 长进度卡片：标题起于 icon 右 4pt（2026-09-06 用户指定 -2pt，原 6）；列表态：标题起于行前缘
            longProgressCard
                ? titleRow.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 4)
                : titleRow.leadingAnchor.constraint(equalTo: row1.leadingAnchor),
            titleTrailingLimit,
            // 行高跟随数值视图固有高（max(行高, 基线探针行高)，随主标题字号设置缩放，
            // 卡片高度随之变化；13pt 时即原固定 16pt 口径）
            row1.heightAnchor.constraint(equalTo: valueView.heightAnchor),
            titleRow.firstBaselineAnchor.constraint(equalTo: valueView.baselineAnchor),
            // 数值右锚 +2.5pt 光学偏移（2026-09-07 用户由 0.7 逐步调大；进度条在右侧独立容器，
            // 见 row 组装处，标题/副标题行右缘对齐后不与条同区）
            valueView.trailingAnchor.constraint(equalTo: row1.trailingAnchor, constant: 2.5),
            // 垂直位置由基线锚定（valueBaseline 创建处见上，随字号设置联动）
            valueBaseline,
        ])

        // 第二行：列表态 = 副标题（左）+ 点阵/账号条（右）同行；
        // 长进度卡片 = 进度条独占整行（左缘=主标题最左，槽高 14 容 12pt 子账号 chip 同槽互换）
        // + 副标题下移一行（design/balance-card-mode.html 口径）
        var extraRows: [NSView] = []
        if longProgressCard {
            if dots != nil || hoverSubStrip != nil {
                let barRow = NSView()
                barRow.translatesAutoresizingMaskIntoConstraints = false
                if let dots = dots {
                    dots.translatesAutoresizingMaskIntoConstraints = false
                    // 全宽进度条：两端钉死行宽（列表态为右锚定固有宽 50.09pt，2026-09-06 加长 10%）；
                    // 高 6（2026-09-07 用户由 4 调高——9-06 口径为连续两轮 -1.5pt：7 → 5.5 → 4；
                    // 行槽 14 容 chip 互换不变）。视图高仅约束容器：横态轨道在 barFrame 内
                    // 仍按 UsageDots.barHeight 4.06 居中不随此高变
                    dots.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    dots.heightAnchor.constraint(equalToConstant: 6.0).isActive = true
                    barRow.addSubview(dots)
                    NSLayoutConstraint.activate([
                        dots.leadingAnchor.constraint(equalTo: barRow.leadingAnchor),
                        dots.trailingAnchor.constraint(equalTo: barRow.trailingAnchor),
                        dots.centerYAnchor.constraint(equalTo: barRow.centerYAnchor),
                    ])
                }
                barRow.heightAnchor.constraint(equalToConstant: 14).isActive = true
                extraRows.append(barRow)
            }
            if let info = info {
                // 副标题独占一行；hover 子账号条与其同行靠右（2026-09-06 用户指定：
                // 不再与进度条同槽互换——进度条常驻 barRow 不消失），副标题经渐隐让位
                //（同列表态口径；条隐藏期零宽由 stripZeroWidth 接管，副标题拿回全行）
                info.translatesAutoresizingMaskIntoConstraints = false
                let subRow = NSView()
                subRow.translatesAutoresizingMaskIntoConstraints = false
                let subtitle = hoverSubStrip == nil ? nil : SubtitleFadeView(contentView: info)
                let subtitleView = subtitle ?? info
                subRow.addSubview(subtitleView)
                NSLayoutConstraint.activate([
                    subtitleView.leadingAnchor.constraint(equalTo: subRow.leadingAnchor),
                    subtitleView.centerYAnchor.constraint(equalTo: subRow.centerYAnchor),
                ])
                if let strip = hoverSubStrip {
                    strip.translatesAutoresizingMaskIntoConstraints = false
                    // 条宽阻力 999（同列表态口径）：宽度不足时亏空全由副标题渐隐让位
                    strip.setContentCompressionResistancePriority(
                        NSLayoutConstraint.Priority(999), for: .horizontal)
                    subRow.addSubview(strip)
                    var constraints = [
                        strip.trailingAnchor.constraint(equalTo: subRow.trailingAnchor),
                        strip.centerYAnchor.constraint(equalTo: subRow.centerYAnchor),
                    ]
                    if let subtitle {
                        // 副标题最多占到子账号条左缘，超出部分渐隐
                        constraints.append(subtitle.trailingAnchor.constraint(
                            equalTo: strip.leadingAnchor, constant: -3))
                    }
                    NSLayoutConstraint.activate(constraints)
                }
                // 副标题右侧 meta 标签（同列表态口径）：贴行尾，hover 换入时隐藏
                if let meta = subtitleMeta {
                    meta.translatesAutoresizingMaskIntoConstraints = false
                    meta.setContentCompressionResistancePriority(
                        NSLayoutConstraint.Priority(999), for: .horizontal)
                    subRow.addSubview(meta)
                    NSLayoutConstraint.activate([
                        meta.trailingAnchor.constraint(equalTo: subRow.trailingAnchor, constant: 0.7),
                        meta.centerYAnchor.constraint(equalTo: subRow.centerYAnchor),
                    ])
                }
                subRow.heightAnchor.constraint(equalToConstant: Self.subRowHeight).isActive = true
                extraRows.append(subRow)
            }
        } else {
            // 列表态第二行（2026-09-06 改版）：只剩副标题（左）+ hover 子账号条（右）+
            // 右侧 meta 标签；竖向进度条在右侧独立容器（见 row 组装处），本行元素
            // 右缘与标题行对齐即可，无须让位
            // 用普通 NSView + 显式约束，避免 NSStackView gravity 分布歧义
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
            // hover 其余账号条：row2 尾随（hover 时由卡片 onHover 换入换出），
            // 右缘让开竖向进度条（条粗 + 4pt 间距，与额度值同让位口径）
            if let strip = hoverSubStrip {
                strip.translatesAutoresizingMaskIntoConstraints = false
                // 子账号条永不挤压（2026-09-06 codex 4 账号排查定案）：副标题渐隐尾随是
                // 等式约束、条宽阻力默认 250 与副标题让位优先级打平，宽度不足时 AL 把
                // 亏空摊给两边 → chip 被压 5pt。宽度阻力提到 999：亏空全由副标题渐隐
                // 让位（可缩到 0）；行宽真不够时 999 < 行宽 required，条才是最后让位方。
                strip.setContentCompressionResistancePriority(
                    NSLayoutConstraint.Priority(999), for: .horizontal)
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
            // 副标题右侧 meta 标签（2026-09-06 用户指定）：「子账号 ×N」「7日消耗 xx/天」
            // 贴行尾（与标题行数值同 +0.7 光学锚，右缘对齐）；hover 账号条换入时由
            // 换入逻辑隐藏、离场恢复（同一位抢占此区域）
            if let meta = subtitleMeta {
                meta.translatesAutoresizingMaskIntoConstraints = false
                meta.setContentCompressionResistancePriority(
                    NSLayoutConstraint.Priority(999), for: .horizontal)
                row2.addSubview(meta)
                NSLayoutConstraint.activate([
                    meta.trailingAnchor.constraint(equalTo: row2.trailingAnchor, constant: 0.7),
                    meta.centerYAnchor.constraint(equalTo: row2.centerYAnchor),
                ])
                row2HasContent = true
            }
            // row2 高度由内容撑开（取 info 和 dots 中较高的）
            if row2HasContent {
                row2.heightAnchor.constraint(equalToConstant: Self.subRowHeight).isActive = true
                extraRows.append(row2)
            }
        }

        // 纵向 stack：row1（标题+数值）与第二行（副标题/点阵/账号条）成组垂直居中。
        // 无文字副标题仅有点阵/账号条时（TRAE：签到行占位已移除）第二行照常入组——
        // 容器恒绑定 DS 等高基准，组高=容器高，成组居中即标题行贴顶，
        // 当前账号积分与其他卡对齐靠上。
        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        var contentViews: [NSView] = [row1]
        contentViews.append(contentsOf: extraRows)
        let content = NSStackView(views: contentViews)
        content.orientation = .vertical
        content.alignment = .leading
        // 主副标题行间距 = 基准 × 字体系数（2026-09-14 用户要求）：主标题不再写死行框后，
        // 行距得按字体疏密补偿（SG 更扁）→ 系统字体与 SG 各一档系数，
        // 设置窗口「卡片」栏开放；长进度卡片标题行↔进度条行恒 0（2026-09-06 用户要求贴紧）
        content.spacing = longProgressCard ? 0 : Self.titleRowGap(
            sg: cardTitleSharpGrotesk,
            scaleSF: cardTitleGapScaleSF,
            scaleSG: cardTitleGapScaleSG)
        // 注册行距作用点：设置窗口拖系数时就地改 spacing（不重建卡片，见 applyTitleRowGap）
        registerTitleRowGap(content)
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

        // 默认卡片改版（2026-09-06 用户定稿）：进度条独立成容器（barHolder）排在内容区
        // 右侧——主/副标题行右缘先对齐（两行同宽），右边才是撑满整行高的进度条容器。
        // 2026-09-07 用户改版：竖向形态 = 4 个圆角正方点竖排点阵；2026-09-13 曾改「固定高度」；
        // 2026-09-14 曾为「主标题行高 + 副标题行高」；**2026-09-15 用户：高 = 卡片高的 70%**
        //（见下方约束注释）；点大小与间隔的比例恒不变：宽度由「高 ÷ verticalHeightToSideRatio」
        // 反推（点恒为正方形，边长 = holder 宽）→ 槽高变化整组等比缩放，比例恒定
        var barHolder: NSView?
        if !longProgressCard, let dots = dots {
            dots.isVertical = true
            dots.translatesAutoresizingMaskIntoConstraints = false
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(dots)
            NSLayoutConstraint.activate([
                holder.widthAnchor.constraint(equalTo: dots.widthAnchor),
                dots.widthAnchor.constraint(equalTo: dots.heightAnchor,
                                            multiplier: 1 / UsageDots.verticalHeightToSideRatio),
                dots.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                dots.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                // 条高 = **图标高度**（2026-09-15 用户「改为与 icon 一样的高度」，随平台 iconSize 走）：
                // 定值常量约束，同子树内即可激活。宽度由上面的比例约束反推（点恒正方 ⇒ 整组等比缩放）
                dots.heightAnchor.constraint(equalToConstant: imgSize),
            ])
            barHolder = holder
        }

        // 长进度卡片：无图标列，内容区独占整行（进度条贯穿整卡内容宽）；
        // 默认卡片：图标列 → 内容区（主/副标题行右缘对齐）→ 进度条容器（撑满行高）
        let row = NSStackView(views: longProgressCard ? [contentContainer]
            : (barHolder.map { [iconContainer, contentContainer, $0] } ?? [iconContainer, contentContainer]))
        row.orientation = .horizontal
        // icon 列↔标题区间距：8→5（2026-08-31 用户要求左侧整带统一 -3pt）→ 6.5（同日 +1.5pt 回调；
        // 不动卡片 horizontalPadding 以免右缘数值/点阵列同步位移）
        row.spacing = 6.5
        // 进度条容器左侧间距单独收紧 1.5pt（2026-09-06 用户指定）：内容区↔条 5pt，
        // 图标列↔内容区仍 6.5（条右侧间距即 .trailing gravity 区，stack 末尾无 spacing）
        if let barHolder {
            row.setCustomSpacing(5, after: contentContainer)
        }
        row.alignment = .centerY   // icon 与内容垂直居中
        // .fill：iconContainer 有 required 固定宽约束保持原宽，
        // contentContainer（低拥抱优先级）撑满剩余宽度到行尾，数值/点阵才能右对齐贴边
        row.distribution = .fill
        iconContainer.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        contentContainer.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        barHolder?.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        // 竖向进度条高度 = **图标高**（约束在同子树里，见上面 barHolder 段）。
        // ⚠️ 别改成"挂卡片/行高的比例"：那会织出「卡片高 ↔ 条高」的尺寸环，把整卡顶高 15pt
        //（2026-09-15 三次二分实测，详见 TRAPS「默认卡片竖向进度条」条）。
        return row
    }

    /// 余额卡片的上下内边距（单侧；卡片高 = 行高 + 2 × 本值）。
    /// Panel.rebuildAccountCards 传给 addCard(topPadding:bottomPadding:)
    /// 调参史：5.5（2026-08-31 大小卡统一）→ 6（2026-09-01）→ 7（2026-09-14「上下缩进 +1pt」）
    ///        → **6.4**（2026-09-16 用户「卡片上下内缩进 −0.6pt」）
    /// ⚠️ 两种卡型（默认卡片 / 长进度卡片）共用本常量，改则一起变
    static let cardVerticalPadding: CGFloat = 6.4

    /// 主标题↔副标题行距 = 基准 × 字体系数（按当前字形档取哪一档系数；两档在设置窗口「卡片」栏可调）
    static func titleRowGap(sg: Bool, scaleSF: CGFloat, scaleSG: CGFloat) -> CGFloat {
        titleRowBaseGap * (sg ? scaleSG : scaleSF)
    }

    /// 行距作用点注册：默认卡片的内容 stack（主副行距就地改 spacing 靠它，不重建卡片）。
    /// 注册时顺带清掉已摘出层级的旧 stack —— 卡片重建走的是整套新建，
    /// 旧 stack 的 superview 变 nil，据此判定失效
    func registerTitleRowGap(_ stack: NSStackView) {
        cardGapStacks.removeAll { $0.superview == nil }
        cardGapStacks.append(stack)
    }

    /// 行距系数变化时就地刷新（设置窗口滑杆每次落值调用）。
    /// 长进度卡片模式不走这里 —— 它的标题行↔进度条行恒 0，且该开关本身走卡片重建路径
    func applyTitleRowGap() {
        cardGapStacks.removeAll { $0.superview == nil }
        guard !cardGapStacks.isEmpty else { return }
        let gap = Self.titleRowGap(sg: cardTitleSharpGrotesk,
                                   scaleSF: cardTitleGapScaleSF,
                                   scaleSG: cardTitleGapScaleSG)
        for s in cardGapStacks { s.spacing = gap }
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

    /// 字符化开关（MonoCharSwitch）切换时的模糊→清晰过渡，
    /// 模拟 CSS `filter: blur()` transition：入场/退场时从模糊聚焦成形，仅作用于控件自身。
    ///
    /// ⚠️ **2026-09-17 改自绘**：原先走 `layerUsesCoreImageFilters + layer.filters` 逐帧换
    /// `CIGaussianBlur` 实例——那条路会拉起一整包 179 MB 的图层 CI 着色器库且常驻卸载不掉
    /// （见 TRAPS「内存占用归因」）。现在改成「**一次快照 + CPU 三遍盒式模糊覆盖层**」：
    /// 起手把目标视图渲染成位图，逐帧由 `SoftBlur.boxBlur` 出模糊图盖在目标之上（原视图
    /// 用 alpha 藏起，不用 isHidden —— NSStackView 里隐藏会把占位空间收掉、布局会跳），
    /// 曲线与时长逐字保留（ease-out cubic / 0.35s / 上限 4 设备像素）。
    /// Mono 开关与 Agent 卡「点阵↔其余账号条」互换共用（internal 供 Panel.swift 调用）。
    func playCharBlurTransition(on views: [NSView]) {
        guard !shouldReduceMotion else { return }
        // 先收干净上一轮：ticker 为多调用方共享，新调用接管时必须把旧覆盖层撤掉、
        // 原视图恢复（否则旧目标永远停在「被覆盖」状态）
        finishCharBlurTransition()
        charBlurOverlays = views.compactMap { v in
            guard v.superview != nil, v.bounds.width > 1, v.bounds.height > 1,
                  let snapshot = charBlurSnapshot(of: v) else { return nil }
            let overlay = NSImageView(frame: v.frame)
            overlay.image = NSImage(cgImage: snapshot, size: v.bounds.size)
            overlay.imageScaling = .scaleAxesIndependently
            overlay.autoresizingMask = v.autoresizingMask
            v.superview?.addSubview(overlay, positioned: .above, relativeTo: v)
            v.alphaValue = 0
            return (overlay, v, snapshot)
        }
        guard !charBlurOverlays.isEmpty else { return }
        let duration = 0.35
        let maxRadius: Double = 4
        let start = CACurrentMediaTime()
        // 出帧源 = 显示器刷新率（DisplayTicker，非 60Hz 定频）：模糊半径逐帧收敛
        let ticker = DisplayTicker(host: self) { [weak self] in
            guard let self else { return false }
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            // ease-out cubic：前段快速收拢，尾段缓慢聚焦
            let eased = 1 - pow(1 - p, 3)
            let radius = max(0, maxRadius * (1 - eased))
            for item in self.charBlurOverlays {
                let image: CGImage? = radius > 0.05
                    ? SoftBlur.boxBlur(item.snapshot, sigmaPx: radius) : item.snapshot
                item.overlay.image = NSImage(cgImage: image ?? item.snapshot, size: item.target.bounds.size)
            }
            if p >= 1 {
                self.finishCharBlurTransition()
                return false
            }
            return true
        }
        charBlurTicker = ticker
        ticker.start()
    }

    /// 收尾 / 打断：撤掉覆盖层、恢复原视图，并停表（幂等）
    private func finishCharBlurTransition() {
        charBlurTicker?.stop()
        charBlurTicker = nil
        guard !charBlurOverlays.isEmpty else { return }
        for item in charBlurOverlays {
            item.overlay.removeFromSuperview()
            item.target.alphaValue = 1
        }
        charBlurOverlays.removeAll()
    }

    /// 目标视图的静态快照（与拖拽幽灵同口径：先提交布局/绘制，再 cacheDisplay）
    private func charBlurSnapshot(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
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

    // ── header 图标按钮统一口径（退出/设置/刷新周期饼图/GitHub/Cockpit/平台开关 六颗共用）──

    /// header 图标统一 pt 尺寸（= RefreshPieButton.pieDiameter：饼图 11pt 直径 + 1pt 描边，
    /// 与其余 SF Symbol / SVG 图标视觉同尺寸）
    static let headerIconPointSize: CGFloat = 11

    // ── header 图标槽位（拖动落点）──
    // 2026-09-14 用户：header 按钮空间平分为若干位置，可拖到任意位置（允许留空）；
    // 随后「改为9个位置，header 左右缩进相同，间距随之分配」。

    /// header 左侧按钮区的槽位数（2026-09-14 由 10 改为 9）
    static let headerButtonSlotCount = 9
    /// 槽位条距 header 左缘的起点 —— 同时**就是右缘缩进**（左右相同）：
    /// = 容器缩进 11 + 正文缩进 7 + 3.6（2026-09-06 用户「header 左右缩进增加2pt」后
    /// 再「再增加0.6pt」；2026-09-14 用户「header 的左右缩进 +1pt」→ 2.6 → 3.6，
    /// 即 20.6 → **21.6**）。对齐关系：正文内容左右缘距容器各 18pt，图标条两端各外扩
    /// 3.6pt（21.6 = 18 + 3.6）→ 图标条与正文块**左右对称**。
    /// ⚠️ 槽间距/节距/槽位条宽都是从本值反解的（见下），改这一处即可，别去手改那些数字。
    static var headerSlotStripLeading: CGFloat {
        BalancePanelViewController.contentHorizontalInset + 10.6
    }
    /// 槽间距：由「左右缩进相同」**反解**出来的量，不是手填常量 ——
    /// 可用宽 = panelWidth − 左右缩进 = 254 − 2×21.6 = 210.8，9 颗占 9×22 = 198，
    /// 余 12.8 平分给 8 个槽间距 → 1.6pt（2026-09-22 面板 264→254 后收窄，仍是正间距）。
    /// 增删槽位或改 panelWidth 时这里自动跟着变，不需要回来手改数字。
    static var headerButtonSlotGap: CGFloat {
        let available = BalancePanelViewController.panelWidth - headerSlotStripLeading * 2
        let used = CGFloat(headerButtonSlotCount) * HoverIconButton.buttonSize
        return (available - used) / CGFloat(headerButtonSlotCount - 1)
    }
    /// 槽位节距 = 按钮宽 + 槽间距
    static var headerButtonSlotPitch: CGFloat { HoverIconButton.buttonSize + headerButtonSlotGap }
    /// 槽位条总宽（= panelWidth − 左右缩进，与首尾槽的实际跨度一致）
    static var headerSlotStripWidth: CGFloat {
        CGFloat(headerButtonSlotCount) * HoverIconButton.buttonSize
            + CGFloat(headerButtonSlotCount - 1) * headerButtonSlotGap
    }

    /// header 图标按钮统一构造入口（五颗 HoverIconButton 共用）：
    /// 尺寸（HoverIconButton.buttonSize）、图标口径（headerIconImage）、常态色
    /// （**副前景色** `Palette.secondaryForeground`：系统灰为基准 + 按面板底色解算对比度补偿，
    /// 2026-09-14 用户要求；原为两档固定色 `Palette.panelHeaderContentColor`）、
    /// hover 提亮（HoverIconButton.hoverTintColor 默认 labelColor）与 hover 底
    /// （HoverIconButton.hoverBackgroundColor）全部同源 ——
    /// 同组按钮的 hover 观感由构造保证一致，不存在单颗特例；新增一颗只加一行调用。
    /// ⚠️ 这里给的是**初值**：真正落屏的常态色由 `applyHeaderButtonSlots` 按落点统一覆写 ——
    /// 中间格 = 卡片主标题色、其余格 = 本副前景色（两档口径见 PanelDrag）。
    /// 垂直位置：六颗（含 RefreshPieButton）都只钉 centerY = headerRowCenterY，
    /// 图标一律按墨迹外框居中，**没有任何按图标微调的偏移参数**（对齐口径唯一）。
    /// - symbol：SF Symbol 名；svgIcon：bundle 内品牌 SVG 名（优先，缺失回退 symbol）
    private func makeHeaderIconButton(in parent: NSView, symbol: String? = nil,
                                      svgIcon: String? = nil,
                                      action: Selector, tooltip: String) -> HoverIconButton {
        let btn = HoverIconButton()
        btn.image = headerIconImage(symbol: symbol, svgIcon: svgIcon)
        btn.normalTintColor = Palette.secondaryForeground
        btn.target = self
        btn.action = action
        btn.toolTip = tooltip
        btn.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(btn)
        return btn
    }

    /// header 图标统一取图：bundle 品牌 SVG 优先、缺失回退 SF Symbol，两者都走项目既有的
    /// 「裁墨迹」口径（trimmedBundleSvgIcon / trimmedSymbolImage）—— 去掉图形自带画布的
    /// 留白，图像边界 = 墨迹外框，按钮居中画布即墨迹外框居中。
    ///
    /// 只做这一件事：各 symbol 画布留白不对称（宽度 12/13/14 不等、墨迹在画布内偏心最多
    /// 0.5pt），裁掉后所有图标按同一条「外框居中」规则落位，横向间距与纵向基线自然齐平。
    /// 曾经额外加过「按图形质心/圆环中心再上移」的修正，属于对单个字形的主观微调 ——
    /// 会让那颗图标的外框偏离同组基线（power 上移 0.75pt 后被看成「退出按钮偏高了」），
    /// 已废弃；同组对齐只认外框这一条口径。
    private func headerIconImage(symbol: String? = nil, svgIcon: String? = nil) -> NSImage? {
        var image = svgIcon.flatMap { Self.trimmedBundleSvgIcon($0, size: Self.headerIconPointSize) }
        if image == nil, let symbol {
            image = Self.trimmedSymbolImage(symbol, size: Self.headerIconPointSize)
        }
        guard let ink = image else { return nil }
        ink.isTemplate = true
        return ink
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
    /// isTemplate=true：调用方用 contentTintColor 统一着色（副标题用副前景色）。
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
    /// 行框高**不再外部固定**（2026-09-14 用户要求去掉行框定义）——走字体自然行高，
    /// 行内垂直位置由 titleRow↔数值视图的 baseline 约束锚定；
    /// 原菜单栏渐变蒙版已随小白点指示替代而移除（2026-08-31）。
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
        /// 进行中态（X 扫描）圆角：7pt 用户指定（2026-09-01）→ 8pt（2026-09-06「增加一点点」），
        /// 独立于完成态的 7pt 与中断态的 side×0.22 等比口径
        static let runningCornerRadius: CGFloat = 8
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
            // 外扩量 3.6pt（2026-09-16 用户指定）：原值 3、中途为排查蒙版裁切临时放到 8，
            // 修好后依次试过 3 → 5 → **3.6** 定稿
            let side = min(bounds.width, bounds.height) - inset * 2 + 3.6
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
            //（随放大底数走，形状比例与未放大时一致）。
            // ⚠️ 形状 = 圆（`.circle`，SVG 原图 icon，2026-09-17 用户要求）时：半径恒取**半边长**
            //（圆角方 → 正圆），曲线同时从 `.continuous` 回落到 `.circular` —— 超椭圆在
            // 半径 = 半边长处虽也退化，但连续曲率会在临界处留一点点方感，显式给圆更稳。
            let isCircle = shape == .circle
            glow.cornerCurve = isCircle ? .circular : .continuous
            glow.cornerRadius = isCircle ? boxSide / 2
                : (taskState == .running ? Self.runningCornerRadius
                   : taskState == .completed ? Self.completedCornerRadius
                   : boxSide * 0.22)
            // 涟漪圈与柔光同基准方；圆态用 `side` 的半边（它比 boxRect 少一层状态放大）
            let ringRadius = isCircle ? side / 2
                : (taskState == .running ? Self.runningCornerRadius
                   : taskState == .completed ? Self.completedCornerRadius
                   : boxSide * 0.22)
            for layer in [ring1, ring2] {
                layer.frame = rect
                layer.cornerCurve = isCircle ? .circular : .continuous
                layer.cornerRadius = ringRadius
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
                // 扫描裁切框与柔光同形：圆态 = 正圆（光束在圆内扫），方态 = 进行中圆角常量
                sweepClip.cornerCurve = isCircle ? .circular : .continuous
                sweepClip.cornerRadius = isCircle ? boxSide / 2 : Self.runningCornerRadius
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
            // 中心挖空蒙版（「无边框图标」模式下用 PNG 图标形状挖掉状态层）随布局重算
            refreshCarveMask()
        }

        // MARK: 状态层形状与中心挖空

        /// 状态层形状（2026-09-17 用户要求）：默认 `.squircle` = 圆角方 —— 与 **PNG icon**
        /// （Icon Composer 底板 = squircle）同形，icon 底板自己就盖住了中心，无需挖空；
        /// `.circle` = 卡片 icon 走 **SVG 原图**（「无边框图标」模式）时用：
        /// 轨迹（柔光 / 双涟漪 / 扫描裁切框）一律成正圆，中心也不再按图标轮廓挖，
        /// 直接挖一个**与 icon 内切的同心圆**（裸 SVG logo 没有可比的底板轮廓，
        /// 方形挖空会留一圈「方角套着圆标」的错位感）。
        enum Shape { case squircle, circle }

        var shape: Shape = .squircle {
            didSet {
                guard oldValue != shape else { return }
                carveRetries = 0        // 形状换了 → 重试预算重置
                needsLayout = true
            }
        }

        /// 蒙版形状的**位置源**（weak）：每次 layout 按它实时换算 icon 在本视图里的 frame，
        /// 避免建卡阶段布局未定时算出的坐标被冻结（字号 / 行高变化后仍跟得上）
        weak var carveIconView: NSImageView? {
            didSet { needsLayout = true }
        }
        /// 上次建蒙版用的键（maskRect + 图标 frame + 图对象 + scale）：不变则不重绘
        private var carveMaskKey: String?

        /// 蒙版范围在视图 bounds 之外的外扩量（见 refreshCarveMask）：
        /// 状态层会溢出 ring，蒙版覆盖不到的地方会被一并裁掉。取 24pt —— 覆盖涟漪最大
        /// scale 扩散（外溢约 10pt）+ 扫描模糊弥散 + 余量。
        private static let carvePad: CGFloat = 24

        /// 中心挖空开关（2026-09-17 用户「去掉蒙版试试」⇒ **停用**）：
        /// `false` = 状态层画满整圈（柔光 / 涟漪 / 扫描完整可见，logo 叠在其上）；
        /// `true` = 用与 icon 内切的同心圆挖掉中心（2026-09-16 至 09-17 的旧行为）。
        /// 改回 `true` 即恢复挖空，其余代码不用动（`.squircle` 模式本来就从不挖）。
        private static let carvesIconCenter = false

        /// ⚠️ 建卡/换图与 icon 落位**不在同一轮布局**里（异步建卡更明显）：首次 `layout()` 时
        /// icon 的 frame 还是 0 → 算出无效 icon frame 只能放弃，而 ring 自身尺寸没变、不会再有
        /// 下一次 layout ⇒ 蒙版永远挂不上（2026-09-16 实测到的「状态层没被裁」）。
        /// 故失败后安排下一拍重试（有限次，非静默降级：每次都会重新尝试挂载）。
        private var carveRetries = 0

        private func scheduleCarveRetry() {
            guard carveRetries < 20 else { return }   // 20 × 0.25s = 5s 覆盖建卡到首帧
            carveRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.needsLayout = true
            }
        }

        /// 构建/更新形状蒙版：**白底 + 中心圆形挖空**（`destinationOut` 按源 alpha 挖）。
        /// 只在 `.circle`（SVG 原图 icon）下挂载 —— `.squircle` 模式 icon 自带底板，无需让位。
        /// 蒙版挂 `layer.mask`（最外层）⇒ 柔光 / 涟漪 / 扫描连同各自的高斯模糊弥散一起被裁，
        /// 不会「形状裁了、糊边留下」。坐标系：视图与位图 context 同为 y 向上、原点左下，
        /// icon frame 直传即可（已离线验证不上下翻转）。
        private func refreshCarveMask() {
            guard Self.carvesIconCenter, shape == .circle, let iv = carveIconView,
                  bounds.width > 1, bounds.height > 1 else {
                if layer?.mask != nil { layer?.mask = nil }
                carveMaskKey = nil
                return
            }
            let iconFrame = iv.convert(iv.bounds, to: self)
            guard iconFrame.width > 1, iconFrame.height > 1 else {
                // icon 尚未落位（见 scheduleCarveRetry 注释）：下一拍再试，别就此放弃
                scheduleCarveRetry()
                return
            }
            let scale = window?.backingScaleFactor ?? 2
            // ⚠️ 蒙版范围必须**超出视图 bounds**：状态层会溢出 ring（柔光外扩、涟漪 scale 扩散、
            // 扫描模糊弥散），落在 mask 覆盖范围之外的内容同样会被裁掉（2026-09-16 用户
            // 「外圈被裁剪」的根因）。故四周各留 carvePad，白底铺满整个蒙版范围。
            let maskRect = bounds.insetBy(dx: -Self.carvePad, dy: -Self.carvePad)
            // 挖空圆 = **与 icon 内切**的同心圆（直径取 icon frame 的短边）：圆环带宽度与
            // 方形时代同口径（外圈 − icon 边长）/2，只是把方角收成圆
            let carveDiameter = min(iconFrame.width, iconFrame.height)
            let carveCircle = CGRect(x: iconFrame.midX - carveDiameter / 2,
                                     y: iconFrame.midY - carveDiameter / 2,
                                     width: carveDiameter, height: carveDiameter)
            let key = "circle|\(maskRect)|\(carveCircle)|\(scale)"
            if key == carveMaskKey { return }
            let pw = Int((maskRect.width * scale).rounded())
            let ph = Int((maskRect.height * scale).rounded())
            guard pw > 0, ph > 0,
                  let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return
            }
            ctx.scaleBy(x: scale, y: scale)
            // 把原点挪到蒙版范围原点，之后「视图坐标」直接可用（iconFrame 即视图坐标系）
            ctx.translateBy(x: Self.carvePad, y: Self.carvePad)
            // 白 = 全保留（蒙版只取 alpha，RGB 无所谓）—— ⚠️ 必须铺满**整个 maskRect**：
            // 只铺 `bounds` 或 `origin: .zero` 起算都不行（后者只覆盖「视图原点往右上」那一块，
            // 左下两侧的外扩带会漏成透明 → 光晕被**单侧**裁掉，2026-09-16 用户「光晕不完整」）。
            // maskRect 本身就定义在视图坐标系里，直接拿来铺即对齐。
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(maskRect)
            // destinationOut：按源 alpha 挖掉目标 —— 圆内即「不显示状态层」的区（logo 让位）
            ctx.setBlendMode(.destinationOut)
            ctx.fillEllipse(in: carveCircle)
            ctx.setBlendMode(.normal)
            guard let out = ctx.makeImage() else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let mask = layer?.mask ?? CALayer()
            mask.frame = maskRect
            mask.contentsScale = scale
            mask.contents = out
            if layer?.mask !== mask { layer?.mask = mask }
            CATransaction.commit()
            carveRetries = 0
            carveMaskKey = key
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }

        /// 视图（重新）进入窗口后动画不会自动续播：接管挂载时机重铺
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restartAnimationsIfNeeded()
            // 面板显示（视图挂窗）时补一次蒙版：首次 layout 时 icon 可能还没落位
            refreshCarveMask()
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
            // 进行中蓝（2026-09-01 提亮一档：115/199/255 → 140/214/255；
            // 2026-09-08 饱和度统一 +10%：S 0.45 → 0.495 → 129/210/255）
            case .running: ns = NSColor(calibratedRed: 0.505, green: 0.824, blue: 1.0, alpha: 1)
            // 完成绿（2026-09-08 饱和度统一 +10%：S 0.526 → 0.579 → 130/242/102）
            case .completed: ns = NSColor(calibratedRed: 0.51, green: 0.95, blue: 0.40, alpha: 1)
            // 中断橙红（2026-09-02 用户要求故障态换橙红 #FF7333 → #FF4514 → 更亮更红 #FF3300）：
            // 与进行中蓝、完成绿形成色相对比；2026-09-08 饱和 +10% 时 S 已封顶 1.0，值不变
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
            // min 半高钳制：宽 > 高（胶囊形态预留）时呈两端半圆的胶囊
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
            layer?.backgroundColor = Palette.borderCGColor(Palette.cardForeground, in: self)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }
    }

    /// 长进度卡片菜单栏显隐指示辉光：与 iconView 同大小、叠加其上的顶部椭圆高斯白光，
    /// **icon α 烘焙进位图作蒙版**（白光只落在 icon 图案上，绝不溢出）——与卡片 hover
    /// 背景同原理：一次性烘焙含蒙版的最终位图设给 layer.contents，无 CALayer mask。
    /// 椭圆中心=icon 顶缘中点、向下衰减；逐像素 exp 衰减；alpha 按生效外观解算
    ///（动态色直落 .cgColor 会定格外观）
    final class CardMenuBarGlowView: NSView {
        private var bakedKey: (w: Int, h: Int, dark: Bool) = (0, 0, false)
        /// 蒙版源：icon 图像（烘焙时取每像素 α）
        var maskImage: NSImage? { didSet { needsLayout = true } }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let w = max(2, Int(bounds.width * scale))
            let h = max(2, Int(bounds.height * scale))
            let dark = effectiveAppearance.isDark
            guard (w, h, dark) != bakedKey else { return }
            bakedKey = (w, h, dark)
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info),
                  let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
            // 先把 icon 画进缓冲（α = 图案形状），随后逐像素合成：白光 α = icon α × 椭圆高斯。
            // ⚠️ 画进的是 w×h 像素缓冲、CG 原点在左下——rect 必须用像素全幅，
            // 用点单位的 bounds 会把 icon 缩进左下四分之一（实测）
            if let cg = maskImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            }
            // 椭圆高斯：中心=icon 顶缘中点（cy=0），rx/ry 稍大于半高宽，向下衰减；
            // 峰值按外观分档（暗 0.5 / 浅 0.4，可调）
            let peak = dark ? 0.5 : 0.4
            let spread = 1.2
            let cx = Double(w) / 2
            let rx = Double(w) * 0.55, ry = Double(h) * 0.55
            for y in 0..<h {
                let gy = (Double(y) + 0.5) / ry   // 顶缘最亮，向下衰减
                let gy2 = gy * gy
                for x in 0..<w {
                    let gx = (Double(x) + 0.5 - cx) / rx
                    let glow = peak * exp(-spread * spread * (gx * gx + gy2))
                    let i = (y * w + x) * 4
                    // icon α 取四通道最大值：premultiplied 缓冲 α 恒 ≥ 各颜色分量，
                    // 无视实际字节序（RGBA/BGRA/ARGB）都精确等于 α；读错通道会出乱纹（实测）。
                    // 白光 α = icon α × 高斯（白色 premultiplied：rgb = α，四通道等值写法亦字节序免疫）
                    let iconA = Double(max(data[i], data[i + 1], data[i + 2], data[i + 3])) / 255.0
                    let a = min(glow * iconA, 1)
                    data[i] = UInt8(a * 255)
                    data[i + 1] = UInt8(a * 255)
                    data[i + 2] = UInt8(a * 255)
                    data[i + 3] = UInt8(a * 255)
                }
            }
            layer?.contents = ctx.makeImage()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }
    }

}

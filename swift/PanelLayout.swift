// PanelLayout.swift — iBalance
// 面板布局构建:build() 主装配 + 卡片/设置行/操作磁贴等行构建器
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)

import Cocoa
import CoreImage

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
        if let bgc = balanceGroupContainer {
            parts.append("bgc=\(String(format: "%.1f", bgc.frame.height))")
            let containers = platformCards.values
                .compactMap { $0 as? NSStackView }
                .sorted { $0.frame.minY < $1.frame.minY }
            for c in containers {
                let hs = c.arrangedSubviews.filter { !$0.isHidden }
                    .map { String(format: "%.1f", $0.frame.height) }
                if !hs.isEmpty { parts.append("[\(hs.joined(separator: ","))]") }
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
        // 宽度下限 240（浮窗 resize 最小宽）；独立（未挂到窗口）时 fittingSize 也能解出高度
        widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

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
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 14),
        // 底部用 ≤：root 顶锚、保持内容自然高度（永不被拉伸）。footer 已移出 root、
        // 单独贴 panel 底部，故 root 底部预留 footer(20)+底边距(11)+最小间隙(10)=41pt，
        // 避免与贴底 footer 重叠；浮窗拖高时多出的高度自然成为 root 与 footer 间的空白
        ])
        rootBottomCap = root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -41)
        rootBottomCap?.isActive = true
        rootViewRef = root

        // 底部更新时间标签启用 layer 供脉冲动效使用
        updatedLabel.wantsLayer = true

        // ── 离线横幅 ──
        offlineBanner.font = .systemFont(ofSize: 12)
        offlineBanner.textColor = .systemOrange
        offlineBanner.isHidden = true
        root.addArrangedSubview(offlineBanner)
        pinFullWidth(offlineBanner, in: root)

        // ── 余额分组标题（12pt bold + systemGray 石墨灰）+ 行尾 pin 置顶按钮 ──
        let balanceTitle = sectionTitleRow(name: "余额")
        balanceTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(balanceTitle)
        // 对齐到卡片内标题的左边界（root.leading + 8pt）
        balanceTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8).isActive = true
        // 行撑满宽，pin 按钮贴行尾（与标题同一行）：点击切换置顶常驻
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        balanceTitle.addArrangedSubview(titleSpacer)
        balanceTitle.addArrangedSubview(pinBtn)
        balanceTitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6).isActive = true
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

        // ── DeepSeek 单账号卡片容器（动态创建，走多号卡片管线；置于余额组首位）──
        dsCardsContainer = NSStackView(views: [])
        dsCardsContainer.orientation = .vertical
        dsCardsContainer.alignment = .leading
        dsCardsContainer.distribution = .fill
        dsCardsContainer.spacing = 0
        dsCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        balanceGroupContainer.addArrangedSubview(dsCardsContainer)
        pinPlatformWidth(dsCardsContainer)
        platformCards[BalancePlatform.deepSeek.rawValue] = dsCardsContainer
        // 平台间间隔 4pt（同平台内各容器内部 spacing=0 不加间隔）
        balanceGroupContainer.setCustomSpacing(4, after: dsCardsContainer)

        // ── ZhiPu 单账号卡片容器（智谱 BigModel，同 DS 管线；置于 DeepSeek 卡片下方）──
        zhipuCardsContainer = NSStackView(views: [])
        zhipuCardsContainer.orientation = .vertical
        zhipuCardsContainer.alignment = .leading
        zhipuCardsContainer.distribution = .fill
        zhipuCardsContainer.spacing = 0
        zhipuCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        balanceGroupContainer.addArrangedSubview(zhipuCardsContainer)
        pinPlatformWidth(zhipuCardsContainer)
        platformCards[BalancePlatform.bigModel.rawValue] = zhipuCardsContainer
        balanceGroupContainer.setCustomSpacing(4, after: zhipuCardsContainer)

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
        monoSwitch.target = self
        monoSwitch.action = #selector(monoFontToggled)
        interSwitch.target = self
        interSwitch.action = #selector(interFontToggled)
        valuePreviewSwitch.target = self
        valuePreviewSwitch.action = #selector(valueScrollPreviewToggled)
        // 刷新间隔行：标题 + 手动刷新按钮 + spacer + 分段控件
        intervalSegment.target = self
        intervalSegment.action = #selector(intervalChanged)
        monoSegment.target = self
        monoSegment.action = #selector(intervalChanged)
        intervalSegment.setContentHuggingPriority(.required, for: .horizontal)
        intervalSegment.setContentHuggingPriority(.defaultLow, for: .vertical)
        intervalSegment.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // 原生分段 + Mono 字符段同框显隐切换（与设置开关一致）；容器作为 segmentView，
        // 整行点击排除整个分段区域、交给可见的那个控件处理选择。
        // Mono 字符段容器：只负责承载控件，控件的视觉右缘直接对齐设置行尾。
        monoSegmentBox.translatesAutoresizingMaskIntoConstraints = false
        // 容器填满 intervalSegmentBox（占满刷新按钮后的全部剩余空间），monoSegment 四边贴满容器
        // → mouseDown 命中区覆盖整段空白。视觉不受影响：draw 内按内容右对齐绘制（紧凑排版）。
        // ⚠️ monoSegment 必须用 top/bottom（非 centerY）贴满：容器高度无独立约束，
        //    靠 monoSegment 的 heightAnchor(16) 撑起；centerY 对齐会导致容器高度无解塌缩为 0，
        //    视觉因 AppKit 不裁剪子视图而「看似正常」，但 hitTest 判定点击在 bounds 外 → 点击失效。
        monoSegmentBox.setContentHuggingPriority(.required, for: .horizontal)
        monoSegment.translatesAutoresizingMaskIntoConstraints = false
        monoSegmentBox.addSubview(monoSegment)
        NSLayoutConstraint.activate([
            monoSegment.leadingAnchor.constraint(equalTo: monoSegmentBox.leadingAnchor),
            monoSegment.trailingAnchor.constraint(equalTo: monoSegmentBox.trailingAnchor),
            monoSegment.topAnchor.constraint(equalTo: monoSegmentBox.topAnchor),
            monoSegment.bottomAnchor.constraint(equalTo: monoSegmentBox.bottomAnchor),
            monoSegment.heightAnchor.constraint(equalToConstant: monoSegment.intrinsicContentSize.height),
        ])
        // overlay 容器：占满刷新按钮之后的全部剩余空间（无 stretchSpacer——spacer 会把
        // 点击切成「整行刷新」区，控件左侧空白的点击会误触刷新）。
        // 原生分段与 Mono 分段都在容器内 trailing 对齐，视觉位置（行尾）与 spacer 方案一致。
        let intervalSegmentBox = NSView()
        intervalSegmentBox.translatesAutoresizingMaskIntoConstraints = false
        intervalSegmentBox.heightAnchor.constraint(equalToConstant:
            max(16, intervalSegment.intrinsicContentSize.height,
                monoSegment.intrinsicContentSize.height)).isActive = true
        intervalSegment.translatesAutoresizingMaskIntoConstraints = false
        intervalSegmentBox.addSubview(intervalSegment)
        intervalSegmentBox.addSubview(monoSegmentBox)
        NSLayoutConstraint.activate([
            intervalSegment.trailingAnchor.constraint(equalTo: intervalSegmentBox.trailingAnchor),
            intervalSegment.centerYAnchor.constraint(equalTo: intervalSegmentBox.centerYAnchor),
            // Mono 字符段容器填满整个 overlay 容器，扩大命中区；
            // 视觉由 monoSegment.draw 右对齐保证与原紧凑排版一致。
            monoSegmentBox.leadingAnchor.constraint(equalTo: intervalSegmentBox.leadingAnchor),
            monoSegmentBox.trailingAnchor.constraint(equalTo: intervalSegmentBox.trailingAnchor),
            monoSegmentBox.centerYAnchor.constraint(equalTo: intervalSegmentBox.centerYAnchor),
        ])
        // 低拥抱优先级让容器吃掉行内全部剩余空间（替代 stretchSpacer），
        // 高压缩阻力防止行空间紧张时容器被压窄到 114 以下。
        intervalSegmentBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        intervalSegmentBox.setContentCompressionResistancePriority(.required, for: .horizontal)
        intervalSegmentBox.setContentHuggingPriority(.defaultLow, for: .vertical)
        intervalSegmentBox.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // 钉死分段控件宽度（3 × 38，与 viewDidMoveToWindow 中 setWidth 一致）：
        // NSSegmentedControl 的 intrinsic 尺寸由 cell 按系统版本计算，setWidth 在
        // viewDidMoveToWindow 才生效、且未必被 intrinsic 采纳，行内余量会被它吃掉，
        // 导致低压缩阻力的 label 先被压窄、文字被裁剪。显式约束不受版本/时序影响。
        // 内边距已由 CompactSegmentedCell 收窄，38pt/段足以容纳「3分钟」@9pt（约 25pt）。
        intervalSegment.widthAnchor.constraint(equalToConstant: 114).isActive = true
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
        intervalRow.spacing = 6
        // intervalSegmentBox 占满按钮后的剩余空间（低拥抱），无 stretchSpacer：
        // 刷新按钮仅自身区域可点（无整行点击），分段控件命中区覆盖全部空白
        intervalRow.setViews([intervalLabel, manualRefreshBtn, intervalSegmentBox], in: .leading)

        let settingRows = [
            intervalRow,
            switchRow(title: "自动签到", sub: autoCheckinSub, sw: autoCheckinSwitch),
            switchRow(title: "面板渐变背景", sub: nil, sw: gradientSwitch),
            switchRow(title: "Mono 风格", sub: nil, sw: monoSwitch),
            switchRow(title: "Inter 字体", sub: nil, sw: interSwitch),
            switchRow(title: "滚动预览", sub: valuePreviewSub, sw: valuePreviewSwitch),
        ].map {
            let hover = wrapHoverRow($0)
            // 行 hover 不提亮小字与图标 tint：小字保持常态颜色，
            // 刷新按钮仅自身 hover 时提亮（RefreshIconButton 内部处理）
            hover.enablesTextBrightening = false
            return hover
        }
        // 副标题默认隐藏（switchRow 内统一设置），静态文案行直接显示
        valuePreviewSub.isHidden = false
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

        let cockpitBtn = ActionTileButton(symbol: "gauge.with.needle", title: "Cockpit", target: self, action: #selector(openCockpitTapped))
        // Key/额度磁贴：DeepSeek + ZhiPu 设置弹窗统一入口，icon 用 SF Symbol 钥匙
        let deepSeekSettingsBtn = ActionTileButton(symbol: "key.fill", title: "Key / 额度", target: self, action: #selector(setApiKeyTapped))
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
        deepSeekSettingsBtn.toolTip = "配置 DeepSeek API Key、日常额度与 ZhiPu Token"
        platformTogglesBtn.toolTip = "管理各平台刷新、自动签到、卡片与用量显示开关"
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

        // ── 底部：更新时间（严格水平居中）+ 退出按钮（贴右）──
        // pin 按钮（挂「余额」标题行尾）：属性在此配置，布局见 balanceTitle 段
        pinBtn.image = symbolImage("pin", size: 11)
        pinBtn.target = self
        pinBtn.action = #selector(pinTapped)
        pinBtn.toolTip = "置顶面板（置顶后可自由拖动）"
        // 拖动示意条：绝对定位在「余额」标题行（root top padding 14pt）上方的留白带内居中
        addSubview(dragGrabber)
        dragGrabber.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dragGrabber.widthAnchor.constraint(equalToConstant: 36),
            dragGrabber.heightAnchor.constraint(equalToConstant: 4),
            dragGrabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            dragGrabber.topAnchor.constraint(equalTo: topAnchor, constant: 11),
        ])

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
        // footer 移出 root、直接挂 panel 并贴底：root 用 ≤ 底约束保持内容自然高度
        // （永不被拉伸），浮窗拖高时多出的高度成为 root 与 footer 间的空白，footer 始终贴底。
        // 宽度与 root 对齐（左右各内缩 7pt），底部留 11pt 边距（与原 root 底边距一致）
        addSubview(footer)
        // 固定 footer 高度，避免子控件 intrinsicContentSize 变化时重新布局导致错位
        let footerHeight: CGFloat = 20
        NSLayoutConstraint.activate([
            footer.heightAnchor.constraint(equalToConstant: footerHeight),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
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
    func addCard(rows: [NSView], to root: NSStackView, title: String? = nil, spacing: CGFloat = 6, onClick: (() -> Void)? = nil, onRightClick: ((NSEvent) -> Void)? = nil, onDragStarted: ((NSPoint) -> Void)? = nil, onDragChanged: ((NSPoint) -> Void)? = nil, onDragEnded: (() -> Void)? = nil, topPadding: CGFloat = 7, bottomPadding: CGFloat = 7, horizontalPadding: CGFloat = 8, titleColor: NSColor = .systemGray, cardBackground: NSColor? = kCardBackground, stretchRows: Bool = true, centerRows: Bool = false) -> NSView {
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
        card.layer?.borderColor = Palette.hoverBorderNormal.cgColor
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
    private func sectionTitleRow(name: String, color: NSColor = .systemGray) -> NSStackView {
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

    /// 可折叠区块标题条：hover 复用余额卡片样式（HoverCard hover 背景色+0.8pt 发丝边框），
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
        hc.layer?.borderColor = Palette.hoverBorderNormal.cgColor
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
    /// monoSize：Mono 模式 ASCII icon 标称尺寸（缺省 = imgSize 即不微调场景）。
    /// SVG 微调（imageSize）与 Mono 标称解耦：像素字母各平台等大，SVG 保持视觉微调
    func balanceContentRow(icon iconName: String, name: String, valueView: RollingNumberView, info: NSStackView?, dots: UsageDots?, iconSize: CGFloat = 20.47, imageSize: CGFloat? = nil, monoSize: CGFloat? = nil, iconTopAligned: Bool = false, iconTint: NSColor = Palette.cardForeground, nickLabel: NSTextField? = nil, titleWeight: NSFont.Weight = .semibold, valueWeight: NSFont.Weight = .semibold, textColor: NSColor = Palette.cardForeground, failureBadge: NSView? = nil, premadeIconView: NSImageView? = nil, titleLabelRef: ((FadeableTextField) -> Void)? = nil) -> NSView {
        var imgSize = imageSize ?? iconSize
        // 左：大 icon（固定列宽 = iconSize + 4，image 居中显示，imageSize 可独立缩小）；
        // premadeIconView 由外部传入（多号卡片用 MenuBarFadeIconView 以支持菜单栏渐变标记）
        let iconView = premadeIconView ?? NSImageView()
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
            // 统一图标列宽（不再随各平台 iconSize 变化）：所有卡标题严格左对齐；
            // 各图标视觉尺寸差异（SVG 留白不同）由 CardStyle.iconSize 单独补偿
            iconContainer.widthAnchor.constraint(equalToConstant: 24.47),
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

        // 标题行：nameLabel（平台名，Palette.cardForeground）+ 可选 nickLabel（昵称，systemGray 石墨灰）
        // FadeableTextField：支持菜单栏显隐渐变标记（与 icon 同一套蒙版参数）
        let nameLabel = FadeableTextField(labelWithString: name)
        registerFont(nameLabel, size: 13, weight: titleWeight)
        nameLabel.textColor = textColor
        // 暴露 nameLabel 给调用方（如 hover 字重动画驱动）
        titleLabelRef?(nameLabel)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 平台标题优先保持完整，昵称在有限空间内使用省略号
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 13.5pt 字体需要略高于字号本身的行框，避免字形下沿被裁切。
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
            valueView.trailingAnchor.constraint(equalTo: row1.trailingAnchor),
            valueView.centerYAnchor.constraint(equalTo: row1.centerYAnchor),
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

        // 「副标题是否有内容」分流：有文字副标题（到期/额度行）走纵向 stack 居中；
        // 无文字副标题但有点阵时（TRAE：签到行占位已移除），点阵视作独立的用量
        // 可视化而非副标题——退出纵向流、贴底右角，标题行独占垂直中心。
        // （组合块居中会把标题顶离卡心，与恒居中的 icon 列产生视觉错位）
        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        if let dots = dots, info == nil {
            // ── 单行模式：row1 垂直居中 + 点阵浮底 ──
            // centerY 上抬 1pt 与浮底点阵相切不重叠；依赖外部等高约束撑高容器
            // （仅当前账号进入本模式，恒绑定 DS 等高基准）
            contentContainer.addSubview(row1)
            contentContainer.addSubview(dots)
            NSLayoutConstraint.activate([
                row1.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                row1.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                row1.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor, constant: -1),
                dots.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor),
                dots.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                dots.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -1),
                row1.topAnchor.constraint(greaterThanOrEqualTo: contentContainer.topAnchor),
            ])
        } else {
            // ── 原两行（或单行）模式 ──
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
            contentContainer.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                content.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
                content.topAnchor.constraint(greaterThanOrEqualTo: contentContainer.topAnchor),
                content.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor),
            ])
        }

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
        // 容器右缘贴行尾。MonoCharSwitch 与 MonoSegmentedControl 都是全自绘控件，
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

    /// 字符化控件（MonoCharSwitch / MonoSegmentedControl）切换时的模糊→清晰过渡，
    /// 模拟 CSS `filter: blur()` transition：入场/退场时从模糊聚焦成形，仅作用于控件自身。
    /// ⚠️ 只能用 layer.filters（作用于自身内容，macOS 有效）；
    /// backgroundFilters 在 macOS 被渲染服务端忽略（勿再尝试）。
    /// 每帧重建 CIFilter 实例——改 inputRadius 不触发 CA 重合成，必须换实例。
    private func playCharBlurTransition(on views: [NSView]) {
        guard !shouldReduceMotion else { return }
        var layers: [CALayer] = []
        for v in views {
            v.wantsLayer = true
            v.layerUsesCoreImageFilters = true
            if let l = v.layer { layers.append(l) }
        }
        guard !layers.isEmpty else { return }
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
    private func crossfade(_ outgoing: NSView, to incoming: NSView, animated: Bool) {
        guard animated, !shouldReduceMotion else {
            outgoing.isHidden = true
            outgoing.alphaValue = 1
            incoming.isHidden = false
            incoming.alphaValue = 1
            return
        }

        outgoing.isHidden = false
        outgoing.alphaValue = 1
        incoming.isHidden = false
        incoming.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            // 与 playCharBlurTransition 同周期同曲线：透明度与模糊聚焦严格同步
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 1/3, 1/3, 1, 1) // ease-out cubic
            outgoing.animator().alphaValue = 0
            incoming.animator().alphaValue = 1
        }, completionHandler: { [weak outgoing, weak incoming] in
            outgoing?.isHidden = true
            outgoing?.alphaValue = 1
            incoming?.alphaValue = 1
        })
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
        // 刷新时间分段控件：两个控件位于固定宽度 overlay 容器中，切换不触发行宽重排。
        monoSegment.selectedSegment = intervalSegment.selectedSegment
        crossfade(useChar ? intervalSegment : monoSegmentBox,
                  to: useChar ? monoSegmentBox : intervalSegment,
                  animated: animated)
        // 切换的两组控件（原生 ↔ 字符化）都叠加模糊→清晰过渡（CSS blur 式）
        if animated {
            playCharBlurTransition(on: switchRows.map { $0.char } + [monoSegment])
            playCharBlurTransition(on: switchRows.map { $0.sw } + [intervalSegment])
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
        // 以 2× 光栅化，像素充足；NSBitmapImageRep 绘制保证 SVG 矢量按指定像素落地
        let scale: CGFloat = 2
        let px = max(1, Int(ceil(size * scale)))
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
        else { return nil }
        // 像素 → 点：以墨迹最大边对齐 size（保持长宽比；tabler 图标近正方形 → ≈ size×size）
        let inkW = CGFloat(maxX - minX + 1), inkH = CGFloat(maxY - minY + 1)
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

    /// 多号账号卡 icon：未显示在菜单栏的账号叠加垂直透明渐变 mask
    /// （视觉底部 80% 可见 → 顶部 25% 可见，从下到上由亮到暗），区别于「已上菜单栏」的完整 icon。
    /// 蒙版逻辑在 MenuBarFadeMask（与卡片主标题/积分数值共用同一套渐变参数），本类只是薄壳。
    final class MenuBarFadeIconView: NSImageView {
        private lazy var fade = MenuBarFadeMask(host: self)
        /// true = 未上菜单栏 → icon 应用渐变；false = 完整显示
        var usesMenuBarFade: Bool {
            get { fade.usesFade }
            set { fade.usesFade = newValue }
        }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            fade.syncLayout()
        }
    }

    /// 支持同一菜单栏渐变标记的文本 label（余额卡片主标题）：wantsLayer + 挂 MenuBarFadeMask，
    /// 接口与 icon 一致（usesMenuBarFade）。行框高 16pt 由外部约束固定，hover 字重动画
    /// 只改字形宽度不改行框。墨迹区间由官方基线读数推导（见 updateInkRange）。
    final class FadeableTextField: NSTextField {
        private lazy var fade = MenuBarFadeMask(host: self)
        var usesMenuBarFade: Bool {
            get { fade.usesFade }
            set { fade.usesFade = newValue }
        }
        private var lastInkFontKey = ""
        /// 墨迹区间 = 官方基线读数（baselineOffsetFromBottom，AppKit cell 排版的唯一权威，
        /// 对 linebox 超出 bounds 的裁剪场景依然正确）+ 字体度量：
        /// low 含 descender、high 取 ascender——宁多盖 1pt 渐变淡尾也不在字形顶部露白条。
        private func updateInkRange() {
            guard let f = font, bounds.height > 0 else { return }
            let key = "\(f.fontName)|\(Int(f.pointSize))"
            guard lastInkFontKey != key else { return }
            lastInkFontKey = key
            let base = baselineOffsetFromBottom
            fade.inkRange = (base + f.descender, base + f.ascender)
            fade.refreshAnchors()
        }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            fade.syncLayout()
            updateInkRange()
        }
    }

}

/// 菜单栏显隐标记蒙版（右键卡片「在菜单栏显示」切换的视觉载体）：垂直透明渐变裁剪层，
/// 自下而上由亮到暗（底部 80% → 顶部 25% 可见），把「未上菜单栏」渲染成半褪视觉。
/// 余额卡片的 icon、主标题、积分数值三处共用同一套渐变色参数；mask 恒铺满宿主 bounds
/// 且锚点全是相对单位，随各自内容高度自适应（icon 22pt 方形 / 标题数值 16pt 行框节奏一致）。
/// v2 锚点动画（自 MenuBarFadeIconView 平移）：colors/locations 固定不变，显隐切换只动画
/// 渐变锚点对 (startPoint, endPoint)（带长恒 3 = bounds 高度 ×3）——
/// 开 = startPoint.y -1（中段渐变对齐内容）；关 = 0（上段纯白对齐，渐变带移出上方）。
/// 锚点平移即「半透明从内容底部往上移入/移出」（0.25s easeInEaseOut）。
final class MenuBarFadeMask {
    private let fadeLayer = CAGradientLayer()
    private unowned var host: NSView?
    private var installed = false
    private let anchorDuration: CFTimeInterval = 0.25
    /// true = 未上菜单栏 → 应用渐变；false = 完整显示
    var usesFade = false {
        didSet {
            guard oldValue != usesFade else { return }
            transition(animated: true)
        }
    }
    init(host: NSView) {
        self.host = host
        // 六段色标：上段纯白 / 中段渐变（底部 0.8 → 顶部 0.25）/ 下段纯白；
        // 同 location 双停靠点形成硬边界
        fadeLayer.colors = [
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.8).cgColor,
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.white.cgColor,
            NSColor.white.cgColor,
        ]
        let third = NSNumber(value: 1.0 / 3.0)
        let twoThirds = NSNumber(value: 2.0 / 3.0)
        fadeLayer.locations = [NSNumber(value: 0), third, third, twoThirds, twoThirds, NSNumber(value: 1)]
    }
    /// 墨迹区间（pt，自宿主 bounds 底部向上计；nil = 跟随整个 bounds，icon 场景）。
    /// 渐变段（locations 1/3–2/3，0.8→0.25）将精确映射到 [low, high]，字形外的
    /// 行框留白自动落在两端纯白段。由文本宿主以基线读数 + 字体度量推导填入
    /// （见 InkRangeMetrics）——离屏快照实测证明各字体行盒差异大且 cell 会裁剪，
    /// 静态猜数必错（曾测出 WorkBuddy 墨迹仅 6.5pt 的假象）。
    var inkRange: (low: CGFloat, high: CGFloat)?
    /// inkRange 更新后按当前开关状态重新落锚（目标未变则为空操作；有变化平滑滑动）
    func refreshAnchors() {
        guard installed else { return }   // 未挂载时首次挂载自然使用最新值
        let s = anchorSlots()
        slideAnchor(to: usesFade ? s.grad : s.above, s.k)
    }
    /// 按 inkRange 解锚点槽位（单位 = bounds 高度）。几何推导：
    /// 轴长 3k（k = high−low）、t=1/3 ↦ lo、t=2/3 ↦ hi ⇒ grad = lo−k；
    /// 关终点 = max(hi, 1−k)（保证白色硬边界不出窗）；开起点 = lo−3k（带沉到墨迹底下之外）
    private func anchorSlots() -> (grad: CGFloat, above: CGFloat, below: CGFloat, k: CGFloat) {
        let B = host?.bounds.height ?? 0
        guard B > 0 else { return (-1, 1, -3, 1) }
        if let r = inkRange {
            let lo = min(max(r.low / B, 0), 0.95)
            let hi = min(max(r.high / B, lo + 0.05), 1)
            let k = hi - lo
            return (lo - k, max(hi, 1 - k), lo - 3 * k, k)
        }
        return (-1, 1, -3, 1)   // icon：全高 = 墨迹（k=1），与原版完全一致
    }
    /// 锚点几何（slot 标量 + 单位 k → CA 两点）。宿主 layer 坐标经 AppKit 翻转
    /// 补偿跟随 view.isFlipped：非翻转宿主（icon/主标题）layer y 向上；翻转宿主
    /// （RollingNumberView isFlipped）layer y 向下——后者必须换算否则渐变与
    /// 滑动方向整体上下颠倒。等效换算（对任意 k 成立）：start = (0.5, 1-s)、
    /// end = start − 3k（轴反向自下而上），可逐 t 推导证明与正向配置视觉逐点相等。
    private func anchorPoints(_ s: CGFloat, _ k: CGFloat) -> (CGPoint, CGPoint) {
        if let host, host.isFlipped {
            let sy = 1 - s
            return (CGPoint(x: 0.5, y: sy), CGPoint(x: 0.5, y: sy - 3 * k))
        }
        return (CGPoint(x: 0.5, y: s), CGPoint(x: 0.5, y: s + 3 * k))
    }
    private func applyAnchor(_ s: CGFloat, _ k: CGFloat) {
        let pts = anchorPoints(s, k)
        fadeLayer.startPoint = pts.0
        fadeLayer.endPoint = pts.1
    }
    /// 宿主 layout 时调用：首次挂载 + 尺寸同步（mask 恒铺满 bounds，仅尺寸变化时更新）
    func syncLayout() {
        guard let host, host.bounds.height > 0 else { return }
        let s = anchorSlots()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !installed {
            host.layer?.mask = fadeLayer
            applyAnchor(usesFade ? s.grad : s.above, s.k)
            installed = true
        }
        fadeLayer.frame = host.bounds
        CATransaction.commit()
    }
    private func transition(animated: Bool) {
        guard let host, host.bounds.height > 0 else { return }   // 布局未定时由宿主 layout() 首挂
        let s = anchorSlots()
        if !installed {
            // 首次挂载（rebuild 后 apply 阶段）：直接就位，不播动画
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.layer?.mask = fadeLayer
            fadeLayer.frame = host.bounds
            applyAnchor(usesFade ? s.grad : s.above, s.k)
            CATransaction.commit()
            installed = true
            return
        }
        if !animated {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fadeLayer.removeAnimation(forKey: "maskAnchorStart")
            fadeLayer.removeAnimation(forKey: "maskAnchorEnd")
            applyAnchor(usesFade ? s.grad : s.above, s.k)
            CATransaction.commit()
            return
        }
        if usesFade {
            // 开：先无动画瞬移到下方纯白位（与任意完整态视觉等价，无跳变），
            // 再上滑进入渐变位——半透明从内容底部往上移入
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fadeLayer.removeAnimation(forKey: "maskAnchorStart")
            fadeLayer.removeAnimation(forKey: "maskAnchorEnd")
            applyAnchor(s.below, s.k)
            CATransaction.commit()
            slideAnchor(to: s.grad, s.k)
        } else {
            // 关：从渐变位上滑到上方纯白位——恢复同样从内容底部往上移入
            slideAnchor(to: s.above, s.k)
        }
    }
    /// 显式锚点平移动画（startPoint/endPoint 同步）：起点取当前呈现位置，
    /// 快速反复切换不跳变；model 直达目标（disableActions），呈现由动画驱动。
    /// 端点一律经 anchorPoints 换算，翻转宿主上滑动方向才与非翻转宿主一致
    private func slideAnchor(to s: CGFloat, _ k: CGFloat) {
        let fromStartY = fadeLayer.presentation()?.startPoint.y ?? fadeLayer.startPoint.y
        // 呈现值回到 slot 标量：按宿主取向反解（flipped: start.y = 1 - slot）
        let fromSlot = (host?.isFlipped == true) ? 1 - fromStartY : fromStartY
        guard fromSlot != s else { return }
        let fromPts = anchorPoints(fromSlot, k)
        let toPts = anchorPoints(s, k)
        let startAnim = CABasicAnimation(keyPath: "startPoint")
        startAnim.fromValue = NSValue(point: fromPts.0)
        startAnim.toValue = NSValue(point: toPts.0)
        let endAnim = CABasicAnimation(keyPath: "endPoint")
        endAnim.fromValue = NSValue(point: fromPts.1)
        endAnim.toValue = NSValue(point: toPts.1)
        for anim in [startAnim, endAnim] {
            anim.duration = anchorDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.isRemovedOnCompletion = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyAnchor(s, k)
        CATransaction.commit()
        fadeLayer.add(startAnim, forKey: "maskAnchorStart")
        fadeLayer.add(endAnim, forKey: "maskAnchorEnd")
    }
}

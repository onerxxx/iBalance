// UpdateProgressWindow.swift — 自更新窗口（固定尺寸状态机：发现新版/安装/失败）
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 对外类型   UpdateProgressWindowController（@MainActor，AppDelegate 持有复用）
// 状态机     Phase：.available / .installing / .failed
//            （检查阶段在后台静默进行；无新版/网络故障由调用方用 NSAlert 呈现，
//              本窗口只在「发现新版本」后才出现）
// 对外 API   showUpdateAvailable(version:current:notes:onInstall:onLater:)（唯一拉起入口）
//            beginInstall(version:)（进入安装态：仅切可见性，不重置窗口/日志/标题以外的任何东西）
//            showFailure(title:message:onRetry:)（失败行标红 + 错误进副标题 + 重试/手动下载/关闭）
//            report(_:) / reporter（进度通道，回调在 delegate 队列，内部切主线程）
//            closeWindow() / isVisible
// 视图层级   header（应用图标 + 标题 + 副标题）→ content（日志文本框 | 步骤进度块）
//            → footer（上下文按钮，右对齐）
// 步骤行     UpdateStepRow（pending/active/done/failed 四态 SF 图标 + 明细）
// 取消标志   UpdateCancelFlag（NSLock 保护；供 URLSession delegate 队列跨线程读）
//
// ⚠️ 稳定性铁律：窗口尺寸固定（440×474）。所有状态切换只做「可见性切换 + 文本更新 +
//    content 区内部布局」，绝不 setContentSize / 重建视图 / 重复 center —— 这是消除
//    「发现新版后进入更新时窗口被重置、闪烁」的根本设计约束。改布局必须维持这条约束。
//    按钮互斥可见性由 Phase 保证：每个 Phase 只显示自己那组按钮，keyEquivalent 不冲突。

import AppKit

/// 翻转坐标系的容器（从上往下排布）
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 跨线程取消标志：下载 delegate 在后台队列轮询它
final class UpdateCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }

    func reset() {
        lock.lock(); flag = false; lock.unlock()
    }
}

// MARK: - 步骤行

private final class UpdateStepRow: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        for v in [icon, titleLabel, detailLabel] { addSubview(v) }
        apply(.pending, detail: "")
    }

    required init?(coder: NSCoder) { fatalError("UpdateStepRow: 代码构建，不走 xib") }

    func apply(_ state: UpdateStepState, detail: String) {
        titleLabel.textColor = state == .pending ? .tertiaryLabelColor : .labelColor
        detailLabel.stringValue = detail
        detailLabel.textColor = state == .failed ? .systemRed : .secondaryLabelColor
        switch state {
        case .pending:
            icon.image = Self.symbol("circle")
            icon.contentTintColor = .tertiaryLabelColor
        case .active:
            icon.image = Self.symbol("arrow.triangle.2.circlepath")
            icon.contentTintColor = .controlAccentColor
        case .done:
            icon.image = Self.symbol("checkmark.circle.fill")
            icon.contentTintColor = .systemGreen
        case .failed:
            icon.image = Self.symbol("xmark.circle.fill")
            icon.contentTintColor = .systemRed
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    override func layout() {
        super.layout()
        let top = (bounds.height - 16) / 2
        icon.frame = NSRect(x: 0, y: top, width: 16, height: 16)
        titleLabel.frame = NSRect(x: 24, y: top, width: 76, height: 16)
        detailLabel.frame = NSRect(x: 104, y: top, width: max(40, bounds.width - 104), height: 16)
    }
}

// MARK: - 窗口控制器

/// 自更新单一窗口：发现新版（更新日志 + 确认）→ 下载（字节/速度）→ 校验 → 安装重启
/// 全程在此呈现，失败反馈也在此呈现，全程非模态、零额外弹窗。
/// 检查阶段在后台静默进行（无新版/网络故障由调用方 NSAlert 呈现），
/// 本窗口只在发现新版后才出现。固定尺寸 + Phase 状态机：状态切换只切可见性/文本，
/// 窗口永不重置（见文件头铁律）。
@MainActor
final class UpdateProgressWindowController: NSObject, NSWindowDelegate {

    /// 窗口生命周期阶段。切换入口只有 3 个公开方法，各自负责文本与按钮，非法组合不可表达。
    enum Phase { case available, installing, failed }

    private enum Metrics {
        static let size = NSSize(width: 440, height: 474)
        static let pad: CGFloat = 24
        static let headerH: CGFloat = 68
        static let footerH: CGFloat = 34
        static let progressH: CGFloat = 172
        static let blockGap: CGFloat = 14
        /// content 区 frame（固定窗口 → 一次性计算）
        static let contentY: CGFloat = pad + headerH + 14
        static let contentH: CGFloat = 474 - contentY - 14 - footerH - pad
    }

    private static let order: [UpdateStage] = [.probe, .fetch, .download, .verify, .install]
    private static let titles: [UpdateStage: String] = [
        .probe: "网络连通", .fetch: "版本信息", .download: "下载安装包",
        .verify: "校验完整性", .install: "安装并重启",
    ]

    private let win: NSWindow
    private let root = FlippedView()
    private let headerRegion = FlippedView()
    private let contentRegion = FlippedView()
    private let footerRegion = FlippedView()

    // header
    private let iconView = NSImageView()
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerSubtitle = NSTextField(labelWithString: "")
    // content：两块互斥/组合显示
    private let notesScroll = NSScrollView()
    private let notesView = NSTextView()
    private let progressBlock = FlippedView()
    private let bar = NSProgressIndicator()
    private let detailLine = NSTextField(labelWithString: "")
    // footer：按 Phase 互斥可见
    private let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
    private let retryBtn = NSButton(title: "重试", target: nil, action: nil)
    private let manualBtn = NSButton(title: "手动下载", target: nil, action: nil)
    private let closeBtn = NSButton(title: "关闭", target: nil, action: nil)
    private let installBtn = NSButton(title: "立即更新", target: nil, action: nil)
    private let laterBtn = NSButton(title: "稍后再说", target: nil, action: nil)

    private var rows: [UpdateStage: UpdateStepRow] = [:]
    private var states: [UpdateStage: UpdateStepState] = [:]
    private let cancelFlag = UpdateCancelFlag()
    private var phase: Phase = .available
    private var lastStage: UpdateStage = .probe
    private var retryHandler: (() -> Void)?
    private var installHandler: (() -> Void)?
    private var laterHandler: (() -> Void)?
    /// 日志文本框是否已填充（失败态据此决定是否显示日志区）
    private var notesLoaded = false
    /// 仅首次 present 时 center；用户挪动过窗口后不再强行归中（消除「位置重置」感）
    private var hasShown = false

    /// 窗口当前是否可见
    var isVisible: Bool { win.isVisible }

    /// 传给 UpdateService 的进度通道：回调来自 URLSession delegate 队列，内部统一切主线程
    private(set) lazy var reporter: UpdateReporter = UpdateReporter(
        report: { [weak self] p in
            Task { @MainActor in self?.apply(p) }
        },
        isCancelled: { [weak self] in self?.cancelFlag.value ?? false }
    )

    override init() {
        win = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.size),
                       styleMask: [.titled, .closable],
                       backing: .buffered,
                       defer: false)
        super.init()
        win.title = "iBalance 更新"
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.level = .floating
        win.delegate = self
        win.contentView = root
        root.frame = NSRect(origin: .zero, size: Metrics.size)
        buildUI()
    }

    // MARK: - 一次性视图构建（固定尺寸 → frame 全部在此定死，运行期只切可见性）

    private func buildUI() {
        let pad = Metrics.pad
        let innerW = Metrics.size.width - pad * 2

        // ── header：应用图标 + 标题 + 副标题 ──
        headerRegion.frame = NSRect(x: pad, y: pad, width: innerW, height: Metrics.headerH)
        root.addSubview(headerRegion)
        if let appIcon = NSApp.applicationIconImage {
            iconView.image = appIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
        }
        iconView.frame = NSRect(x: 0, y: 12, width: 44, height: 44)
        headerTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        headerTitle.textColor = .labelColor
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.frame = NSRect(x: 58, y: 4, width: innerW - 58, height: 20)
        headerSubtitle.font = .systemFont(ofSize: 11)
        headerSubtitle.textColor = .secondaryLabelColor
        headerSubtitle.lineBreakMode = .byWordWrapping
        headerSubtitle.maximumNumberOfLines = 3
        headerSubtitle.cell?.wraps = true
        headerSubtitle.cell?.isScrollable = false
        headerSubtitle.cell?.truncatesLastVisibleLine = true
        headerSubtitle.frame = NSRect(x: 58, y: 26, width: innerW - 58, height: 40)
        for v in [iconView, headerTitle, headerSubtitle] { headerRegion.addSubview(v) }

        // ── content：日志文本框 + 步骤进度块（布局见 relayoutContent）──
        contentRegion.frame = NSRect(x: pad, y: Metrics.contentY,
                                     width: innerW, height: Metrics.contentH)
        root.addSubview(contentRegion)

        notesView.font = .systemFont(ofSize: 11)
        notesView.textColor = .labelColor
        notesView.backgroundColor = .textBackgroundColor
        notesView.isEditable = false
        notesView.isSelectable = true
        notesView.isRichText = false
        notesView.isAutomaticQuoteSubstitutionEnabled = false
        notesView.isAutomaticDashSubstitutionEnabled = false
        notesView.isVerticallyResizable = true
        notesView.isHorizontallyResizable = false
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        notesView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        notesView.textContainerInset = NSSize(width: 8, height: 8)
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.hasHorizontalScroller = false
        notesScroll.autohidesScrollers = true
        notesScroll.wantsLayer = true
        notesScroll.layer?.cornerRadius = 8
        notesScroll.layer?.borderWidth = 1
        contentRegion.addSubview(notesScroll)

        progressBlock.frame = NSRect(x: 0, y: 0, width: innerW, height: Metrics.progressH)
        for (i, stage) in Self.order.enumerated() {
            let row = UpdateStepRow(title: Self.titles[stage] ?? "")
            row.frame = NSRect(x: 0, y: CGFloat(i) * 26, width: innerW, height: 24)
            rows[stage] = row
            states[stage] = .pending
            progressBlock.addSubview(row)
        }
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 100
        bar.isIndeterminate = true
        bar.usesThreadedAnimation = true
        bar.frame = NSRect(x: 0, y: 142, width: innerW, height: 8)
        detailLine.font = .systemFont(ofSize: 11)
        detailLine.textColor = .secondaryLabelColor
        detailLine.lineBreakMode = .byTruncatingTail
        detailLine.frame = NSRect(x: 0, y: 156, width: innerW, height: 16)
        for v in [bar, detailLine] { progressBlock.addSubview(v) }
        contentRegion.addSubview(progressBlock)

        // ── footer：按钮 ──
        footerRegion.frame = NSRect(x: pad,
                                    y: Metrics.size.height - pad - Metrics.footerH,
                                    width: innerW, height: Metrics.footerH)
        root.addSubview(footerRegion)
        for b in [cancelBtn, retryBtn, manualBtn, closeBtn, installBtn, laterBtn] {
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 13)
            b.target = self
            footerRegion.addSubview(b)
        }
        cancelBtn.action = #selector(onCancel)
        retryBtn.action = #selector(onRetry)
        manualBtn.action = #selector(onManual)
        closeBtn.action = #selector(onClose)
        installBtn.action = #selector(onInstall)
        laterBtn.action = #selector(onLater)
        installBtn.bezelColor = .controlAccentColor
        retryBtn.bezelColor = .controlAccentColor
        installBtn.keyEquivalent = "\r"
        retryBtn.keyEquivalent = "\r"
        laterBtn.keyEquivalent = "\u{1b}"
        cancelBtn.keyEquivalent = "\u{1b}"
        for b in [cancelBtn, retryBtn, manualBtn, closeBtn, installBtn, laterBtn] {
            b.isHidden = true
        }
        notesScroll.isHidden = true
        progressBlock.isHidden = true
    }

    // MARK: - 对外状态切换（Phase 的唯一入口）

    /// 发现新版态：更新日志独立滚动文本框 + 立即更新 / 稍后再说。
    /// 点红绿灯关闭 = 稍后再说。
    func showUpdateAvailable(version: String, current: String, notes: String,
                             onInstall: @escaping () -> Void,
                             onLater: @escaping () -> Void) {
        cancelFlag.reset()
        notesLoaded = true
        installHandler = onInstall
        laterHandler = onLater
        retryHandler = nil
        headerTitle.stringValue = "发现新版本 v\(version)"
        setSubtitle("当前版本 v\(current) · 校验通过后自动重启应用，配置不受更新影响。")
        notesView.string = notes
        setButtons(choosing: true)
        enter(.available)
    }

    /// 安装态：从发现新版态原地过渡——标题/日志原位保留，仅显示进度块 + 换按钮。
    /// 这是「窗口不得重置」的关键路径：不重建任何视图、不改窗口尺寸。
    func beginInstall(version: String) {
        cancelFlag.reset()
        installHandler = nil
        laterHandler = nil
        headerTitle.stringValue = "正在更新到 v\(version)"
        setSubtitle("下载完成后自动校验并重启；校验通过前不会改动当前版本。")
        setRow(.probe, state: .done, detail: "已连通")
        setRow(.fetch, state: .done, detail: "v\(version)")
        setRow(.download, state: .active, detail: "准备下载…")
        detailLine.stringValue = ""
        bar.isHidden = false
        bar.isIndeterminate = true
        bar.doubleValue = 0
        bar.startAnimation(nil)
        setButtons(canceling: true)
        enter(.installing)
    }

    /// 失败态：失败步骤行标红，错误信息进副标题（红），重试 / 手动下载 / 关闭
    func showFailure(title: String = "更新未完成",
                     message: String,
                     onRetry: @escaping () -> Void) {
        retryHandler = onRetry
        installHandler = nil
        laterHandler = nil
        headerTitle.stringValue = title
        setSubtitle(message, error: true)
        setRow(lastStage, state: .failed, detail: "失败")
        bar.stopAnimation(nil)
        bar.isHidden = true
        detailLine.stringValue = ""
        setButtons(failing: true)
        enter(.failed)
    }

    /// 调用方直推进度（安装/重启阶段由 AppDelegate 推，不经网络层）
    func report(_ progress: UpdateProgress) {
        apply(progress)
    }

    func closeWindow() {
        retryHandler = nil
        installHandler = nil
        laterHandler = nil
        bar.stopAnimation(nil)
        win.orderOut(nil)
    }

    // MARK: - Phase 切换内核

    private func enter(_ newPhase: Phase) {
        phase = newPhase
        relayoutContent()
        layoutFooter()
        present()
    }

    /// content 区布局（互斥规则由 Phase 决定，frame 变化只发生在 content 内部）：
    /// - available：仅日志文本框，占满
    /// - installing / 安装失败：日志在上（压缩高度）+ 进度块贴底
    private func relayoutContent() {
        let size = contentRegion.bounds.size
        let showNotes = notesLoaded
            && (phase == .available || phase == .installing || phase == .failed)
        let showProgress = phase == .installing || phase == .failed
        setVisibility(notesScroll, showNotes)
        setVisibility(progressBlock, showProgress)

        notesScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        if showNotes && showProgress {
            let notesH = size.height - Metrics.progressH - Metrics.blockGap
            changelogFrame(height: notesH)
            progressBlock.frame = NSRect(x: 0, y: size.height - Metrics.progressH,
                                         width: size.width, height: Metrics.progressH)
        } else if showNotes {
            changelogFrame(height: size.height)
        } else if showProgress {
            progressBlock.frame = NSRect(x: 0, y: (size.height - Metrics.progressH) / 2,
                                         width: size.width, height: Metrics.progressH)
        }
    }

    private func changelogFrame(height: CGFloat) {
        notesScroll.frame = NSRect(x: 0, y: 0,
                                   width: contentRegion.bounds.width, height: max(64, height))
    }

    /// footer 按钮右对齐排布（末位 = 最右主操作）
    private func layoutFooter() {
        let ordered: [NSButton] = [closeBtn, manualBtn, retryBtn, laterBtn, cancelBtn, installBtn]
            .filter { !$0.isHidden }
        var x = footerRegion.bounds.width
        for b in ordered {
            b.sizeToFit()
            let bw = max(b.frame.width + 24, 78)
            x -= bw
            b.frame = NSRect(x: x, y: 4, width: bw, height: 26)
            x -= 8
        }
    }

    /// 区域显隐带 0.16s 淡入淡出（帧变化即时，窗口永不跳动）
    private func setVisibility(_ view: NSView, _ visible: Bool) {
        if visible {
            guard view.isHidden else { return }
            view.isHidden = false
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            })
        } else {
            guard !view.isHidden else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                view.animator().alphaValue = 0
            }, completionHandler: { [weak view] in
                view?.isHidden = true
                view?.alphaValue = 1
            })
        }
    }

    private func setSubtitle(_ text: String, error: Bool = false) {
        headerSubtitle.textColor = error ? .systemRed : .secondaryLabelColor
        headerSubtitle.stringValue = text
    }

    /// 按钮组互斥可见性（每 Phase 一组）
    private func setButtons(canceling: Bool) {
        cancelBtn.isHidden = !canceling
        cancelBtn.isEnabled = true
        retryBtn.isHidden = true
        manualBtn.isHidden = true
        closeBtn.isHidden = true
        installBtn.isHidden = true
        laterBtn.isHidden = true
    }

    private func setButtons(choosing: Bool) {
        cancelBtn.isHidden = true
        retryBtn.isHidden = true
        manualBtn.isHidden = true
        closeBtn.isHidden = true
        installBtn.isHidden = !choosing
        laterBtn.isHidden = !choosing
    }

    private func setButtons(failing: Bool) {
        cancelBtn.isHidden = true
        retryBtn.isHidden = !failing
        manualBtn.isHidden = !failing
        closeBtn.isHidden = !failing
        installBtn.isHidden = true
        laterBtn.isHidden = true
    }

    /// 已可见时直接返回：状态在窗口打开期间切换绝不重新 center / orderFront（防闪烁）
    private func present() {
        guard !win.isVisible else { return }
        if !hasShown {
            win.center()
            hasShown = true
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }

    // MARK: - 进度应用

    private func apply(_ p: UpdateProgress) {
        guard phase == .installing else { return }   // 窗口出现前的迟到回调一律丢弃
        lastStage = p.stage
        let target = Self.rowStage(p.stage)
        let targetIndex = Self.order.firstIndex(of: target) ?? 0
        // 走到某一步时，其之前仍处于 pending 的步骤一律视为已完成
        // （如跳过检查直接进下载、或某步没上报过进度）
        for stage in Self.order {
            guard let i = Self.order.firstIndex(of: stage), i < targetIndex,
                  states[stage] == .pending else { continue }
            setRow(stage, state: .done, detail: "已完成")
        }
        setRow(p.stage, state: p.state, detail: p.detail)

        if let f = p.fraction {
            if bar.isIndeterminate {
                bar.isIndeterminate = false
                bar.stopAnimation(nil)
            }
            bar.doubleValue = min(max(f, 0), 1) * 100
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        detailLine.stringValue = p.detail
    }

    private func setRow(_ stage: UpdateStage, state: UpdateStepState, detail: String) {
        let key = Self.rowStage(stage)
        rows[key]?.apply(state, detail: detail)
        states[key] = state
    }

    /// .stage（暂存）与 .install（替换重启）共用「安装并重启」一行
    private static func rowStage(_ stage: UpdateStage) -> UpdateStage {
        stage == .stage ? .install : stage
    }

    // MARK: - 动作

    @objc private func onCancel() {
        cancelFlag.set()
        cancelBtn.isEnabled = false
        detailLine.stringValue = "正在取消…"
    }

    @objc private func onRetry() {
        let handler = retryHandler
        retryHandler = nil
        handler?()
    }

    @objc private func onManual() {
        guard let url = URL(string: UpdateService.releasesPage) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func onClose() {
        closeWindow()
    }

    @objc private func onInstall() {
        let handler = installHandler
        installHandler = nil
        laterHandler = nil
        handler?()
    }

    @objc private func onLater() {
        let handler = laterHandler
        installHandler = nil
        laterHandler = nil
        handler?()
        closeWindow()
    }

    // MARK: - NSWindowDelegate

    /// 关闭语义按 Phase：确认态=稍后再说；安装中=取消（窗口留到流程真正退出）；
    /// 失败态直接关
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch phase {
        case .available:
            let handler = laterHandler
            installHandler = nil
            laterHandler = nil
            handler?()
            return true
        case .installing:
            onCancel()
            return false
        case .failed:
            retryHandler = nil
            return true
        }
    }
}

// UpdateProgressWindow.swift — 自更新窗口（高度自适应状态机：发现新版/安装/失败）
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 对外类型   UpdateProgressWindowController（@MainActor，AppDelegate 持有复用）
// 状态机     Phase：.available / .installing / .failed
//            （检查阶段在后台静默进行；无新版/网络故障由调用方用 NSAlert 呈现，
//              本窗口只在「发现新版本」后才出现）
// 对外 API   showUpdateAvailable(version:current:notes:onInstall:onLater:)（唯一拉起入口）
//            beginInstall(version:)（进入安装态：仅切可见性，不重置窗口/日志/标题以外的任何东西）
//            showFailure(title:message:onRetry:)（错误进副标题 + 重试/手动下载/关闭）
//            report(_:) / reporter（进度通道，回调在 delegate 队列，内部切主线程）
//            closeWindow() / isVisible
// 视图层级   NSGlassEffectView（整窗一块 regular 玻璃，Liquid Glass 窗口）
//            └ root：header（应用图标 + 标题 + 副标题）→ content（更新描述框 | 进度描述+进度条）
//              → footer（上下文按钮，右对齐）
//            （原「InnerGlowView 内发光 + 彩色流光覆层」连同「发光参数」调试区已于 2026-09-17
//              用户要求整体移除：窗口不再有边框内发光，也没有可调参数）
// 描述框     ConcentricScrollView：hover 卡片同款皮肤（暗色黑@85% 底 +
//            白@30% 1.5pt 描边），高度按内容实高自适应、封顶 150pt，超出框内滚动
// 高度       窗口高度随 Phase 与描述实高自动伸缩（relayoutAndResize 唯一入口，
//            保持左上角不动），宽度固定 440
// 取消标志   UpdateCancelFlag（NSLock 保护；供 URLSession delegate 队列跨线程读）
//
// ⚠️ 稳定性约束：高度只经 relayoutAndResize 一处重算（Phase 切换/描述变更时），
//    状态切换绝不重建视图 / 重复 center —— 这是消除「窗口被重置、闪烁」的根本设计。
//    按钮互斥可见性由 Phase 保证：每个 Phase 只显示自己那组按钮，keyEquivalent 不冲突。

import AppKit

/// 翻转坐标系的容器（从上往下排布）
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 日志区滚动容器：圆角交给 macOS 27 的 cornerConfiguration ——
/// .containerConcentric 让内层圆角自动跟随玻璃窗口外形保持同心（而非写死数值）。
/// 两个 override 均为 27-only：macOS 26 上系统不会派发，圆角回落为直角。
private final class ConcentricScrollView: NSScrollView {
    /// 外观切换（系统深浅 / 应用内浅色主题）回调：层的 CGColor 是解算后的快照，
    /// 描述框描边与渐变底借此重解（见 UpdateProgressWindowController.applyNotesBoxSkin）
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .uniformCorners(radius: .containerConcentric(8))
    }

    @available(macOS 27.0, *)
    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        wantsLayer = true
        layer?.masksToBounds = true
        if let radii = effectiveCornerRadii {
            layer?.cornerRadius = radii.topLeft
        }
    }
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
        static let width: CGFloat = 440
        static let pad: CGFloat = 24
        static let headerH: CGFloat = 68
        /// footer 按钮高
        static let footerButtonH: CGFloat = 26
        /// footer 区域高 = 按钮高：按钮贴区域底（局部 y=0），区域底距窗口下边缘 = pad(24)
        /// → 按钮下缘与窗口下边缘正好 24pt。
        /// ⚠️ 别把 footerH 调大于 footerButtonH——多出来的高度会变成按钮下方的死空间
        /// （曾设 30 导致下间隔 28pt，2026-09-10 用户要求改回 24）
        static let footerH: CGFloat = footerButtonH
        /// 进度区：进度条 8 + 间距 8 + 描述行 16
        static let progressH: CGFloat = 32
        static let blockGap: CGFloat = 14
        /// header 与内容区（描述框）间距
        static let headerContentGap: CGFloat = 9   // 文本框与上方 header 间距（18 缩一半）
        /// 更新描述框高度：内容实高自适应，[保底, 封顶]
        static let notesMinH: CGFloat = 64
        static let notesMaxH: CGFloat = 150
    }

    private let win: NSWindow
    private let root = FlippedView()
    private let headerRegion = FlippedView()
    private let contentRegion = FlippedView()
    private let footerRegion = FlippedView()

    // header
    private let iconView = NSImageView()
    /// icon 高度常量约束（宽度 = 高度）：尺寸由 relayoutAndResize 按副标题实测行数更新
    private var iconHeightConstraint: NSLayoutConstraint!
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerSubtitle = NSTextField(labelWithString: "")
    // content：两块互斥/组合显示
    private let notesScroll = ConcentricScrollView()
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

    /// 描述框背景：hover 卡片同款渐变（暗色 黑@85% 两端同色），挂 scroll layer 最底层
    private let notesBackdrop = CAGradientLayer()
    /// 描述框当前高度（relayoutAndResize 按文本实高计算，[64,150] 夹取）
    private var notesContentH: CGFloat = Metrics.notesMinH
    private let cancelFlag = UpdateCancelFlag()
    private var phase: Phase = .available
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

    /// 标题栏高度（fullSizeContentView 下内容延伸进标题栏区，布局需整体下移避开红绿灯）
    private var titlebarInset: CGFloat = 0

    override init() {
        // 初始高度为占位值：真实高度由 relayoutAndResize 按 Phase + 描述实高计算
        win = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: Metrics.width, height: 320)),
                       styleMask: [.titled, .closable, .fullSizeContentView],
                       backing: .buffered,
                       defer: false)
        super.init()
        win.title = "iBalance 更新"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.backgroundColor = .clear
        win.isOpaque = false
        // 应用内主题：更新窗同样是自建顶层窗口、不在面板视图树上，外观按全局镜像显式设。
        // ⚠️ 必须在 buildUI 之前——描述框的 CALayer 描边/渐变要按窗口生效外观解算
        win.appearance = Palette.topLevelWindowAppearance
        win.delegate = self
        // Liquid Glass 窗口：整窗一块 regular 玻璃（macOS 26+ NSGlassEffectView，
        // 系统 StyleMask 无新增枚举——Tahoe/Golden Gate 的官方组合就是
        // fullSizeContentView + 透明标题栏 + 玻璃根容器）。
        // ⚠️ effectIsInteractive 不开：27 的交互式玻璃会在拖动窗口时实时重采样，
        // 玻璃层与内容层合成节奏偏差 → 内容抖动/滞后感（实测）。按钮 hover 反馈
        // 不依赖它（bezelColor 高亮照常工作）。
        let glass = NSGlassEffectView()
        glass.style = .regular
        win.contentView = glass
        root.frame = glass.bounds
        root.autoresizingMask = [.width, .height]
        glass.contentView = root
        // 红绿灯浮在玻璃上（Tahoe 一体化窗口）：窗口整体加高 titlebarInset，
        // relayoutAndResize 计算总高时会补上这段标题栏高度
        titlebarInset = win.frame.height - win.contentLayoutRect.height
        buildUI()
    }

    /// Release notes 简易 markdown 渲染（不求全，覆盖 GitHub Releases 常见语法）：
    /// - `#`/`##`/`###` 行 → 半粗标题（13/12/11pt）
    /// - `- `/`* ` 列表行 → 「• 」圆点 + 缩进
    /// - `**粗体**` → 半粗；`` `代码` `` → 等宽
    /// - 其余原样；空行保留为段间距
    private static func renderNotes(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        func paraStyle(headIndent: CGFloat) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.headIndent = headIndent
            p.paragraphSpacing = 3
            p.lineBreakMode = .byWordWrapping
            return p
        }
        for rawLine in md.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            var attrs = base
            var indent: CGFloat = 0
            let hashes = line.prefix(while: { $0 == "#" })
            if hashes.count >= 1, line.dropFirst(hashes.count).hasPrefix(" ") {
                line = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                let size: CGFloat = hashes.count == 1 ? 13 : (hashes.count == 2 ? 12 : 11)
                attrs[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
                attrs[.paragraphStyle] = paraStyle(headIndent: 0)
                out.append(NSAttributedString(string: line + "\n", attributes: attrs))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "•  " + line.dropFirst(2)
                indent = 14
            }
            attrs[.paragraphStyle] = paraStyle(headIndent: indent)
            appendInline(line + "\n", base: attrs, to: out)
        }
        return out
    }

    /// 行内扫描：`**粗体**` 与 `` `代码` ``，其余按 base 属性原样输出
    private static func appendInline(_ text: String, base: [NSAttributedString.Key: Any], to out: NSMutableAttributedString) {
        var rest = Substring(text)
        while !rest.isEmpty {
            if let b = rest.range(of: "**") {
                out.append(NSAttributedString(string: String(rest[..<b.lowerBound]), attributes: base))
                rest = rest[b.upperBound...]
                if let e = rest.range(of: "**") {
                    var bold = base
                    if let f = base[.font] as? NSFont { bold[.font] = NSFont.systemFont(ofSize: f.pointSize, weight: .semibold) }
                    out.append(NSAttributedString(string: String(rest[..<e.lowerBound]), attributes: bold))
                    rest = rest[e.upperBound...]
                } else {
                    out.append(NSAttributedString(string: "**", attributes: base))
                }
            } else if let b = rest.range(of: "`") {
                out.append(NSAttributedString(string: String(rest[..<b.lowerBound]), attributes: base))
                rest = rest[b.upperBound...]
                if let e = rest.range(of: "`") {
                    var code = base
                    if let f = base[.font] as? NSFont {
                        code[.font] = NSFont.monospacedSystemFont(ofSize: f.pointSize - 0.5, weight: .regular)
                        code[.foregroundColor] = NSColor.secondaryLabelColor
                    }
                    out.append(NSAttributedString(string: String(rest[..<e.lowerBound]), attributes: code))
                    rest = rest[e.upperBound...]
                } else {
                    out.append(NSAttributedString(string: "`", attributes: base))
                }
            } else {
                out.append(NSAttributedString(string: String(rest), attributes: base))
                return
            }
        }
    }

    // MARK: - 一次性视图构建（横向/内部布局在此定死；纵向几何由 relayoutAndResize 统一排）

    /// 裁掉应用图标四周的透明留白：macOS 图标画布按规范留 ~10% 边距，不裁的话
    /// 图形实边比 frame 顶低一截，视觉上与主标题错位（裁后图形顶=frame 顶）。
    /// 一次性全像素扫描 alpha 包围盒，仅构建时跑一次。
    ///（internal：平台开关窗口 header 图标与更新窗口统一位置/大小时复用）
    static func trimmedAppIcon() -> NSImage? {
        guard let icon = NSApp.applicationIconImage,
              let tiff = icon.tiffRepresentation,
              let src = CGImageSourceCreateWithData(tiff as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return NSApp.applicationIconImage }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return icon }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        var y = 0
        while y < h {
            var x = 0
            let rowBase = y * w * 4
            while x < w {
                if px[rowBase + x * 4 + 3] > 40 {   // 阈值 40：滤掉图标柔和投影的半透明边，只取图形实边
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                x += 1
            }
            y += 1
        }
        guard maxX >= minX, maxY >= minY else { return icon }
        // CGContext 坐标原点在左下，包围盒 y 需翻转成图像坐标
        let cropRect = CGRect(x: minX, y: h - 1 - maxY,
                              width: maxX - minX + 1, height: maxY - minY + 1)
        guard let full = ctx.makeImage(), let cropped = full.cropping(to: cropRect) else { return icon }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    private func buildUI() {
        let pad = Metrics.pad
        let innerW = Metrics.width - pad * 2

        // ── header：应用图标 + 标题 + 副标题（纵向位置由 relayoutAndResize 排）──
        root.addSubview(headerRegion)
        if let appIcon = Self.trimmedAppIcon() {
            iconView.image = appIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
        }
        // 图标纵向几何由 relayoutAndResize 按副标题实际行数动态计算（与文本块同高）
        // header 内部改用与面板卡片同构的 Auto Layout：icon 列 + 文字竖排 stack，
        // 图标尺寸/间距由约束驱动，不再手算 frame / capHeight 光学补偿
        iconView.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerSubtitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        headerTitle.textColor = .labelColor
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerSubtitle.font = .systemFont(ofSize: 11)
        headerSubtitle.textColor = .secondaryLabelColor
        headerSubtitle.lineBreakMode = .byWordWrapping
        headerSubtitle.maximumNumberOfLines = 3
        headerSubtitle.cell?.wraps = true
        headerSubtitle.cell?.isScrollable = false
        headerSubtitle.cell?.truncatesLastVisibleLine = true
        headerSubtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let infoStack = NSStackView(views: [headerTitle, headerSubtitle])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 2
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        headerRegion.addSubview(iconView)
        headerRegion.addSubview(infoStack)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 42)
        NSLayoutConstraint.activate([
            // icon：贴容器顶（用户定稿），正方形；尺寸常量由 relayoutAndResize 按副标题
            // 实测行数算（不能绑 stack 高度做 multiplier——icon 高→stack 宽→副标题折行→
            // stack 高是循环依赖，求解器会挑任意解，icon 曾被撑到 209pt）
            iconView.leadingAnchor.constraint(equalTo: headerRegion.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: headerRegion.topAnchor),
            iconView.widthAnchor.constraint(equalTo: iconView.heightAnchor),
            iconHeightConstraint,
            // 文字列：icon 右侧 8pt（2026-09-10 用户指定，原 12），顶距 4
            infoStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            infoStack.topAnchor.constraint(equalTo: headerRegion.topAnchor, constant: 4),
            infoStack.trailingAnchor.constraint(equalTo: headerRegion.trailingAnchor),
        ])

        // ── content：更新描述框 + 进度区（纵向布局见 relayoutAndResize）──
        root.addSubview(contentRegion)

        notesView.font = .systemFont(ofSize: 11)
        notesView.textColor = .labelColor
        // 玻璃窗口上日志区不再垫实底：文字直接浮在玻璃上（Liquid Glass 内容层语义）
        notesView.drawsBackground = false
        notesView.backgroundColor = .clear
        notesView.isEditable = false
        notesView.isSelectable = true
        // 富文本开（markdown 渲染靠属性字符串）；不可编辑所以无粘贴富文本副作用
        notesView.isRichText = true
        notesView.isAutomaticQuoteSubstitutionEnabled = false
        notesView.isAutomaticDashSubstitutionEnabled = false
        notesView.isVerticallyResizable = true
        notesView.isHorizontallyResizable = false
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        notesView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        notesView.textContainerInset = NSSize(width: 8, height: 8)
        notesScroll.documentView = notesView
        notesScroll.drawsBackground = false
        notesScroll.hasVerticalScroller = true
        notesScroll.hasHorizontalScroller = false
        notesScroll.autohidesScrollers = true
        notesScroll.wantsLayer = true
        // hover 卡片同款皮肤（动态色，随窗口外观深浅切换）：用量色@30% 描边 +
        // 深色 黑@50% 底 / 浅色 白@90% 底（Palette.hoverBorderBright /
        // hoverGradient 取值，与面板 hover 卡片同源）；圆角由
        // ConcentricScrollView.cornerConfiguration（containerConcentric）驱动。
        // 帧/端点/颜色统一由 applyNotesBoxSkin() 上（布局后调用，见 relayoutAndResize）
        notesScroll.layer?.borderWidth = Palette.cardBorderWidth
        notesScroll.layer?.insertSublayer(notesBackdrop, at: 0)
        notesScroll.onEffectiveAppearanceChange = { [weak self] in self?.applyNotesBoxSkin() }
        contentRegion.addSubview(notesScroll)

        // ── 进度区：进度条 + 描述（只显示最新一条进度，无步骤清单）──
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 100
        bar.isIndeterminate = true
        bar.usesThreadedAnimation = true
        bar.frame = NSRect(x: 0, y: 0, width: innerW, height: 8)
        detailLine.font = .systemFont(ofSize: 11)
        detailLine.textColor = .secondaryLabelColor
        detailLine.lineBreakMode = .byTruncatingTail
        detailLine.frame = NSRect(x: 0, y: 16, width: innerW, height: 16)
        for v in [bar, detailLine] { progressBlock.addSubview(v) }
        contentRegion.addSubview(progressBlock)

        // ── footer：按钮（纵向位置由 relayoutAndResize 排）──
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
        setSubtitle("校验通过后自动重启应用，配置不受更新影响。")
        notesView.textStorage?.setAttributedString(Self.renderNotes(notes))
        setButtons(choosing: true)
        enter(.available)
    }

    /// 安装态：从发现新版态原地过渡——点「立即更新」后更新日志文本框隐藏
    /// （notesLoaded=false，relayoutAndResize 收起并缩窗高），仅显示进度块 + 换按钮。
    func beginInstall(version: String) {
        cancelFlag.reset()
        installHandler = nil
        laterHandler = nil
        notesLoaded = false
        headerTitle.stringValue = "正在更新到 v\(version)"
        setSubtitle("下载完成后自动校验并重启；校验通过前不会改动当前版本。")
        detailLine.stringValue = ""
        bar.isHidden = false
        bar.isIndeterminate = true
        bar.doubleValue = 0
        bar.startAnimation(nil)
        setButtons(canceling: true)
        enter(.installing)
    }

    /// 失败态：错误信息进副标题（红），重试 / 手动下载 / 关闭
    func showFailure(title: String = "更新未完成",
                     message: String,
                     onRetry: @escaping () -> Void) {
        retryHandler = onRetry
        installHandler = nil
        laterHandler = nil
        headerTitle.stringValue = title
        setSubtitle(message, error: true)
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
        relayoutAndResize()
        layoutFooter()
        present()
    }

    /// 全窗口纵向重排（唯一入口）：按 Phase + 描述实高重算窗口总高并保持左上角不动。
    /// - available：header + 描述框
    /// - installing / failed：header + 描述框 + 间距 + 进度条 + 进度描述
    private func relayoutAndResize() {
        let pad = Metrics.pad
        let innerW = Metrics.width - pad * 2
        let top = titlebarInset + pad
        let showNotes = notesLoaded
        let showProgress = phase == .installing || phase == .failed
        setVisibility(notesScroll, showNotes)
        setVisibility(progressBlock, showProgress)

        // 描述框高度 = 文本实高（含 8pt 上下内边距），[64, 150] 夹取；先按最终宽度
        // 铺设视图再测量，ensureLayout 强制同步排版保证 usedRect 有效
        notesScroll.frame = NSRect(x: 0, y: 0, width: innerW, height: Metrics.notesMaxH)
        notesView.frame = NSRect(x: 0, y: 0,
                                 width: innerW - notesView.textContainerInset.width * 2, height: 10)
        if let lm = notesView.layoutManager, let tc = notesView.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let fitted = used.height + notesView.textContainerInset.height * 2
            notesContentH = min(max(fitted, Metrics.notesMinH), Metrics.notesMaxH)
        }
        // 文本框隐藏时不占空间（2026-09-10 用户确认）：高度与进度块 y 均按 showNotes 计入
        let notesH = showNotes ? notesContentH : 0
        let contentH = notesH + (showProgress ? Metrics.blockGap + Metrics.progressH : 0)
        // header 实际需要的高（约束求解下一 runloop 才回填 frame，高度计算用同步测量口径）：
        // 顶距 4 + 标题 20 + 间距 2 + 副标题实测高（≤3 行 40 封顶）+ icon 底部溢出 2
        let subW = innerW - 88
        let subFitH = headerSubtitle.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: subW, height: .greatestFiniteMagnitude)).height ?? 40
        // icon 尺寸固定 42（2026-09-10 用户指定，与平台开关窗口统一）
        iconHeightConstraint.constant = 42
        let headerNeeded = 4 + 20 + 2 + min(subFitH, 40) + 2
        // header 高度贴内容（原 68pt 地板会留 12pt 死空间垫在副标题与文本框之间，
        // 视觉上吃掉 headerContentGap 的缩放）；icon 底(≤34)始终在内容高之内
        let headerH = headerNeeded
        let rootH = top + headerH + Metrics.headerContentGap + contentH + 14 + Metrics.footerH + pad

        // 窗口高度伸缩：左上角钉住（宽度恒定，高度差在阈值内不动防微抖）
        if abs(win.frame.height - rootH) > 0.5 {
            let topLeft = NSPoint(x: win.frame.minX, y: win.frame.maxY)
            win.setContentSize(NSSize(width: Metrics.width, height: rootH))
            win.setFrameTopLeftPoint(topLeft)
        }

        // 区域纵向几何（root 为翻转坐标，y 自顶向下）
        // header 内部（icon/标题/副标题）由 Auto Layout 约束排布，这里只定容器 frame
        headerRegion.frame = NSRect(x: pad, y: top, width: innerW, height: headerH)
        contentRegion.frame = NSRect(x: pad, y: top + headerH + Metrics.headerContentGap, width: innerW, height: contentH)
        footerRegion.frame = NSRect(x: pad, y: rootH - pad - Metrics.footerH,
                                    width: innerW, height: Metrics.footerH)
        layoutFooter()
        notesScroll.frame = NSRect(x: 0, y: 0, width: innerW, height: notesContentH)
        applyNotesBoxSkin()
        if showProgress {
            progressBlock.frame = NSRect(x: 0, y: notesH + Metrics.blockGap,
                                         width: innerW, height: Metrics.progressH)
        }
        applyLayoutDebugSkin()
    }

    // MARK: - 布局调试皮肤（--layout-debug 启动参数开启）

    /// 布局调试开关：启动带 --layout-debug 时，每个容器/文本块描专属色边 + 8% 同色底，
    /// 肉眼核对边距与缩进；正常运行零影响。
    private let layoutDebug = CommandLine.arguments.contains("--layout-debug")
    private static let debugPalette: [NSColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange,
        .systemPurple, .systemTeal, .systemPink, .systemYellow,
    ]

    private func debugSkin(_ view: NSView, _ colorIndex: Int) {
        let c = Self.debugPalette[colorIndex % Self.debugPalette.count]
        view.wantsLayer = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = c.cgColor
        view.layer?.backgroundColor = c.withAlphaComponent(0.08).cgColor
    }

    /// 索引即颜色：0红 header / 1蓝 content / 2绿 描述框 / 3橙 进度区 / 4紫 footer /
    /// 5青 icon / 6粉 标题 / 7黄 副标题
    private func applyLayoutDebugSkin() {
        guard layoutDebug else { return }
        debugSkin(headerRegion, 0)
        debugSkin(contentRegion, 1)
        debugSkin(notesScroll, 2)
        debugSkin(progressBlock, 3)
        debugSkin(footerRegion, 4)
        debugSkin(iconView, 5)
        debugSkin(headerTitle, 6)
        debugSkin(headerSubtitle, 7)
    }

    /// footer 按钮右对齐排布（数组首位 = 最右主操作）。
    /// 「立即更新」在右、「稍后再说」在左（2026-09-10 用户指定换位，主操作贴右缘
    /// 符合 macOS 惯例）；failed 态 close/manual/retry 相对次序不变，installing 态仅取消。
    private func layoutFooter() {
        let ordered: [NSButton] = [closeBtn, manualBtn, retryBtn, installBtn, laterBtn, cancelBtn]
            .filter { !$0.isHidden }
        var x = footerRegion.bounds.width
        for b in ordered {
            b.sizeToFit()
            let bw = max(b.frame.width + 24, 78)
            x -= bw
            b.frame = NSRect(x: x, y: 0, width: bw, height: Metrics.footerButtonH)
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

    /// 应用内主题切换时重设窗口外观（由 AppDelegate.onToggleLightTheme 调）。
    /// 描述框的层皮肤不在这里手工重解：win.appearance 一变，notesScroll 就走
    /// viewDidChangeEffectiveAppearance → applyNotesBoxSkin 自动跟上
    func applyThemeAppearance() {
        win.appearance = Palette.topLevelWindowAppearance
    }

    /// 更新描述框皮肤：纯色底（按主题：浅色白 / 深色黑）+ 描边。
    /// 动态色按视图生效外观解算（notesScroll 在窗口层级里，取它即窗口外观）。
    /// ⚠️ CGColor 落盘就定格当时外观——外观切换时由 notesScroll.onEffectiveAppearanceChange
    /// 再调一次，别改成只在 buildUI 里设一遍
    private func applyNotesBoxSkin() {
        notesBackdrop.frame = notesScroll.bounds
        // 背景不再引用卡片渐变，纯色带统一 50% 不透明度：浅色白 / 深色黑（两端同色，layer 结构不动）
        let solid = (notesScroll.effectiveAppearance.isDark ? NSColor.black : NSColor.white)
            .withAlphaComponent(0.50)
        let cg = Palette.borderCGColor(solid, in: notesScroll)
        notesBackdrop.colors = [cg, cg]
        notesScroll.layer?.borderColor =
            Palette.borderCGColor(Palette.hoverBorderBright, in: notesScroll)
    }

    /// 已可见时直接返回：状态在窗口打开期间切换绝不重新 center / orderFront（防闪烁）
    private func present() {
        guard !win.isVisible else { return }
        win.appearance = Palette.topLevelWindowAppearance
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
        // 进度描述只显示最新一条（detail 覆盖上一条）
        detailLine.stringValue = p.detail
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

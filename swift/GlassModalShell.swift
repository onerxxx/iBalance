// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 窗口壳      GlassModalShell：titled + fullSizeContentView + NSGlassEffectView 整窗一块玻璃
//             （无标题栏 / 无红绿灯、系统 16pt 连续曲率圆角），runModal 同步模态
// 用法        addHeader(标题 + 说明[ + symbol]) → addContent(主内容) → addButton(主 / 次) → present()
//             symbol 缺省 = 应用图标；给了就画该 SF Symbol（与入口磁贴同款着色），
//             用于「入口是什么 icon，弹窗 header 就是什么 icon」的弹窗（如 3D 硬币）
// 常量口径    Metrics（宽 440 / 边距 24 / top 34 / footer 26…全弹窗唯一出处）
// 配方文档    docs/glass-modal-window-guide.md
// ⚠️ 不许改 styleMask 成 borderless：borderless 整条 layer 链 r=0，拿不到系统圆角，
//    而 NSGlassEffectView 自绘的 SDF 圆角实测只有圆弧观感（详见配方文档「圆角」一节）
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa

/// 玻璃模态窗口统一壳（更新窗口 / 平台开关弹窗 / Key 额度弹窗共用一套窗口配方）。
///
/// 窗口层：`[.titled, .fullSizeContentView]` —— **不带** closable / miniaturizable /
/// resizable，三个红绿灯按钮压根不会被创建；标题栏隐藏 + 透明，视觉上就是无框玻璃浮窗；
/// 圆角由系统 NSThemeFrame 层给出 16pt 连续曲率（与主面板 popover 同源）。
/// 内容层：contentView = NSGlassEffectView(.regular)，内嵌翻转容器，子视图按
/// 「y 自窗口顶向下」直接铺 frame（与 UpdateProgressWindow.relayoutAndResize 同法）。
/// 交互：NSApp.runModal 同步模态；保存按钮绑回车、取消按钮绑 Esc。
@MainActor
final class GlassModalShell: NSObject {

    /// 窗口与排版常量：三处玻璃弹窗共用，改这里等于改全部（勿在调用侧写死同义数值）
    enum Metrics {
        /// 窗口宽（更新窗口 / 平台开关弹窗同为 440）
        static let width: CGFloat = 440
        /// 内容区左右边距
        static let pad: CGFloat = 24
        /// 内容自窗口顶起铺的留白：顶部 32pt 落在标题栏拖动区（那里只有不可交互的图标 /
        /// 标题文字，无冲突）。2026-09-10 用户指定 icon / 主标题上方留白 20 → 40 → 34
        static let top: CGFloat = 34
        /// header 应用图标边长（裁边后按此铺）
        static let iconSide: CGFloat = 42
        /// 文字列起点 = 图标右缘 + 此间距
        static let textGap: CGFloat = 8
        /// 主标题行高
        static let titleH: CGFloat = 20
        /// header 底部余量（改它 = 改三个玻璃弹窗的 header 高度）
        static let headerBottomGap: CGFloat = 2
        /// header 与主内容间距
        static let gapHeaderContent: CGFloat = 12
        /// 主内容与按钮行间距
        static let gapContentFooter: CGFloat = 16
        /// 按钮行高
        static let footerH: CGFloat = 26
        /// 窗口底边距
        static let bottomPad: CGFloat = 20
        /// 按钮最小宽（宽 = max(sizeToFit 实宽 + 24, 此值)）
        static let buttonMinWidth: CGFloat = 78
        /// 按钮间距
        static let buttonHGap: CGFloat = 8
    }

    /// 翻转坐标容器：内容按「y 自顶向下」直接铺 frame
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private let width: CGFloat
    private var innerW: CGFloat { width - Metrics.pad * 2 }
    /// 文字列起点（图标右缘 + 间距）
    private var textX: CGFloat { Metrics.pad + Metrics.iconSide + Metrics.textGap }
    private var textW: CGFloat { innerW - Metrics.iconSide - Metrics.textGap }

    private let win: NSWindow
    private let root = FlippedView()

    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var infoView: NSView?
    private var subH: CGFloat = 0
    private var headerH: CGFloat { 4 + Metrics.titleH + 2 + subH + Metrics.headerBottomGap }

    private var contentPart: (view: NSView, height: CGFloat)?
    private var buttons: [NSButton] = []
    private var clickedIndex = -1

    /// 初始第一响应者（文本输入弹窗用；present() 时 makeFirstResponder）
    var firstResponder: NSView?

    /// 主内容可用宽（调用侧排控件行用它算宽度，勿自行 width - pad*2）
    var contentWidth: CGFloat { innerW }

    init(width: CGFloat = Metrics.width) {
        self.width = width
        // styleMask 只留 titled + fullSizeContentView（不带 closable / miniaturizable /
        // resizable）→ 无红绿灯；窗口圆角由系统 NSThemeFrame 层给出 16pt 连续曲率
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: 320)),
                           styleMask: [.titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "iBalance"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.backgroundColor = .clear
        win.isOpaque = false
        self.win = win
        super.init()
        // 玻璃不设 cornerRadius：外形完全交给窗口的 16pt 连续曲率圆角裁剪
        //（NSGlassEffectView 自绘的 SDF 圆角实测只有圆弧观感，设了会盖在系统圆角之上）
        let glass = NSGlassEffectView()
        glass.style = .regular
        win.contentView = glass
        root.frame = glass.bounds
        root.autoresizingMask = [.width, .height]
        glass.contentView = root
    }

    /// 窗口标题（仅窗口列表 / 辅助功能可见，界面上不绘制）
    func setWindowTitle(_ title: String) {
        win.title = title
    }

    /// header：图标 + 主标题 + 说明（图标贴 header 顶，文字列起点 = 图标右缘 + 间距）
    ///
    /// `symbol` 缺省（nil）= 应用图标（`UpdateProgressWindowController.trimmedAppIcon`）；
    /// 给 SF Symbol 名时改画该符号，点径 / 粗细 / 着色与入口磁贴（`ActionTileButton`）同款
    /// —— 入口磁贴是什么 icon，弹窗 header 就画同一个。
    func addHeader(title: String, info: NSAttributedString, symbol: String? = nil) {
        let iv = NSImageView()
        if let symbol,
           let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: Metrics.iconSide, weight: .medium)) {
            sym.isTemplate = true
            // 强制 size = 盒尺寸，避免 SF Symbol 的 alignmentRect 留白把图形顶偏（同磁贴口径）
            sym.size = NSSize(width: Metrics.iconSide, height: Metrics.iconSide)
            iv.image = sym
            iv.contentTintColor = Palette.cardForeground
        } else {
            iv.image = UpdateProgressWindowController.trimmedAppIcon()
        }
        iv.imageScaling = .scaleProportionallyUpOrDown
        iconView = iv

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        titleLabel = label

        // 含链接的说明走 NSTextView（NSTextField 点不动链接）；纯文本仍走 wrapping label，
        // 与平台开关弹窗既有排版口径一致
        var hasLink = false
        info.enumerateAttributes(in: NSRange(location: 0, length: info.length),
                                 options: [.longestEffectiveRangeNotRequired]) { attrs, _, _ in
            if attrs[.link] != nil { hasLink = true }
        }
        if hasLink {
            let tv = NSTextView(frame: .zero)
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.backgroundColor = .clear
            tv.isRichText = true
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainerInset = .zero
            tv.alignment = .natural
            tv.textStorage?.setAttributedString(info)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            let bounds = info.boundingRect(with: NSSize(width: textW, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
            subH = min(ceil(bounds.height), 40)
            infoView = tv
        } else {
            let field = NSTextField(wrappingLabelWithString: "")
            field.attributedStringValue = info
            let fit = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW,
                                                            height: .greatestFiniteMagnitude))
            subH = min(ceil(fit.height), 40)
            infoView = field
        }
        guard let iconView, let titleLabel, let infoView else { return }
        root.addSubview(iconView)
        root.addSubview(titleLabel)
        root.addSubview(infoView)
    }

    /// 主内容块（表格 / 表单容器），高度由调用侧给出
    func addContent(_ view: NSView, height: CGFloat) {
        contentPart = (view, height)
        root.addSubview(view)
    }

    /// 添加按钮：**第一个添加的在最右 = 主操作**（与 DialogShell 同约定），
    /// 返回索引供 present() 比对。primary = 强调色（保存类主操作）。
    @discardableResult
    func addButton(_ title: String, keyEquivalent: String = "", primary: Bool = false) -> Int {
        let index = buttons.count
        let btn = NSButton(title: title, target: self, action: #selector(onButtonClicked(_:)))
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 13)
        btn.keyEquivalent = keyEquivalent
        if primary { btn.bezelColor = .controlAccentColor }
        buttons.append(btn)
        root.addSubview(btn)
        return index
    }

    @objc private func onButtonClicked(_ sender: NSButton) {
        clickedIndex = buttons.firstIndex(of: sender) ?? -1
        NSApp.stopModal(withCode: .OK)
    }

    /// 同步模态运行，返回被点击按钮的索引（Esc / 取消返回其索引；异常收口 -1）
    func present() -> Int {
        // 应用内主题：模态壳是自建顶层窗口、不在面板视图树上，取不到容器 appearance，
        // 只能按全局镜像显式设（浅色主题开=aqua，否则 nil 跟随系统）
        win.appearance = Palette.topLevelWindowAppearance
        let contentH = contentPart?.height ?? 0
        let totalH = Metrics.top + headerH + Metrics.gapHeaderContent + contentH
            + Metrics.gapContentFooter + Metrics.footerH + Metrics.bottomPad
        win.setContentSize(NSSize(width: width, height: totalH))

        // ── frame 直铺（翻转坐标，y 自顶向下）──
        let top = Metrics.top
        iconView?.frame = NSRect(x: Metrics.pad, y: top,
                                 width: Metrics.iconSide, height: Metrics.iconSide)
        titleLabel?.frame = NSRect(x: textX, y: top + 4, width: textW, height: Metrics.titleH)
        infoView?.frame = NSRect(x: textX, y: top + 4 + Metrics.titleH + 2,
                                 width: textW, height: subH)
        contentPart?.view.frame = NSRect(x: Metrics.pad,
                                         y: top + headerH + Metrics.gapHeaderContent,
                                         width: innerW, height: contentH)
        let footerY = top + headerH + Metrics.gapHeaderContent + contentH
            + Metrics.gapContentFooter
        // 按钮自右向左排：宽 = max(sizeToFit 实宽 + 24, 78)、高 26，间 8pt，右缘对齐内容右缘
        var bx = Metrics.pad + innerW
        for btn in buttons {
            btn.sizeToFit()
            let bw = max(ceil(btn.frame.width) + 24, Metrics.buttonMinWidth)
            bx -= bw
            btn.frame = NSRect(x: bx, y: footerY, width: bw, height: Metrics.footerH)
            bx -= Metrics.buttonHGap
        }

        // ── 模态运行：回车 / Esc 两路都收口到 stopModal ──
        win.center()
        clickedIndex = -1
        // ⚠️ 先激活 App 再上屏：本 App 是 LSUIElement（默认不活跃），不激活时窗口拿不到
        // key，落在窗口里的第一次 mouseDown 会被系统当成「激活点击」吞掉 —— 用户表现为
        // 「得先点一下，之后才能拖动 / 点击」（3D 硬币拖动、滑杆等都栽在这）。
        // 口径同 UpdateProgressWindow.present() 与 Dialogs 的 NSAlert：activate +
        // orderFrontRegardless（后者不依赖 App active 态，先保证窗口被 WindowServer 登记上屏，
        // 避免 activate 未完成就 runModal 的竞态）。
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        if let firstResponder { win.makeFirstResponder(firstResponder) }
        NSApp.runModal(for: win)
        win.orderOut(nil)
        return clickedIndex
    }
}

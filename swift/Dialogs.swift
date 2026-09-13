// Dialogs.swift — iBalance
// 弹窗统一封装:DialogShell 布局系统 + 各业务弹窗(InputDialog / 平台自动化)
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 布局常量    DialogMetrics（内容宽 240 / 输入类 280 / 边距 8 / 图标 66，集中处）
// NSAlert 壳  DialogShell（原生 NSAlert 薄封装；轻量确认/输入类弹窗走它，别另起 NSAlert）
// 玻璃模态壳  GlassModalShell（另一个文件：整窗 Liquid Glass 模态窗口，App 图标 header +
//            内容块 + 保存/取消；更新窗口同配方）
// 业务弹窗    InputDialog（NSAlert 类）
// 设置窗内容   PlatformTogglesPanelView（平台开关表格；2026-09-12 由玻璃弹窗迁入设置窗口）
//
// ⚠️ 两个壳怎么选：要「和更新窗口一样的玻璃浮窗」= GlassModalShell；
//    只要一个系统小弹窗（如单行输入）= DialogShell。
// ⚠️ DialogShell 三件套（血泪坑，详见 AGENT.md 陷阱 #6）：
//    1) 标题/说明走 messageText + informativeText（系统排版），别自己堆 label；
//    2) 需要自定义排版的内容放 accessoryView；
//    3) 按钮用 addButton（第一个添加的在右侧 = 主操作、回车触发），取消按钮绑 Esc。

import Cocoa
import UserNotifications

// MARK: - 弹窗统一封装（原生 NSAlert 设定）
//
// v44 重写：回归原生 NSAlert 布局——标题/说明用 messageText / informativeText（系统排版，
// 系统字号、换行与间距），按钮用 alert.addButton（系统按钮行：第一个添加的在右侧，
// 即默认主操作，回车触发；后续按钮往左排，取消按钮绑 Esc）。
// 需要自定义排版的内容放 accessoryView：输入控件、含可点链接的富文本说明。
// 标题和图标统一使用 NSAlert 原生标题区，保持各弹窗结构一致。

enum DialogMetrics {
    /// accessoryView 默认内容宽（NSAlert 按此宽度自适应窗口；窗口宽 ≈ 此值 + 系统边距 16×2）
    static let width: CGFloat = 240
    /// 输入类弹窗（配置Key）内容宽：说明文字较长，在默认宽基础上加宽一档
    static let inputWidth: CGFloat = 280
    /// accessory 内控件区左右边距（说明/控件距窗口边缘 = 系统 16pt + 此值）
    static let sidePadding: CGFloat = 8
    /// accessory 内富文本说明与控件区间距
    static let vSpacing: CGFloat = 8
    /// 弹窗图标统一 66pt（2026-09-08 用户拍板，全弹窗唯一出处）
    static let iconSize: CGFloat = 66
}

/// 统一弹窗：原生 NSAlert 薄封装
@MainActor
final class DialogShell {
    private let alert = NSAlert()
    /// 富文本说明（含链接）：informativeText 不支持可点链接，放 accessoryView 顶部
    private var richInfo: NSAttributedString?
    /// 输入控件（输入框/下拉等），放 accessoryView 底部
    private var contentPart: (view: NSView, height: CGFloat)?
    private var buttonCount = 0
    /// accessoryView 内容宽（addContent/addInfo 的排版宽度；调用侧布局控件行也用它算宽度）
    var contentWidth: CGFloat = DialogMetrics.width
    var firstResponder: NSView?

    init() {
        alert.alertStyle = .informational
        // macOS 26 无条件显示 suppression checkbox，强制隐藏（实测有效）
        alert.showsSuppressionButton = false
        alert.suppressionButton?.isHidden = true
    }

    /// 设置标题（系统标题区，加粗）
    func addTitle(_ text: String) {
        alert.messageText = text
    }

    /// 设置图标（系统图标槽，64×64）
    func addIcon(_ image: NSImage?) {
        guard let image else { return }
        image.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
        alert.icon = image
    }

    /// 添加纯文本说明：统一转富文本样式（12pt 次级标签色、与容器等宽），与其他弹窗 info 一致
    func addInfo(_ text: String) {
        addInfo(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    }

    /// 添加富文本说明（支持链接）：左对齐，放 accessoryView 顶部
    func addInfo(_ attr: NSAttributedString) {
        richInfo = attr
    }

    /// 添加自定义控件（输入框、下拉等）
    func addContent(_ view: NSView, height: CGFloat) {
        contentPart = (view, height)
    }

    /// 添加按钮（原生按钮行：第一个添加的在右侧，即默认主操作）。
    /// 返回按钮索引，present() 返回值与之比较。
    @discardableResult
    func addButton(_ title: String, keyEquivalent: String = "", tintColor: NSColor? = nil) -> Int {
        let btn = alert.addButton(withTitle: title)
        if !keyEquivalent.isEmpty {
            btn.keyEquivalent = keyEquivalent
        }
        if tintColor != nil {
            // macOS 26 的 NSAlert rounded 次按钮使用 tintProminence 控制主次层级；
            // contentTintColor 仅适用于无边框按钮，bezelColor 在该 appearance 下会被忽略。
            btn.tintProminence = .primary
        }
        let idx = buttonCount
        buttonCount += 1
        return idx
    }

    /// 把某个按钮标成**破坏性操作**（删除类）：系统按 destructive 渲染（红色）。
    /// `present()` 之前调用，索引即 `addButton` 的返回值。
    func markDestructive(_ index: Int) {
        guard index >= 0, index < alert.buttons.count else { return }
        alert.buttons[index].hasDestructiveAction = true
    }

    /// 显示模态弹窗，返回点击的按钮索引（取消/关闭 = -1）
    func present() -> Int {
        // 组装 accessoryView：富文本说明（如有）在上、控件区在下
        var parts: [(view: NSView, height: CGFloat)] = []
        if let rich = richInfo {
            let textWidth = contentWidth - DialogMetrics.sidePadding * 2
            let bounds = rich.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
            let tv = NSTextView(frame: .zero)
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.backgroundColor = .clear
            tv.isRichText = true
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainerInset = .zero
            tv.alignment = .natural
            tv.textStorage?.setAttributedString(rich)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            parts.append((tv, ceil(bounds.height)))
        }
        if let part = contentPart {
            parts.append(part)
        }

        if !parts.isEmpty {
            var totalHeight: CGFloat = 0
            for (i, p) in parts.enumerated() {
                if i > 0 { totalHeight += DialogMetrics.vSpacing }
                totalHeight += p.height
            }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: totalHeight))
            var y = totalHeight
            for (i, p) in parts.enumerated() {
                y -= p.height
                p.view.frame = NSRect(x: DialogMetrics.sidePadding, y: y,
                                      width: contentWidth - DialogMetrics.sidePadding * 2,
                                      height: p.height)
                container.addSubview(p.view)
                if i < parts.count - 1 { y -= DialogMetrics.vSpacing }
            }
            alert.accessoryView = container
        }

        if let fr = firstResponder {
            alert.window.initialFirstResponder = fr
        }

        NSApp.activate(ignoringOtherApps: true)
        // ⚠️ 强制窗口先行上屏再进模态循环：自更新等后台 Task 冷启动场景下，
        // activate 尚未完成时直接 runModal 存在竞态——模态窗口从未被 WindowServer
        // 登记显示（CGWindowList 里不存在），主线程却吊死在 modal loop 等输入，
        // 表现为「弹窗闪没/无任何界面可点、进程假死」。访问 alert.window 会强制
        // 实例化 NSAlert 的私有 panel，orderFrontRegardless 不依赖 app active 态。
        let modalWindow = alert.window
        // NSAlert 是自建顶层窗口、不在面板视图树上：外观按全局镜像显式设，
        // 否则应用内浅色主题（系统深色）时弹窗仍是系统深色
        modalWindow.appearance = Palette.topLevelWindowAppearance
        modalWindow.orderFrontRegardless()
        let resp = alert.runModal()
        return resp.rawValue >= 1000 ? resp.rawValue - 1000 : -1
    }
}

/// WorkBuddy 品牌图标（PNG，保持原色非 template），用于添加账号选择弹窗
func makeWbBrandIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "workbuddy", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
    return img
}

/// App 图标快照（App-Icon-Default-1024@1x.png，ictool 按 design-generation 27 导出的
/// Default rendition，随 icons/*.png 打包）。操作磁贴类弹窗（手动签到/签到历史/检查更新/关于）
/// 统一用它，不走 NSApp.applicationIconImage（后者受系统图标缓存影响）
func makeAppIconSnapshot() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "App-Icon-Default-1024@1x", withExtension: "png"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = false
    img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
    return img
}

/// 弹窗统一输入框（Key / 额度 弹窗四行共用）：**只用系统 bezel，不自定义外观**。
///
/// - 形状与内缩都交给 `bezelStyle = .roundedBezel`：系统画圆角 + 边框，并自带内缩
///   （实测文字左起 = field 左缘 **+7pt**；关掉 bezel 只有 3pt、贴边）——
///   不需要手写 padding，也不需要 layer 圆角 / masksToBounds。
/// - 黑底：`NSTextField` 出厂就是 `drawsBackground = true` + `backgroundColor =
///   .textBackgroundColor`（系统语义色），深色外观下实测渲染为近黑 0.09，
///   一个颜色字段都不用写。
/// - 单行：只需 `cell.wraps = false`。实测默认 `wraps = true` 会折行（长文本折成 2 行），
///   而 `usesSingleLineMode` / `maximumNumberOfLines` / `lineBreakMode` 对是否折行毫无影响，
///   故不再设；`cell.isScrollable = true` 保留，否则长 token 尾部滚不到。
final class DarkInputField: NSTextField {
    /// 统一口径：高 22 = macOS regular 尺寸控件的标准高（`cell.cellSize` 建议 23，
    /// 系统偏好设置里的标准输入框就是 22）。探针实测：字 12 时 18 以上文字完整
    /// （墨迹像素恒 209），16 起开始压字（207）—— 22 是下限之上的安全值。
    static let defaultHeight: CGFloat = 22

    init(value: String = "", placeholder: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Self.defaultHeight))
        stringValue = value
        placeholderString = placeholder
        bezelStyle = .roundedBezel
        font = .systemFont(ofSize: 12)
        cell?.wraps = false
        cell?.isScrollable = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 弹窗内小号 checkbox：空标题、居中，辅助功能名用于旁白等读屏
private func makeCheckbox(label: String, isOn: Bool) -> NSButton {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    checkbox.controlSize = .small
    checkbox.alignment = .center
    checkbox.state = isOn ? .on : .off
    checkbox.setAccessibilityLabel(label)
    return checkbox
}

/// 平台开关表格（设置窗口「平台」pane 内嵌，2026-09-12 由 `GlassModalShell` 玻璃弹窗迁入）。
///
/// 每个平台一行，四列开关：刷新 / 签到（不支持的平台显「—」占位）/ 卡片显示 / 用量显示；
/// 行首「全选」是三态混合框 —— 该行全开=勾选、全关=空白、部分开启=「−」。
///
/// 迁入设置窗口后的口径变化：
/// - 不再自己开窗，改为**定高内容视图**（`contentHeight`）由宿主内嵌；
/// - **勾选即生效**（2026-09-12 用户去掉页脚「保存」按钮）：任一处勾选变化 → `onCommit` →
///   宿主 `makeConfig()` 合并落盘 + 同步菜单 / 签到定时器 / 面板。所以没有「未保存改动」，
///   也没有「取消」语义 —— `reload(config:)` 退化成「每次开窗回读真实配置、归一勾选态」。
///
/// 2026-09-12 排版整备（对齐设置窗口其余 pane 的 macOS 口径）：
/// - 名字 12→13pt（= Form 行正文），品牌图标 12→16pt，行高 27→**36**（用户两次各要 +4pt 行距）、
///   行间留距改**行底分隔线**；
/// - 卡片内留白 12pt（原来 0，内容贴卡缘）+ 表头下一条分隔线；
/// - 名字列由 `layout()` 吸收余量 → 四个开关列恒贴卡片右缘，窗口变宽不再在右侧留空档。
///
/// 2026-09-13 水平对齐整备（用户：「表格最左应该和标题对齐」）：
/// 面板由 `HostedPane` 内嵌在 Form Section 里，占的正是**行内容区**——
/// 离线取证（/tmp/layoutprobe：680×700 窗口，标记线实测）得到 macOS grouped Form 的三条水平基准：
/// 卡片左缘 220pt、Section 标题 = 行内容区 = 系统行分隔线左缘同为 **230pt**（卡片再内缩 10pt）。
/// 所以面板自己那 12pt 内缩是**重复留白**：表格最左会被推到标题右方 12pt，正是用户看到的那条缝。
/// - `horizontalInset` 12→**0**：表格左缘落到标题左缘；自绘行分隔线也随之与系统行分隔线同宽（230…649.5pt）。
/// - 全选列 24→20pt 且 `xPlacement` 居中→**靠左**：让行首那个框的**左缘**（而不是列中线）压在表格左缘，
///   与标题左缘像素级对齐；名字列跟着左移后，与行首框仍留 ~10pt 间距（原来是 ~9.5pt）。
@MainActor
final class PlatformTogglesPanelView: NSView {
    override var isFlipped: Bool { true }

    // MARK: - 平台表

    /// 一个平台行：除图标与名字外只描述「哪个配置位对应哪一列」——
    /// 建表、回读、保存三处都按这一张表走，不再各写一遍 7 行字面量。
    private struct Platform {
        let name: String
        /// 面板卡片 / 用量可见性字典的键
        let id: String
        /// 平台名列前置图标：bundle SVG 资源名（与面板品牌卡同图，ZCode 用 "zhipu"）
        let icon: String
        /// 参与刷新的配置位
        let refresh: WritableKeyPath<AppConfig, Bool>
        /// 自动签到配置位（nil = 该平台不支持签到，「签到」列显「—」）
        let checkin: WritableKeyPath<AppConfig, Bool>?
    }

    private static let platforms: [Platform] = [
        Platform(name: "DeepSeek", id: "ds", icon: "deepseek",
                 refresh: \.deepseekRefreshEnabled, checkin: nil),
        Platform(name: "ZhiPu", id: "zhipu", icon: "zhipu",
                 refresh: \.bigmodelRefreshEnabled, checkin: nil),
        Platform(name: "Qwen", id: "qwen", icon: "qwen",
                 refresh: \.qwenRefreshEnabled, checkin: nil),
        Platform(name: "WorkBuddy", id: "wb", icon: "workbuddy",
                 refresh: \.workbuddyEnabled, checkin: \.workbuddyAutoCheckin),
        Platform(name: "TRAE", id: "trae", icon: "trae-color",
                 refresh: \.traeRefreshEnabled, checkin: \.traeAutoCheckin),
        Platform(name: "ZCode", id: "zcode", icon: "zhipu",
                 refresh: \.zcodeRefreshEnabled, checkin: nil),
        Platform(name: "Codex", id: "codex", icon: "codex",
                 refresh: \.codexRefreshEnabled, checkin: nil),
    ]

    /// 每行的四个勾选框（与 `platforms` 同序；`checkin` nil = 该平台无签到列控件）
    private struct RowControls {
        let refresh: NSButton
        let checkin: NSButton?
        let card: NSButton
        let usage: NSButton
    }

    private enum Metrics {
        // ── 水平留白：**恒为 0**（2026-09-13 起）──
        // 面板占的是 Form Section 的行内容区，卡片已在它外面给了 10pt 留白
        // （离线取证见类注释），这里再给一次就会让表格最左比 Section 标题右移一截。
        // 0 = 表格左缘 / 右缘分别落在标题左缘、行内容区右缘。
        static let horizontalInset: CGFloat = 0
        static let topInset: CGFloat = 6
        static let bottomInset: CGFloat = 6
        // ── 表格节奏（对齐 macOS 表格：行高 36 + 行间细分隔线，不留行距）──
        static let headerHeight: CGFloat = 24
        static let rowHeight: CGFloat = 36
        static let columnSpacing: CGFloat = 4
        /// 列宽：行首全选 / 平台名（最小宽，实际由 layout 吸收余量）/ 四个开关列
        /// 名字列下限 108 = 最长平台名（WorkBuddy，13pt ≈ 74pt）+ 图标 16 + 间距 6 再留余量；
        /// 取值要保证「侧栏拉到 240 上限 + 窗口收到 640」的极限卡片宽 380 也放得下
        /// 全选列 20 = 框 14 + 6pt 余量：该列靠左放（见 buildGrid），不再为居中留白
        static let allColumnWidth: CGFloat = 20
        static let nameColumnMinWidth: CGFloat = 108
        static let toggleColumnWidth: CGFloat = 50
        /// 除名字列外的固定占宽：左右留白 + 全选列 + 四个开关列 + 5 条列间距
        static var fixedColumnsWidth: CGFloat {
            horizontalInset * 2 + allColumnWidth
                + toggleColumnWidth * 4 + columnSpacing * 5
        }
    }

    /// 内容定高（设置窗口内嵌用；手工 frame 布局的视图不参与 SwiftUI 自适应）。
    /// = 上留白 + 表头 + 行数 × 行高 + 下留白（行间不留距，分隔线画在行底）
    static var contentHeight: CGFloat {
        Metrics.topInset + Metrics.headerHeight
            + CGFloat(platforms.count) * Metrics.rowHeight + Metrics.bottomInset
    }

    private var controls: [RowControls] = []
    /// 行首「全选」checkbox 的控制器；action 目标需存活至视图销毁，由本视图持有
    private var rowAllHandlers: [RowAllHandler] = []
    /// 上一次回读的配置：保存时以它为基，未在表里的平台 / 字段原样保留
    private var originalConfig: AppConfig
    /// 表格本体（`layout()` 里按卡片可用宽度重算名字列宽）
    private var gridView: NSGridView?
    /// 上一次布局时的卡宽（分隔线重绘的去重依据，见 `layout()`）
    private var lastLaidOutWidth: CGFloat = 0
    /// 任一处勾选变化后的落盘回调（宿主编排：`makeConfig()` → 落盘 + 同步菜单 / 定时器 / 面板）
    var onCommit: (() -> Void)?

    // MARK: - 构建

    init(config: AppConfig) {
        originalConfig = config
        super.init(frame: .zero)
        let grid = buildGrid()
        gridView = grid
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: Metrics.horizontalInset),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 名字列吸收余量：四个开关列恒贴卡片右缘（macOS 表格口径）。
    /// 原来名字列写死 130 → 窗口一宽，右侧就空出一条与内容无关的空白；
    /// 现在固定列以外的宽度全给名字列；只在变宽时写回（幂等，不会来回抖）。
    override func layout() {
        super.layout()
        guard let grid = gridView else { return }
        let width = max(Metrics.nameColumnMinWidth,
                        bounds.width - Metrics.fixedColumnsWidth)
        if abs(grid.column(at: 1).width - width) > 0.5 {
            grid.column(at: 1).width = width
        }
        // 分隔线长度跟卡宽走：非 layer-backed 视图不会因 resize 自动重画，
        // 但也不能每轮 layout 都置位（拖动窗口时会白重绘），只在宽度真变了才重画
        if abs(lastLaidOutWidth - bounds.width) > 0.5 {
            lastLaidOutWidth = bounds.width
            needsDisplay = true
        }
    }

    /// 行分隔线：表头下一条 + 每行底部各一条（末行不画）——
    /// macOS 表格靠它把一行的四个开关串成一条，1 物理像素。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let lineWidth = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setStroke()
        let x0 = Metrics.horizontalInset
        let x1 = bounds.maxX - Metrics.horizontalInset
        for index in 0..<Self.platforms.count {
            let y = Metrics.topInset + Metrics.headerHeight
                + CGFloat(index) * Metrics.rowHeight + lineWidth / 2
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x0, y: y))
            line.line(to: NSPoint(x: x1, y: y))
            line.lineWidth = lineWidth
            line.stroke()
        }
    }

    private func buildGrid() -> NSGridView {
        func headerLabel(_ text: String, alignment: NSTextAlignment) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.alignment = alignment
            return label
        }
        /// 「—」占位（该平台无此项能力）：与行内文字同号的次级灰
        func unavailablePlaceholder(_ label: String) -> NSView {
            let unavailable = NSTextField(labelWithString: "—")
            unavailable.alignment = .center
            unavailable.font = .systemFont(ofSize: 13)
            unavailable.textColor = .tertiaryLabelColor
            unavailable.setAccessibilityLabel(label)
            return unavailable
        }

        var gridRows: [[NSView]] = [[
            headerLabel("", alignment: .center),
            headerLabel("平台", alignment: .natural),
            headerLabel("刷新", alignment: .center),
            headerLabel("签到", alignment: .center),
            headerLabel("卡片", alignment: .center),
            headerLabel("用量", alignment: .center),
        ]]

        for platform in Self.platforms {
            let name = NSTextField(labelWithString: platform.name)
            // 13pt = 设置窗口 Form 行正文口径（表内文字不再比其它 pane 小一档）
            name.font = .systemFont(ofSize: 13)
            name.textColor = .labelColor   // 图标 tint 同此色号（见 brandIconView）
            // 平台名列：前置 bundle SVG 品牌图标（裁边模板图，16pt 显示框），
            // 与面板品牌卡同图；取不到资源（表外平台）则只留文字
            let nameCell = NSStackView(views: [Self.brandIconView(platform.icon), name])
            nameCell.orientation = .horizontal
            nameCell.alignment = .centerY
            nameCell.spacing = 6
            let rowAll = makeCheckbox(label: "\(platform.name) 全选", isOn: false)
            let row = RowControls(
                refresh: makeCheckbox(label: "\(platform.name) 刷新",
                                      isOn: originalConfig[keyPath: platform.refresh]),
                checkin: platform.checkin.map {
                    makeCheckbox(label: "\(platform.name) 自动签到", isOn: originalConfig[keyPath: $0])
                },
                card: makeCheckbox(label: "\(platform.name) 卡片显示",
                                   isOn: originalConfig.panelCardVisible[platform.id] ?? true),
                usage: makeCheckbox(label: "\(platform.name) 用量显示",
                                    isOn: originalConfig.panelUsageVisible[platform.id] ?? true))
            controls.append(row)
            let handler = RowAllHandler(
                all: rowAll,
                options: [row.refresh, row.checkin, row.card, row.usage].compactMap { $0 })
            // 勾选即落盘：行首全选与行内单个开关共用一个回调（弱引用视图，避免循环持有）
            handler.onChange = { [weak self] in self?.onCommit?() }
            rowAllHandlers.append(handler)
            gridRows.append([
                rowAll, nameCell, row.refresh,
                row.checkin ?? unavailablePlaceholder("该平台不支持签到"),
                row.card, row.usage,
            ])
        }

        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 0            // 行高即节奏，行间靠分隔线（macOS 表格口径）
        grid.columnSpacing = Metrics.columnSpacing
        grid.xPlacement = .fill
        grid.yPlacement = .center
        grid.column(at: 0).width = Metrics.allColumnWidth
        // 靠左（不是居中）：行首全选框的**左缘**要压在表格左缘 = Section 标题左缘上
        // （2026-09-13 用户要求「表格最左和标题对齐」，居中会让框右移半个列宽）
        grid.column(at: 0).xPlacement = .leading
        // 名字列起步宽 = 最小宽，实际宽度由 layout() 按卡片可用宽度吸收余量
        grid.column(at: 1).width = Metrics.nameColumnMinWidth
        grid.column(at: 1).xPlacement = .leading
        for column in 2...5 {
            grid.column(at: column).width = Metrics.toggleColumnWidth
            grid.column(at: column).xPlacement = .center
        }
        grid.row(at: 0).height = Metrics.headerHeight
        for index in 1...Self.platforms.count {
            grid.row(at: index).height = Metrics.rowHeight
        }
        return grid
    }

    // MARK: - 回读 / 保存

    /// 回读真实配置：按配置重置全部勾选（含行首全选框）。
    /// 勾选即生效，本视图不会有「未保存编辑」，所以这里只是每次开窗的归一（幂等）。
    func reload(config: AppConfig) {
        originalConfig = config
        for (index, platform) in Self.platforms.enumerated() {
            let row = controls[index]
            row.refresh.state = config[keyPath: platform.refresh] ? .on : .off
            if let keyPath = platform.checkin {
                row.checkin?.state = config[keyPath: keyPath] ? .on : .off
            }
            row.card.state = (config.panelCardVisible[platform.id] ?? true) ? .on : .off
            row.usage.state = (config.panelUsageVisible[platform.id] ?? true) ? .on : .off
        }
        rowAllHandlers.forEach { $0.sync() }
    }

    /// 勾选结果合并回配置：以 `reload` 时的配置为基，未出现在表里的平台 / 字段原样保留
    func makeConfig() -> AppConfig {
        var updated = originalConfig
        for (index, platform) in Self.platforms.enumerated() {
            let row = controls[index]
            updated[keyPath: platform.refresh] = (row.refresh.state == .on)
            if let keyPath = platform.checkin {
                updated[keyPath: keyPath] = (row.checkin?.state == .on)
            }
            updated.panelCardVisible[platform.id] = (row.card.state == .on)
            updated.panelUsageVisible[platform.id] = (row.usage.state == .on)
        }
        return updated
    }

    // MARK: - 部件

    /// 行首「全选」控制器：勾选全开该行所有开关、取消全关；
    /// 行内任一开关变化时反向同步——全开=勾选、全关=空白、部分开启=混合态「−」。
    /// 每次状态变化后回调 `onChange`（宿主据此即时落盘，见 `PlatformTogglesPanelView.onCommit`）。
    private final class RowAllHandler: NSObject {
        private let all: NSButton
        private let options: [NSButton]
        /// 任一处变化后的通知（行首全选 / 行内单个开关都算）
        var onChange: (() -> Void)?

        init(all: NSButton, options: [NSButton]) {
            self.all = all
            self.options = options
            super.init()
            all.allowsMixedState = true
            all.target = self
            all.action = #selector(toggleAll(_:))
            for option in options {
                option.target = self
                option.action = #selector(syncAllState(_:))
            }
            sync()
        }

        /// 全选框按选项重算（构建时与 `reload` 后都要调）
        func sync() {
            all.state = Self.syncedState(of: options)
        }

        /// 全选框应显示的状态：全开=勾选、全关=空白、部分=「−」
        private static func syncedState(of options: [NSButton]) -> NSControl.StateValue {
            if options.allSatisfy({ $0.state == .on }) { return .on }
            return options.contains { $0.state == .on } ? .mixed : .off
        }

        @objc private func toggleAll(_ sender: NSButton) {
            // 点击后 sender.state 已按系统循环 off→mixed→on→off 跳变（实测）：
            // mixed 只会从「全关」点出，按主流惯例（混合态点击=全选）与 .on 一样导向全开
            let state: NSControl.StateValue = sender.state == .off ? .off : .on
            for option in options { option.state = state }
            sender.state = state    // 归一「−」中间值：选项全开时全选框不能停在混合态
            onChange?()
        }

        @objc private func syncAllState(_ sender: NSButton) {
            sync()
            onChange?()
        }
    }

    /// 平台名列前置品牌图标：bundle SVG 裁边模板图（与面板品牌卡同名资源），
    /// 固定 16×16 显示框 + 按比例填满，各 SVG 墨迹视觉大小统一（2026-09-12 随行高一起放大，
    /// 原来 12pt 相对 13pt 文字偏小；平台名行与 macOS 表单行的图标口径一致）
    ///
    /// contentTintColor 必须显式设成 labelColor：模板图在 NSImageView 里的默认着色是
    /// **secondaryLabelColor**（实测 α=0.549），比同一行的平台名 label（.labelColor，
    /// α=0.847）淡一档，看起来像两个色号；显式指定后两者同色。
    private static func brandIconView(_ resource: String) -> NSImageView {
        let size: CGFloat = 16
        let iv = NSImageView()
        iv.image = BalancePanelView.trimmedBundleSvgIcon(resource, size: size)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.contentTintColor = .labelColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: size).isActive = true
        iv.heightAnchor.constraint(equalToConstant: size).isActive = true
        return iv
    }
}

/// 通用输入弹窗控制器（API Key 等单行文本输入）。
/// 构建、联动、取值收拢在控制器内；外部只调用 present()。
@MainActor
final class InputDialog: NSObject {
    private let title: String
    private let info: String
    private let linkText: String
    private let linkURL: URL
    private let prefill: String
    private let icon: NSImage?
    private let inputView = NSTextField()

    init(title: String, info: String, linkText: String, linkURL: URL, prefill: String,
         icon: NSImage? = nil) {
        self.title = title
        self.info = info
        self.linkText = linkText
        self.linkURL = linkURL
        self.prefill = prefill
        self.icon = icon
        super.init()

        // 输入框使用 NSTextField（苹果 HIG 单行文本输入规范）：
        // - 原生 roundedBezel 外观，与系统一致
        // - cell.wraps = false + isScrollable = true → 单行不换行、水平滚动
        // - field editor 原生支持 Cmd+C/V/X/A（由主菜单 Edit 菜单分发）+ 右键菜单
        inputView.isBezeled = true
        inputView.bezelStyle = .roundedBezel
        inputView.isEditable = true
        inputView.isSelectable = true
        inputView.font = NSFont.systemFont(ofSize: 12)
        inputView.stringValue = prefill
        inputView.cell?.isScrollable = true
        inputView.cell?.wraps = false
        inputView.lineBreakMode = .byTruncatingTail
    }

    /// 同步模态运行。返回用户输入内容（去除首尾空白），取消/空输入返回 nil。
    func present() -> String? {
        let shell = DialogShell()
        shell.addIcon(icon)
        shell.addTitle(title)

        // 说明 + 链接（富文本路径放 accessoryView，与输入控件同容器等宽，12pt——与日常额度弹窗同一套规范）
        let infoAttr = NSMutableAttributedString(
            string: info,
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.secondaryLabelColor])
        infoAttr.append(NSAttributedString(
            string: linkText,
            attributes: [.link: linkURL,
                         .foregroundColor: NSColor.linkColor,
                         .underlineStyle: NSUnderlineStyle.single.rawValue,
                         .font: NSFont.systemFont(ofSize: 12)]))
        shell.addInfo(infoAttr)

        // 输入行（行宽从 shell.contentWidth 推导，本弹窗用加宽规格 inputWidth）
        shell.contentWidth = DialogMetrics.inputWidth
        let rowWidth = shell.contentWidth - DialogMetrics.sidePadding * 2
        let row = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 28))
        inputView.frame = NSRect(x: 0, y: 2, width: rowWidth, height: 24)
        row.addSubview(inputView)
        shell.addContent(row, height: 28)
        shell.firstResponder = inputView

        // NSAlert 按钮顺序：第一个添加的在右侧（默认主操作）
        let save = shell.addButton("保存", keyEquivalent: "\r")
        shell.addButton("稍后", keyEquivalent: "\u{1b}")
        let clicked = shell.present()
        guard clicked == save else { return nil }
        let v = inputView.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

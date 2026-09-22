// SwiftUI 设置窗口宿主：NSWindow + NSHostingController 保活复用（关闭仅收起、再开回到原位），
// 模型由 AppDelegate 装配（动作闭包 + 状态快照），打开前回读一次真实状态；
// 外观与其它自建顶层窗口同口径（Palette.topLevelWindowAppearance）。

import AppKit
import SettingsUI
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let model = AppSettingsModel()
    /// 侧栏「禁折叠」持续守卫的挂钩（挂在 NSSplitView 的 `willResizeSubviews` 上；
    /// 为什么必须持续守卫见 `installSplitResizeGuard`）
    private var splitResizeObserver: NSObjectProtocol?
    private var guardedSplitViewID: ObjectIdentifier?
    /// 「3D 硬币」pane 内嵌的面板（保活复用——
    /// pane 切走再回来不丢未保存调参；关闭整个窗口也不释放，下次打开续用）
    private var coinDemoPanel: CoinDemoPanelView?
    /// 「平台」pane 的开关表格（保活；每次开窗由 refresh 回读真实配置、丢弃未保存勾选）
    private var platformPanel: PlatformTogglesPanelView?
    /// 平台开关：真实配置回读 + 保存（AppDelegate 注入；保存要落盘并同步右键菜单 /
    /// 签到定时器 / 面板状态，这一整串只有宿主知道）
    var platformConfig: (() -> AppConfig?)?
    var applyPlatformConfig: ((AppConfig) -> Void)?

    override init() {
        super.init()
        model.hostedPanes = [
            // 内嵌 3D 硬币：**分四段**（预览 + Control / Edge / Motion），一段一个 Form Section。
            // 2026-09-13 用户两轮要求定下：「3D 预览框不要包裹下方的 forms」+「硬币下面的参数
            // 放在普通的 forms 里不要嵌套」—— 所以预览单独一张卡，三块参数区各自当普通 Form
            // 段（标题交给 Section header、卡底交给 Form，区块内部只留行与分隔线）。
            // 面板实例仍保活复用（切页再回来不丢未保存调参），内容由它的 stageHost /
            // splitGroupViews 提供；高度都随内容（fittingSize）
            .coinDemo: [
                SettingsHostedContent(
                    header: "3D硬币预览",
                    view: { [weak self] in self?.coinStageHostIfNeeded() ?? NSView() },
                    footnote: "",
                    // 标题 + 预览框**钉在页面顶部、不参与滚动**（2026-09-13 用户要求）；
                    // 容器尺寸也固定（面板那边舞台取满量程高，不随参数收窄）
                    pinned: true),
                SettingsHostedContent(
                    header: CoinControlSectionView.sectionTitle,
                    view: { [weak self] in self?.coinParamsGroupIfNeeded(0) ?? NSView() },
                    footnote: ""),
                SettingsHostedContent(
                    header: CoinEdgeSectionView.sectionTitle,
                    view: { [weak self] in self?.coinParamsGroupIfNeeded(1) ?? NSView() },
                    footnote: ""),
                SettingsHostedContent(
                    header: CoinMotionSectionView.sectionTitle,
                    view: { [weak self] in self?.coinParamsGroupIfNeeded(2) ?? NSView() },
                    footnote: "点击自旋、拖动翻转；调整实时生效并自动保存。"),
            ],
            // 内嵌平台开关：定高表格，**勾选即生效**（无页脚按钮）
            .platforms: [
                SettingsHostedContent(
                    header: "平台开关",
                    view: { [weak self] in self?.platformPanelIfNeeded() ?? NSView() },
                    height: PlatformTogglesPanelView.contentHeight,
                    footnote: "逐平台勾选：参与刷新、自动签到、面板余额卡片、用量行。勾选即生效。",
                    refresh: { [weak self] in
                        // 每次开窗回读真实配置（归一勾选态）；面板还没建时不必回读，
                        // 建的时候就会按当时的配置初始化
                        guard let self, let config = self.platformConfig?() else { return }
                        self.platformPanel?.reload(config: config)
                    }),
            ],
        ]
    }

    /// 3D 硬币面板：**分段内嵌**模式建（见 `SettingsHostedContent` 那段注释）——
    /// 面板自身不上屏，只作为预览框与三块参数区的宿主
    private func coinDemoPanelIfNeeded() -> CoinDemoPanelView {
        if let coinDemoPanel { return coinDemoPanel }
        let panel = CoinDemoPanelView(frame: .zero, splitHosting: true)
        coinDemoPanel = panel
        return panel
    }

    /// 「3D硬币预览」Section 的内容 = 预览框（只装 3D 舞台）
    private func coinStageHostIfNeeded() -> NSView {
        coinDemoPanelIfNeeded().stageHost
    }

    /// 「主题预设」应用后回灌「3D 硬币」pane（宿主 `applyCoinIdentity` 调）：预设把硬币的
    /// 视觉身份四项改掉了，参数区的控件初值与硬币预览都得跟着走。
    /// 面板**没建过就什么都不做** —— 建的时候本来就按当时的磁盘值初始化控件，那一刻不存在旧值
    func reloadCoinPanelIfNeeded() {
        coinDemoPanel?.reloadFromDisk()
    }

    /// Control / Edge / Motion 三个 Section 的内容 = 三块参数区（裸模式，当普通 Form 行）
    private func coinParamsGroupIfNeeded(_ index: Int) -> NSView {
        let groups = coinDemoPanelIfNeeded().splitGroupViews
        return index < groups.count ? groups[index] : NSView()
    }

    /// 平台开关表格：**必须**按真实配置建（不回退默认 AppConfig，否则一屏勾选全错），
    /// 取不到配置就是接线漏了 —— 直接给空视图，宁可空白也别显示错状态
    private func platformPanelIfNeeded() -> NSView {
        if let platformPanel { return platformPanel }
        guard let config = platformConfig?() else { return NSView() }
        let panel = PlatformTogglesPanelView(config: config)
        // 勾选即生效：任一处变化 → 落盘 + 同步菜单 / 签到定时器 / 面板
        panel.onCommit = { [weak self] in self?.applyPlatformConfigNow() }
        platformPanel = panel
        return panel
    }

    /// 取走表格当前勾选并落盘（宿主 `applyPlatformConfig` 负责后续整串同步）
    private func applyPlatformConfigNow() {
        guard let panel = platformPanel, let apply = applyPlatformConfig else { return }
        apply(panel.makeConfig())
        // ⚠️ reload 必须用**写回之后**回读的那份：`applyPlatformConfig` 是 `config = updated`，
        //    若沿用 apply 之前捕获的旧值，勾选会被打回旧态（点了又弹回去）。
        //    顺带让面板的 `originalConfig` 基保持在最新，下次合并不会以旧配置为基。
        if let saved = platformConfig?() { panel.reload(config: saved) }
    }
    /// 窗口会话进行中（open → willClose）：popover 保活 / 防 hide 判定用它而非 isVisible——
    /// windowWillClose 回调时窗口仍可见，可见性语义会把自身关闭误判成「还开着」
    private(set) var isSessionActive = false
    /// 窗口关闭回调（AppDelegate 在此 endKeepPanelAlive 恢复 popover 行为）
    var onClose: (() -> Void)?

    /// AppDelegate 启动接线时装配一次；闭包弱捕获 self，重复 configure 直接覆盖
    func configure(actions: AppSettingsActions, snapshot: @escaping () -> AppSettingsSnapshot,
                   iconProvider: ((BrandIconRequest) -> NSImage?)? = nil,
                   coinThumbnail: ((CoinVisualIdentity, CGFloat) -> NSImage?)? = nil) {
        model.actions = actions
        model.snapshotProvider = snapshot
        model.iconProvider = iconProvider
        model.coinThumbnailProvider = coinThumbnail
    }

    /// - Parameter pane: 打开后定位到的 pane（缺省 = 侧栏第一项「主题外观」）；
    ///   右键「Key / 额度设置…」（面板无对应入口）用它直达目标 pane。
    func open(pane: SettingsSidebarItem? = nil) {
        isSessionActive = true
        // 窗口是保活复用的（关闭只收起、视图不重建）：beginSession 回读真实状态
        // + 重置「Key / 额度」草稿丢弃未保存编辑（等于旧弹窗的「取消」）
        model.beginSession()
        // 直接写 selection：模型侧 `selection.didSet` 就是唯一的导航记录路径（不再另设 select()）
        if let pane { model.selection = pane }
        let win: NSWindow
        if let window {
            win = window
        } else {
            win = NSWindow(contentViewController: NSHostingController(rootView: AppSettingsView(model: model)))
            // 系统设置同款结构：fullSizeContentView + 透明标题栏 → 侧边栏材质通到窗顶、
            // 红绿灯压在侧栏上；标题文字不显示（Traffic lights 保留可关窗）
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            win.title = "iBalance 设置"   // 仅窗口切换/Mission Control 用，界面不显示
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            // 顶带高度对齐系统设置：空 unified toolbar 撑高标题栏带，红绿灯按
            // toolbar 窗口的系统布局落位（无任何可显示/可定制项）
            let toolbar = NSToolbar(identifier: "SettingsWindowToolbar")
            toolbar.displayMode = .iconOnly
            win.toolbar = toolbar
            win.toolbarStyle = .unified
            win.appearance = Palette.topLevelWindowAppearance
            // ⚠️ 玻璃底：SwiftUI 的 NavigationSplitView **确实**会给侧栏铺一层
            // NSGlassEffectView（dump 视图树实测：680×700 窗口下它就是侧栏 split item 里
            // 144×700 的那层，`style=.regular` / `tintColor=nil` —— 系统默认即 HIG 口径），
            // 但它是**背景采样型**材质 —— 采样的是「窗口之后」的东西。
            // 窗口默认 isOpaque=true + backgroundColor=.windowBackgroundColor，
            // 玻璃背后是一块不透明底，采不到任何东西 → 渲染成一块平的着色板，没有玻璃感。
            // 与 GlassModalShell / UpdateProgressWindow 的玻璃配方同口径（那两处也显式设了
            // 这两条，文档原话「背景交给玻璃，必须与上一条同时设」）。
            // ⚠️ 窗口透明只负责「让玻璃有东西可采」；侧栏那层玻璃保持系统默认
            // （`.regular` + tintColor=nil，HIG sidebar 变体），不做任何着色/改写。
            win.isOpaque = false
            win.backgroundColor = .clear
            win.isReleasedWhenClosed = false
            win.hidesOnDeactivate = false
            // ⚠️ floating 层级（GlassModalShell 同款）：本 App 是 LSUIElement/accessory，
            // .normal 窗口在 App 失活瞬间会被前台 App 的窗口盖住（表现为「点击后消失」，
            // 实际是沉到别的 App 后面，不是关闭）
            win.level = .floating
            // 首次打开的默认内容尺寸（2026-09-12 用户指定高度 500 → 700）；
            // 窗口可缩放，用户调过之后关闭再开回到原位，这里只在首次建窗时生效。
            // 尺寸口径与根视图 `.frame(minWidth:minHeight:)` 共用 SettingsWindowMetrics，避免两处漂移
            win.setContentSize(NSSize(width: SettingsWindowMetrics.defaultWidth,
                                      height: SettingsWindowMetrics.defaultHeight))
            win.contentMinSize = NSSize(width: SettingsWindowMetrics.minWidth,
                                        height: SettingsWindowMetrics.minHeight)
            win.center()
            win.delegate = self
            window = win
        }
        // 菜单栏常驻 App 无常规前台激活，需显式带前才能聚焦新窗口
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        // 视图树是懒建的：侧栏那层玻璃、底层的 NSSplitViewController 都要到上屏后的首次布局才建出来。
        // 这里补两拍（下一轮 runloop + 0.25s 后）兜底，之后每次变 key 还会重扫（见 delegate）
        DispatchQueue.main.async { [weak self] in self?.applySidebarTweaks() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.applySidebarTweaks()
        }
    }

    /// ⌘W（主菜单「文件 → 关闭窗口」）→ 走**标准关窗流程**：
    /// `performClose` → `windowWillClose` → 「Key / 额度」草稿提交 + `onClose`（恢复 popover 保活行为）。
    /// ⚠️ 别用 `orderOut` 绕过它 —— 会跳过草稿提交，编辑内容静默丢失。
    /// ⚠️ 只在窗口是 key 时才关：更新窗口等模态开着时按 ⌘W 不应把背后的设置窗口关掉。
    func close() {
        guard let win = window, win.isKeyWindow else { return }
        win.performClose(nil)
    }

    /// 全局外观（浅色主题开关）变化后重染窗口。
    /// 本窗口的 appearance 只在首次建窗时设过一次，而「主题外观」pane 就在这个窗口里 ——
    /// 不重染的话当场翻「浅色主题」这个窗口毫无反应，要关掉重开才变。
    /// 由面板侧的 `applyPanelAppearance` 调用（原同点还有一个非阻塞玻璃弹窗的重染入口，
    /// 已随 3D 硬币弹窗 2026-09-22 删除）。
    func refreshAppearance() {
        window?.appearance = Palette.topLevelWindowAppearance
    }

    // MARK: - 侧栏

    /// 侧栏「按类型找出来改」的后处理。视图树懒建（上屏后首次布局才有），
    /// 所以只在 open 的两拍兜底 + 每次变 key 时统一走这里。
    private func applySidebarTweaks() {
        pinSidebarItem()
    }

    /// 侧栏「禁折叠 + 锁宽」（用户 2026-09-12：拖到最左不要触发隐藏；2026-09-13：**固定 180pt、不可拖动**）。
    ///
    /// ⚠️ 关键：SwiftUI 的 `NavigationSplitView` **只铺一层 `NSSplitView`**，那个管理它的
    /// `NSSplitViewController` 私有子类（实测类链 `NavigationSplitViewController < SplitViewController
    /// < NSSplitViewController`）**不在 view controller 树里** —— 它是挂在 `NSSplitView.delegate`
    /// 上的。所以必须**从 delegate 反查**，遍历 `children` 一个都找不到（v100 就是这么白改一次的）。
    ///
    /// ⚠️ 折叠的真正开关也只是 sidebar 那个 `NSSplitViewItem.canCollapse`（实测初始 = `true`，
    /// 别被文档「默认 false」误导 —— 那是裸 item 的默认值，sidebar 型 item 建出来就是 true）。
    /// 光把 `columnVisibility` 锁成 `.constant(.all)` 拦不住：那把锁只管「toolbar 按钮 / 系统要求折叠」，
    /// 分隔条拖到最左走的是 split item 这条路。
    ///
    /// 离线取证 `/tmp/sidebarprobe3`（离屏真窗口 + `setPosition(minPossible)` 模拟拖到最左，
    /// 判据用 `splitViewItems[0].isCollapsed`）：基线折叠 = true；设 `canCollapse = false` 后 = false，
    /// 且 `minPossiblePositionOfDivider(0)` 自动从 −1 变 180（拖到底停在 min 宽度）。
    /// `canCollapseFromWindowResize` 会被系统联动成 false，**不必**单独设。
    ///
    /// 宽度同理逐帧钉：视图侧那条 `.navigationSplitViewColumnWidth(min:ideal:max:)` 声明式已经把
    /// item 的 minimum/maximumThickness 设成 180（离线取证 `/tmp/layoutprobe/sidebar.swift`：
    /// 强行 `setPosition(300)` / `(120)`、窗口拉宽到 900，侧栏恒 180），但 SwiftUI 重配 split item 时
    /// 同样会打回默认（`canCollapse` 就是这么被打回的），所以在同一个守卫里再钉一遍 —— 拖拽时每帧
    /// 都会经过这里，拖不动。
    private func pinSidebarItem() {
        guard let root = window?.contentViewController?.view else { return }
        for split in Self.splitViews(in: root) {
            installSplitResizeGuard(split)
            guard let svc = split.delegate as? NSSplitViewController,
                  let sidebarItem = svc.splitViewItems.first else { continue }
            // 只在真正翻掉的那一刻记一行：变 key 会重扫、拖拽时每帧都会经过这里，不判状态会刷屏
            if sidebarItem.canCollapse {
                Logger.log(.layout, "侧栏禁折叠：canCollapse true→false（splitItems=\(svc.splitViewItems.count)）")
            }
            sidebarItem.canCollapse = false
            // 掰回可能被 autosave / 上一次拖拽留下的折叠态
            if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
            // 宽度钉死（用户 2026-09-13：固定 180pt、不可拖动）
            let width = SettingsWindowMetrics.sidebarWidth
            if sidebarItem.minimumThickness != width { sidebarItem.minimumThickness = width }
            if sidebarItem.maximumThickness != width { sidebarItem.maximumThickness = width }
        }
    }

    /// 「拖到最左不折叠」的**持续守卫**。
    ///
    /// ⚠️ 为什么光设一次不够（v101 只做了一半）：SwiftUI 会在开窗 / 布局更新时重建或重配 sidebar
    /// split item，`canCollapse` 被打回 `true` —— 实测日志里每次扫描都是 `true→false`，
    /// 说明设完又被重置。而拖到最左的**第一帧**若读到 `true`，位置就已经被算成 −1，
    /// 此时再改 `canCollapse` 也救不回来（`/tmp/sidebarprobe5`：钩子明明改了，折叠照样发生）。
    ///
    /// 好在真实拖拽是**连续**的：`NSSplitView` 每帧 resize 都发 `willResizeSubviews`，
    /// 在回调里把 `canCollapse` 掰回 `false`，从第二帧起位置就被夹在 `minimumThickness`。
    /// 离线取证（`/tmp/sidebarprobe6` / `sidebarprobe7`）：`canCollapse=false` 时**越界位置也夹得住**
    /// （位置暴力设到 −1 / 0 / 100 都不折叠）；起始故意重置成 `true`，逐帧从 200 拖到 −1，
    /// 30 帧后仍是 `isCollapsed=false`。所以这一层守住就够了，不需要再掰位置。
    private func installSplitResizeGuard(_ sv: NSSplitView) {
        let id = ObjectIdentifier(sv)
        guard guardedSplitViewID != id else { return }
        stopSplitResizeGuard()
        guardedSplitViewID = id
        splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.willResizeSubviewsNotification, object: sv, queue: .main
        ) { [weak self] _ in
            // 重新走一遍扫描：期间 SwiftUI 若把 split view / item 换掉（新对象），这里也能跟上
            self?.pinSidebarItem()
        }
    }

    /// 摘掉守卫（关窗时）：窗口保活复用，下次 open 会重新装到 SwiftUI 新铺的 split view 上
    private func stopSplitResizeGuard() {
        if let token = splitResizeObserver { NotificationCenter.default.removeObserver(token) }
        splitResizeObserver = nil
        guardedSplitViewID = nil
    }

    /// 深度优先收集视图树里的 `NSSplitView`
    private static func splitViews(in view: NSView) -> [NSSplitView] {
        var found: [NSSplitView] = []
        if let split = view as? NSSplitView { found.append(split) }
        for sub in view.subviews { found.append(contentsOf: splitViews(in: sub)) }
        return found
    }

    // MARK: - NSWindowDelegate

    /// 每次成为 key 都重扫一遍侧栏后处理（见 `applySidebarTweaks`）：窗口是保活复用的，
    /// 关掉再开时 SwiftUI 可能重建过那层玻璃 / split item，着色与「禁折叠」都会被打回默认
    func windowDidBecomeKey(_ notification: Notification) {
        applySidebarTweaks()
    }

    func windowWillClose(_ notification: Notification) {
        // 侧栏守卫挂钩摘掉：窗口保活复用，视图树下次开窗可能重建，重装交给 open()
        stopSplitResizeGuard()
        // 「Key / 额度」pane 已无「保存」按钮 → 关窗即一次编辑结束，未落盘的草稿在此提交
        // （不提交的话：输入框里改了值、直接关窗就静默丢了）
        model.commitKeyQuotaIfDirty()
        // 系统色盘（「面板」组两个 ColorPicker 的入口）是 app 级独立窗口，**不随设置窗口消失** ——
        // 一起收起，免得设置窗口关了色盘还孤零零留在桌面上
        SettingsWindowController.closeOpenColorPanels()
        // 先摘会话标记再回调：endKeepPanelAlive 据此判定能否恢复 .transient
        //（此刻窗口仍可见，若按可见性判定会把自己当「还在屏」而永久卡住保活）
        isSessionActive = false
        onClose?()
    }

    /// 关掉当前打开的系统色盘。只处理**已存在**的实例（`window is NSColorPanel` 覆盖其子类）：
    /// 直接摸 `NSColorPanel.shared` 会在「压根没开过色盘」的普通关窗路径上凭空建一份实例。
    /// 若色盘是以 popover 形式附在设置窗口上（系统实现差异），它本来就跟窗一起消失，这里无副作用。
    private static func closeOpenColorPanels() {
        for window in NSApp.windows where window is NSColorPanel {
            window.close()
        }
    }
}

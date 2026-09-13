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
    /// 「3D 硬币」pane 内嵌的面板（与 GlassModalShell 弹窗同款组件，保活复用——
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
            // 内嵌 3D 硬币：面板实例惰性创建；高度 = 舞台 + 参数滚动视口（静态常量推导）；
            // 标题由 HostedPane 画在分区卡上方（Form Section header 同位，参考「动画」pane 预览区）
            .coinDemo: SettingsHostedContent(
                header: "3D硬币预览",
                view: { [weak self] in self?.coinDemoPanelIfNeeded() ?? NSView() },
                height: CoinDemoPanelView.coinHeight + CoinDemoPanelView.gap
                    + CoinDemoPanelView.paramsViewportHeight,
                footnote: "点击自旋、拖动翻转；调整实时生效，保存后按此还原。",
                actionTitle: "保存为默认",
                action: { [weak self] in self?.coinDemoPanelIfNeeded().persistDefaults() }),
            // 内嵌平台开关：定高表格，**勾选即生效**（无页脚按钮）
            .platforms: SettingsHostedContent(
                view: { [weak self] in self?.platformPanelIfNeeded() ?? NSView() },
                height: PlatformTogglesPanelView.contentHeight,
                footnote: "逐平台勾选：参与刷新、自动签到、面板余额卡片、用量行。勾选即生效。",
                refresh: { [weak self] in
                    // 每次开窗回读真实配置（归一勾选态）；面板还没建时不必回读，
                    // 建的时候就会按当时的配置初始化
                    guard let self, let config = self.platformConfig?() else { return }
                    self.platformPanel?.reload(config: config)
                }),
        ]
    }

    private func coinDemoPanelIfNeeded() -> CoinDemoPanelView {
        if let coinDemoPanel { return coinDemoPanel }
        let panel = CoinDemoPanelView(frame: .zero)
        coinDemoPanel = panel
        return panel
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
                   iconProvider: ((String) -> NSImage?)? = nil) {
        model.actions = actions
        model.snapshotProvider = snapshot
        model.iconProvider = iconProvider
    }

    /// - Parameter pane: 打开后定位到的 pane（缺省 = 侧栏第一项「主题外观」）；面板「Key / 额度」磁贴、
    ///   右键「Key / 额度设置…」用它直达目标 pane。
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
            // ⚠️ 窗口透明只负责「让玻璃有东西可采」；侧栏那层是 regular 还是 clear 由
            // `applySidebarGlass` 决定 —— 别再回头去改写 `style`（见那里的 HIG 依据）。
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
    /// 由面板侧的 `applyPanelAppearance` 与 `GlassModalShell.refreshActiveNonModalAppearance` 同点调用。
    func refreshAppearance() {
        window?.appearance = Palette.topLevelWindowAppearance
    }

    // MARK: - 侧栏

    /// 侧栏的两项「按类型找出来改」后处理。两者都是**视图树懒建**的产物（上屏后首次布局才有），
    /// 所以只在 open 的两拍兜底 + 每次变 key 时统一走这里；拖滑杆这类树已就绪的路径只需单跑玻璃那条。
    private func applySidebarTweaks() {
        applySidebarGlass()
        forbidSidebarCollapse()
    }

    /// 禁止侧栏折叠（用户 2026-09-12：「拖到最左不要触发隐藏」）。
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
    private func forbidSidebarCollapse() {
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
            self?.forbidSidebarCollapse()
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

    // MARK: - 侧栏玻璃

    /// 侧栏玻璃透明度（0…1，1 = 最透）：落盘值，见 `SidebarGlass`
    static var sidebarGlassTransparency: Double {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: UDKey.settingsSidebarGlassTransparency) != nil else {
                return SidebarGlass.defaultTransparency
            }
            let raw = defaults.double(forKey: UDKey.settingsSidebarGlassTransparency)
            return min(max(raw, SidebarGlass.transparencyRange.lowerBound),
                       SidebarGlass.transparencyRange.upperBound)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: UDKey.settingsSidebarGlassTransparency)
        }
    }

    /// 设置窗口拖动「主题外观 → 侧栏玻璃」滑杆：落盘 + 立即重灌侧栏玻璃
    func setSidebarGlassTransparency(_ t: Double) {
        Self.sidebarGlassTransparency = t
        applySidebarGlass()
    }

    /// SwiftUI 的 `NavigationSplitView` 会给侧栏铺一层 `NSGlassEffectView`
    /// （dump 视图树可见：`_NSSplitViewItemViewWrapper > NSGlassEffectView`），
    /// **默认就是 `.regular` + `tintColor = nil`** —— 这正是系统按 HIG 选定的 sidebar 变体。
    ///
    /// ⚠️ 2026-09-12 修正：先前为「更透」把它改写成 `.clear`，是**反 HIG** 的。
    /// HIG《Materials》原话：clear 变体「Only use clear Liquid Glass for components that appear
    /// over visually rich backgrounds」（图片 / 视频之上的浮层）；而 regular 变体
    /// 「Use the regular variant … when components have a significant amount of text,
    /// such as alerts, **sidebars**, or popovers」。且 `style` 是系统统一驱动的：
    /// `.regular` 会随「外观 → Liquid Glass」偏好与辅助功能（降低透明度 / 提高对比度）自适应，
    /// 写死 `.clear` 等于把这些系统设置全部绕过 —— 观感自然「不像原生」。
    /// 所以**不再碰 `style`**，交回系统。
    ///
    /// 保留的 `tintColor` = 玻璃上的**着色层**：透明度 100% 时为 nil（完全原生），
    /// 用户主动调低时才按 (1 − 透明度) 给窗口底色上 alpha，让侧栏更实。
    ///
    /// ⚠️ 这层玻璃由 SwiftUI 内部创建、没有对外 API，只能在视图树建好后**按类型找出来改**。
    /// 视图树是懒建的，所以每次窗口变 key（= 每次打开）都重扫一遍兜底；
    /// 侧栏内容切换不会重建它（它是 split item 的背景层，不是列表内容）。
    private func applySidebarGlass() {
        guard let root = window?.contentView else { return }
        // style 交给系统（`.regular`）；这里只施加可选的着色层
        let alpha = SidebarGlass.tintAlpha(forTransparency: Self.sidebarGlassTransparency)
        let tint: NSColor? = alpha <= 0.001
            ? nil
            : NSColor.windowBackgroundColor.withAlphaComponent(CGFloat(alpha))
        for glass in Self.glassEffectViews(in: root) {
            glass.tintColor = tint
        }
    }

    /// 深度优先收集视图树里的 `NSGlassEffectView`（本窗口只有侧栏那一层）
    private static func glassEffectViews(in view: NSView) -> [NSGlassEffectView] {
        var found: [NSGlassEffectView] = []
        if let glass = view as? NSGlassEffectView { found.append(glass) }
        for sub in view.subviews { found.append(contentsOf: glassEffectViews(in: sub)) }
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
        // 先摘会话标记再回调：endKeepPanelAlive 据此判定能否恢复 .transient
        //（此刻窗口仍可见，若按可见性判定会把自己当「还在屏」而永久卡住保活）
        isSessionActive = false
        onClose?()
    }
}

// PinWindow.swift — iBalance
// 面板置顶浮窗(pin):popover ↔ 无边框 NSPanel 内容转移、尺寸恢复
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)

import Cocoa
import UserNotifications

extension AppDelegate {

    /// 切换面板置顶（popover ↔ 无边框 NSPanel 浮动窗口）：
    /// - 置顶：popover 内容（contentViewController）转移至 NSPanel——无边框窗口
    ///   天然无箭头，浮层层级 + 背景原生拖动；面板背景为 TintedVisualEffectView
    ///   （毛玻璃 + 圆角 + 裁剪），透明窗口承载后外观与 popover 无缝。
    /// - 取消：浮窗直接关闭（不弹回菜单栏下方），归还焦点；
    ///   预建 popover/面板保留，下次点击菜单栏图标时由 showPanel 零构建弹出。
    func togglePanelPin() {
        // 取消置顶：浮窗直接关闭，语义与「点击图标关闭浮窗」一致
        if let fp = floatingPanel, fp.isVisible {
            fp.orderOut(nil)
            fp.contentView = nil
            floatingPanelVC = nil
            NSApp.hide(nil)
            return
        }
        guard let popover = popoverController, popover.isShown,
              let vc = popover.contentViewController,
              let popWindow = vc.view.window else { return }
        // 用内容视图自身的屏幕位置定位浮窗：popover 窗口 frame 含箭头/阴影边距，
        // 直接套用会向左上偏移；无边框浮窗内容铺满窗口，与原内容像素级重合。
        // ⚠️ 满尺寸内容（hasFullSizeContent）下 vc.view 铺满整个 popover 窗口、含顶部
        // 三角箭头带，必须取安全区矩形（= popover 正文区）：直接拿 bounds 会把浮窗
        // 撑高、内容上移一个箭头带的高度。浮窗无箭头，安全区 == bounds，自动等价。
        let safeFrame = vc.view.safeAreaRect
        let viewFrame = popWindow.convertToScreen(vc.view.convert(safeFrame, to: nil))
        let targetScreen = popWindow.screen ?? NSScreen.main
        // 恢复上次保存的浮窗尺寸（未记录时用面板当前尺寸），clamp 到上下限与屏幕
        let savedSize = restoredFloatingPanelSize(default: viewFrame.size, screen: targetScreen)
        // 目标位置：面板当前所在屏幕可见区右上角（留 8pt 边距）
        var targetFrame = viewFrame
        targetFrame.size = savedSize
        if let screen = targetScreen {
            let visible = screen.visibleFrame
            targetFrame.origin = NSPoint(x: visible.maxX - savedSize.width - 8,
                                         y: visible.maxY - savedSize.height - 8)
        }
        let fp = floatingPanel ?? makeFloatingPanel()
        floatingPanel = fp
        // 转移标志：popover 关闭回调跳过「记录点击时间戳 + NSApp.hide」
        //（hide 会隐藏包括新浮窗在内的全部窗口）
        isTransferringPanel = true
        // 先挂载（窗口按 preferredContentSize 自动定形），再 setFrame 覆盖为
        // 内容视图的实际屏幕位置——顺序颠倒会被挂载时的自动 resize 带偏。
        // ⚠️ 必须在转移当次 runloop 内解除 popover 遗留的尺寸锁定（摘 501 优先级
        // 约束 + 清零 preferredContentSize 属性）——否则窗口尺寸被同步回 popover
        // 尺寸，拖拽 resize 的 setFrame 全被弹回（v2026.8.22.81 实测只摘约束不清
        // 属性无效；延后清零也无效——经一次布局后尺寸即被锁死）。
        if let panelVC = vc as? BalancePanelViewController {
            panelVC.isFloatingWindow = true
            panelVC.detachPreferredContentSizeConstraints()
            Logger.log(.refresh, "[Pin] transferred to floating panel, pcs lock detached, preferredContentSize=\(panelVC.preferredContentSize)")
        }
        floatingPanelVC = vc as? BalancePanelViewController
        fp.contentView = vc.view
        fp.setFrame(viewFrame, display: false)
        popWindow.orderOut(nil)
        popover.close()
        isTransferringPanel = false
        fp.orderFrontRegardless()
        // 预建下一轮 popover：unpin 关闭浮窗后、点击菜单栏图标重开面板时零构建等待。
        // 面板重建是百毫秒级主线程工作，放在滑动动画发起之前——动画期间主线程
        // 空闲才能流畅播放；旧 popover（含转移过的 VC）在此整体释放。
        // ⚠️ 置顶期间 panelView 必须继续指向浮窗中的面板（数据刷新目标），
        // 预建面板单独存放，showPanel 时恢复
        let pinnedPanel = panelView
        popoverController = nil
        buildPanelOnce()
        prebuiltPanelView = panelView
        panelView = pinnedPanel
        // 浮窗可见后再滑向右上角。frame 动画必须走 animator() 代理：
        // NSAnimationContext 的 duration 只作用于 animator 调用，
        // 直接 setFrame 不吃 duration、是瞬时跳变
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = Motion.reveal
        NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fp.animator().setFrame(targetFrame, display: true)
        NSAnimationContext.endGrouping()
    }

    /// 置顶浮动窗：无边框 + 不激活（点击面板不抢 App 焦点，与 popover 行为一致）、
    /// 透明背景（圆角玻璃由面板容器自绘）、浮层层级、跟随全部 Space。
    /// ⚠️ 不用 isMovableByWindowBackground：borderless 窗口上系统会显示灰色拖动
    /// 示意条；也不用 titled+fullSizeContentView 规避——透明 titlebar 会截获顶部
    /// 鼠标事件（「余额」标题行的 pin 按钮在 titlebar 区收不到点击，无法解除置顶）。
    /// 拖动改由面板视图自绘（BalancePanelView.mouseDown）
    private func makeFloatingPanel() -> NSPanel {
        // 注意：不要加 .resizable——实测 macOS 26 下 borderless + nonactivating 面板
        // 加了也不出现系统边缘 resize 热区/光标，反而引入 borderless+resizable 的
        // 空闲 CPU 飙高系统 bug 风险。resize 走自绘把手（轮询拖拽），
        // min/maxSize 作为 setFrame 的系统级钳制兜底。
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces]
        p.hidesOnDeactivate = false
        p.minSize = NSSize(width: PanelResizeHandle.minWidth, height: PanelResizeHandle.minHeight)
        p.maxSize = NSSize(width: PanelResizeHandle.maxWidth,
                           height: NSScreen.main?.visibleFrame.height ?? 4096)
        return p
    }

    /// 恢复浮窗尺寸：优先 config 持久化值（resize 把手拖动结束时写入），
    /// 未记录（0）时用面板当前尺寸；宽 clamp 到 [240, 480]、高 ≥ 220 且不超屏幕可见高
    /// （换小屏后恢复时收缩到屏内）。宽度下限 = 面板当前内容宽：加「1小时」列后面板
    /// 自然变宽，历史保存的旧宽度不再够用（浮窗宽度本就不可手动调整，抬底无副作用）
    private func restoredFloatingPanelSize(default def: NSSize, screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = max(config.floatingPanelWidth, def.width)
        let h = config.floatingPanelHeight > 0 ? config.floatingPanelHeight : def.height
        return NSSize(width: min(max(w, PanelResizeHandle.minWidth), PanelResizeHandle.maxWidth),
                      height: min(max(h, PanelResizeHandle.minHeight), visible.height))
    }

}

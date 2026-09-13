import Cocoa
import QuartzCore

/// 显示器刷新率驱动的帧循环 —— 面板内「逐帧推进 / 逐帧 needsDisplay」的自绘动画
/// 统一从这里出帧，替代原先硬编码的 `Timer(timeInterval: 1.0 / 60.0)`。
///
/// 为什么要换掉 60Hz Timer：
/// - 固定 1/60 只是「希望的间隔」，在 120Hz（ProMotion）/ 75Hz 屏上与屏幕刷新错拍，
///   动画每两帧才前进一步，观感是周期性顿挫；displayLink 由窗口所在显示器驱动，
///   出帧节奏天然等于该屏刷新率（60 屏 60 帧、120 屏 120 帧），面板拖到另一块屏
///   也会自动跟随新屏刷新率。
/// - Timer 受 runloop 抖动影响、间隔不匀；displayLink 与垂直同步对齐，逐帧单调推进。
///
/// 用法（宿主必须是 NSView —— 出帧屏由它所在窗口决定）：
/// ```swift
/// ticker = DisplayTicker(host: self) { [weak self] in
///     guard let self else { return false }
///     self.needsDisplay = true
///     return CACurrentMediaTime() - start < total   // false = 本帧后自动停表
/// }
/// ticker?.start()
/// ```
///
/// ⚠️ 生命周期：`NSView.displayLink(target:selector:)` 强持有 target，本对象强持有
/// link，成环后 deinit 永不执行 —— 唯一解除点是 `stop()`。动效结束必须 stop；
/// 宿主先被销毁时由 onFrame 兜底停表。
final class DisplayTicker: NSObject {
    /// 每帧回调（主线程，节奏 = 显示器刷新率）。返回 false → 本帧后自动停表。
    private let step: () -> Bool
    /// 宿主视图（弱引用，不参与成环）；出帧屏 = 宿主所在窗口所在屏
    private weak var host: NSView?
    private var link: CADisplayLink?

    init(host: NSView, step: @escaping () -> Bool) {
        self.host = host
        self.step = step
        super.init()
    }

    /// 是否在跑（宿主据此避免重复启动）
    var isRunning: Bool { link != nil }

    /// 幂等启动：已在跑则直接返回（不会叠加第二个 link）
    func start() {
        guard link == nil, let host else { return }
        let l = host.displayLink(target: self, selector: #selector(onFrame(_:)))
        // .common：面板处于 event tracking（菜单/popover 交互）时也不停帧
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// 停表：invalidate 是解除「link ↔ ticker」强引用的唯一出口
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func onFrame(_ l: CADisplayLink) {
        // ⚠️ 本地强持有 self：step 回调里宿主可能 stop() 并把对本对象的引用置 nil，
        // 没有这份本地引用时 invalidate 会在本方法执行途中释放 self（use-after-free）
        withExtendedLifetime(self) {
            // 宿主已销毁（面板视图释放）：无人会再 stop，这里兜底断开成环
            guard host != nil else { stop(); return }
            if !step() { stop() }
        }
    }
}

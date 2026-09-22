// NativeRollingEngine.swift — 数值滚动的「原生引擎」（Swift 移植）
//
// 移植源：ronickg/react-native-nitro-rolling-number 的共享状态机
// `packages/react-native-nitro-rolling-number/cpp/RollingEngine.{hpp,cpp}`（Nitro Modules 的
// iOS/Android 共用 C++）。使用点 = 设置窗口「主题外观 → 卡片」的 `native_rolling_number`
// 开关，打开后由 `RollingNumberView` 用它驱动主面板的数值滚动（见那边的「原生引擎」一节）。
//
// 移植范围（**偏差逐条列出，别按原版脑补**）：
//   - 只要**滚动**那一半：Target 解算 / Wheel 连续位置 / Transition（共享时长 + 每轮 stagger +
//     方向 + 曲线）/ tick / 落定。**未移植**：jackpot reveal（count / spin 两种开奖表现、
//     里程碑、revealScale）与 loading shimmer（loadingProgress / shimmerPhase）—— 主面板没有
//     这两个用法，搬过来就是死代码。
//   - **负号不移植**：原版用 signFactor 让 "-" 随数值淡入，iBalance 的 "-" 是文本里的静态槽。
//   - 入口收**显示口径的整数幅值**（`UInt64` + 小数位数），不是原版的 `double value`：主面板的
//     数值来源是格式化文本（"1,234.56" / "0.0812" / "12.3M"），走 Double 往返既要解分隔符又有
//     精度损失。`Target` 的解算（makeTarget / digit）逐字保留，只是 `value × 10^fd` 那一步
//     改由调用方给。
//   - `reduceMotion` 不移植：主面板在「减弱动态」时压根不下发 animated（调用点已判），
//     引擎收不到动画请求。
//
// 时间 = 秒、任意单调时钟（`CACurrentMediaTime()`）；无渲染 / 无字体 / 无线程，与原版同分工。

import Foundation

/// 10^0 … 10^19（原版 `kPow10` 逐字照搬，`UInt64` 上限内）
private let kPow10: [UInt64] = [
    1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000,
    10000000000, 100000000000, 1000000000000, 10000000000000, 100000000000000,
    1000000000000000, 10000000000000000, 100000000000000000, 1000000000000000000,
    10000000000000000000,
]

/// 位数上限（原版 `kMaxPowerCount`）
private let kMaxPowerCount = 18

/// 数值滚动的原生引擎：一位数字一个「轮」，轮在 0–9 的条带上有一个连续位置；
/// 一次滚动 = 一条过渡（**共享时长** + 每轮 `stagger` 延迟），逐帧 `tick` 推进。
/// 渲染侧只读 `wheel(at:)` / `targetWheelPositions()`，绘制留在 `RollingNumberView`。
final class NativeRollingEngine {

    // MARK: - 类型

    /// 一位数字的轮
    struct Wheel: Equatable {
        /// 条带上的位置：内轮按 10 环绕（0–9，10 回到 0）；边缘轮用 −1 表示"空白"、不环绕
        var position: Double
        /// 横向占比 0…1：轮靠长/缩出现与消失
        var width: Double
        /// true = 线性条带 `[空白, 0, 1, …, 9]`（出现/消失中的轮）
        var linear: Bool
        /// 数字 0 画成空白（里程表顶上刚冒出来的那一格）
        var blankZero: Bool
    }

    /// 曲线档位（原版注释：0 线性 / 1 缓入 / 2 缓出 / 3 缓入缓出 / 4 弹簧）
    enum Easing: Int32 {
        case linear = 0, easeIn = 1, easeOut = 2, easeInOut = 3, spring = 4
    }

    /// 滚动方向（原版注释：0 自动（按变化量正负）/ 1 向上 / 2 向下）
    enum Direction: Int32 {
        case auto = 0, up = 1, down = 2
    }

    /// 目标：显示口径的整数幅值 + 位数。
    /// 原版把它叫 `Target{magnitude, negative, powerCount}`；`negative` 随符号一并省去（见文件头）。
    private struct Target {
        var magnitude: UInt64
        var powerCount: Int
        /// `10^power` 位上的数字（power 0 = 最低位）
        func digit(_ power: Int) -> Int {
            guard power >= 0, power < kPow10.count else { return 0 }
            return Int((magnitude / kPow10[power]) % 10)
        }
    }

    private struct WheelTransition {
        var from: Wheel
        var to: Wheel
    }

    private struct Transition {
        var active = false
        var start: Double = 0
        var duration: Double = 0
        /// 每轮的启动延迟（最低位在前）
        var delays: [Double] = []
        var wheels: [WheelTransition] = []
        var finals: [Wheel] = []
        /// 本段是对**正在动的轮**重新定目标：跳过缓入那一半，连续快更不再每次从静止起手（原版同款）
        var fromMotion = false
    }

    // MARK: - 配置

    private var fractionDigits = 0
    private var minimumIntegerDigits = 1
    private var duration: Double = 0.5
    private var easing: Easing = .easeInOut
    private var bounce: Double = 0.15
    private var stagger: Double = 0
    private var direction: Direction = .auto

    // MARK: - 状态

    private var wheels: [Wheel] = []
    /// 是否已有过目标（false = 首次落值，`animate` 直接摆上不做动画）。容器读它来判
    /// 「引擎还没被摆过位」（刚开启开关 / 视图刚建），先用当前显示值喂一次再滚
    private(set) var hasShownValue = false
    /// 当前（或正在滚向的）目标幅值：`setFormat` 变了要按它重建，方向判定也读它
    private var targetMagnitude: UInt64 = 0
    private var transition = Transition()

    // MARK: - 配置

    /// 小数位数（0…9）与整数部分补零下限（1…15）。**变化即按当前目标落位**（原版同款：
    /// 显示口径变了就得重排，不能拿旧位数继续插值）。
    func setFormat(fractionDigits fd: Int, minimumIntegerDigits minInt: Int) {
        let fd = min(9, max(0, fd))
        let minInt = min(15, max(1, minInt))
        guard fd != fractionDigits || minInt != minimumIntegerDigits else { return }
        fractionDigits = fd
        minimumIntegerDigits = minInt
        if hasShownValue { snap(makeTarget(magnitude: targetMagnitude)) }
    }

    /// 时长（整段共享）/ 曲线 / 弹簧回弹 / 每轮错峰 / 方向
    func setTiming(duration seconds: Double, easing: Easing, bounce: Double,
                   stagger: Double, direction: Direction) {
        duration = max(0, seconds)
        self.easing = easing
        self.bounce = bounce
        self.stagger = max(0, stagger)
        self.direction = direction
    }

    // MARK: - 命令

    /// 直接把 `magnitude` 摆上（里程表口径：轮位置连续、含进位规则），取消在途滚动。
    /// 对应原版 `setValue(value)`。
    func show(magnitude: UInt64) {
        transition.active = false
        targetMagnitude = magnitude
        hasShownValue = true

        let fd = fractionDigits
        // 原版在 double 空间里算（`scaled = |value| × 10^fd`），这里 scaled 就是幅值本身；
        // 保留同一套算式（下方 limit 与原版的 `min(scaled, 1e15)` 同量级）
        let scaled = min(Double(magnitude), 1e15)
        let whole = scaled.rounded(.down)
        let integerPart = UInt64(whole) / kPow10[fd]
        let needed = min(kMaxPowerCount, max(minimumIntegerDigits, Self.digitCount(integerPart)) + fd)

        wheels.removeAll(keepingCapacity: true)
        for power in 0...needed {
            let p10 = Double(kPow10[power])
            let digit = (scaled / p10).rounded(.down).truncatingRemainder(dividingBy: 10)
            let carry: Double
            if power == 0 {
                carry = scaled - whole
            } else {
                // 低位轮从 9 走到 0 的路上，这一轮才跟着转
                carry = Self.clamp01(scaled.truncatingRemainder(dividingBy: p10) - (p10 - 1))
            }
            if power == needed {
                // 更高一位的轮正在"冒头"（空白 → 1）
                if carry <= 0 { break }
                wheels.append(Wheel(position: carry, width: carry, linear: false, blankZero: true))
            } else {
                wheels.append(Wheel(position: digit + carry, width: 1, linear: false, blankZero: false))
            }
        }
    }

    /// 滚到 `magnitude`：每轮走**滚动方向上的最短路径**；整段共享 `duration`，每轮按
    /// `stagger × 位序` 错峰启动。
    /// 首次落值 / 时长 0 → 直接落位（原版同款；「减弱动态」由调用方挡在动画判定之前）。
    func animate(to magnitude: UInt64, at now: Double) {
        let target = makeTarget(magnitude: magnitude)
        guard hasShownValue, duration > 0 else {
            targetMagnitude = magnitude
            snap(target)
            return
        }
        let increasing = increasingToward(magnitude)
        targetMagnitude = magnitude

        let mandatory = minimumIntegerDigits + fractionDigits
        let currentCount = wheels.count
        let count = max(currentCount, target.powerCount)

        var next = Transition()
        next.active = true
        next.start = now
        next.duration = duration
        next.fromMotion = transition.active
        next.delays.reserveCapacity(count)
        next.wheels.reserveCapacity(count)
        next.finals.reserveCapacity(target.powerCount)

        for power in 0..<count {
            let current = power < currentCount
                ? wheels[power]
                : Wheel(position: -1, width: 0, linear: true, blankZero: false)
            var from = current
            let to: Wheel
            if power < target.powerCount {
                let digit = Double(target.digit(power))
                let isEdge = power >= mandatory
                    && (power >= currentCount || current.width < 1 || current.linear || current.blankZero)
                if isEdge {
                    // 出现中（或还没出完）的轮：线性条带，空白 → 数字
                    if !current.linear { from.position = Self.wrap(current.position) }
                    from.linear = true
                    to = Wheel(position: digit, width: 1, linear: true, blankZero: current.blankZero)
                } else {
                    // 内轮：按方向取最短路径
                    let base = Self.wrap(current.position)
                    from.position = base
                    from.linear = false
                    let delta = interiorDelta(digit: digit, from: base, increasing: increasing)
                    to = Wheel(position: base + delta, width: 1, linear: false, blankZero: false)
                }
                next.finals.append(Wheel(position: digit, width: 1, linear: false, blankZero: false))
            } else {
                // 消散中的轮：一边缩一边滚向空白
                if !current.linear { from.position = Self.wrap(current.position) }
                from.linear = true
                to = Wheel(position: -1, width: 0, linear: true, blankZero: current.blankZero)
            }
            next.wheels.append(WheelTransition(from: from, to: to))

            // 错峰：第 i 轮按 `stagger × i` 延后启动；已经在途的轮沿用**原本**的启动时刻
            // （不因重新定目标再被推后），否则高频更新会把低位轮饿死
            var delay = stagger * Double(power)
            if transition.active, power < transition.delays.count {
                let pending = max(0, (transition.start + transition.delays[power]) - now)
                delay = min(delay, pending)
            }
            next.delays.append(delay)
        }

        transition = next
        apply(0)
    }

    /// 若现在 `animate(to:)`，各轮将行进多少格（**只询不落位、不改任何状态**）。
    /// 与 `animate` 共用同一条方向 / 环绕 / 位移解算（`increasingToward` + `interiorDelta`），
    /// 容器据此约束共享时长 —— 原版没有这个出口：原版的时长由调用方直接给，
    /// 而 iBalance 的预算口径是「每格一个时长」，换算成一段共享时长时必须先知道各轮行程
    ///（见 `RollingNumberView.beginNativeRoll` 的时长封顶）。下标与 `wheel(at:)` 一致。
    func plannedTravels(to magnitude: UInt64) -> [Double] {
        let target = makeTarget(magnitude: magnitude)
        let increasing = increasingToward(magnitude)
        let mandatory = minimumIntegerDigits + fractionDigits
        let currentCount = wheels.count
        let count = max(currentCount, target.powerCount)
        var travels: [Double] = []
        travels.reserveCapacity(count)
        for power in 0..<count {
            let current = power < currentCount
                ? wheels[power]
                : Wheel(position: -1, width: 0, linear: true, blankZero: false)
            guard power < target.powerCount else {
                travels.append(0)          // 消散中的轮没有目标数字，不计入（容器据此取 min/max 行程）
                continue
            }
            let digit = Double(target.digit(power))
            let isEdge = power >= mandatory
                && (power >= currentCount || current.width < 1 || current.linear || current.blankZero)
            // 起点口径与 `animate` 逐字一致：线性（出现/消失中的）轮用条带原位置（空白 = −1，不环绕），
            // 内轮才取 `wrap`
            let base = (isEdge || current.linear) ? current.position : Self.wrap(current.position)
            travels.append(abs(isEdge ? digit - base
                                      : interiorDelta(digit: digit, from: base, increasing: increasing)))
        }
        return travels
    }

    /// 逐帧推进到 `now`；返回"还要不要下一帧"（= `needsFrames()`）
    @discardableResult
    func tick(_ now: Double) -> Bool {
        if transition.active {
            let elapsed = now - transition.start
            let maxDelay = transition.delays.max() ?? 0
            if elapsed >= transition.duration + maxDelay {
                finish()
            } else {
                apply(elapsed)
            }
        }
        return needsFrames()
    }

    /// 立刻落定在途过渡（轮位置 = 本段终点）。原版由 `tick` 内部调；这里额外开放给容器 ——
    /// 面板隐藏时挂起 display link 而引擎按墙钟计时，恢复后再补帧会"跳帧追赶"，
    /// 故隐藏那一刻直接落定（见 `RollingNumberView.onTick`）。
    func finishTransition() {
        guard transition.active else { return }
        finish()
    }

    /// 回到初始态（视图复用）
    func reset() {
        fractionDigits = 0
        minimumIntegerDigits = 1
        duration = 0.5
        easing = .easeInOut
        bounce = 0.15
        stagger = 0
        direction = .auto
        wheels.removeAll()
        hasShownValue = false
        targetMagnitude = 0
        transition = Transition()
    }

    // MARK: - 渲染状态

    var wheelCount: Int { wheels.count }
    func wheel(at index: Int) -> Wheel { wheels[index] }

    /// 本段各轮的**终点位置**（含环绕累积：9 → 0 走底缓冲时是 10，不是 0）。
    /// ⚠️ 与原版的差别：原版渲染只读 `wheel(at:)`（位置本身已含全部信息），iBalance 的容器
    /// 还要知道终点（槽宽端点 / chip 边缘吸附读的显示数字），故把 `transition.wheels[].to` 露出来。
    /// 无在途过渡时返回当前轮的整数位置。
    func targetWheelPositions() -> [Double] {
        if transition.active { return transition.wheels.map { $0.to.position } }
        return wheels.map { $0.position.rounded() }
    }

    /// 还有东西在动（= 在途过渡）
    func needsFrames() -> Bool { transition.active }

    // MARK: - 内部

    private func makeTarget(magnitude: UInt64) -> Target {
        let integerPart = magnitude / kPow10[fractionDigits]
        let intDigits = max(minimumIntegerDigits, Self.digitCount(integerPart))
        return Target(magnitude: magnitude,
                      powerCount: min(kMaxPowerCount, intDigits + fractionDigits))
    }

    /// 滚向 `magnitude` 时的方向判定（原 `animateTo` 里的那段：方向档位 → 布尔）。
    /// `animate` 与 `plannedTravels` 共用，两者的位移解算必须同源。
    private func increasingToward(_ magnitude: UInt64) -> Bool {
        switch direction {
        case .up: return true
        case .down: return false
        case .auto: return magnitude >= targetMagnitude
        }
    }

    /// 内轮的位移：按方向取最短路径（原 `animateTo` 里那一行，`animate` 与 `plannedTravels` 共用）
    private func interiorDelta(digit: Double, from base: Double, increasing: Bool) -> Double {
        increasing ? Self.wrap(digit - base) : -Self.wrap(base - digit)
    }

    /// 直接落位（取消在途滚动）
    private func snap(_ target: Target) {
        transition.active = false
        wheels = (0..<target.powerCount).map { power in
            Wheel(position: Double(target.digit(power)), width: 1, linear: false, blankZero: false)
        }
        hasShownValue = true
    }

    private func finish() {
        wheels = transition.finals
        transition.active = false
    }

    /// 按已过时长把每轮插到 from → to 之间
    private func apply(_ elapsed: Double) {
        let tr = transition
        if wheels.count != tr.wheels.count {
            wheels = tr.wheels.map { $0.from }
        }
        for i in 0..<tr.wheels.count {
            let wt = tr.wheels[i]
            let delay = i < tr.delays.count ? tr.delays[i] : 0
            let raw = tr.duration > 0 ? Self.clamp01((elapsed - delay) / tr.duration) : 1
            let t = tr.fromMotion ? easeFromMotion(raw) : ease(raw)
            wheels[i].position = wt.from.position + (wt.to.position - wt.from.position) * t
            wheels[i].width = Self.clamp01(wt.from.width + (wt.to.width - wt.from.width) * t)
            wheels[i].linear = wt.from.linear
            wheels[i].blankZero = wt.from.blankZero
        }
    }

    private func ease(_ t: Double) -> Double {
        switch easing {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .spring: return Self.spring(t, bounce: bounce)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }

    /// 中途重新定目标时用的曲线：缓入类塌回缓出/线性，让动着的轮永不停顿
    private func easeFromMotion(_ t: Double) -> Double {
        switch easing {
        case .linear, .easeIn: return t
        case .spring: return Self.spring(t, bounce: bounce)
        case .easeOut, .easeInOut: return 1 - pow(1 - t, 3)
        }
    }

    /// 阻尼弹簧的阶跃响应，归一化成 t == 1 时已停稳；`bounce` ↔ 阻尼比的口径与
    /// SwiftUI `.spring(duration:bounce:)` 一致（bounce 1 = 完全无阻尼）
    private static func spring(_ t: Double, bounce: Double) -> Double {
        let zeta = min(1, max(0.05, 1 - clamp01(bounce)))
        let omega = 3 * Double.pi
        let k = zeta * omega
        if zeta >= 0.999 { return 1 - (1 + k * t) * exp(-k * t) }
        let wd = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-k * t) * (cos(wd * t) + (k / wd) * sin(wd * t))
    }

    private static func wrap(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 10)
        return r < 0 ? r + 10 : r
    }

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    private static func digitCount(_ n: UInt64) -> Int {
        var n = n
        var count = 1
        while n >= 10 { n /= 10; count += 1 }
        return count
    }
}

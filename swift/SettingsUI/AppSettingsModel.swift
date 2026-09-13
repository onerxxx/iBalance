// SettingsUI — SwiftUI 设置窗口（系统设置式：左侧 sidebar + 右侧 grouped forms）。
// 独立库 target：可执行 target 不支持 Xcode Previews，纯视图 + 模型放这里；
// 宿主（iBalance 可执行目标）只负责装配动作闭包与状态快照，本 target 不依赖任何 App 类型。
// ⚠️ 跨 target 类型一律 public（internal 默认可见性对宿主不可见）。

import AppKit
import CoreImage
import SwiftUI

/// 菜单栏「进行中」状态点的小球弹跳参数（设置窗口「菜单栏」pane 可调）。
/// 刻意放在 SettingsUI 里：**宿主与设置界面共用同一份取值域与默认值** ——
/// 宿主 `MenuBarStatusGlowController` 按这份参数逐帧算小球帧，界面按同一份画实时预览，
/// 两边各写一份常量迟早会漂移。落盘读写见宿主侧的 `MenuBarBounceSettings.load()/save()`。
public struct MenuBarBounceSettings: Equatable {
    /// 弹跳高度（pt）：静止位 → 顶点
    public var amplitude: Double
    /// 一次完整弹跳周期（秒，含触地驻留）
    public var period: Double
    /// 周期中「腾空」占比（余下为触地压扁驻留）
    public var airRatio: Double
    /// 触地最扁时的纵向比例（<1 = 压扁）
    public var squashMin: Double
    /// 顶点最长时的纵向比例（>1 = 拉伸）
    public var stretchMax: Double

    public static let amplitudeRange: ClosedRange<Double> = 1...6
    public static let periodRange: ClosedRange<Double> = 0.4...1.6
    public static let airRatioRange: ClosedRange<Double> = 0.6...1
    public static let squashRange: ClosedRange<Double> = 0.6...1
    public static let stretchRange: ClosedRange<Double> = 1...1.3

    public static let initial = MenuBarBounceSettings(amplitude: 3, period: 0.8,
                                                      airRatio: 0.86, squashMin: 0.78,
                                                      stretchMax: 1.08)

    public init(amplitude: Double, period: Double, airRatio: Double,
                squashMin: Double, stretchMax: Double) {
        self.amplitude = amplitude
        self.period = period
        self.airRatio = airRatio
        self.squashMin = squashMin
        self.stretchMax = stretchMax
    }

    /// 夹回取值域：老落盘值、或将来范围收窄后都不会把滑杆顶歪
    public func clamped() -> MenuBarBounceSettings {
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double {
            min(max(v, r.lowerBound), r.upperBound)
        }
        return MenuBarBounceSettings(
            amplitude: c(amplitude, Self.amplitudeRange),
            period: c(period, Self.periodRange),
            airRatio: c(airRatio, Self.airRatioRange),
            squashMin: c(squashMin, Self.squashRange),
            stretchMax: c(stretchMax, Self.stretchRange))
    }

    /// 给定「弹跳相位内已过时间」解算这一帧的形变：
    /// 抛物线 4u(1-u)（起跳快 → 顶点缓 → 落地快）取高度，高度越低越压扁、越高越拉伸，
    /// 横向按近似体积守恒反向形变。返回值 = (垂直偏移 pt, 横向比例, 纵向比例)。
    /// ⚠️ 宿主与预览必须共用本函数，否则预览调好了上真机观感会不一样。
    public func solve(at t: TimeInterval) -> (dy: Double, sx: Double, sy: Double) {
        let phase = (t.truncatingRemainder(dividingBy: period)) / period
        let u = min(1, phase / airRatio)
        let h = 4 * u * (1 - u)
        let sy = squashMin + (stretchMax - squashMin) * h
        let sx = 1 + (1 - sy) * 0.7
        return (amplitude * h, sx, sy)
    }
}

/// 菜单栏状态点（任务指示圆点）的**绘制规格**：本体常亮圆 + 状态色高斯模糊光晕 + 余弦呼吸。
/// 菜单栏宿主（`MenuBarStatusGlowController`）与设置窗口「菜单栏」pane 的实时预览共用本规格
/// —— 预览把所有 pt 量纲乘 `visualScale` 等比放大，其余参数（透明度 / 模糊增益 / 呼吸）
/// 逐值同源；与 `MenuBarBounceSettings.solve(at:)` 同一条「两边各画一份迟早漂移」的共存铁律。
public enum MenuBarStatusDotStyle {
    /// 本体常亮透明度（弹跳只动 frame，本体不闪烁）
    public static let dotOpacity: CGFloat = 0.9
    /// 光晕画布相对圆点每侧的外扩（pt，菜单栏 1:1 口径）
    public static let glowPadding: CGFloat = 5.1
    /// 光晕高斯模糊 σ（烘焙位图像素；烘焙按 `bitmapScale` 超采样，菜单栏视觉 σ ≈ 1.7pt）
    public static let blurSigmaPx: CGFloat = 5
    /// 光晕位图超采样倍率（px/pt）
    public static let bitmapScale: CGFloat = 3
    /// 模糊后 alpha 增益（小面积光晕峰值被模糊拉低，需更高增益）
    public static let alphaBoost: CGFloat = 2.0
    /// 光晕呼吸峰值透明度
    public static let glowPeakOpacity: CGFloat = 0.7
    /// 光晕呼吸周期（余弦 0 → 峰值半周期处 → 0；与面板光环 2.8s 同口径）
    public static let breathPeriod: Double = 2.8

    /// 「进行中」蓝（宿主三态色表与设置预览共用，防止两处各写一份 RGB）
    public static let runningColor = NSColor(calibratedRed: 0.505, green: 0.824, blue: 1.0, alpha: 1)

    private static let ciContext = CIContext()

    /// 呼吸当前透明度（0 → 峰值 → 0）。宿主与预览共用同一公式
    public static func breathOpacity(at t: Double) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: breathPeriod) / breathPeriod
        let breath = 0.5 * (1 - cos(2 * .pi * phase))
        return glowPeakOpacity * CGFloat(breath)
    }

    /// 光晕位图烘焙（状态色圆点剪影 → 高斯模糊 → alpha 增益 → 裁回画布）。
    /// - Parameters:
    ///   - dotDiameter: 圆点直径的**最终视觉值**（pt）
    ///   - visualScale: 相对菜单栏实物的观感倍数（宿主 1；预览 = 放大倍数）——
    ///     画布外扩与模糊 σ 等比跟随，放大后光晕观感与实物同构
    public static func glowBitmap(color: NSColor, dotDiameter: CGFloat,
                                  visualScale: CGFloat = 1) -> CGImage? {
        let padding = glowPadding * visualScale
        let side = dotDiameter + padding * 2
        let px = max(1, Int(side * bitmapScale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // 圆点剪影（实心圆）直接矢量绘制，无需图标形状
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: padding, y: padding,
                                    width: dotDiameter, height: dotDiameter)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let base = rep.cgImage else { return nil }

        // 高斯模糊 + alpha 增益（模糊拉低峰值）+ 裁回画布（模糊 extent 外扩，不裁会破坏 frame 对位）；
        // σ 随观感倍数放大（菜单栏 σ=5px@3x ≈ 1.7pt，等比放大后视觉同构）
        var ci = CIImage(cgImage: base)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(ci, forKey: kCIInputImageKey)
            blur.setValue(blurSigmaPx * visualScale, forKey: kCIInputRadiusKey)
            ci = blur.outputImage ?? ci
        }
        if let boost = CIFilter(name: "CIColorMatrix") {
            boost.setValue(ci, forKey: kCIInputImageKey)
            boost.setValue(CIVector(x: 0, y: 0, z: 0, w: alphaBoost), forKey: "inputAVector")
            ci = boost.outputImage ?? ci
        }
        ci = ci.cropped(to: CGRect(x: 0, y: 0, width: px, height: px))
        return ciContext.createCGImage(ci, from: ci.extent)
    }
}

/// 设置窗口尺寸口径：**宿主（`SettingsWindowController`）与视图共用同一份常量**，
/// 免得「视图 min 640×460」和「窗口 setContentSize 680×700」各写一遍后漂移。
public enum SettingsWindowMetrics {
    /// 首次打开的内容尺寸（用户调过之后关闭再开回到原位，只在首次建窗时生效）
    public static let defaultWidth: CGFloat = 680
    public static let defaultHeight: CGFloat = 700
    /// 内容最小尺寸 = 根视图 `.frame(minWidth:minHeight:)`，宿主据此设 `contentMinSize`
    public static let minWidth: CGFloat = 640
    public static let minHeight: CGFloat = 460
    /// 侧栏宽度：**固定值**（2026-09-13 用户要求「固定 180pt、不可拖动」；原为 min 180 / ideal 200 / max 240）。
    /// 视图侧 `.navigationSplitViewColumnWidth(min:ideal:max:)` 与宿主侧 `NSSplitViewItem` 的
    /// minimum/maximumThickness 共用这一个数 —— 两处都钉死才是真「拖不动」
    public static let sidebarWidth: CGFloat = 180
}

/// 「已保存账号」分组（2026-09-13 用户要求）：账号页逐平台列出已保存账号并支持逐个删除。
public struct SavedAccountGroup: Equatable, Identifiable {
    /// 平台键（workbuddy / trae / zcode / codex）：删除动作回传宿主，用于定位账号数组与菜单栏前缀
    public let id: String
    /// 平台展示名（Section header）
    public let platform: String
    /// 平台品牌图标键（与面板卡片图标名同源，经宿主 iconProvider 解析）
    public let iconKey: String
    public let accounts: [SavedAccountEntry]

    public init(id: String, platform: String, iconKey: String, accounts: [SavedAccountEntry]) {
        self.id = id
        self.platform = platform
        self.iconKey = iconKey
        self.accounts = accounts
    }
}

/// 单个已保存账号：name = 展示名（昵称 / 用户名 / 邮箱），detail = 次要标识（uid 等，可空）
public struct SavedAccountEntry: Equatable, Identifiable {
    public let id: String      // uid
    public let name: String
    public let detail: String

    public init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// 设置窗口各项的当前值快照：宿主从真实状态（config / 面板快照）装配，预览给静态值。
public struct AppSettingsSnapshot: Equatable {
    /// 刷新间隔（秒）：60 / 180 / 300，存量异常值由宿主归一到 300
    public var refreshInterval: Int = 300
    public var autoCheckin: Bool = false
    /// 今日签到统计文案（如 "9-12 3成功 1失败"），空 = 今天尚未产生签到结果
    public var autoCheckinSub: String = ""
    public var autoUpdateCheck: Bool = false
    /// 菜单栏状态点小球弹跳参数（「菜单栏」pane）
    public var bounce: MenuBarBounceSettings = .initial
    /// ── 「主题外观」pane：以下各项（原「主题调教」玻璃弹窗内容）──
    /// 「高对比背景」强度（0…1，0 = 无遮罩原生玻璃；面板遮罩 alpha 随此值缩放）
    public var panelMaskOpacity: Double = 1
    /// 浅色主题开关（强制浅色外观，即使系统是深色主题）
    public var lightThemeEnabled = false
    /// 品牌 icon 深浅版互换
    public var iconThemeSwap = false
    /// 品牌 icon 裁圆（宽高不变，仅形状裁切；任务状态光环同步翻圆形）
    public var circularIcon = false
    /// 长进度卡片（整行进度条 + 副标题下移）
    public var longProgressCard = false
    /// 卡片主标题字号（pt，10…18）
    public var cardTitleFontSize: Double = 13
    /// 卡片主标题 Sharp Grotesk（本机安装的商业字体；未装该字重回落系统字体）
    public var cardTitleSharpGrotesk = false
    /// Sharp Grotesk 字重档（0=Thin 1=Book 2=Light 3=Medium 4=SemiBold 5=Bold 6=Black）
    public var cardTitleSGWeight = 3
    /// Sharp Grotesk 宽度档（0=05 1=10 2=15 3=20 4=25）
    public var cardTitleSGWidth = 3
    /// 点阵主题色相（0…1）
    public var heatHue: Double = 0
    /// 点阵主题饱和度（0…1）
    public var heatSaturation: Double = 0
    /// 点阵主题峰值明度（0…1）
    public var heatBrightness: Double = 0
    /// DeepSeek API Key（真实值来自钥匙串；空 = 未配置）
    public var apiKey: String = ""
    /// DeepSeek 常用充值额度（0 = 未设置 → 面板不画点阵；>0 = 点阵分母）
    public var commonQuota: Double = 0
    /// ZhiPu Token 手填覆盖（空 = 自动读浏览器登录态）
    public var zhipuToken: String = ""
    /// Qwen Ticket 手填覆盖（空 = 自动读浏览器登录态）
    public var qwenTicket: String = ""
    /// 「账号」pane 底部「删除账号」用：已保存的**账号数**（WorkBuddy / TRAE / ZCode / Codex 四个数组之和）
    public var savedAccountCount: Int = 0
    /// 同上：已保存的**手填凭据数**（DeepSeek Key / ZhiPu Token / Qwen Ticket 里非空的条数）
    public var savedOverrideCount: Int = 0
    /// 「已保存账号」列表（2026-09-13 用户要求）：逐平台分组，空平台不出现；全空 = 空数组
    public var savedAccountGroups: [SavedAccountGroup] = []

    public init(refreshInterval: Int = 300, autoCheckin: Bool = false,
                autoCheckinSub: String = "", autoUpdateCheck: Bool = false,
                bounce: MenuBarBounceSettings = .initial,
                apiKey: String = "", commonQuota: Double = 0,
                zhipuToken: String = "", qwenTicket: String = "",
                savedAccountCount: Int = 0, savedOverrideCount: Int = 0,
                savedAccountGroups: [SavedAccountGroup] = [],
                panelMaskOpacity: Double = 1, lightThemeEnabled: Bool = false,
                iconThemeSwap: Bool = false, circularIcon: Bool = false,
                longProgressCard: Bool = false,
                cardTitleFontSize: Double = 13, cardTitleSharpGrotesk: Bool = false,
                cardTitleSGWeight: Int = 3, cardTitleSGWidth: Int = 3,
                heatHue: Double = 0, heatSaturation: Double = 0, heatBrightness: Double = 0) {
        self.refreshInterval = refreshInterval
        self.autoCheckin = autoCheckin
        self.autoCheckinSub = autoCheckinSub
        self.autoUpdateCheck = autoUpdateCheck
        self.bounce = bounce
        self.apiKey = apiKey
        self.commonQuota = commonQuota
        self.zhipuToken = zhipuToken
        self.qwenTicket = qwenTicket
        self.savedAccountCount = savedAccountCount
        self.savedOverrideCount = savedOverrideCount
        self.savedAccountGroups = savedAccountGroups
        self.panelMaskOpacity = panelMaskOpacity
        self.lightThemeEnabled = lightThemeEnabled
        self.iconThemeSwap = iconThemeSwap
        self.circularIcon = circularIcon
        self.longProgressCard = longProgressCard
        self.cardTitleFontSize = cardTitleFontSize
        self.cardTitleSharpGrotesk = cardTitleSharpGrotesk
        self.cardTitleSGWeight = cardTitleSGWeight
        self.cardTitleSGWidth = cardTitleSGWidth
        self.heatHue = heatHue
        self.heatSaturation = heatSaturation
        self.heatBrightness = heatBrightness
    }
}

/// 全部动作由宿主装配（面板/AppDelegate 既有回调的转发）；默认空实现保证预览可跑。
public struct AppSettingsActions {
    public var setRefreshInterval: (Int) -> Void = { _ in }
    /// 宿主是翻转式实现（读 config 取反），传期望值、由宿主比对后再翻
    public var toggleAutoCheckin: (Bool) -> Void = { _ in }
    public var toggleAutoUpdateCheck: (Bool) -> Void = { _ in }
    public var checkForUpdate: () -> Void = {}
    public var runUpdateDemo: () -> Void = {}
    public var addWbAccount: () -> Void = {}
    public var addTraeAccount: () -> Void = {}
    public var addZcodeAccount: () -> Void = {}
    public var addCodexAccount: () -> Void = {}
    /// Key/额度表单保存（2026-09-13 并入账号 pane；apiKey、日常额度、ZhiPu Token、Qwen Ticket；空串 = 清除该项覆盖）
    public var saveKeyQuota: (String, Double, String, String) -> Void = { _, _, _, _ in }
    /// 「账号」pane 底部「删除账号」（2026-09-13 用户要求）：清空全部已保存的平台凭据 ——
    /// WorkBuddy / TRAE / ZCode / Codex 的账号数组 + DeepSeek Key / ZhiPu Token / Qwen Ticket 手填覆盖。
    /// 二次确认与结果提示都由宿主负责（破坏性操作，UI 这边只发一个意图）
    public var deleteAllAccounts: () -> Void = {}
    /// 「已保存账号」列表的逐个删除（2026-09-13 用户要求）：platform = 平台键
    /// （workbuddy / trae / zcode / codex），uid = 账号 uid。二次确认由宿主负责（破坏性操作）
    public var deleteAccount: (String, String) -> Void = { _, _ in }
    /// ── 「主题外观」pane：外观开关（传期望值，宿主比对当前配置后再落盘）+ 强度滑杆 ──
    /// 「高对比背景」强度（0…1，0 = 原生玻璃；宿主：落盘 + 快照同步重绘遮罩）
    public var setPanelMaskOpacity: (Double) -> Void = { _ in }
    public var setLightTheme: (Bool) -> Void = { _ in }
    public var setIconThemeSwap: (Bool) -> Void = { _ in }
    public var setCircularIcon: (Bool) -> Void = { _ in }
    public var setLongProgressCard: (Bool) -> Void = { _ in }
    /// 「主题外观」pane 点阵色相 / 饱和度 / 明度（0…1；宿主：落 UserDefaults + 就地重绘点阵与边框）
    public var setHeatHue: (Double) -> Void = { _ in }
    public var setHeatSaturation: (Double) -> Void = { _ in }
    public var setHeatBrightness: (Double) -> Void = { _ in }
    public var manualCheckin: () -> Void = {}
    public var showCheckinHistory: () -> Void = {}
    public var shareWbHistory: () -> Void = {}
    /// 菜单栏小球弹跳参数变更（宿主：写内存 + 落盘 + 推给 MenuBarStatusGlowController）
    public var setBounce: (MenuBarBounceSettings) -> Void = { _ in }
    /// 卡片主标题字号 / Sharp Grotesk 开关与字重×宽度档（「主题外观 → 卡片」；
    /// 宿主：写 config + 落盘 + syncPanel，面板快照比对变化后就地重刷标题）
    public var setCardTitleFontSize: (Double) -> Void = { _ in }
    public var setCardTitleSharpGrotesk: (Bool) -> Void = { _ in }
    public var setCardTitleSGWeight: (Int) -> Void = { _ in }
    public var setCardTitleSGWidth: (Int) -> Void = { _ in }
    public var about: () -> Void = {}

    public init() {}
}

/// Key/额度表单的编辑草稿（原 DeepSeek / ZhiPu / Qwen 玻璃弹窗的四项内容；2026-09-13 并入账号 pane）。
///
/// 草稿刻意放模型而不是视图的 `@State`：本机工具链是 CLT，SwiftUI 的 `@State` 是宏
/// （`SwiftUIMacros.StateMacro`），没有 Xcode 就没有那个插件，编不过 —— 见本文件头注释。
/// 模型是 `@Observable` 类，草稿字段照样能驱动界面刷新。
public struct KeyQuotaDraft: Equatable {
    /// 日常额度下拉的预设档（与旧弹窗同一份取值域；`value` 兼作 `Identifiable.id`）
    public struct QuotaPreset: Identifiable, Hashable {
        public let title: String
        public let value: Double
        public var id: Double { value }

        public init(title: String, value: Double) {
            self.title = title
            self.value = value
        }
    }

    /// 额度选择：预设档 or 自定义手填。用枚举而不是「下标 + 哨兵值」，
    /// 下拉项 identity 稳定（`ForEach` 不靠 index，也不用手算 customTag）。
    public enum QuotaChoice: Hashable {
        case preset(Double)
        case custom
    }

    /// 日常额度预设档（`value == 0` = 未设置，面板不画点阵）
    public static let presets: [QuotaPreset] = [
        QuotaPreset(title: "未设置", value: 0),
        QuotaPreset(title: "¥10", value: 10),
        QuotaPreset(title: "¥20", value: 20),
        QuotaPreset(title: "¥50", value: 50),
        QuotaPreset(title: "¥100", value: 100),
    ]

    public var apiKey = ""
    public var quotaChoice: QuotaChoice = .preset(0)
    /// 自定义档的手填额度文本
    public var quotaText = ""
    public var zhipuToken = ""
    public var qwenTicket = ""

    public init() {}

    /// 草稿对应的额度值：自定义档解析失败按 0（= 不设置，面板不画点阵）处理
    public var quota: Double {
        switch quotaChoice {
        case .preset(let value):
            return value
        case .custom:
            return max(0, Double(quotaText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        }
    }

    /// 真实配置 → 草稿：非预设额度自动落到「自定义」档
    public static func from(apiKey: String, quota: Double,
                            zhipuToken: String, qwenTicket: String) -> KeyQuotaDraft {
        var d = KeyQuotaDraft()
        d.apiKey = apiKey
        d.zhipuToken = zhipuToken
        d.qwenTicket = qwenTicket
        if quota > 0 {
            d.quotaChoice = presets.contains { $0.value == quota } ? .preset(quota) : .custom
            d.quotaText = String(Int(quota))
        }
        return d
    }
}

/// 某个 pane 的**内嵌 AppKit 内容**：面板上那些用 CoreGraphics 自绘 / 复用既有 AppKit 控件的
/// 区块（3D 硬币舞台、主题调教表单、平台开关表格）不适合用 SwiftUI 重写，整块嵌进设置窗口右栏。
///
/// 与 `AppSettingsSnapshot` / `AppSettingsActions` 同一分工：状态与动作仍是宿主装配，
/// 这里只描述「拿哪个视图、占多高、配什么页脚与按钮」。
public struct SettingsHostedContent {
    /// 分区卡上方的标题（Form Section header 同位，nil = 无标题）
    public let header: String?
    /// 构造/返回内容视图（宿主持有实例，pane 切走再回来不丢未保存调参）
    public let view: () -> NSView
    /// 内容区定高（nil = 高度随内容，视图 fittingSize 决定）
    public let height: CGFloat?
    /// 内容下方（可滚动区）的说明文字
    public let footnote: String
    /// 页脚按钮标题（nil = 该 pane 即时生效、无保存动作）
    public let actionTitle: String?
    public let action: (() -> Void)?
    /// 每次打开设置窗口时回调：丢弃未保存编辑、回读真实状态
    /// （窗口是保活复用的，不做这一步上次没保存的勾选会一直留在框里）
    public let refresh: (() -> Void)?
    /// **钉住不滚**（2026-09-13 用户：「该容器和标题不参与页面滚动」）：
    /// 该段连同它的标题被放进页面顶部那块「只吃自身内容高度」的 Form 里，页面滚动只发生在
    /// 它下面的段上。⚠️ 同一个 pane 里 pinned 段必须排在前面（顺序即上屏顺序）
    public let pinned: Bool

    public init(header: String? = nil, view: @escaping () -> NSView, height: CGFloat? = nil,
                footnote: String, actionTitle: String? = nil,
                action: (() -> Void)? = nil, refresh: (() -> Void)? = nil,
                pinned: Bool = false) {
        self.header = header
        self.view = view
        self.height = height
        self.footnote = footnote
        self.actionTitle = actionTitle
        self.action = action
        self.refresh = refresh
        self.pinned = pinned
    }
}

@MainActor
@Observable
public final class AppSettingsModel {
    /// 当前 pane（默认 = 侧栏第一项「主题外观」，2026-09-13 用户要求打开即落第一项）。
    /// **直接赋值就会记进导航历史** —— 侧栏 List 的选择绑定（`$model.selection`）、
    /// 宿主的 `open(pane:)`、预览三处都走这一条路径，不会出现「绕开记录函数直接写」把前进分支写坏。
    public var selection: SettingsSidebarItem = .appearance {
        didSet {
            guard !isRestoringHistory, selection != oldValue else { return }
            // 离开「账号」= Key/额度表单一次编辑结束 → 未保存草稿就地落盘（2026-09-13
            // 起 Key/额度并入账号 pane，原独立 keyQuota pane 删除；提交时机：
            // 回车 / 离开账号 pane / 关窗）
            if oldValue == .accounts { commitKeyQuotaIfDirty() }
            history.removeSubrange((historyIndex + 1)...)
            history.append(selection)
            historyIndex += 1
        }
    }
    public var snapshot = AppSettingsSnapshot()
    public var actions = AppSettingsActions()
    /// 宿主提供的真实状态回读（nil = 预览静态值）
    public var snapshotProvider: (() -> AppSettingsSnapshot)?
    /// 平台品牌图标解析（宿主注入：键 → 品牌 PNG，App 侧固定取 dark 版）；
    /// nil 或缺图时行视图回退通用 SF Symbol（预览环境即走回退）
    public var iconProvider: ((String) -> NSImage?)?
    /// 内嵌 AppKit 内容的 pane（3D 硬币 / 平台开关）；缺项 = 预览 → 回退单动作行。
    /// **数组 = 该 pane 的若干段**，每段一个 Form Section（各画各的卡片）——
    /// 「3D 硬币」用它把预览框与表单框拆成两块（2026-09-13 用户：预览框不要包裹下方 forms），
    /// 单段 pane 就给一个元素的数组。顺序即上屏顺序。
    /// 「主题外观」是原生 SwiftUI `ThemePane`，不走这里
    public var hostedPanes: [SettingsSidebarItem: [SettingsHostedContent]] = [:]
    /// Key/额度表单的编辑草稿（窗口打开时按真实配置重置，见 `beginSession`）
    public var keyQuotaDraft = KeyQuotaDraft()

    /// pane 导航历史（系统设置同款后退/前进）；初始 = [初始 pane]，两侧按钮初始均禁用
    private var history: [SettingsSidebarItem] = [.appearance]
    private var historyIndex = 0
    /// 后退/前进期间抑制历史记录：这两个动作只是「在已有历史里移动」，不是新的一次导航
    private var isRestoringHistory = false

    public var canNavigateBack: Bool { historyIndex > 0 }
    public var canNavigateForward: Bool { historyIndex < history.count - 1 }

    public func navigateBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        isRestoringHistory = true
        selection = history[historyIndex]
        isRestoringHistory = false
    }

    public func navigateForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        isRestoringHistory = true
        selection = history[historyIndex]
        isRestoringHistory = false
    }

    public init() {}

    public func sync() {
        if let snapshotProvider { snapshot = snapshotProvider() }
    }

    /// 窗口每次打开时：回读真实状态 + 用真实配置重置 Key/额度草稿与各内嵌内容。
    /// 窗口是保活复用的（关闭只收起、视图不重建），不做这一步的话上次没保存的草稿/勾选会一直留在框里。
    public func beginSession() {
        sync()
        resetKeyQuotaDraft()
        for sections in hostedPanes.values {
            for content in sections { content.refresh?() }
        }
    }

    // 设置项写路径：先交宿主动作、再回读真实状态（翻转式实现下回读是唯一事实源）
    public func setRefreshInterval(_ seconds: Int) {
        actions.setRefreshInterval(seconds)
        sync()
    }
    /// 删除单个已保存账号（宿主：二次确认 + 落盘 + 刷新面板/菜单栏），随后回读快照刷新列表
    public func deleteAccount(platform: String, uid: String) {
        actions.deleteAccount(platform, uid)
        sync()
    }
    public func setAutoCheckin(_ on: Bool) {
        actions.toggleAutoCheckin(on)
        sync()
    }
    public func setAutoUpdateCheck(_ on: Bool) {
        actions.toggleAutoUpdateCheck(on)
        sync()
    }
    /// 小球弹跳参数：滑杆逐次拖动都会走这里（实时生效 + 落盘），再回读一次
    public func setBounce(_ s: MenuBarBounceSettings) {
        actions.setBounce(s)
        sync()
    }

    // ── 「主题外观」pane：开关 + 滑杆，全部即时生效（改完 sync() 回读真实配置）──

    /// 「高对比背景」强度（0…1，滑杆实时拖动）：动作转交宿主，随后回读快照
    public func setPanelMaskOpacity(_ opacity: Double) {
        actions.setPanelMaskOpacity(opacity)
        sync()
    }
    public func setLightTheme(_ on: Bool) {
        actions.setLightTheme(on)
        sync()
    }
    public func setIconThemeSwap(_ on: Bool) {
        actions.setIconThemeSwap(on)
        sync()
    }
    public func setCircularIcon(_ on: Bool) {
        actions.setCircularIcon(on)
        sync()
    }
    public func setCardTitleFontSize(_ size: Double) {
        actions.setCardTitleFontSize(size)
        sync()
    }
    public func setCardTitleSharpGrotesk(_ on: Bool) {
        actions.setCardTitleSharpGrotesk(on)
        sync()
    }
    public func setCardTitleSGWeight(_ idx: Int) {
        actions.setCardTitleSGWeight(idx)
        sync()
    }
    public func setCardTitleSGWidth(_ idx: Int) {
        actions.setCardTitleSGWidth(idx)
        sync()
    }
    public func setLongProgressCard(_ on: Bool) {
        actions.setLongProgressCard(on)
        sync()
    }
    public func setHeatHue(_ hue: Double) {
        actions.setHeatHue(hue)
        sync()
    }
    public func setHeatSaturation(_ saturation: Double) {
        actions.setHeatSaturation(saturation)
        sync()
    }
    public func setHeatBrightness(_ brightness: Double) {
        actions.setHeatBrightness(brightness)
        sync()
    }
    /// 草稿是否有未落盘的改动（提交点的守卫：脏才写，避免空提交反复刷网络）
    public var keyQuotaDirty: Bool {
        let d = keyQuotaDraft, s = snapshot
        return trimCredential(d.apiKey) != s.apiKey
            || d.quota != s.commonQuota
            || trimCredential(d.zhipuToken) != s.zhipuToken
            || trimCredential(d.qwenTicket) != s.qwenTicket
    }

    /// 放弃草稿、回到真实配置
    public func resetKeyQuotaDraft() {
        keyQuotaDraft = KeyQuotaDraft.from(apiKey: snapshot.apiKey,
                                           quota: snapshot.commonQuota,
                                           zhipuToken: snapshot.zhipuToken,
                                           qwenTicket: snapshot.qwenTicket)
    }

    /// 「编辑结束即落盘」的统一入口（该 pane 已无「保存」按钮）：
    /// 回车 / 离开 pane / 关窗三处都调它，脏才写。
    /// 不做逐键落盘 —— 凭据落盘走钥匙串且宿主会立刻触发一次刷新，逐键代价太高；
    /// 也不在改额度档位时提交 —— 选「自定义」的瞬间手填框还是空的，会把额度先写成 0。
    public func commitKeyQuotaIfDirty() {
        guard keyQuotaDirty else { return }
        saveKeyQuotaDraft()
    }

    /// Key/额度保存：先落盘（凭据走钥匙串）再回读，随后按真实值重置草稿
    /// （顺带把「 10 」这类手输归一）
    public func saveKeyQuotaDraft() {
        let d = keyQuotaDraft
        actions.saveKeyQuota(trimCredential(d.apiKey), d.quota,
                             trimCredential(d.zhipuToken), trimCredential(d.qwenTicket))
        sync()
        resetKeyQuotaDraft()
    }
}

/// 凭据/额度手输的首尾空白（粘贴 token 常带换行；判定脏值与落盘前都要统一口径）
private func trimCredential(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

extension AppSettingsModel {
    /// 预览静态模型（仅模块内预览使用）
    @MainActor
    static func preview(selection: SettingsSidebarItem = .appearance) -> AppSettingsModel {
        let m = AppSettingsModel()
        m.selection = selection
        m.snapshot = AppSettingsSnapshot(
            refreshInterval: 180, autoCheckin: true,
            autoCheckinSub: "9-12 3成功 1失败", autoUpdateCheck: true,
            apiKey: "sk-preview-key", commonQuota: 20,
            panelMaskOpacity: 1, lightThemeEnabled: false,
            iconThemeSwap: true,
            longProgressCard: true,
            heatHue: 0.25, heatSaturation: 0.6, heatBrightness: 0.996)
        m.resetKeyQuotaDraft()   // 「Key / 额度」pane 的草稿也要有值，否则预览是空框
        return m
    }
}

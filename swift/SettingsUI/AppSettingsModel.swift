// SettingsUI — SwiftUI 设置窗口（系统设置式：左侧 sidebar + 右侧 grouped forms）。
// 独立库 target：可执行 target 不支持 Xcode Previews，纯视图 + 模型放这里；
// 宿主（iBalance 可执行目标）只负责装配动作闭包与状态快照，本 target 不依赖任何 App 类型。
// ⚠️ 跨 target 类型一律 public（internal 默认可见性对宿主不可见）。

import AppKit
import CoreImage
import SwiftUI

/// 点阵主题色的**取值域与解算**（HSB → RGB 的唯一实现）。2026-09-14 由设置窗口三根滑杆
/// 改制成系统色盘时上提到这里：宿主 `Palette.heatPeakRGB`（点阵档位色 / 卡片边框 / 热力图印章）
/// 与设置窗口色盘色块共用同一份 —— 与 `MenuBarBounceSettings.solve` 同一条
/// 「两边各写一份迟早漂移」的共存铁律。
public enum PanelThemeColor {
    /// 标准 HSV → RGB（各分量 0…1）。色相/饱和度/明度调整后推导峰值色的唯一实现
    public static func rgb(hue: CGFloat, saturation: CGFloat, brightness: CGFloat)
        -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let h = hue * 6, s = saturation, v = brightness
        let i = Int(floor(h)), f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch ((i % 6) + 6) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// 标准 RGB → HSV（各分量 0…1），`rgb` 的反解 —— 只用于「明度取反」这类
    /// 需要在 HSB 域上做单参运算的场合（`PanelBackgroundColor.brightnessFlipped`）。
    /// 灰阶（delta = 0）时色相无定义，返回 hue = 0（此时色相对结果无影响）
    public static func hsb(red: CGFloat, green: CGFloat, blue: CGFloat)
        -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let maxV = max(red, green, blue), minV = min(red, green, blue)
        let delta = maxV - minV
        let brightness = maxV
        let saturation = maxV == 0 ? 0 : delta / maxV
        var hue: CGFloat = 0
        if delta > 0 {
            if maxV == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, saturation, brightness)
    }
}

/// 面板「面板背景色」：主面板底色遮罩的颜色。
/// 宿主（`Palette.containerColors` / `TintOverlayView`）与设置窗口色盘**共用同一份取值域**
/// —— 与 `MenuBarBounceSettings` 同一条「两边各写一份迟早漂移」的共存铁律。
///
/// 2026-09-14 由「高对比背景」强度滑杆改制：原滑杆只等比缩放固定黑/白遮罩的 alpha，
/// 现在整条遮罩就是这个颜色本身，alpha 由系统色盘直接给（= 原「强度」语义）。
///
/// ⚠️ **存储以 HSB 为准，RGB 只是派生渲染值**（`red/green/blue` 是计算属性）。
/// 原因见 `brightnessFlipped`：若按 RGB 存储，「浅色主题」开关的明度翻转会在
/// 翻转结果落到灰阶（V=1 → 纯黑、V=0 → 纯白）时**永久丢掉色相与饱和度**。
/// 与点阵「主题色」的存储口径一致（那边也是 HSB 三参分开存）。
/// 落盘格式 `hsv:H,S,V,A`（见 `configValue`，config.json 可手改；旧 `#RRGGBBAA` 仍可读）。
public struct PanelBackgroundColor: Equatable {
    /// 色相 / 饱和度 / 明度 / 不透明度（各 0…1）—— 存储真值，渲染用的 RGB 由前三者合成
    public var hue: Double
    public var saturation: Double
    public var brightness: Double
    public var alpha: Double

    /// 默认 = 原「高对比背景 100%」的顶部色（近黑 @70%）：老配置迁移到新键时观感不变
    public static let `default` = PanelBackgroundColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 0.70)

    /// 点阵**背景色**默认（= 无用量底点 / 进度条轨道底 / 骨架行；2026-09-15 起设置窗口可改）：
    /// 深灰 #292929，与旧内置值同源。浅色主题开关会把明度翻转（翻到 ≈ #d6d6d6）
    public static let heatDotEmptyDefault = PanelBackgroundColor(red: 0x29 / 255.0, green: 0x29 / 255.0,
                                                                 blue: 0x29 / 255.0, alpha: 1)
    /// 卡片 **hover 背景色**默认（= `HoverMaterialHost` 材质块底色；2026-09-15 起设置窗口可改）：
    /// 黑 @30%，与旧内置值同源（浅色主题开关 → 白 @30%）
    public static let cardHoverDefault = PanelBackgroundColor(red: 0, green: 0, blue: 0, alpha: 0.30)

    /// 遮罩**底端**不透明度的默认值（0…1）：= 默认色自身的 alpha（两端同值 ⇒ 纯色遮罩）。
    /// 2026-09-14 起上下两端各自独立（`panel_background_bottom_alpha`），此值只作各处属性的初值；
    /// 旧配置的迁移值见 `Config` 解码（取与顶端同值）
    public static let defaultBottomAlpha: Double = 0.70

    /// 遮罩是否生效（alpha ≤ 1% 视为关 → 露出容器原生毛玻璃）
    public var isEffective: Bool { alpha > 0.01 }

    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double) {
        // 四参一律量化到 1e-6（同时夹进 0…1）：与落盘串（`configValue` 的 `%.6f`）精度一致，
        // 保证「落盘 → 读回」与「翻转 → 翻回」都是**逐位无损**的 ——
        // 否则 `1 - (1 - 0.02)` 会得到 0.020000000000000018，来回切换会攒出假不等。
        // 1e-6 的色相 ≈ 0.00036°，远在肉眼分辨之下
        self.hue = Self.quantized(hue)
        self.saturation = Self.quantized(saturation)
        self.brightness = Self.quantized(brightness)
        self.alpha = Self.quantized(alpha)
    }

    /// 量化到 1e-6 并夹进 0…1（落盘/翻转的无损基准）
    private static func quantized(_ v: Double) -> Double {
        (min(max(v, 0), 1) * 1_000_000).rounded() / 1_000_000
    }

    /// RGB 构造（各 0…1）：分解成 HSB 落值 —— 灰阶（delta = 0）时色相无定义，取 0
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        let hsb = PanelThemeColor.hsb(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue))
        self.init(hue: Double(hsb.hue), saturation: Double(hsb.saturation),
                  brightness: Double(hsb.brightness), alpha: alpha)
    }

    /// HSB → sRGB 派生渲染值（各 0…1）。只在下游取色/落 hex 时现算，不做缓存
    private var rgb: (red: Double, green: Double, blue: Double) {
        let c = PanelThemeColor.rgb(hue: CGFloat(hue), saturation: CGFloat(saturation),
                                    brightness: CGFloat(brightness))
        return (Double(c.red), Double(c.green), Double(c.blue))
    }
    public var red: Double { rgb.red }
    public var green: Double { rgb.green }
    public var blue: Double { rgb.blue }

    /// 从 AppKit 颜色取分量：统一转 sRGB 再读，避免 calibrated / device 空间下
    /// 分量不可比（同一视觉色在两空间里的数值不同，等值比较会假不等）
    public init(nsColor: NSColor) {
        guard let c = nsColor.usingColorSpace(.sRGB) else {
            self = .default
            return
        }
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent),
                  blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// SwiftUI 色盘口径（sRGB 直通：走 `Color(nsColor:)` 会按显示 P3 解释，选中值会被挪位）
    public var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    public init(swiftUIColor: Color) {
        self.init(nsColor: NSColor(swiftUIColor))
    }

    /// 当前渲染色的 `#RRGGBBAA`（仅供日志/GradProbe 探针可读，**不再是落盘格式**）
    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
    }

    /// 亮度翻转（「浅色主题」开关联动用）：**只把明度 V 取反**，色相 / 饱和度 / 不透明度原样保留。
    ///
    /// 为什么不直接 RGB 逐通道取反：那会连色相一起翻（深蓝 → 米黄），浅色底会跑成另一种颜色；
    /// 取明度才是用户说的「翻转亮度」——近黑底（V=0.02）↔ 近白底（V=0.98），
    /// 自选的深蓝底（V=0.16）↔ 同色相浅蓝底（V=0.84），语义稳定且可逆。
    /// 灰阶（饱和度 0）下与 RGB 取反等价，所以默认近黑底翻转后就是纯灰白。
    ///
    /// 2026-09-14 修（用户报「开关浅色主题时色相和饱和度被重置」）：
    /// 原实现是 RGB → HSB → 翻 V → RGB 往返，当翻转结果落到灰阶时——
    /// V=1 的浅色翻成 **V=0 纯黑**、V=0 的黑翻成纯白——`PanelThemeColor.hsb` 对灰阶
    /// （delta = 0）返回 hue=0 / saturation=0，**色相与饱和度被永久抹掉**，
    /// 再翻一次就只剩灰白。现在颜色本身就以 HSB 存储，翻转只改 `brightness` 一个字段，
    /// 色相/饱和度根本不参与运算：既不丢也不漂，来回切换精确可逆。
    public var brightnessFlipped: PanelBackgroundColor {
        PanelBackgroundColor(hue: hue, saturation: saturation,
                             brightness: 1 - brightness, alpha: alpha)
    }

    /// 换不透明度、保留色相/饱和度/明度：「顶部不透明度」滑杆与系统色盘共用同一落值入口
    /// （两者都写同一个 `alpha` 字段，滑杆拖动即等价于色盘里改不透明度）
    public func withAlpha(_ a: Double) -> PanelBackgroundColor {
        PanelBackgroundColor(hue: hue, saturation: saturation, brightness: brightness, alpha: a)
    }

    /// config 落盘格式 `hsv:H,S,V,A`（四参各 0…1，6 位小数 = 结构体的量化精度，故逐位无损；
    /// 人可读、可手改）。存 HSB 而非 `#RRGGBBAA` 的原因见 `brightnessFlipped`
    public var configValue: String {
        String(format: "hsv:%.6f,%.6f,%.6f,%.6f", hue, saturation, brightness, alpha)
    }

    /// 解析 `hsv:H,S,V,A`；兼容旧落盘格式 `#RRGGBBAA`（分解成 HSB，一次性迁移）。非法输入返回 nil
    public init?(configValue: String) {
        let s = configValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("hsv:") else {
            self.init(hex: s)   // 旧格式兜底
            return
        }
        let parts = s.dropFirst(4).split(separator: ",").map { Double($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        func unit(_ v: Double) -> Double { min(max(v, 0), 1) }
        self.init(hue: unit(parts[0]!), saturation: unit(parts[1]!),
                  brightness: unit(parts[2]!), alpha: unit(parts[3]!))
    }

    /// 解析 `#RRGGBBAA` / `RRGGBBAA`；`#RRGGBB`（6 位）按不透明处理。非法输入返回 nil
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(red: Double((v >> 16) & 0xFF) / 255,
                      green: Double((v >> 8) & 0xFF) / 255,
                      blue: Double(v & 0xFF) / 255, alpha: 1)
        } else {
            self.init(red: Double((v >> 24) & 0xFF) / 255,
                      green: Double((v >> 16) & 0xFF) / 255,
                      blue: Double((v >> 8) & 0xFF) / 255,
                      alpha: Double(v & 0xFF) / 255)
        }
    }
}

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
    /// 面板底色遮罩色（2026-09-14 由「高对比背景」强度滑杆改制：颜色 + alpha 由色盘给）
    public var panelBackgroundColor: PanelBackgroundColor = .default
    /// 遮罩**底端**不透明度（0…1；顶端 = panelBackgroundColor 的 alpha，两端各自独立，
    /// 取代原「alpha × 0.65」自动递减）
    public var panelBackgroundBottomAlpha: Double = PanelBackgroundColor.defaultBottomAlpha
    /// 浅色主题开关（强制浅色外观，即使系统是深色主题）
    public var lightThemeEnabled = false
    /// 品牌 icon 深浅版互换
    public var iconThemeSwap = false
    /// 长进度卡片（整行进度条 + 副标题下移）
    public var longProgressCard = false
    /// 卡片主标题字号（pt，10…16、步进 0.5）
    public var cardTitleFontSize: Double = 13
    /// 卡片主标题 Sharp Grotesk（本机安装的商业字体；未装该字重回落系统字体）
    public var cardTitleSharpGrotesk = false
    /// 主标题↔副标题行距的字体系数（× `PanelLayout.titleRowBaseGap`，0.2…2.0）：
    /// 主标题去掉硬行框后按字体疏密补偿，SG 更扁 → 单独一档
    public var cardTitleGapScaleSF: Double = 1.0
    public var cardTitleGapScaleSG: Double = 0.7
    /// 点阵主题色（HSB 三参 0…1）：设置窗口「面板 → 主题色」系统色盘拾色后分解落值
    /// （下游点阵档位色与卡片边框仍按 HSB 口径取值）
    public var heatHue: Double = 0
    /// 点阵主题饱和度（0…1）
    public var heatSaturation: Double = 0
    /// 点阵主题峰值明度（0…1）
    public var heatBrightness: Double = 0
    /// 点阵**背景色**（无用量底点 / 进度条轨道底 / 骨架行；2026-09-15 用户要求开放）
    public var heatDotEmptyColor: PanelBackgroundColor = .heatDotEmptyDefault
    /// 卡片 **hover 背景色**（HoverMaterialHost 材质块底色；2026-09-15 用户要求开放）
    public var cardHoverBackgroundColor: PanelBackgroundColor = .cardHoverDefault
    /// DeepSeek API Key（真实值来自钥匙串；空 = 未配置）
    public var apiKey: String = ""
    /// DeepSeek 常用充值额度（0 = 未设置 → 面板不画点阵；>0 = 点阵分母）
    public var commonQuota: Double = 0
    /// ZhiPu Token 手填覆盖（空 = 自动读浏览器登录态）
    public var zhipuToken: String = ""
    /// Qwen Ticket 手填覆盖（空 = 自动读浏览器登录态）
    public var qwenTicket: String = ""
    /// 「已保存账号」列表（2026-09-13 用户要求）：逐平台分组，空平台不出现；全空 = 空数组
    public var savedAccountGroups: [SavedAccountGroup] = []

    public init(refreshInterval: Int = 300, autoCheckin: Bool = false,
                autoCheckinSub: String = "", autoUpdateCheck: Bool = false,
                bounce: MenuBarBounceSettings = .initial,
                apiKey: String = "", commonQuota: Double = 0,
                zhipuToken: String = "", qwenTicket: String = "",
                savedAccountGroups: [SavedAccountGroup] = [],
                panelBackgroundColor: PanelBackgroundColor = .default,
                panelBackgroundBottomAlpha: Double = PanelBackgroundColor.defaultBottomAlpha,
                lightThemeEnabled: Bool = false,
                iconThemeSwap: Bool = false,
                longProgressCard: Bool = false,
                cardTitleFontSize: Double = 13, cardTitleSharpGrotesk: Bool = false,
                cardTitleGapScaleSF: Double = 1.0, cardTitleGapScaleSG: Double = 0.7,
                heatHue: Double = 0, heatSaturation: Double = 0, heatBrightness: Double = 0,
                heatDotEmptyColor: PanelBackgroundColor = .heatDotEmptyDefault,
                cardHoverBackgroundColor: PanelBackgroundColor = .cardHoverDefault) {
        self.refreshInterval = refreshInterval
        self.autoCheckin = autoCheckin
        self.autoCheckinSub = autoCheckinSub
        self.autoUpdateCheck = autoUpdateCheck
        self.bounce = bounce
        self.apiKey = apiKey
        self.commonQuota = commonQuota
        self.zhipuToken = zhipuToken
        self.qwenTicket = qwenTicket
        self.savedAccountGroups = savedAccountGroups
        self.panelBackgroundColor = panelBackgroundColor
        self.panelBackgroundBottomAlpha = panelBackgroundBottomAlpha
        self.lightThemeEnabled = lightThemeEnabled
        self.iconThemeSwap = iconThemeSwap
        self.longProgressCard = longProgressCard
        self.cardTitleFontSize = cardTitleFontSize
        self.cardTitleSharpGrotesk = cardTitleSharpGrotesk
        self.cardTitleGapScaleSF = cardTitleGapScaleSF
        self.cardTitleGapScaleSG = cardTitleGapScaleSG
        self.heatHue = heatHue
        self.heatSaturation = heatSaturation
        self.heatBrightness = heatBrightness
        self.heatDotEmptyColor = heatDotEmptyColor
        self.cardHoverBackgroundColor = cardHoverBackgroundColor
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
    /// 「已保存账号」列表的逐个删除（2026-09-13 用户要求）：platform = 平台键
    /// （workbuddy / trae / zcode / codex），uid = 账号 uid。二次确认由宿主负责（破坏性操作）
    public var deleteAccount: (String, String) -> Void = { _, _ in }
    /// ── 「主题外观」pane：外观开关（传期望值，宿主比对当前配置后再落盘）+ 底色色盘 ──
    /// 面板「面板背景色」（宿主：落盘 + 快照同步重绘遮罩）
    public var setPanelBackgroundColor: (PanelBackgroundColor) -> Void = { _ in }
    /// 面板底色遮罩**底端**不透明度（宿主：落盘 + 同步镜像 + 重绘遮罩）
    public var setPanelBackgroundBottomAlpha: (Double) -> Void = { _ in }
    public var setLightTheme: (Bool) -> Void = { _ in }
    public var setIconThemeSwap: (Bool) -> Void = { _ in }
    public var setLongProgressCard: (Bool) -> Void = { _ in }
    /// 「主题外观」pane 点阵主题色（HSB 三参 0…1，**一把写**；2026-09-14 由三根滑杆改为
    /// 系统色盘拾色 —— 色盘给的是一个颜色，分解回 HSB 后一次落值、只重绘一次）。
    /// 宿主：落 UserDefaults + 就地重绘点阵与卡片边框
    public var setHeatColor: (Double, Double, Double) -> Void = { _, _, _ in }
    /// 点阵背景色 / 卡片 hover 背景色（2026-09-15 开放；宿主：写 config + 落盘 + 镜像 + 就地重绘）
    public var setHeatDotEmptyColor: (PanelBackgroundColor) -> Void = { _ in }
    public var setCardHoverBackgroundColor: (PanelBackgroundColor) -> Void = { _ in }
    public var manualCheckin: () -> Void = {}
    public var showCheckinHistory: () -> Void = {}
    public var shareWbHistory: () -> Void = {}
    /// 菜单栏小球弹跳参数变更（宿主：写内存 + 落盘 + 推给 MenuBarStatusGlowController）
    public var setBounce: (MenuBarBounceSettings) -> Void = { _ in }
    /// 卡片主标题字号 / Sharp Grotesk 开关与字重×宽度档（「主题外观 → 卡片」；
    /// 宿主：写 config + 落盘 + syncPanel，面板快照比对变化后就地重刷标题）
    public var setCardTitleFontSize: (Double) -> Void = { _ in }
    public var setCardTitleSharpGrotesk: (Bool) -> Void = { _ in }
    /// 主副标题行距系数（系统字体 / SG 两档）：宿主写 config + 落盘 + syncPanel，
    /// 面板比对到变化后**就地改间距**（不重建卡片）
    public var setCardTitleGapScaleSF: (Double) -> Void = { _ in }
    public var setCardTitleGapScaleSG: (Double) -> Void = { _ in }
    public var about: () -> Void = {}
    /// 「关于」pane 备份（BackupService）：导出 = config 全量（含凭据）+ UserDefaults 域 → JSON；
    /// 导入 = 覆盖写回并重启（确认弹窗与破坏性提示都在宿主侧）
    public var exportBackup: () -> Void = {}
    public var importBackup: () -> Void = {}

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

    // ── 「主题外观」pane：开关 + 色盘，全部即时生效（改完 sync() 回读真实配置）──

    /// 面板「面板背景色」（色盘逐次拾色都会走这里）：动作转交宿主，随后回读快照
    public func setPanelBackgroundColor(_ color: PanelBackgroundColor) {
        actions.setPanelBackgroundColor(color)
        sync()
    }
    /// 遮罩底端不透明度滑杆（顶端走上面那个色盘 / 顶部滑杆）
    public func setPanelBackgroundBottomAlpha(_ v: Double) {
        actions.setPanelBackgroundBottomAlpha(v)
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
    public func setCardTitleFontSize(_ size: Double) {
        actions.setCardTitleFontSize(size)
        sync()
    }
    public func setCardTitleSharpGrotesk(_ on: Bool) {
        actions.setCardTitleSharpGrotesk(on)
        sync()
    }
    public func setCardTitleGapScaleSF(_ v: Double) {
        actions.setCardTitleGapScaleSF(v)
        sync()
    }
    public func setCardTitleGapScaleSG(_ v: Double) {
        actions.setCardTitleGapScaleSG(v)
        sync()
    }
    public func setLongProgressCard(_ on: Bool) {
        actions.setLongProgressCard(on)
        sync()
    }
    /// 主题色拾取（色盘）：先交宿主动作（落 UserDefaults + 就地重绘），随后回读快照
    public func setThemeColor(hue: Double, saturation: Double, brightness: Double) {
        actions.setHeatColor(hue, saturation, brightness)
        sync()
    }
    /// 点阵背景色拾取（色盘，2026-09-15）：宿主落盘 + 镜像 + 清烘焙缓存就地重绘，随后回读快照
    public func setHeatDotEmptyColor(_ color: PanelBackgroundColor) {
        actions.setHeatDotEmptyColor(color)
        sync()
    }
    /// 卡片 hover 背景色拾取（色盘，2026-09-15）：宿主落盘 + 镜像 + 逐材质宿主重解算，随后回读快照
    public func setCardHoverBackgroundColor(_ color: PanelBackgroundColor) {
        actions.setCardHoverBackgroundColor(color)
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
            panelBackgroundColor: .default, lightThemeEnabled: false,
            iconThemeSwap: true,
            longProgressCard: true,
            heatHue: 0.25, heatSaturation: 0.6, heatBrightness: 0.996)
        m.resetKeyQuotaDraft()   // 「Key / 额度」pane 的草稿也要有值，否则预览是空框
        return m
    }
}

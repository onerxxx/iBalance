// SoftBlur.swift — 自绘模糊 / 软边位图（替代 CoreImage 的公共底座）
//
// ⚠️ 本文件存在的理由：CoreImage 的 Metal 着色器库一旦被加载就**常驻进程、无 API 卸载**
//（图层滤镜一套 ~179 MB、`CIContext` 一套 ~154 MB，取证见 TRAPS「内存占用归因」）⇒
// 工程里所有「高斯模糊 / 柔化边缘」一律自绘，不再 import CoreImage。
//
// σ 口径（两处都是实测定标过的，别随手改）：
// - `CIGaussianBlur` 的 `inputRadius` **就是 σ**（单位 = 输入图像的像素）：离线定标里
//   σ=5 与 CI 输出逐像素 maxΔ=4/255，σ=4.5/5.5 都明显更差。
// - **图层滤镜**（`layer.filters`）的半径按**设备像素**算、不随 contentsScale 缩放 ⇒
//   想拿「视觉 pt」得除以 backingScale，用 `sigmaPt(fromCIRadius:scale:)` 换算。
//
// 模糊一律用**三遍盒式**逼近高斯：单遍盒宽 w 的方差 = (w²−1)/12，三遍串联 ⇒ σ² = (w²−1)/4，
// 反解 w = √(4σ²+1)。滑动窗口实现，每像素每通道 O(1)（逐帧路径与整面板烘焙都要靠它）。

import Cocoa

enum SoftBlur {

    /// CI 图层滤镜半径（设备像素）→ 视觉 σ（pt）
    static func sigmaPt(fromCIRadius radius: Double, scale: CGFloat) -> Double {
        radius / Double(max(scale, 1))
    }

    /// 三遍盒式模糊（预乘 RGBA8；`sigmaPx` 单位 = 位图像素）。σ 极小时原样返回。
    static func boxBlur(_ image: CGImage, sigmaPx: Double) -> CGImage? {
        guard sigmaPx > 0.05 else { return image }
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return image }
        var rgb = [UInt8](repeating: 0, count: w * h * 4)
        rgb.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var src = [Float](repeating: 0, count: rgb.count)
        for i in 0..<rgb.count { src[i] = Float(rgb[i]) }
        var dst = [Float](repeating: 0, count: rgb.count)
        // 三遍串联 ⇒ 单遍只需 σ_pass = σ/√3。盒宽取**连续值** W = 2σ（半宽 = W/2 = σ − 0.5）：
        // 单遍方差 W²/12 = σ²/3，三遍正好 σ²。半宽带小数是为了窗口恒**居中**：
        // 偶数整数宽会让窗口偏半个像素，硬边处 alpha 直接错到 ~200/255（离线 harness 实测）。
        let half = sigmaPx - 0.5
        guard half >= 0.5 else { return image }
        for _ in 0..<3 {
            boxPass(src, &dst, w: w, h: h, half: Float(half), horizontal: true)
            swap(&src, &dst)
            boxPass(src, &dst, w: w, h: h, half: Float(half), horizontal: false)
            swap(&src, &dst)
        }
        for i in 0..<rgb.count { rgb[i] = UInt8(max(0, min(255, src[i].rounded()))) }
        return Self.image(from: rgb, width: w, height: h)
    }

    /// 单遍盒式（滑动窗口，边缘复制；横/纵由 `horizontal` 选）。
    /// 窗口 = 全权重 [-m, m] + 两端各 `fr` 权重于 ±(m+1)，总权重 = 2·half+1 ⇒ 恒居中、可带小数半宽
    private static func boxPass(_ src: [Float], _ dst: inout [Float],
                                w: Int, h: Int, half: Float, horizontal: Bool) {
        let m = Int(half)
        let fr = half - Float(m)
        let inv = 1 / (2 * half + 1)
        let lines = horizontal ? h : w
        let len = horizontal ? w : h
        for line in 0..<lines {
            @inline(__always) func base(_ idx: Int) -> Int {
                horizontal ? line * w * 4 + idx * 4 : idx * w * 4 + line * 4
            }
            var sum: Float = 0, sumB: Float = 0, sumG: Float = 0, sumA: Float = 0
            for k in -m...m {
                let b = base(min(max(k, 0), len - 1))
                sum += src[b]; sumB += src[b + 1]
                sumG += src[b + 2]; sumA += src[b + 3]
            }
            for i in 0..<len {
                let lb = base(min(max(i - m - 1, 0), len - 1))
                let rb = base(min(max(i + m + 1, 0), len - 1))
                let ob = base(i)
                dst[ob] = (sum + fr * (src[lb] + src[rb])) * inv
                dst[ob + 1] = (sumB + fr * (src[lb + 1] + src[rb + 1])) * inv
                dst[ob + 2] = (sumG + fr * (src[lb + 2] + src[rb + 2])) * inv
                dst[ob + 3] = (sumA + fr * (src[lb + 3] + src[rb + 3])) * inv
                // 推进全权重窗口：加入 i+1+m、移出 i-m
                let inB = base(min(max(i + 1 + m, 0), len - 1))
                let outB = base(min(max(i - m, 0), len - 1))
                sum += src[inB] - src[outB]
                sumB += src[inB + 1] - src[outB + 1]
                sumG += src[inB + 2] - src[outB + 2]
                sumA += src[inB + 3] - src[outB + 3]
            }
        }
    }

    /// 把**独立** CALayer 渲染成位图。
    /// ⚠️ 形状必须交给 CALayer 自己画：`.continuous`（超椭圆 / squircle）在 CGPath 里没有对应
    /// API，自己拼圆角矩形会退化成圆弧角。层按 bounds 画在 context 原点，位置由 `offset` 平移
    /// 决定（不用 frame.origin/anchorPoint，避免被 CA 的 position 语义带偏）。
    static func render(_ layer: CALayer, scale: CGFloat,
                       canvas: CGSize? = nil, offset: CGPoint = .zero) -> CGImage? {
        let size = canvas ?? layer.bounds.size
        let pw = Int((size.width * scale).rounded(.up))
        let ph = Int((size.height * scale).rounded(.up))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: offset.x, y: offset.y)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// 软边形状一次出图：渲染形状（填色 / 描边 / 圆角 / 曲线全按 CALayer 口径）→ 三遍盒式模糊。
    /// `sigmaPx` 单位 = **位图像素**（= 视觉 pt × scale）。
    ///
    /// ⚠️ 画布四周按 **3σ** 自动外扩，模糊尾巴不被位图边界切掉（不扩的话最外一圈会留一道
    /// 半透明硬边）。贴回 layer 时必须配 `contentsGravity = .center` + `contentsScale = scale`：
    /// 位图按「像素 ÷ contentsScale」的自然尺寸居中绘制，形状正好落回 layer bounds、
    /// 尾巴溢出在外（layer 自身 contents 不受 bounds 裁剪，除非 masksToBounds）。
    static func softShape(size: CGSize, scale: CGFloat,
                          cornerRadius: CGFloat, cornerCurve: CALayerCornerCurve,
                          fill: CGColor?, border: CGColor?, borderWidth: CGFloat,
                          sigmaPx: Double) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let outset = sigmaPx > 0.05 ? CGFloat(ceil(3 * sigmaPx)) / scale : 0
        let shape = CALayer()
        shape.frame = CGRect(origin: .zero, size: size)
        shape.cornerRadius = cornerRadius
        shape.cornerCurve = cornerCurve
        shape.backgroundColor = fill
        shape.borderColor = border
        shape.borderWidth = borderWidth
        let canvas = CGSize(width: size.width + outset * 2, height: size.height + outset * 2)
        guard let raw = render(shape, scale: scale, canvas: canvas, offset: CGPoint(x: outset, y: outset))
        else { return nil }
        return boxBlur(raw, sigmaPx: sigmaPx)
    }

    /// 去饱和（口径对齐 `CIColorControls(saturation: 0)`：Rec.709 亮度，alpha 原样）
    static func desaturated(_ color: CGColor) -> CGColor {
        let comps = color.components ?? [0, 0, 0, 1]
        guard comps.count >= 3 else { return color }
        let luma = 0.2126 * comps[0] + 0.7152 * comps[1] + 0.0722 * comps[2]
        let alpha = comps.count >= 4 ? comps[3] : 1
        return CGColor(colorSpace: color.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                       components: [luma, luma, luma, alpha]) ?? color
    }

    /// 取色器：位图布局统一为 deviceRGB / 预乘 RGBA8 / 紧排
    static func image(from pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 位图尺寸（px）按 pt × scale 取整（与烘焙键同口径，别两处各算一遍）
    static func pixelSize(_ size: CGSize, scale: CGFloat) -> (w: Int, h: Int) {
        (max(0, Int((size.width * scale).rounded(.up))), max(0, Int((size.height * scale).rounded(.up))))
    }
}

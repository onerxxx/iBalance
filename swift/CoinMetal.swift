// CoinMetal.swift — 硬币的 GPU 渲染（CAMetalLayer + 解析式圆柱求交 shader）
//
// 为什么：硬币是工程里**唯一**逐帧 CPU 重绘的路径（姿态一变就重建整张 CG 位图）。
// 实测 ms/帧：40pt 2.71 / 96pt 5.67 / 200pt 11.85（120Hz 屏上 200pt ≈ 1.4 个核）。
// CG 那套每帧要建位图、拼侧壁/盖面路径、逐个渐变填色 —— 这些在 GPU 上都是「一次画一个像素」的事。
//
// 分阶段落地（见 plans/coin-metal.md，每阶段都要过离线对拍才进 App）：
//   Phase 1 ✅ 几何骨架：正交投影 + 解析式圆柱求交 + 分面归属（40 姿态剪影 IoU 最差 0.9975）
//   Phase 2 ✅ 材质 token：盖面 8 层（六停/三停渐变、innerRing 20% 黑、环遮蔽、两道方向性月牙、
//              lowerField 的 CSS `color` 混合）+ 侧壁（交替 ridge 色、逐面板横向高光、色场按面板强度）
//   Phase 3 ⬜ mark（SVG 盖面局部纹理 + logoInverted / markDepth 挤出）
//   Phase 4 ⬜ outline 线稿外观 + 离屏 staticBitmap()
//   Phase 5 ⬜ 切进 Coin3DView（makeBackingLayer）+ 全参数对拍 + CPU 复测
//
// ⚠️ 几何口径必须与 CG 逐位一致：局部系原点 = 币心、x 右、**y 下**（视图翻转）、z 朝观众；
//    正交 ⇒ 屏幕坐标就是 (x, y)、world.z 越大越靠前；旋转取 `CoinFrame.transform`（同源）。
// ⚠️ 混色一律在 **sRGB 数值空间**做（`CoinRGB.mix` 就是普通的线性插值）—— 纹理因此用
//    `bgra8Unorm`（不做 sRGB 转换），与 CG 位图的字节语义一致，才能逐像素对拍。
// ⚠️ shader 现在是运行时编译（`makeLibrary(source:)`，首次约百毫秒）。发版前改成
//    build.sh 里 `xcrun metal` 预编译 + `makeDefaultLibrary`（SwiftPM 不编 .metal）。

import Cocoa
import Metal
import QuartzCore

/// 硬币渲染 uniform（布局与 MSL 里 `CoinUniforms` 必须逐字对齐：float4 16B / float2 8B）。
/// 长度单位一律**像素**（与 `radius` 同尺度）。
struct CoinMetalUniforms {
    // —— Phase 1：几何 ——
    var col0 = SIMD4<Float>(1, 0, 0, 0)   // 局部→世界旋转矩阵的三列
    var col1 = SIMD4<Float>(0, 1, 0, 0)
    var col2 = SIMD4<Float>(0, 0, 1, 0)
    var center = SIMD2<Float>(0, 0)       // 币心（像素坐标，y 向下）
    var radius: Float = 0                 // 币半径
    var halfThickness: Float = 0          // 半厚
    var subsampleStep: Float = 0.25       // 子采样步长
    var debugMode: Float = 0              // 0 = 上色；1 = 分面掩膜（盖=绿、侧壁=红）
    // —— Phase 2：材质 token（盖面五档已按朝向在 CPU 侧混好，与 CG 同口径）——
    var tokenBase = SIMD4<Float>(1, 1, 1, 1)
    var tokenMid = SIMD4<Float>(1, 1, 1, 1)
    var tokenShadow = SIMD4<Float>(0, 0, 0, 1)
    var tokenHighlight = SIMD4<Float>(1, 1, 1, 1)
    var tokenDepth = SIMD4<Float>(1, 1, 1, 1)
    var edgeBase = SIMD4<Float>(1, 1, 1, 1)
    var edgeAccent = SIMD4<Float>(1, 1, 1, 1)
    var fieldColor = SIMD4<Float>(1, 1, 1, 1)
    // —— Phase 2：几何口径（盖面内缩 / 阴影 / 月牙，都乘过 sizeScale）——
    var rimRadius: Float = 0
    var ringRadius: Float = 0
    var surfaceRadius: Float = 0
    var rimShadow: Float = 0
    var rimShadowAlpha: Float = 0.35
    var shadowBlur: Float = 0
    var crescentOffsetX: Float = 0
    var fieldTransparent: Float = 50
    var fieldOpaque: Float = 80
    var edgeShade: Float = 0
    var segments: Float = 24
    var accentEvery: Float = 0            // 0 = 不交替（uniform）；2 = reeded 每 2 块一次
    var smoothEdge: Float = 0             // 1 = smooth 边纹（面板单色，无横向高光）
}

/// mark（logo）的 GPU 参数 —— **独立缓冲**（fragment 的 `buffer(1)`），不跟主 uniform 混。
///
/// ⚠️ 为什么单独一个缓冲：mark 这一组字段是 Phase 3 才加的，当初直接从尾部往
///    `CoinMetalUniforms` 里追加，而 MSL 那份把 `smoothEdge` 留在了 `accentEvery` 后面、
///    Swift 这份把 `smoothEdge` 写在了结构体末尾 ⇒ **两份声明的字段顺序不一致**，
///    整个 mark 块在 shader 侧错位 4 字节（`markEnabled` 恒读到 0 ⇒ mark 对画面零影响）。
///    实测（`/tmp/ibal_unifprobe`，两边结构体都从源码逐字抽出）：
///    Swift `markOffsetX@256 / smoothEdge@288`，MSL 读到的 `smoothEdge` = Swift 的 `markOffsetX`。
///    注意**与对齐无关**：两侧 `stride` 都是 304（那个 292 是 `size`），没有 padding 分歧。
/// ⇒ 现在这组字段全部是 `float4`：Swift `SIMD4<Float>` / MSL `float4` 都是 16B 一槽，
///   无 padding、无对齐分歧，只要**声明顺序一致**就必然对齐（下面 MSL 那份逐字对应）。
/// ⚠️ 改动这个结构体：两边**必须同时改**（下单校验见 `verifyUniformLayout()`，启动时跑一次）。
struct CoinMarkUniforms {
    /// x = 挤出位移 X（像素，未按前后盖取符号）y = 位移 Y
    /// z = 盖面半径（像素，= 覆盖度纹理半宽）w = 是否启用（0/1）
    var params = SIMD4<Float>(0, 0, 0, 0)
    /// x = 侧壁靠顶面一档压暗 y = 靠外缘一档压暗
    /// z = 边界阴影**每遍**的落点 alpha w = 同一轮廓叠画的遍数
    var wall = SIMD4<Float>(0, 0, 0, 0)
}

/// mark（logo）渲染参数：由宿主把 `Coin3DView` 上的 logo 状态摘出来传进来
struct CoinMarkParams {
    var enabled = false
    var depthPt: Double = 0        // markDepth（pt，未乘 sizeScale）
    var shadowAlpha: Double = 0    // 单遍 alpha（0…1）
    var shadowPasses: Int = 2
}

/// 硬币 GPU 渲染器。线程约定：只在主线程调用（与 `Coin3DView` 的绘制路径一致）。
final class CoinMetalRenderer {

    static let shared = CoinMetalRenderer()

    /// 诊断/复测用：累计已提交的渲染帧数（App 侧不读；Phase 5 的 ms/帧复测靠它数帧）。
    private(set) var frameCount = 0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "coinVertex")
            desc.fragmentFunction = library.makeFunction(name: "coinFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            Self.verifyUniformLayout(device: device, queue: queue, library: library)
        } catch {
            Logger.log(.layout, "CoinMetal：管线创建失败 —— \(error.localizedDescription)")
            return nil
        }
    }

    /// 从币的当前参数烘 uniform（几何 + 材质；与 CG 的 `renderCoin` 同源口径）。
    /// - Parameters:
    ///   - pixelScale: 渲染倍率（位图 = 点 × 该值）
    ///   - center: 币心在**位图**里的坐标（像素）
    static func uniforms(frame: CoinFrame, pixelScale: CGFloat, center: CGPoint,
                         size: Double, thickness: Double, material: CoinMaterial,
                         edgeFinish: CoinEdgeFinish, shade: (face: Double, edge: Double),
                         debugMode: Float = 0) -> CoinMetalUniforms {
        var u = CoinMetalUniforms()
        // 旋转矩阵的列 = 局部基向量变换到世界后的坐标（正交下就是屏幕方向）
        let cx = frame.transform(CoinVec(x: 1, y: 0, z: 0))
        let cy = frame.transform(CoinVec(x: 0, y: 1, z: 0))
        let cz = frame.transform(CoinVec(x: 0, y: 0, z: 1))
        u.col0 = SIMD4<Float>(Float(cx.x), Float(cx.y), Float(cx.z), 0)
        u.col1 = SIMD4<Float>(Float(cy.x), Float(cy.y), Float(cy.z), 0)
        u.col2 = SIMD4<Float>(Float(cz.x), Float(cz.y), Float(cz.z), 0)
        u.center = SIMD2<Float>(Float(center.x), Float(center.y))
        u.radius = Float(size / 2 * pixelScale)
        u.halfThickness = Float(thickness / 2 * pixelScale)
        u.debugMode = debugMode

        let scale = size / Double(CoinMetrics.size)      // = Coin3DView.sizeScale（那边是 private）
        let px = Double(pixelScale)
        let half = size / 2
        u.rimRadius = Float((half - CoinMetrics.rimInset * scale) * px)
        u.ringRadius = Float((half - CoinMetrics.innerRingInset * scale) * px)
        u.surfaceRadius = Float((half - CoinMetrics.surfaceInset * scale) * px)
        u.rimShadow = Float(CoinMetrics.surfaceRimShadow * scale * px)
        u.rimShadowAlpha = Float(CoinMetrics.surfaceRimShadowAlpha)
        u.shadowBlur = Float(CoinMetrics.shadowBlur * scale * px)
        // CSS `inset calc(shadow-x × −2) 0`：前盖 −2、后盖 +2（后盖局部 x 是镜像的）
        let offsetX = 2 * 4 * scale * CoinMath.projectedNormal(yaw: frame.rotation,
                                                              pitch: frame.pitch).x
        u.crescentOffsetX = Float(offsetX * px)

        let tokens = material.faceTokens(shade: shade.face)
        func v4(_ c: CoinRGB) -> SIMD4<Float> { SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1) }
        u.tokenBase = v4(tokens.base)
        u.tokenMid = v4(tokens.mid)
        u.tokenShadow = v4(tokens.shadow)
        u.tokenHighlight = v4(tokens.highlight)
        u.tokenDepth = v4(tokens.depth)
        u.edgeBase = v4(material.edgeBase)
        u.edgeAccent = v4(material.edgeAccent)
        u.fieldColor = v4(material.field)
        u.fieldTransparent = Float(material.fieldTransparentAt)
        u.fieldOpaque = Float(material.fieldOpaqueAt)
        u.edgeShade = Float(shade.edge)
        let geometry = CoinGeometry(size: size, thickness: thickness,
                                    transparentAt: material.fieldTransparentAt,
                                    opaqueAt: material.fieldOpaqueAt)
        u.segments = Float(geometry.segments)
        u.accentEvery = Float(edgeFinish.accentEvery)
        u.smoothEdge = edgeFinish == .smooth ? 1 : 0
        return u
    }

    /// mark 参数 → 独立缓冲的 uniform（buffer(1)）。位移 = 投影法线 × markDepth × sizeScale。
    static func markUniforms(frame: CoinFrame, size: Double, pixelScale: CGFloat,
                             mark: CoinMarkParams) -> CoinMarkUniforms {
        var m = CoinMarkUniforms()
        let scale = size / Double(CoinMetrics.size)         // = Coin3DView.sizeScale（那边是 private）
        let px = Double(pixelScale)
        let normal = CoinMath.projectedNormal(yaw: frame.rotation, pitch: frame.pitch)
        let offset = mark.depthPt * scale * px
        m.params = SIMD4<Float>(Float(normal.x * offset), Float(normal.y * offset),
                                Float(size / 2 * px), mark.enabled ? 1 : 0)
        m.wall = SIMD4<Float>(Float(CoinMetrics.markWallShadeTop),
                              Float(CoinMetrics.markWallShadeEdge),
                              Float(mark.shadowAlpha), Float(max(1, mark.shadowPasses)))
        return m
    }

    /// mark 的两张盖面局部覆盖度纹理（r8Unorm）。
    struct CoinMarkTexture {
        let flat: MTLTexture      // 轮廓覆盖度
        let shadow: MTLTexture    // 轮廓的模糊副本（边界阴影）
        let key: String           // 缓存键（logo/尺寸/描边变了要重烘）
    }

    /// 烘焙 mark 覆盖度（盖面局部坐标，覆盖 ±size/2）。与 `drawMark` 同口径：
    /// `total = logoScale × logoExtraScale × sizeScale × contentFit`，art 的 160 盒以中心为原点缩放；
    /// `logoInverted` = 「裁剪圆 − logo」合成一条 even-odd 路径（负形浮雕）。
    static func bakeMarkTextures(art: CoinLogoArt, logoScale: Double, logoExtraScale: Double,
                                 contentFit: Double, size: Double, thickness: Double,
                                 inverted: Bool, pixelScale: CGFloat,
                                 shadowSigmaPt: Double) -> CoinMarkTexture? {
        guard !art.isEmpty else { return nil }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let sizeScale = size / Double(CoinMetrics.size)
        let total = logoScale * logoExtraScale * sizeScale * contentFit
        let half = size / 2
        let px = max(8, Int((half * 2 * Double(pixelScale)).rounded(.up)))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        // 「160 盒 → 位图」一次写成**一个显式矩阵**（绕开 concatenate 的先后语义坑）：
        //   local = total·(art − 80)  [pt, y 向下] → q = pixelScale·local [px] → 上下文 (px/2 + q.x, px/2 − q.y)
        // ⇒ a = s, d = −s（y 翻正）、tx = px/2 − s·80、ty = px/2 + s·80，其中 s = pixelScale × total
        let center = Double(CoinSVG.box) / 2
        let s = Double(pixelScale) * total
        ctx.concatenate(CGAffineTransform(a: CGFloat(s), b: 0, c: 0, d: -CGFloat(s),
                                          tx: CGFloat(Double(px) / 2 - s * center),
                                          ty: CGFloat(Double(px) / 2 + s * center)))
        // 裁剪圆：在 **art 坐标**里画（圆 → 圆：半径 ÷ total，圆心仍在 160 盒中心）
        let clipRadius = CoinMetrics.markClipRadius * sizeScale / total
        ctx.addPath(CGPath(ellipseIn: CGRect(x: center - clipRadius, y: center - clipRadius,
                                             width: clipRadius * 2, height: clipRadius * 2),
                           transform: nil))
        ctx.clip()
        // 填充：路径就是 art 坐标（描边宽度已由 solids(scale:) 乘过 total），交给 CTM 变换
        if inverted {
            let combined = CGMutablePath()
            combined.addPath(CGPath(ellipseIn: CGRect(x: center - clipRadius, y: center - clipRadius,
                                                      width: clipRadius * 2, height: clipRadius * 2),
                                    transform: nil))
            for solid in art.solids(scale: total) { combined.addPath(solid.path) }
            ctx.addPath(combined)
            ctx.fillPath(using: .evenOdd)
        } else {
            for solid in art.solids(scale: total) {
                ctx.addPath(solid.path)
                ctx.fillPath(using: solid.evenOdd ? .evenOdd : .winding)
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        // 读回覆盖度（取 R；上面用白色填充）
        var bytes = [UInt8](repeating: 0, count: px * px * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: px, height: px, bitsPerComponent: 8,
                                    bytesPerRow: px * 4, space: space, bitmapInfo: info) else { return }
            c.setBlendMode(.copy)
            c.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        }
        var gray = [UInt8](repeating: 0, count: px * px)
        for i in 0..<(px * px) { gray[i] = bytes[i * 4] }
        // 阴影：同样大小的模糊副本
        var shadow = gray
        if shadowSigmaPt > 0.05 {
            if let src = Self.image(fromRGBA: gray, px: px),
               let blurred = SoftBlur.boxBlur(src, sigmaPx: shadowSigmaPt * Double(pixelScale)) {
                var buf = [UInt8](repeating: 0, count: px * px * 4)
                buf.withUnsafeMutableBytes { raw in
                    guard let c = CGContext(data: raw.baseAddress, width: px, height: px,
                                            bitsPerComponent: 8, bytesPerRow: px * 4,
                                            space: space, bitmapInfo: info) else { return }
                    c.setBlendMode(.copy)
                    c.draw(blurred, in: CGRect(x: 0, y: 0, width: px, height: px))
                }
                for i in 0..<(px * px) { shadow[i] = buf[i * 4] }
            }
        }
        func texture(_ data: [UInt8]) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: px,
                                                             height: px, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            data.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, px, px), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: px)
            }
            return t
        }
        func note(_ m: String) {
            let line = "[mark] " + m + "\n"
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/coinmark.log")) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else { try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/coinmark.log")) }
        }
        let cover = gray.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
        var x0 = px, x1 = -1, y0 = px, y1 = -1
        for j in 0..<px { for i in 0..<px where gray[j * px + i] > 127 {
            x0 = min(x0, i); x1 = max(x1, i); y0 = min(y0, j); y1 = max(y1, j)
        } }
        note("烘焙 px=\(px) total=\(String(format: "%.3f", total)) 覆盖=\(cover)px 包围盒 x[\(x0),\(x1)] y[\(y0),\(y1)] 裁切圆半径=\(String(format: "%.1f", (CoinMetrics.markClipRadius * sizeScale) * Double(pixelScale)))px")
        guard let flatTex = texture(gray), let shadowTex = texture(shadow) else { note("纹理创建失败"); return nil }
        let key = "mark|\(Int(size * 10))|\(Int(total * 1000))|\(inverted)|\(px)|\(Int(shadowSigmaPt * 100))"
        return CoinMarkTexture(flat: flatTex, shadow: shadowTex, key: key)
    }

    /// 单通道位图 → CGImage（给 SoftBlur 用）
    private static func image(fromRGBA gray: [UInt8], px: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: px * px * 4)
        for i in 0..<(px * px) {
            rgba[i * 4] = gray[i]; rgba[i * 4 + 1] = gray[i]
            rgba[i * 4 + 2] = gray[i]; rgba[i * 4 + 3] = 255
        }
        return SoftBlur.image(from: rgba, width: px, height: px)
    }

    /// 离屏渲染一张硬币（像素尺寸 = 币的包围盒）。Phase 5 的 `staticBitmap()` 也走这条。
    func renderToTexture(pixels: Int, uniforms: CoinMetalUniforms,
                         mark: CoinMarkUniforms = CoinMarkUniforms(),
                         markTexture: CoinMarkTexture? = nil) -> MTLTexture? {
        guard pixels > 0, pixels <= 4096 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: pixels, height: pixels,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared          // Apple Silicon：共享内存，省一次 blit，也方便直接回读
        guard let target = device.makeTexture(descriptor: desc),
              let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pipeline)
        bind(enc, uniforms: uniforms, mark: mark, markTexture: markTexture)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return target
    }

    /// 绑 uniform（buffer 0/1）+ mark 纹理（texture 0/1）到 fragment。
    /// ⚠️ 传 `Size` 而不是 `stride`：stride 含尾部 padding，会让 Metal 读到结构体末尾之外。
    private func bind(_ enc: MTLRenderCommandEncoder, uniforms: CoinMetalUniforms,
                      mark: CoinMarkUniforms, markTexture: CoinMarkTexture?) {
        var u = uniforms
        var m = mark
        withUnsafeBytes(of: &u) { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        withUnsafeBytes(of: &m) { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.setFragmentTexture(markTexture?.flat, index: 0)
        enc.setFragmentTexture(markTexture?.shadow, index: 1)
    }

    /// 渲染到 `CAMetalLayer` 的当前 drawable 并 present（Phase 5 接入 App 用；离线并排对比窗口也走这条）。
    /// 异步提交（不等 GPU），CPU 侧只有 uniform 组装 + 一次 draw call。
    @discardableResult
    func render(into layer: CAMetalLayer, uniforms: CoinMetalUniforms,
                mark: CoinMarkUniforms = CoinMarkUniforms(),
                markTexture: CoinMarkTexture? = nil) -> Bool {
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setRenderPipelineState(pipeline)
        bind(enc, uniforms: uniforms, mark: mark, markTexture: markTexture)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        frameCount += 1
        return true
    }

    /// **一次性**布局自检：CPU 侧写哨兵值 → 绑给 GPU → 让 `probeUniformFields` 按 MSL 的声明读回来。
    /// 为什么留着：mark 那组字段曾因「Swift 与 MSL 两份声明的字段**顺序**不一致」整体错位 4 字节，
    /// 症状是**画面完全正常、只有 mark 不生效**（`markEnabled` 恒读到 0），肉眼几乎查不出来。
    /// 这一跑直接点名错位的字段，代价只有一次 1 线程 dispatch。
    private static func verifyUniformLayout(device: MTLDevice, queue: MTLCommandQueue,
                                           library: MTLLibrary) {
        var u = CoinMetalUniforms()
        u.col2 = SIMD4<Float>(0, 0, 0, 1001)
        u.radius = 1002
        u.tokenBase = SIMD4<Float>(1003, 0, 0, 1)
        u.fieldColor = SIMD4<Float>(0, 1004, 0, 1)
        u.rimRadius = 1005; u.shadowBlur = 1006; u.fieldOpaque = 1007
        u.segments = 1008; u.smoothEdge = 1009
        var m = CoinMarkUniforms()
        m.params = SIMD4<Float>(1010, 0, 1011, 0)
        m.wall = SIMD4<Float>(0, 1012, 0, 1013)
        let names = ["col2.w", "radius", "tokenBase.x", "fieldColor.y", "rimRadius", "shadowBlur",
                     "fieldOpaque", "segments", "smoothEdge", "mark.x(挤出X)", "mark.z(盖面半径)",
                     "mark.y(侧壁外缘)", "mark.w(阴影遍数)"]
        let count = names.count
        guard let fn = library.makeFunction(name: "probeUniformFields"),
              let pso = try? device.makeComputePipelineState(function: fn),
              let src = device.makeBuffer(bytes: &u, length: MemoryLayout.size(ofValue: u),
                                          options: .storageModeShared),
              let srcMark = device.makeBuffer(bytes: &m, length: MemoryLayout.size(ofValue: m),
                                              options: .storageModeShared),
              let dst = device.makeBuffer(length: count * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(srcMark, offset: 0, index: 1)
        enc.setBuffer(dst, offset: 0, index: 2)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let got = dst.contents().bindMemory(to: Float.self, capacity: count)
        var bad: [String] = []
        for i in 0..<count where abs(got[i] - Float(1001 + i)) > 0.5 {
            bad.append("\(names[i]) 期望 \(1001 + i) 读到 \(Int(got[i]))")
        }
        if bad.isEmpty {
            Logger.log(.layout, "CoinMetal：uniform 布局自检通过（\(count) 个字段，mark 走独立缓冲）")
        } else {
            Logger.log(.layout, "CoinMetal：⚠️ uniform 布局错位 —— " + bad.joined(separator: "；")
                        + "（Swift 与 MSL 的声明顺序/类型不一致，改一处必须改另一处）")
        }
    }

    /// **诊断用**：把 uniform 结构体绑给 GPU（与渲染同一条路径），再用一个 kernel 原样拷出来回读 ——
    /// 用来核对「Swift 写进去的字节」与「shader 真正读到的字节」是否一致（对拍时怀疑字段错位就查这个）。
    func debugReadUniformBytes(_ uniforms: CoinMetalUniforms) -> [UInt8]? {
        var u = uniforms
        let count = MemoryLayout<CoinMetalUniforms>.stride
        guard let src = device.makeBuffer(bytes: &u, length: count, options: .storageModeShared),
              let dst = device.makeBuffer(length: count, options: .storageModeShared),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let kernel = library.makeFunction(name: "copyUniforms"),
              let pipeline = try? device.makeComputePipelineState(function: kernel),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        let threads = MTLSize(width: count, height: 1, depth: 1)
        let group = MTLSize(width: min(count, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        enc.dispatchThreads(threads, threadsPerThreadgroup: group)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let raw = dst.contents().bindMemory(to: UInt8.self, capacity: count)
        return Array(UnsafeBufferPointer(start: raw, count: count))
    }

    /// 便利入口：给定币的几何参数，直接渲染到 layer（并排对比窗口 / Phase 5 接入都用这条）。
    ///
    /// **落位口径（唯一一处，别在调用方自己算像素）**：
    /// - `centerInView` = 币心在**视图坐标系**里的位置（pt，y 向下 —— `Coin3DView` 是翻转视图，
    ///   所以那就是 `coinCenter` 本身，不需要翻 y）。内部乘 `contentsScale` 转成像素。
    ///   ⚠️ 别把「离屏位图的像素中心」传进来：位图的 px 与视图的 pt 是**两套坐标系**。
    ///   踩过的样子：并排窗口传 `px/2` = 111，而真实币心是 `(100, 112.1)` ——
    ///   数值接近、语义不同，币就偏到画布一角，三格并排时比例看着完全不对。
    /// - `pixelScale` 也**不接受外部传入**，一律取 `layer.contentsScale`（= 画布的 px / pt）。
    ///   ⚠️ 画布尺寸看 `layer.bounds`，**别看 `drawableSize`**：自建 `CAMetalLayer` 时它是
    ///   **懒推导**的（首次 `nextDrawable()` 之后才有值），首帧读到 0×0 ⇒ 拿它当判据永远画不出来。
    @discardableResult
    func render(into layer: CAMetalLayer, frame: CoinFrame, centerInView: CGPoint,
                size: Double, thickness: Double,
                material: CoinMaterial, edgeFinish: CoinEdgeFinish,
                shade: (face: Double, edge: Double),
                mark: CoinMarkParams = CoinMarkParams(),
                markTexture: CoinMarkTexture? = nil) -> Bool {
        guard layer.bounds.width >= 1, layer.bounds.height >= 1 else { return false }
        let scale = layer.contentsScale
        let u = Self.uniforms(frame: frame, pixelScale: scale,
                              center: CGPoint(x: centerInView.x * scale,
                                              y: centerInView.y * scale),
                              size: size, thickness: thickness, material: material,
                              edgeFinish: edgeFinish, shade: shade)
        let m = Self.markUniforms(frame: frame, size: size, pixelScale: scale, mark: mark)
        return render(into: layer, uniforms: u, mark: m, markTexture: markTexture)
    }

    /// 纹理 → CGImage（对拍与预设图卡用）。bgra8Unorm + 预乘 alpha ⇒ premultipliedFirst + little endian
    static func cgImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: shader（Phase 2：几何 + 材质 token；mark 见 Phase 3）

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CoinUniforms {
        float4 col0; float4 col1; float4 col2;
        float2 center; float radius; float halfThickness;
        float subsampleStep; float debugMode;
        float4 tokenBase; float4 tokenMid; float4 tokenShadow;
        float4 tokenHighlight; float4 tokenDepth;
        float4 edgeBase; float4 edgeAccent; float4 fieldColor;
        float rimRadius; float ringRadius; float surfaceRadius;
        float rimShadow; float rimShadowAlpha; float shadowBlur; float crescentOffsetX;
        float fieldTransparent; float fieldOpaque; float edgeShade;
        float segments; float accentEvery; float smoothEdge;
    };

    // ⚠️ 与 Swift 的 `CoinMarkUniforms` **逐字对应**（buffer(1)）。只放 float4：
    //    两侧 16B 一槽、无 padding、无对齐分歧 —— 当初 mark 字段直接追加在主 uniform 尾部，
    //    两份声明的字段顺序不一致（smoothEdge 一个在前一个在后）⇒ 整块错位 4 字节、
    //    markEnabled 恒读 0、mark 对画面零影响。改这里必须同步改 Swift 那份。
    struct CoinMarkUniforms {
        float4 params;   // x=offsetX(px) y=offsetY(px) z=radius(px) w=enabled
        float4 wall;     // x=wallShadeTop y=wallShadeEdge z=shadowAlpha w=shadowPasses
    };

    kernel void copyUniforms(constant uchar *src [[buffer(0)]],
                             device uchar *dst [[buffer(1)]],
                             uint i [[thread_position_in_grid]]) {
        dst[i] = src[i];
    }

    // 布局自检：按 MSL 的声明把字段读出来（哨兵值由 CPU 写进去）。见 `verifyUniformLayout()`。
    kernel void probeUniformFields(constant CoinUniforms &u [[buffer(0)]],
                                   constant CoinMarkUniforms &mk [[buffer(1)]],
                                   device float *out [[buffer(2)]]) {
        out[0]  = u.col2.w;      out[1]  = u.radius;      out[2]  = u.tokenBase.x;
        out[3]  = u.fieldColor.y; out[4] = u.rimRadius;   out[5]  = u.shadowBlur;
        out[6]  = u.fieldOpaque; out[7]  = u.segments;    out[8]  = u.smoothEdge;
        out[9]  = mk.params.x;   out[10] = mk.params.z;   out[11] = mk.wall.y;
        out[12] = mk.wall.w;
    }

    struct VSOut { float4 pos [[position]]; };

    vertex VSOut coinVertex(uint vid [[vertex_id]]) {
        float2 quad[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        VSOut o;
        o.pos = float4(quad[vid], 0.0, 1.0);
        return o;
    }

    // 单条射线 × 有限圆柱（半径 R、|z| ≤ h）求**最近**命中。
    // ⚠️ 参数化从「屏幕平面」（world.z = 0）起算、方向朝观众的反向 ⇒ t = −world.z，
    // 所以 **t 可以是负的**：币会伸出屏幕平面（正交下屏幕平面直接切过币体）。
    // 判据 = 取**最小的合法 t**，不能要求 t > 0。kind：0 = 侧壁，1 = 后盖，2 = 前盖。
    static float hitCylinder(float3 p0, float3 d, float R, float h,
                             thread int &kind, thread float3 &nrm) {
        float best = INFINITY;
        int bestKind = -1;
        float3 bestN = float3(0.0);
        if (fabs(d.z) > 1e-6) {
            for (int s = 0; s < 2; ++s) {
                float zc = (s == 0) ? -h : h;
                float t = (zc - p0.z) / d.z;
                float2 q = p0.xy + t * d.xy;
                if (dot(q, q) <= R * R && t < best) {
                    best = t; bestKind = 1 + s;
                    bestN = float3(0.0, 0.0, (s == 0) ? -1.0 : 1.0);
                }
            }
        }
        float a = dot(d.xy, d.xy);
        if (a > 1e-9) {
            float b = dot(p0.xy, d.xy);
            float c = dot(p0.xy, p0.xy) - R * R;
            float disc = b * b - a * c;
            if (disc > 0.0) {
                float root = sqrt(disc);
                for (int r = 0; r < 2; ++r) {
                    float t = (-b + ((r == 0) ? -root : root)) / a;
                    float z = p0.z + t * d.z;
                    if (fabs(z) <= h && t < best) {
                        best = t; bestKind = 0;
                        bestN = normalize(float3(p0.xy + t * d.xy, 0.0));
                    }
                }
            }
        }
        kind = bestKind;
        nrm = bestN;
        return (bestKind < 0) ? -1.0 : best;
    }

    // mark 覆盖度纹理采样（r8Unorm；线性插值）
    static float covSample(texture2d<float> tex, float2 uv) {
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { return 0.0; }
        constexpr sampler markSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return tex.sample(markSampler, uv).r;
    }

    // CSS `linear-gradient(θ, …)` 的渐变参数：方向 (sinθ, −cosθ)，线长 = 2·radius·(|sin|+|cos|)
    static float gradT(float2 q, float radius, float angleDeg) {
        float a = angleDeg * M_PI_F / 180.0;
        float2 dir = float2(sin(a), -cos(a));
        float len = 2.0 * radius * (fabs(dir.x) + fabs(dir.y));
        return 0.5 + dot(q, dir) / len;
    }

    static float3 mix6(float t, float3 shadow, float3 base, float3 highlight) {
        // 停：[shadow@0, base@.2, highlight@.4, highlight@.6, base@.8, shadow@1]
        if (t <= 0.2) { return mix(shadow, base, saturate(t / 0.2)); }
        if (t <= 0.4) { return mix(base, highlight, saturate((t - 0.2) / 0.2)); }
        if (t <= 0.6) { return highlight; }
        if (t <= 0.8) { return mix(highlight, base, saturate((t - 0.6) / 0.2)); }
        return mix(base, shadow, saturate((t - 0.8) / 0.2));
    }

    static float3 mix3(float t, float3 hi, float3 base, float3 depth) {
        // 停：[highlight@0, base@.5, depth@1]
        return (t <= 0.5) ? mix(hi, base, saturate(t / 0.5)) : mix(base, depth, saturate((t - 0.5) / 0.5));
    }

    // `color` 混合（PDF 规范口径 = CoreGraphics 的 `CGBlendMode.color`，与 CSS 同族但**不是** HSL）：
    //   结果 = SetLum(SetSat(源, 底的饱和度), 底的亮度)，亮度用 PDF 的 0.3/0.59/0.11 加权
    // ⚠️ 一开始按 CSS 那套 HSL 实现（源 H/S + 底 L 的 HSL 往返），中心以下整片偏色（R/G 压太低）——
    //    实测 CG 用的是 PDF 的 Lum 加权，不是 HSL 的 (max+min)/2。
    static float lumPDF(float3 c) { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b; }

    static float sat(float3 c) {
        return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    }

    static float3 setSat(float3 c, float s) {
        float mn = min(c.r, min(c.g, c.b));
        float mx = max(c.r, max(c.g, c.b));
        if (mx - mn < 1e-6) { return float3(0.0); }
        return (c - mn) * (s / (mx - mn));
    }

    static float3 clipColor(float3 c) {
        float l = lumPDF(c);
        float mn = min(c.r, min(c.g, c.b));
        float mx = max(c.r, max(c.g, c.b));
        if (mn < 0.0) { c = l + (c - l) * (l / max(l - mn, 1e-6)); }
        if (mx > 1.0) { c = l + (c - l) * ((1.0 - l) / max(mx - l, 1e-6)); }
        return c;
    }

    static float3 setLum(float3 c, float l) { return clipColor(c + (l - lumPDF(c))); }

    static float3 blendColor(float3 dst, float3 src, float alpha) {
        if (alpha <= 0.001) { return dst; }
        float3 blended = setLum(setSat(src, sat(dst)), lumPDF(dst));
        return mix(dst, blended, alpha);
    }

    // 盖面 8 层（与 `drawCap` 逐层对齐；第 ⑤ 层 mark 属 Phase 3，这里留空）
    static float3 capColor(float2 p, float r, bool front, constant CoinUniforms &u,
                           constant CoinMarkUniforms &mk,
                           texture2d<float> markFlat, texture2d<float> markShadow) {
        float2 q = front ? p : float2(-p.x, p.y);      // 后盖局部 x 是镜像的
        // ① outer：−60° 六停（后盖靠 q 的 x 镜像表达，角度不变 —— 与 CG 的 capTransform 同口径）
        float3 out1 = mix6(gradT(q, u.radius, -60.0), u.tokenShadow.rgb, u.tokenBase.rgb, u.tokenHighlight.rgb);
        if (r <= u.rimRadius) {                        // ② rim：+60° 六停
            float3 c = mix6(gradT(q, u.rimRadius, 60.0), u.tokenShadow.rgb, u.tokenBase.rgb, u.tokenHighlight.rgb);
            out1 = c;
        }
        if (r <= u.ringRadius) {                       // ③ innerRing：+60° 六停 + 20% 黑
            float3 c = mix6(gradT(q, u.ringRadius, 60.0), u.tokenShadow.rgb, u.tokenBase.rgb, u.tokenHighlight.rgb);
            out1 = mix(c, float3(0.0), 0.2);
        }
        if (r <= u.surfaceRadius) {                    // ④ surface：自上而下 3 停
            out1 = mix3(gradT(q, u.surfaceRadius, 180.0), u.tokenHighlight.rgb, u.tokenBase.rgb, u.tokenDepth.rgb);
        }
        // ⑤ mark（Phase 3）：覆盖度纹理按盖面局部 UV 采样。
        //    合成顺序照 CG 的三遍：① 边界阴影（轮廓外）→ ② 侧壁带（平轮廓有、顶面无）
        //    → ③ 顶面（与盖面逐像素同色 ⇒ 无需改色，只要它**盖住**侧壁/阴影）。
        if (mk.params.w > 0.5) {
            const float2 center = float2(0.5);
            float2 uvFlat = q / (2.0 * mk.params.z) + center;
            float2 off = front ? mk.params.xy : -mk.params.xy;   // 后盖挤出方向相反（CG: front ? 1 : -1）
            float2 uvTop = (q - off) / (2.0 * mk.params.z) + center;
            float2 uvMid = (q - off * 0.5) / (2.0 * mk.params.z) + center;
            float covFlat = covSample(markFlat, uvFlat);
            float covTop = covSample(markFlat, uvTop);
            // ① 边界阴影：轮廓外的模糊副本，`passes` 遍 source-over（1−(1−a)^N）
            if (mk.wall.z > 0.001) {
                float cs = covSample(markShadow, uvFlat);
                float a = 1.0 - pow(1.0 - min(1.0, mk.wall.z * cs), mk.wall.w);
                if (covFlat < 0.5) { out1 = mix(out1, float3(0.0), a); }
            }
            // ② 侧壁带：沿挤出方向浅压暗（0.04 → 0.12，用中点采样判「走到哪一段」）
            float wall = clamp(covFlat - covTop, 0.0, 1.0);
            if (wall > 0.001) {
                float along = clamp(1.0 - covSample(markFlat, uvMid), 0.0, 1.0);
                float shade = mix(mk.wall.x, mk.wall.y, along);
                out1 = mix(out1, out1 * (1.0 - shade), wall);
            }
        }
        // ⑥ 环形环境遮蔽：自 surfaceRadius−rimShadow 线性爬升到满值（CG 用 6 段 inset 原语模拟 ⇒ 同 6 段量化）
        if (u.rimShadow > 0.01 && r <= u.surfaceRadius) {
            float t = saturate((r - (u.surfaceRadius - u.rimShadow)) / u.rimShadow);
            float a = u.rimShadowAlpha * ceil(t * 6.0) / 6.0;
            out1 = mix(out1, float3(0.0), a);
        }
        // ⑦ 硬边月牙（tokens.shadow）：偏移圆之外、surface 圆之内
        float dOff = length(p - float2(u.crescentOffsetX, 0.0));
        if (r <= u.surfaceRadius && dOff > u.surfaceRadius) {
            out1 = u.tokenShadow.rgb;
        }
        // ⑧ 模糊月牙（黑 α0.8）：同样 6 段量化；⚠️ CG 里它被 clip 在 surface 圆内（漏了这层裁剪，
        //    圆外会多出一圈暗环 —— 对拍剖面里 +84px 处 Metal=29 / CG=222 就是它）
        if (u.shadowBlur > 0.01 && r <= u.surfaceRadius) {
            float t = saturate((dOff - (u.surfaceRadius - u.shadowBlur)) / (2.0 * u.shadowBlur));
            out1 = mix(out1, float3(0.0), 0.8 * ceil(t * 6.0) / 6.0);
        }
        // ⑨ lowerField：整盖自上而下「透明 → 实色」，CSS color 混合
        if (u.fieldTransparent < 100.0) {
            float tf = gradT(q, u.radius, 180.0);
            float a = saturate((tf - u.fieldTransparent / 100.0) / (u.fieldOpaque / 100.0 - u.fieldTransparent / 100.0));
            out1 = blendColor(out1, u.fieldColor.rgb, a);
        }
        return out1;
    }

    // 侧壁：交替 ridge 色 × edgeShade → 逐面板横向高光 → 按面板强度压色场
    // ⚠️ 色场强度**在 shader 里按 CoinGeometry 的公式现算**（vertical = (1−cos a)/2，
    // strength = clamp((vertical−start)/(end−start))）—— 不传数组：对拍时发现「CPU 数组里
    // 侧段强度=0，但 shader 取到的值不为 0」，与其查 buffer 绑定，不如把公式搬进来，
    // 少一条跨缓冲的通路就少一处能出错的地方。
    static float3 sideColor(float3 lp, float3 n, constant CoinUniforms &u, float angle) {
        int segs = max(1, int(u.segments));
        // ⚠️ 段号口径必须照 `CoinGeometry`：normal[index] = (sin a, −cos a, 0)、angle = index/count·2π
        //    ⇒ 0 号在**正上方**（y 向下时 −y 是上）顺时针编号。原先按 atan2(n.y, n.x) 映射，
        //    段号整体错位 ⇒ 色场强度取错、交替 ridge 相位也错（对拍：yaw=90 的侧壁整条偏紫 +b/−g）。
        float ang = atan2(n.x, -n.y);
        if (ang < 0.0) { ang += 2.0 * M_PI_F; }
        // ⚠️ 面板是「以该角度为中心」的弦（`CoinGeometry.point(u, w, angle)` 的四个角都在同一 angle 上），
        //    所以像素属于**最近**的那一段（round），不是 floor —— floor 会整体偏半段，
        //    配合 accentEvery 交替 ⇒ 一半面板的 ridge 色取反（对拍症状：侧壁整条偏紫绿的 accent 色）。
        float segF = ang / (2.0 * M_PI_F) * float(segs);
        int seg = int(round(segF)) % segs;
        if (seg < 0) { seg += segs; }
        float uw = saturate(segF - float(seg) + 0.5);      // 面板内横向位置（中心 = 0.5）
        bool alternate = (u.accentEvery > 0.5) && ((seg + 1) % int(u.accentEvery) == 0);
        float3 ridge = alternate ? u.edgeAccent.rgb : u.edgeBase.rgb;
        float3 face = mix(ridge, u.tokenShadow.rgb, u.edgeShade);
        float3 col = face;
        if (u.smoothEdge < 0.5) {
            // linear-gradient(90deg, mix(face,#000 12%), face 32% 68%, mix(face,#fff 10%))
            if (uw <= 0.32) {
                col = mix(mix(face, float3(0.0), 0.12), face, saturate(uw / 0.32));
            } else if (uw >= 0.68) {
                col = mix(face, mix(face, float3(1.0), 0.10), saturate((uw - 0.68) / 0.32));
            }
        }
        float vertical = (1.0 - cos(angle)) / 2.0;
        float start = u.fieldTransparent / 100.0;
        float end = u.fieldOpaque / 100.0;
        float fstrength = (end <= start) ? 0.0
            : clamp((vertical - start) / (end - start), 0.0, 1.0);
        return blendColor(col, u.fieldColor.rgb, fstrength);
    }

    fragment float4 coinFragment(VSOut in [[stage_in]], constant CoinUniforms &u [[buffer(0)]],
                                 constant CoinMarkUniforms &mk [[buffer(1)]],
                                 texture2d<float> markFlat [[texture(0)]],
                                 texture2d<float> markShadow [[texture(1)]]) {
        // 2×2 子采样抗锯齿（CG 版是 CoreGraphics 的边缘抗锯齿，量级等价）
        float2 offs[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float4 acc = float4(0.0);
        for (int i = 0; i < 4; ++i) {
            float2 sp = in.pos.xy + offs[i] * u.subsampleStep;
            float3 s = float3(sp - u.center, 0.0);
            // ⚠️ 起点用矩阵的**行**：local = Mᵀ·s ⇒ local = s.x·(col0.x, col1.x, col2.x)
            //    + s.y·(col0.y, col1.y, col2.y)。拿列当行 ⇒ 正对/侧对都对、中间角度全错。
            float3 row0 = float3(u.col0.x, u.col1.x, u.col2.x);
            float3 row1 = float3(u.col0.y, u.col1.y, u.col2.y);
            float3 p0 = row0 * s.x + row1 * s.y;
            float3 d = -float3(u.col0.z, u.col1.z, u.col2.z);
            int kind = -1;
            float3 n = float3(0.0, 0.0, 1.0);
            float sideAngle = 0.0;
            float t = hitCylinder(p0, d, u.radius, u.halfThickness, kind, n);
            if (kind < 0) { continue; }
            float3 rgb;
            if (u.debugMode > 2.5) {
                // 探针：吐 mark 的中间量（3 = 轮廓覆盖度 covFlat；4 = 阴影覆盖度 covShadow；
                // 5 = 侧壁带 covFlat−covTop；6 = 顶面覆盖度 covTop）。侧壁像素吐 0。
                float v = 0.0;
                if (kind != 0) {
                    float2 lp2 = (p0 + t * d).xy;
                    float2 q2 = (kind == 2) ? lp2 : float2(-lp2.x, lp2.y);
                    float inv = 1.0 / (2.0 * mk.params.z);
                    float2 uvA = q2 * inv + 0.5;
                    float2 off2 = (kind == 2) ? mk.params.xy : -mk.params.xy;
                    float covA = covSample(markFlat, uvA);
                    if (u.debugMode < 3.5) { v = covA; }
                    else if (u.debugMode < 4.5) { v = covSample(markShadow, uvA); }
                    else if (u.debugMode < 5.5) { v = clamp(covA - covSample(markFlat, (q2 - off2) * inv + 0.5), 0.0, 1.0); }
                    else { v = covSample(markFlat, (q2 - off2) * inv + 0.5); }
                }
                rgb = float3(v);
            } else if (u.debugMode > 1.5) {
                rgb = u.tokenBase.rgb;                      // 探针：直接吐 tokenBase（查 uniform 是否传对）
            } else if (u.debugMode > 0.5) {
                rgb = (kind == 0) ? float3(1, 0, 0) : float3(0, 1, 0);
            } else if (kind == 0) {
                float aa = atan2(n.x, -n.y);
                if (aa < 0.0) { aa += 2.0 * M_PI_F; }
                sideAngle = aa;
                rgb = sideColor(p0 + t * d, n, u, aa);
            } else {
                float2 lp = (p0 + t * d).xy;
                float r = length(lp);
                rgb = capColor(lp, r, kind == 2, u, mk, markFlat, markShadow);
            }
            acc += float4(rgb, 1.0);
        }
        return acc * 0.25;
    }
    """
}

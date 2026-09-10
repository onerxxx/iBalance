// ─── 本文件速查（只写「去哪找」，不写行号）──────────────────────────────────────
// 目的      把 SVG（自家 GHO 预设 + 用户上传的 .svg）解析成 mark 能画的轮廓：只做几何
// 产出      CoinLogoArt：三条轮廓（nonzero 填充 / evenodd 填充 / 描边）+ 线宽/端点/拐角
// 支持      元素 path circle ellipse rect line polyline polygon，容器 g svg
//           transform translate/scale/rotate/matrix（按 SVG 规则左到右复合）
//           样式继承 fill stroke stroke-width fill-rule stroke-linecap stroke-linejoin
//           路径命令 M L H V C S Q T A Z（大小写、重复组、圆弧转三次贝塞尔都支持）
// 坐标      输出落在 **160 参考盒**：有 viewBox / width-height 就按它等比居中装进 160×160；
//           两者都没有（裸坐标）就按**内容自身范围**自动定位 —— 否则会缩在角落、画不出来
// 产出补充  `boundingReach` = 外接方形口径的最大半径（判断有没有出裁剪圆）
//           `radialReach`   = 真实几何离盒中心的最大半径（出圆时按它收缩，收完一点不切）
// 不做      text image use defs clipPath mask 渐变 filter CSS 类（整块跳过，不猜着画）
// ⚠️ 局限    描边宽度/端点/拐角与填充规则按「最后一个声明者」定，不逐元素分组
// ─────────────────────────────────────────────────────────────────────────────

import Cocoa

/// 解析结果：mark 的三条轮廓。参考实现里 logo 恒为 `fill: currentColor` —— 只解析几何，
/// 上色交给 `Coin3DView`：mark 直接用盖面那套面材质（surface 渐变 + lowerField），
/// 所以这里不带任何颜色信息。
struct CoinLogoArt {
    /// 填充轮廓（`fill-rule` 默认 nonzero）
    var fillPath: CGPath?
    /// `fill-rule="evenodd"` 的填充轮廓（Figma / Illustrator 导出常用来挖洞）
    var evenOddPath: CGPath?
    /// 描边轮廓（`fill="none"` + `stroke=…` 的线性图标走这条）
    var strokePath: CGPath?
    var strokeWidth: Double = 1
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    /// viewBox → 160 盒的等比缩放：描边宽度不随 CGPath 变换走，画的时候要手动乘上
    /// （总缩放 = fitScale × logoScale × sizeScale）
    var fitScale: Double = 1

    var isEmpty: Bool { fillPath == nil && evenOddPath == nil && strokePath == nil }

    /// 三条轮廓在外接方形口径下的最大半径（= 并集包围盒离 160 盒中心最远的边）。
    /// 只用来**判断内容有没有出圆**：预设 mark 是照着固定裁剪圆画的，外接方仍在圆内
    /// （擦边的四个角是刻意外观）→ 靠它把预设排除在自动收缩之外。描边按线宽一半外扩。
    var boundingReach: Double? {
        var box: CGRect?
        for path in [fillPath, evenOddPath] {
            guard let path else { continue }
            let rect = path.boundingBoxOfPath
            box = box.map { $0.union(rect) } ?? rect
        }
        if let strokePath {
            let grow = strokeWidth * fitScale / 2
            let rect = strokePath.boundingBoxOfPath.insetBy(dx: -grow, dy: -grow)
            box = box.map { $0.union(rect) } ?? rect
        }
        guard let box, !box.isNull, !box.isEmpty else { return nil }
        let c = Double(CoinSVG.box) / 2
        return max(max(Double(box.maxX) - c, c - Double(box.minX)),
                   max(Double(box.maxY) - c, c - Double(box.minY)))
    }

    /// 三条轮廓里**离 160 盒中心最远**的那一点的半径（描边按真实外轮廓、含端点与拐角）。
    /// `drawMark` 用它把内容收进裁剪圆：总缩放里先乘 `markClipRadius / radialReach`。
    ///
    /// ⚠️ 别用包围盒代替 —— 盒的四角在圆外。正方形半边 80 时外接方口径 reach=80、缩到
    /// 61.5/80=0.77，但四角半径是 80√2≈113，缩完仍在圆外 → 四个角还是被切。
    /// 只有按**真实几何的最大半径**收缩，才能保证收缩后一点不切。
    var radialReach: Double? {
        let cx = Double(CoinSVG.box) / 2, cy = cx
        var best = 0.0
        var seen = false
        func consider(_ p: CGPoint) {
            let dx = Double(p.x) - cx, dy = Double(p.y) - cy
            let r = (dx * dx + dy * dy).squareRoot()
            if r > best { best = r }
            seen = true
        }
        func walk(_ path: CGPath?) {
            guard let path else { return }
            var from = CGPoint.zero
            path.applyWithBlock { e in
                let el = e.pointee
                switch el.type {
                case .moveToPoint:
                    from = el.points[0]; consider(from)
                case .addLineToPoint:
                    from = el.points[0]; consider(from)
                case .addQuadCurveToPoint:
                    let c = el.points[0], end = el.points[1]
                    for i in 1...Self.curveSteps { consider(Self.quad(from, c, end, Double(i) / Double(Self.curveSteps))) }
                    from = end
                case .addCurveToPoint:
                    let c1 = el.points[0], c2 = el.points[1], end = el.points[2]
                    for i in 1...Self.curveSteps { consider(Self.cubic(from, c1, c2, end, Double(i) / Double(Self.curveSteps))) }
                    from = end
                case .closeSubpath:
                    break
                @unknown default:
                    break
                }
            }
        }
        walk(fillPath)
        walk(evenOddPath)
        // 描边：直接量「描边后的外轮廓」，端点圆帽 / 拐角尖角都算进去（不是简单加线宽一半）
        if let strokePath {
            let w = strokeWidth * fitScale
            walk(strokePath.copy(strokingWithWidth: w, lineCap: lineCap, lineJoin: lineJoin,
                                 miterLimit: 10, transform: .identity))
        }
        return seen ? best : nil
    }

    /// 曲线细分段数：16 段时半径误差远小于 0.01（160 盒单位），一次性计算，开销可忽略
    private static let curveSteps = 16

    /// 可按**面**填充的实体轮廓：fill / evenodd / 把描边外扩成的闭合外轮廓。
    ///
    /// 立体挤出要的是面、不是描边指令 —— 描边得先 `copy(strokingWithWidth:)` 转成外轮廓路径
    /// 才能跟填充轮廓走同一条「沿法线 Minkowski 扫掠」的路。
    /// `scale` = 除 `fitScale` 之外还会施加的缩放（logoScale × sizeScale × contentFit）；
    /// 描边宽度不随 CGPath 变换走，所以要手动乘进去。
    func solids(scale: Double) -> [(path: CGPath, evenOdd: Bool)] {
        var list: [(CGPath, Bool)] = []
        if let fillPath { list.append((fillPath, false)) }
        if let evenOddPath { list.append((evenOddPath, true)) }
        if let strokePath {
            let width = strokeWidth * fitScale * scale
            list.append((strokePath.copy(strokingWithWidth: width, lineCap: lineCap,
                                         lineJoin: lineJoin, miterLimit: 10,
                                         transform: .identity), false))
        }
        return list
    }

    private static func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * Double(p0.x) + 2 * u * t * Double(c.x) + t * t * Double(p1.x),
                       y: u * u * Double(p0.y) + 2 * u * t * Double(c.y) + t * t * Double(p1.y))
    }

    private static func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * Double(p0.x) + b * Double(c1.x) + c * Double(c2.x) + d * Double(p1.x),
                       y: a * Double(p0.y) + b * Double(c1.y) + c * Double(c2.y) + d * Double(p1.y))
    }
}

enum CoinSVGError: LocalizedError {
    case malformed
    case noDrawable

    var errorDescription: String? {
        switch self {
        case .malformed:  return "不是有效的 SVG / XML"
        case .noDrawable: return "没有可绘制的图形（支持 path、circle、rect、ellipse、line、polygon）"
        }
    }
}

enum CoinSVG {
    /// 解析结果的坐标口径：160 参考盒（= mintform 的 size=160 基准）
    static let box: CGFloat = 160

    // MARK: 入口

    static func parse(_ data: Data) throws -> CoinLogoArt {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw CoinSVGError.malformed }
        return try delegate.finish()
    }

    static func parse(_ svg: String) throws -> CoinLogoArt {
        try parse(Data(svg.utf8))
    }

    /// GHO 预设 mark（Mintform.tsx `GhoMark`：一条环形轮廓 + 两只眼睛）。
    /// 与用户上传件走**同一条解析路径**，不另养一套解析器。
    /// ⚠️ 源串是编译期常量且离线自检过（bbox + 探针）：解析失败直接崩，不静默画错。
    static let ghoPreset: CoinLogoArt = try! parse("""
        <svg viewBox="0 0 160 160" xmlns="http://www.w3.org/2000/svg">
          <path d="M80 26c-29 0-52 23-52 53s23 53 52 53c18 0 32-8 41-21l-1-1v21h13V84h-14c-3 19-18 33-39 33S41 100 41 79s17-39 39-39c19 0 34 13 37 31h14c-4-26-26-45-51-45Z"/>
          <circle cx="66" cy="71" r="10.5"/>
          <circle cx="94" cy="71" r="10.5"/>
        </svg>
        """)
}

// MARK: - XML 遍历

extension CoinSVG {

    /// 可继承的绘制样式（SVG 的 presentation attribute + `style=""` 合并后的结果）
    fileprivate struct Style {
        var fill = true
        var evenOdd = false
        var stroke = false
        var strokeWidth = 1.0
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
    }

    /// 整块跳过（不产出几何）的元素：它们只是定义 / 引用 / 栅格 / 文本 / 样式
    fileprivate static let skipped: Set<String> = [
        "defs", "clippath", "mask", "symbol", "marker", "pattern",
        "lineargradient", "radialgradient", "filter", "use", "image",
        "text", "tspan", "style", "title", "desc", "foreignobject",
    ]

    fileprivate final class Parser: NSObject, XMLParserDelegate {
        private var viewBox: CGRect?
        private var rootSize: CGSize?

        private let nonzero = CGMutablePath()
        private let evenOdd = CGMutablePath()
        private let stroked = CGMutablePath()

        private var style = Style()
        private var transform = CGAffineTransform.identity
        private var styleStack: [Style] = []
        private var transformStack: [CGAffineTransform] = []
        private var skipDepth = 0
        /// 描边计量（局限见文件头：按最后一个声明者定）
        private var strokeWidth = 1.0
        private var cap: CGLineCap = .butt
        private var join: CGLineJoin = .miter

        // MARK: 收尾

        func finish() throws -> CoinLogoArt {
            let box = sourceBox
            let scale = min(CoinSVG.box / box.width, CoinSVG.box / box.height)
            // 先按源盒缩放，再平移到居中（scale 作用在平移**之前**）
            var map = CGAffineTransform(scaleX: scale, y: scale).translatedBy(
                x: -box.minX + (CoinSVG.box / scale - box.width) / 2,
                y: -box.minY + (CoinSVG.box / scale - box.height) / 2)
            var art = CoinLogoArt()
            if !nonzero.isEmpty { art.fillPath = nonzero.copy(using: &map) }
            if !evenOdd.isEmpty { art.evenOddPath = evenOdd.copy(using: &map) }
            if !stroked.isEmpty {
                art.strokePath = stroked.copy(using: &map)
                art.strokeWidth = strokeWidth
                art.lineCap = cap
                art.lineJoin = join
            }
            art.fitScale = Double(scale)
            guard !art.isEmpty else { throw CoinSVGError.noDrawable }
            return art
        }

        /// 源盒：viewBox（优先）或 width/height；**两者都没有时用内容自己的范围** ——
        /// 裸坐标的 SVG（既无 viewBox 也无宽高）没有源盒，若按 160 假盒处理，
        /// 内容会缩在角落、整块落在裁剪圆外 = 一个像素都画不出来。
        private var sourceBox: CGRect {
            if let viewBox, viewBox.width > 0, viewBox.height > 0 { return viewBox }
            if let rootSize, rootSize.width > 0, rootSize.height > 0 {
                return CGRect(origin: .zero, size: rootSize)
            }
            if let content = sourceContentBounds, content.width > 0, content.height > 0 { return content }
            return CGRect(x: 0, y: 0, width: CoinSVG.box, height: CoinSVG.box)
        }

        /// 已解析几何在**源坐标**里的并集范围（还没有任何图形 → nil）
        private var sourceContentBounds: CGRect? {
            var box: CGRect?
            for path in [nonzero, evenOdd, stroked] where !path.isEmpty {
                let rect = path.boundingBoxOfPath
                guard !rect.isNull, !rect.isEmpty else { continue }
                box = box.map { $0.union(rect) } ?? rect
            }
            return box
        }

        // MARK: XMLParserDelegate

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let name = elementName.lowercased()
            styleStack.append(style)
            transformStack.append(transform)

            if name == "svg" { readRootBox(attributes) }
            merge(attributes)                                    // 本元素自己的样式声明
            if let text = attributes["transform"] {
                transform = CoinSVG.transform(text).concatenating(transform)   // 元素在前、父级在后
            }

            if CoinSVG.skipped.contains(name) { skipDepth += 1 }
            guard skipDepth == 0 else { return }
            switch name {
            case "path":
                if let d = attributes["d"] { addPathData(d) }
            case "circle":
                addEllipse(cx: number(attributes, "cx"), cy: number(attributes, "cy"),
                           rx: number(attributes, "r"), ry: number(attributes, "r"))
            case "ellipse":
                addEllipse(cx: number(attributes, "cx"), cy: number(attributes, "cy"),
                           rx: number(attributes, "rx"), ry: number(attributes, "ry"))
            case "rect":
                addRect(attributes)
            case "line":
                addPolyline([CGPoint(x: number(attributes, "x1"), y: number(attributes, "y1")),
                             CGPoint(x: number(attributes, "x2"), y: number(attributes, "y2"))],
                            closed: false)
            case "polyline":
                addPolyline(CoinSVG.points(attributes["points"] ?? ""), closed: false)
            case "polygon":
                addPolyline(CoinSVG.points(attributes["points"] ?? ""), closed: true)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let name = elementName.lowercased()
            if CoinSVG.skipped.contains(name) { skipDepth -= 1 }
            if let last = styleStack.popLast() { style = last }
            if let last = transformStack.popLast() { transform = last }
        }

        // MARK: 元素 → 轮廓

        private func emit(_ subpath: CGPath) {
            // 既无填充也无描边 = SVG 里的隐形件，直接丢
            if style.fill {
                (style.evenOdd ? evenOdd : nonzero).addPath(subpath)
            }
            if style.stroke {
                stroked.addPath(subpath)
                strokeWidth = style.strokeWidth
                cap = style.cap
                join = style.join
            }
        }

        private func addPathData(_ d: String) {
            let path = CGMutablePath()
            CoinSVG.appendPathData(d, to: path)
            var element = transform
            emit(path.copy(using: &element) ?? path)
        }

        private func addEllipse(cx: Double, cy: Double, rx: Double, ry: Double) {
            guard rx > 0, ry > 0 else { return }
            let rect = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
            let path = CGMutablePath()
            path.addEllipse(in: rect, transform: transform)
            emit(path)
        }

        private func addRect(_ attributes: [String: String]) {
            let x = number(attributes, "x"), y = number(attributes, "y")
            let w = number(attributes, "width"), h = number(attributes, "height")
            guard w > 0, h > 0 else { return }
            let rx = min(number(attributes, "rx"), w / 2), ry = min(number(attributes, "ry"), h / 2)
            let radius = max(rx, ry)
            let rect = CGRect(x: x, y: y, width: w, height: h)
            let path = CGMutablePath()
            if radius > 0 {
                path.addRoundedRect(in: rect, cornerWidth: rx > 0 ? rx : ry,
                                    cornerHeight: ry > 0 ? ry : rx, transform: transform)
            } else {
                path.addRect(rect, transform: transform)
            }
            emit(path)
        }

        private func addPolyline(_ points: [CGPoint], closed: Bool) {
            guard points.count > 1 else { return }
            let path = CGMutablePath()
            path.addLines(between: points, transform: transform)
            if closed { path.closeSubpath() }
            emit(path)
        }

        // MARK: 属性

        private func readRootBox(_ attributes: [String: String]) {
            if viewBox == nil, let text = attributes["viewBox"] {
                let v = CoinSVG.numbers(text)
                if v.count == 4 { viewBox = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
            }
            if rootSize == nil, let w = attributes["width"], let h = attributes["height"] {
                let size = CGSize(width: CoinSVG.length(w), height: CoinSVG.length(h))
                if size.width > 0, size.height > 0 { rootSize = size }
            }
        }

        /// presentation attribute 先、`style=""` 后（SVG 的优先级就是这个）
        private func merge(_ attributes: [String: String]) {
            apply(attributes)
            guard let inline = attributes["style"] else { return }
            var declared: [String: String] = [:]
            for item in inline.split(separator: ";") {
                let pair = item.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                declared[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    pair[1].trimmingCharacters(in: .whitespaces)
            }
            apply(declared)
        }

        private func apply(_ attributes: [String: String]) {
            if let fill = attributes["fill"] {
                style.fill = !(fill == "none" || fill == "transparent")
            }
            if let rule = attributes["fill-rule"] {
                style.evenOdd = (rule == "evenodd")
            }
            if let stroke = attributes["stroke"] {
                style.stroke = !(stroke == "none" || stroke == "transparent")
            }
            if let width = attributes["stroke-width"], let value = Double(width) {
                style.strokeWidth = max(value, 0)
            }
            if let value = attributes["stroke-linecap"] {
                style.cap = ["round": CGLineCap.round, "square": .square][value] ?? .butt
            }
            if let value = attributes["stroke-linejoin"] {
                style.join = ["round": CGLineJoin.round, "bevel": .bevel][value] ?? .miter
            }
        }

        private func number(_ attributes: [String: String], _ key: String) -> Double {
            guard let text = attributes[key] else { return 0 }
            return Double(text) ?? CoinSVG.length(text)
        }
    }
}

// MARK: - transform / 数值 / 路径数据的纯函数

extension CoinSVG {

    /// `transform="translate(…) scale(…) rotate(…)"` —— 左到右**依次作用在点上**（后写的先作用）
    static func transform(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i].isLetter else { i += 1; continue }
            var name = ""
            while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
            while i < chars.count, chars[i] == " " || chars[i] == "," { i += 1 }
            var args: [Double] = []
            while i < chars.count, chars[i] != ")" {
                if let value = readNumber(chars, &i) { args.append(value) } else { i += 1 }
            }
            if i < chars.count { i += 1 }   // 跳过 ")"
            let step: CGAffineTransform
            switch name.lowercased() {
            case "translate":
                step = CGAffineTransform(translationX: args.first ?? 0,
                                         y: args.count > 1 ? args[1] : 0)
            case "scale":
                let sx = args.first ?? 1
                step = CGAffineTransform(scaleX: sx, y: args.count > 1 ? args[1] : sx)
            case "rotate":
                let radians = (args.first ?? 0) * .pi / 180
                if args.count > 2 {
                    let t = CGAffineTransform(translationX: args[1], y: args[2])
                    step = t.rotated(by: radians).translatedBy(x: -args[1], y: -args[2])
                } else {
                    step = CGAffineTransform(rotationAngle: radians)
                }
            case "matrix":
                if args.count == 6 {
                    step = CGAffineTransform(a: args[0], b: args[1], c: args[2],
                                             d: args[3], tx: args[4], ty: args[5])
                } else {
                    step = .identity
                }
            case "skewx": step = CGAffineTransform(a: 1, b: 0, c: tan((args.first ?? 0) * .pi / 180),
                                                   d: 1, tx: 0, ty: 0)
            case "skewy": step = CGAffineTransform(a: 1, b: tan((args.first ?? 0) * .pi / 180),
                                                   c: 0, d: 1, tx: 0, ty: 0)
            default: step = .identity
            }
            result = step.concatenating(result)   // 后写的先作用在点上
        }
        return result
    }

    /// 带单位后缀的长度（`24`、`24px`、`2.5em` 都当成数值前缀）
    static func length(_ text: String) -> Double {
        var text = Array(text.trimmingCharacters(in: .whitespaces))
        var i = 0
        return readNumber(text, &i) ?? 0
    }

    /// 逗号/空格分隔的数字串（viewBox、points、渐变 offset 等）→ 数值数组
    static func numbers(_ text: String) -> [Double] {
        let chars = Array(text)
        var result: [Double] = []
        var i = 0
        while i < chars.count {
            if let value = readNumber(chars, &i) { result.append(value) } else { i += 1 }
        }
        return result
    }

    /// `points="x,y x,y …"` → 点列
    static func points(_ text: String) -> [CGPoint] {
        let values = numbers(text)
        var result: [CGPoint] = []
        var i = 0
        while i + 1 < values.count {
            result.append(CGPoint(x: values[i], y: values[i + 1]))
            i += 2
        }
        return result
    }

    // MARK: 路径数据

    /// 把 `d` 追加进 `path`：M L H V C S Q T A Z（大小写 = 绝对/相对，支持重复参数组）
    static func appendPathData(_ d: String, to path: CGMutablePath) {
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?

        for (raw, values) in scan(d) {
            let relative = raw.isLowercase
            let command = Character(raw.uppercased())
            var i = 0
            func point(_ index: Int) -> CGPoint {
                let x = values[index], y = values[index + 1]
                return relative ? CGPoint(x: current.x + x, y: current.y + y)
                                : CGPoint(x: x, y: y)
            }
            /// 相对命令下「控制点也要跟着当前点偏移」的反射点
            func reflect(_ control: CGPoint?) -> CGPoint {
                control.map { CGPoint(x: current.x * 2 - $0.x, y: current.y * 2 - $0.y) } ?? current
            }

            switch command {
            case "M":
                while i + 1 < values.count {
                    let p = point(i)
                    if i == 0 { path.move(to: p); subpathStart = p } else { path.addLine(to: p) }
                    current = p
                    i += 2
                }
                lastCubic = nil; lastQuad = nil
            case "L":
                while i + 1 < values.count {
                    let p = point(i); path.addLine(to: p); current = p; i += 2
                }
                lastCubic = nil; lastQuad = nil
            case "H":
                while i < values.count {
                    let p = CGPoint(x: relative ? current.x + values[i] : values[i], y: current.y)
                    path.addLine(to: p); current = p; i += 1
                }
                lastCubic = nil; lastQuad = nil
            case "V":
                while i < values.count {
                    let p = CGPoint(x: current.x, y: relative ? current.y + values[i] : values[i])
                    path.addLine(to: p); current = p; i += 1
                }
                lastCubic = nil; lastQuad = nil
            case "C", "S":
                let stride = command == "C" ? 6 : 4
                while i + stride <= values.count {
                    let c1: CGPoint, c2: CGPoint, end: CGPoint
                    if command == "C" {
                        c1 = point(i); c2 = point(i + 2); end = point(i + 4)
                    } else {
                        c1 = reflect(lastCubic); c2 = point(i); end = point(i + 2)
                    }
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastCubic = c2; lastQuad = nil
                    current = end
                    i += stride
                }
            case "Q", "T":
                let stride = command == "Q" ? 4 : 2
                while i + stride <= values.count {
                    let control: CGPoint, end: CGPoint
                    if command == "Q" {
                        control = point(i); end = point(i + 2)
                    } else {
                        control = reflect(lastQuad); end = point(i)
                    }
                    // 二次 → 三次：c1 = p0 + 2/3(q − p0)、c2 = p1 + 2/3(q − p1)
                    let c1 = CGPoint(x: current.x + 2.0 / 3.0 * (control.x - current.x),
                                     y: current.y + 2.0 / 3.0 * (control.y - current.y))
                    let c2 = CGPoint(x: end.x + 2.0 / 3.0 * (control.x - end.x),
                                     y: end.y + 2.0 / 3.0 * (control.y - end.y))
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastQuad = control; lastCubic = nil
                    current = end
                    i += stride
                }
            case "A":
                while i + 6 < values.count {
                    let rx = values[i], ry = values[i + 1], rotation = values[i + 2]
                    let largeArc = values[i + 3] != 0, sweep = values[i + 4] != 0
                    let end = point(i + 5)
                    addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation,
                           largeArc: largeArc, sweep: sweep)
                    current = end
                    i += 7
                }
                lastCubic = nil; lastQuad = nil
            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastCubic = nil; lastQuad = nil
            default:
                break
            }
        }
    }

    /// 切出 (命令, 该命令后的一串数字)；重复的数字组由调用方按元数分组消费。
    /// ⚠️ `A/a` 的 7 元组里**两个 flag 是单个字符**：`a.306.306 0 01.415-.287` 要读成
    /// rot=0 / large=0 / sweep=1 / x=.415 / y=−.287 —— 把 `01.415` 当一个数读成 1.415，
    /// 后面所有参数整体错位（SVGO 压过的图标几乎全是这种写法，DeepSeek 那条 path 就是）。
    private static func scan(_ d: String) -> [(Character, [Double])] {
        let chars = Array(d)
        var result: [(Character, [Double])] = []
        var command: Character?
        var buffer: [Double] = []
        var i = 0

        func flush() {
            if let command, !buffer.isEmpty {
                result.append((command, buffer))
                buffer = []
            }
        }

        while i < chars.count {
            let ch = chars[i]
            if ch.isLetter {
                flush()
                command = ch
                i += 1
            } else if isSeparator(ch) {
                i += 1
            } else if isArc(command), buffer.count % 7 == 4 {
                // 第 5 位是 sweep flag —— 同样只吃一个字符（第 4 位 large flag 见下）
                buffer.append(ch == "1" ? 1 : 0)
                i += 1
            } else if isArc(command), buffer.count % 7 == 3 {
                buffer.append(ch == "1" ? 1 : 0)
                i += 1
            } else if let value = readNumber(chars, &i) {
                buffer.append(value)
            } else {
                i += 1
            }
        }
        flush()
        return result
    }

    private static func isArc(_ command: Character?) -> Bool {
        command == "a" || command == "A"
    }

    private static func isSeparator(_ ch: Character) -> Bool {
        ch == "," || ch == " " || ch == "\n" || ch == "\t" || ch == "\r"
    }

    private static func isDigit(_ ch: Character) -> Bool {
        ch.isASCII && ch.isNumber
    }

    /// 读一个 SVG number：可选符号 + 整数 + 可选小数 + 可选指数。
    /// ⚠️ 一个小数点只能出现一次 —— `3.393.137` 必须切成 `3.393` 与 `.137`（SVGO 把相邻
    /// 数字压在一起时全靠这条）；读不出数字时**不动** index，由调用方跳过该字符防止死循环。
    private static func readNumber(_ chars: [Character], _ index: inout Int) -> Double? {
        let start = index
        var text = ""
        if index < chars.count, chars[index] == "+" || chars[index] == "-" {
            text.append(chars[index])
            index += 1
        }
        var digits = 0
        while index < chars.count, isDigit(chars[index]) {
            text.append(chars[index])
            index += 1
            digits += 1
        }
        if index < chars.count, chars[index] == "." {
            text.append(".")
            index += 1
            while index < chars.count, isDigit(chars[index]) {
                text.append(chars[index])
                index += 1
                digits += 1
            }
        }
        guard digits > 0 else {
            index = start
            return nil
        }
        if index < chars.count, chars[index] == "e" || chars[index] == "E" {
            let exponentStart = index
            var exponent = ""
            exponent.append(chars[index])
            index += 1
            if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                exponent.append(chars[index])
                index += 1
            }
            var exponentDigits = 0
            while index < chars.count, isDigit(chars[index]) {
                exponent.append(chars[index])
                index += 1
                exponentDigits += 1
            }
            if exponentDigits > 0 { text += exponent } else { index = exponentStart }
        }
        return Double(text)
    }

    /// 端点式圆弧 → 三次贝塞尔（W3C 实现附注 F.6 的中心参数化，每段 ≤ 90°）
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: Double, ry ryIn: Double, rotation: Double,
                               largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx < 1e-9 || ry < 1e-9 {
            path.addLine(to: p1)
            return
        }
        if p0 == p1 { return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if lambda > 1 {
            let grow = lambda.squareRoot()
            rx *= grow
            ry *= grow
        }
        let sign: Double = (largeArc != sweep) ? 1 : -1
        let numerator = max(rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p, 0)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let factor = denominator > 0 ? sign * (numerator / denominator).squareRoot() : 0
        let cxp = factor * rx * y1p / ry
        let cyp = -factor * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func sweepAngle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let length = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var angle = acos(min(max(dot / max(length, 1e-12), -1), 1))
            if ux * vy - uy * vx < 0 { angle = -angle }
            return angle
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta0 = sweepAngle(1, 0, ux, uy)
        var delta = sweepAngle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(Int(ceil(abs(delta) / (.pi / 2))), 1)
        let step = delta / Double(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)

        func onCurve(_ angle: Double) -> CGPoint {
            let x = rx * cos(angle), y = ry * sin(angle)
            return CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
        }
        func tangent(_ angle: Double) -> CGPoint {
            let x = -rx * sin(angle), y = ry * cos(angle)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }

        var start = p0
        var theta = theta0
        for _ in 0..<segments {
            let next = theta + step
            let end = onCurve(next)
            let d0 = tangent(theta), d1 = tangent(next)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + alpha * d0.x, y: start.y + alpha * d0.y),
                          control2: CGPoint(x: end.x - alpha * d1.x, y: end.y - alpha * d1.y))
            start = end
            theta = next
        }
    }
}

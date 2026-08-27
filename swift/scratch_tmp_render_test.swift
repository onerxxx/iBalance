// 渲染对比实验:原版单 label 富文本 vs RollingNumberView 逐字符槽位
// 渲染到位图后扫描墨迹 bbox,对比水平/垂直位置差异
import Cocoa

func textWidth(_ s: String, font: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
}

let mainFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
let prefixFont = NSFont.monospacedDigitSystemFont(ofSize: 7.8, weight: .semibold)
print("mainFont metrics: asc=\(mainFont.ascender) desc=\(mainFont.descender) lead=\(mainFont.leading) lineH=\(ceil(mainFont.ascender - mainFont.descender + mainFont.leading))")
print("prefixFont metrics: asc=\(prefixFont.ascender) desc=\(prefixFont.descender) lead=\(prefixFont.leading)")

let W: CGFloat = 65, H: CGFloat = 16

// —— A: 原版口径 —— 富文本 + 右对齐 label(高16,同 row1)
let labelA = NSTextField(labelWithString: "")
labelA.font = mainFont
let attr = NSMutableAttributedString(string: "¥", attributes: [.font: prefixFont])
attr.append(NSAttributedString(string: "11.99", attributes: [.font: mainFont]))
let para = NSMutableParagraphStyle()
para.alignment = .right
attr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attr.length))
labelA.attributedStringValue = attr
labelA.frame = NSRect(x: 0, y: 0, width: W, height: H)

// —— B: RollingNumberView 口径 —— 逐字符槽位(RollPos 实测坐标,flipped 容器)
// RollPos: ¥@21.66 1@26.98 1@35.44 .@43.89 9@48.09 9@56.55 (等宽 8.45, . 4.20, ¥ 5.33)
// flipped 坐标 y 转非 flipped(NSView 默认):label frame y = H - yOff - h
final class FlipContainer: NSView {
    override var isFlipped: Bool { true }
}
let containerB = FlipContainer(frame: NSRect(x: 0, y: 0, width: W, height: H))
let slotsB: [(String, NSFont, CGFloat, CGFloat)] = [
    ("¥", prefixFont, 21.66, 5.33),
    ("1", mainFont, 26.98, 8.45),
    ("1", mainFont, 35.44, 8.45),
    (".", mainFont, 43.89, 4.20),
    ("9", mainFont, 48.09, 8.45),
    ("9", mainFont, 56.55, 8.45),
]
// DigitWheelView 静态槽口径: yOff = asc - f.asc; plain 高 = lineH(21), prefix 高 = prefixLineH
let lineH = ceil(mainFont.ascender - mainFont.descender + mainFont.leading)
let prefixLineH = ceil(prefixFont.ascender - prefixFont.descender + prefixFont.leading)
for (ch, f, x, w) in slotsB {
    let l = NSTextField(labelWithString: ch)
    l.font = f
    let isPrefix = (ch == "¥")
    let h = isPrefix ? prefixLineH : lineH
    let yOff = mainFont.ascender - f.ascender
    l.frame = NSRect(x: x, y: yOff, width: w, height: h)
    containerB.addSubview(l)
}

// —— 渲染与墨迹扫描 ——
func renderInk(_ view: NSView) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * 4, pixelsHigh: Int(H) * 4,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    view.cacheDisplay(in: view.bounds, to: rep)
    // 白底变透明区:找非白墨迹(文本黑色)
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    for py in 0..<rep.pixelsHigh {
        for px in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: px, y: py) else { continue }
            if c.redComponent < 0.5 || c.greenComponent < 0.5 || c.blueComponent < 0.5 {
                if px < minX { minX = px }; if px > maxX { maxX = px }
                if py < minY { minY = py }; if py > maxY { maxY = py }
            }
        }
    }
    guard maxX >= 0 else { return nil }
    // 转 pt(位图原点左下,视图 flipped?A 非 flipped,B flipped 容器但 cacheDisplay 用 view.bounds)
    return (minX, maxX, minY, maxY)
}

// 分别渲染(A 单 label;B 需包一层非 flipped 外壳,cacheDisplay 对 flipped 视图也适用其 bounds)
let wrapA = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
wrapA.addSubview(labelA)
if let a = renderInk(wrapA) {
    print("A(原版label) 墨迹bbox px: x[\(a.minX),\(a.maxX)] y[\(a.minY),\(a.maxY)] (4x,1px=0.25pt)")
}
if let b = renderInk(containerB) {
    print("B(逐字符槽) 墨迹bbox px: x[\(b.minX),\(b.maxX)] y[\(b.minY),\(b.maxY)]")
}

// 对照:逐槽理论 advance 边界
print("理论: A 右缘=65pt; B 最右槽右缘=56.55+8.45=65.0pt; ¥ 右缘=26.99pt")

// —— 附加:垂直口径 —— 原版 label(高16) vs 槽位 label(高21,yOff) 的基线位置
// label 垂直居中行为验证:不同高的 label 内同字形的墨迹 y
func glyphY(_ s: String, font: NSFont, h: CGFloat) -> (Int, Int)? {
    let l = NSTextField(labelWithString: s)
    l.font = font
    l.frame = NSRect(x: 0, y: 0, width: 30, height: h)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: Int(h) * 4,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 30, height: h)
    l.cacheDisplay(in: l.bounds, to: rep)
    var minY = Int.max, maxY = -1
    for py in 0..<rep.pixelsHigh {
        for px in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: px, y: py) else { continue }
            if c.redComponent < 0.5 {
                if py < minY { minY = py }; if py > maxY { maxY = py }
            }
        }
    }
    guard maxY >= 0 else { return nil }
    return (minY, maxY)
}
if let g16 = glyphY("9", font: mainFont, h: 16) {
    print("单label高16 '9' 墨迹y(px,原点左下): [\(g16.0),\(g16.1)] → 顶=\(String(format: "%.2f", 16 - Double(g16.1)/4))pt 基线参考")
}
if let g21 = glyphY("9", font: mainFont, h: lineH) {
    print("单label高\(Int(lineH)) '9' 墨迹y: [\(g21.0),\(g21.1)] → 顶=\(String(format: "%.2f", lineH - Double(g21.1)/4))pt")
}

// UsagePanel.swift — iBalance
// 用量板块:UsageRowSnapshot / 一周趋势图与子弹窗 / UsageDots / 面板用量行构建
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 数据模型    UsageRowSnapshot（用量行）/ UsageWeekData（一周 7 天数值 + 表头 + 累计）
// 趋势图      UsageHistoryChartView（**自绘**折线 + 面积 + 今日标注，走 draw(_:)，非控件）
// 子弹窗      UsageHistoryPopoverController + UsageHistoryPopoverAnchorView
//             （锚点固定为「用量标题」而非 hover 行，避免换行时错位）
// 进度条      UsageDots（渐变进度条：灰轨道 + 蓝渐变填充，按剩余比例填充；类名沿用旧点阵）
// 面板用量行    extension BalancePanelView：makeUsageRow / makeUsageHeaderRow / 列宽计算
//
// ⚠️ 自绘层不参与 AppKit 的字体/外观自动传播：Mono 开关与浅色主题由
//    UsageHistoryPopoverController 的 monoFontEnabled / lightThemeEnabled didSet **显式转发**。
//    改图表字体或配色，要确认这条转发链还在，别指望动态色自动生效。

import Cocoa
import CoreImage

/// 单个周浏览页的数据：图表 7 天数值/文本 + 表头标签与周累计。
struct UsageWeekData: Equatable {
    var daily: [Double] = []
    var dailyTexts: [String] = []
    /// 表头第二行标签：本周 =「本周累计用量」；历史周 =「8-25~8-31累计用量」
    var headerLabel: String = ""
    /// 右上角周累计数值（本周沿用实时差值 weekText，历史周为每日加总）
    var totalText: String = ""
}

/// 1小时/日/周用量行快照：icon + 平台名 + 已格式化的近1小时/今日/本周用量文本 + 周历史浏览页。
struct UsageRowSnapshot: Equatable {
    var platform: String
    var icon: String
    var name: String
    var hourText: String = ""
    var todayText: String
    var weekText: String
    /// 周历史浏览页：index 0 = 本周，1 = 上周……（usage.json 60 天保留窗口内最多 8 页）
    var historyWeeks: [UsageWeekData] = []
}

/// 用量行右侧趋势图：使用 AppKit 原生 NSView + NSBezierPath 绘制一周面积图。
/// 视图本身承担 hover 追踪，保证鼠标从用量行移动到 popover 时不会立即关闭。
final class UsageHistoryChartView: NSView, PanelScrollHoverSync {
    var row: UsageRowSnapshot? {
        didSet {
            // 跨行切换（hover 到别的平台）时周浏览页复位到本周
            if oldValue != row { weekOffset = 0 }
            needsDisplay = true
        }
    }
    /// 周浏览偏移：0 = 本周（默认），1 = 上周……由右上角箭头切换
    var weekOffset: Int = 0 {
        didSet { needsDisplay = true }
    }
    /// 右上角箭头命中区（draw 时更新；单周数据无历史时不显示箭头）
    private var leftArrowRect = NSRect.zero
    private var rightArrowRect = NSRect.zero
    private var cursorPushed = false
    var onHoverChanged: ((Bool) -> Void)?
    /// Mono 字体开关：开启时图表内所有文本（标题/刻度/数值/日期）用 JetBrainsMono
    var monoFontEnabled = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?
    /// 当日圆点 Pulse Dot 相位（0~1 线性周期位置）：驱动光环扩散进度
    private var blinkPhase: CGFloat = 0
    /// 闪烁驱动：NSView.displayLink（macOS 15+），随屏幕刷新出帧；
    /// 视图移出 window（子弹窗关闭）时暂停，重新出现时复用。
    private weak var blinkLink: CADisplayLink?

    /// 按当前字体开关取字体（优先级：Mono 风格 > 系统字体，与面板 uiFont 同策略）
    private func uiFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if monoFontEnabled { return MonoFontProvider.font(size: size, weight: weight) }
        return .systemFont(ofSize: size, weight: weight)
    }

    override var isFlipped: Bool { true }
    // 面积图保持紧凑，同时保留两行表头（平台名 + 本周用量两行标签、大号右对齐数值）、
    // 坐标日期和底部留白。2026-08-21 表头改两行结构，高度 158 → 172；
    // 2026-08-23 图表区高度降 15%（~86pt → ~73pt），总高 172 → 159（表头与底部 36pt 日期轴不动）；
    // 同日宽度降 10%（232 → 209），图表绘图区随宽度自适应收窄；
    // 2026-08-27 图表区高度再降 10%（~73 → ~66pt），总高 159 → 152
    override var intrinsicContentSize: NSSize { NSSize(width: 209, height: 152) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        // 退出图表前若箭头还压着手指光标，先弹出归还
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateArrowCursor(point: convert(event.locationInWindow, from: nil))
    }

    /// 命中箭头区域时切换手指光标（与余额卡片/磁贴同一交互语言）
    private func updateArrowCursor(point: NSPoint) {
        let inArrows = (row?.historyWeeks.count ?? 0) > 1
            && (arrowHitArea(leftArrowRect).contains(point) || arrowHitArea(rightArrowRect).contains(point))
        if inArrows, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !inArrows, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    private func arrowHitArea(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: -4, dy: -5)
    }

    /// 点击右上角箭头切换周浏览页（mouseUp 触发，与 HoverCard onClick 同时机）
    /// 左箭头 = 去更早的周（offset+1），右箭头 = 回到更新的周（offset-1）
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let row, row.historyWeeks.count > 1 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if arrowHitArea(leftArrowRect).contains(p),
           weekOffset < row.historyWeeks.count - 1 {
            weekOffset += 1
        } else if arrowHitArea(rightArrowRect).contains(p), weekOffset > 0 {
            weekOffset -= 1
        }
    }

    func syncHoverState(_ inside: Bool) {
        onHoverChanged?(inside)
    }

    // MARK: - 当日圆点 Pulse Dot（1.8s 周期：中心点常亮 + 光环向外扩散淡出，前 70% 扩散后 30% 停顿）
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startBlink() } else { stopBlink() }
    }

    private func startBlink() {
        if let link = blinkLink {
            link.isPaused = false
            return
        }
        let link = displayLink(target: self, selector: #selector(onBlinkTick(_:)))
        link.add(to: .main, forMode: .common)
        blinkLink = link
    }

    private func stopBlink() {
        blinkLink?.isPaused = true
    }

    @objc private func onBlinkTick(_ link: CADisplayLink) {
        // Pulse Dot 周期 1.8s；相位量化到 1/60 步长，120Hz 屏也不全速重绘
        let cycle: Double = 1.8
        let phase = (link.targetTimestamp.truncatingRemainder(dividingBy: cycle)) / cycle
        let q = (phase * 60).rounded() / 60
        if abs(q - blinkPhase) > 0.0001 {
            blinkPhase = q
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row else { return }

        let titleFont = monoFontEnabled
            ? MonoFontProvider.font(size: 9)
            : NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let detailFont = uiFont(size: 10)
        let axisFont = titleFont
        let titleColor = Palette.cardForeground
        let secondaryColor = NSColor.secondaryLabelColor
        let plotInset: CGFloat = 16
        let yAxisLabelWidth: CGFloat = 30
        let yAxisGap: CGFloat = 5
        let yAxisRightInset: CGFloat = 4
        let graphLineColor = Palette.chartLine
        let headerY: CGFloat = 12

        // 表头两行式：第一行「平台名 + 本周累计用量」标签（同行同字号同色，与 Token 子面板
        // 首行同款，右缘同一纵坐标为周切换箭头）；第二行周用量数值换行左对齐（字号不变）。
        let plotFullWidth = max(1, bounds.width - plotInset - yAxisGap
                                - yAxisLabelWidth - yAxisRightInset)
        let valueFont = monoFontEnabled
            ? MonoFontProvider.font(size: 17, weight: .semibold)
            : NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        // 当前浏览的周页（weekOffset 由右上角箭头切换；越界防御性夹取）
        let pageCount = max(1, row.historyWeeks.count)
        let safeOffset = min(max(0, weekOffset), pageCount - 1)
        let isCurrentWeek = safeOffset == 0
        let week = row.historyWeeks.indices.contains(safeOffset)
            ? row.historyWeeks[safeOffset]
            : UsageWeekData(daily: Array(repeating: 0, count: 7),
                            dailyTexts: Array(repeating: "—", count: 7),
                            headerLabel: "本周累计用量", totalText: row.weekText)
        // 第一行：平台名 + 空格 + 周标签（9pt 同字号同色 + 0.8 字距，系统灰对齐 Token 子面板标题）
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .kern: 0.8]
        let headerText = "\(row.name) \(week.headerLabel)"
        let headerTextH = headerText.size(withAttributes: [.font: titleFont]).height
        (headerText as NSString).draw(at: NSPoint(x: plotInset, y: headerY),
                                      withAttributes: headerAttrs.merging([.foregroundColor: NSColor.systemGray]) { cur, _ in cur })
        // 第二行：数值换行左对齐（17pt semibold 不变）
        let valueY = headerY + headerTextH + 4
        let weekSize = week.totalText.size(withAttributes: [.font: valueFont])
        drawText(week.totalText, at: NSPoint(x: plotInset, y: valueY), font: valueFont, color: titleColor)
        let headerBlockHeight = valueY + weekSize.height - headerY

        // 第一行右缘的周切换箭头（有历史周才显示，右对齐、与首行同一纵坐标）：
        // 左=过去周（offset+1），右=回到本周（offset-1）；到边界时置灰
        if row.historyWeeks.count > 1 {
            let arrowBox: CGFloat = 13
            let arrowGap: CGFloat = 6
            let arrowCenterY = headerY + headerTextH / 2
            let rightRect = NSRect(x: bounds.maxX - 4 - arrowBox,
                                   y: arrowCenterY - arrowBox / 2,
                                   width: arrowBox, height: arrowBox)
            let leftRect = NSRect(x: rightRect.minX - arrowGap - arrowBox,
                                  y: rightRect.minY,
                                  width: arrowBox, height: arrowBox)
            leftArrowRect = leftRect
            rightArrowRect = rightRect
            let disabledColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35)
            drawChevron(in: leftRect, pointingRight: false,
                        color: safeOffset < pageCount - 1 ? titleColor : disabledColor)
            drawChevron(in: rightRect, pointingRight: true,
                        color: safeOffset > 0 ? titleColor : disabledColor)
        } else {
            leftArrowRect = .zero
            rightArrowRect = .zero
        }

        // 表头块下保留 4pt 基础间距，随后将面积图、数值和日期轴整体下移 10pt。
        let headerHeight = headerBlockHeight
        let graphOffsetY: CGFloat = 10
        let plotTop = headerY + headerHeight + 4 + graphOffsetY
        // 底部固定 36pt 给 45° 旋转日期轴（高度改由 intrinsicContentSize 决定后按需留白）
        let plotBottom = bounds.height - 36
        let plot = NSRect(x: plotInset, y: plotTop,
                          width: max(1, bounds.width - plotInset - yAxisGap
                                     - yAxisLabelWidth - yAxisRightInset),
                          height: max(1, plotBottom - plotTop))
        // 曲线顶部预留数值标签空间，避免最高点和数值文字互相覆盖。
        let graphTopPadding: CGFloat = 14
        let graphHeight = max(1, plot.height - graphTopPadding)
        let values = Array(week.daily.prefix(7)) + Array(repeating: 0, count: max(0, 7 - week.daily.count))
        let texts = Array(week.dailyTexts.prefix(7)) + Array(repeating: "—", count: max(0, 7 - week.dailyTexts.count))
        let maxValue = values.max() ?? 0
        // 今天在周内第几个位置（周一=0）：按系统日期从本周一推算，仅本周有效；
        // 历史周是完整 7 天，todayIndex 取 6 让全部圆点/日期参与绘制，
        // 但不享受「今日高亮 + Pulse 光环 + 今日数值标注」（由 isCurrentWeek 门控）。
        var weekCal = Calendar.current
        weekCal.firstWeekday = 2
        let weekStartDate = weekCal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let todayIndex = isCurrentWeek
            ? min(6, max(0, weekCal.dateComponents([.day], from: weekStartDate, to: Date()).day ?? 0))
            : 6
        // 纵轴顶端取本周峰值向上取整，底端固定为 0；曲线按轴顶端归一化，给顶部留出真实余量。
        let axisMaxValue = max(1, ceil(maxValue))
        let axisSampleText = texts.first(where: { $0 != "—" }) ?? row.todayText

        // 网格线分两层：基线（0 位）更实，为面积提供「地面」；其余网格线更虚，纯读数辅助。
        let grid = NSBezierPath()
        let baseline = NSBezierPath()
        for ratio in [CGFloat(0), CGFloat(0.5), CGFloat(1)] {
            let y = plot.maxY - plot.height * ratio
            let path = ratio == 0 ? baseline : grid
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.20).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()
        NSColor.secondaryLabelColor.withAlphaComponent(0.38).setStroke()
        baseline.lineWidth = 0.5
        baseline.stroke()

        // 右侧纵轴：顶端为向上取整后的本周最高值，中点辅助读数，底端为 0。
        // 轴线与最后一个数据点共用同一条竖线，避免图表和坐标轴出现 1 个间距的错位。
        let axisX = plot.maxX
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: axisX, y: plot.minY))
        axis.line(to: NSPoint(x: axisX, y: plot.maxY))
        NSColor.secondaryLabelColor.withAlphaComponent(0.42).setStroke()
        axis.lineWidth = 0.5
        axis.stroke()
        let axisTicks: [(value: Double, ratio: CGFloat)] = [
            (axisMaxValue, 0),
            (axisMaxValue / 2, 0.5),
            (0, 1),
        ]
        for tick in axisTicks {
            let y = plot.minY + plot.height * tick.ratio
            let label = axisValueText(tick.value, sample: axisSampleText,
                                      preserveFraction: tick.value != tick.value.rounded())
            let labelHeight = label.size(withAttributes: [.font: axisFont]).height
            drawText(label,
                     // 纵坐标文本统一左对齐，所有刻度从轴线右侧同一个 x 起笔。
                     at: NSPoint(x: axisX + yAxisGap,
                                 y: y - labelHeight / 2),
                     font: axisFont, color: NSColor.systemGray)
        }

        if maxValue > 0.000001 {
            let points = values.enumerated().map { index, value in
                NSPoint(x: plot.minX + plot.width * CGFloat(index) / 6,
                        y: plot.maxY - graphHeight * CGFloat(value / axisMaxValue))
            }
            // 本周只把线/面积画到今天为止，未来日期保留坐标轴与标签但无曲线；
            // 历史周仍是完整 7 天（todayIndex 已置为 6）。
            let drawPoints = isCurrentWeek ? Array(points[0...todayIndex]) : points
            let area = NSBezierPath()
            area.move(to: NSPoint(x: drawPoints[0].x, y: plot.maxY))
            appendSmoothSegments(drawPoints, to: area)
            area.line(to: NSPoint(x: drawPoints.last!.x, y: plot.maxY))
            area.close()
            // 渐变锚点固定在绘图区上下边界，不随曲线最高点变化：顶部最实、向下渐隐。
            fillAreaGradient(area, in: plot)

            let line = NSBezierPath()
            appendSmoothSegments(drawPoints, to: line, movesToFirst: true)
            graphLineColor.setStroke()
            line.lineWidth = 2.2
            line.lineCapStyle = .round
            line.stroke()

            // 圆点尺寸按数值相对比例：本周最大值 8.2pt，最小 3.2pt，
            // 其余在区间内按 value/maxValue 线性映射；只画到今天为止（未来占位天不画）。
            // 当日圆点为 Pulse Dot：中心实心点常亮（峰值色区分于其余灰点，动态色随主题反转），
            // 光环按 blinkPhase 相位向外扩散并淡出（雷达 ping，1.8s 周期）。
            let dotMaxSize: CGFloat = 8.2
            let dotMinSize: CGFloat = 3.2
            let scale = maxValue > 0.000001 ? (dotMaxSize - dotMinSize) / maxValue : 0
            let dotBaseColor = Palette.pulseDotBase
            let dotPeakColor = Palette.pulseDotPeak
            for (index, point) in points.enumerated() where index <= todayIndex {
                let size = dotMinSize + values[index] * scale
                let radius = size / 2
                // 圆点必须以数据点为中心，保持与平滑曲线使用同一组坐标。
                let dot = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                                       width: size, height: size))
                (index == todayIndex && isCurrentWeek ? dotPeakColor : dotBaseColor).setFill()
                dot.fill()
                // 当日 Pulse 光环（仅本周）：前 70% 相位 ease-out 扩散到 ~2.4x 并淡出，后 30% 停顿（alpha=0 天然隐形）
                if index == todayIndex, isCurrentWeek {
                    let ping = min(blinkPhase / 0.7, 1)
                    let ease = 1 - (1 - ping) * (1 - ping)
                    let ringRadius = radius * (1 + 1.4 * ease)
                    let ringAlpha = 0.65 * pow(1 - ping, 1.5)
                    let ring = NSBezierPath(ovalIn: NSRect(x: point.x - ringRadius,
                                                           y: point.y - ringRadius,
                                                           width: ringRadius * 2,
                                                           height: ringRadius * 2))
                    // 动态色 + 随相位变化的 alpha：withAlphaComponent 不保证保留动态解析，
                    // 改用图形上下文全局 alpha（draw 内上下文外观即本视图 effectiveAppearance）
                    NSGraphicsContext.current?.cgContext.setAlpha(ringAlpha)
                    dotPeakColor.setStroke()
                    ring.lineWidth = max(0.8, 2.6 * (1 - ping))
                    ring.stroke()
                    NSGraphicsContext.current?.cgContext.setAlpha(1)
                }
            }

            // 数值标注：本周标当日数值（与高亮日期同一列）；历史周标峰值天数值，其余天不标
            let annotateIndex = isCurrentWeek ? todayIndex : (values.firstIndex(of: maxValue) ?? -1)
            if annotateIndex >= 0 {
                let valueText = texts[annotateIndex]
                if valueText != "—" {
                    let valueWidth = valueText.size(withAttributes: [.font: axisFont]).width
                    let x = min(max(plot.minX, points[annotateIndex].x - valueWidth / 2),
                                plot.maxX - valueWidth)
                    let y = max(26, points[annotateIndex].y - 17)
                    drawText(valueText, at: NSPoint(x: x, y: y), font: axisFont,
                             color: Palette.chartValueColor)
                }
            }
        } else {
            let empty = isCurrentWeek ? "本周暂无历史用量" : "该周暂无用量记录"
            let emptyWidth = empty.size(withAttributes: [.font: detailFont]).width
            drawText(empty, at: NSPoint(x: plot.midX - emptyWidth / 2, y: plot.midY - 6),
                     font: detailFont, color: secondaryColor)
        }

        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        // 日期轴跟随浏览页：历史周从「本周一 - 7×offset」起算
        let start = calendar.date(byAdding: .day, value: -7 * safeOffset, to: currentWeekStart) ?? currentWeekStart
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M/d"
        for index in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: index, to: start) else { continue }
            let label = formatter.string(from: date)
            let width = label.size(withAttributes: [.font: axisFont]).width
            // 日期逆时针旋转 45°：先沿文本方向平移 -width/2 让文字光学中心对准贯穿线
            let anchorX = plot.minX + plot.width * CGFloat(index) / 6
            let anchorY = plot.maxY + 10
            let labelColor: NSColor = index == todayIndex && isCurrentWeek
                ? Palette.cardForeground
                : .systemGray
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            ctx?.translateBy(x: anchorX, y: anchorY)
            // AppKit 视图坐标 y 向上、文本绘制方向向右，逆时针 = 负角度旋转
            ctx?.rotate(by: -.pi / 4)
            drawText(label, at: NSPoint(x: -width / 2, y: 0), font: axisFont, color: labelColor)
            ctx?.restoreGState()
        }
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        text.draw(at: point, withAttributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    /// 圆头细线书名号箭头（‹ ›）：与表头文本同层级的中性图形，不用位图 icon
    private func drawChevron(in rect: NSRect, pointingRight: Bool, color: NSColor) {
        let path = NSBezierPath()
        let midX = rect.midX
        let midY = rect.midY
        let halfH: CGFloat = 4
        let halfW: CGFloat = 2
        if pointingRight {
            path.move(to: NSPoint(x: midX - halfW + 0.5, y: midY - halfH))
            path.line(to: NSPoint(x: midX + halfW - 0.5, y: midY))
            path.line(to: NSPoint(x: midX - halfW + 0.5, y: midY + halfH))
        } else {
            path.move(to: NSPoint(x: midX + halfW - 0.5, y: midY - halfH))
            path.line(to: NSPoint(x: midX - halfW + 0.5, y: midY))
            path.line(to: NSPoint(x: midX + halfW - 0.5, y: midY + halfH))
        }
        color.setStroke()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// 品牌图标的前景色单色版本（与用量行 icon 同款配色，保证深色 popover 上可见）。
    /// 用 sourceAtop 把原始形状着色，不改变 alpha 通道。
    private func tintedIcon(_ icon: NSImage, color: NSColor, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: false, hints: nil)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// 在面积路径内绘制固定锚点的白→白透明垂直渐变（顶部 40% 白向下渐变到 2% 白）。
    private func fillAreaGradient(_ area: NSBezierPath, in plot: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            Palette.chartAreaTop.cgColor,
            Palette.chartAreaBottom.cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors,
                                        locations: [0, 1]) else { return }
        context.saveGState()
        area.addClip()
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: plot.midX, y: plot.minY),
                                   end: CGPoint(x: plot.midX, y: plot.maxY),
                                   options: [])
        context.restoreGState()
    }

    /// 根据已有数据文本保留货币前缀、百分号和小数位，格式化纵轴刻度。
    private func axisValueText(_ value: Double, sample: String, preserveFraction: Bool) -> String {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstNumber = trimmed.firstIndex(where: { $0.isNumber || $0 == "." || $0 == "-" }),
              let lastNumber = trimmed.lastIndex(where: { $0.isNumber }) else {
            return String(format: "%.0f", value)
        }

        let prefix = String(trimmed[..<firstNumber])
        let suffix = String(trimmed[trimmed.index(after: lastNumber)...])
        let numericSample = String(trimmed[firstNumber...lastNumber])
        let sampleDecimals: Int
        if let decimalIndex = numericSample.lastIndex(of: ".") {
            sampleDecimals = numericSample[numericSample.index(after: decimalIndex)...].count
        } else {
            sampleDecimals = 0
        }
        let decimals: Int
        if suffix.contains("%") {
            // 百分比纵坐标不显示小数
            decimals = 0
        } else {
            decimals = max(sampleDecimals, preserveFraction ? 1 : 0)
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        let fallback = decimals == 0 ? String(Int(value.rounded())) : String(value)
        let number = formatter.string(from: NSNumber(value: value)) ?? fallback
        return prefix + number + suffix
    }

    /// 用分段三次 Bézier 曲线连接数据点：曲线经过每个数据点，且相邻段在点位处保持连续切线。
    /// smoothness 控制弯曲强度：0 = 直线折线，1 = 完全平滑（控制点拉到相邻段中点）。
    private func appendSmoothSegments(_ points: [NSPoint], to path: NSBezierPath,
                                      movesToFirst: Bool = false) {
        guard let first = points.first else { return }
        if movesToFirst {
            path.move(to: first)
        } else {
            path.line(to: first)
        }
        guard points.count > 1 else { return }

        let smoothness: CGFloat = 0.6
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let middleX = (start.x + end.x) / 2
            // 控制点在中点与端点之间按 smoothness 插值：值越小曲线越贴近直线
            let cp1X = middleX + (start.x - middleX) * (1 - smoothness)
            let cp2X = middleX + (end.x - middleX) * (1 - smoothness)
            path.curve(to: end,
                       controlPoint1: NSPoint(x: cp1X, y: start.y),
                       controlPoint2: NSPoint(x: cp2X, y: end.y))
        }
    }
}

/// 一周用量面积图的原生 popover 控制器。
final class UsageHistoryPopoverController: NSViewController {
    private let chartView = UsageHistoryChartView()
    private let backgroundView = TintedVisualEffectView(frame: .zero)
    /// 子面板内容左右各留 2pt，避免图表贴边，同时保持高度和箭头定位不变。
    private let horizontalContentInset: CGFloat = 2
    /// 左侧额外缩进：在基础 inset 上再内推 4pt，让标题/图表更远离容器左缘。
    private let leadingExtraInset: CGFloat = 4
    var onHoverChanged: ((Bool) -> Void)?
    var panelGradientEnabled = true {
        didSet { applyPanelBackground() }
    }
    /// 浅色主题开关：开启即强制浅色外观（优先级高于渐变，主面板切换时同步）
    var lightThemeEnabled = false {
        didSet { applyPanelBackground() }
    }
    /// 主面板当前生效的背景遮罩色（含渐变开关状态）：子弹窗继承同一配色
    var panelTintColor: NSColor? = Palette.containerTint {
        didSet { applyPanelBackground() }
    }
    var panelTintBottomColor: NSColor? = Palette.containerTintBottom {
        didSet { applyPanelBackground() }
    }
    /// Mono 字体开关：图表内文本（标题/刻度/日期）与数值随开关切换字体
    var monoFontEnabled = false {
        didSet { chartView.monoFontEnabled = monoFontEnabled }
    }

    override func loadView() {
        backgroundView.material = .menu
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.isEmphasized = false
        // 外观统一走 Palette.panelAppearance：浅色主题强制浅色；其余（含渐变开）跟随系统
        backgroundView.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                            gradientOn: panelGradientEnabled)
        backgroundView.tintColor = panelTintColor
        backgroundView.tintBottomColor = Palette.gradientEffective(lightTheme: lightThemeEnabled,
                                                                   gradientOn: panelGradientEnabled)
            ? panelTintBottomColor : nil
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = Palette.cardCornerRadius
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.masksToBounds = true

        chartView.onHoverChanged = { [weak self] inside in
            self?.onHoverChanged?(inside)
        }
        chartView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(chartView)
        NSLayoutConstraint.activate([
            // macOS 14+ 的 hasFullSizeContent 会把背景延伸到箭头区域，
            // 图表本身留在 safe area 内，避免内容被箭头区域改变尺寸。
            chartView.leadingAnchor.constraint(equalTo: backgroundView.safeAreaLayoutGuide.leadingAnchor,
                                               constant: horizontalContentInset + leadingExtraInset),
            chartView.trailingAnchor.constraint(equalTo: backgroundView.safeAreaLayoutGuide.trailingAnchor,
                                                constant: -horizontalContentInset),
            chartView.topAnchor.constraint(equalTo: backgroundView.safeAreaLayoutGuide.topAnchor),
            chartView.bottomAnchor.constraint(equalTo: backgroundView.safeAreaLayoutGuide.bottomAnchor),
        ])
        let chartSize = chartView.intrinsicContentSize
        preferredContentSize = NSSize(width: chartSize.width + horizontalContentInset * 2 + leadingExtraInset,
                                      height: chartSize.height)
        view = backgroundView
    }

    func update(row: UsageRowSnapshot) {
        chartView.row = row
    }

    private func applyPanelBackground() {
        guard isViewLoaded else { return }
        // 外观随开关即时切换：统一走 Palette.panelAppearance（浅色强制浅色，其余跟随系统）
        backgroundView.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                            gradientOn: panelGradientEnabled)
        backgroundView.tintColor = panelTintColor
        backgroundView.tintBottomColor = Palette.gradientEffective(lightTheme: lightThemeEnabled,
                                                                   gradientOn: panelGradientEnabled)
            ? panelTintBottomColor : nil
    }
}

/// 用于 NSPopover 的透明定位点：避免把超出标题 bounds 的 positioningRect 直接交给 AppKit，
/// 在部分 macOS 版本上会导致 popover 不展示。
final class UsageHistoryPopoverAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 卡片进度条（2026-09-02 由 9 方块点阵改造为渐变进度条，旧实现备份于
/// backups/UsagePanel.swift.bak-20260902-dots-progressbar）：
/// 灰色胶囊轨道（Palette.dotsDim）+ 蓝色左→右渐变填充（systemBlue alpha 0.10→0.80），
/// ratio 表示剩余比例（填充宽 = 轨道宽 × ratio），变化走 0.25s ease-in-out 宽度动画。
/// pulsing=true 时填充层以 2s 周期透明度呼吸（0.55↔1.0），示意额度正在被消耗。
/// 脉冲状态由外部（makePanelSnapshot）传入，不自行比较，避免被面板操作重置。
/// 类名与 API（ratio / pulsing / intrinsicContentSize）沿用 UsageDots，调用点零改动；
/// 尺寸适配原点阵槽位：固有宽 45.54pt（9×5.06）、槽高 7pt（外部 heightAnchor 固定），
/// 条高 5.06pt（原方块边长）在槽内垂直居中，胶囊圆角 = 条高/2。
final class UsageDots: NSView {
    var ratio: CGFloat = 0 { didSet { updateProgress() } }
    var pulsing: Bool = false {
        didSet {
            guard oldValue != pulsing else { return }
            updatePulse()
        }
    }

    // ── 尺寸：沿用原点阵口径（9 方块 × 5.06pt = 45.54pt 宽；7pt 槽高由外部约束固定）──
    private static let barHeight: CGFloat = 5.06
    private static let barWidth: CGFloat = 9 * 5.06   // 45.54
    /// 轨道透明度（dotsDim 再乘此系数：深 systemGray@0.75→0.34 / 浅 systemGray→0.45）
    private static let trackAlpha: CGFloat = 0.45
    /// 填充蓝（比 systemBlue 更亮的亮蓝 #409CFF，sRGB 所见即所得）
    private static let brightBlue = NSColor(srgbRed: 0x40/255.0, green: 0x9C/255.0, blue: 0xFF/255.0, alpha: 1)

    /// 灰色背景轨道
    private let trackLayer = CALayer()
    /// 蓝色渐变填充
    private let progressLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        wantsLayer = true
        guard let rootLayer = layer else { return }
        trackLayer.masksToBounds = true
        rootLayer.addSublayer(trackLayer)
        // 左 → 右
        progressLayer.startPoint = CGPoint(x: 0, y: 0.5)
        progressLayer.endPoint = CGPoint(x: 1, y: 0.5)
        progressLayer.masksToBounds = true
        rootLayer.addSublayer(progressLayer)
        applyColors()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 窗口落定后生效外观才稳定，重着色一次（动态色落 CALayer 会定格外观）
        applyColors()
    }
    /// 动态色（dotsDim / systemBlue）落 CALayer 会定格外观：主题切换时按视图生效外观重着色
    /// （须走 Palette.borderCGColor 解算，勿直接 .cgColor——面板强制 aqua 与系统外观可能不一致）
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
    override func layout() {
        super.layout()
        layoutBar()
    }
    /// 首次布局前 bounds 为零：跳过（intrinsicContentSize 驱动 Auto Layout 随后到位）
    private func layoutBar() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let barRect = barFrame()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = barRect
        trackLayer.cornerRadius = barRect.height / 2
        progressLayer.frame = CGRect(x: 0, y: barRect.minY,
                                     width: barRect.width * ratio, height: barRect.height)
        progressLayer.cornerRadius = barRect.height / 2
        CATransaction.commit()
    }
    /// 条框：全宽（= 固有宽 45.54）、高 5.06 垂直居中于 7pt 槽
    private func barFrame() -> CGRect {
        let h = min(Self.barHeight, bounds.height)
        return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }
    /// 轨道/渐变按「视图生效外观」解算落 layer（直接 .cgColor 会定格错主题分支）
    private func applyColors() {
        guard trackLayer.superlayer != nil else { return }
        let blue = Self.brightBlue
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.backgroundColor = Palette.borderCGColor(Palette.dotsDim.withAlphaComponent(Self.trackAlpha), in: self)
        progressLayer.colors = [
            Palette.borderCGColor(blue.withAlphaComponent(0.30), in: self),
            Palette.borderCGColor(blue.withAlphaComponent(0.95), in: self),
        ]
        CATransaction.commit()
    }
    private func updateProgress() {
        // 填充跨过零界（0 ↔ >0）时刷新脉冲目标：全空时脉冲无落点，恢复有填充须重挂
        let hasFill = ratio > 0
        if hasFill != lastHasFill {
            lastHasFill = hasFill
            updatePulse()
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let barRect = barFrame()
        let newWidth = barRect.width * ratio
        let newFrame = CGRect(x: 0, y: barRect.minY, width: newWidth, height: barRect.height)

        // 模型值无动画直落（含首次设置），动画单独挂 presentation 补间
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.frame = newFrame
        CATransaction.commit()

        // 首帧（无 presentation）从模型值出发无可见跳变，直接返回
        guard progressLayer.presentation() != nil else { return }
        // 当前显示中的宽度
        let currentWidth = progressLayer.presentation()?.frame.width ?? newWidth
        guard abs(currentWidth - newWidth) > 0.5 else { return }
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = currentWidth
        animation.toValue = newWidth
        animation.duration = 0.25
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        progressLayer.add(animation, forKey: "progress")
    }
    private var lastHasFill = false
    private func updatePulse() {
        progressLayer.removeAnimation(forKey: "pulseGroup")
        progressLayer.opacity = 1.0
        guard pulsing, ratio > 0 else { return }
        // 填充层脉冲：2s 周期透明度呼吸（沿用点阵口径 0.55↔1.0）
        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.values = [0.55, 1.0, 0.55]
        opacityAnim.keyTimes = [0, 0.5, 1.0]
        opacityAnim.duration = 2.0
        opacityAnim.repeatCount = .infinity
        opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        progressLayer.add(opacityAnim, forKey: "pulseGroup")
    }
    override var intrinsicContentSize: NSSize {
        // 宽度沿用点阵口径（9×5.06=45.54）；高度默认 7.0pt，实际由外部 heightAnchor 约束决定
        return NSSize(width: Self.barWidth, height: 7.0)
    }
}

// MARK: - BalancePanelView 用量扩展

extension BalancePanelView {

    /// 用量表头行：「1小时 / 今日 / 本周」列名，右对齐固定列宽，与下方数值上下对齐
    func makeUsageHeaderRow() -> NSView {
        func headerLabel(_ text: String, width: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            registerFont(l, size: SmallTable.titleSize, weight: SmallTable.titleWeight)
            l.textColor = SmallTable.textColor
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: width).isActive = true
            return l
        }
        // 左列名「平台」左对齐（与下方 icon 左缘同起点），右侧三列列名右对齐
        let platformHeader = NSTextField(labelWithString: "平台")
        registerFont(platformHeader, size: SmallTable.titleSize, weight: SmallTable.titleWeight)
        platformHeader.textColor = SmallTable.textColor
        let row = NSStackView(views: [platformHeader, stretchSpacer(),
                                      headerLabel("1H", width: usageColWidths.hour),
                                      headerLabel("1D", width: usageColWidths.today),
                                      headerLabel("1W", width: usageColWidths.week)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = usageColumnSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: usageHorizontalInset),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -usageHorizontalInset),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: usageRowTopInset),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -usageRowBottomInset),
        ])
        return container
    }

    /// 1小时/日/周用量行：品牌 icon + 平台名 + 右侧三列数值（固定列宽右对齐，对齐表头）
    func makeUsageRow(_ row: UsageRowSnapshot) -> NSView {
        let usageIconSize: CGFloat = 10
        let iconView = NSImageView()
        iconView.image = bundleIcon(row.icon, size: usageIconSize) ?? Self.trimmedSymbolImage("app.fill", size: usageIconSize)
        iconView.image?.isTemplate = true
        iconView.contentTintColor = .systemGray
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 10).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let nameLabel = NSTextField(labelWithString: row.name)
        registerFont(nameLabel, size: SmallTable.rowSize, weight: SmallTable.rowWeight)
        nameLabel.textColor = SmallTable.textColor
        func valueLabel(_ text: String, width: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            registerFont(l, size: SmallTable.rowSize, weight: SmallTable.rowWeight, monoDigits: true)
            l.textColor = SmallTable.textColor
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: width).isActive = true
            return l
        }
        let rowStack = NSStackView(views: [iconView, nameLabel, stretchSpacer(),
                                           valueLabel(row.hourText, width: usageColWidths.hour),
                                           valueLabel(row.todayText, width: usageColWidths.today),
                                           valueLabel(row.weekText, width: usageColWidths.week)])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = usageColumnSpacing
        // icon↔标题 4pt、标题↔数值区 6pt（平台列整体收紧）；
        // 数值三列之间保持 8pt 列距节奏，表头右缘与数值列右缘锚 trailing 对齐不受影响
        rowStack.setCustomSpacing(4, after: iconView)
        rowStack.setCustomSpacing(6, after: nameLabel)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        // 位移动画需要 layer-backed
        rowStack.wantsLayer = true
        // 用量条目 hover：整行渐变背景 + 发丝边框（与余额卡片/磁贴/折叠标题条同一套 Palette）；
        // 行内容常态系统灰，hover 时文字/icon 提亮（HoverRowView 内建：文字→hoverTextColor、
        // 灰 tint 图标→labelColor；退出回落 systemGray；hover 锁定期间保持提亮）
        let hoverRow = wrapHoverRow(rowStack, hoverTextColor: Palette.cardForeground,
                                    horizontalPadding: usageHorizontalInset,
                                    topInset: usageRowTopInset,
                                    bottomInset: usageRowBottomInset)
        hoverRow.hoverGradientColors = Palette.hoverGradient
        // 发丝边框：与余额卡片 HoverCard 同款（白@20%→白@35%，0.8pt，0.22s）
        hoverRow.enablesHoverBorder = true
        hoverRow.wantsLayer = true
        hoverRow.onHoverChanged = { [weak self, weak hoverRow] inside in
            guard let self else { return }
            if inside {
                self.showUsageHistory(row: row, from: hoverRow)
            } else {
                self.usageHistoryRowHovered = false
                self.scheduleUsageHistoryClose()
            }
        }
        // 行内左/右键点击映射到子面板周切换：左键 = 过去周（‹），右键 = 回到本周（›）
        hoverRow.onLeftClick = { [weak self, weak hoverRow] in
            self?.shiftUsageHistoryWeek(row: row, from: hoverRow, delta: 1)
        }
        hoverRow.onRightClick = { [weak self, weak hoverRow] in
            self?.shiftUsageHistoryWeek(row: row, from: hoverRow, delta: -1)
        }
        return hoverRow
    }

    /// 用量行左右键点击 → 子面板周浏览页步进（delta>0 去过去周，delta<0 回本周）。
    /// 子面板按 platform 匹配当前锚定行；未打开/平台不符时先弹出该行子面板再切换。
    private func shiftUsageHistoryWeek(row: UsageRowSnapshot, from anchor: NSView?, delta: Int) {
        guard let controller = usageHistoryController,
              let chartView = controller.view.subviews.first(where: { $0 is UsageHistoryChartView })
                as? UsageHistoryChartView,
              chartView.row?.platform == row.platform,
              row.historyWeeks.count > 1 else {
            // 子面板未打开或已切到其他平台：先按当前行弹出，本周页起步
            showUsageHistory(row: row, from: anchor)
            return
        }
        let target = chartView.weekOffset + delta
        if target >= 0, target < row.historyWeeks.count {
            chartView.weekOffset = target
        }
    }

    /// 沿 superview 链向上找主面板的背景容器（TintedVisualEffectView），
    /// 读取其当前 tintColor/tintBottomColor 供子弹窗继承
    static func findPanelContainer(from view: NSView) -> TintedVisualEffectView? {
        var current: NSView? = view
        while let v = current {
            if let tinted = v as? TintedVisualEffectView { return tinted }
            current = v.superview
        }
        return nil
    }

    /// 用量子面板背景配色 → 主面板当前生效值（渐变/浅色/系统主题切换时的重同步入口）：
    /// 优先拷贝主面板容器当前生效实色，容器查找失败按 Palette.containerColors 兜底
    /// （lightTint 与 Token 子面板同口径：浅色主题开关开或生效外观为浅色）
    func syncUsageHistoryPanelBackground() {
        guard let controller = usageHistoryController else { return }
        controller.panelGradientEnabled = panelGradientEnabled
        controller.lightThemeEnabled = lightThemeEnabled
        if let container = Self.findPanelContainer(from: self) {
            controller.panelTintColor = container.tintColor
            controller.panelTintBottomColor = container.tintBottomColor
        } else {
            let colors = Palette.containerColors(
                lightTint: lightThemeEnabled || !effectiveAppearance.isDark,
                gradientOn: panelGradientEnabled)
            controller.panelTintColor = colors.top
            controller.panelTintBottomColor = colors.bottom
        }
        usageHistoryPopover?.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                                  gradientOn: panelGradientEnabled)
    }

    private func showUsageHistory(row: UsageRowSnapshot, from anchor: NSView?) {
        guard let anchor, anchor.window != nil else { return }
        // 标题尚未完成挂窗或正在重建时先回退到当前行，避免 hover 事件被直接吞掉。
        // 正常状态始终使用标题作为固定定位锚点。
        let fixedAnchor: NSView
        if let title = usageTitleRef, title.window != nil, !title.isHidden {
            fixedAnchor = title
        } else {
            fixedAnchor = anchor
        }
        usageHistoryCloseTask?.cancel()
        usageHistoryRowHovered = true
        // 锚定行锁定 hover 高亮：子面板打开期间行保持高亮（跨行切换时旧行解锁、新行锁定）
        if usageHistoryAnchorRow !== anchor {
            usageHistoryAnchorRow?.setHoverLocked(false)
            (anchor as? HoverRowView)?.setHoverLocked(true)
            usageHistoryAnchorRow = anchor as? HoverRowView
        }

        if usageHistoryPopover == nil {
            let controller = UsageHistoryPopoverController()
            controller.onHoverChanged = { [weak self] inside in
                guard let self else { return }
                self.usageHistoryChartHovered = inside
                if inside {
                    self.usageHistoryCloseTask?.cancel()
                } else {
                    self.scheduleUsageHistoryClose()
                }
            }
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            // 三角箭头由 NSPopover 窗口本身绘制，外观与主面板同策略：
            // 统一走 Palette.panelAppearance（浅色强制浅色，其余跟随系统）
            popover.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                         gradientOn: panelGradientEnabled)
            // 让内容背景延伸覆盖系统三角箭头区域，箭头与主面板背景保持一致。
            popover.hasFullSizeContent = true
            // hover 反馈需要即时出现；跨行切换时也不让系统 popover 动画制造延迟感。
            popover.animates = false
            popover.contentViewController = controller
            _ = controller.view // 兼容 macOS 12：访问 view 会触发一次懒加载
            // 自定义背景容器没有可靠的 intrinsicContentSize，显式设置避免 popover 变成零尺寸。
            popover.contentSize = controller.preferredContentSize
            usageHistoryController = controller
            usageHistoryPopover = popover
        }

        let anchorChanged = usageHistoryAnchor !== fixedAnchor
        usageHistoryAnchor = fixedAnchor
        // 背景/字体开关与主面板保持一致（主题/渐变切换时的唯一重同步入口，见下方同名方法）
        syncUsageHistoryPanelBackground()
        // Mono 开关在面板打开期间切换时，子弹窗是懒创建的——每次 show 前同步当前状态
        usageHistoryController?.monoFontEnabled = monoFontEnabled
        // 外观与渐变/浅色开关每次 show 前重设（开关可能在面板存在期间切换：深色 ↔ 浅色玻璃）
        usageHistoryPopover?.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                                  gradientOn: panelGradientEnabled)
        let wasShown = usageHistoryPopover?.isShown == true
        usageHistoryController?.update(row: row)
        usageHistoryChartHovered = false
        if !wasShown || anchorChanged {
            if wasShown { usageHistoryPopover?.close() }
            // 在主面板内部放置一个有效定位点：popover 默认以定位点中心对齐，
            // 将定位点放在标题顶边下方半个图表高度处，即可让子面板顶边与标题顶边同高。
            let chartSize = usageHistoryController?.preferredContentSize
                ?? NSSize(width: 240, height: 158)
            let titleRect = fixedAnchor.convert(fixedAnchor.bounds, to: self)
            let anchorCenterY = titleRect.maxY - chartSize.height / 2
            // 弹出方向：默认锚点在面板内容右缘、向右弹出（preferredEdge .maxX）；
            // 面板贴近屏幕右缘、右侧剩余空间不足一个弹窗宽度时，锚点移到面板左缘、
            // 翻转为向左弹出，避免 NSPopover 被屏幕边缘 clamp 后与面板重叠。
            var edge: NSRectEdge = .maxX
            var anchorX = min(max(self.bounds.minX + 1, titleRect.maxX - 2), self.bounds.maxX - 1)
            if let visible = self.window?.screen?.visibleFrame,
               let window = self.window,
               visible.maxX - window.frame.maxX < chartSize.width + 16 {
                edge = .minX
                anchorX = min(max(self.bounds.minX + 1, titleRect.minX + 1), self.bounds.maxX - 1)
            }
            // 位置点必须留在文档视图 bounds 内，落到 scroll view 裁剪边界外时
            // NSPopover 会静默不展示。
            let anchorY = min(max(self.bounds.minY + 1, anchorCenterY), self.bounds.maxY - 1)
            usageHistoryPositionAnchor.frame = NSRect(x: anchorX,
                                                       y: anchorY - 0.5,
                                                       width: 1, height: 1)
            usageHistoryPositionAnchor.isHidden = false
            usageHistoryPositionAnchor.superview?.layoutSubtreeIfNeeded()

            let presentPopover: () -> Void = { [weak self, weak fixedAnchor, edge] in
                guard let self, let historyPopover = self.usageHistoryPopover else { return }
                if self.usageHistoryPositionAnchor.window != nil {
                    historyPopover.show(relativeTo: self.usageHistoryPositionAnchor.bounds,
                                        of: self.usageHistoryPositionAnchor, preferredEdge: edge)
                } else if let fixedAnchor {
                    // 布局切换的瞬间定位点可能尚未挂窗；使用标题自身 bounds 内的 1pt
                    // 定位矩形兜底，避免 hover 时整次弹出被吞掉。
                    let titleBounds = fixedAnchor.bounds
                    let fallbackX = edge == .minX ? titleBounds.minX : max(titleBounds.minX, titleBounds.maxX - 1)
                    let fallbackRect = NSRect(x: fallbackX,
                                               y: titleBounds.midY,
                                               width: 1, height: 1)
                    historyPopover.show(relativeTo: fallbackRect,
                                        of: fixedAnchor, preferredEdge: edge)
                }
            }
            presentPopover()
            // mouseEntered 可能与主面板重排处于同一事件周期；如果 AppKit 首次调用
            // 没有创建窗口，下一轮立即重试，不引入可感知的 hover 延迟。
            if usageHistoryPopover?.isShown != true {
                DispatchQueue.main.async { [weak self] in
                    guard self?.usageHistoryRowHovered == true else { return }
                    presentPopover()
                }
            }
        }
    }

    private func scheduleUsageHistoryClose() {
        usageHistoryCloseTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.usageHistoryRowHovered,
                  !self.usageHistoryChartHovered else { return }
            self.dismissUsageHistoryPopover()
        }
        usageHistoryCloseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    /// 面板内容重建或 popover 关闭时清理趋势图窗口与 hover 状态。
    func dismissUsageHistoryPopover() {
        usageHistoryCloseTask?.cancel()
        usageHistoryCloseTask = nil
        usageHistoryPopover?.close()
        usageHistoryRowHovered = false
        usageHistoryChartHovered = false
        usageHistoryAnchor = nil
        // 解除锚定行的 hover 锁定（子面板消失，行高亮随之退出）
        usageHistoryAnchorRow?.setHoverLocked(false)
        usageHistoryAnchorRow = nil
    }

}

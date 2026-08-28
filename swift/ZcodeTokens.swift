// ZcodeTokens.swift — ZCode 卡片 hover 子面板：Token 用量统计
// 数据源 = 本机 ZCode 会话库 ~/.zcode/cli/db/db.sqlite（model_usage 表，每次 LLM 请求一行，
// 含 input/output/reasoning/cache 拆分）。总计口径 = input + output 相加（与 ZCode
// computed_total_tokens 一致，reasoning 是 output 子集、cache_read 是 input 子集，均不另加）。
import Cocoa
import SQLite3

// MARK: - 数据

/// 单日 token 用量（本地时区当日零点时间戳 + input+output 合计）
struct ZcodeDayUsage {
    let dayStart: TimeInterval
    let tokens: Int64
}

/// 本机 ZCode token 用量汇总（按项目分组，降序）
struct ZcodeTokenSummary {
    struct ProjectUsage {
        let name: String   // 项目名（会话目录末段）
        let tokens: Int64  // input + output
    }
    let totalTokens: Int64
    let projects: [ProjectUsage]
    let requestCount: Int64
    /// 按天用量（词元活动热力图数据源，仅含有用量的天）
    let daily: [ZcodeDayUsage]
}

enum ZcodeTokenStore {
    /// 打开策略链（WAL 库只读限制的完整覆盖）：
    /// ① 只读直开——ZCode 运行中或异常退出残留 -wal/-shm 时可附着读取（含 WAL 最新增量）；
    /// ② immutable=1——ZCode 正常退出会合并删除 -wal/-shm，此时只读连接无法为 WAL 库重建
    ///    -shm（READONLY 禁写辅助文件），prepare 报 "unable to open database file"，
    ///    immutable 跳过锁与 shm 直读主文件（干净退出后主文件即完整数据，无损失）；
    /// ③ 克隆副本兜底——把 db+-wal+-shm 复制到临时目录（APFS clonefile 秒级）再 immutable
    ///    查询，覆盖辅助文件损坏等罕见态。
    private static func query() -> ZcodeTokenSummary? {
        let path = NSHomeDirectory() + "/.zcode/cli/db/db.sqlite"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let s = queryDB(path: path, immutable: false) ?? queryDB(path: path, immutable: true) {
            return s
        }
        return querySnapshotCopy(path: path)
    }

    /// 按 plain 只读或 immutable URI 打开并聚合；任何失败返回 nil
    private static func queryDB(path: String, immutable: Bool) -> ZcodeTokenSummary? {
        var db: OpaquePointer?
        if immutable {
            let escaped = path.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? path
            guard sqlite3_open_v2("file:\(escaped)?immutable=1", &db,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
        } else {
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
        }
        defer { sqlite3_close(db) }
        return runAggregates(db: db)
    }

    /// 克隆 db 与辅助文件到临时目录后查询（immutable；副本归本进程所有，恢复/建 shm 无障碍）。
    /// APFS 上 copyItem 走 clonefile，近乎零拷贝。
    private static func querySnapshotCopy(path: String) -> ZcodeTokenSummary? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ibalance-zcode-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: path + suffix)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("db.sqlite" + suffix))
            }
            return queryDB(path: dir.appendingPathComponent("db.sqlite").path, immutable: true)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// 在已打开的连接上跑项目聚合 + 按天聚合两条 SQL
    private static func runAggregates(db: OpaquePointer?) -> ZcodeTokenSummary? {
        var projects: [ZcodeTokenSummary.ProjectUsage] = []
        var requests: Int64 = 0
        var daily: [ZcodeDayUsage] = []

        var stmt: OpaquePointer?
        // 按会话目录（项目）聚合；目录缺失的会话归入「(未知项目)」
        let projectSQL = """
            SELECT COALESCE(NULLIF(s.directory, ''), '(未知项目)') AS proj,
                   SUM(m.input_tokens) + SUM(m.output_tokens), COUNT(*)
            FROM model_usage m JOIN session s ON s.id = m.session_id
            GROUP BY s.directory
            HAVING SUM(m.input_tokens) + SUM(m.output_tokens) > 0
            ORDER BY 2 DESC
            """
        if sqlite3_prepare_v2(db, projectSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dir = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "(未知项目)"
                let tokens = sqlite3_column_int64(stmt, 1)
                requests += sqlite3_column_int64(stmt, 2)
                // 项目名 = 目录末段（(未知项目) 原样保留）
                let name = dir == "(未知项目)" ? dir : (dir as NSString).lastPathComponent
                projects.append(ZcodeTokenSummary.ProjectUsage(name: name, tokens: tokens))
            }
        }
        sqlite3_finalize(stmt)

        // 按天聚合（本地时区日界），供「词元活动」热力图
        let daySQL = """
            SELECT date(started_at/1000, 'unixepoch', 'localtime') AS day,
                   SUM(input_tokens) + SUM(output_tokens)
            FROM model_usage
            GROUP BY day
            """
        if sqlite3_prepare_v2(db, daySQL, -1, &stmt, nil) == SQLITE_OK {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.isLenient = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dayStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let tokens = sqlite3_column_int64(stmt, 1)
                if let day = fmt.date(from: dayStr), tokens > 0 {
                    daily.append(ZcodeDayUsage(dayStart: day.timeIntervalSince1970, tokens: tokens))
                }
            }
        }
        sqlite3_finalize(stmt)

        let total = projects.reduce(Int64(0)) { $0 + $1.tokens }
        return projects.isEmpty ? nil : ZcodeTokenSummary(totalTokens: total, projects: projects,
                                                          requestCount: requests, daily: daily.sorted { $0.dayStart < $1.dayStart })
    }

    private static let queue = DispatchQueue(label: "ibalance.zcodeTokens", qos: .userInitiated)
    private static var cache: (summary: ZcodeTokenSummary, at: Date)?
    private static let cacheTTL: TimeInterval = 15

    /// 异步取汇总；缓存 15s 内直接回缓存。completion 恒在主线程回调（可能为 nil）。
    static func fetch(completion: @escaping (ZcodeTokenSummary?) -> Void) {
        if let c = cache, Date().timeIntervalSince(c.at) < cacheTTL {
            completion(c.summary)
            return
        }
        queue.async {
            let s = query()
            if let s { cache = (s, Date()) }
            DispatchQueue.main.async { completion(s) }
        }
    }

    // MARK: 数值格式化

    /// 千分位完整数字（总计大数字用）：570902356 → "570,902,356"
    static func grouped(_ t: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: t)) ?? "\(t)"
    }

    /// 紧凑三位有效数字（模型行用，参考同类工具口径）：273M / 189.3M / 27.7M / 11M / 452K / 890
    static func compact(_ t: Int64) -> String {
        let v = Double(t)
        func strip(_ s: String) -> String { s.hasSuffix(".0") ? String(s.dropLast(2)) : s }
        if v >= 1e9 { return strip(String(format: "%.1f", v / 1e9)) + "B" }
        if v >= 1e8 { return String(format: "%.0f", v / 1e6) + "M" }
        if v >= 1e6 { return strip(String(format: "%.1f", v / 1e6)) + "M" }
        if v >= 1e5 { return String(format: "%.0f", v / 1e3) + "K" }
        if v >= 1e3 { return strip(String(format: "%.1f", v / 1e3)) + "K" }
        return "\(t)"
    }

    /// 中文量级（项目行数值 + 词元活动悬浮提示用）：1.23亿 / 234.5万 / 8,920
    static func cnCompact(_ t: Int64) -> String {
        let v = Double(t)
        func strip(_ s: String) -> String { s.hasSuffix(".0") ? String(s.dropLast(2)) : s }
        if v >= 1e8 { return strip(String(format: "%.2f", v / 1e8)) + "亿" }
        if v >= 1e4 { return strip(String(format: "%.1f", v / 1e4)) + "万" }
        return grouped(t)
    }
}

// MARK: - 面板视图（总计词元大数字 + 模型列表 + 词元活动热力图，draw 自绘）

final class ZcodeTokensPanelView: NSView, PanelScrollHoverSync {
    var summary: ZcodeTokenSummary? {
        didSet {
            syncTotalRoll()
            if oldValue?.totalTokens != summary?.totalTokens
                || oldValue?.projects.count != summary?.projects.count {
                invalidateIntrinsicContentSize()
            }
            needsDisplay = true
        }
    }
    /// 总计词元大数字（逐位垂直滚动；左对齐贴版心，位次与原 drawText 排版一致）
    private let totalRollView = RollingNumberView()
    /// 大数字当前字号（超宽逐级缩 26→15；字号变化才重新 configure）
    private var totalNumberSize: CGFloat = 26
    var onHoverChanged: ((Bool) -> Void)?
    /// 词元活动视图切换每日/每周时回调（控制器据此刷新 popover 尺寸）
    var onActivityModeChanged: (() -> Void)?
    var monoFontEnabled = false {
        didSet { totalRollView.refreshFont(); needsDisplay = true }
    }
    var interFontEnabled = false {
        didSet { totalRollView.refreshFont(); needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?
    /// 模型行品牌 icon 缓存（bundleIcon 每次读盘，draw 高频不能直呼）
    private var iconCache: [String: NSImage] = [:]

    // MARK: 词元活动状态

    enum ActivityMode { case daily, weekly }
    var activityMode: ActivityMode = .daily {
        didSet {
            guard oldValue != activityMode else { return }
            hoveredDot = nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
            onActivityModeChanged?()
        }
    }
    /// 热力图窗口：最近 5 个月（列 = 周，末列为今天所在周，首列对齐其所在周的周一）
    static let activityMonths = 5
    /// draw 时填充：每个可 hover 圆点的 (命中框, 悬浮文案)；mouseMoved 命中测试用
    private struct DotCell { let rect: NSRect; let tooltip: String }
    private var dotCells: [DotCell] = []
    private var hoveredDot: Int?
    /// 「每日/每周」切换文案命中区（draw 时更新）
    private var dailyToggleRect = NSRect.zero
    private var weeklyToggleRect = NSRect.zero
    /// 正圆点阵印章缓存（5 级亮度，懒建；NSImage 绘制块按需执行，避免每次 draw 重建路径）
    private var dotStamps: [NSImage?] = []

    /// 列表行数上限（超出按用量截断，头部项目已覆盖绝大多数占比）
    static let maxListRows = 7
    private static let contentWidth: CGFloat = 240
    private static let rowHeight: CGFloat = 16
    private let insets = NSEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        totalRollView.alignsLeft = true
        totalRollView.configure(size: 26, weight: .semibold, fontProvider: { [weak self] s, w, monoDigits in
            self?.totalFont(size: s, weight: w, monoDigits: monoDigits)
                ?? .monospacedDigitSystemFont(ofSize: s, weight: w)
        })
        addSubview(totalRollView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 大数字行框：与原 draw 排版同位（y = insets.top + 10 + 4，行带高 32）
    override func layout() {
        super.layout()
        totalRollView.frame = NSRect(x: insets.left, y: insets.top + 14,
                                     width: max(0, bounds.width - insets.left - insets.right),
                                     height: 32)
        // 布局就绪后复算缩字号（打开瞬间 summary 落位时 view 可能尚未布局，宽度不可判）
        if let tokens = summary?.totalTokens {
            applyTotalNumberSize(for: ZcodeTokenStore.grouped(tokens))
        }
    }

    /// 总计数字落位：nil → 占位 —；有值 → 滚动落值（结构相同=逐位滚动，
    /// 仅在数值变动时表现；位数增减/—↔数值为结构变化，整组重建直接落值）
    private func syncTotalRoll() {
        guard let tokens = summary?.totalTokens else {
            totalRollView.setText("—", animated: false)
            return
        }
        let text = ZcodeTokenStore.grouped(tokens)
        applyTotalNumberSize(for: text)
        totalRollView.setText(text, animated: true)
    }

    /// 大数字字体：系统字体态用等宽数字变体（滚轮槽宽恒定）；Mono/Inter 本身即等宽/按主面板策略
    private func totalFont(size: CGFloat, weight: NSFont.Weight, monoDigits: Bool) -> NSFont {
        if monoDigits, !monoFontEnabled, !interFontEnabled {
            return .monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
        return uiFont(size: size, weight: weight)
    }

    /// 超出可用宽度时逐级缩字号（等宽 13 位数字也能放下；与原 draw 循环同参数）。
    /// 未布局（bounds 为 0）时跳过，等 layout() 就绪后复算
    private func applyTotalNumberSize(for text: String) {
        let availWidth = bounds.width - insets.left - insets.right
        guard availWidth > 40 else { return }
        var size: CGFloat = 26
        while size > 15,
              text.size(withAttributes: [.font: uiFont(size: size, weight: .semibold)]).width > availWidth {
            size -= 1
        }
        guard size != totalNumberSize else { return }
        totalNumberSize = size
        totalRollView.configure(size: size, weight: .semibold,
                                fontProvider: { [weak self] s, w, monoDigits in
            self?.totalFont(size: s, weight: w, monoDigits: monoDigits)
                ?? .monospacedDigitSystemFont(ofSize: s, weight: w)
        })
    }

    private var activityGridHeight: CGFloat {
        activityMode == .daily ? 7 * activityPitch : activityPitch
    }
    /// 横坐标月份标签区高度（4pt 间距 + 10pt 文本）
    private var activityAxisHeight: CGFloat { 14 }
    /// 热力图列几何：窗口周列数 + 点距（可用宽均分，正圆 = 点距 - 2）。
    /// 窗口 = 最近 5 个整月：firstMonth = 4 个月前当月 1 号，start = 其所在周的周一，末列 = 今天所在周。
    private func activityWindow() -> (start: Date, cols: Int, firstMonth: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func monday(of d: Date) -> Date {
            let back = (cal.component(.weekday, from: d) + 5) % 7
            return cal.date(byAdding: .day, value: -back, to: d) ?? d
        }
        let firstOfMonth = cal.date(from: DateComponents(
            calendar: cal,
            year: cal.component(.year, from: today),
            month: cal.component(.month, from: today) - Self.activityMonths + 1,
            day: 1)) ?? today
        let start = monday(of: firstOfMonth)
        let todayMonday = monday(of: today)
        let days = cal.dateComponents([.day], from: start, to: todayMonday).day ?? 0
        return (start, days / 7 + 1, firstOfMonth)
    }
    /// 点距 = 版心宽 / 周列数（精确均分，不取整）：网格恰撑满版心，
    /// 最右点列与模型表的百分比右缘对齐；正圆 = 点距 - 2（格内四周各缩 1pt）
    private var activityPitch: CGFloat {
        let avail = Self.contentWidth - insets.left - insets.right
        return max(6, avail / CGFloat(activityWindow().cols))
    }

    override var intrinsicContentSize: NSSize {
        let rows = min(summary?.projects.count ?? 0, Self.maxListRows)
        // 标签(10) + 间距(4) + 大数字(32) + 段间距(14) + 模型标签(10) + 间距(6) + n 行
        // + 段间距(14) + 活动标签(12) + 间距(6) + 热力图(7行/1行) + 月份轴(14) + 底留白
        let height: CGFloat = 10 + 4 + 32 + 14 + 10 + 6 + CGFloat(rows) * Self.rowHeight
            + 14 + 12 + 6 + activityGridHeight + activityAxisHeight + insets.top + insets.bottom
        return NSSize(width: Self.contentWidth, height: height)
    }

    /// 按当前字体开关取字体（优先级 Mono > Inter > 系统，与面板/用量图表同策略）
    private func uiFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if monoFontEnabled { return MonoFontProvider.font(size: size, weight: weight) }
        if interFontEnabled { return InterFontProvider.font(size: size, weight: weight) }
        return .systemFont(ofSize: size, weight: weight)
    }

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
        super.mouseExited(with: event)
        if hoveredDot != nil {
            hoveredDot = nil
            needsDisplay = true
        }
        onHoverChanged?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let hit = dotCells.firstIndex { $0.rect.insetBy(dx: -1, dy: -1).contains(p) }
        if hit != hoveredDot {
            hoveredDot = hit
            needsDisplay = true
        }
    }

    /// 点击「每日/每周」文案切换词元活动视图
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        if dailyToggleRect.insetBy(dx: -3, dy: -3).contains(p) {
            activityMode = .daily
        } else if weeklyToggleRect.insetBy(dx: -3, dy: -3).contains(p) {
            activityMode = .weekly
        }
    }

    func syncHoverState(_ inside: Bool) {
        onHoverChanged?(inside)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let labelFont = monoFontEnabled
            ? MonoFontProvider.font(size: 9)
            : (interFontEnabled
                ? InterFontProvider.font(size: 9)
                : NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular))
        let labelColor = NSColor.secondaryLabelColor
        let y = insets.top

        // ── 总计词元标签（小号 + 字距）──
        drawSpacedText("总计词元", at: NSPoint(x: insets.left, y: y),
                       font: labelFont, color: labelColor, kern: 0.8)

        // ── 总计大数字：RollingNumberView 子视图渲染（layout() 定位，summary didSet 驱动滚动）──
        let numberY = y + 10 + 4

        // ── 项目区块头 ──
        let projects = Array((summary?.projects ?? []).prefix(Self.maxListRows))
        let sectionY = numberY + 32 + 14
        drawSpacedText("项目", at: NSPoint(x: insets.left, y: sectionY),
                       font: labelFont, color: labelColor, kern: 0.8)

        var listEndY = sectionY + 10 + 6
        if projects.isEmpty {
            if summary == nil {
                drawText("读取中…", at: NSPoint(x: insets.left, y: listEndY),
                         font: uiFont(size: 10), color: labelColor)
            }
        } else if let summary {
            listEndY = drawProjectRows(projects, summary: summary, topY: listEndY,
                                       nameFont: uiFont(size: 10, weight: .medium),
                                       valueFont: uiFont(size: 10, weight: .medium),
                                       pctFont: uiFont(size: 10))
        }

        drawActivitySection(topY: listEndY + 14, labelFont: labelFont, labelColor: labelColor)
    }

    /// 项目行：文件夹 icon + 项目名（限宽截断）+ token 值 + 百分比；返回行块底部 Y。
    /// 内容（icon/名/值/百分比）统一系统灰（语义色随主题适配）
    @discardableResult
    private func drawProjectRows(_ projects: [ZcodeTokenSummary.ProjectUsage], summary: ZcodeTokenSummary,
                                 topY: CGFloat, nameFont: NSFont, valueFont: NSFont,
                                 pctFont: NSFont) -> CGFloat {
        let pctColWidth: CGFloat = 45
        let valueRight = bounds.width - insets.right - pctColWidth
        // 数值固定列宽（"1234.5万" ≈ 38pt，取 40）右对齐；项目名列从数值列左缘留 8pt 起截断
        let valueColWidth: CGFloat = 40
        let valueLeft = valueRight - valueColWidth
        let nameX = insets.left + 14
        let nameColWidth = max(40, valueLeft - 8 - nameX)
        let namePs = NSMutableParagraphStyle()
        namePs.lineBreakMode = .byTruncatingTail
        let rowH = Self.rowHeight
        var rowY = topY
        for p in projects {
            let iconRect = NSRect(x: insets.left, y: rowY + (rowH - 10) / 2, width: 10, height: 10)
            if let img = projectIcon() {
                // respectFlipped:true：isFlipped 视图内保证正立（旧式 draw(in:) 不跟随翻转上下文）
                img.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            }
            let nameH = nameFont.boundingRectForFont.height
            let nameRect = NSRect(x: nameX, y: rowY + (rowH - nameH) / 2,
                                  width: nameColWidth, height: ceil(nameH))
            (p.name as NSString).draw(in: nameRect, withAttributes: [
                .font: nameFont, .foregroundColor: NSColor.systemGray, .paragraphStyle: namePs,
            ])
            let valueText = ZcodeTokenStore.cnCompact(p.tokens)
            let valueW = valueText.size(withAttributes: [.font: valueFont]).width
            let valueH = valueFont.boundingRectForFont.height
            drawText(valueText, at: NSPoint(x: valueLeft + (valueColWidth - valueW), y: rowY + (rowH - valueH) / 2),
                     font: valueFont, color: NSColor.systemGray)
            // 百分比一位小数（"69.6%"；各行四舍五入之和可能 ≠100%，属正常舍入误差）
            let pctValue = summary.totalTokens > 0
                ? Double(p.tokens) / Double(summary.totalTokens) * 100 : 0
            let pctText = String(format: "%.1f%%", pctValue)
            let pctW = pctText.size(withAttributes: [.font: pctFont]).width
            let pctH = pctFont.boundingRectForFont.height
            drawText(pctText, at: NSPoint(x: bounds.width - insets.right - pctW, y: rowY + (rowH - pctH) / 2),
                     font: pctFont, color: NSColor.systemGray)
            rowY += rowH
        }
        return rowY
    }

    // MARK: 词元活动热力图

    /// 词元活动：标题 + 每日/每周切换 + 正圆点阵（用量越多越亮）。
    /// 每日 = 7 行（周一→周日）× 26 周列；每周 = 单行 26 点（每周合计）。
    private func drawActivitySection(topY: CGFloat, labelFont: NSFont, labelColor: NSColor) {
        drawSpacedText("词元活动", at: NSPoint(x: insets.left, y: topY),
                       font: labelFont, color: labelColor, kern: 0.8)

        // 右上角切换：选中 = 主前景，未选中 = 次级灰
        let toggleFont = labelFont
        let dailyText = "每日"
        let weeklyText = "每周"
        let weeklyW = weeklyText.size(withAttributes: [.font: toggleFont]).width
        let dailyW = dailyText.size(withAttributes: [.font: toggleFont]).width
        let toggleY = topY + (10 - toggleFont.boundingRectForFont.height) / 2
        let weeklyX = bounds.width - insets.right - weeklyW
        let dailyX = weeklyX - 6 - dailyW
        drawText(weeklyText, at: NSPoint(x: weeklyX, y: toggleY), font: toggleFont,
                 color: activityMode == .weekly ? Palette.cardForeground : labelColor)
        drawText(dailyText, at: NSPoint(x: dailyX, y: toggleY), font: toggleFont,
                 color: activityMode == .daily ? Palette.cardForeground : labelColor)
        dailyToggleRect = NSRect(x: dailyX, y: topY, width: dailyW, height: 10)
        weeklyToggleRect = NSRect(x: weeklyX, y: topY, width: weeklyW, height: 10)

        // ── 点阵（全格子绘制：无用量 = 底色点，有用量 = 渐变亮点；格内四周各缩 1pt）──
        dotCells.removeAll()
        let pitch = activityPitch
        let size = pitch - 2
        let gridTop = topY + 12 + 6
        let window = activityWindow()
        let cells = activityCells()
        let maxVal = cells.map(\.tokens).max() ?? 0
        for c in cells {
            let rect = NSRect(x: insets.left + CGFloat(c.col) * pitch + 1,
                              y: gridTop + CGFloat(c.row) * pitch + 1,
                              width: size, height: size)
            let level = (c.tokens <= 0 || maxVal <= 0) ? 0
                : min(4, 1 + Int(Double(c.tokens) / Double(maxVal) * 3.999))
            stamp(level: level).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                     respectFlipped: true, hints: nil)
            dotCells.append(DotCell(rect: rect, tooltip: c.tooltip))
        }

        // ── 横坐标月份标签：从网格左缘起，按「网格宽 ÷ 月数」等距分布，文本左对齐 ──
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "M月"
        let axisY = gridTop + CGFloat(activityMode == .daily ? 7 : 1) * pitch + 4
        let segWidth = (CGFloat(window.cols) * pitch) / CGFloat(Self.activityMonths)
        for offset in 0..<Self.activityMonths {
            guard let mStart = Calendar.current.date(byAdding: .month, value: offset,
                                                     to: window.firstMonth) else { continue }
            drawText(monthFmt.string(from: mStart),
                     at: NSPoint(x: insets.left + CGFloat(offset) * segWidth, y: axisY),
                     font: labelFont, color: labelColor)
        }

        // hover 圆点：外圈高亮环 + 悬浮提示（日期 + 用量，中文量级）
        if let hi = hoveredDot, dotCells.indices.contains(hi) {
            let cell = dotCells[hi]
            let ring = cell.rect.insetBy(dx: -1.5, dy: -1.5)
            Palette.heatDotRing.setStroke()
            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = 1
            path.stroke()
            drawTooltip(for: cell, anchor: cell.rect)
        }
    }

    /// 生成热力图全格子（无用量也占位，供底色与 hover）：
    /// 每日 = 窗口周列 × 7 行逐日；每周 = 窗口周列周合计单行
    private func activityCells() -> [(col: Int, row: Int, tokens: Int64, tooltip: String)] {
        guard let summary else { return [] }
        let cal = Calendar.current
        let window = activityWindow()
        let windowStartTime = window.start.timeIntervalSince1970
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "M月d日"

        // 有用量的天 → (列,行) 聚合
        var usage: [Int: Int64] = [:]
        for d in summary.daily {
            let col = Int((d.dayStart - windowStartTime) / 86400 / 7)
            guard col >= 0, col < window.cols else { continue }
            let row = (cal.component(.weekday, from: Date(timeIntervalSince1970: d.dayStart)) + 5) % 7
            usage[col * 7 + row, default: 0] += d.tokens
        }

        var cells: [(col: Int, row: Int, tokens: Int64, tooltip: String)] = []
        if activityMode == .daily {
            for col in 0..<window.cols {
                for row in 0..<7 {
                    let day = window.start.addingTimeInterval(TimeInterval((col * 7 + row) * 86400))
                    let t = usage[col * 7 + row] ?? 0
                    cells.append((col, row, t,
                                  "\(dayFmt.string(from: day)) \(ZcodeTokenStore.cnCompact(t))"))
                }
            }
        } else {
            let rangeFmt = DateFormatter()
            rangeFmt.dateFormat = "M.d"
            for col in 0..<window.cols {
                let weekStart = window.start.addingTimeInterval(TimeInterval(col * 7 * 86400))
                let weekEnd = weekStart.addingTimeInterval(6 * 86400)
                var t: Int64 = 0
                for row in 0..<7 { t += usage[col * 7 + row] ?? 0 }
                cells.append((col, 0, t,
                              "\(rangeFmt.string(from: weekStart))–\(rangeFmt.string(from: weekEnd)) \(ZcodeTokenStore.cnCompact(t))"))
            }
        }
        return cells
    }

    /// 悬浮提示气泡：锚点圆上方居中（贴顶时改下方），画日期 + 用量
    private func drawTooltip(for cell: DotCell, anchor: NSRect) {
        let font = uiFont(size: 9)
        let textW = cell.tooltip.size(withAttributes: [.font: font]).width
        let w = ceil(textW) + 12
        let h: CGFloat = 16
        var x = anchor.midX - w / 2
        x = min(max(insets.left, x), bounds.width - insets.right - w)
        var y = anchor.minY - 4 - h
        if y < 1 { y = anchor.maxY + 4 }
        let bubble = NSRect(x: x, y: y, width: w, height: h)
        // 气泡配色动态解析（Palette 统一定义）：深色外观深底浅字，浅色外观白底黑字
        Palette.tooltipBackground.setFill()
        Palette.tooltipBorder.setStroke()
        let path = NSBezierPath(roundedRect: bubble, xRadius: 4, yRadius: 4)
        path.fill()
        path.lineWidth = 0.5
        path.stroke()
        let textH = font.boundingRectForFont.height
        drawText(cell.tooltip, at: NSPoint(x: bubble.minX + 6, y: bubble.minY + (h - textH) / 2),
                 font: font, color: Palette.cardForeground)
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        text.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    /// 带字距的小标签（总计词元 / 模型 / 词元活动）
    private func drawSpacedText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor, kern: CGFloat) {
        text.draw(at: point, withAttributes: [.font: font, .foregroundColor: color, .kern: kern])
    }

    /// 亮度第 level 级的正圆印章（懒建缓存）：0 = 无用量底色（动态色，浅色外观=浅灰），
    /// 1-4 = #313d4b→#84c3ff 线性过渡。动态色按本视图 effectiveAppearance 解算成实色
    /// 后烘焙（NSImage 位图缓存会定格颜色，主题/浅色开关切换经 viewDidChangeEffectiveAppearance
    /// 清缓存重建）
    private func stamp(level: Int) -> NSImage {
        if dotStamps.count <= level {
            dotStamps.append(contentsOf: Array(repeating: nil, count: level + 1 - dotStamps.count))
        }
        if let cached = dotStamps[level] { return cached }
        var color = Self.levelColor(level)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = color.usingColorSpace(.deviceRGB) ?? color
        }
        let size = activityPitch - 2
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
            return true
        }
        dotStamps[level] = img
        return img
    }

    private static func levelColor(_ level: Int) -> NSColor {
        if level <= 0 { return Palette.heatDotEmpty }
        let t = Double(min(level, 4) - 1) / 3
        func lerp(_ a: Int, _ b: Int) -> CGFloat {
            CGFloat(a) + (CGFloat(b) - CGFloat(a)) * CGFloat(t)
        }
        return NSColor(calibratedRed: lerp(Palette.heatLevelFrom.r, Palette.heatLevelTo.r) / 255,
                       green: lerp(Palette.heatLevelFrom.g, Palette.heatLevelTo.g) / 255,
                       blue: lerp(Palette.heatLevelFrom.b, Palette.heatLevelTo.b) / 255, alpha: 1)
    }

    /// 项目行图标：文件夹符号（统一单色化为系统灰，与行文本同色；缓存染色结果）
    private func projectIcon() -> NSImage? {
        if let cached = iconCache["__folder__"] { return cached }
        let base = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        let image = base.flatMap { tintedImage($0, .systemGray) }
        iconCache["__folder__"] = image
        return image
    }

    /// 品牌图标染色经 sourceAtop 烘进缓存图，会定格当时外观：主题切换时清缓存重染；
    /// 点阵印章（NSImage 绘制块烘焙，无用量底点 = 动态色 heatDotEmpty 浅灰/深灰）同样定格，一并清
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !iconCache.isEmpty || !dotStamps.isEmpty {
            iconCache.removeAll()
            dotStamps.removeAll()
            needsDisplay = true
        }
    }

    /// 叠色拷贝：底图 draw 后以 sourceAtop 盖前景色（保留 alpha 形状），与昵称签到角标同法
    private func tintedImage(_ base: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        color.setFill()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}

// MARK: - 子面板控制器（背景容器与用量趋势子面板同款）

final class ZcodeTokensPanelController: NSViewController {
    private let contentView = ZcodeTokensPanelView()
    private let backgroundView = TintedVisualEffectView(frame: .zero)
    /// 内容左右内边距（与用量子面板口径一致）
    private let horizontalContentInset: CGFloat = 2
    var onHoverChanged: ((Bool) -> Void)?
    /// 词元活动每日/每周切换后同步 popover 尺寸（回传新 preferredContentSize，由 BalancePanelView 接线）
    var onActivityModeChanged: ((NSSize) -> Void)?
    /// 背景配色继承自主面板（show 时经 BalancePanelView.syncTokensPanelBackground 同步）。
    /// 默认值 = 主面板渐变开配色，保证任何时序下首帧都不偏色；三个属性 didSet 即时上屏，
    /// 赋值顺序无关（渐变开关切换会连带换配色，必须走 syncTokensPanelBackground 重取色）。
    var panelGradientEnabled = true {
        didSet { applyPanelBackground() }
    }
    /// 浅色主题开关（主面板快照同步）：开启时强制浅色外观，优先于渐变
    var lightThemeEnabled = false {
        didSet { applyPanelBackground() }
    }
    var panelTintColor: NSColor? = Palette.containerTint.withAlphaComponent(0) {
        didSet { applyPanelBackground() }
    }
    var panelTintBottomColor: NSColor? = Palette.containerTint {
        didSet { applyPanelBackground() }
    }
    var monoFontEnabled = false {
        didSet { contentView.monoFontEnabled = monoFontEnabled }
    }
    var interFontEnabled = false {
        didSet { contentView.interFontEnabled = interFontEnabled }
    }

    override func loadView() {
        backgroundView.material = .menu
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.isEmphasized = false
        // 外观统一走 Palette.panelAppearance：浅色主题强制浅色；渐变开强制深色；否则跟随系统
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

        contentView.onHoverChanged = { [weak self] inside in
            self?.onHoverChanged?(inside)
        }
        contentView.onActivityModeChanged = { [weak self] in
            guard let self else { return }
            let size = self.preferredContentSize
            self.onActivityModeChanged?(size)
        }
        contentView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: backgroundView.safeAreaLayoutGuide.leadingAnchor,
                                                 constant: horizontalContentInset),
            contentView.trailingAnchor.constraint(equalTo: backgroundView.safeAreaLayoutGuide.trailingAnchor,
                                                  constant: -horizontalContentInset),
            contentView.topAnchor.constraint(equalTo: backgroundView.safeAreaLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: backgroundView.safeAreaLayoutGuide.bottomAnchor),
        ])
        let size = contentView.intrinsicContentSize
        preferredContentSize = NSSize(width: size.width + horizontalContentInset * 2,
                                      height: size.height)
        view = backgroundView
    }

    func update(summary: ZcodeTokenSummary?) {
        contentView.summary = summary
        refreshContentSize()
    }

    private func refreshContentSize() {
        let size = contentView.intrinsicContentSize
        preferredContentSize = NSSize(width: size.width + horizontalContentInset * 2,
                                      height: size.height)
    }

    private func applyPanelBackground() {
        guard isViewLoaded else { return }
        // 外观随开关即时切换：统一走 Palette.panelAppearance（浅色 > 渐变深色 > 跟随系统）
        backgroundView.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                            gradientOn: panelGradientEnabled)
        backgroundView.tintColor = panelTintColor
        backgroundView.tintBottomColor = Palette.gradientEffective(lightTheme: lightThemeEnabled,
                                                                   gradientOn: panelGradientEnabled)
            ? panelTintBottomColor : nil
    }
}

// MARK: - BalancePanelView 接线（ZCode 卡片 hover 展示/收起）

extension BalancePanelView {

    /// ZCode 卡片 hover 回调入口：进入 0.25s 后弹出（滤掉划过），离开延迟收起。
    /// anchorCard 为弱引用目标（卡片可能随快照重建被替换）。
    func zcodeCardHoverTokens(_ showing: Bool, anchorCard: NSView?) {
        tokensShowTask?.cancel()
        if showing {
            tokensCardHovered = true
            let task = DispatchWorkItem { [weak self, weak anchorCard] in
                self?.showTokensPanel(from: anchorCard)
            }
            tokensShowTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
        } else {
            tokensCardHovered = false
            scheduleTokensPanelClose()
        }
    }

    /// 主面板背景配色 → Token 子面板（单一同步入口，所有时序都走这里）：
    /// 优先拷贝主面板容器当前生效实色（含渐变开关两态；关态两色均 nil = 原生 Liquid Glass），
    /// 容器查找失败按 Palette.containerColors 重构同款配色兜底。渐变开关切换时必须经此
    /// 重取色——开关连带配色在「渐变 ↔ 纯玻璃」间变化，只翻 controller 的渐变 flag 不换色值。
    func syncTokensPanelBackground() {
        guard let controller = tokensPanelController else { return }
        controller.panelGradientEnabled = panelGradientEnabled
        controller.lightThemeEnabled = lightThemeEnabled
        if let container = Self.findPanelContainer(from: self) {
            controller.panelTintColor = container.tintColor
            controller.panelTintBottomColor = container.tintBottomColor
        } else {
            let colors = Palette.containerColors(lightTheme: lightThemeEnabled,
                                                 gradientOn: panelGradientEnabled)
            controller.panelTintColor = colors.top
            controller.panelTintBottomColor = colors.bottom
        }
        // popover 窗口外观（含箭头）同样随开关即时切换（子面板可能跨开关切换存活）：
        // 统一走 Palette.panelAppearance（浅色 > 渐变深色 > 跟随系统）
        tokensPanelPopover?.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                                gradientOn: panelGradientEnabled)
    }

    private func showTokensPanel(from card: NSView?) {
        guard tokensCardHovered, let card, card.window != nil else { return }
        tokensCloseTask?.cancel()

        if tokensPanelPopover == nil {
            let controller = ZcodeTokensPanelController()
            controller.onHoverChanged = { [weak self] inside in
                guard let self else { return }
                self.tokensPanelHovered = inside
                if inside {
                    self.tokensCloseTask?.cancel()
                } else {
                    self.scheduleTokensPanelClose()
                }
            }
            controller.onActivityModeChanged = { [weak self, weak controller] size in
                guard let self, let controller, let popover = self.tokensPanelPopover else { return }
                popover.contentSize = size
                _ = controller
            }
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            // 外观与主面板同策略：浅色 > 渐变深色 > 跟随系统（统一走 Palette.panelAppearance）
            popover.appearance = Palette.panelAppearance(lightTheme: lightThemeEnabled,
                                                        gradientOn: panelGradientEnabled)
            popover.hasFullSizeContent = true
            popover.animates = false
            popover.contentViewController = controller
            _ = controller.view
            popover.contentSize = controller.preferredContentSize
            tokensPanelController = controller
            tokensPanelPopover = popover
        }
        guard let controller = tokensPanelController, let popover = tokensPanelPopover else { return }

        // 背景/字体开关与主面板保持一致（单一同步入口，见 syncTokensPanelBackground）
        syncTokensPanelBackground()
        controller.monoFontEnabled = monoFontEnabled
        controller.interFontEnabled = interFontEnabled

        // 定位锚点：贴卡片右缘中点（右翻左逻辑与用量子面板一致）
        let cardRect = card.convert(card.bounds, to: self)
        let size = controller.preferredContentSize
        var edge: NSRectEdge = .maxX
        var anchorX = min(max(bounds.minX + 1, cardRect.maxX - 1), bounds.maxX - 1)
        if let visible = window?.screen?.visibleFrame, let window,
           visible.maxX - window.frame.maxX < size.width + 16 {
            edge = .minX
            anchorX = min(max(bounds.minX + 1, cardRect.minX + 1), bounds.maxX - 1)
        }
        let anchorY = min(max(bounds.minY + 1, cardRect.midY), bounds.maxY - 1)
        tokensPanelPositionAnchor.frame = NSRect(x: anchorX, y: anchorY - 0.5, width: 1, height: 1)
        tokensPanelPositionAnchor.isHidden = false
        tokensPanelPositionAnchor.superview?.layoutSubtreeIfNeeded()

        let present = { [weak self] in
            guard let self, let popover = self.tokensPanelPopover else { return }
            if self.tokensPanelPositionAnchor.window != nil {
                popover.show(relativeTo: self.tokensPanelPositionAnchor.bounds,
                             of: self.tokensPanelPositionAnchor, preferredEdge: edge)
            } else {
                popover.show(relativeTo: NSRect(x: card.bounds.midX, y: card.bounds.midY,
                                                width: 1, height: 1),
                             of: card, preferredEdge: edge)
            }
        }
        // 换卡片 hover 重定位：先关再弹（animates=false，无动画帧残留）
        if popover.isShown { popover.close() }
        present()
        if popover.isShown != true {
            DispatchQueue.main.async { [weak self] in
                guard self?.tokensCardHovered == true else { return }
                present()
            }
        }

        // 数据：先展示占位，再异步取最新（缓存命中时回调同步执行，内容立即落定；
        // 到达后原位更新内容与尺寸，并重同步一次背景色防展示期间主面板配色变化）
        controller.update(summary: nil)
        ZcodeTokenStore.fetch { [weak self, weak controller, weak popover] summary in
            guard let controller, let popover else { return }
            controller.update(summary: summary)
            popover.contentSize = controller.preferredContentSize
            self?.syncTokensPanelBackground()
        }
        // 打开期间低频刷新（间隔 = store 缓存 TTL，到期即真查库）：总计变化时滚动到新值
        startTokensRefreshTimer()
    }

    private func scheduleTokensPanelClose() {
        tokensCloseTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.tokensCardHovered,
                  !self.tokensPanelHovered else { return }
            self.dismissTokensPanel()
        }
        tokensCloseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    /// 打开期间每 15s（= store 缓存 TTL，到期即真查库）刷一次数据；
    /// 总计词元变化时经 RollingNumberView 从旧值滚动到新值。pop 面板已关则空转自清。
    private func startTokensRefreshTimer() {
        tokensRefreshTimer?.invalidate()
        tokensRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.tokensPanelPopover?.isShown == true,
                  let controller = self.tokensPanelController else {
                self?.tokensRefreshTimer?.invalidate()
                self?.tokensRefreshTimer = nil
                return
            }
            ZcodeTokenStore.fetch { summary in
                controller.update(summary: summary)
            }
        }
    }

    /// 面板内容重建/关闭/拖拽开始时收起子面板
    func dismissTokensPanel() {
        tokensShowTask?.cancel()
        tokensCloseTask?.cancel()
        tokensShowTask = nil
        tokensCloseTask = nil
        tokensRefreshTimer?.invalidate()
        tokensRefreshTimer = nil
        tokensPanelPopover?.close()
        tokensPanelPopover = nil
        tokensPanelController = nil
        tokensCardHovered = false
        tokensPanelHovered = false
    }
}

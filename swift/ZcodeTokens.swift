// ZcodeTokens.swift — ZCode 卡片 hover 子面板：Token 用量统计
// 数据源 = 本机 ZCode 会话库 ~/.zcode/cli/db/db.sqlite（model_usage 表，每次 LLM 请求一行，
// 含 input/output/reasoning/cache 拆分）。总计口径 = input + output 相加（与 ZCode
// computed_total_tokens 一致，reasoning 是 output 子集、cache_read 是 input 子集，均不另加）。
import Cocoa
import SQLite3

// MARK: - 数据

/// Token 数据仓通用缓存壳：首次 fetch 启动后台定时器，每 60s 重建一次缓存；
/// 之后 fetch 只回缓存（同步、零读取，面板弹出不再触发扫描/查库），首次无缓存时
/// 挂起回调、构建完成后主线程补发（含构建失败 nil，避免每次弹面板反复重试）。
final class TokenStoreCache {
    private let queue: DispatchQueue
    private let build: () -> ZcodeTokenSummary?
    private var cached: (summary: ZcodeTokenSummary?, at: Date)?
    private var pending: [(ZcodeTokenSummary?) -> Void] = []
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval = 60

    init(label: String, build: @escaping () -> ZcodeTokenSummary?) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.build = build
    }

    /// 取汇总：有缓存同步返回（主线程），无缓存挂起待构建完成回调
    func fetch(completion: @escaping (ZcodeTokenSummary?) -> Void) {
        if let c = cached {
            completion(c.summary)
            return
        }
        pending.append(completion)
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    /// 后台重建缓存并补发挂起回调（构建失败也落缓存，防反复重扫）
    private func refresh() {
        let s = build()
        cached = (s, Date())
        guard !pending.isEmpty else { return }
        let callbacks = pending
        pending.removeAll()
        DispatchQueue.main.async {
            callbacks.forEach { $0(s) }
        }
    }
}

/// Token 子面板数据源分流：ZCode 与 WorkBuddy 共用同一面板视图，仅数据仓/区块标题/行图标不同
enum TokensPanelSource {
    case zcode
    case workbuddy

    /// 面板首行标题 = 平台名
    var platformName: String { self == .zcode ? "ZCode" : "WorkBuddy" }
    /// 异步取汇总（各数据仓后台每 60s 重建缓存，fetch 只回缓存，主线程回调）
    func fetch(completion: @escaping (ZcodeTokenSummary?) -> Void) {
        switch self {
        case .zcode: ZcodeTokenStore.fetch(completion: completion)
        case .workbuddy: WBTokenStore.fetch(completion: completion)
        }
    }
}

/// 总计词元的周期口径（面板首行 5h/1d/7d/30d/All 切换）
enum TokenPeriod: Int, CaseIterable {
    case h5, d1, d7, d30, all
    var label: String { ["5h", "1d", "7d", "30d", "All"][rawValue] }
    /// 滚动时间窗（.all 无窗口 = 全量总计）
    static var windowed: [TokenPeriod] { [.h5, .d1, .d7, .d30] }
}

/// 各滚动窗口起点（秒）：5 小时前 / 今日零点 / 7 天前 / 30 天前（.all 无窗口）。
/// 周一回退算法与热力图 activityWindow 同口径 (weekday+5)%7 仅 1d 用。
enum TokenPeriodWindows {
    static func starts(now: Date = Date(), cal: Calendar = .current) -> [TokenPeriod: TimeInterval] {
        let t = now.timeIntervalSince1970
        let day = cal.startOfDay(for: now)
        return [.h5: t - 5 * 3600,
                .d1: day.timeIntervalSince1970,
                .d7: t - 7 * 86400,
                .d30: t - 30 * 86400,
                .all: 0]
    }
}

/// 单日 token 用量（本地时区当日零点时间戳 + input+output 合计）
/// Equatable：热力图 cells 缓存按 daily 数组比对失效
struct ZcodeDayUsage: Equatable {
    let dayStart: TimeInterval
    let tokens: Int64
}

/// 本机 token 用量汇总（列表行按用量降序；WB 数据源另带模型分组）
struct ZcodeTokenSummary {
    struct ProjectUsage {
        let name: String   // 项目名（会话目录末段）/ 模型名
        let tokens: Int64  // input + output
        /// 项目完整目录（模型行无此字段；nil = 不可点击打开，如「(未知项目)」）
        var path: String? = nil
    }
    let totalTokens: Int64
    let projects: [ProjectUsage]
    /// 按模型分组（仅 WB 数据源填充；ZCode 库无此聚合，空 = 列表不显示「模型」切换）
    var models: [ProjectUsage] = []
    let requestCount: Int64
    /// 按天用量（词元活动热力图数据源，仅含有用量的天）
    let daily: [ZcodeDayUsage]
    /// 各周期总计词元（5H/1D/1W/1M 首行切换；窗口起点 = TokenPeriodWindows，
    /// 数据仓构建时按当前时刻聚合，60s 重建自然滚动窗口）
    var periodTotals: [TokenPeriod: Int64] = [:]
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

    /// 在已打开的连接上跑项目聚合 + 按天聚合 + 周期总计三条 SQL
    private static func runAggregates(db: OpaquePointer?) -> ZcodeTokenSummary? {
        var projects: [ZcodeTokenSummary.ProjectUsage] = []
        var models: [ZcodeTokenSummary.ProjectUsage] = []
        var requests: Int64 = 0
        var daily: [ZcodeDayUsage] = []
        var periodTotals: [TokenPeriod: Int64] = [:]

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
                // 项目名 = 目录末段（(未知项目) 原样保留）；完整目录随行携带供点击打开
                let name = dir == "(未知项目)" ? dir : (dir as NSString).lastPathComponent
                projects.append(ZcodeTokenSummary.ProjectUsage(name: name, tokens: tokens,
                                                               path: dir == "(未知项目)" ? nil : dir))
            }
        }
        sqlite3_finalize(stmt)

        // 按模型聚合（口径与 WB 数据源一致：input + output 降序），供「项目/模型」切换
        let modelSQL = """
            SELECT model_id,
                   SUM(input_tokens) + SUM(output_tokens)
            FROM model_usage
            GROUP BY model_id
            HAVING SUM(input_tokens) + SUM(output_tokens) > 0
            ORDER BY 2 DESC
            """
        if sqlite3_prepare_v2(db, modelSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "(未知模型)"
                let tokens = sqlite3_column_int64(stmt, 1)
                models.append(ZcodeTokenSummary.ProjectUsage(name: name, tokens: tokens))
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

        // 周期总计（5h/1d/7d/30d 滚动窗口）：started_at 为毫秒，四窗口起点转毫秒后
        // 单条 CASE 求和（All = 全量总计在下方补入）；缓存每 60s 重建 → 窗口自然前移
        let starts = TokenPeriodWindows.starts()
        func ms(_ p: TokenPeriod) -> Int64 { Int64((starts[p] ?? 0) * 1000) }
        let periodSQL = """
            SELECT
              SUM(CASE WHEN started_at >= \(ms(.h5)) THEN input_tokens + output_tokens ELSE 0 END),
              SUM(CASE WHEN started_at >= \(ms(.d1)) THEN input_tokens + output_tokens ELSE 0 END),
              SUM(CASE WHEN started_at >= \(ms(.d7)) THEN input_tokens + output_tokens ELSE 0 END),
              SUM(CASE WHEN started_at >= \(ms(.d30)) THEN input_tokens + output_tokens ELSE 0 END)
            FROM model_usage
            """
        if sqlite3_prepare_v2(db, periodSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                periodTotals = [.h5: sqlite3_column_int64(stmt, 0),
                                .d1: sqlite3_column_int64(stmt, 1),
                                .d7: sqlite3_column_int64(stmt, 2),
                                .d30: sqlite3_column_int64(stmt, 3)]
            }
        }
        sqlite3_finalize(stmt)

        let total = projects.reduce(Int64(0)) { $0 + $1.tokens }
        periodTotals[.all] = total   // All = 全量总计，无窗口
        return projects.isEmpty ? nil : ZcodeTokenSummary(totalTokens: total, projects: projects,
                                                          models: models,
                                                          requestCount: requests, daily: daily.sorted { $0.dayStart < $1.dayStart },
                                                          periodTotals: periodTotals)
    }

    /// 异步取汇总：后台每 60s 重建缓存，fetch 只回缓存不触发读取
    private static let cache = TokenStoreCache(label: "ibalance.zcodeTokens") { Self.query() }
    static func fetch(completion: @escaping (ZcodeTokenSummary?) -> Void) {
        cache.fetch(completion: completion)
    }

    // MARK: 数值格式化

    /// 千分位分组格式器（static 复用：NumberFormatter 构造含 locale 数据加载，
    /// 原每次调用新建——总计落位与 cnCompact 小数值分支都走这里，draw 期间被逐格放大）
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// 千分位完整数字（总计大数字用）：570902356 → "570,902,356"
    static func grouped(_ t: Int64) -> String {
        groupedFormatter.string(from: NSNumber(value: t)) ?? "\(t)"
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
            hoveredListRow = nil
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
        didSet {
            totalRollView.refreshFont()
            // 行距随墨迹推导（大数字 ascender 同理）：字体切换后固有高度已变，需失效重排
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    /// 数据源分流（ZCode=项目 / WorkBuddy=模型）：影响区块标题与行图标
    var source: TokensPanelSource = .zcode {
        didSet { guard oldValue != source else { return }; needsDisplay = true }
    }

    // MARK: 总计周期切换（5H/1D/1W/1M）

    /// 大数字当前周期口径（默认 All，与改版前常显的全量总计一致）
    var period: TokenPeriod = .all {
        didSet {
            guard oldValue != period else { return }
            needsDisplay = true
            // 用户主动换周期：结构变化（位数增减）走整组滑移
            syncTotalRoll(slideOnRebuild: true)
        }
    }
    /// 周期切换文案命中区（draw 时更新；mouseUp 判定）
    private var periodToggleRects: [NSRect] = []

    private var trackingArea: NSTrackingArea?
    /// 模型行品牌 icon 缓存（bundleIcon 每次读盘，draw 高频不能直呼）
    private var iconCache: [String: NSImage] = [:]

    // MARK: 列表视图（项目/模型切换）

    enum ListMode { case projects, models }
    var listMode: ListMode = .projects {
        didSet {
            guard oldValue != listMode else { return }
            hoveredListRow = nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
            onActivityModeChanged?()   // 复用：切换后同步 popover 尺寸
        }
    }
    /// 列表「项目/模型」切换文案命中区（draw 时更新；无模型数据不绘制不响应）
    private var projectToggleRect = NSRect.zero
    private var modelToggleRect = NSRect.zero
    /// 当前生效的列表是否为模型视图（模型数据为空时回落项目，标题/图标/行数同源）
    private var activeListIsModels: Bool {
        listMode == .models && !(summary?.models.isEmpty ?? true)
    }
    /// 当前列表行图标符号（项目=文件夹 / 模型=芯片，随切换变化）
    private var rowIconSymbol: String { activeListIsModels ? "cpu" : "folder" }
    /// 列表行 hover 高亮索引（自绘，样式 = 用量行同款：hover 渐变背景 + 发丝边框 +
    /// 文字/icon 提亮；行命中框 draw 时回填）
    private var hoveredListRow: Int?
    private var listRowRects: [NSRect] = []
    /// 行点击打开的项目目录（与 listRowRects 同序；nil = 不可点击，如模型行/(未知项目)）
    private var listRowPaths: [String?] = []


    // MARK: 词元活动状态

    enum ActivityMode { case daily, weekly }
    var activityMode: ActivityMode = .daily {
        didSet {
            guard oldValue != activityMode else { return }
            hoveredDot = nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
            onActivityModeChanged?()
            restartDotFade()   // 点阵重挂整体同步淡入（与平台切换同款动效）
        }
    }
    /// 热力图窗口：最近 5 个月（列 = 周，末列为今天所在周，首列对齐其所在周的周一）
    static let activityMonths = 5
    /// draw 时填充：每个可 hover 圆点的命中框 + 提示文案数据（day/tipTokens）；
    /// mouseMoved 命中测试用。文案不缓存，hover 命中时按格现算（dotTooltip）
    private struct DotCell { let rect: NSRect; let day: Date; let tipTokens: Int64 }
    private var dotCells: [DotCell] = []
    /// activityCells() 结果缓存（单槽）：draw 高频（hover 移动/切换动效逐帧重绘），
    /// 输入 = summary.daily + activityMode + 窗口起点，三者不变即整表复用——
    /// 原实现每次 draw 全量重算 182 格并逐格生成日期文案
    private var activityCellsCache: (daily: [ZcodeDayUsage], mode: ActivityMode,
                                     windowStart: Date, cells: [ActivityCell])?
    /// 热力图格子（缓存单元）：几何随 pitch/bounds 在 draw 现算，这里只留数据。
    /// tokens = 亮度源（每日 = 当天用量；每周 = 周合计，列内未点亮行记 0）；
    /// day = 提示锚点日（每日 = 当天；每周 = 该列周一）；tipTokens = 提示用量
    /// （每周模式未点亮行同显周合计，与原文案口径一致）
    private struct ActivityCell {
        let col: Int
        let row: Int
        let tokens: Int64
        let day: Date
        let tipTokens: Int64
    }
    private var hoveredDot: Int?
    /// 「每日/每周」切换文案命中区（draw 时更新）
    private var dailyToggleRect = NSRect.zero
    private var weeklyToggleRect = NSRect.zero
    /// 正圆点阵印章缓存（5 级亮度，懒建；NSImage 绘制块按需执行，避免每次 draw 重建路径）
    private var dotStamps: [NSImage?] = []

    /// 列表行数上限（超出按用量截断，头部项目已覆盖绝大多数占比）
    static let maxListRows = 4
    /// 项目行点击的文件夹打开应用（用户指定 QSpace Pro；未安装回退系统默认）
    private static let folderOpenerBundleID = "com.jinghaoshe.qspace.pro"
    private static let contentWidth: CGFloat = 240
    /// 列表行距 = 行墨迹高 + 2×rowInset：文字在行带内居中后上下各留 2.5pt，
    /// 行间墨迹空隙恒 5pt，与用量表格（usageRowTop/BottomInset）同源同口径；
    /// Mono 墨迹更高时行距自动放宽
    private var rowHeight: CGFloat { rowInkHeight + 2 * SmallTable.rowInset }
    /// 区块间距（总计词元 / 列表 / 词元活动 统一 20pt）
    private static let sectionGap: CGFloat = 20
    /// 左右内容缩进：hover 子面板保持 16（原版视觉）；主面板内嵌设 8，与用量行 /
    /// 设置卡片的内容边界（usageHorizontalInset / 卡片 horizontalPadding）对齐
    var horizontalInset: CGFloat = 16
    /// 顶部内容缩进：hover 子面板保持 20（弹窗顶留白）；主面板内嵌设 4 = usageRowTopInset，
    /// 使「Token 标题 → 首行」与「用量标题 → 平台表头」的间距同口径（其余结构项两边一致：
    /// 标题行高 24 + 标题下间距 0 + 卡片 topPadding 2）
    var topInset: CGFloat = 20
    /// 底部内容缩进（月份轴墨迹之下）：hover 子面板保持 20（弹窗底留白）；主面板内嵌设 3——
    /// 视觉墨迹间隙 = 本值 + 卡片 bottomPadding 2 + 区块间距 10 + 「用量」标题条半行距 ≈5
    /// ≈ 20（sectionGap 口径，与列表 → 词元活动的间距一致），20 会让词元活动下多出一条空白
    var bottomInset: CGFloat = 20
    private var insets: NSEdgeInsets {
        NSEdgeInsets(top: topInset, left: horizontalInset, bottom: bottomInset, right: horizontalInset)
    }

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

    // MARK: 墨迹几何（区块视觉间距恒 = sectionGap）
    // 名义行框（标签 10/12、数字带 32、列表行 = 墨迹+2×rowInset 居中）自带行框留白，
    // 区块锚点全部按字体实际墨迹（boundingRect/ascender）推导，间距不掺留白

    /// 9pt 小注释字体：仅「项目/模型」「每日/每周」切换文案与热力图月份轴（非标题）
    private func makeLabelFont() -> NSFont {
        monoFontEnabled ? MonoFontProvider.font(size: 9)
            : NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    }
    /// 标签墨迹高度（9pt 小注释）
    private var labelInkHeight: CGFloat { ceil(makeLabelFont().boundingRectForFont.height) }
    /// 区块标题字体（「平台名 总计」「项目」「词元活动」）：与用量表头同款（小表格口径）
    private func makeTitleFont() -> NSFont { SmallTable.titleFont(mono: monoFontEnabled) }
    /// 标题墨迹高度（10pt semibold）
    private var titleInkHeight: CGFloat { ceil(makeTitleFont().boundingRectForFont.height) }
    /// 列表行墨迹高度（小表格行字体 10pt medium）
    private var rowInkHeight: CGFloat { ceil(SmallTable.rowFont(mono: monoFontEnabled).boundingRectForFont.height) }
    /// 大数字字体（与 totalRollView configure 同参；数字轮行带贴顶排版，墨迹底 = 带顶 + ascender）
    private var numberFont: NSFont { totalFont(size: totalNumberSize, weight: .semibold, monoDigits: true) }

    /// 总计标签顶 = 面板首行（与平台名同行）
    private var totalLabelTop: CGFloat { insets.top }
    /// 大数字行带顶（layout 与 draw 共用同一推导，防错位）；首行段高 = 标题墨迹 + 4
    private var numberRowY: CGFloat { totalLabelTop + titleInkHeight + 4 }
    /// 列表标签顶 = 数字墨迹底 + 20
    private var sectionLabelTop: CGFloat { numberRowY + numberFont.ascender + Self.sectionGap }
    /// 列表首行顶 = 区块标题墨迹底 + rowInset（叠加行内上留白 rowInset 后，
    /// 标题→首行墨迹空隙 2×rowInset = 5pt，与用量表格表头→首行同口径）
    private var listStartTop: CGFloat { sectionLabelTop + titleInkHeight + SmallTable.rowInset }
    /// 末行墨迹底（行内文字垂直居中；无行时回落列表首行顶）
    private func rowsInkBottom(rows: Int) -> CGFloat {
        rows <= 0 ? listStartTop
            : listStartTop + CGFloat(rows - 1) * rowHeight + rowHeight / 2 + rowInkHeight / 2
    }
    /// 词元活动标题顶 = 末行墨迹底 + sectionGap（draw 与 intrinsic 共用）
    private func activityTitleTop(rows: Int) -> CGFloat {
        rowsInkBottom(rows: rows) + Self.sectionGap
    }
    /// 热力图网格顶 = 活动标题墨迹底 + 6（draw 与 intrinsic 共用）
    private func activityGridTop(rows: Int) -> CGFloat {
        activityTitleTop(rows: rows) + titleInkHeight + 6
    }

    /// 大数字行框：与原 draw 排版同位（行带高 32）
    override func layout() {
        super.layout()
        // 热力图行高（7×点距）随实际版心宽变化：宽度落定/变化后失效固有尺寸，让外层
        // 按真实行高重排（宽定后高度单向收敛，无循环）；旧点阵印章一并作废重烘
        if bounds.width != lastLaidOutWidth {
            lastLaidOutWidth = bounds.width
            dotStamps.removeAll()
            invalidateIntrinsicContentSize()
        }
        totalRollView.frame = NSRect(x: insets.left, y: numberRowY,
                                     width: max(0, bounds.width - insets.left - insets.right),
                                     height: 32)
        // 布局就绪后复算缩字号（打开瞬间 summary 落位时 view 可能尚未布局，宽度不可判）
        if let text = totalDisplayText {
            applyTotalNumberSize(for: text)
        }
    }
    /// 上次布局宽度（intrinsic 高度依赖实际宽，宽度变化时需重算，见 layout()）
    private var lastLaidOutWidth: CGFloat = 0

    /// 大数字显示文本 = 当前周期窗口的总计（无数据回落 —）
    private var totalDisplayText: String? {
        summary.map { ZcodeTokenStore.grouped($0.periodTotals[period] ?? 0) }
    }

    /// 总计数字落位：nil → 占位 —；有值 → 滚动落值（结构相同=逐位滚动，
    /// 仅在数值变动时表现；位数增减默认整组重建直接落值——打开/后台刷新口径；
    /// 用户主动切周期（period didSet）传 slideOnRebuild=true，结构变化走整组滑移：
    /// 原位数缓动平移让位、新增高位从左移入/移出列随组滑出）。
    /// 面板不可见且大数字已是真实数值时挂起不下发（视图保持旧显示，最新总计随 summary 待命），
    /// 打开后由 scheduleOpenReroll 统一补发：有变化从旧值滚到新值，未变化原地不动。
    /// 占位「—」阶段不受挂起闸限制（启动预读）：首次数据到达即直接落位，打开即显示。
    /// totalDuration：整段式时长（开面板补发传 Motion.openRerollDuration）；缺省走 setText
    /// 默认预算 0.9（刷新路径口径不变）。
    /// 开面板重滚窗口截止时刻（BalancePanelView.scheduleOpenReroll 设定 / cancelOpenReroll
    /// 清除）：非 nil 且未过期时，summary didSet 的刷新路径派发按「最长轮恰好落在截止
    /// 时刻」规划时长，与 0.5s 补发同速合流；过期或 nil = 常规刷新 0.9 预算
    var openRerollDeadline: Date?

    func syncTotalRoll(slideOnRebuild: Bool = false, totalDuration: CFTimeInterval? = nil) {
        guard totalRollView.window != nil || totalRollView.currentText == "—" else { return }
        guard let text = totalDisplayText else {
            totalRollView.setText("—", animated: false)
            return
        }
        applyTotalNumberSize(for: text)
        var effectiveTotal = totalDuration
        if effectiveTotal == nil, let deadline = openRerollDeadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 { effectiveTotal = remaining }
        }
        totalRollView.setText(text, animated: true, slideOnRebuild: slideOnRebuild, totalDuration: effectiveTotal)
    }

    /// 大数字字体：系统字体态用等宽数字变体（滚轮槽宽恒定）；Mono 按主面板策略
    private func totalFont(size: CGFloat, weight: NSFont.Weight, monoDigits: Bool) -> NSFont {
        if monoDigits, !monoFontEnabled {
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
        // 字号参与锚点链（numberFont.ascender → intrinsic 高度）：变化必须同步失效
        // 固有尺寸，否则高度滞留旧值，直到下一次无关的 invalidate（如首次列表切换）
        // 才一次性落地，文档高度跳变带动面板内容肉眼位移
        invalidateIntrinsicContentSize()
        totalRollView.configure(size: size, weight: .semibold,
                                fontProvider: { [weak self] s, w, monoDigits in
            self?.totalFont(size: s, weight: w, monoDigits: monoDigits)
                ?? .monospacedDigitSystemFont(ofSize: s, weight: w)
        })
    }

    private var activityGridHeight: CGFloat { 7 * activityPitch }
    /// 横坐标月份标签区高度（4pt 间距 + 标签墨迹）
    private var activityAxisHeight: CGFloat { 4 + labelInkHeight }
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
    /// 点距 = 实际版心宽 / 周列数（精确均分，不取整）：网格恰撑满版心，
    /// 最右点列与模型表的百分比右缘对齐；正圆 = 点距 - 2（格内四周各缩 1pt）。
    /// 嵌入宽度 ≠ intrinsic 标称宽时按实际 bounds 等比放大（未布局时回退标称宽）
    private var activityPitch: CGFloat {
        let width = bounds.width > 0 ? bounds.width : Self.contentWidth
        let avail = width - insets.left - insets.right
        return max(6, avail / CGFloat(activityWindow().cols))
    }

    override var intrinsicContentSize: NSSize {
        // 行数取当前列表视图（模型视图空数据时回落项目，与 draw 的 showModels 逻辑一致）
        let active = summary.flatMap { s -> [ZcodeTokenSummary.ProjectUsage] in
            (listMode == .models && !s.models.isEmpty) ? s.models : s.projects
        } ?? []
        let rows = min(active.count, Self.maxListRows)
        // 高度 = 锚点链一路推到热力图网格顶（与 draw 同一表达式，无重复字面量）
        let height: CGFloat = activityGridTop(rows: rows)
            + activityGridHeight + activityAxisHeight + insets.bottom
        return NSSize(width: Self.contentWidth, height: height)
    }

    /// 按当前字体开关取字体（优先级 Mono > 系统，与面板/用量图表同策略）
    private func uiFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if monoFontEnabled { return MonoFontProvider.font(size: size, weight: weight) }
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
        var changed = false
        if hoveredDot != nil { hoveredDot = nil; changed = true }
        if hoveredListRow != nil { hoveredListRow = nil; changed = true }
        if changed { needsDisplay = true }
        onHoverChanged?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let hit = dotCells.firstIndex { $0.rect.insetBy(dx: -1, dy: -1).contains(p) }
        let hitRow = listRowRects.firstIndex { $0.contains(p) }
        if hit != hoveredDot || hitRow != hoveredListRow {
            hoveredDot = hit
            hoveredListRow = hitRow
            needsDisplay = true
        }
    }

    /// 置顶浮窗的拖窗实现（BalancePanelView.mouseDown）会起循环吞掉 mouseUp，
    /// 本视图未覆写 mouseDown 时事件沿 responder chain 转给拖窗 → 交互区点击全失效。
    /// 命中交互区必须就地消费 mouseDown 阻断转发；空白处仍沿链交给拖窗。
    override func mouseDown(with event: NSEvent) {
        guard !hitInteractive(convert(event.locationInWindow, from: nil)) else { return }
        super.mouseDown(with: event)
    }

    /// mouseUp 各交互判定的并集（命中口径与 mouseUp 一致）
    private func hitInteractive(_ p: NSPoint) -> Bool {
        if periodToggleRects.contains(where: { $0.insetBy(dx: -3, dy: -3).contains(p) }) { return true }
        for r in [modelToggleRect, projectToggleRect, dailyToggleRect, weeklyToggleRect]
        where r.insetBy(dx: -3, dy: -3).contains(p) { return true }
        if let row = listRowRects.firstIndex(where: { $0.contains(p) }),
           row < listRowPaths.count, listRowPaths[row] != nil { return true }
        return false
    }

    /// 点击切换：总计周期（5H/1D/1W/1M）与「每日/每周」「项目/模型」视图
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        if let hit = periodToggleRects.firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(p) }),
           let next = TokenPeriod(rawValue: hit), next != period {
            period = next
        } else if modelToggleRect.insetBy(dx: -3, dy: -3).contains(p) {
            listMode = .models
        } else if projectToggleRect.insetBy(dx: -3, dy: -3).contains(p) {
            listMode = .projects
        } else if dailyToggleRect.insetBy(dx: -3, dy: -3).contains(p) {
            activityMode = .daily
        } else if weeklyToggleRect.insetBy(dx: -3, dy: -3).contains(p) {
            activityMode = .weekly
        }
        // 点击项目行 → 优先 QSpace 打开项目目录（用户指定 com.jinghaoshe.qspace.pro）；
        // 未安装回退系统默认接口（LaunchServices 按文件夹默认处理程序分发）。
        // 模型行/(未知项目) 无路径不响应
        if let row = listRowRects.firstIndex(where: { $0.contains(p) }),
           row < listRowPaths.count, let path = listRowPaths[row] {
            let url = URL(fileURLWithPath: path)
            if let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.folderOpenerBundleID) {
                NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 可点击的项目行显示手型光标（模型行/(未知项目) 除外）
    override func resetCursorRects() {
        super.resetCursorRects()
        for (i, r) in listRowRects.enumerated()
        where i < listRowPaths.count && listRowPaths[i] != nil {
            addCursorRect(r, cursor: .pointingHand)
        }
    }

    func syncHoverState(_ inside: Bool) {
        onHoverChanged?(inside)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let labelFont = makeLabelFont()
        let labelColor = NSColor.secondaryLabelColor
        // 区块标题统一系统灰 = 小表格口径（与列表行同色；切换文案的未选中态仍用次级灰）
        let titleColor = SmallTable.textColor

        // ── 首行：平台名 + 总计（标题样式同用量表头，两段间留 4pt 间距）──
        let titleFont = makeTitleFont()
        drawText(source.platformName, at: NSPoint(x: insets.left, y: totalLabelTop),
                 font: titleFont, color: titleColor)
        let nameWidth = (source.platformName as NSString).size(withAttributes: [.font: titleFont]).width
        drawText("总计", at: NSPoint(x: insets.left + ceil(nameWidth) + 4, y: totalLabelTop),
                 font: titleFont, color: titleColor)

        // ── 首行右侧：周期切换（5H/1D/1W/1M；样式同项目/模型切换：选中主前景/未选次级灰）──
        periodToggleRects = []
        let pGap: CGFloat = 6
        let pWidths = TokenPeriod.allCases.map {
            $0.label.size(withAttributes: [.font: labelFont]).width
        }
        let pTotal = pWidths.reduce(0, +) + pGap * CGFloat(TokenPeriod.allCases.count - 1)
        var px = bounds.width - insets.right - pTotal
        let pY = totalLabelTop + (titleInkHeight - labelFont.boundingRectForFont.height) / 2
        for (i, p) in TokenPeriod.allCases.enumerated() {
            drawText(p.label, at: NSPoint(x: px, y: pY), font: labelFont,
                     color: period == p ? Palette.cardForeground : labelColor)
            periodToggleRects.append(NSRect(x: px, y: totalLabelTop,
                                            width: pWidths[i], height: titleInkHeight))
            px += pWidths[i] + pGap
        }

        // ── 总计大数字：RollingNumberView 子视图渲染（layout() 定位，summary didSet 驱动滚动）──

        // ── 列表区块头 ──（WB 双数据齐备时右上角「项目/模型」切换，样式同词元活动的每日/每周）
        let allProjects = summary?.projects ?? []
        let allModels = summary?.models ?? []
        let showModels = listMode == .models && !allModels.isEmpty
        let projects = Array((showModels ? allModels : allProjects).prefix(Self.maxListRows))
        let sectionY = sectionLabelTop
        drawText(showModels ? "模型" : "项目", at: NSPoint(x: insets.left, y: sectionY),
                 font: titleFont, color: titleColor)
        projectToggleRect = .zero
        modelToggleRect = .zero
        if !allModels.isEmpty {
            let tFont = labelFont
            let modelW = "模型".size(withAttributes: [.font: tFont]).width
            let projW = "项目".size(withAttributes: [.font: tFont]).width
            // 切换文案在标题行带内垂直居中（标题 10pt 比切换文案 9pt 高半档）
            let tY = sectionY + (titleInkHeight - tFont.boundingRectForFont.height) / 2
            let mX = bounds.width - insets.right - modelW
            let pX = mX - 6 - projW
            drawText("模型", at: NSPoint(x: mX, y: tY), font: tFont,
                     color: showModels ? Palette.cardForeground : labelColor)
            drawText("项目", at: NSPoint(x: pX, y: tY), font: tFont,
                     color: showModels ? labelColor : Palette.cardForeground)
            projectToggleRect = NSRect(x: pX, y: sectionY, width: projW, height: titleInkHeight)
            modelToggleRect = NSRect(x: mX, y: sectionY, width: modelW, height: titleInkHeight)
        }

        var listEndY = listStartTop
        listRowRects = []
        listRowPaths = []
        if projects.isEmpty {
            if summary == nil {
                drawText("读取中…", at: NSPoint(x: insets.left, y: listEndY),
                         font: SmallTable.rowFont(mono: monoFontEnabled), color: labelColor)
            }
        } else if let summary {
            // 行字体 = 用量行同款（小表格口径）：名称/百分比 medium，数值等宽数字；
            // 切换过渡期按逐行交错进度绘制(自下方 6pt 上移淡入),常态直绘零开销
            let nameFont = SmallTable.rowFont(mono: monoFontEnabled)
            let valueFont = SmallTable.rowFont(mono: monoFontEnabled, monoDigits: true)
            let pctFont = SmallTable.rowFont(mono: monoFontEnabled)
            if let start = switchTransitionStart {
                let elapsed = CACurrentMediaTime() - start
                listEndY = drawProjectRows(projects, summary: summary, topY: listStartTop,
                                           nameFont: nameFont, valueFont: valueFont, pctFont: pctFont,
                                           rowReveals: (0..<projects.count).map { i in
                                               let t = (elapsed - Double(i) * Self.staggerDelay) / Self.rowDuration
                                               return CGFloat(easeOutCubic(min(1, max(0, t))))
                                           })
            } else {
                listEndY = drawProjectRows(projects, summary: summary, topY: listStartTop,
                                           nameFont: nameFont, valueFont: valueFont, pctFont: pctFont)
            }
        }

        // 词元活动顶 = 末行墨迹底 + 20（行框居中留白不计入间距）
        drawActivitySection(topY: activityTitleTop(rows: projects.count),
                            gridTop: activityGridTop(rows: projects.count),
                            labelFont: labelFont, labelColor: labelColor, titleColor: titleColor)
        // 行命中框/可点击路径已随本次绘制更新：重挂光标矩形（draw 低频，开销可忽略）
        window?.invalidateCursorRects(for: self)
    }

    /// 项目行：文件夹 icon + 项目名（限宽截断）+ token 值 + 百分比；返回行块底部 Y。
    /// 内容（icon/名/值/百分比）统一系统灰（语义色随主题适配）；
    /// hover 行（hoveredListRow）背景只显百分比条 + 0.8pt 发丝边框（2026-08-31 用户要求
    /// 去掉用量行同款渐变底、边框保留），文字/icon 仍提亮到 Palette.cardForeground，
    /// 命中框回填 listRowRects 供 mouseMoved 判定。
    /// rowReveals = 平台切换动效的逐行交错进度（nil = 常态直绘）：每行独立透明度 +
    /// 自下方 6pt 上移，CG 变换实现、绘制坐标不变、命中框仍按最终几何记录
    @discardableResult
    private func drawProjectRows(_ projects: [ZcodeTokenSummary.ProjectUsage], summary: ZcodeTokenSummary,
                                 topY: CGFloat, nameFont: NSFont, valueFont: NSFont,
                                 pctFont: NSFont, rowReveals: [CGFloat]? = nil) -> CGFloat {
        let pctColWidth: CGFloat = 45
        let valueRight = bounds.width - insets.right - pctColWidth
        // 数值固定列宽（"1234.5万" ≈ 38pt，取 40）右对齐；项目名列从数值列左缘留 8pt 起截断
        let valueColWidth: CGFloat = 40
        let valueLeft = valueRight - valueColWidth
        let nameX = insets.left + 14
        let nameColWidth = max(40, valueLeft - 8 - nameX)
        let namePs = NSMutableParagraphStyle()
        namePs.lineBreakMode = .byTruncatingTail
        let rowH = rowHeight
        var rowY = topY
        let cg = NSGraphicsContext.current?.cgContext
        listRowRects = (0..<projects.count).map { NSRect(x: 0, y: topY + CGFloat($0) * rowH,
                                                          width: bounds.width, height: rowH) }
        listRowPaths = projects.map { $0.path }
        for (i, p) in projects.enumerated() {
            // 行级交错（平台切换动效）：逐行独立透明度 + 自下方上移（翻转坐标 +y 向下）
            let rowReveal = rowReveals?[i]
            if let rv = rowReveal {
                cg?.saveGState()
                cg?.setAlpha(rv)
                cg?.translateBy(x: 0, y: (1 - rv) * Self.listRowRise)
            }
            defer { if rowReveal != nil { cg?.restoreGState() } }
            let hovered = i == hoveredListRow
            let rowColor: NSColor = hovered ? Palette.cardForeground : SmallTable.textColor
            // 百分比背景条（仅 hover 行显示）：按行占比从左到右填充行底
            // （复用热力图无用量底点色，深 #262626/浅 210 灰）；常态行无背景
            if hovered {
                let pctBarRatio = summary.totalTokens > 0
                    ? CGFloat(p.tokens) / CGFloat(summary.totalTokens) : 0
                let barRect = NSRect(x: 0, y: rowY,
                                     width: bounds.width * pctBarRatio, height: rowH)
                let barPath = NSBezierPath(roundedRect: barRect, xRadius: 6, yRadius: 6)
                Palette.heatDotEmpty.setFill()
                barPath.fill()
            }
            // hover 发丝边框（保留）：只留描边、无渐变底（2026-08-31 用户口径）
            if hovered {
                let rect = NSRect(x: 0, y: rowY, width: bounds.width, height: rowH)
                let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                Palette.hoverBorderBright.setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }
            let iconRect = NSRect(x: insets.left, y: rowY + (rowH - 10) / 2, width: 10, height: 10)
            if let img = rowIcon(bright: hovered) {
                // respectFlipped:true：isFlipped 视图内保证正立（旧式 draw(in:) 不跟随翻转上下文）
                img.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            }
            let nameH = nameFont.boundingRectForFont.height
            let nameRect = NSRect(x: nameX, y: rowY + (rowH - nameH) / 2,
                                  width: nameColWidth, height: ceil(nameH))
            (p.name as NSString).draw(in: nameRect, withAttributes: [
                .font: nameFont, .foregroundColor: rowColor, .paragraphStyle: namePs,
            ])
            let valueText = ZcodeTokenStore.cnCompact(p.tokens)
            let valueW = valueText.size(withAttributes: [.font: valueFont]).width
            let valueH = valueFont.boundingRectForFont.height
            drawText(valueText, at: NSPoint(x: valueLeft + (valueColWidth - valueW), y: rowY + (rowH - valueH) / 2),
                     font: valueFont, color: rowColor)
            // 百分比一位小数（"69.6%"；各行四舍五入之和可能 ≠100%，属正常舍入误差）
            let pctValue = summary.totalTokens > 0
                ? Double(p.tokens) / Double(summary.totalTokens) * 100 : 0
            let pctText = String(format: "%.1f%%", pctValue)
            let pctW = pctText.size(withAttributes: [.font: pctFont]).width
            let pctH = pctFont.boundingRectForFont.height
            drawText(pctText, at: NSPoint(x: bounds.width - insets.right - pctW, y: rowY + (rowH - pctH) / 2),
                     font: pctFont, color: rowColor)
            rowY += rowH
        }
        return rowY
    }

    // MARK: 平台切换动效（交错上移淡入；「总计大数字 + 列表行」上移淡入、
    // 热力图点阵旧点亮出→新点亮入交叉淡变（0.6s），标题/表头/月份轴静止）

    /// 交错节奏(用户指定 2026-08-31,加长时长不适用 Motion.emphasis 0.40 硬顶,同 Motion.roll 口径):
    /// 行间延迟 0.1s、单行 0.4s;末行完成 = 0.3 + 0.4 = 0.7s
    private static let staggerDelay: Double = 0.1
    private static let rowDuration: Double = 0.4
    /// 切换动效总时长（timer 终点 = 列表末行完成时刻，点阵列延迟以此为摊派上限）
    private static var switchTotalDuration: Double {
        rowDuration + staggerDelay * Double(maxListRows - 1)
    }
    /// 大数字自下方的上移距离(pt)
    private static let staggerRise: CGFloat = 10
    /// 列表行（项目/模型表格）上移距离 = 大数字减 4pt（用户指定 2026-08-31，仅表格行程缩短）
    private static let listRowRise: CGFloat = 6
    /// 进行中的切换动效起始时刻;nil = 常态直绘
    private var switchTransitionStart: CFTimeInterval?
    private var switchTimer: Timer?
    /// 「每日/每周」切换专用的点阵波次起始（平台切换进行中恒为 nil，点阵随切换波次走）
    private var dotFadeStart: CFTimeInterval?
    private var dotFadeTimer: Timer?
    /// 点阵淡出/淡入时长（用户指定 2026-08-31：0.6s，双向 ease-in-out，
    /// 独立于列表行 0.4s 节奏；平台切换 timer 总时长 0.7s 覆盖之）
    private static let dotFadeDuration: Double = 0.6
    /// 上一次绘制的点亮度点快照（rect+level）：动效起点取作「旧点」做淡出
    private var lastLitDots: [(rect: NSRect, level: Int)] = []
    /// 动效期间参与淡出的旧点（起点自 lastLitDots 截取，动效结束清空）
    private var outgoingDots: [(rect: NSRect, level: Int)] = []

    private func easeOutCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    private func easeInOutCubic(_ p: Double) -> Double {
        p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    /// 平台切换动效入口(refreshInlineTokens 在 summary 换新前调用)。
    /// 大数字 = alpha + layer transform(layout 只改 frame 不碰 transform,与重排无冲突;
    /// 翻转视图的 backing layer geometryFlipped 同步翻转,+y 即视觉向下),与首行同节奏;
    /// 列表行在 draw 内按逐行交错进度绘制。系统「减弱动态效果」开启时直接落定不做动效。
    func beginSwitchTransition() {
        switchTimer?.invalidate()
        switchTimer = nil
        stopDotFade()   // 平台切换接管点阵波次，独立波次作废
        setNumberSwitchVisual(alpha: 1, transform: .identity)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        outgoingDots = lastLitDots   // 旧平台点亮出（此时 summary 未清，快照仍是旧数据）
        switchTransitionStart = CACurrentMediaTime()
        applyNumberSwitchProgress(0)
        let total = Self.switchTotalDuration
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, let start = self.switchTransitionStart else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - start
            if elapsed >= total {
                t.invalidate()
                self.endSwitchTransition()
            } else {
                self.applyNumberSwitchProgress(elapsed)
                // 行块动效在 draw 内按当前时刻计算进度,每帧驱动宿主重绘
                // (大数字是图层属性不需重绘,列表行是 draw 自绘,漏了就整段不动)
                self.needsDisplay = true
            }
        }
        switchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endSwitchTransition() {
        switchTransitionStart = nil
        outgoingDots.removeAll()
        setNumberSwitchVisual(alpha: 1, transform: .identity)
        needsDisplay = true
    }

    /// 大数字动效帧:与首行同节奏(单行时长)的透明度 + 上移
    private func applyNumberSwitchProgress(_ elapsed: CFTimeInterval) {
        let p = easeOutCubic(min(1, elapsed / Self.rowDuration))
        setNumberSwitchVisual(alpha: CGFloat(p),
                              transform: CGAffineTransform(translationX: 0, y: (1 - CGFloat(p)) * Self.staggerRise))
    }

    private func setNumberSwitchVisual(alpha: CGFloat, transform: CGAffineTransform) {
        totalRollView.wantsLayer = true
        totalRollView.alphaValue = alpha
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        totalRollView.layer?.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// 「每日/每周」切换入口：点阵独立重挂旧点亮出→新点亮入（0.6s 双向 ease-in-out），
    /// 只动点阵不碰大数字/列表行；平台切换进行中不另起（点阵已在切换淡入里）。
    /// 自绘点阵无图层可挂动画，靠 60fps timer 每帧 needsDisplay 驱动 draw 现算进度
    func restartDotFade() {
        stopDotFade()
        guard switchTransitionStart == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        outgoingDots = lastLitDots   // 旧模式点亮出（didSet 时上一帧 draw 仍是旧模式几何）
        dotFadeStart = CACurrentMediaTime()
        let total = Self.dotFadeDuration
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, self.dotFadeStart != nil else { t.invalidate(); return }
            if CACurrentMediaTime() - self.dotFadeStart! >= total {
                t.invalidate()
                self.dotFadeTimer = nil
                self.dotFadeStart = nil
                self.outgoingDots.removeAll()
            } else {
                self.needsDisplay = true
            }
        }
        dotFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDotFade() {
        dotFadeTimer?.invalidate()
        dotFadeTimer = nil
        dotFadeStart = nil
        outgoingDots.removeAll()
    }

    // MARK: 词元活动热力图

    /// 词元活动：标题 + 每日/每周切换 + 正圆点阵（用量越多越亮）。
    /// 每日 = 7 行（周一→周日）× 26 周列；每周 = 单行 26 点（每周合计）。
    /// topY/gridTop 由锚点链传入（activityTitleTop/activityGridTop），与 intrinsic 同源
    private func drawActivitySection(topY: CGFloat, gridTop gridTopAnchor: CGFloat, labelFont: NSFont,
                                     labelColor: NSColor, titleColor: NSColor) {
        drawText("词元活动", at: NSPoint(x: insets.left, y: topY),
                 font: makeTitleFont(), color: titleColor)

        // 右上角切换：选中 = 主前景，未选中 = 次级灰
        let toggleFont = labelFont
        let dailyText = "每日"
        let weeklyText = "每周"
        let weeklyW = weeklyText.size(withAttributes: [.font: toggleFont]).width
        let dailyW = dailyText.size(withAttributes: [.font: toggleFont]).width
        // 切换文案在标题行带内垂直居中（标题 10pt 比切换文案 9pt 高半档）
        let toggleY = topY + (titleInkHeight - toggleFont.boundingRectForFont.height) / 2
        let weeklyX = bounds.width - insets.right - weeklyW
        let dailyX = weeklyX - 6 - dailyW
        drawText(weeklyText, at: NSPoint(x: weeklyX, y: toggleY), font: toggleFont,
                 color: activityMode == .weekly ? Palette.cardForeground : labelColor)
        drawText(dailyText, at: NSPoint(x: dailyX, y: toggleY), font: toggleFont,
                 color: activityMode == .daily ? Palette.cardForeground : labelColor)
        dailyToggleRect = NSRect(x: dailyX, y: topY, width: dailyW, height: titleInkHeight)
        weeklyToggleRect = NSRect(x: weeklyX, y: topY, width: weeklyW, height: titleInkHeight)

        // ── 点阵（全格子绘制：无用量 = 底色点，有用量 = 渐变亮点；格内四周各缩 1pt）──
        dotCells.removeAll()
        let pitch = activityPitch
        let size = pitch - 2
        let gridTop = gridTopAnchor
        let window = activityWindow()
        let cells = activityCells()
        let maxVal = cells.map(\.tokens).max() ?? 0
        // 平台切换/每日·每周切换动效：旧点亮出→新点亮入交叉淡变（0.6s 双向 ease-in-out，
        // 整体同步、无列间交错、不上移）；仅有用量的点亮度点参与，无用量底点恒亮不动；
        // 常态直绘零开销
        let waveStart = switchTransitionStart ?? dotFadeStart
        let waveP: CGFloat = {
            guard let waveStart else { return 1 }
            let t = min(1, max(0, (CACurrentMediaTime() - waveStart) / Self.dotFadeDuration))
            return CGFloat(easeInOutCubic(t))
        }()
        if waveStart != nil {
            let out = 1 - waveP
            if out > 0.004 {
                for d in outgoingDots {
                    stamp(level: d.level).draw(in: d.rect, from: .zero, operation: .sourceOver,
                                               fraction: out, respectFlipped: true, hints: nil)
                }
            }
        }
        lastLitDots.removeAll(keepingCapacity: true)
        for c in cells {
            let rect = NSRect(x: insets.left + CGFloat(c.col) * pitch + 1,
                              y: gridTop + CGFloat(c.row) * pitch + 1,
                              width: size, height: size)
            let level = (c.tokens <= 0 || maxVal <= 0) ? 0
                : min(4, 1 + Int(Double(c.tokens) / Double(maxVal) * 3.999))
            stamp(level: level).draw(in: rect, from: .zero, operation: .sourceOver,
                                     fraction: level == 0 ? 1 : waveP,
                                     respectFlipped: true, hints: nil)
            if level > 0 { lastLitDots.append((rect, level)) }
            dotCells.append(DotCell(rect: rect, day: c.day, tipTokens: c.tipTokens))
        }

        // ── 横坐标月份标签：从网格左缘起，按「网格宽 ÷ 月数」等距分布，文本左对齐 ──
        let monthFmt = Self.monthAxisFmt
        let axisY = gridTop + 7 * pitch + 4
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
    /// 每日 = 窗口周列 × 7 行逐日；每周 = 窗口周列周合计单行点亮列内。
    /// 结果按 (daily, activityMode, 窗口起点) 缓存，draw 重复进入零重算
    private func activityCells() -> [ActivityCell] {
        guard let summary else { return [] }
        let window = activityWindow()
        if let c = activityCellsCache,
           c.mode == activityMode, c.windowStart == window.start, c.daily == summary.daily {
            return c.cells
        }
        let cal = Calendar.current
        let windowStartTime = window.start.timeIntervalSince1970

        // 有用量的天 → (列,行) 聚合
        var usage: [Int: Int64] = [:]
        for d in summary.daily {
            let col = Int((d.dayStart - windowStartTime) / 86400 / 7)
            guard col >= 0, col < window.cols else { continue }
            let row = (cal.component(.weekday, from: Date(timeIntervalSince1970: d.dayStart)) + 5) % 7
            usage[col * 7 + row, default: 0] += d.tokens
        }

        var cells: [ActivityCell] = []
        if activityMode == .daily {
            for col in 0..<window.cols {
                for row in 0..<7 {
                    let day = window.start.addingTimeInterval(TimeInterval((col * 7 + row) * 86400))
                    let t = usage[col * 7 + row] ?? 0
                    cells.append(ActivityCell(col: col, row: row, tokens: t, day: day, tipTokens: t))
                }
            }
        } else {
            // 每周视图：网格形态与每日一致（7 行 × 周列），不切单行——按周合计点亮列内的点：
            // 周用量越大，列内点亮的点越多（自下而上，周用量/最大周用量 × 7 行向上取整），
            // 点亮的点也越亮（tokens 记周合计，绘制端按最大周用量归一到 1-4 级亮度）
            var weekTotals: [Int: Int64] = [:]
            for col in 0..<window.cols {
                var t: Int64 = 0
                for row in 0..<7 { t += usage[col * 7 + row] ?? 0 }
                weekTotals[col] = t
            }
            let maxWeek = weekTotals.values.max() ?? 0
            for col in 0..<window.cols {
                let t = weekTotals[col] ?? 0
                let weekStart = window.start.addingTimeInterval(TimeInterval(col * 7 * 86400))
                let lit = t <= 0 || maxWeek <= 0 ? 0
                    : max(1, Int((Double(t) / Double(maxWeek) * 7).rounded(.up)))
                for row in 0..<7 {
                    let isLit = row >= 7 - lit
                    cells.append(ActivityCell(col: col, row: row, tokens: isLit ? t : 0,
                                              day: weekStart, tipTokens: t))
                }
            }
        }
        activityCellsCache = (summary.daily, activityMode, window.start, cells)
        return cells
    }

    // 热力图文案格式器（static 复用：DateFormatter 构造含 locale 数据加载，draw/hover
    // 高频路径不可每次新建；仅本视图主线程使用）
    private static let monthAxisFmt = makeFmt("M月")      // 月份轴
    private static let dailyTipFmt = makeFmt("M月d日")    // 每日 hover 提示
    private static let weeklyTipFmt = makeFmt("M.d")      // 每周 hover 提示（周区间两端）

    private static func makeFmt(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }

    /// hover 提示文案（单格现算）：每日 = 「M月d日 用量」；每周 = 「M.d–M.d 用量」
    /// （cell.day 为该列周一，区间两端各格式化一次）
    private func dotTooltip(for cell: DotCell) -> String {
        switch activityMode {
        case .daily:
            return "\(Self.dailyTipFmt.string(from: cell.day)) \(ZcodeTokenStore.cnCompact(cell.tipTokens))"
        case .weekly:
            let end = cell.day.addingTimeInterval(6 * 86400)
            return "\(Self.weeklyTipFmt.string(from: cell.day))–\(Self.weeklyTipFmt.string(from: end)) \(ZcodeTokenStore.cnCompact(cell.tipTokens))"
        }
    }

    /// 悬浮提示气泡：锚点圆上方居中（贴顶时改下方），画日期 + 用量
    private func drawTooltip(for cell: DotCell, anchor: NSRect) {
        let font = uiFont(size: 9)
        let text = dotTooltip(for: cell)
        let textW = text.size(withAttributes: [.font: font]).width
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
        drawText(text, at: NSPoint(x: bubble.minX + 6, y: bubble.minY + (h - textH) / 2),
                 font: font, color: Palette.cardForeground)
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        text.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    /// 亮度第 level 级的正圆印章（懒建缓存）：0 = 无用量底色（动态色，浅色外观=浅灰），
    /// 1-4 = 深色 GitHub 暗色绿阶离散色 / 浅色两端点插值。动态色按本视图 effectiveAppearance 解算成实色
    /// 后烘焙（NSImage 位图缓存会定格颜色，主题/浅色开关切换经 viewDidChangeEffectiveAppearance
    /// 清缓存重建）
    private func stamp(level: Int) -> NSImage {
        if dotStamps.count <= level {
            dotStamps.append(contentsOf: Array(repeating: nil, count: level + 1 - dotStamps.count))
        }
        if let cached = dotStamps[level] { return cached }
        var color = Self.levelColor(level, dark: effectiveAppearance.isDark)
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

    private static func levelColor(_ level: Int, dark: Bool) -> NSColor {
        if level <= 0 { return Palette.heatDotEmpty }
        // 深色主题：GitHub 暗色绿阶离散色直取；浅色主题：两端点线性插值
        if dark {
            let c = Palette.heatLevelsDark[min(level, 4) - 1]
            return NSColor(calibratedRed: CGFloat(c.r) / 255,
                           green: CGFloat(c.g) / 255,
                           blue: CGFloat(c.b) / 255, alpha: 1)
        }
        let t = Double(min(level, 4) - 1) / 3
        let levels = Palette.heatLevelsLight
        func lerp(_ a: Int, _ b: Int) -> CGFloat {
            CGFloat(a) + (CGFloat(b) - CGFloat(a)) * CGFloat(t)
        }
        return NSColor(calibratedRed: lerp(levels.from.r, levels.to.r) / 255,
                       green: lerp(levels.from.g, levels.to.g) / 255,
                       blue: lerp(levels.from.b, levels.to.b) / 255, alpha: 1)
    }

    /// 面板 icon 统一入口：来源（品牌 SVG / SF Symbol）一律 sourceAtop 单色化后按键缓存
    /// （品牌色直接上屏在深色玻璃上不可读；单色化与文件历史定稿一致）
    private func tintedIcon(key: String, color: NSColor, make: () -> NSImage?) -> NSImage? {
        if let cached = iconCache[key] { return cached }
        guard let base = make() else { return nil }
        let img = tintedImage(base, color)
        iconCache[key] = img
        return img
    }

    /// 列表行图标：SF Symbol 单色化（常态系统灰 = 行文本同色；hover 行提亮到主前景色，
    /// 缓存键区分亮度）
    private func rowIcon(bright: Bool) -> NSImage? {
        let symbol = rowIconSymbol
        return tintedIcon(key: bright ? symbol + ".bright" : symbol,
                          color: bright ? Palette.cardForeground : .systemGray) {
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        }
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

// MARK: - BalancePanelView 接线（ZCode / WorkBuddy 卡片 hover 切换内嵌 Token 板块）

extension BalancePanelView {

    /// Agent 卡 hover 确认（ZCode / WorkBuddy）：HoverCard 进度填充撑满 1s 后回调，
    /// 主面板 Token 板块切换为该平台内容，切换动效在 refreshInlineTokens 统一处理。
    /// 快速掠过不进入此回调（dwell 已取消）。同平台重复确认经 refreshInlineTokens
    /// 去重（view.source 未变则无高度变化，无几何反馈振荡）。
    func confirmTokensHover(source: TokensPanelSource) {
        hoverTokensSource = source
        refreshInlineTokens()
    }


    /// 拖拽开始/面板关闭时清除 hover 覆盖：Token 板块回落到 Agent 组顶部平台。
    /// 这是唯一的回落路径（hover 离开不回落，防几何反馈振荡，见 confirmTokensHover）。
    func clearTokensHoverOverride() {
        guard hoverTokensSource != nil else { return }
        hoverTokensSource = nil
        refreshInlineTokens()
    }

    // MARK: - 主面板「Token」板块（内嵌 ZCode / WorkBuddy 卡片 hover 同款内容）

    /// 创建唯一的内嵌内容视图并启动低频刷新。与卡片 hover 子面板共用 ZcodeTokensPanelView
    /// 与数据仓缓存；显示平台由 refreshInlineTokens 按 Agent 组顶部平台动态解析。
    func setupInlineTokens() {
        let view = ZcodeTokensPanelView()
        view.source = .zcode
        view.monoFontEnabled = monoFontEnabled
        // 左右缩进 8 = 用量行 / 设置卡片内容边界（usageHorizontalInset），内容撑满版心后
        // 热力图按实际宽等比放大、字号不变（hover 子面板保持默认 16 不受影响）；
        // 顶部缩进 4 = usageRowTopInset，标题→首行间距与用量区块同口径
        view.horizontalInset = 8
        view.topInset = 4
        view.bottomInset = 3
        view.isHidden = true
        // 列表（项目/模型）/热力图（每日/每周）切换改变内容高度：与折叠标题同口径
        // 通知 VC 按新内容高度重算面板尺寸
        view.onActivityModeChanged = { [weak self] in self?.onContentChanged?() }
        tokenContentStack.addArrangedSubview(view)
        // 显式等宽撑满版心：intrinsic 标称宽 240 仅供 hover 弹窗定尺寸，主面板按卡片实际宽拉伸
        view.widthAnchor.constraint(equalTo: tokenContentStack.widthAnchor).isActive = true
        inlineTokenView = view
        // 启动即无条件预热两个数据仓：App 启动阶段账号卡片尚未建好，「顶部平台」暂时
        // 解析不出，若只按解析结果取数会连带跳过预热 → 首次开面板要现等后台构建，板块延迟出现
        TokensPanelSource.zcode.fetch { _ in }
        TokensPanelSource.workbuddy.fetch { _ in }
        refreshInlineTokens()
        startInlineTokensRefreshTimer()
    }

    /// Token 板块跟随的平台：hover 中的 Agent 卡片优先；未 hover 时 = Agent 组最顶上的
    /// 可见卡片容器。该平台无 Token 数据源（Codex/TRAE）或组为空时返回 nil（板块整体隐藏）。
    private var inlineTokensSource: TokensPanelSource? {
        if let hover = hoverTokensSource { return hover }
        guard let group = balanceGroupContainer else { return nil }
        for container in group.arrangedSubviews where !container.isHidden {
            guard let id = platformCards.first(where: { $0.value === container })?.key else { continue }
            if id == BalancePlatform.zcode.rawValue { return .zcode }
            if id == BalancePlatform.workBuddy.rawValue { return .workbuddy }
            return nil
        }
        return nil
    }

    /// 取数并套用到内嵌视图。缓存命中同步返回（零读取），未命中挂起待后台构建补发；
    /// 无数据时块保持隐藏（主面板内不放「读取中」常驻占位）。
    /// hover/回落引起平台切换时做淡入动效（旧平台内容先清，新内容落定后整体揭示）。
    func refreshInlineTokens() {
        guard let view = inlineTokenView, view.superview != nil else { return }
        guard let source = inlineTokensSource else {
            if !view.isHidden {
                view.isHidden = true
                applyInlineTokensVisibility()
            }
            return
        }
        source.fetch { [weak self, weak view] summary in
            guard let self, let view, view.superview != nil else { return }
            // 取数期间平台已切换（hover 换卡/离开）：丢弃过期结果，等下一轮刷新重取
            guard self.inlineTokensSource == source else { return }
            var switched = false
            if view.source != source {
                view.beginSwitchTransition()   // 启动平台切换动效
                view.summary = nil   // 先清旧平台数据，防标题与数字错位一帧
                view.source = source
                switched = true
            }
            guard let summary = summary else {
                // 单次后台构建失败：已有数据则保留展示（本机库/trace 仍在，下一轮重试即恢复），
                // 避免偶发失败导致整块闪隐 60s；从未拿到过数据才保持隐藏
                if view.summary == nil, !view.isHidden {
                    view.isHidden = true
                    applyInlineTokensVisibility()
                }
                return
            }
            view.summary = summary
            if view.isHidden {
                view.isHidden = false
                applyInlineTokensVisibility()
            }
            if switched {
                // 动效已由 beginSwitchTransition 启动的 60fps timer 驱动，这里只按新内容高度重算面板尺寸
                self.onContentChanged?()
            }
        }
    }

    /// Token 板块显隐总闸：顶部平台有数据 → 标题+卡片按折叠态显隐（与用量区块同款）；
    /// 无数据 → 标题+卡片一并隐藏，标题隐藏期间折叠态不变（点击入口已消失），
    /// 数据恢复时按持久化的折叠态重新落地。
    private func applyInlineTokensVisibility() {
        guard let view = inlineTokenView else { return }
        let hasData = !view.isHidden
        tokenTitleRef?.isHidden = !hasData
        guard let card = tokenCardRef else { return }
        if hasData {
            let collapsed = UserDefaults.standard.bool(forKey: UDKey.tokenSectionCollapsed)
            card.isHidden = collapsed
            if let title = tokenTitleRef {
                (card.superview as? NSStackView)?.setCustomSpacing(collapsed ? 6 : 0, after: title)
            }
        } else {
            card.isHidden = true
        }
        onContentChanged?()
    }

    /// 主面板 Token 板块低频刷新（与后台缓存重建同周期 60s，fetch 只回缓存零读取）；
    /// 总计词元变化时经 RollingNumberView 从旧值滚动到新值。面板销毁后定时器空转自清。
    private func startInlineTokensRefreshTimer() {
        inlineTokensRefreshTimer?.invalidate()
        inlineTokensRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.inlineTokenView?.superview != nil else {
                self?.inlineTokensRefreshTimer?.invalidate()
                self?.inlineTokensRefreshTimer = nil
                return
            }
            self.refreshInlineTokens()
        }
    }
}

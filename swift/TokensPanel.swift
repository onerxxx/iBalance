// TokensPanel.swift — Token 板块通用代码（ZCode / WorkBuddy / Codex 共用：卡片 hover 子面板与主面板内嵌板块）
// ZCode 数据源 = 本机会话库 ~/.zcode/cli/db/db.sqlite（model_usage 表，每次 LLM 请求一行，
// 含 input/output/reasoning/cache 拆分；WB 数据源在 WbTokens.swift）。总计口径 = input + output
// 相加（与 ZCode computed_total_tokens 一致，reasoning 是 output 子集、cache_read 是 input 子集，均不另加）。
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 缓存壳         TokenStoreCache（60s 后台重建；fetch 只回缓存，首次无缓存挂起回调主线程补发）
// 查询 / 聚合     ZcodeTokenStore（SQLite 读取）；数据模型 TokenSummary / TokenDayUsage
// 周期            TokenPeriod（日/周）+ TokenPeriodWindows
// 数据源来源       TokensPanelSource（.zcode / .workbuddy / .codex：卡片 hover 子面板与主面板内嵌板块共用；
//                  .aggregate = Agent 分组标题 hover 驻留触发的三平台聚合视图）
// 面板视图         TokensPanelView（数值 + 热力图 + hover 气泡）
// 主面板内嵌挂载    extension BalancePanelView（「Token」板块复用同一个 TokensPanelView）
//
// ⚠️ 热力图与 hover 气泡是**自绘**的（draw(_:) 画格子、mouseMoved 按 dotCells 命中测试、
//    drawTooltip 画气泡）——不是 NSView，不走约束/hover 协议/自动布局。
//    改气泡样式改 drawTooltip，别去找 tooltip 控件（找不到）。
import Cocoa
import SQLite3

// MARK: - 数据

/// Token 数据仓通用缓存壳：首次 fetch 启动后台定时器，每 60s 重建一次缓存；
/// 之后 fetch 只回缓存（同步、零读取，面板弹出不再触发扫描/查库），首次无缓存时
/// 挂起回调、构建完成后主线程补发（含构建失败 nil，避免每次弹面板反复重试）。
final class TokenStoreCache {
    private let queue: DispatchQueue
    private let build: () -> TokenSummary?
    private var cached: (summary: TokenSummary?, at: Date)?
    private var pending: [(TokenSummary?) -> Void] = []
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval = 60

    /// .utility：60s 后台预热重建非交互路径，userInitiated 会与面板动画抢调度
    ///（2026-08-31 效率审查遗留项；面板弹出时取数走缓存，QoS 不影响体感）
    init(label: String, build: @escaping () -> TokenSummary?) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.build = build
    }

    /// 取汇总：有缓存同步返回（主线程），无缓存挂起待构建完成回调
    func fetch(completion: @escaping (TokenSummary?) -> Void) {
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

    /// 每轮后台重建完成后的通知（**主线程**回调）。
    /// 存在的理由（2026-09-17）：卡片副标题的 tok/s 是走 `cachedIfBuilt` 的**同步只读**，
    /// 缓存重建完若没人叫面板重画，那一格要等到下一次面板刷新才跟上 —— 观感就是
    ///「刚打开时 tok/s 半天不出来」。宿主在预热处注册它，回调里刷面板。
    var onRefresh: ((TokenSummary?) -> Void)?

    /// 后台重建缓存并补发挂起回调（构建失败也落缓存，防反复重扫）
    private func refresh() {
        let s = build()
        cached = (s, Date())
        if let notify = onRefresh {
            DispatchQueue.main.async { notify(s) }
        }
        guard !pending.isEmpty else { return }
        let callbacks = pending
        pending.removeAll()
        DispatchQueue.main.async {
            callbacks.forEach { $0(s) }
        }
    }

    /// 已构建完成的缓存的同步只读（从未构建过 = nil）：余额卡片副标题 tok/s 快照装配用
    /// ——快照在主线程同步构建，不能走 fetch 的挂起补发通道
    var cachedIfBuilt: TokenSummary? { cached?.summary }
}

/// 最近 10 次会话均速（tok/s）：每次会话速率 = 该次会话 tokens ÷ 所花时间（秒），
/// 取时间最近（start 降序前 10 个）会话速率的算术平均；时长 ≤ 0 的会话无法度量
/// 耗时、不计入。三数据仓（ZCode / WB / Codex）各自收集会话后走这里归一口径
///（tokens 的统计范围由调用方定：2026-09-14 用户指定三仓均只传 output）
func recentSessionSpeed(_ sessions: [(start: TimeInterval, tokens: Double, seconds: Double)]) -> Double? {
    let rates = sessions
        .filter { $0.seconds > 0 && $0.tokens > 0 }
        .sorted { $0.start > $1.start }
        .prefix(10)
        .map { $0.tokens / $0.seconds }
    guard !rates.isEmpty else { return nil }
    return rates.reduce(0, +) / Double(rates.count)
}

/// Token 子面板数据源分流：ZCode、WorkBuddy、Codex 共用同一面板视图，仅数据仓/区块标题/行图标不同
enum TokensPanelSource {
    case zcode
    case workbuddy
    case codex
    /// 三平台聚合（Agent 分组标题 hover 驻留触发）：ZCode + WorkBuddy + Codex 加总
    case aggregate

    /// 面板首行标题 = 平台名
    var platformName: String {
        switch self {
        case .zcode: return "ZCode"
        case .workbuddy: return "WorkBuddy"
        case .codex: return "Codex"
        case .aggregate: return "Agent"   // 首行会再拼「总计」，标题带「总计」会重复（2026-09-06）
        }
    }
    /// 异步取汇总（各数据仓后台每 60s 重建缓存，fetch 只回缓存，主线程回调）
    func fetch(completion: @escaping (TokenSummary?) -> Void) {
        switch self {
        case .zcode: ZcodeTokenStore.fetch(completion: completion)
        case .workbuddy: WBTokenStore.fetch(completion: completion)
        case .codex: CodexTokenStore.fetch(completion: completion)
        case .aggregate:
            // 三仓缓存并行收集（各仓回调均在主线程：缓存命中同步返回 / 未命中构建后补发），
            // 全部到齐后合并；三仓皆无数据 → nil（聚合视图与单仓口径一致地保持隐藏）
            let sources: [TokensPanelSource] = [.zcode, .workbuddy, .codex]
            var results: [TokenSummary?] = Array(repeating: nil, count: sources.count)
            var remaining = sources.count
            for (i, s) in sources.enumerated() {
                s.fetch { sum in
                    results[i] = sum
                    remaining -= 1
                    if remaining == 0 { completion(TokenSummary.merge(results)) }
                }
            }
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

/// 各滚动窗口起点（秒）：均为滚动窗口 = now − 窗口时长（.all 无窗口）。
/// 2026-09-08 用户指定：1d 由「今日零点」改为过去 24h，与其余周期统一为纯时间差。
enum TokenPeriodWindows {
    static func starts(now: Date = Date()) -> [TokenPeriod: TimeInterval] {
        let t = now.timeIntervalSince1970
        return [.h5: t - 5 * 3600,
                .d1: t - 86400,
                .d7: t - 7 * 86400,
                .d30: t - 30 * 86400,
                .all: 0]
    }
}

/// 单日 token 用量（本地时区当日零点时间戳 + input+output 合计）
/// Equatable：热力图 cells 缓存按 daily 数组比对失效
struct TokenDayUsage: Equatable {
    let dayStart: TimeInterval
    let tokens: Int64
}

/// 本机 token 用量汇总（列表行按用量降序；WB 数据源另带模型分组）
struct TokenSummary {
    struct ProjectUsage {
        let name: String   // 项目名（会话目录末段）/ 模型名
        let tokens: Int64  // input + output
        /// 项目完整目录（模型行无此字段；nil = 不可点击打开，如「(未知项目)」）
        var path: String? = nil
    }
    let totalTokens: Int64
    let projects: [ProjectUsage]
    /// 按模型分组（WB / Codex 数据源填充；ZCode 库无此聚合，空 = 列表不显示「模型」切换）
    var models: [ProjectUsage] = []
    let requestCount: Int64
    /// 按天用量（词元活动热力图数据源，仅含有用量的天）
    let daily: [TokenDayUsage]
    /// 各周期总计词元（5H/1D/1W/1M 首行切换；窗口起点 = TokenPeriodWindows，
    /// 数据仓构建时按当前时刻聚合，60s 重建自然滚动窗口）
    var periodTotals: [TokenPeriod: Int64] = [:]
    /// 各滚动窗口下的项目/模型聚合（窗口口径同 periodTotals，窗口内无用量 = 无键/空列表；
    /// .all 不存 = 全量即 projects/models，列表随总计周期切换换数据）
    var periodProjects: [TokenPeriod: [ProjectUsage]] = [:]
    var periodModels: [TokenPeriod: [ProjectUsage]] = [:]
    /// 最近 10 次会话均速（tok/s，卡片副标题 meta 用；nil = 无可度量会话）。
    /// 各数据仓在后台重建时顺手算好挂进来；聚合 merge 视图不填（卡片按平台单仓取）
    var recentSessionSpeed: Double? = nil

    /// 列表行（周期口径）：All = 全量列表；窗口周期取各窗口聚合，窗口内无用量 = 空列表
    ///（不做全量回落——列表与首行大数字保持同一周期口径）
    func listRows(period: TokenPeriod, isModels: Bool) -> [ProjectUsage] {
        if period == .all { return isModels ? models : projects }
        return (isModels ? periodModels[period] : periodProjects[period]) ?? []
    }

    /// 项目行跨仓归并：键 = 完整目录（缺失用名称前缀区分，避免与真目录同名误合），
    /// 同键 tokens 相加，降序
    private static func mergedProjectRows(_ lists: [[ProjectUsage]]) -> [ProjectUsage] {
        struct Agg { var tokens: Int64 = 0; var path: String?; var name: String }
        var aggs: [String: Agg] = [:]
        for rows in lists {
            for p in rows {
                let key = p.path ?? "name:\(p.name)"
                var a = aggs[key] ?? Agg(tokens: 0, path: nil, name: "")
                a.tokens += p.tokens
                a.path = a.path ?? p.path
                a.name = p.path == nil ? p.name : (p.path! as NSString).lastPathComponent
                aggs[key] = a
            }
        }
        return aggs.values
            .map { ProjectUsage(name: $0.name, tokens: $0.tokens, path: $0.path) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// 模型行跨仓归并：小写名同键；展示名大写写法优先，同档取单仓名下用量大的写法，降序
    private static func mergedModelRows(_ lists: [[ProjectUsage]]) -> [ProjectUsage] {
        var aggs: [String: (tokens: Int64, name: String, nameTokens: Int64)] = [:]
        for rows in lists {
            for m in rows {
                let key = m.name.lowercased()
                var a = aggs[key] ?? (0, m.name, -1)
                a.tokens += m.tokens
                let curUpper = m.name != key
                let dispUpper = a.name != a.name.lowercased()
                let replace: Bool
                if curUpper != dispUpper { replace = curUpper }
                else { replace = m.tokens > a.nameTokens }
                if replace { a.name = m.name; a.nameTokens = m.tokens }
                aggs[key] = a
            }
        }
        return aggs.values
            .map { ProjectUsage(name: $0.name, tokens: $0.tokens) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// Agent 聚合视图合并（.aggregate 取数收口）：总计/请求数逐项加总，
    /// 每日与周期窗口按键求和，项目按「完整目录 ?? 名称」跨仓归并（同目录合并一行），
    /// 模型按小写名归并（展示名口径同 ZCode 单仓：大写优先、同档取大），列表重排降序。
    /// 三仓全部为 nil → nil（板块隐藏）。
    static func merge(_ parts: [TokenSummary?]) -> TokenSummary? {
        let valid = parts.compactMap { $0 }
        guard !valid.isEmpty else { return nil }

        let total = valid.reduce(Int64(0)) { $0 + $1.totalTokens }
        let requests = valid.reduce(Int64(0)) { $0 + $1.requestCount }

        var dayAgg: [TimeInterval: Int64] = [:]
        for s in valid { for d in s.daily { dayAgg[d.dayStart, default: 0] += d.tokens } }
        let daily = dayAgg.map { TokenDayUsage(dayStart: $0.key, tokens: $0.value) }
            .sorted { $0.dayStart < $1.dayStart }

        var periodTotals: [TokenPeriod: Int64] = [:]
        for s in valid { for (p, v) in s.periodTotals { periodTotals[p, default: 0] += v } }

        let projects = mergedProjectRows(valid.map { $0.projects })
        let models = mergedModelRows(valid.map { $0.models })

        // 各周期窗口列表逐仓归并（键口径与全量一致），窗口内无用量的周期为空列表
        var periodProjects: [TokenPeriod: [ProjectUsage]] = [:]
        var periodModels: [TokenPeriod: [ProjectUsage]] = [:]
        for p in TokenPeriod.windowed {
            periodProjects[p] = mergedProjectRows(valid.map { $0.periodProjects[p] ?? [] })
            periodModels[p] = mergedModelRows(valid.map { $0.periodModels[p] ?? [] })
        }

        return TokenSummary(totalTokens: total, projects: projects, models: models,
                            requestCount: requests, daily: daily, periodTotals: periodTotals,
                            periodProjects: periodProjects, periodModels: periodModels)
    }
}

enum ZcodeTokenStore {
    /// 打开策略链（WAL 库只读限制的完整覆盖）：
    /// ① 只读直开——ZCode 运行中或异常退出残留 -wal/-shm 时可附着读取（含 WAL 最新增量）；
    /// ② immutable=1——ZCode 正常退出会合并删除 -wal/-shm，此时只读连接无法为 WAL 库重建
    ///    -shm（READONLY 禁写辅助文件），prepare 报 "unable to open database file"，
    ///    immutable 跳过锁与 shm 直读主文件（干净退出后主文件即完整数据，无损失）；
    /// ③ 克隆副本兜底——把 db+-wal+-shm 复制到临时目录（APFS clonefile 秒级）再 immutable
    ///    查询，覆盖辅助文件损坏等罕见态。
    private static func query() -> TokenSummary? {
        let path = NSHomeDirectory() + "/.zcode/cli/db/db.sqlite"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let s = queryDB(path: path, immutable: false) ?? queryDB(path: path, immutable: true) {
            return s
        }
        return querySnapshotCopy(path: path)
    }

    /// 按 plain 只读或 immutable URI 打开并聚合；任何失败返回 nil
    private static func queryDB(path: String, immutable: Bool) -> TokenSummary? {
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
    private static func querySnapshotCopy(path: String) -> TokenSummary? {
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
    private static func runAggregates(db: OpaquePointer?) -> TokenSummary? {
        var projects: [TokenSummary.ProjectUsage] = []
        var models: [TokenSummary.ProjectUsage] = []
        var requests: Int64 = 0
        var daily: [TokenDayUsage] = []
        var periodTotals: [TokenPeriod: Int64] = [:]

        // 窗口起点（毫秒）与各窗口 CASE 列：列表（项目/模型）与总计共用同一窗口口径
        let starts = TokenPeriodWindows.starts()
        func ms(_ p: TokenPeriod) -> Int64 { Int64((starts[p] ?? 0) * 1000) }
        let periodCase = TokenPeriod.windowed
            .map { "SUM(CASE WHEN started_at >= \(ms($0)) THEN input_tokens + output_tokens ELSE 0 END)" }
            .joined(separator: ",\n                   ")

        var stmt: OpaquePointer?
        // 按会话目录（项目）聚合；目录缺失的会话归入「(未知项目)」；
        // 第 3~6 列 = 各窗口（5h/1d/7d/30d）项目小计，供列表随周期切换
        let projectSQL = """
            SELECT COALESCE(NULLIF(s.directory, ''), '(未知项目)') AS proj,
                   SUM(m.input_tokens) + SUM(m.output_tokens), COUNT(*),
                   \(periodCase)
            FROM model_usage m JOIN session s ON s.id = m.session_id
            GROUP BY s.directory
            HAVING SUM(m.input_tokens) + SUM(m.output_tokens) > 0
            ORDER BY 2 DESC
            """
        var periodProjTokens: [TokenPeriod: [(path: String, tokens: Int64)]] = [:]
        if sqlite3_prepare_v2(db, projectSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dir = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "(未知项目)"
                let tokens = sqlite3_column_int64(stmt, 1)
                requests += sqlite3_column_int64(stmt, 2)
                for (i, p) in TokenPeriod.windowed.enumerated() {
                    let t = sqlite3_column_int64(stmt, Int32(3 + i))
                    if t > 0 { periodProjTokens[p, default: []].append((dir, t)) }
                }
                // 项目名 = 目录末段（(未知项目) 原样保留）；完整目录随行携带供点击打开
                let name = dir == "(未知项目)" ? dir : (dir as NSString).lastPathComponent
                projects.append(TokenSummary.ProjectUsage(name: name, tokens: tokens,
                                                               path: dir == "(未知项目)" ? nil : dir))
            }
        }
        sqlite3_finalize(stmt)
        let periodProjects: [TokenPeriod: [TokenSummary.ProjectUsage]] = periodProjTokens.mapValues { rows in
            rows.map { dir, tokens in
                TokenSummary.ProjectUsage(
                    name: dir == "(未知项目)" ? dir : (dir as NSString).lastPathComponent,
                    tokens: tokens, path: dir == "(未知项目)" ? nil : dir)
            }.sorted { $0.tokens > $1.tokens }
        }

        // 按模型聚合（口径与 WB 数据源一致：input + output 降序），供「项目/模型」切换；
        // 大小写变体归并为一行（GLM-5.3-Flash / glm-5.3-flash），展示名优先带大写的写法，
        // 同档取用量大的写法，全小写时回落小写
        let modelSQL = """
            SELECT model_id,
                   SUM(input_tokens) + SUM(output_tokens),
                   \(periodCase)
            FROM model_usage
            GROUP BY model_id
            HAVING SUM(input_tokens) + SUM(output_tokens) > 0
            """
        // key = 小写模型名；value = (累计词元, 展示名, 展示名写法的词元)
        var modelAggs: [String: (tokens: Int64, name: String, nameTokens: Int64)] = [:]
        // 各窗口模型小计（key = 小写名，展示名取全量聚合结果——窗口 ⊆ 全量，键必已存在）
        var modelPeriodTokens: [String: [TokenPeriod: Int64]] = [:]
        if sqlite3_prepare_v2(db, modelSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "(未知模型)"
                let tokens = sqlite3_column_int64(stmt, 1)
                let key = name.lowercased()
                for (i, p) in TokenPeriod.windowed.enumerated() {
                    let t = sqlite3_column_int64(stmt, Int32(2 + i))
                    if t > 0 { modelPeriodTokens[key, default: [:]][p, default: 0] += t }
                }
                var agg = modelAggs[key] ?? (0, "", -1)
                agg.tokens += tokens
                let curUpper = name != key
                let dispUpper = !agg.name.isEmpty && agg.name != agg.name.lowercased()
                let replace: Bool
                if agg.name.isEmpty { replace = true }
                else if curUpper != dispUpper { replace = curUpper }   // 大写写法优先
                else { replace = tokens > agg.nameTokens }             // 同档取用量大的
                if replace {
                    agg.name = name
                    agg.nameTokens = tokens
                }
                modelAggs[key] = agg
            }
        }
        sqlite3_finalize(stmt)
        models = modelAggs.values
            .map { TokenSummary.ProjectUsage(name: $0.name, tokens: $0.tokens) }
            .sorted { $0.tokens > $1.tokens }
        var periodModels: [TokenPeriod: [TokenSummary.ProjectUsage]] = [:]
        for (key, periods) in modelPeriodTokens {
            for (p, t) in periods {
                // 展示名取全量聚合结果：窗口 ⊆ 全量，此键必已存在
                periodModels[p, default: []].append(
                    TokenSummary.ProjectUsage(name: modelAggs[key]!.name, tokens: t))
            }
        }
        periodModels = periodModels.mapValues { $0.sorted { $0.tokens > $1.tokens } }

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
                    daily.append(TokenDayUsage(dayStart: day.timeIntervalSince1970, tokens: tokens))
                }
            }
        }
        sqlite3_finalize(stmt)

        // 周期总计（5h/1d/7d/30d 滚动窗口）：started_at 为毫秒，四窗口起点转毫秒后
        // 单条 CASE 求和（All = 全量总计在下方补入）；缓存每 60s 重建 → 窗口自然前移
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
        // 最近 10 次会话均速（tok/s，卡片副标题 meta）：一次会话 = 同一 session_id 的
        // **output tokens** 合计 ÷ 会话时长（session.time_created → time_updated，毫秒）；
        // 用户 2026-09-14 指定只算 output——input 是每轮重发的上下文，混入会把速率抬高一个量级。
        // 均值口径归 recentSessionSpeed；ZCode 运行中库带 -wal，只读链路与上方聚合同源
        var sessionSpeed: Double?
        let speedSQL = """
            SELECT SUM(m.output_tokens),
                   s.time_created, s.time_updated
            FROM model_usage m JOIN session s ON s.id = m.session_id
            GROUP BY m.session_id
            ORDER BY s.time_created DESC
            """
        if sqlite3_prepare_v2(db, speedSQL, -1, &stmt, nil) == SQLITE_OK {
            var sessions: [(start: TimeInterval, tokens: Double, seconds: Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tokens = Double(sqlite3_column_int64(stmt, 0))
                let created = Double(sqlite3_column_int64(stmt, 1))
                let updated = Double(sqlite3_column_int64(stmt, 2))
                sessions.append((start: created / 1000, tokens: tokens,
                                 seconds: (updated - created) / 1000))
            }
            sessionSpeed = recentSessionSpeed(sessions)
        }
        sqlite3_finalize(stmt)
        guard !projects.isEmpty else { return nil }
        var summary = TokenSummary(totalTokens: total, projects: projects,
                                   models: models,
                                   requestCount: requests, daily: daily.sorted { $0.dayStart < $1.dayStart },
                                   periodTotals: periodTotals,
                                   periodProjects: periodProjects,
                                   periodModels: periodModels)
        summary.recentSessionSpeed = sessionSpeed
        return summary
    }

    /// 异步取汇总：后台每 60s 重建缓存，fetch 只回缓存不触发读取
    private static let cache = TokenStoreCache(label: "ibalance.zcodeTokens") { Self.query() }
    static func fetch(completion: @escaping (TokenSummary?) -> Void) {
        cache.fetch(completion: completion)
    }
    /// 每轮缓存重建完成后的通知（宿主刷面板用；见 `TokenStoreCache.onRefresh`）
    static func onRefresh(_ f: @escaping (TokenSummary?) -> Void) { cache.onRefresh = f }
    /// 已构建缓存的同步只读（nil = 尚未构建过）：卡片副标题 tok/s 用
    static func cachedSummary() -> TokenSummary? { cache.cachedIfBuilt }

    // MARK: 数值格式化

    /// 千分位分组格式器（static 复用：NumberFormatter 构造含 locale 数据加载，
    /// 原每次调用新建——总计落位与 cnCompact 小数值分支都走这里，draw 期间被逐格放大）
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// 千分位完整数字：570902356 → "570,902,356"
    static func grouped(_ t: Int64) -> String {
        groupedFormatter.string(from: NSNumber(value: t)) ?? "\(t)"
    }

    /// M 单位展示格式器（整数部分照常千分位 + 固定三位小数）：
    /// 1234567.8912 → "1,234,567.891"。与 `groupedFormatter` 同源同 locale，
    /// 只是把小数位固定成 3（2026-09-12 用户指定「用 M 单位时依旧要千位分隔符」，
    /// 随后指定「小数点后三位」）。
    private static let millionFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 3
        f.maximumFractionDigits = 3
        return f
    }()

    /// 总计大数字展示文本（2026-09-12 用户指定）：
    /// 数值 ≥ 10 亿（1 billion）→ 改用 M 单位（百万）、**精确到小数点后三位且整数部分
    /// 保留千位分隔符**，1,234,567,890 → "1,234.568M"；低于 10 亿仍走千分位完整数字
    /// （570,902,356）。
    static func totalDisplay(_ t: Int64) -> String {
        guard t >= 1_000_000_000 else { return grouped(t) }
        let millions = Double(t) / 1_000_000
        let body = millionFormatter.string(from: NSNumber(value: millions))
            ?? String(format: "%.2f", millions)
        return body + "M"
    }

    /// `totalDisplay` 的产出是否使用 M 单位记法（判据 = 以 "M" 结尾；千分位串全是
    /// 数字与逗号，不会误判）。换值动效据此决定走整组淡变还是位次滑移，
    /// 见 `TokensPanelView.syncTotalRoll` / `RollingNumberView.rollSwapText`。
    static func usesMUnit(_ text: String) -> Bool { text.hasSuffix("M") }

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

final class TokensPanelView: NSView, PanelScrollHoverSync {
    var summary: TokenSummary? {
        didSet {
            hoveredListRow = nil
            syncRowMaterial()
            metricsDirty = true
            // 占位骨架扫光：真实数据到达即停（timer tick 亦自检）
            if summary != nil { stopSkeletonShimmer() }
            // 平台切换换值：大数字走整组滑移（旧平台值滚到新值，与周期切换同款）
            let slide = slideNextTotalRoll
            slideNextTotalRoll = false
            syncTotalRoll(slideOnRebuild: slide)
            if oldValue?.totalTokens != summary?.totalTokens
                || oldValue?.projects.count != summary?.projects.count {
                invalidateIntrinsicContentSize()
            }
            needsDisplay = true
        }
    }
    /// 总计词元大数字（逐位垂直滚动；左对齐贴版心，位次与原 drawText 排版一致）
    private let totalRollView = RollingNumberView()
    /// 大数字左边那枚**小尺寸 3D 硬币**（用户 2026-09-11 指定）：参数与「3D 硬币」弹窗同源
    /// （材质 / Logo / 边纹 / 厚度 / 浮雕深度按 `CoinSettings` 等比缩到 `inlineCoinDiameter`），
    /// 只在主面板内嵌实例上显示（`showsInlineCoin`；hover 子面板保持原排版）。
    private let inlineCoin = Coin3DView(frame: .zero)
    /// 内嵌硬币直径（pt）：由「3D 硬币」弹窗的 **Panel coin size** 驱动（默认 32，
    /// 2026-09-12 用户指定可单独调；与弹窗的 Coin size 相互独立）。
    /// 在 `reloadInlineCoinSettings` 里按设置刷新。
    private var inlineCoinDiameter: CGFloat = CGFloat(CoinMetrics.defaultPanelSize)
    /// 硬币与大数字之间的间距 = 直径 × 0.25（2026-09-14 用户指定间距随硬币尺寸增减；
    /// 默认 32pt 时 = 8pt 与原固定值等值）。硬币 frame 比标称直径略宽 1~2pt，间距留够避免视觉贴字
    private static let inlineCoinGapRatio: CGFloat = 0.3
    /// 数字行带基准高（原硬编码 32）：数字 / 硬币 / 转圈共用它的中线，
    /// 硬币尺寸变化时不牵动数字的位置
    private static let numberRowBaseHeight: CGFloat = 32
    /// 数字行中线：硬币无论多大都以此垂直居中，恒与数字墨迹中心对齐
    private var numberRowCenterY: CGFloat { numberRowY + Self.numberRowBaseHeight / 2 }
    /// 是否显示内嵌硬币（由 `setupInlineTokens()` 打开）
    var showsInlineCoin = false
    /// 大数值行（硬币 + 大数字 + spinner）整体左缩进：默认 0 = 贴版心左缘（hover 子面板口径）；
    /// 主面板内嵌实例设 3（2026-09-15 用户指定）。整行同基准，硬币与数字间距不受影响
    var numberRowLeadingInset: CGFloat = 0
    /// `CoinSettings.save()` 变更通知的观察者 token（弹窗调参 → 小硬币实时重灌，见 init）
    private var settingsChangeObserver: NSObjectProtocol?
    /// 弹窗 CoinSettings 的 logo 原图：聚合态（无平台可对应）与平台 SVG 缺失时的回落
    private var inlineCoinSettingsArt: CoinLogoArt = CoinSVG.ghoPreset
    /// 总计占位 loading：数据未到时替代「—」横杆（2026-09-09 用户指定）
    private let totalSpinner = NSProgressIndicator()
    /// 大数字基准字号与字距增量（em，加宽，同日指定）。
    /// 沿革：26 →（2026-09-16「缩 10%」）23.4 →（2026-09-17「字号增加 5%」）24.57 → **直接定 24.6**
    ///（用户「26 * 0.9 * 1.05 改为 24.6pt」：算式换算来的值以后要按字面量维护，别再叠系数）。
    /// ⚠️ 只动**主面板**这一档；设置窗口图卡里那串示例值走 `AppSettingsView.tokenValueScale`，是另一条口径
    private static let totalBaseSize: CGFloat = 24.6
    private static let totalTrackingEm: CGFloat = 0.02
    /// 大数字当前字号（超宽逐级缩 基准→15；字号变化才重新 configure）
    private var totalNumberSize: CGFloat = TokensPanelView.totalBaseSize
    var onHoverChanged: ((Bool) -> Void)?
    /// 词元活动视图切换每日/每周时回调（控制器据此刷新 popover 尺寸）
    var onActivityModeChanged: (() -> Void)?
    /// 面板字体档（Sharp Grotesk 开关）翻转时由宿主调用：字体解析已收口到 `PanelFont`
    /// （全局读开关，不需要注入字体名），这里只负责让本视图按新字体重算 ——
    /// 滚动数值重解析 + 文本度量缓存作废 + 固有尺寸失效 + 重绘
    func refreshFontStyle() {
        totalRollView.refreshFont()
        metricsDirty = true   // 字体变了 → 所有文本度量缓存作废
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    /// 数据源分流（ZCode=项目 / WorkBuddy、Codex=模型）：影响区块标题与行图标
    var source: TokensPanelSource = .zcode {
        didSet {
            guard oldValue != source else { return }
            metricsDirty = true   // 平台名宽度随 source 变化
            // 硬币 logo 跟随平台换品牌 SVG（尺寸/材质等参数不动）—— 走「先自旋、转过 90° 再换」
            swapInlineCoinLogoOnSpin()
            needsDisplay = true
        }
    }
    /// 平台切换动效置位：下一次 summary 落值时大数字整组滑移（旧平台值滚到新值）。
    /// 一次性消费；切换后无数据的分支走 setText("—") 不受影响
    private var slideNextTotalRoll = false

    // MARK: 总计周期切换（5H/1D/1W/1M）

    /// 大数字当前周期口径（默认 7d，2026-09-02 用户指定；打开面板即 7 天滚动窗总计）
    var period: TokenPeriod = .d7 {
        didSet {
            guard oldValue != period else { return }
            hoveredListRow = nil   // 行内容随周期换数据，旧 hover 索引指向的行已非原项目/模型
            syncRowMaterial()
            metricsDirty = true    // 行数值/百分比随周期变化 → 行度量缓存作废
            needsDisplay = true
            // 用户主动换周期：结构变化（位数增减）走整组滑移
            syncTotalRoll(slideOnRebuild: true)
            // 切换周期：内嵌硬币自旋一圈（2026-09-12 用户指定；走程序化入口共用 0.3s 去抖）
            spinInlineCoin()
        }
    }
    /// 周期切换文案命中区（draw 时更新；mouseUp 判定）
    private var periodToggleRects: [NSRect] = []
    /// 大数值整行命中区（draw 时更新；mouseUp 判定 → 内嵌硬币自旋）
    private var numberRowRect = NSRect.zero

    private var trackingArea: NSTrackingArea?
    /// 模型行品牌 icon 缓存（bundleIcon 每次读盘，draw 高频不能直呼）
    private var iconCache: [String: NSImage] = [:]

    // MARK: 列表视图（项目/模型切换）

    enum ListMode { case projects, models }
    var listMode: ListMode = .projects {
        didSet {
            guard oldValue != listMode else { return }
            hoveredListRow = nil
            syncRowMaterial()
            metricsDirty = true   // 行内容随列表模式变化
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
    /// 当前行描边落在共享材质上的矩形（hideIfCurrent 需要 show 时同值 rect 比对）
    private var shownRowRect: NSRect?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 行描边共享材质宿主（重复安装无副作用）：**仅描边**——2026-08-31 行 hover 底
        // 口径「无渐变底」，且自绘视图的 draw 内容在自身层里，背景子层压不下去；
        // 描边层 zPosition 1000 在 draw 内容之上不受此限
        installHoverMaterialHost(showsBackground: false)
    }

    /// 行描边交接给共享材质宿主：行间整块滑动（与卡片连续效果同源），离开走宽限收场。
    /// hoveredListRow 的每个变更点（mouseMoved/exited、数据/周期/模式重置）都要调。
    private func syncRowMaterial() {
        if let i = hoveredListRow, i < listRowRects.count {
            let rect = listRowRects[i]
            hoverMaterialHost?.show(rect: rect, in: self, cornerRadius: 6)
            shownRowRect = rect
        } else if let rect = shownRowRect {
            hoverMaterialHost?.hideIfCurrent(rect: rect, in: self)
            shownRowRect = nil
        }
    }
    private var listRowRects: [NSRect] = []
    /// 行点击打开的项目目录（与 listRowRects 同序；nil = 不可点击，如模型行/(未知项目)）
    private var listRowPaths: [String?] = []


    // MARK: 词元活动状态

    enum ActivityMode { case daily, weekly }
    var activityMode: ActivityMode = .daily {
        didSet {
            guard oldValue != activityMode else { return }
            hoveredDot = nil
            dotsImagesDirty = true   // 点阵数据变 → 淡变位图重烘
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
    private var activityCellsCache: (daily: [TokenDayUsage], mode: ActivityMode,
                                     windowStart: Date, cells: [ActivityCell])?
    /// 占位态（summary 未到）全底色点阵缓存：输入 = activityMode + 窗口起点
    private var activityPlaceholderCache: (mode: ActivityMode, windowStart: Date,
                                           cells: [ActivityCell])?
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
    /// 圆角方块点阵印章缓存（5 级亮度，懒建；NSImage 绘制块按需执行，避免每次 draw 重建路径）
    private var dotStamps: [NSImage?] = []

    /// 列表行数上限（超出按用量截断，头部项目已覆盖绝大多数占比）：
    /// 项目 / 模型两个视图共用；行数少则列表区留白（intrinsic 高度、骨架行、
    /// 词元活动标题定位三处都钉死这个值，改这里即整体生效）
    /// 2026-09-15 用户要求「显示前三位项目/模型」：2 → 3（列表已按 tokens 降序，取前 N 即前 N 名）
    static let maxListRows = 3
    /// 项目行点击的文件夹打开应用（用户指定 QSpace Pro；未安装回退系统默认）
    private static let folderOpenerBundleID = "com.jinghaoshe.qspace.pro"
    // 标称版心宽：仅未布局/尺寸未落时回退用，不参与实际宽度解算——布局后热力图
    // 点距均分、列表行撑满等自绘元素全部按实际 bounds 自适应（列宽随宽等比缩放）
    private static let contentWidth: CGFloat = 260
    /// 列表行距 = 行墨迹高 + 2×rowInset：文字在行带内居中后上下各留 2.5pt，
    /// 行间墨迹空隙恒 5pt，与用量表格（usageRowTop/BottomInset）同源同口径；
    /// Mono 墨迹更高时行距自动放宽
    private var rowHeight: CGFloat { rowInkHeight + 2 * SmallTable.rowInset }
    /// 区块间距（总计词元 / 列表 / 词元活动 统一）：20 → 16（2026-09-08 用户
    /// 「项目列表和词元活动上面间隔都减少 4pt」）
    private static let sectionGap: CGFloat = 16
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
        // 字距加宽（2026-09-16）：refreshFont 读它按当前字号折算 pt
        totalRollView.trackingEm = Self.totalTrackingEm
        // 字体档统一由 PanelFont 全局解析（SG 开关 + 中文兜底）；不捕获 self，
        // SG 翻转时经 refreshFontStyle() 就地重算
        totalRollView.configure(size: Self.totalBaseSize, weight: .semibold, fontProvider: { s, w, monoDigits in
            PanelFont.font(size: s, weight: w, monoDigits: monoDigits)
        })
        addSubview(totalRollView)
        // 内嵌小硬币：紧凑呈现（无弹跳、按自身尺寸收紧高度）。
        // ⚠️ 交互保持开启（用户 2026-09-11 指定：任何时候都能点击自旋 / 拖拽翻转）——
        // 它是可滚动面板里的一个「活的」控件，靠 hitTest 只吃硬币圆内那 24pt，
        // 圈外的滚动 / hover 不受影响。
        inlineCoin.compactInline = true
        inlineCoin.interactive = true
        inlineCoin.isHidden = true
        addSubview(inlineCoin)
        // 「3D 硬币」弹窗实时同步：弹窗每改一个参数 apply 就发 .coinSettingsDidChange
        // （主线程同步，object = 弹窗的**内存快照** CoinSettingsBox——落盘是「保存」按钮的
        // 显式行为，磁盘上还是旧值，这里不能读盘）。弹窗关闭后 main.swift 会再灌一次
        // 磁盘值：保存过 = 无害复位，没保存 = 撤掉本次未保存的实时同步。
        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: .coinSettingsDidChange, object: nil, queue: .main
        ) { [weak self] note in
            self?.reloadInlineCoinSettings((note.object as? CoinSettingsBox)?.value)
        }
        // 总计占位 loading（2026-09-09 用户指定：替代原「—」横杆）：系统原生小转圈，
        // 停转自动隐藏（isDisplayedWhenStopped），起停在 syncTotalRoll 按 summary 有无切换
        totalSpinner.isIndeterminate = true
        totalSpinner.controlSize = .small
        totalSpinner.style = .spinning
        totalSpinner.isDisplayedWhenStopped = false
        addSubview(totalSpinner)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer = settingsChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: 墨迹几何（区块视觉间距恒 = sectionGap）
    // 名义行框（标签 10/12、数字带 32、列表行 = 墨迹+2×rowInset 居中）自带行框留白，
    // 区块锚点全部按字体实际墨迹（boundingRect/ascender）推导，间距不掺留白

    /// 9pt 小注释字体：仅「项目/模型」「每日/每周」切换文案与热力图月份轴（非标题）
    private func makeLabelFont() -> NSFont {
        PanelFont.font(size: 9, weight: .regular, monoDigits: true)
    }
    /// 选中周期字体：字重加一档（regular → medium，2026-09-08 用户指定；未选中仍 regular）。
    /// 宽度度量（cachedPeriodWidths）按此字体测——槽位取较宽态，选中切换不跳动。
    private func makePeriodSelectedFont() -> NSFont {
        PanelFont.font(size: 9, weight: .medium, monoDigits: true)
    }
    /// 标签墨迹高度（9pt 小注释）
    private var labelInkHeight: CGFloat { ceil(makeLabelFont().boundingRectForFont.height) }
    /// 区块标题字体（「项目」「词元活动」）：与用量表头同款（小表格口径）
    private func makeTitleFont() -> NSFont { SmallTable.titleFont() }
    /// 首行「平台名 总计」标题字体：同字号降一档字重（semibold → medium，2026-09-02 用户指定）
    private func makeHeaderTitleFont() -> NSFont {
        SmallTable.font(size: SmallTable.titleSize, weight: .medium)
    }
    /// 标题墨迹高度（10pt semibold）
    private var titleInkHeight: CGFloat { ceil(makeTitleFont().boundingRectForFont.height) }
    /// 列表行墨迹高度（小表格行字体 10pt medium）
    private var rowInkHeight: CGFloat { ceil(SmallTable.rowFont().boundingRectForFont.height) }
    /// 大数字字体（与 totalRollView configure 同参；数字轮行带贴顶排版，墨迹底 = 带顶 + ascender）
    private var numberFont: NSFont { PanelFont.font(size: totalNumberSize, weight: .semibold, monoDigits: true) }

    /// 总计标签顶 = 面板首行（与平台名同行）
    private var totalLabelTop: CGFloat { insets.top }
    /// 大数字行带顶（layout 与 draw 共用同一推导，防错位）；首行段高 = 标题墨迹 + 4
    private var numberRowY: CGFloat { totalLabelTop + titleInkHeight + 4 }
    /// 列表标签顶：基准仍 = 数字墨迹底 + sectionGap（原布局节奏，硬币 32pt 时**不触发**下移）；
    /// 「Panel coin size」调大后硬币会伸到数字墨迹之下，这里给它留 6pt 净空兜底，
    /// 否则「项目/模型」列表会压到硬币上。
    private var sectionLabelTop: CGFloat {
        max(numberRowY + numberFont.ascender + Self.sectionGap, inlineCoinBottom + 6)
    }
    /// 内嵌硬币的**视觉**底边：静止位 + 半径 + 半个弹跳幅度（不含 frame 的 1pt 余量）。
    /// 不显示硬币时回落数字墨迹底，此时兜底项恒不触发。
    private var inlineCoinBottom: CGFloat {
        guard showsInlineCoin else { return numberRowY + numberFont.ascender }
        let radius = inlineCoinDiameter / 2
        let bob = CGFloat(CoinMetrics.idleBounceHeight * Double(inlineCoinDiameter)
                          / Double(CoinMetrics.size)) / 2
        return numberRowCenterY + radius + bob
    }
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
            metricsDirty = true     // 几何变了 → 度量缓存作废
            dotsImagesDirty = true  // 点阵位图按新几何重烘
            invalidateIntrinsicContentSize()
        }
        // 硬币大数值行左缩进 = numberRowLeadingInset（默认 0：硬币/大数字/spinner 整行贴
        // 版心左缘，2026-09-14 用户指定；主面板内嵌实例 +3，2026-09-15 用户指定），
        // 其余行（标题/列表/热力图）仍按 insets.left
        let rowX = numberRowLeadingInset
        totalRollView.frame = NSRect(x: rowX + inlineCoinWidth, y: numberRowY,
                                     width: max(0, bounds.width - insets.right - rowX - inlineCoinWidth),
                                     height: Self.numberRowBaseHeight)
        // 内嵌小硬币：以**数字行中线**垂直居中（不随硬币尺寸漂移，
        // 所以「Panel coin size」调大调小都不会让硬币与数字错位）；
        // 宽高取硬币自身的紧凑边长（含厚度投影 + 弹跳余量）
        if showsInlineCoin {
            let side = inlineCoin.compactFittingHeight
            inlineCoin.frame = NSRect(x: rowX, y: numberRowCenterY - side / 2,
                                      width: side, height: side)
        }
        // spinner 与大数字同带垂直居中、左对齐（小号系统转圈 ~16pt 见方）
        let spinSize = totalSpinner.intrinsicContentSize
        totalSpinner.frame = NSRect(x: rowX + inlineCoinWidth + 1,
                                    y: numberRowCenterY - spinSize.height / 2,
                                    width: spinSize.width, height: spinSize.height)
        // 布局就绪后复算缩字号（打开瞬间 summary 落位时 view 可能尚未布局，宽度不可判）
        if let text = totalDisplayText {
            applyTotalNumberSize(for: text)
        }
    }
    /// 大数字行左侧内嵌硬币占掉的宽度（0 = 不显示）
    private var inlineCoinWidth: CGFloat {
        showsInlineCoin ? inlineCoinDiameter * (1 + Self.inlineCoinGapRatio) : 0
    }

    /// 内嵌小硬币自转一圈（面板每次打开、以及 hover 换平台换数据时由外部调用）。
    /// 起点在硬币当前姿态上叠加 360°，所以连点/连开不会跳姿态。
    /// ⚠️ 程序化自旋做 0.3s 去抖：面板打开那一拍可能「开面板」与「换数据」两处同时触发，
    /// 不去抖会叠成两圈（用户直接点硬币走 mouseUp 那条路，不受此限）。
    func spinInlineCoin() {
        guard showsInlineCoin else { return }
        let now = CACurrentMediaTime()
        guard now - lastProgrammaticSpinAt > 0.3 else { return }
        lastProgrammaticSpinAt = now
        inlineCoin.spin()
    }
    private var lastProgrammaticSpinAt: CFTimeInterval = 0

    /// 按 CoinSettings 重灌内嵌小硬币。**参数同源、尺寸等比**：直径固定为
    /// `inlineCoinDiameter`，厚度 / 浮雕深度按 k = 直径 / 弹窗直径 缩放（它们与 size
    /// 同量纲），logoScale / 材质 / 轮廓 / 边纹 / 静止姿态 / 自旋圈数原样照搬。
    /// - Parameter snapshot: 弹窗调参实时同步时传**内存快照**（落盘是显式保存，磁盘是旧值）；
    ///   nil = 读磁盘（弹窗关闭后的复位 / 初始化）。
    func reloadInlineCoinSettings(_ snapshot: CoinSettings? = nil) {
        guard showsInlineCoin else { return }
        let s = snapshot ?? CoinSettings.load()
        // Panel coin size：内嵌硬币自己的直径（与弹窗 Coin size 独立，见 CoinMetrics）。
        // 厚度 / 浮雕深度仍按 k = 内嵌直径 ÷ 弹窗直径 等比缩放。
        inlineCoinDiameter = CGFloat(s.panelSize)
        let k = inlineCoinDiameter / CGFloat(max(1, s.size))
        inlineCoin.size = Double(inlineCoinDiameter)
        inlineCoin.thickness = s.thickness * Double(k)
        inlineCoin.markDepth = s.markDepth * Double(k)
        // 边界阴影不乘 k：spread 是 160 盒单位，drawMark 里已按 sizeScale 自缩
        // （与现状恒等 —— 之前常量口径同样不乘 k），乘了反而把小币的阴影压到近乎不可见
        inlineCoin.markShadowOpacity = s.markShadowOpacity / 100
        inlineCoin.markShadowSpread = s.markShadowSpread
        inlineCoin.logoScale = s.logoScalePercent / 100
        inlineCoin.material = s.material
        // logo 先存弹窗原图，再按当前平台覆盖：弹窗调参时其余参数实时反映，
        // logo 维持平台 SVG（hover 切换平台即换 logo，2026-09-15 用户指定「其他参数不变」）
        inlineCoinSettingsArt = s.logoArt
        applyInlineCoinLogo()
        inlineCoin.edgeFinish = s.finish
        inlineCoin.style = s.appearance
        inlineCoin.outlineLevel = Int(s.outlineLevel.rounded())
        inlineCoin.outlineWidth = s.outlineWidth
        inlineCoin.logoInverted = s.logoInverted
        inlineCoin.restingTilt = s.restingTilt
        inlineCoin.restingRotation = s.restingRotation
        inlineCoin.turns = s.turns
        inlineCoin.isHidden = false
        needsLayout = true
    }

    /// 平台切换时的 logo 换代：**先自旋，等币转过 90°（盖面侧对观众）那一刻再换图** ——
    /// 正对观众换 logo 是一次「闪变」，转过去换就看不见（2026-09-16 用户要求）。
    /// 圈数跟 Motion 区 **Turns** 走（`spin()` 只有 `turns` 一个口径）—— 用户 2026-09-17 追问
    /// 「为什么不跟随 turns」，就把它接回去：临界阻尼下弹簧的落定时间只由 ω 决定、与振幅无关
    ///（ω = √15 ≈ 3.9 rad/s，约 1.7s 落定），所以转 5 圈不比转 1 圈**更久**，只是角速度更快，
    /// 「90° 那一刻」来得更早（≈70ms），闪变更不可能被看见。
    ///
    /// ⚠️ 币**不出帧**时钩子永不触发（`onTick` 的闸门：窗口不可见 / 自己被隐藏 / 祖先隐藏），
    /// 那时**直接换**：这枚币本来就没人看得见，也不必为一次看不见的换代白转一圈。
    /// 判定条件与 `onTick` 的闸门逐条对齐，别只判 `window != nil`。
    private func swapInlineCoinLogoOnSpin() {
        let tickerWillRun = showsInlineCoin
            && inlineCoin.window?.isVisible == true
            && !inlineCoin.isHiddenOrHasHiddenAncestor
            && !isHiddenOrHasHiddenAncestor
        guard tickerWillRun else {
            inlineCoin.onEdgeCrossing = nil
            applyInlineCoinLogo()
            return
        }
        inlineCoin.onEdgeCrossing = { [weak self] in self?.applyInlineCoinLogo() }
        inlineCoin.spin()
    }

    /// 内嵌硬币 logo 跟随当前平台：单平台 = 该平台品牌 SVG 解析出的 mark 轮廓；
    /// aggregate 聚合（无单一平台）与解析失败回落弹窗设置的 logo。只换 logoArt。
    private func applyInlineCoinLogo() {
        guard showsInlineCoin else { return }
        inlineCoin.logoArt = Self.platformCoinArt(for: source) ?? inlineCoinSettingsArt
        // WB 的 logo 图形再放大 1.5 倍（2026-09-15 用户指定，由 2 收窄）：乘在 contentFit
        // 之后不被「收进裁剪圆」的自动缩放抵消；超出裁剪圆的部分由圆切住
        inlineCoin.logoExtraScale = source == .workbuddy ? 1.5 : 1
    }

    /// 平台 → 品牌 SVG 资源名（与卡片品牌 icon 键同源：ZCode 用 ZhiPu 的 zhipu.svg）
    private static let coinLogoResources: [TokensPanelSource: String] = [
        .zcode: "zhipu", .workbuddy: "workbuddy", .codex: "codex",
    ]
    /// 解析缓存（含失败 = nil，恒不重试）：bundle SVG 只读盘解析一次
    private static var coinLogoArtCache: [TokensPanelSource: CoinLogoArt?] = [:]

    private static func platformCoinArt(for source: TokensPanelSource) -> CoinLogoArt? {
        guard let resource = coinLogoResources[source] else { return nil }
        if let cached = coinLogoArtCache[source] { return cached }
        let art = Bundle.main.url(forResource: resource, withExtension: "svg")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? CoinSVG.parse($0) }
        if art == nil {
            Logger.log(.layout, "Token 板块：\(resource).svg 缺失或解析失败，硬币 logo 回落弹窗设置")
        }
        coinLogoArtCache[source] = art
        return art
    }

    /// 上次布局宽度（intrinsic 高度依赖实际宽，宽度变化时需重算，见 layout()）
    private var lastLaidOutWidth: CGFloat = 0

    /// 大数字显示文本 = 当前周期窗口的总计（无数据回落 —）；
    /// ≥ 10 亿走 M 单位两位小数，否则千分位完整数字（见 ZcodeTokenStore.totalDisplay）
    private var totalDisplayText: String? {
        summary.map { ZcodeTokenStore.totalDisplay($0.periodTotals[period] ?? 0) }
    }

    /// 列表行百分比/hover 占比条的分母（与大数字同周期口径：All = 全量总计，窗口 = periodTotals）
    private var listBaseTotal: Int64 {
        guard let summary else { return 0 }
        return period == .all ? summary.totalTokens : (summary.periodTotals[period] ?? 0)
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
        guard let text = totalDisplayText else {
            // 占位：原生 loading 转圈（替代「—」横杆，2026-09-09 用户指定）；
            // 占位阶段不受下方挂起闸限制（启动预读即起转，数据到达直接落位）
            totalRollView.isHidden = true
            totalSpinner.startAnimation(self)
            return
        }
        guard totalRollView.window != nil || totalRollView.currentText == "—" else { return }
        totalSpinner.stopAnimation(self)
        totalRollView.isHidden = false
        applyTotalNumberSize(for: text)
        // 单位制切换（千分位完整数字 ↔ M 单位）：改走「数字滚动 + 字符纵向换位」。
        // 滑移的前提是新旧两串存在位次对应，而这两种记法的静态位语义完全不同
        // （逗号 ↔ 小数点 + 单位字母），强行滑移会让两串数字在中途交叉叠字
        // （2026-09-12 用户反馈）。判据与 totalDisplay 同源，见 usesMUnit。
        if ZcodeTokenStore.usesMUnit(totalRollView.currentText) != ZcodeTokenStore.usesMUnit(text) {
            totalRollView.rollSwapText(text)
            return
        }
        var effectiveTotal = totalDuration
        if effectiveTotal == nil, let deadline = openRerollDeadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 { effectiveTotal = remaining }
        }
        totalRollView.setText(text, animated: true, slideOnRebuild: slideOnRebuild, totalDuration: effectiveTotal)
    }

    /// 超出可用宽度时逐级缩字号（等宽 13 位数字也能放下；与原 draw 循环同参数）。
    /// 未布局（bounds 为 0）时跳过，等 layout() 就绪后复算
    private func applyTotalNumberSize(for text: String) {
        // 可用宽要扣掉左侧内嵌硬币（它占的是同一行带），否则数字会压到硬币上；
        // 再扣行左缩进 numberRowLeadingInset（与 layout() 同一基准），只留右侧版心边距
        let availWidth = bounds.width - insets.right - inlineCoinWidth - numberRowLeadingInset
        guard availWidth > 40 else { return }
        var size = Self.totalBaseSize
        // 度量须用实际渲染字体（PanelFont 与 totalRollView 同源）：Sharp Grotesk /
        // 等宽数字档按比例系统字体测宽会低估，超宽数字溢出版心；字距增量按当前档
        // 字号折算一并计入（advance 度量不含 tracking），系统 SF 档的紧缩
        // （`RollingNumberView.sfSlotTrackingEm`，现 −0.02em）不抵扣（保守侧：宁早缩不溢出）
        while size > 15,
              text.size(withAttributes: [.font: PanelFont.font(size: size, weight: .semibold, monoDigits: true)]).width
                + CGFloat(max(0, text.count - 1)) * size * Self.totalTrackingEm > availWidth {
            size -= 1
        }
        guard size != totalNumberSize else { return }
        totalNumberSize = size
        // 字号参与锚点链（numberFont.ascender → intrinsic 高度）：变化必须同步失效
        // 固有尺寸，否则高度滞留旧值，直到下一次无关的 invalidate（如首次列表切换）
        // 才一次性落地，文档高度跳变带动面板内容肉眼位移
        invalidateIntrinsicContentSize()
        totalRollView.configure(size: size, weight: .semibold,
                                fontProvider: { s, w, monoDigits in
            PanelFont.font(size: s, weight: w, monoDigits: monoDigits)
        })
    }

    private var activityGridHeight: CGFloat { 7 * activityPitch }
    /// 横坐标月份标签区高度（4pt 间距 + 标签墨迹）
    private var activityAxisHeight: CGFloat { 4 + labelInkHeight }
    /// 热力图列几何：窗口周列数 + 点距（可用宽均分，正圆 = 点距 - 2）。
    /// 窗口 = 最近 5 个整月：firstMonth = 4 个月前当月 1 号，start = 其所在周的周一，末列 = 今天所在周。
    /// 热力图窗口日级缓存：窗口锚点跨天才会变（首月 1 号所在周的周一 / 列数），
    /// 原实现每次调用都做 Calendar 组件运算（draw/pitch/intrinsic 高频路径）
    private var activityWindowCache: (day: Date, start: Date, cols: Int, firstMonth: Date)?
    private func activityWindow() -> (start: Date, cols: Int, firstMonth: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if let c = activityWindowCache, cal.isDate(c.day, inSameDayAs: today) {
            return (c.start, c.cols, c.firstMonth)
        }
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
        let cols = days / 7 + 1
        activityWindowCache = (today, start, cols, firstOfMonth)
        return (start, cols, firstOfMonth)
    }
    /// 版心可用宽：点距与点阵间隙共用同一宽度源（未布局时回退标称宽），
    /// 保证「点:隙:格」比例永远同源等比
    private var activityAvail: CGFloat {
        let width = bounds.width > 0 ? bounds.width : Self.contentWidth
        return width - insets.left - insets.right
    }
    /// 点距 = 实际版心可用宽 / 周列数（精确均分，不取整）：网格恰撑满版心，
    /// 最右点列与模型表的百分比右缘对齐
    private var activityPitch: CGFloat {
        max(6, activityAvail / CGFloat(activityWindow().cols))
    }
    /// 点阵间隙比例（间隙 ÷ 版心可用宽）：锚定 2026-09-03 调定观感，
    /// 2026-09-06 圆角方块化时间隙缩小一档（2.1 → 1.7，方块观感比圆点更密才协调）。
    /// 间隙随可用宽等比缩放（点径 = 点距 − 间隙），任意宽度（面板定宽/浮窗 resize）下
    /// 点:隙:格比例恒定不漂移
    private static let dotGapPerAvail: CGFloat = 1.7 / 202
    /// 当前宽度下的点阵间隙（相邻点之间的空隙 = 格内两侧各半隙）
    private var activityDotGap: CGFloat {
        activityAvail * Self.dotGapPerAvail
    }

    override var intrinsicContentSize: NSSize {
        // 列表区恒保留 maxListRows 行高度（行数少则留白）：平台切换列表行数不同，
        // 若高度随之伸缩，文档高度变化会让滚动位置重锚定、整块内容在静止光标下
        // 滑动点亮相邻卡的假 hover（2026-09-06 诊断闭环，见 [HoverDbg] 日志结论）
        let height: CGFloat = activityGridTop(rows: Self.maxListRows)
            + activityGridHeight + activityAxisHeight + insets.bottom
        return NSSize(width: Self.contentWidth, height: height)
    }

    /// 图表文本字体（走主面板字体档 PanelFont）
    private func uiFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        PanelFont.font(size: size, weight: weight)
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
        if changed {
            syncRowMaterial()
            needsDisplay = true
        }
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
            syncRowMaterial()
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
        if showsInlineCoin, numberRowRect.insetBy(dx: -3, dy: -3).contains(p) { return true }
        return false
    }

    /// 点击切换：总计周期（5H/1D/1W/1M）与「每日/每周」「项目/模型」视图；
    /// 点击大数值整行：内嵌硬币自旋一圈（2026-09-12 用户指定。硬币圆内点击由
    /// Coin3DView 自己的 mouseUp 处理、到不了这里，不会双重自旋）
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
        } else if showsInlineCoin, numberRowRect.insetBy(dx: -3, dy: -3).contains(p) {
            // 用户直点整行：与直点硬币同口径，绕过程序化自旋的 0.3s 去抖
            inlineCoin.spin()
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
        rebuildMetricsIfNeeded()   // 文本度量/月份轴/行文本缓存：数据或字体变化时一次性重建
        let labelFont = makeLabelFont()
        // 次级文案 = **副前景灰**（2026-09-14 用户要求「Token 板块中的也改」）：覆盖面
        // 周期切换（5h…All）/ 项目-模型切换 / 每日-每周切换的**未选中态**、月份轴、列表次要列 ——
        // 与区块标题同源（= 系统灰为基准 + 按面板底色解算对比度补偿），原为系统
        // `secondaryLabelColor`（只随外观分档、不随底色解算）
        let labelColor = Palette.secondaryForeground
        // 区块标题统一副前景灰 = 小表格口径（与列表行同色）
        let titleColor = SmallTable.textColor

        // ── 首行：平台名 + 总计（字重比区块标题低一档，两段间留 4pt 间距）──
        let titleFont = makeHeaderTitleFont()
        drawText(source.platformName, at: NSPoint(x: insets.left, y: totalLabelTop),
                 font: titleFont, color: titleColor)
        drawText("总计", at: NSPoint(x: insets.left + ceil(cachedNameWidth) + 4, y: totalLabelTop),
                 font: titleFont, color: titleColor)

        // ── 首行右侧：周期切换（5H/1D/1W/1M；选中 = 主前景 + 字重加一档 medium，
        // 未选 = 次级灰 regular；槽位宽按选中态字体测量，切换不跳）──
        // 大数值整行命中区：与 layout() 的数字行同一几何（numberRowY 共用推导）
        numberRowRect = NSRect(x: 0, y: numberRowY, width: bounds.width,
                               height: Self.numberRowBaseHeight)
        periodToggleRects = []
        let pWidths = cachedPeriodWidths
        let periodSelectedFont = makePeriodSelectedFont()
        var px = bounds.width - insets.right - cachedPeriodTotal
        let pY = totalLabelTop + (titleInkHeight - labelFont.boundingRectForFont.height) / 2
        for (i, p) in TokenPeriod.allCases.enumerated() {
            drawText(p.label, at: NSPoint(x: px, y: pY),
                     font: period == p ? periodSelectedFont : labelFont,
                     color: period == p ? Palette.cardForeground : labelColor)
            periodToggleRects.append(NSRect(x: px, y: totalLabelTop,
                                            width: pWidths[i], height: titleInkHeight))
            px += pWidths[i] + 6
        }

        // ── 总计大数字：RollingNumberView 子视图渲染（layout() 定位，summary didSet 驱动滚动）──

        // ── 列表区块头 ──（WB 双数据齐备时右上角「项目/模型」切换，样式同词元活动的每日/每周）
        let allModels = summary?.models ?? []
        let showModels = listMode == .models && !allModels.isEmpty
        // 列表随总计周期换数据：All = 全量列表，窗口周期取各窗口聚合（窗口内无用量 = 空列表）
        let projects = summary.map {
            Array($0.listRows(period: period, isModels: showModels).prefix(Self.maxListRows))
        } ?? []
        let sectionY = sectionLabelTop
        drawText(showModels ? "模型" : "项目", at: NSPoint(x: insets.left, y: sectionY),
                 font: titleFont, color: titleColor)
        projectToggleRect = .zero
        modelToggleRect = .zero
        if !allModels.isEmpty {
            let tFont = labelFont
            let modelW = cachedToggleModelW
            let projW = cachedToggleProjW
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
        // 占位态（summary 未到）：列表区按 maxListRows 画灰条骨架（2026-09-09 用户指定），
        // 词元活动标题按满行数排——骨架行填补后与点阵之间不再有空白带
        if summary == nil {
            drawSkeletonRows(count: Self.maxListRows, topY: listStartTop)
        }
        if !projects.isEmpty && summary != nil {
            // 行字体 = 用量行同款（小表格口径）：名称/百分比 medium，数值等宽数字；
            // 切换过渡期按逐行交错进度绘制(行遮罩显影:行带内自下缘上滑入位),常态直绘零开销
            let nameFont = SmallTable.rowFont()
            let valueFont = SmallTable.rowFont(monoDigits: true)
            let pctFont = SmallTable.rowFont()
            if let start = switchTransitionStart {
                let elapsed = CACurrentMediaTime() - start
                listEndY = drawProjectRows(projects, baseTotal: listBaseTotal, topY: listStartTop,
                                           nameFont: nameFont, valueFont: valueFont, pctFont: pctFont,
                                           rowReveals: (0..<projects.count).map { i in
                                               let t = (elapsed - Double(i) * Self.staggerDelay) / Self.rowDuration
                                               return CGFloat(easeOutCubic(min(1, max(0, t))))
                                           })
            } else {
                listEndY = drawProjectRows(projects, baseTotal: listBaseTotal, topY: listStartTop,
                                           nameFont: nameFont, valueFont: valueFont, pctFont: pctFont)
            }
        }

        // 词元活动顶 = 末行墨迹底 + 20（行框居中留白不计入间距）。标题与点阵恒按满行数
        // （maxListRows）排——intrinsic 高度与点阵都钉死满行数（行数少留白留在列表区），
        // 标题若跟实际行数走会与点阵错开一条空带（2026-09-09 两行项目实测）
        drawActivitySection(topY: activityTitleTop(rows: Self.maxListRows),
                            gridTop: activityGridTop(rows: Self.maxListRows),
                            labelFont: labelFont, labelColor: labelColor, titleColor: titleColor)
        // 行命中框/可点击路径已随本次绘制更新：光标矩形仅在命中内容实际变化时才
        // 通知窗口重算（切换动效 42 帧零窗口级重算；原实现每帧无条件 invalidate）
        if listRowRects != lastCursorRowRects || listRowPaths != lastCursorRowPaths {
            lastCursorRowRects = listRowRects
            lastCursorRowPaths = listRowPaths
            window?.invalidateCursorRects(for: self)
        }
    }

    /// 项目行：文件夹 icon + 项目名（限宽截断）+ token 值 + 百分比；返回行块底部 Y。
    /// baseTotal = 百分比/hover 占比条的分母（周期口径：All = 全量总计，窗口 = periodTotals[period]）。
    /// 内容（icon/名/值/百分比）统一系统灰（语义色随主题适配）；
    /// hover 行（hoveredListRow）背景只显百分比条 + 1.2pt 发丝边框（2026-08-31 用户要求
    /// 去掉用量行同款渐变底、边框保留；2026-09-14 起占比条底色改用 hover 材质色
    /// `Palette.hoverGradientBright` —— 2026-09-15 该色与点阵底点色合并为「次背景色」），文字/icon 仍提亮到 Palette.cardForeground，
    /// 命中框回填 listRowRects 供 mouseMoved 判定。
    /// rowReveals = 平台切换动效的逐行交错进度（nil = 常态直绘）：每行裁切到行带、
    /// 内容自「起始全遮最小行程」(行高+墨迹高)/2 上滑显影，淡入全程同步（alpha=rv），
    /// CG 变换实现、绘制坐标不变、命中框仍按最终几何记录
    @discardableResult
    /// 占位骨架行（summary 未到时列表区）：与真实行同构的四列——icon 圆点 + 名称灰条 +
    /// 数值灰条 + 百分比灰条，列位/列宽与 drawProjectRows 一致，色与点阵底点同源
    ///（secondaryBackground = 次背景色），名称/数值宽度逐行错开避免呆板
    private func drawSkeletonRows(count: Int, topY: CGFloat) {
        let pctColWidth: CGFloat = 45
        let valueRight = bounds.width - insets.right - pctColWidth
        let valueColWidth: CGFloat = 40
        let nameX = insets.left + 14
        let barH: CGFloat = 8
        let nameWidths: [CGFloat] = [92, 66, 80, 58]
        Palette.secondaryBackground.setFill()
        for i in 0..<count {
            let y = topY + CGFloat(i) * rowHeight + (rowHeight - barH) / 2
            // icon：10×10 圆点（与真实行 iconRect 同位同径）
            let iconRect = NSRect(x: insets.left, y: topY + CGFloat(i) * rowHeight + (rowHeight - 10) / 2,
                                  width: 10, height: 10)
            NSBezierPath(ovalIn: iconRect).fill()
            // 名称条 / 数值条（右对齐至数值列右缘）/ 百分比条（右对齐内容缘）
            let nameRect = NSRect(x: nameX, y: y, width: nameWidths[i % nameWidths.count], height: barH)
            let valueRect = NSRect(x: valueRight - valueColWidth, y: y, width: valueColWidth, height: barH)
            let pctRect = NSRect(x: bounds.width - insets.right - 38, y: y, width: 38, height: barH)
            let shapes: [(NSRect, NSBezierPath)] = [
                (iconRect, NSBezierPath(ovalIn: iconRect)),
                (nameRect, NSBezierPath(roundedRect: nameRect, xRadius: barH / 2, yRadius: barH / 2)),
                (valueRect, NSBezierPath(roundedRect: valueRect, xRadius: barH / 2, yRadius: barH / 2)),
                (pctRect, NSBezierPath(roundedRect: pctRect, xRadius: barH / 2, yRadius: barH / 2)),
            ]
            // 渐变扫光（2026-09-10 用户指定）：每条灰条/圆点上叠一道左→右移动的高光
            // 渐变带（透明→峰→透明），行程 = 形状宽 + 带宽，逐行错开 0.15 相位；
            // clip 到形状路径内绘制，出带即熄、循环重扫。timer 驱动见 startSkeletonShimmerIfNeeded
            startSkeletonShimmerIfNeeded()
            let elapsed = CACurrentMediaTime() - (skeletonShimmerStart ?? CACurrentMediaTime())
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let peak = isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.65)
            let gradient = NSGradient(colors: [peak.withAlphaComponent(0), peak, peak.withAlphaComponent(0)])
            let rowPhase = elapsed / Self.shimmerDuration + Double(i) * 0.15
            for (rect, path) in shapes {
                path.fill()
                guard let gradient else { continue }
                let bandW = max(18, rect.width * 0.6)
                let travel = rect.width + bandW
                let phase = rowPhase.truncatingRemainder(dividingBy: 1)
                let bandRect = NSRect(x: rect.minX - bandW + CGFloat(phase) * travel,
                                      y: rect.minY, width: bandW, height: rect.height)
                if let cg = NSGraphicsContext.current?.cgContext {
                    cg.saveGState()
                    path.addClip()
                    gradient.draw(in: bandRect, angle: 0)
                    cg.restoreGState()
                }
            }
        }
    }

    private func drawProjectRows(_ projects: [TokenSummary.ProjectUsage], baseTotal: Int64,
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
            // 行级交错（平台切换动效）= 遮罩显影 + 淡入同步：裁切到本行行带上滑入位
            // （overflow-hidden 式），alpha 恒随 rv 走完整段（曾按 0.4/0.7 提前补满，
            // easeOutCubic 前段太快淡入 ~140ms 即结束，用户实测读作「没有透明度变化」，
            // 勿再改回提前补满）。行程 = 起始全遮最小值 (行高+墨迹高)/2：文字顶
            // (行带内居中后距带底恰为此值) 在 rv=0 时恰好贴住行带下缘；行程小于此值
            // 上升前必露文字顶缘（10pt 版实测 bug，勿再缩小）
            let rowReveal = rowReveals?[i]
            var rowMasked = false
            if let rv = rowReveal, rv < 1 {
                cg?.saveGState()
                cg?.setAlpha(rv)
                cg?.clip(to: NSRect(x: 0, y: rowY, width: bounds.width, height: rowH))
                cg?.translateBy(x: 0, y: (1 - rv) * (rowH + rowInkHeight) / 2)
                rowMasked = true
            }
            defer { if rowMasked { cg?.restoreGState() } }
            let hovered = i == hoveredListRow
            let rowColor: NSColor = hovered ? Palette.cardForeground : SmallTable.textColor
            // 百分比背景条（仅 hover 行显示）：按行占比从左到右填充行底。
            // 底色 = **次背景色**（`Palette.hoverGradientBright` → `secondaryBackground`，
            // 与 HoverMaterialHost 材质块同源）—— 2026-09-14 用户「去掉百分比进度的背景色，
            // 使用卡片 hover 背景色」；2026-09-15 该色与点阵底点色合并为同一个「次背景色」参数。
            // 常态行无背景
            if hovered {
                let pctBarRatio = baseTotal > 0
                    ? CGFloat(p.tokens) / CGFloat(baseTotal) : 0
                let barRect = NSRect(x: 0, y: rowY,
                                     width: bounds.width * pctBarRatio, height: rowH)
                let barPath = NSBezierPath(roundedRect: barRect, xRadius: 6, yRadius: 6)
                Palette.hoverGradientBright.setFill()
                barPath.fill()
            }
            // hover 描边 2026-09-13 移入共享材质宿主（行间整块滑动，viewDidMoveToWindow
            // 处安装、syncRowMaterial 驱动）；行内只保留占比条与文字/icon 提亮
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
            let valueText: String, valueW: CGFloat
            if let m = i < cachedRowMetrics.count ? cachedRowMetrics[i] : nil {
                (valueText, valueW) = (m.value, m.valueW)
            } else {
                // 兜底（缓存与行数短暂错位时）：现算，下一帧度量重建即恢复
                valueText = ZcodeTokenStore.cnCompact(p.tokens)
                valueW = valueText.size(withAttributes: [.font: valueFont]).width
            }
            let valueH = valueFont.boundingRectForFont.height
            drawText(valueText, at: NSPoint(x: valueLeft + (valueColWidth - valueW), y: rowY + (rowH - valueH) / 2),
                     font: valueFont, color: rowColor)
            // 百分比一位小数（"69.6%"；各行四舍五入之和可能 ≠100%，属正常舍入误差）
            let pctText: String, pctW: CGFloat
            if let m = i < cachedRowMetrics.count ? cachedRowMetrics[i] : nil {
                (pctText, pctW) = (m.pct, m.pctW)
            } else {
                let pctValue = baseTotal > 0
                    ? Double(p.tokens) / Double(baseTotal) * 100 : 0
                pctText = String(format: "%.1f%%", pctValue)
                pctW = pctText.size(withAttributes: [.font: pctFont]).width
            }
            let pctH = pctFont.boundingRectForFont.height
            drawText(pctText, at: NSPoint(x: bounds.width - insets.right - pctW, y: rowY + (rowH - pctH) / 2),
                     font: pctFont, color: rowColor)
            rowY += rowH
        }
        return rowY
    }

    // MARK: 平台切换动效（大数字 = 数值滚动；列表行交错遮罩显影；
    // 热力图点阵旧点亮出→新点亮入交叉淡变（0.6s），标题/表头/月份轴静止）

    /// 交错节奏(用户指定 2026-08-31,加长时长不适用 Motion.emphasis 0.40 硬顶,同 Motion.roll 口径):
    /// 行间延迟 0.1s、单行 0.4s;末行完成 = 0.3 + 0.4 = 0.7s
    private static let staggerDelay: Double = 0.1
    private static let rowDuration: Double = 0.4
    /// 切换动效总时长（timer 终点 = 列表末行完成时刻，点阵列延迟以此为摊派上限）
    private static var switchTotalDuration: Double {
        rowDuration + staggerDelay * Double(maxListRows - 1)
    }
    /// 进行中的切换动效起始时刻;nil = 常态直绘
    private var switchTransitionStart: CFTimeInterval?
    /// 出帧源 = 显示器刷新率（DisplayTicker），非 60Hz 定频：120Hz 屏上逐帧推进
    private var switchTicker: DisplayTicker?
    /// 「每日/每周」切换专用的点阵波次起始（平台切换进行中恒为 nil，点阵随切换波次走）
    private var dotFadeStart: CFTimeInterval?
    private var dotFadeTicker: DisplayTicker?
    /// 点阵淡出/淡入时长（用户指定 2026-08-31：0.6s，双向 ease-in-out，
    /// 独立于列表行 0.4s 节奏；平台切换 timer 总时长 0.7s 覆盖之）
    private static let dotFadeDuration: Double = 0.6
    /// 上一次绘制的点亮度点快照（rect+level）：动效起点取作「旧点」做淡出
    private var lastLitDots: [(rect: NSRect, level: Int)] = []
    /// 动效期间参与淡出的旧点（起点自 lastLitDots 截取，动效结束清空）
    private var outgoingDots: [(rect: NSRect, level: Int)] = []

    // MARK: 骨架行渐变扫光（占位态 shimmer，2026-09-10 用户指定）

    /// 占位骨架行扫光起始时刻（nil = 非占位态）；出帧源 = 显示器刷新率，
    /// 每帧 needsDisplay 驱动 draw 现算相位
    private var skeletonShimmerStart: CFTimeInterval?
    private var skeletonShimmerTicker: DisplayTicker?
    /// 扫光一个完整行程的时长；逐行错开 0.15 个相位
    private static let shimmerDuration: Double = 1.6

    /// 占位态扫光驱动：draw 里发现 summary 未到即启动；数据到达 / 离开窗口 / 隐藏自停
    private func startSkeletonShimmerIfNeeded() {
        guard skeletonShimmerTicker == nil, window != nil else { return }
        if skeletonShimmerStart == nil { skeletonShimmerStart = CACurrentMediaTime() }
        let ticker = DisplayTicker(host: self) { [weak self] in
            guard let self else { return false }
            guard self.summary == nil, self.window != nil, !self.isHidden else {
                self.stopSkeletonShimmer()
                return false
            }
            self.needsDisplay = true
            return true
        }
        skeletonShimmerTicker = ticker
        ticker.start()
    }

    private func stopSkeletonShimmer() {
        skeletonShimmerTicker?.stop()
        skeletonShimmerTicker = nil
        skeletonShimmerStart = nil
    }

    private func easeOutCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    private func easeInOutCubic(_ p: Double) -> Double {
        p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    /// 平台切换动效入口(refreshInlineTokens 在 summary 换新前调用)。
    /// 大数字不再做 alpha+上移：置 slideNextTotalRoll，summary 落值时经 RollingNumberView
    /// 从旧平台值整组滑移滚到新值（与周期切换同款）；列表行在 draw 内按逐行交错进度绘制。
    /// 系统「减弱动态效果」开启时直接落定不做行/点阵动效。
    func beginSwitchTransition() {
        switchTicker?.stop()
        switchTicker = nil
        stopDotFade()   // 平台切换接管点阵波次，独立波次作废
        slideNextTotalRoll = true   // 大数字：下一次 summary 落值走整组滑移滚动
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        outgoingDots = lastLitDots   // 旧平台点亮出（此时 summary 未清，快照仍是旧数据）
        switchTransitionStart = CACurrentMediaTime()
        let total = Self.switchTotalDuration
        let ticker = DisplayTicker(host: self) { [weak self] in
            guard let self, let start = self.switchTransitionStart else { return false }
            if CACurrentMediaTime() - start >= total {
                self.endSwitchTransition()
                return false
            }
            // 行块动效在 draw 内按当前时刻计算进度,每帧驱动宿主重绘
            // (大数字滚动由 RollingNumberView 自管,列表行是 draw 自绘,漏了就整段不动)
            self.needsDisplay = true
            return true
        }
        switchTicker = ticker
        ticker.start()
    }

    private func endSwitchTransition() {
        switchTransitionStart = nil
        switchTicker = nil   // link 已由 ticker 自停（step 返回 false），这里只清引用
        outgoingDots.removeAll()
        releaseDotsImages()   // 淡变结束：位图释放，常态回逐点直绘
        needsDisplay = true
    }

    /// 「每日/每周」切换入口：点阵独立重挂旧点亮出→新点亮入（0.6s 双向 ease-in-out），
    /// 只动点阵不碰大数字/列表行；平台切换进行中不另起（点阵已在切换淡入里）。
    /// 自绘点阵无图层可挂动画，靠 DisplayTicker 每帧 needsDisplay 驱动 draw 现算进度
    func restartDotFade() {
        stopDotFade()
        guard switchTransitionStart == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        outgoingDots = lastLitDots   // 旧模式点亮出（didSet 时上一帧 draw 仍是旧模式几何）
        dotFadeStart = CACurrentMediaTime()
        let total = Self.dotFadeDuration
        let ticker = DisplayTicker(host: self) { [weak self] in
            guard let self, let start = self.dotFadeStart else { return false }
            if CACurrentMediaTime() - start >= total {
                self.dotFadeTicker = nil
                self.dotFadeStart = nil
                self.outgoingDots.removeAll()
                self.releaseDotsImages()   // 淡变结束：位图释放
                return false
            }
            self.needsDisplay = true
            return true
        }
        dotFadeTicker = ticker
        ticker.start()
    }

    private func stopDotFade() {
        dotFadeTicker?.stop()
        dotFadeTicker = nil
        dotFadeStart = nil
        outgoingDots.removeAll()
        releaseDotsImages()   // 中断/重启：位图作废，新 wave 首帧按需重烘
    }

    // MARK: 词元活动热力图

    /// 区块标题 + 每日/每周切换 + 圆角方块点阵（用量越多越亮）。
    /// 每日 = 7 行（周一→周日）× 26 周列；每周 = 单行 26 点（每周合计）。
    /// topY/gridTop 由锚点链传入（activityTitleTop/activityGridTop），与 intrinsic 同源。
    /// ⚠️ 标题文案 2026-09-17 用户连改三次：`词元活动` → `Token activity` → `Token活动` → **`Token 活动`**
    ///（最后一次是「中间加间隔」= 补一个半角空格，与同一行右侧的「每日 / 每周」同一语言；
    ///  标题左对齐、切换器右对齐，改文案不会互相顶到）
    private func drawActivitySection(topY: CGFloat, gridTop gridTopAnchor: CGFloat, labelFont: NSFont,
                                     labelColor: NSColor, titleColor: NSColor) {
        drawText("Token 活动", at: NSPoint(x: insets.left, y: topY),
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

        // ── 点阵（全格子绘制：无用量 = 底色点，有用量 = 渐变亮点；格内四周各缩半隙）──
        dotCells.removeAll()
        let pitch = activityPitch
        let gap = activityDotGap
        let size = pitch - gap
        let gridTop = gridTopAnchor
        let cells = activityCells()
        let maxVal = cells.map(\.tokens).max() ?? 0
        // 平台切换/每日·每周切换动效：新点阵淡入 + 旧点阵盖顶淡出的交叉溶解（0.6s
        // 双向 ease-in-out，整体同步、无列间交错、不上移）；仅有用量的点亮度点参与，
        // 无用量底点恒亮不动；常态逐点直绘，淡变帧走位图合成（性能：3 次整图 blit
        // 替代 ~364 次逐点 draw）
        let waveStart = switchTransitionStart ?? dotFadeStart
        let waveP: CGFloat = {
            guard let waveStart else { return 1 }
            let t = min(1, max(0, (CACurrentMediaTime() - waveStart) / Self.dotFadeDuration))
            return CGFloat(easeInOutCubic(t))
        }()
        lastLitDots.removeAll(keepingCapacity: true)
        if waveStart != nil {
            // 位图合成：新底点整图（恒不透明）+ 新亮点整图（alpha=waveP 淡入）先画，
            // 旧亮点整图最后画（alpha=out 淡出，盖在新点阵之上）——交叉溶解。旧点
            // 必须先画会残留边缘带（半透明抗锯齿像素叠半透明无法覆盖，旧点光晕穿透
            // 新点边缘成「亮边」）；最后画则旧点是整体淡出，无穿透轮廓（2026-09-01）
            // 命中框 dotCells 与下轮淡出快照 lastLitDots 仍逐格回填（纯算术，无绘制）
            if dotsImagesDirty || incomingLitImage == nil {
                let region = NSRect(x: insets.left, y: gridTop,
                                    width: bounds.width - insets.left - insets.right,
                                    height: 7 * pitch)
                rebuildIncomingDotsImages(cells: cells, region: region, maxVal: maxVal)
                dotsImagesDirty = false
            }
            if outgoingDotsImage == nil, !outgoingDots.isEmpty,
               let baked = renderDotsBitmap(outgoingDots, region: nil) {
                outgoingDotsImage = baked.image
                outgoingDotsRegion = baked.region
            }
            if let img = incomingEmptyImage {
                img.draw(in: incomingRegion, from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: true, hints: nil)
            }
            if waveP > 0.004, let img = incomingLitImage {
                img.draw(in: incomingRegion, from: .zero, operation: .sourceOver,
                         fraction: waveP, respectFlipped: true, hints: nil)
            }
            let out = 1 - waveP
            if out > 0.004, let img = outgoingDotsImage {
                img.draw(in: outgoingDotsRegion, from: .zero, operation: .sourceOver,
                         fraction: out, respectFlipped: true, hints: nil)
            }
            for c in cells {
                let rect = NSRect(x: insets.left + CGFloat(c.col) * pitch + gap / 2,
                                  y: gridTop + CGFloat(c.row) * pitch + gap / 2,
                                  width: size, height: size)
                let level = (c.tokens <= 0 || maxVal <= 0) ? 0
                    : min(4, 1 + Int(Double(c.tokens) / Double(maxVal) * 3.999))
                if level > 0 { lastLitDots.append((rect, level)) }
                dotCells.append(DotCell(rect: rect, day: c.day, tipTokens: c.tipTokens))
            }
        } else {
            // 常态路径：逐点直绘（waveP == 1，等价全亮度）
            for c in cells {
                let rect = NSRect(x: insets.left + CGFloat(c.col) * pitch + gap / 2,
                                  y: gridTop + CGFloat(c.row) * pitch + gap / 2,
                                  width: size, height: size)
                let level = (c.tokens <= 0 || maxVal <= 0) ? 0
                    : min(4, 1 + Int(Double(c.tokens) / Double(maxVal) * 3.999))
                stamp(level: level).draw(in: rect, from: .zero, operation: .sourceOver,
                                         fraction: level == 0 ? 1 : waveP,
                                         respectFlipped: true, hints: nil)
                if level > 0 { lastLitDots.append((rect, level)) }
                dotCells.append(DotCell(rect: rect, day: c.day, tipTokens: c.tipTokens))
            }
        }

        // ── 横坐标月份标签：首尾贴齐网格两端、中间等距（最左锚网格左缘），文本左对齐 ──
        //（位置与文案已随绘制度量缓存预计算，draw 只读，零 Calendar/Formatter 开销）
        let axisY = gridTop + 7 * pitch + 4
        for (text, x) in cachedMonthLabels {
            drawText(text, at: NSPoint(x: x, y: axisY), font: labelFont, color: labelColor)
        }

        // hover 圆点：外圈高亮环 + 悬浮提示（日期 + 用量，中文量级）
        if let hi = hoveredDot, dotCells.indices.contains(hi) {
            let cell = dotCells[hi]
            // 描边居中于路径：外扩半个线宽（0.5pt）→ 环内缘紧贴点边缘；
            // 圆角半径随环尺寸等比（与点印章同 0.3 比例，环与点形状同心一致）
            let ring = cell.rect.insetBy(dx: -0.5, dy: -0.5)
            Palette.heatDotRing.setStroke()
            let path = NSBezierPath(roundedRect: ring, xRadius: ring.width * 0.3, yRadius: ring.width * 0.3)
            path.lineWidth = 1
            path.stroke()
            drawTooltip(for: cell, anchor: cell.rect)
        }
    }

    /// 生成热力图全格子（无用量也占位，供底色与 hover）：
    /// 每日 = 窗口周列 × 7 行逐日；每周 = 窗口周列周合计单行点亮列内。
    /// 结果按 (daily, activityMode, 窗口起点) 缓存，draw 重复进入零重算
    private func activityCells() -> [ActivityCell] {
        let window = activityWindow()
        // 占位态（数据未到）：全底色点阵（tokens 恒 0）——2026-09-08 用户要求
        // 「词元活动的占位显示只有背景色的点阵」，网格形态/月份轴与加载后一致
        guard let summary else {
            if let c = activityPlaceholderCache,
               c.mode == activityMode, c.windowStart == window.start {
                return c.cells
            }
            var cells: [ActivityCell] = []
            for col in 0..<window.cols {
                for row in 0..<7 {
                    let day = window.start.addingTimeInterval(TimeInterval((col * 7 + row) * 86400))
                    cells.append(ActivityCell(col: col, row: row, tokens: 0, day: day, tipTokens: 0))
                }
            }
            activityPlaceholderCache = (activityMode, window.start, cells)
            return cells
        }
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
        dotsImagesDirty = true   // 点阵数据重算 → 淡变位图（如启用）随新数据重烘
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

    // MARK: 绘制度量缓存（性能：动画帧零 size() 实测 / 零 Calendar 运算）

    /// 度量缓存失效标记：summary/source/listMode/period/monoFont didSet 与 layout() 宽度变化置位，
    /// draw 头部统一重建。覆盖文本度量全部输入（内容、字体、几何），不随 hover/动效进度变化
    private var metricsDirty = true
    private var cachedNameWidth: CGFloat = 0
    private var cachedPeriodWidths: [CGFloat] = []
    private var cachedPeriodTotal: CGFloat = 0
    private var cachedToggleModelW: CGFloat = 0
    private var cachedToggleProjW: CGFloat = 0
    private var cachedMonthLabels: [(text: String, x: CGFloat)] = []
    /// 列表行文本度量：drawProjectRows 逐帧只读（原实现每帧 ≤4 行 × 2 次 size() 实测）
    private var cachedRowMetrics: [(value: String, valueW: CGFloat,
                                    pct: String, pctW: CGFloat)] = []
    /// 光标矩形变化检测（draw 尾部）：命中矩形/路径实际变化才通知窗口重算
    private var lastCursorRowRects: [NSRect] = []
    private var lastCursorRowPaths: [String?] = []

    private func rebuildMetricsIfNeeded() {
        guard metricsDirty else { return }
        metricsDirty = false
        let labelFont = makeLabelFont()
        // 平台名宽度按首行标题字体测量（与 draw 处同一字体，「总计」落位才对齐）
        let titleFont = makeHeaderTitleFont()
        cachedNameWidth = (source.platformName as NSString)
            .size(withAttributes: [.font: titleFont]).width
        // 周期槽宽按选中态字体（medium）测：选中切换时槽位/整块宽度不跳
        cachedPeriodWidths = TokenPeriod.allCases.map {
            ($0.label as NSString).size(withAttributes: [.font: makePeriodSelectedFont()]).width
        }
        let pGap: CGFloat = 6
        cachedPeriodTotal = cachedPeriodWidths.reduce(0, +)
            + pGap * CGFloat(TokenPeriod.allCases.count - 1)
        cachedToggleModelW = ("模型" as NSString).size(withAttributes: [.font: labelFont]).width
        cachedToggleProjW = ("项目" as NSString).size(withAttributes: [.font: labelFont]).width
        // 月份轴：Calendar.date(byAdding:) ×5 + DateFormatter 格式化只在重建时执行一次。
        // 首尾贴齐分布：最左标签锚网格左缘，按最宽文案「10月」恒量预留末档右缘贴网格右缘，
        // 中间等距——较「网格宽 ÷ 月数」等分加大月间距；预留不随实际月份文案变化，
        // 五档位置跨月恒定不漂移（gridWidth = cols × pitch 恒等于版心宽，周列数增加亦不影响）
        let window = activityWindow()
        let gridWidth = CGFloat(window.cols) * activityPitch
        var labels: [(text: String, x: CGFloat)] = []
        for offset in 0..<Self.activityMonths {
            guard let m = Calendar.current.date(byAdding: .month, value: offset,
                                               to: window.firstMonth) else { continue }
            labels.append((Self.monthAxisFmt.string(from: m), 0))
        }
        let lastLabelW = ceil(("10月" as NSString)
            .size(withAttributes: [.font: labelFont]).width)
        let step = max(0, (gridWidth - lastLabelW) / CGFloat(Self.activityMonths - 1))
        for i in labels.indices { labels[i].x = insets.left + CGFloat(i) * step }
        cachedMonthLabels = labels
        // 列表行数值/百分比文本与宽度
        let valueFont = SmallTable.rowFont(monoDigits: true)
        let pctFont = SmallTable.rowFont()
        if let summary {
            let showModels = listMode == .models && !summary.models.isEmpty
            // 行随总计周期换数据：All = 全量列表，窗口周期取各窗口聚合，分母同大数字口径
            let rows = Array(summary.listRows(period: period, isModels: showModels)
                .prefix(Self.maxListRows))
            let base = listBaseTotal
            cachedRowMetrics = rows.map { p in
                let value = ZcodeTokenStore.cnCompact(p.tokens)
                let pct = String(format: "%.1f%%", base > 0
                    ? Double(p.tokens) / Double(base) * 100 : 0)
                return (value,
                        (value as NSString).size(withAttributes: [.font: valueFont]).width,
                        pct,
                        (pct as NSString).size(withAttributes: [.font: pctFont]).width)
            }
        } else {
            cachedRowMetrics = []
        }
    }

    // MARK: 点阵交叉淡变位图合成（性能：淡变帧 3 次 blit 替代 ~364 次逐点 draw）

    private var outgoingDotsImage: NSImage?
    private var outgoingDotsRegion: NSRect = .zero
    /// 新点阵整图两张：底点（level 0，恒不透明）与亮点（alpha = waveP）
    private var incomingEmptyImage: NSImage?
    private var incomingLitImage: NSImage?
    private var incomingRegion: NSRect = .zero
    /// 位图失效标记：activityCells 重算 / 几何变化 / 外观变化时置位
    private var dotsImagesDirty = true

    /// 点阵亮度点整图烘焙（位图像素 = region 尺寸 × 2，点尺寸 = region 原分数尺寸，
    /// blit 恒 1:1 与直绘几何一致）。region 传 nil 时取点集联合包围盒。位图上下文 y 向上、
    /// view 翻转坐标 y 向下，逐点做镜像换算，blit 回视图（respectFlipped: true）时几何严格还原。
    private func renderDotsBitmap(_ dots: [(rect: NSRect, level: Int)],
                                  region given: NSRect?) -> (image: NSImage, region: NSRect)? {
        guard !dots.isEmpty else { return nil }
        var region: NSRect
        if let given {
            region = given
        } else {
            region = dots[0].rect
            for d in dots.dropFirst() { region = region.union(d.rect) }
        }
        // 按 region 原分数尺寸烘焙：像素 = 尺寸×2 取整，rep.size / NSImage.size = region 原尺寸，
        // blit 回同尺寸 rect 恒 1:1 无重采样，与逐点直绘路径几何严格一致
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((region.width * scale).rounded()),
                                         pixelsHigh: Int((region.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = region.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for d in dots {
            let r = NSRect(x: d.rect.minX - region.minX,
                           y: region.height - (d.rect.maxY - region.minY),
                           width: d.rect.width, height: d.rect.height)
            stamp(level: d.level).draw(in: r, from: .zero, operation: .sourceOver,
                                       fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return (NSImage(cgImage: cg, size: region.size), region)
    }

    /// 新点阵整图两张（底点/亮点分离：底点恒不透明，亮点随 waveP 淡入）
    private func rebuildIncomingDotsImages(cells: [ActivityCell], region: NSRect, maxVal: Int64) {
        let pitch = activityPitch
        let gap = activityDotGap
        let size = pitch - gap
        var empty: [(rect: NSRect, level: Int)] = []
        var lit: [(rect: NSRect, level: Int)] = []
        for c in cells {
            let rect = NSRect(x: insets.left + CGFloat(c.col) * pitch + gap / 2,
                              y: region.minY + CGFloat(c.row) * pitch + gap / 2,
                              width: size, height: size)
            let level = (c.tokens <= 0 || maxVal <= 0) ? 0
                : min(4, 1 + Int(Double(c.tokens) / Double(maxVal) * 3.999))
            if level == 0 { empty.append((rect, 0)) } else { lit.append((rect, level)) }
        }
        incomingEmptyImage = renderDotsBitmap(empty, region: region)?.image
        incomingLitImage = renderDotsBitmap(lit, region: region)?.image
        incomingRegion = region
    }

    /// 释放淡变位图（wave 结束/中断时调用，下次 wave 按需重烘）
    private func releaseDotsImages() {
        outgoingDotsImage = nil
        incomingEmptyImage = nil
        incomingLitImage = nil
    }

    /// 亮度第 level 级的圆角方块印章（懒建缓存，圆角 = 边长 × 0.3）：
    /// 0 = 无用量底色（动态色，浅色外观=浅灰），
    /// 1-4 = 深色 GitHub 暗色绿阶离散色 / 浅色两端点插值。动态色按本视图 effectiveAppearance 解算成实色
    /// 后烘焙（NSImage 位图缓存会定格颜色，主题/浅色开关切换经 viewDidChangeEffectiveAppearance
    /// 清缓存重建）
    private func stamp(level: Int) -> NSImage {
        if dotStamps.count <= level {
            dotStamps.append(contentsOf: Array(repeating: nil, count: level + 1 - dotStamps.count))
        }
        if let cached = dotStamps[level] { return cached }
        var color = Palette.heatLevelColor(level, dark: effectiveAppearance.isDark)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = color.usingColorSpace(.deviceRGB) ?? color
        }
        let size = activityPitch - activityDotGap
        let radius = size * 0.3
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                         xRadius: radius, yRadius: radius).fill()
            return true
        }
        dotStamps[level] = img
        return img
    }

    /// 面板 icon 统一入口：来源（品牌 SVG / SF Symbol）一律 sourceAtop 单色化后按键缓存
    /// （品牌色直接上屏在深色玻璃上不可读；单色化与文件历史定稿一致）。
    /// ⚠️ 键里带上解算后的色值：位图把颜色烘死了，色变了必须重烘 —— 副前景色会随面板底色
    /// 加深/提亮，只按 symbol 命中的话换底色后面板里会留着旧灰的行图标
    private func tintedIcon(key: String, color: NSColor, make: () -> NSImage?) -> NSImage? {
        let cacheKey = key + "@" + bakedColorTag(color)
        if let cached = iconCache[cacheKey] { return cached }
        guard let base = make() else { return nil }
        let img = tintedImage(base, color)
        iconCache[cacheKey] = img
        return img
    }

    /// 烘色位图的色标签（缓存键用）：按**视图生效外观**解算到 sRGB 再取分量 ——
    /// lockFocus 里 NSAppearance.current 是系统外观，浅色主题下面板强制 aqua 时直读会解错分支
    private func bakedColorTag(_ color: NSColor) -> String {
        var resolved: NSColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let c = resolved else { return "?" }
        return String(format: "%.3f,%.3f,%.3f,%.2f",
                      c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// 列表行图标：SF Symbol 单色化（常态副前景灰 = 行文本同色；hover 行提亮到主前景色，
    /// 缓存键区分亮度）
    private func rowIcon(bright: Bool) -> NSImage? {
        let symbol = rowIconSymbol
        return tintedIcon(key: bright ? symbol + ".bright" : symbol,
                          color: bright ? Palette.cardForeground : Palette.secondaryForeground) {
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        }
    }

    /// header 色相按钮改了峰值色：点阵印章/淡变位图都烘了旧色，清缓存重绘
    ///（与外观切换钩子同一失效口径）
    func refreshHeatPalette() {
        dotsImagesDirty = true
        releaseDotsImages()
        dotStamps.removeAll()
        needsDisplay = true
    }

    /// 品牌图标染色经 sourceAtop 烘进缓存图，会定格当时外观：主题切换时清缓存重染；
    /// 点阵印章（NSImage 绘制块烘焙，无用量底点 = 动态色 secondaryBackground）同样定格，一并清
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dotsImagesDirty = true   // 点阵位图定格了旧外观的印章色，需重烘
        if !iconCache.isEmpty || !dotStamps.isEmpty {
            iconCache.removeAll()
            dotStamps.removeAll()
            needsDisplay = true
        }
    }

    /// 叠色拷贝：底图 draw 后以 sourceAtop 盖前景色（保留 alpha 形状），与昵称签到角标同法。
    /// ⚠️ 色值必须按**视图生效外观**解算（同 `bakedColorTag`）：lockFocus 里的
    /// `NSAppearance.current` 是系统外观，动态色（副前景色）直读会解到深色分支
    private func tintedImage(_ base: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color.setFill()
            NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        }
        out.unlockFocus()
        return out
    }
}

// MARK: - BalancePanelView 接线（ZCode / WorkBuddy / Codex 卡片 hover 切换内嵌 Token 板块）

extension BalancePanelView {

    /// Agent 卡 hover 确认（ZCode / WorkBuddy / Codex）：HoverCard 进度填充撑满 1s 后回调，
    /// 主面板 Token 板块切换为该平台内容，切换动效在 refreshInlineTokens 统一处理。
    /// 快速掠过不进入此回调（dwell 已取消）。同平台重复确认经 refreshInlineTokens
    /// 去重（view.source 未变则无高度变化，无几何反馈振荡）。
    func confirmTokensHover(source: TokensPanelSource) {
        Logger.log(.layout, "[HoverDbg] confirm source=\(source)")
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

    // MARK: - 主面板「Token」板块（内嵌 ZCode / WorkBuddy / Codex 卡片 hover 同款内容）

    /// 创建唯一的内嵌内容视图并启动低频刷新。与卡片 hover 子面板共用 TokensPanelView
    /// 与数据仓缓存；显示平台由 refreshInlineTokens 按 Agent 组顶部平台动态解析。
    /// 3D 硬币弹窗关闭后调用：内嵌小硬币按同一份 CoinSettings 重灌（参数同源，见 TokensPanelView）
    func reloadInlineCoinSettings() {
        inlineTokenView?.reloadInlineCoinSettings()
    }

    /// 面板每次打开时让内嵌小硬币自转一圈（用户 2026-09-11 指定；由 showPanel 调）
    func spinInlineCoin() {
        inlineTokenView?.spinInlineCoin()
    }

    func setupInlineTokens() {
        let view = TokensPanelView()
        view.source = .zcode
        // 左右缩进 8 = 用量行 / 设置卡片内容边界（usageHorizontalInset），内容撑满版心后
        // 热力图按实际宽等比放大、字号不变（hover 子面板保持默认 16 不受影响）；
        // 顶部缩进 4 = usageRowTopInset，标题→首行间距与用量区块同口径
        view.horizontalInset = 8
        view.topInset = 4
        view.bottomInset = 3
        // 大数字左边的内嵌小 3D 硬币：参数取自「3D 硬币」弹窗落盘的那份 CoinSettings
        view.showsInlineCoin = true
        // 大数值行（硬币 + 大数字）整体左缩进 +3（2026-09-15 用户指定；hover 子面板不受影响）
        view.numberRowLeadingInset = 3
        view.reloadInlineCoinSettings()
        view.isHidden = true
        // 列表（项目/模型）/热力图（每日/每周）切换改变内容高度：与折叠标题同口径
        // 通知 VC 按新内容高度重算面板尺寸
        view.onActivityModeChanged = { [weak self] in self?.onContentChanged?() }
        tokenContentStack.addArrangedSubview(view)
        // 显式等宽撑满版心：intrinsic 标称宽 260 仅供 hover 弹窗定尺寸，主面板按卡片实际宽拉伸
        view.widthAnchor.constraint(equalTo: tokenContentStack.widthAnchor).isActive = true
        inlineTokenView = view
        // 启动即无条件预热两个数据仓：App 启动阶段账号卡片尚未建好，「顶部平台」暂时
        // 解析不出，若只按解析结果取数会连带跳过预热 → 首次开面板要现等后台构建，板块延迟出现
        TokensPanelSource.zcode.fetch { _ in }
        TokensPanelSource.workbuddy.fetch { _ in }
        TokensPanelSource.codex.fetch { _ in }
        refreshInlineTokens()
        startInlineTokensRefreshTimer()
    }

    /// Token 板块跟随的平台：hover 中的 Agent 卡片优先；未 hover 时 = Agent 组最顶上的
    /// 可见卡片容器。TRAE 暂无本地 Token 数据源，Codex 从 ~/.codex/sessions 读取。
    private var inlineTokensSource: TokensPanelSource? {
        if let hover = hoverTokensSource { return hover }
        guard let group = balanceGroupContainer else { return nil }
        for container in group.arrangedSubviews where !container.isHidden {
            guard let id = platformCards.first(where: { $0.value === container })?.key else { continue }
            if id == BalancePlatform.zcode.rawValue { return .zcode }
            if id == BalancePlatform.workBuddy.rawValue { return .workbuddy }
            if id == BalancePlatform.codex.rawValue { return .codex }
            return nil
        }
        return nil
    }

    /// 取数并套用到内嵌视图。缓存命中同步返回（零读取），未命中挂起待后台构建补发；
    /// 数据未到时保留空占位（表头骨架，2026-09-08 用户要求：打开面板时信息显示前
    /// 先占位，避免板块内容突现）；顶部平台解析不出（无源）才整块隐藏。
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
        // 占位同步落地：缓存未命中时 fetch 只挂起回调、构建完成才补发（最长达一个
        // 重建周期），占位必须在 fetch 前就显示——打开面板即见表头骨架 + 空点阵，
        // 数据落定原位填充（intrinsic 高度恒定，不跳版）
        if view.isHidden {
            view.isHidden = false
            applyInlineTokensVisibility()
        }
        source.fetch { [weak self, weak view] summary in
            guard let self, let view, view.superview != nil else { return }
            // 取数期间平台已切换（hover 换卡/离开）：丢弃过期结果，等下一轮刷新重取
            guard self.inlineTokensSource == source else { return }
            var switched = false
            if view.source != source {
                view.beginSwitchTransition()   // 启动平台切换动效
                // ⚠️ 这一行赋值**本身就会转一次币**：`source` 的 didSet → `swapInlineCoinLogoOnSpin()`
                // → `inlineCoin.spin()`（转过 90° 才换 logo，转的就是 Motion 区 Turns 那个 `turns`）。
                // 所以这里**不许再补一发 `spinInlineCoin()`** —— 2026-09-17 用户报「硬币转动 turns
                // 要遵循设置参数」的根因就是两发叠在一起：转出来是 2×turns（turns=1 转两圈、
                // turns=3 转六圈）。换平台的转动**只有 didSet 那一个来源**。
                view.source = source
                switched = true
                // 注意：不在此清 summary——大数字要从旧平台值滚动到新值（slideNextTotalRoll），
                // 先清会落 "—" 使滚动起点丢失。无数据的收尾清理由下方 guard else 分支接管
            }
            guard let summary = summary else {
                // 单次后台构建失败：已有数据则保留展示（本机库/trace 仍在，下一轮重试即恢复）；
                // 无数据（含切换清空后）→ 维持表头骨架空占位
                if switched { view.summary = nil }
                return
            }
            view.summary = summary
            if switched {
                // 动效已由 beginSwitchTransition 启动的 DisplayTicker（显示器刷新率出帧）驱动，这里只按新内容高度重算面板尺寸
                self.onContentChanged?()
            }
        }
    }

    /// Token 板块显隐总闸：顶部平台有源 → 标题+卡片显示（数据未到时为
    /// 表头骨架空占位，2026-09-08 用户要求）；无源 → 标题+卡片一并隐藏，
    /// 数据恢复时重新落地。（板块已不可折叠，标题无点击入口）
    private func applyInlineTokensVisibility() {
        guard let view = inlineTokenView else { return }
        let hasData = !view.isHidden
        tokenTitleRef?.isHidden = !hasData
        guard let card = tokenCardRef else { return }
        card.isHidden = !hasData
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

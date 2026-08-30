// WbTokens.swift — WorkBuddy Token 用量数据源（与 ZCode 共用 Token 统计子面板视图）
// 数据源 = ~/.workbuddy/traces/<pid>/trace_*.json：WB 每次 agent 运行落一个 trace 文件，
// trace.modelInfo 记录该次运行的模型列表与 token 累计（totalInputTokens/totalOutputTokens/
// totalCachedTokens/callCount），trace.startedAt 为运行起点（ISO8601，各 trace 互相独立、
// 数值为该次运行的增量，跨文件直接求和）。
// 项目归属 = trace.sessionId → workbuddy.db sessions 表的 cwd（含已删除会话，保留历史归属），
// 项目名取 cwd 末段；映射不到的归入「(未知项目)」。
// 口径与 ZCode 一致：总计 = input + output（cache 是 input 子集不另加）。
// 文件总量上千个（数百 MB），全量重解析需数秒——按 (mtime,size) 做按文件增量缓存，
// 未变文件直接复用单文件贡献，只解析新增/变化的文件。
import Cocoa
import SQLite3

enum WBTokenStore {

    /// 单文件解析结果（增量缓存的值）；整体持久化到 App Support，
    /// App 重启后首次构建免全量重解析（~1700 文件数秒 → 只解析新增文件）
    private struct FileContribution: Codable {
        let mtime: Date
        let size: Int
        let model: String    // 首要模型（极少数多模型 trace 归属第一个，无法按模型拆分）
        let sessionId: String
        let tokens: Int64    // input + output
        let calls: Int64
        let startedAt: TimeInterval?   // trace 原始起点（秒）；缺失/不可解析为 nil（不计入周期总计）
        let dayStart: TimeInterval?   // 本地时区当日零点；startedAt 缺失/不可解析为 nil
    }

    /// 模型聚合行（大小写归并后的展示名 = 累计用量最大的原始写法）
    private struct ModelAgg {
        var tokens: Int64 = 0
        var calls: Int64 = 0
        var name: String = ""
        var nameTokens: Int64 = -1
    }

    private static let cache = TokenStoreCache(label: "ibalance.wbTokens") { Self.query() }
    /// 单文件贡献增量缓存（(mtime,size) 未变直接复用；磁盘持久化见 loadDiskCache/saveDiskCache）
    private static var fileCache: [String: FileContribution] = [:]
    private static var diskCacheLoaded = false

    /// 增量缓存落盘位置（App Support/wb-tokens-filecache-v2.json）；
    /// v2 = FileContribution 增加 startedAt 字段后换名，旧缓存解码失败自动全量重建一次
    private static var diskCacheURL: URL {
        AppDataStore.applicationSupportURL.appendingPathComponent("wb-tokens-filecache-v2.json")
    }

    /// 首次查询前把持久化的单文件贡献装回内存（进程生命周期内只装一次）
    private static func loadDiskCacheIfNeeded() {
        guard !diskCacheLoaded else { return }
        diskCacheLoaded = true
        guard let data = try? Data(contentsOf: diskCacheURL) else { return }
        fileCache = (try? JSONDecoder().decode([String: FileContribution].self, from: data)) ?? [:]
    }

    /// 缓存有变化时写盘（JSONDecoder/Encoder 对 ~1700 条为毫秒级，仅在增量扫描后触发）
    private static func saveDiskCacheIfNeeded(_ changed: Bool) {
        guard changed else { return }
        guard let data = try? JSONEncoder().encode(fileCache) else { return }
        try? data.write(to: diskCacheURL, options: .atomic)
    }

    /// 异步取汇总：后台每 60s 重建缓存，fetch 只回缓存不触发读取
    static func fetch(completion: @escaping (ZcodeTokenSummary?) -> Void) {
        cache.fetch(completion: completion)
    }

    private static func query() -> ZcodeTokenSummary? {
        loadDiskCacheIfNeeded()
        let dir = NSHomeDirectory() + "/.workbuddy/traces"
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }

        // 增量解析：签名未变的文件沿用缓存贡献，其余现场解析；扫描后重建缓存（顺带清已删文件）。
        // 只有解析过新文件或有文件消失才算变化，避免每轮刷新空写盘
        var fresh: [String: FileContribution] = [:]
        var changed = false
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("trace_"), url.pathExtension == "json" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mtime = vals?.contentModificationDate, let size = vals?.fileSize else { continue }
            let path = url.path
            if let c = fileCache[path], c.mtime == mtime, c.size == size {
                fresh[path] = c
                continue
            }
            if let c = parse(path: path, mtime: mtime, size: size) {
                fresh[path] = c
                changed = true
            }
        }
        changed = changed || fresh.count != fileCache.count
        fileCache = fresh
        saveDiskCacheIfNeeded(changed)

        // 项目映射（sessionId → cwd 末段），每次查询现读 sessions 表（量小、可含新增会话）
        let sessionMap = sessionProjects()

        // 按模型/项目聚合（模型大小写归并）+ 按天聚合（词元活动热力图）
        var models: [String: ModelAgg] = [:]
        var projects: [String: Int64] = [:]
        /// 项目完整目录（basename 键 → 首个命中的 cwd 末段），供行点击打开
        var projectPaths: [String: String] = [:]
        var dailyMap: [TimeInterval: Int64] = [:]
        var requests: Int64 = 0
        // 周期总计（5h/1d/7d/30d 滚动窗口）：startedAt 落在各窗口起点之后即计入（All 补全量）
        let periodStarts = TokenPeriodWindows.starts()
        var periodTotals: [TokenPeriod: Int64] = [:]
        for c in fresh.values {
            let key = c.model.lowercased()
            var agg = models[key] ?? ModelAgg()
            agg.tokens += c.tokens
            agg.calls += c.calls
            if c.tokens > agg.nameTokens {
                agg.name = c.model
                agg.nameTokens = c.tokens
            }
            models[key] = agg
            let full = sessionMap[c.sessionId]
            let proj = full.map { ($0 as NSString).lastPathComponent } ?? "(未知项目)"
            projects[proj, default: 0] += c.tokens
            if let full, projectPaths[proj] == nil { projectPaths[proj] = full }
            requests += c.calls
            if let d = c.dayStart { dailyMap[d, default: 0] += c.tokens }
            if let s = c.startedAt {
                for p in TokenPeriod.windowed where s >= (periodStarts[p] ?? .infinity) {
                    periodTotals[p, default: 0] += c.tokens
                }
            }
        }

        let projectRows = projects
            .filter { $0.value > 0 }
            .map { ZcodeTokenSummary.ProjectUsage(name: $0.key, tokens: $0.value,
                                                  path: projectPaths[$0.key]) }
            .sorted { $0.tokens > $1.tokens }
        guard !projectRows.isEmpty else { return nil }
        let modelRows = models.values
            .filter { $0.tokens > 0 }
            .map { ZcodeTokenSummary.ProjectUsage(name: $0.name, tokens: $0.tokens) }
            .sorted { $0.tokens > $1.tokens }
        let total = projectRows.reduce(Int64(0)) { $0 + $1.tokens }
        periodTotals[.all] = total   // All = 全量总计，无窗口
        let daily = dailyMap
            .map { ZcodeDayUsage(dayStart: $0.key, tokens: $0.value) }
            .sorted { $0.dayStart < $1.dayStart }
        return ZcodeTokenSummary(totalTokens: total, projects: projectRows, models: modelRows,
                                 requestCount: requests, daily: daily, periodTotals: periodTotals)
    }

    /// workbuddy.db sessions 表 sessionId → cwd（含已删除会话，保留历史用量归属）。
    /// WAL 库同 ZCode 打开链：先只读直开（WB 运行中含 -wal 增量），失败再 immutable 直读主文件。
    private static func sessionProjects() -> [String: String] {
        let path = NSHomeDirectory() + "/.workbuddy/workbuddy.db"
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(db)
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard sqlite3_open_v2("file:\(escaped)?immutable=1", &db,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return [:] }
        }
        defer { sqlite3_close(db) }
        var out: [String: String] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, cwd FROM sessions", -1, &stmt, nil) == SQLITE_OK else { return out }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let cwd = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if !id.isEmpty, !cwd.isEmpty { out[id] = cwd }
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// 解析单个 trace 文件；结构不符或无用量返回 nil（该文件不进缓存）
    private static func parse(path: String, mtime: Date, size: Int) -> FileContribution? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let trace = root["trace"] as? [String: Any],
              let mi = trace["modelInfo"] as? [String: Any] else { return nil }
        let input = (mi["totalInputTokens"] as? NSNumber)?.int64Value ?? 0
        let output = (mi["totalOutputTokens"] as? NSNumber)?.int64Value ?? 0
        let tokens = input + output
        guard tokens > 0 else { return nil }
        let model = (mi["models"] as? [Any])?.compactMap { $0 as? String }.first ?? "unknown"
        let sid = trace["sessionId"] as? String ?? ""
        let calls = (mi["callCount"] as? NSNumber)?.int64Value ?? 0
        let startedAt = (trace["startedAt"] as? String).flatMap { isoTimestamp(iso: $0) }
        let dayStart = startedAt
            .map { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0)).timeIntervalSince1970 }
        return FileContribution(mtime: mtime, size: size, model: model, sessionId: sid,
                                tokens: tokens, calls: calls, startedAt: startedAt, dayStart: dayStart)
    }

    /// ISO8601 → 原始时间戳（秒）。容忍毫秒位有无：截前 19 位补 Z 再解析。
    private static func isoTimestamp(iso: String) -> TimeInterval? {
        guard iso.count >= 19 else { return nil }
        return Self.isoParser.date(from: String(iso.prefix(19)) + "Z")?.timeIntervalSince1970
    }

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

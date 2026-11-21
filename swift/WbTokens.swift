// WbTokens.swift — WorkBuddy Token 用量数据源（与 ZCode 共用 Token 统计子面板视图）
// 数据源 = ~/.workbuddy/projects/<cwd-slug>/<sessionId>.jsonl：WB 把每次会话的完整事件流
// 落在这里，**带 usage 的条目 = 一次真实 LLM 请求**（providerData.rawUsage 的
// prompt_tokens / completion_tokens + providerData.model + timestamp + cwd）。
//
// ⚠️ 为什么不再读 traces/（2026-10-29 的根因）：WB CLI 2.165 起 trace 里的 `modelInfo`
// 与 `trace.totalTokens` 已恒为缺失/0（10-28 之后所有 trace 都是 `totalTokens:0`，
// 连 1.4 MB 的大会话也一样），token 统计因此归零。会话记录不受影响 —— 每次请求的 usage
// 都在，且比 trace 全（trace 只覆盖 23 个会话 / 2.59 亿，会话记录覆盖 416 个 / 58.9 亿）。
// trace 那套 modelInfo 的解析已整段删除，别按老路子加回去。
//
// 口径：总计 = prompt_tokens + completion_tokens（cache_read 是 prompt 的子集，不另加；
// 与 ZCode / 旧 trace 口径一致）。同一条 JSONL 内每次请求的 (prompt, completion) 唯一且
// prompt 单调递增，实测无重复条目（2026-10-29 核过 88 条 / 650 条两种规模的会话）。
// 项目归属 = 条目自带的 cwd 末段（无需再查 workbuddy.db sessions 表，DB 只留着做账号那摊事）。
//
// 文件量 400+ / 523 MB，全量重解析要几秒 —— 按 (mtime,size) 做**按文件增量缓存**，
// 未变文件直接复用缓存内的调用列表（无 usage 的会话也缓存空列表，免得每轮重读）。
import Cocoa

enum WBTokenStore {

    /// 一次 LLM 请求的用量（会话记录里一条带 usage 的条目）
    private struct Call: Codable {
        let t: TimeInterval   // 请求时间（秒）
        let model: String     // providerData.model（缺失时回落 requestModelId）
        let tokens: Int64     // prompt + completion
        let output: Int64     // 仅 completion（卡片副标题 tok/s 用，2026-09-14 用户指定）
    }

    /// 单文件（= 单会话）解析结果；整体持久化到 App Support，
    /// App 重启后首次构建免全量重解析（~420 文件 / 523 MB → 只解析新增/变化的文件）
    private struct FileContribution: Codable {
        let mtime: Date
        let size: Int
        let cwd: String
        let calls: [Call]     // 空 = 该会话没有任何 model 调用（照样进缓存，签名命中即可跳过）
    }

    /// 模型聚合行（大小写归并后的展示名 = 优先带大写的原始写法，同档取用量最大的）
    private struct ModelAgg {
        var tokens: Int64 = 0
        var calls: Int64 = 0
        var name: String = ""
        var nameTokens: Int64 = -1
    }

    private static let cache = TokenStoreCache(label: "ibalance.wbTokens") { Self.query() }
    /// 单文件贡献增量缓存（(mtime,size) 未变直接复用）
    private static var fileCache: [String: FileContribution] = [:]
    private static var diskCacheLoaded = false

    /// 并发解析的收集器：`DispatchQueue.concurrentPerform` 要跨线程写同一份结果，
    /// 而 Swift 6 不允许并发闭包捕获可变局部量 ⇒ 用带锁的引用类型（每次 parse 后取一次锁）
    private final class ParseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: FileContribution] = [:]
        private var count = 0
        func add(_ path: String, _ c: FileContribution) {
            lock.lock(); items[path] = c; count += 1; lock.unlock()
        }
        var parsed: Int { lock.lock(); defer { lock.unlock() }; return count }
        func merged(into base: [String: FileContribution]) -> [String: FileContribution] {
            lock.lock(); defer { lock.unlock() }
            return base.merging(items) { _, new in new }
        }
    }

    /// 增量缓存落盘位置。**v5 = 数据源从 traces/ 换成 projects/ 会话记录**（结构从
    /// 「单文件单模型汇总」变成「单文件调用列表」）；换名 → 老缓存解码失败 → 自动全量重建一次。
    private static var diskCacheURL: URL {
        AppDataStore.applicationSupportURL.appendingPathComponent("wb-tokens-filecache-v5.json")
    }

    /// 首次查询前把持久化的单文件贡献装回内存（进程生命周期内只装一次）
    private static func loadDiskCacheIfNeeded() {
        guard !diskCacheLoaded else { return }
        diskCacheLoaded = true
        guard let data = try? Data(contentsOf: diskCacheURL),
              let decoded = try? JSONDecoder().decode([String: FileContribution].self, from: data)
        else { return }
        fileCache = decoded
    }

    /// 缓存有变化时写盘（JSONEncoder 对几万条为毫秒级，仅在增量扫描后触发）
    private static func saveDiskCacheIfNeeded(_ changed: Bool) {
        guard changed else { return }
        guard let data = try? JSONEncoder().encode(fileCache) else { return }
        try? data.write(to: diskCacheURL, options: .atomic)
    }

    /// 异步取汇总：后台每 60s 重建缓存，fetch 只回缓存不触发读取
    static func fetch(completion: @escaping (TokenSummary?) -> Void) {
        cache.fetch(completion: completion)
    }
    /// 每轮缓存重建完成后的通知（宿主刷面板用；见 `TokenStoreCache.onRefresh`）
    static func onRefresh(_ f: @escaping (TokenSummary?) -> Void) { cache.onRefresh = f }
    /// 已构建缓存的同步只读（nil = 尚未构建过）：卡片副标题 tok/s 用
    static func cachedSummary() -> TokenSummary? { cache.cachedIfBuilt }

    private static func query() -> TokenSummary? {
        let t0 = CACurrentMediaTime()
        loadDiskCacheIfNeeded()
        let dir = NSHomeDirectory() + "/.workbuddy/projects"
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }

        // 第一遍（串行、只 stat）：签名命中的直接沿用缓存贡献；**空贡献同样命中**。
        // 未命中的攒进 pending，第二遍并发解析。
        var fresh: [String: FileContribution] = [:]
        var pending: [(path: String, mtime: Date, size: Int)] = []
        for case let url as URL in walker {
            // 只收 <sessionId>.jsonl（项目目录 = cwd slug，再下一层才是会话文件）
            guard url.pathExtension == "jsonl" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mtime = vals?.contentModificationDate, let size = vals?.fileSize else { continue }
            let path = url.path
            if let c = fileCache[path], c.mtime == mtime, c.size == size {
                fresh[path] = c
                continue
            }
            pending.append((path, mtime, size))
        }
        // 第二遍：**并发解析**（IO 与 JSON 解析都能并行，首轮全量收益最大）；
        // parse 返回 nil = 读盘失败（文件正在写）→ 本轮不入缓存，下轮签名仍未命中 → 自动重试
        let box = ParseBox()
        if !pending.isEmpty {
            DispatchQueue.concurrentPerform(iterations: pending.count) { i in
                let item = pending[i]
                if let c = parse(path: item.path, mtime: item.mtime, size: item.size) {
                    box.add(item.path, c)
                }
            }
        }
        let parsedCount = box.parsed
        fresh = box.merged(into: fresh)
        let changed = parsedCount > 0 || fresh.count != fileCache.count
        fileCache = fresh
        saveDiskCacheIfNeeded(changed)

        // 聚合：模型（大小写归并）/ 项目 / 按天 / 各滚动窗口
        var models: [String: ModelAgg] = [:]
        var projects: [String: Int64] = [:]
        /// 项目完整目录（basename 键 → 首个命中的 cwd），供行点击打开
        var projectPaths: [String: String] = [:]
        var dailyMap: [TimeInterval: Int64] = [:]
        var requests: Int64 = 0
        let periodStarts = TokenPeriodWindows.starts()
        var periodTotals: [TokenPeriod: Int64] = [:]
        var periodProjectTokens: [TokenPeriod: [String: Int64]] = [:]
        var periodModelTokens: [TokenPeriod: [String: Int64]] = [:]
        /// 会话均速原料：每文件（= 会话）首末请求时间 + output 合计
        var sessions: [(start: TimeInterval, tokens: Double, seconds: Double)] = []
        /// 本地时区当日零点缓存（键 = UTC 日序号，同一天的 startOfDay 恒定，避免每条调用都算一遍）
        var dayStartCache: [Int: TimeInterval] = [:]

        for c in fresh.values {
            let full = c.cwd.isEmpty ? nil : c.cwd
            let proj = full.map { ($0 as NSString).lastPathComponent } ?? "(未知项目)"
            if let full, projectPaths[proj] == nil { projectPaths[proj] = full }
            var first: TimeInterval = .infinity
            var last: TimeInterval = -.infinity
            var sessionOutput: Int64 = 0
            for call in c.calls {
                guard call.tokens > 0 else { continue }
                // 模型
                let key = call.model.lowercased()
                var agg = models[key] ?? ModelAgg()
                agg.tokens += call.tokens
                agg.calls += 1
                // 展示名优先带大写的写法（与 ZCode 数据源同口径），同档取用量大的，全小写回落小写
                let curUpper = call.model != key
                let dispUpper = !agg.name.isEmpty && agg.name != agg.name.lowercased()
                let replace: Bool
                if agg.name.isEmpty { replace = true }
                else if curUpper != dispUpper { replace = curUpper }
                else { replace = call.tokens > agg.nameTokens }
                if replace {
                    agg.name = call.model.isEmpty ? "unknown" : call.model
                    agg.nameTokens = call.tokens
                }
                models[key] = agg
                // 项目 / 总量 / 请求数
                projects[proj, default: 0] += call.tokens
                requests += 1
                // 按天（本地时区零点）
                let dayKey = Int(call.t / 86400)
                let day: TimeInterval
                if let d = dayStartCache[dayKey] {
                    day = d
                } else {
                    day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: call.t))
                        .timeIntervalSince1970
                    dayStartCache[dayKey] = day
                }
                dailyMap[day, default: 0] += call.tokens
                // 滚动窗口
                for p in TokenPeriod.windowed where call.t >= (periodStarts[p] ?? .infinity) {
                    periodTotals[p, default: 0] += call.tokens
                    periodProjectTokens[p, default: [:]][proj, default: 0] += call.tokens
                    periodModelTokens[p, default: [:]][key, default: 0] += call.tokens
                }
                first = min(first, call.t)
                last = max(last, call.t)
                sessionOutput += call.output
            }
            if last > first, sessionOutput > 0 {
                sessions.append((start: first, tokens: Double(sessionOutput), seconds: last - first))
            }
        }

        let projectRows = projects
            .filter { $0.value > 0 }
            .map { TokenSummary.ProjectUsage(name: $0.key, tokens: $0.value,
                                             path: projectPaths[$0.key]) }
            .sorted { $0.tokens > $1.tokens }
        // 构建耗时落日志（这类"数据仓慢"的问题不好复现，留一条常驻记录；本机 416 文件 / 523 MB：
        // 缓存全命中 ≈ 100ms，全量首建（并发）≈ 2～4s）
        Logger.log(.refresh, String(format: "[WBToken] build %.0fms 文件 %d（本轮解析 %d）模型 %d 项目 %d 总计 %lld",
                                    (CACurrentMediaTime() - t0) * 1000, fresh.count, parsedCount,
                                    models.count, projectRows.count,
                                    projectRows.reduce(Int64(0)) { $0 + $1.tokens }))
        guard !projectRows.isEmpty else { return nil }
        let modelRows = models.values
            .filter { $0.tokens > 0 }
            .map { TokenSummary.ProjectUsage(name: $0.name, tokens: $0.tokens) }
            .sorted { $0.tokens > $1.tokens }
        let total = projectRows.reduce(Int64(0)) { $0 + $1.tokens }
        periodTotals[.all] = total   // All = 全量总计，无窗口
        // 各窗口列表：项目键沿用 basename（path 回查全量映射）；模型展示名取全量聚合结果
        var periodProjects: [TokenPeriod: [TokenSummary.ProjectUsage]] = [:]
        for (p, dict) in periodProjectTokens {
            periodProjects[p] = dict
                .map { TokenSummary.ProjectUsage(name: $0.key, tokens: $0.value,
                                                 path: projectPaths[$0.key]) }
                .sorted { $0.tokens > $1.tokens }
        }
        var periodModels: [TokenPeriod: [TokenSummary.ProjectUsage]] = [:]
        for (p, dict) in periodModelTokens {
            periodModels[p] = dict
                .map { TokenSummary.ProjectUsage(name: models[$0.key]!.name, tokens: $0.value) }
                .sorted { $0.tokens > $1.tokens }
        }
        let daily = dailyMap
            .map { TokenDayUsage(dayStart: $0.key, tokens: $0.value) }
            .sorted { $0.dayStart < $1.dayStart }
        var summary = TokenSummary(totalTokens: total, projects: projectRows, models: modelRows,
                                   requestCount: requests, daily: daily, periodTotals: periodTotals,
                                   periodProjects: periodProjects, periodModels: periodModels)
        summary.recentSessionSpeed = recentSessionSpeed(sessions)
        return summary
    }

    /// 解析单个会话记录文件（`~/.workbuddy/projects/<slug>/<sessionId>.jsonl`）。
    ///
    /// 每行一个事件（message / reasoning / function_call / function_call_result / …），
    /// **只有真正调过模型的条目带 `providerData.rawUsage`** —— 一次请求一条，且实测
    /// (prompt, completion) 唯一、prompt 随上下文增长单调不减，直接累加即可，无需去重。
    /// 无 usage 的会话返回空 calls（**不吃 nil**：nil 表示读盘失败、下轮重试；
    /// 空贡献要进缓存，否则这类文件每轮 60s 都被重读重解析 —— 2026-09-17 踩过）。
    ///
    /// 性能：文件可达 11 MB、上万行且大量是工具输出/快照 ⇒ 先做字节级 needle 命中，
    /// 未命中的行直接跳过不解析（`"usage"` 是 `"rawUsage"` 的补集写法，两种都收）。
    private static let rawUsageNeedle = Data("\"rawUsage\"".utf8)
    private static let usageNeedle = Data("\"usage\"".utf8)

    private static func parse(path: String, mtime: Date, size: Int) -> FileContribution? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var cwd = ""
        var calls: [Call] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.range(of: rawUsageNeedle) != nil || line.range(of: usageNeedle) != nil else { continue }
            guard let root = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let pd = root["providerData"] as? [String: Any],
                  let u = (pd["rawUsage"] as? [String: Any]) ?? (pd["usage"] as? [String: Any])
            else { continue }
            let input = num(u, "prompt_tokens", "inputTokens", "input_tokens", "promptTokens")
            let output = num(u, "completion_tokens", "outputTokens", "output_tokens", "completionTokens")
            guard input > 0 || output > 0 else { continue }
            if cwd.isEmpty, let c = root["cwd"] as? String { cwd = c }
            let model = (pd["model"] as? String) ?? (pd["requestModelId"] as? String) ?? ""
            // timestamp 是毫秒（1793177026095）；> 1e11 判为毫秒，缺失时用文件 mtime 兜底，
            // 免得整条丢出「按天 / 窗口」统计
            var t = (root["timestamp"] as? NSNumber)?.doubleValue ?? 0
            t = t > 1e11 ? t / 1000 : t
            if t <= 0 { t = mtime.timeIntervalSince1970 }
            calls.append(Call(t: t, model: model, tokens: input + output, output: output))
        }
        return FileContribution(mtime: mtime, size: size, cwd: cwd, calls: calls)
    }

    /// usage 里的整数字段（各家字段名不一致：WB 用 prompt_tokens/completion_tokens，
    /// 老格式可能是 camelCase）—— 取第一个存在的键
    private static func num(_ dict: [String: Any], _ keys: String...) -> Int64 {
        for k in keys {
            if let n = dict[k] as? NSNumber { return n.int64Value }
            if let d = dict[k] as? Double { return Int64(d) }
            if let i = dict[k] as? Int { return Int64(i) }
        }
        return 0
    }
}

// CodexTokens.swift — Codex Agent Token 用量数据源
// 数据源 = ~/.codex/sessions/**/rollout-*.jsonl。
// 每个 token_count 事件的 last_token_usage 是本轮增量，避免把 total_token_usage
//（session 内累计值）重复相加；cwd 作为项目归属，turn_context.model 作为模型归属。
import Cocoa

enum CodexTokenStore {
    private static let cache = TokenStoreCache(label: "ibalance.codexTokens") { Self.query() }
    /// 单文件贡献增量缓存（(mtime,size) 未变直接复用；磁盘持久化见 loadDiskCacheIfNeeded）
    private static var fileCache: [String: FileContribution] = [:]
    private static var diskCacheLoaded = false

    static func fetch(completion: @escaping (TokenSummary?) -> Void) {
        cache.fetch(completion: completion)
    }

    private static func query() -> TokenSummary? {
        loadDiskCacheIfNeeded()
        let sessionsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { return nil }

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoWithoutFraction = ISO8601DateFormatter()
        isoWithoutFraction.formatOptions = [.withInternetDateTime]

        // 增量扫描：(mtime,size) 未变的文件直接沿用缓存贡献，其余现场解析；扫描后重建
        // 缓存（顺带清已删文件）。空用量文件也进缓存，无 token_count 的大文件不至于每轮重啃
        var fresh: [String: FileContribution] = [:]
        var changed = false
        for case let fileURL as URL in walker {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = vals.contentModificationDate, let size = vals.fileSize else { continue }
            let path = fileURL.path
            if let c = fileCache[path], c.mtime == mtime, c.size == size {
                fresh[path] = c
                continue
            }
            if let c = parseFile(fileURL, mtime: mtime, size: size,
                                 isoWithFraction: isoWithFraction,
                                 isoWithoutFraction: isoWithoutFraction) {
                fresh[path] = c
                changed = true
            }
        }
        changed = changed || fresh.count != fileCache.count
        fileCache = fresh
        saveDiskCacheIfNeeded(changed)

        var projects: [String: Int64] = [:]
        var projectPaths: [String: String] = [:]
        var models: [String: Int64] = [:]
        var modelNames: [String: String] = [:]
        var dailyMap: [TimeInterval: Int64] = [:]
        var periodTotals: [TokenPeriod: Int64] = [:]
        // 各窗口项目/模型小计（5h/1d/7d/30d 滚动窗口，口径同 periodTotals）
        var periodProjectTokens: [TokenPeriod: [String: Int64]] = [:]
        var periodModelTokens: [TokenPeriod: [String: Int64]] = [:]
        var requestCount: Int64 = 0
        let periodStarts = TokenPeriodWindows.starts()
        let calendar = Calendar.current

        for c in fresh.values where !c.usages.isEmpty {
            let projectPath = c.cwd
            let projectName: String
            if let projectPath, !projectPath.isEmpty {
                let basename = (projectPath as NSString).lastPathComponent
                projectName = basename.isEmpty ? "(未知项目)" : basename
                if projectPaths[projectName] == nil { projectPaths[projectName] = projectPath }
            } else {
                projectName = "(未知项目)"
            }

            for value in c.usages {
                guard value.tokens > 0 else { continue }
                projects[projectName, default: 0] += value.tokens
                let modelKey = value.model.lowercased()
                models[modelKey, default: 0] += value.tokens
                let oldName = modelNames[modelKey]
                if oldName == nil || (value.model != modelKey && oldName == modelKey) {
                    modelNames[modelKey] = value.model
                }
                requestCount += 1

                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: value.t)).timeIntervalSince1970
                dailyMap[day, default: 0] += value.tokens
                for period in TokenPeriod.windowed
                where value.t >= (periodStarts[period] ?? .infinity) {
                    periodTotals[period, default: 0] += value.tokens
                    periodProjectTokens[period, default: [:]][projectName, default: 0] += value.tokens
                    periodModelTokens[period, default: [:]][modelKey, default: 0] += value.tokens
                }
            }
        }

        let projectRows = projects
            .filter { $0.value > 0 }
            .map { TokenSummary.ProjectUsage(name: $0.key, tokens: $0.value,
                                              path: projectPaths[$0.key]) }
            .sorted { $0.tokens > $1.tokens }
        guard !projectRows.isEmpty else { return nil }

        let modelRows = models
            .filter { $0.value > 0 }
            .map { key, tokens in
                TokenSummary.ProjectUsage(name: modelNames[key] ?? key, tokens: tokens)
            }
            .sorted { $0.tokens > $1.tokens }
        let total = projectRows.reduce(Int64(0)) { $0 + $1.tokens }
        periodTotals[.all] = total
        // 各窗口列表：项目 path 回查全量映射；模型展示名取全量聚合结果
        // （窗口 ⊆ 全量，键必已存在）
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
                .map { TokenSummary.ProjectUsage(name: modelNames[$0.key]!, tokens: $0.value) }
                .sorted { $0.tokens > $1.tokens }
        }
        let daily = dailyMap
            .map { TokenDayUsage(dayStart: $0.key, tokens: $0.value) }
            .sorted { $0.dayStart < $1.dayStart }
        return TokenSummary(totalTokens: total, projects: projectRows, models: modelRows,
                            requestCount: requestCount, daily: daily, periodTotals: periodTotals,
                            periodProjects: periodProjects, periodModels: periodModels)
    }

    /// 单文件解析结果（增量缓存的值）；整体持久化到 App Support，
    /// App 重启后首次构建免全量重解析（此前每 60s 全量重啃 ~351MB 曾致长时满核）
    private struct FileContribution: Codable {
        let mtime: Date
        let size: Int
        let cwd: String?
        let usages: [CachedUsage]
    }

    /// 一条 token_count 增量（date 落盘为秒）；模型名保留原始大小写（聚合展示名仍按小写键归并）
    private struct CachedUsage: Codable {
        let t: TimeInterval
        let model: String
        let tokens: Int64
    }

    /// 增量缓存落盘位置（App Support/codex-tokens-filecache-v1.json），命名与 WB 数据源同约定
    private static var diskCacheURL: URL {
        AppDataStore.applicationSupportURL.appendingPathComponent("codex-tokens-filecache-v1.json")
    }

    /// 首次查询前把持久化的单文件贡献装回内存（进程生命周期内只装一次）
    private static func loadDiskCacheIfNeeded() {
        guard !diskCacheLoaded else { return }
        diskCacheLoaded = true
        guard let data = try? Data(contentsOf: diskCacheURL) else { return }
        fileCache = (try? JSONDecoder().decode([String: FileContribution].self, from: data)) ?? [:]
    }

    /// 缓存有变化时写盘（编码 ~239 条为毫秒级，仅在增量扫描后触发）
    private static func saveDiskCacheIfNeeded(_ changed: Bool) {
        guard changed else { return }
        guard let data = try? JSONEncoder().encode(fileCache) else { return }
        try? data.write(to: diskCacheURL, options: .atomic)
    }

    /// 解析单个 rollout 文件；读取失败返回 nil（不进缓存，下轮重试），空用量正常进缓存
    private static func parseFile(_ url: URL, mtime: Date, size: Int,
                                  isoWithFraction: ISO8601DateFormatter,
                                  isoWithoutFraction: ISO8601DateFormatter) -> FileContribution? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        var cwd: String?
        var currentModel = "Codex"
        var usages: [CachedUsage] = []
        // 字节级按 \n 切行直接喂 JSONSerialization；Character 级 split（\.isNewline 走
        // 图素断行 + KeyPath 派发）+ 整文件转 String 再逐行回转 Data 在大文件上慢一个量级
        for lineData in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: lineData),
                  let record = object as? [String: Any],
                  let type = record["type"] as? String,
                  let payload = record["payload"] as? [String: Any] else { continue }

            if type == "session_meta" {
                cwd = payload["cwd"] as? String
                if let model = payload["model"] as? String, !model.isEmpty { currentModel = model }
                continue
            }
            if type == "turn_context" {
                if let model = payload["model"] as? String, !model.isEmpty { currentModel = model }
                continue
            }
            guard type == "event_msg", payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any],
                  let input = (usage["input_tokens"] as? NSNumber)?.int64Value,
                  let output = (usage["output_tokens"] as? NSNumber)?.int64Value,
                  let timestamp = record["timestamp"] as? String,
                  let date = isoWithFraction.date(from: timestamp)
                        ?? isoWithoutFraction.date(from: timestamp) else { continue }
            usages.append(CachedUsage(t: date.timeIntervalSince1970, model: currentModel,
                                      tokens: input + output))
        }
        return FileContribution(mtime: mtime, size: size, cwd: cwd, usages: usages)
    }
}

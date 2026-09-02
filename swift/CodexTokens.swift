// CodexTokens.swift — Codex Agent Token 用量数据源
// 数据源 = ~/.codex/sessions/**/rollout-*.jsonl。
// 每个 token_count 事件的 last_token_usage 是本轮增量，避免把 total_token_usage
//（session 内累计值）重复相加；cwd 作为项目归属，turn_context.model 作为模型归属。
import Cocoa

enum CodexTokenStore {
    private static let cache = TokenStoreCache(label: "ibalance.codexTokens") { Self.query() }

    static func fetch(completion: @escaping (TokenSummary?) -> Void) {
        cache.fetch(completion: completion)
    }

    private static func query() -> TokenSummary? {
        let sessionsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }

        var projects: [String: Int64] = [:]
        var projectPaths: [String: String] = [:]
        var models: [String: Int64] = [:]
        var modelNames: [String: String] = [:]
        var dailyMap: [TimeInterval: Int64] = [:]
        var periodTotals: [TokenPeriod: Int64] = [:]
        var requestCount: Int64 = 0
        let periodStarts = TokenPeriodWindows.starts()
        let calendar = Calendar.current
        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoWithoutFraction = ISO8601DateFormatter()
        isoWithoutFraction.formatOptions = [.withInternetDateTime]

        for case let fileURL as URL in walker {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let values = parseFile(fileURL, isoWithFraction: isoWithFraction,
                                         isoWithoutFraction: isoWithoutFraction) else { continue }

            let projectPath = values.cwd
            let projectName: String
            if let projectPath, !projectPath.isEmpty {
                let basename = (projectPath as NSString).lastPathComponent
                projectName = basename.isEmpty ? "(未知项目)" : basename
                if projectPaths[projectName] == nil { projectPaths[projectName] = projectPath }
            } else {
                projectName = "(未知项目)"
            }

            for value in values.usages {
                guard value.tokens > 0 else { continue }
                projects[projectName, default: 0] += value.tokens
                let modelKey = value.model.lowercased()
                models[modelKey, default: 0] += value.tokens
                let oldName = modelNames[modelKey]
                if oldName == nil || (value.model != modelKey && oldName == modelKey) {
                    modelNames[modelKey] = value.model
                }
                requestCount += 1

                let day = calendar.startOfDay(for: value.date).timeIntervalSince1970
                dailyMap[day, default: 0] += value.tokens
                for period in TokenPeriod.windowed
                where value.date.timeIntervalSince1970 >= (periodStarts[period] ?? .infinity) {
                    periodTotals[period, default: 0] += value.tokens
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
        let daily = dailyMap
            .map { TokenDayUsage(dayStart: $0.key, tokens: $0.value) }
            .sorted { $0.dayStart < $1.dayStart }
        return TokenSummary(totalTokens: total, projects: projectRows, models: modelRows,
                            requestCount: requestCount, daily: daily, periodTotals: periodTotals)
    }

    private struct Usage {
        let date: Date
        let model: String
        let tokens: Int64
    }

    private struct ParsedFile {
        let cwd: String?
        let usages: [Usage]
    }

    private static func parseFile(_ url: URL,
                                  isoWithFraction: ISO8601DateFormatter,
                                  isoWithoutFraction: ISO8601DateFormatter) -> ParsedFile? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var cwd: String?
        var currentModel = "Codex"
        var usages: [Usage] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
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
            usages.append(Usage(date: date, model: currentModel, tokens: input + output))
        }
        return usages.isEmpty ? nil : ParsedFile(cwd: cwd, usages: usages)
    }
}

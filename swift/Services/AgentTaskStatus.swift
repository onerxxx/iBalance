// AgentTaskStatus.swift — WorkBuddy / ZCode / Codex 任务状态读取
// 数据源（均为本机明文 SQLite，WAL 库：先只读直开拿 -wal 增量，失败再 immutable 直读主文件，
// 与 WbTokens.sessionProjects 同一打开链）：
//   WB    ~/.workbuddy/workbuddy.db       sessions.status      （planning=进行中，
//         completed=完成，error/terminated=中断）
//   ZCode ~/.zcode/v2/tasks-index.sqlite  tasks.task_status    （仅落定态 completed/error，
//         运行中不写行 → 进行中由 cli db 精确运行标记判定，见 zcodeHasActiveSession）
//   Codex ~/.codex/sessions/**/*.jsonl                         task_started/task_complete/
//         turn_aborted/error（Codex Desktop/CLI 的 rollout 事件流）
// 状态映射为卡片 icon 光环：进行中=蓝 / 完成=绿 / 中断=橙红；
// 完成与中断最多显示 5 分钟（按库内 updated_at 计），进行中不过期。
// 后台 5s 轮询（三条单行查询，开销可忽略），可见状态变化时回调触发面板同步。
import Foundation
import SQLite3

/// Agent 任务三态（卡片 icon 光环颜色判据）
enum AgentTaskState: Equatable {
    case running       // 进行中 → 蓝
    case completed     // 完成 → 绿
    case interrupted   // 中断 → 橙红
}

/// 一次任务状态采样：状态 + 库内更新时刻（秒）
struct AgentTaskStatus: Equatable {
    let state: AgentTaskState
    let updatedAt: TimeInterval
}

enum AgentTaskStatusStore {
    /// 完成/中断的显示时长上限（秒）：超时视为过期，光环消失；进行中不适用
    /// （2026-09-02 用户要求 10 分钟 → 5 分钟）
    private static let settledDisplayLimit: TimeInterval = 300
    /// 轮询间隔（2026-09-02 用户要求 15s → 10s → 5s）
    private static let pollInterval: TimeInterval = 5

    private static let queue = DispatchQueue(label: "ibalance.agentTaskStatus", qos: .utility)
    private static var timer: DispatchSourceTimer?
    private static var onChange: (() -> Void)?
    /// 最近一轮采样（queue 内读写）
    private static var latestWb: AgentTaskStatus?
    private static var latestZcode: AgentTaskStatus?
    private static var latestCodex: AgentTaskStatus?
    /// 上次通知出去的可见状态（含过期口径），用于变化检测
    private static var lastNotified: (wb: AgentTaskState?, zcode: AgentTaskState?, codex: AgentTaskState?) = (nil, nil, nil)

    private static let wbDbPath = NSHomeDirectory() + "/.workbuddy/workbuddy.db"
    private static let zcodeDbPath = NSHomeDirectory() + "/.zcode/v2/tasks-index.sqlite"
    private static let zcodeCliDbPath = NSHomeDirectory() + "/.zcode/cli/db/db.sqlite"
    private static var codexSessionsPath: String {
        if let raw = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            let home = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !home.isEmpty {
                return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
                    .appendingPathComponent("sessions", isDirectory: true).path
            }
        }
        return NSHomeDirectory() + "/.codex/sessions"
    }
    /// 运行标记推进上限（秒）：在途消息/未完工具件在会话正常活动时每几秒推进，
    /// 只有进程崩溃残留会永久停在 running（实测库内有 8 月中两条脏数据）。
    /// 超 1 小时未推进的标记视为崩溃残留不计数——这是脏数据过滤，
    /// 状态判定本身用库内精确标记，无时间窗兜底
    private static let zcodeMarkerStaleLimit: TimeInterval = 3600

    // MARK: - 对外读取（主线程，makePanelSnapshot 调用）

    /// WB 当前可见任务状态（nil = 无光环）
    static var workbuddyVisible: AgentTaskState? {
        queue.sync { visible(latestWb) }
    }

    /// ZCode 当前可见任务状态（nil = 无光环）
    static var zcodeVisible: AgentTaskState? {
        queue.sync { visible(latestZcode) }
    }

    /// Codex 当前可见任务状态（nil = 无光环）
    static var codexVisible: AgentTaskState? {
        queue.sync { visible(latestCodex) }
    }

    /// 应用 5 分钟过期：完成/中断超时 → nil；进行中恒可见
    private static func visible(_ s: AgentTaskStatus?) -> AgentTaskState? {
        guard let s else { return nil }
        switch s.state {
        case .running:
            return .running
        case .completed, .interrupted:
            return Date().timeIntervalSince1970 - s.updatedAt <= settledDisplayLimit ? s.state : nil
        }
    }

    // MARK: - 轮询

    /// 启动后台轮询（幂等）；可见状态变化时 onChange 主线程回调（供 syncPanel）
    static func startPolling(onChange: @escaping () -> Void) {
        queue.sync {
            Self.onChange = onChange
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: pollInterval)
            t.setEventHandler { poll() }
            t.resume()
            timer = t
        }
    }

    private static func poll() {
        latestWb = queryLatest(path: wbDbPath,
                                sql: "SELECT status, updated_at FROM sessions WHERE deleted_at IS NULL ORDER BY updated_at DESC LIMIT 1",
                                map: mapWorkbuddy)
        latestZcode = queryZcode()
        latestCodex = queryCodex()
        let nowVisible = (visible(latestWb), visible(latestZcode), visible(latestCodex))
        guard nowVisible != lastNotified else { return }
        lastNotified = nowVisible
        DispatchQueue.main.async { [onChange] in onChange?() }
    }

    // MARK: - 状态映射

    /// WB sessions.status：planning=进行中；completed=完成；error/terminated=中断；
    /// 未知值按进行中兜底（该表状态集合以进行中语义为主）
    private static func mapWorkbuddy(_ raw: String) -> AgentTaskState {
        switch raw {
        case "completed": return .completed
        case "error", "terminated", "cancelled", "failed": return .interrupted
        default: return .running
        }
    }

    /// ZCode tasks.task_status：completed=完成；error=中断；其余（运行中等）=进行中。
    /// 实测该列只写落定值（completed/error，运行中不写行），default 分支实际不触发，
    /// 进行中判定在 zcodeHasActiveSession 由库内运行标记承担
    private static func mapZcode(_ raw: String) -> AgentTaskState {
        switch raw {
        case "completed": return .completed
        case "error", "cancelled", "failed": return .interrupted
        default: return .running
        }
    }

    /// ZCode 采样：进行中 = 库内精确运行标记（见 zcodeHasActiveSession，App 任务与
    /// 终端 CLI 会话同口径，均入 tasks-index 建任务行）；无运行标记回落落定态口径
    /// （tasks-index 最新行，completed/error + 10 分钟过期）
    private static func queryZcode() -> AgentTaskStatus? {
        if zcodeHasActiveSession() {
            return AgentTaskStatus(state: .running, updatedAt: Date().timeIntervalSince1970)
        }
        return queryLatest(path: zcodeDbPath,
                           sql: "SELECT task_status, updated_at FROM tasks WHERE deleted = 0 ORDER BY updated_at DESC LIMIT 1",
                           map: mapZcode)
    }

    /// Codex rollout 状态：读取最近的任务事件，不读取或记录事件正文。
    /// 多个会话同时存在时，任一近期会话进行中优先；否则取最近落定事件。
    private static func queryCodex() -> AgentTaskStatus? {
        let root = URL(fileURLWithPath: codexSessionsPath, isDirectory: true)
        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        let now = Date().timeIntervalSince1970
        let runningStaleLimit: TimeInterval = 3600
        var running: AgentTaskStatus?
        var settled: AgentTaskStatus?

        for case let fileURL as URL in files where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate?.timeIntervalSince1970,
                  now - modifiedAt <= runningStaleLimit,
                  let event = latestCodexTaskEvent(in: fileURL) else { continue }

            let sample = AgentTaskStatus(state: event, updatedAt: modifiedAt)
            if event == .running {
                // 没有 task_complete 的残留 rollout 可能来自崩溃；长时间没有写入时不再当作进行中。
                if running == nil || sample.updatedAt > running!.updatedAt {
                    running = sample
                }
            } else if settled == nil || sample.updatedAt > settled!.updatedAt {
                settled = sample
            }
        }
        return running ?? settled
    }

    /// 从 JSONL 文件尾部向前按块找最后一个任务级事件。只解析事件类型，避免触碰任务正文。
    ///
    /// 不能只读取固定大小的 suffix：一个进行中的长任务会在 task_started 之后
    /// 写入大量工具/消息内容，导致 task_started 被挤出窗口；当前会话随后被忽略，
    /// queryCodex 便可能错误回退到旧会话的 task_complete。
    private static func latestCodexTaskEvent(in fileURL: URL) -> AgentTaskState? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let chunkSize = 256 * 1024
        var offset = handle.seekToEndOfFile()
        var partialLine = Data()

        while offset > 0 {
            let readSize = min(UInt64(chunkSize), offset)
            offset -= readSize
            do {
                try handle.seek(toOffset: offset)
            } catch {
                return nil
            }
            let chunk = handle.readData(ofLength: Int(readSize))
            guard !chunk.isEmpty else { return nil }

            // 当前块末尾与上一轮保留的行尾拼接；第一段可能仍是不完整行，
            // 其余行都是完整 JSONL 行，可从后往前直接找到最新状态。
            var data = chunk
            data.append(partialLine)
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            for line in lines.dropFirst().reversed() {
                if let state = codexTaskState(in: Data(line)) { return state }
            }
            partialLine = Data(lines.first ?? Data())
        }

        return codexTaskState(in: partialLine)
    }

    /// 解析单条 JSONL 的任务状态；非任务事件返回 nil。
    private static func codexTaskState(in line: Data) -> AgentTaskState? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return nil }
        switch type {
        case "task_started": return .running
        case "task_complete": return .completed
        case "turn_aborted", "error": return .interrupted
        default: return nil
        }
    }

    /// ZCode 是否有进行中的会话（interactive，App 任务与终端 CLI 同口径）。两条库内
    /// 精确标记任一命中即进行中，秒级推进、无时间窗兜底：
    ///   ① 在途助手消息：message.data.time.completed 缺失 = 仍在生成/流式输出；
    ///   ② 未完工具件：part.data.state.status ∈ running/pending（实测值集仅
    ///      completed/error/running）。
    /// 标记行 time_updated 超 zcodeMarkerStaleLimit 未推进视为崩溃残留不计数
    private static func zcodeHasActiveSession() -> Bool {
        guard FileManager.default.fileExists(atPath: zcodeCliDbPath) else { return false }
        guard let db = openReadOnly(path: zcodeCliDbPath) else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let minMs = Int64((Date().timeIntervalSince1970 - zcodeMarkerStaleLimit) * 1000)
        let sql = """
            SELECT
             (SELECT COUNT(*) FROM message m JOIN session s ON s.id = m.session_id
               WHERE s.task_type = 'interactive'
                 AND json_extract(m.data, '$.role') = 'assistant'
                 AND json_extract(m.data, '$.time.completed') IS NULL
                 AND m.time_updated > \(minMs))
            +
             (SELECT COUNT(*) FROM part p JOIN session s ON s.id = p.session_id
               WHERE s.task_type = 'interactive'
                 AND json_extract(p.data, '$.state.status') IN ('running','pending')
                 AND p.time_updated > \(minMs))
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(stmt, 0) > 0
    }

    // MARK: - SQLite 单行查询

    /// 只读打开 SQLite（WAL 库先直开拿 -wal 增量，失败再 immutable 直读主文件），失败返回 nil
    private static func openReadOnly(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(db)
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard sqlite3_open_v2("file:\(escaped)?immutable=1", &db,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        }
        return db
    }

    /// 打开库读首行（状态文本 + updated_at 毫秒）；库缺失/打开失败/无行返回 nil
    private static func queryLatest(path: String, sql: String,
                                     map: (String) -> AgentTaskState) -> AgentTaskStatus? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let db = openReadOnly(path: path) else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let raw = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return nil }
        let ms = sqlite3_column_int64(stmt, 1)
        return AgentTaskStatus(state: map(raw), updatedAt: TimeInterval(ms) / 1000)
    }
}

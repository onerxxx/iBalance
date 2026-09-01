// AgentTaskStatus.swift — WorkBuddy / ZCode 任务状态读取
// 数据源（均为本机明文 SQLite，WAL 库：先只读直开拿 -wal 增量，失败再 immutable 直读主文件，
// 与 WbTokens.sessionProjects 同一打开链）：
//   WB    ~/.workbuddy/workbuddy.db       sessions.status      （planning=进行中，
//         completed=完成，error/terminated=中断）
//   ZCode ~/.zcode/v2/tasks-index.sqlite  tasks.task_status    （completed / error，
//         其余值按进行中处理）
// 状态映射为卡片 icon 光环：进行中=蓝 / 完成=绿 / 中断=橙红；
// 完成与中断最多显示 10 分钟（按库内 updated_at 计），进行中不过期。
// 后台 15s 轮询（两条单行查询，开销可忽略），可见状态变化时回调触发面板同步。
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
    private static let settledDisplayLimit: TimeInterval = 600
    /// 轮询间隔
    private static let pollInterval: TimeInterval = 15

    private static let queue = DispatchQueue(label: "ibalance.agentTaskStatus", qos: .utility)
    private static var timer: DispatchSourceTimer?
    private static var onChange: (() -> Void)?
    /// 最近一轮采样（queue 内读写）
    private static var latestWb: AgentTaskStatus?
    private static var latestZcode: AgentTaskStatus?
    /// 上次通知出去的可见状态（含过期口径），用于变化检测
    private static var lastNotified: (wb: AgentTaskState?, zcode: AgentTaskState?) = (nil, nil)

    private static let wbDbPath = NSHomeDirectory() + "/.workbuddy/workbuddy.db"
    private static let zcodeDbPath = NSHomeDirectory() + "/.zcode/v2/tasks-index.sqlite"

    // MARK: - 对外读取（主线程，makePanelSnapshot 调用）

    /// WB 当前可见任务状态（nil = 无光环）
    static var workbuddyVisible: AgentTaskState? {
        queue.sync { visible(latestWb) }
    }

    /// ZCode 当前可见任务状态（nil = 无光环）
    static var zcodeVisible: AgentTaskState? {
        queue.sync { visible(latestZcode) }
    }

    /// 应用 10 分钟过期：完成/中断超时 → nil；进行中恒可见
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
        latestZcode = queryLatest(path: zcodeDbPath,
                                  sql: "SELECT task_status, updated_at FROM tasks WHERE deleted = 0 ORDER BY updated_at DESC LIMIT 1",
                                  map: mapZcode)
        let nowVisible = (visible(latestWb), visible(latestZcode))
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

    /// ZCode tasks.task_status：completed=完成；error=中断；其余（运行中等）=进行中
    private static func mapZcode(_ raw: String) -> AgentTaskState {
        switch raw {
        case "completed": return .completed
        case "error", "cancelled", "failed": return .interrupted
        default: return .running
        }
    }

    // MARK: - SQLite 单行查询

    /// 打开库读首行（状态文本 + updated_at 毫秒）；库缺失/打开失败/无行返回 nil
    private static func queryLatest(path: String, sql: String,
                                     map: (String) -> AgentTaskState) -> AgentTaskStatus? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(db)
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard sqlite3_open_v2("file:\(escaped)?immutable=1", &db,
                                  SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        }
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

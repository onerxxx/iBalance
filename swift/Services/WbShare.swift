// WbShare.swift — iBalance
// WorkBuddy 多账号「同步共享」：把全部历史会话归属到当前登录账号（sessions.user_id 转移），
// 并以最近更新的记忆为基准广播到所有账号的 memory 文件——切到任何账号都能看到同一份
// 对话历史（可续聊）与记忆。
// (2026-09-01, 由「聚合查看」方案改写为「同步共享」方案)
//
// ─── 数据事实（2026-09-01 实测）────────────────────────────────────────────────
// - workbuddy.db sessions.user_id 是会话归属的唯一键；jsonl 正文路径
//   projects/{cwd编码}/{sessionId}.jsonl 与 artifact-index 均不含 uid
//   → 只转移 user_id，目标账号即可在会话列表看到并直接续聊
// - 记忆按 memory/{uid}_memory.md 分账号，三份为同构文档（~90% 重复）
//   → 合并拼接无意义，以 mtime 最新为基准广播到各账号文件
// - workspaces 表无 user_id（全局共享，无需处理）；automations 有 user_id 但 v1 不动
//
// ⚠️ 风险与约束
// - 必须先杀 WorkBuddy 再写库：WAL 并发写会 BUSY，且客户端内存态可能覆盖本地修改
//   （杀/等/强杀复用 ProcessUtil.killMainProcesses，与账号切换同款）
// - 转移不可从 db 反推：执行前把 (id, 旧 user_id) 明细导出到
//   ~/Library/Application Support/com.local.ibalance/wb_share_backup.json 留回滚依据
// - 记忆广播前把各账号原文件备份为 {uid}_memory.md.pre-share（保留首次，不覆盖）
// - 只写 sessions.user_id 一列 + memory 文件，不碰其他表/目录（WorkBuddy 升级零耦合）

import Cocoa
import SQLite3

/// Swift 的 SQLite3 module 不暴露 SQLITE_TRANSIENT 宏，自行构造等价 destructor
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 同步核心

enum WbShareSync {

    struct Preview {
        let totalSessions: Int       // 未删除会话总数
        let toMove: Int              // 将从其他账号转入的条数
        let memoryCount: Int         // 账号记忆文件数
        let memoryBaseNickname: String?  // mtime 最新的记忆归属账号（nil = 无记忆文件）
    }

    struct Report {
        var movedSessions = 0
        var memorySynced = 0
        var memoryBaseNickname: String?
        var backupPath: String?
        var error: String?
    }

    static var home: String { NSHomeDirectory() + "/.workbuddy" }
    static var dbPath: String { home + "/workbuddy.db" }

    /// 同步备份文件（id → 原 user_id 明细）
    static var backupPath: String {
        NSHomeDirectory() + "/Library/Application Support/com.local.ibalance/wb_share_backup.json"
    }

    /// 备份文件是否存在（回滚按钮可用性判断）
    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupPath) }

    /// 备份时间（弹窗展示「回滚到何时」），nil = 无备份
    static var backupDate: String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: backupPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = obj["date"] as? String else { return nil }
        return date
    }

    private static func openDb(flags: Int32) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
        return db
    }

    // MARK: 预览（只读，弹窗确认前调用）

    static func preview(targetUid: String, nicknameByUid: [String: String]) -> Preview {
        var total = 0, toMove = 0
        if let db = openDb(flags: SQLITE_OPEN_READONLY) {
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, """
                SELECT count(*), sum(CASE WHEN user_id != ?1 THEN 1 ELSE 0 END)
                FROM sessions WHERE deleted_at IS NULL
                """, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, targetUid, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    total = Int(sqlite3_column_int64(stmt, 0))
                    toMove = Int(sqlite3_column_int64(stmt, 1))
                }
            }
        }
        let memFiles = accountMemoryFiles()
        let base = memFiles.max(by: { $0.value.mtime < $1.value.mtime })
        let baseNick = base.flatMap { nicknameByUid[$0.key] ?? String($0.key.prefix(6)) }
        return Preview(totalSessions: total, toMove: toMove,
                       memoryCount: memFiles.count, memoryBaseNickname: baseNick)
    }

    // MARK: 执行（调用前必须已杀 WorkBuddy）

    /// 转移全部未删除会话归属到 targetUid，并把最新记忆广播到所有账号文件。
    static func perform(targetUid: String, nicknameByUid: [String: String]) -> Report {
        var report = Report()
        guard let db = openDb(flags: SQLITE_OPEN_READWRITE) else {
            report.error = "无法打开 workbuddy.db（\(dbPath)）"
            return report
        }
        defer { sqlite3_close(db) }

        // 1. 导出 (id, 旧 user_id) 备份 → 回滚依据（写 iBalance 自己的目录，不污染 ~/.workbuddy）
        var rows: [(String, String)] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, user_id FROM sessions WHERE deleted_at IS NULL AND user_id != ?1", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, targetUid, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let uid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                rows.append((id, uid))
            }
            sqlite3_finalize(stmt)
        }
        if !rows.isEmpty, let data = try? JSONSerialization.data(withJSONObject: [
            "date": ISO8601DateFormatter().string(from: Date()),
            "targetUid": targetUid,
            "rows": rows.map { ["id": $0.0, "user_id": $0.1] },
        ]) {
            let dir = NSHomeDirectory() + "/Library/Application Support/com.local.ibalance"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/wb_share_backup.json"
            try? data.write(to: URL(fileURLWithPath: path))
            report.backupPath = path
        }

        // 2. UPDATE sessions SET user_id = target（单事务原子提交）
        if sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK {
            var upd: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE sessions SET user_id = ?1 WHERE deleted_at IS NULL AND user_id != ?1", -1, &upd, nil) == SQLITE_OK {
                sqlite3_bind_text(upd, 1, targetUid, -1, SQLITE_TRANSIENT)
                if sqlite3_step(upd) == SQLITE_DONE {
                    report.movedSessions = Int(sqlite3_changes(db))
                }
                sqlite3_finalize(upd)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
        Logger.log(.switchAccount, "[wb-share] sessions moved: \(report.movedSessions) → uid=\(targetUid)")

        // 3. 记忆广播：mtime 最新为基准，写入其余账号文件（原文件备份 .pre-share，保留首次）
        let memFiles = accountMemoryFiles()
        if let base = memFiles.max(by: { $0.value.mtime < $1.value.mtime }) {
            let baseContent = base.value.content
            report.memoryBaseNickname = nicknameByUid[base.key] ?? String(base.key.prefix(6))
            for (uid, info) in memFiles where uid != base.key {
                let path = info.url.path
                let bak = path + ".pre-share"
                if !FileManager.default.fileExists(atPath: bak) {
                    try? FileManager.default.copyItem(atPath: path, toPath: bak)
                }
                if (try? baseContent.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                    report.memorySynced += 1
                } else {
                    Logger.log(.switchAccount, "[wb-share] memory write FAILED: \(path)")
                }
            }
            Logger.log(.switchAccount, "[wb-share] memory base=\(base.key) synced=\(report.memorySynced) files")
        }
        return report
    }

    // MARK: 回滚（调用前必须已杀 WorkBuddy）

    struct RollbackReport {
        var restoredSessions = 0
        var restoredMemories = 0
        var error: String?
    }

    /// 按最近一次同步的备份恢复：会话归属逐条还原（按 id 精确 UPDATE），
    /// 记忆从 .pre-share 拷回（备份文件保留，回滚可重复执行）。
    /// 注意：同步之后新建的会话不在备份明细里，归属保持现状（合理——它们本来就属于当前账号）。
    static func rollback() -> RollbackReport {
        var report = RollbackReport()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: backupPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["rows"] as? [[String: String]] else {
            report.error = "备份文件缺失或损坏（\(backupPath)）"
            return report
        }
        guard let db = openDb(flags: SQLITE_OPEN_READWRITE) else {
            report.error = "无法打开 workbuddy.db"
            return report
        }
        defer { sqlite3_close(db) }

        // 1. 会话归属逐条还原（单事务）
        if sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK {
            var upd: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE sessions SET user_id = ?1 WHERE id = ?2", -1, &upd, nil) == SQLITE_OK {
                for row in rows {
                    guard let id = row["id"], let uid = row["user_id"] else { continue }
                    sqlite3_reset(upd)
                    sqlite3_bind_text(upd, 1, uid, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(upd, 2, id, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(upd) == SQLITE_DONE { report.restoredSessions += 1 }
                }
                sqlite3_finalize(upd)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
        Logger.log(.switchAccount, "[wb-share] rollback sessions restored: \(report.restoredSessions)")

        // 2. 记忆从 .pre-share 拷回（copy 而非 move：备份保留，回滚幂等）
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: home + "/memory"),
                                                   includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasSuffix(".pre-share") {
                let target = URL(fileURLWithPath: String(f.path.dropLast(".pre-share".count)))
                // 目标已存在先删（copyItem 不覆盖），copy 而非 move：备份保留，回滚幂等
                if fm.fileExists(atPath: target.path) {
                    try? fm.removeItem(at: target)
                }
                if (try? fm.copyItem(at: f, to: target)) != nil {
                    report.restoredMemories += 1
                } else {
                    report.error = report.error ?? "记忆恢复失败：\(target.lastPathComponent)"
                }
            }
        }
        Logger.log(.switchAccount, "[wb-share] rollback memories restored: \(report.restoredMemories)")
        return report
    }

    // MARK: 记忆文件枚举

    private static func accountMemoryFiles() -> [String: (url: URL, content: String, mtime: Date)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: home + "/memory"),
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return [:]
        }
        var result: [String: (URL, String, Date)] = [:]
        for f in files {
            let name = f.lastPathComponent
            guard name.hasSuffix("_memory.md") else { continue }  // 跳过 .bak / .pre-share
            guard let content = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let uid = String(name.dropLast("_memory.md".count))
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            result[uid] = (f, content, mtime)
        }
        return result
    }
}

// MARK: - 弹窗与编排

@MainActor
extension AppDelegate {

    /// 同步共享：确认弹窗 → 杀 WorkBuddy → 转移会话归属 + 广播记忆 → 重启 WorkBuddy → 结果弹窗。
    /// 磁贴入口（操作卡片「同步共享」）。
    /// 整段必须包在 keepPanelAliveDuring 内（含首个确认弹窗）：否则 .transient popover 会把
    /// 「与弹窗的交互」判为点击面板外 → popoverDidClose 里 NSApp.hide 连弹窗一起隐藏
    /// （表现即「弹窗一出现就消失」，与 API Key 等弹窗同一坑，见 main.swift 注释）。
    @objc func onShareWbHistory() {
        keepPanelAliveDuring {
            // 当前登录账号（auth 文件实时读；无登录则提示后返回）
            guard let auth = WorkBuddyService.authInfo() else {
                let warn = DialogShell()
                warn.addIcon(makeWbBrandIcon())
                warn.addTitle("同步共享")
                warn.addInfo("未检测到 WorkBuddy 登录信息（workbuddy-desktop.info 不存在或无效），请先登录任一账号。")
                warn.addButton("好")
                _ = warn.present()
                return
            }
            let nickByUid: [String: String] = {
                var m: [String: String] = [:]
                for a in wbCheckinAccounts() where !a.nickname.isEmpty { m[a.uid] = a.nickname }
                if m[auth.uid] == nil { m[auth.uid] = auth.nickname }
                return m
            }()
            let pv = WbShareSync.preview(targetUid: auth.uid, nicknameByUid: nickByUid)

            // 确认弹窗：执行同步（默认）/ 回滚 / 取消
            let shell = DialogShell()
            shell.addIcon(makeWbBrandIcon())
            shell.addTitle("同步共享")
            var info = "将全部历史会话与记忆同步给当前登录账号「\(auth.nickname)」。\n"
            info += "共 \(pv.totalSessions) 条会话（\(pv.toMove) 条将从其他账号转入），"
            if let base = pv.memoryBaseNickname {
                info += "\(pv.memoryCount) 份账号记忆以最近更新的「\(base)」为基准同步。"
            } else {
                info += "未找到账号记忆文件。"
            }
            info += "\n执行时会退出并重启 WorkBuddy；会话正文与记忆内容不受影响，原归属已备份可回滚。"
            if let date = WbShareSync.backupDate {
                info += "\n（已有备份：\(date.prefix(16).replacingOccurrences(of: "T", with: " "))，可用「回滚」还原）"
            }
            shell.addInfo(info)
            // 注意：DialogShell.present() 返回按钮索引（0/1/2，Esc/关闭 = -1），不是 ModalResponse
            let idxSync = shell.addButton("执行同步")
            let idxRollback = shell.addButton("回滚")
            _ = shell.addButton("取消")
            let choice = shell.present()
            if choice != idxSync && choice != idxRollback { return }  // 取消 / Esc / 关闭：什么都不做

            // 执行：杀 → 同步/回滚 → （若原本在运行）重启
            let wasRunning = !ProcessUtil.mainPids(bundleId: "com.tencent.workbuddy.mac").isEmpty
            ProcessUtil.killMainProcesses(bundleId: "com.tencent.workbuddy.mac", label: "WorkBuddy")
            let t0 = Date()

            // 结果弹窗（回滚分支）
            if choice == idxRollback {
                let rb = WbShareSync.rollback()
                Logger.log(.switchAccount, "[wb-share] rollback done in \(ProcessUtil.ms(since: t0))ms")
                if wasRunning { WorkBuddyService.restartWorkBuddy() }
                let done = DialogShell()
                done.addIcon(makeWbBrandIcon())
                done.addTitle("同步共享 · 回滚")
                if let err = rb.error {
                    done.addInfo("回滚失败：\(err)")
                } else {
                    var msg = "已按最近一次同步前的备份还原：\(rb.restoredSessions) 条会话回到原账号归属，"
                    msg += "\(rb.restoredMemories) 份记忆文件恢复原内容。\n"
                    msg += wasRunning ? "WorkBuddy 正在重启。" : "WorkBuddy 未在运行，下次启动即生效。"
                    msg += "\n注意：之后用 iBalance 切号时仍会自动执行同步。"
                    done.addInfo(msg)
                }
                done.addButton("好")
                _ = done.present()
                return
            }

            // 同步分支
            let report = WbShareSync.perform(targetUid: auth.uid, nicknameByUid: nickByUid)
            Logger.log(.switchAccount, "[wb-share] perform done in \(ProcessUtil.ms(since: t0))ms")
            if wasRunning { WorkBuddyService.restartWorkBuddy() }

            // 结果弹窗
            let done = DialogShell()
            done.addIcon(makeWbBrandIcon())
            done.addTitle("同步共享")
            if let err = report.error {
                done.addInfo("同步失败：\(err)（WorkBuddy 数据未被改动）")
            } else {
                var msg = "已将 \(report.movedSessions) 条会话归属到「\(auth.nickname)」。\n"
                if let base = report.memoryBaseNickname, report.memorySynced > 0 {
                    msg += "记忆已按「\(base)」（最近更新）同步到 \(report.memorySynced) 个账号文件。"
                }
                if wasRunning { msg += "\nWorkBuddy 正在重启。" } else { msg += "\nWorkBuddy 未在运行，下次启动即生效。" }
                done.addInfo(msg)
            }
            done.addButton("好")
            _ = done.present()
        }
    }
}

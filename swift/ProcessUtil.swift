// ProcessUtil.swift — Electron 应用切号共用的进程工具
// （找主进程 / 温和杀 / 强杀 / 等待退出），WorkBuddy 与 TRAE 复用。
import Darwin
import Foundation

enum ProcessUtil {
    /// 计算从 start 到现在的毫秒数（耗时日志用）
    static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// 收集主进程 PID：ps 全表逐行匹配（小写），要求包含全部关键词，排除 Electron 子进程。
    /// WorkBuddy 传 ["workbuddy.app/contents/macos/"]；TRAE 主程序名与 .app 路径无固定前缀，传 ["trae", ".app/contents/macos/"]。
    static func mainPids(containingAll keywords: [String]) -> [Int] {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        // ⚠️ 必须先读数据再等退出，否则 ps 输出填满 pipe 缓冲区后会死锁
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var result: [Int] = []
        for line in output.split(separator: "\n") {
            let lower = line.lowercased()
            guard keywords.allSatisfy({ lower.contains($0) }),
                  !isHelperCommandLine(lower) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let spaceIdx = trimmed.firstIndex(of: " "),
               let pid = Int(trimmed[..<spaceIdx].trimmingCharacters(in: .whitespaces)) {
                result.append(pid)
            }
        }
        return result
    }

    /// 判断是否为 Electron 子进程（helper/renderer/gpu/crashpad 等）
    static func isHelperCommandLine(_ cmd: String) -> Bool {
        let helperKeywords: [String] = [
            "--type=", "helper", "renderer", "gpu", "crashpad",
            "utility", "audio", "sandbox", "--node-ipc",
            "--clientprocessid=", "resources/app/extensions/",
        ]
        return helperKeywords.contains { cmd.contains($0) }
    }

    /// 杀掉主进程：SIGTERM 等 0.8s（正常约 600ms 退出），超时对残留 SIGKILL 强杀（最坏 < 1s）。
    /// 仿 Cockpit Tools：只杀主进程，Electron 主进程退出自动回收子进程。
    /// label 仅用于日志前缀（"WorkBuddy" / "TRAE"）。
    static func killMainProcesses(containingAll keywords: [String], label: String) {
        let tCollect = Date()
        let pids = mainPids(containingAll: keywords)
        Logger.log(.switchAccount, "[iBalance] \(label) collected pids (\(ms(since: tCollect))ms): \(pids)")
        guard !pids.isEmpty else {
            Logger.log(.switchAccount, "[iBalance] no \(label) pids found, skipping kill")
            return
        }
        sendSignal(pids, SIGTERM)
        Logger.log(.switchAccount, "[iBalance] \(label) SIGTERM sent, waiting up to 0.8s...")
        if waitPidsExit(pids, timeout: 0.8) {
            Logger.log(.switchAccount, "[iBalance] \(label) all pids exited (round 1)")
            return
        }
        let remaining = mainPids(containingAll: keywords)
        Logger.log(.switchAccount, "[iBalance] \(label) remaining after round 1: \(remaining)")
        guard !remaining.isEmpty else { return }
        sendSignal(remaining, SIGKILL)
        _ = waitPidsExit(remaining, timeout: 1.0)
        Logger.log(.switchAccount, "[iBalance] \(label) SIGKILL done")
    }

    /// 杀掉指定主进程 PID：SIGTERM 等 0.8s，超时 SIGKILL（节奏同 killMainProcesses）。
    /// 用于无法按命令行关键词定位主进程的应用（如 ZCode 主进程命令行为裸二进制名
    /// "ZCode"，无 .app 路径可匹配，需按 bundleId 经 NSRunningApplication 取 PID）
    static func killMainProcess(pid: Int, label: String) {
        Logger.log(.switchAccount, "[iBalance] \(label) kill pid \(pid)")
        sendSignal([pid], SIGTERM)
        Logger.log(.switchAccount, "[iBalance] \(label) SIGTERM sent, waiting up to 0.8s...")
        if waitPidsExit([pid], timeout: 0.8) {
            Logger.log(.switchAccount, "[iBalance] \(label) pid \(pid) exited (round 1)")
            return
        }
        sendSignal([pid], SIGKILL)
        _ = waitPidsExit([pid], timeout: 1.0)
        Logger.log(.switchAccount, "[iBalance] \(label) SIGKILL done")
    }

    /// 对一组 PID 发信号：直接 kill 系统调用，不起 /bin/kill 子进程
    private static func sendSignal(_ pids: [Int], _ sig: Int32) {
        for pid in pids { _ = kill(pid_t(pid), sig) }
    }

    /// 轮询等待 PID 退出（每 120ms 查一次），僵尸态（Z）视为已退出
    static func waitPidsExit(_ pids: [Int], timeout: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if !pids.contains(where: { isRunning($0) }) { return true }
            Thread.sleep(forTimeInterval: 0.12)
        }
        return false
    }

    /// 检查 PID 是否存活（ps -p <pid> -o stat=，僵尸态 Z 视为已死）
    static func isRunning(_ pid: Int) -> Bool {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "stat="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespaces) else { return false }
        if output.isEmpty { return false }
        if output.first == "Z" || output.first == "z" { return false }
        return true
    }
}

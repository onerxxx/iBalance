// ProcessUtil.swift — Electron 应用切号共用的进程工具
// （找主进程 / 温和杀 / 强杀 / 等待退出），WorkBuddy / TRAE / ZCode 复用。
import AppKit
import Darwin
import Foundation

enum ProcessUtil {
    /// 计算从 start 到现在的毫秒数（耗时日志用）
    static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// 按 bundle id 精确匹配运行中的应用主进程 PID。
    /// NSRunningApplication 只登记各 app 的主进程（Electron helper/renderer 不在其中，
    /// 天然排除子进程），也避免命令行关键词匹配误伤路径恰好含关键词的无关进程。
    static func mainPids(bundleId: String) -> [Int] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .map { Int($0.processIdentifier) }
    }

    /// 杀掉应用主进程：SIGTERM 等 1.5s（WorkBuddy 5.4.7 退出流程含遥测打点，0.8s 内
    /// 经常退不完；正常约 600ms 退出则 round 1 直接返回，不影响耗时），超时对残留
    /// SIGKILL 强杀。⚠️ 强杀会让 Electron 单实例锁残留，调用方重启前须清锁
    /// （WorkBuddyService.clearElectronSingletonLocks），否则新实例被误判静默退出。
    /// label 仅用于日志前缀（"WorkBuddy" / "TRAE" / "ZCode"）。
    static func killMainProcesses(bundleId: String, label: String) {
        let tCollect = Date()
        let pids = mainPids(bundleId: bundleId)
        Logger.log(.switchAccount, "[iBalance] \(label) collected pids (\(ms(since: tCollect))ms): \(pids)")
        guard !pids.isEmpty else {
            Logger.log(.switchAccount, "[iBalance] no \(label) pids found, skipping kill")
            return
        }
        sendSignal(pids, SIGTERM)
        Logger.log(.switchAccount, "[iBalance] \(label) SIGTERM sent, waiting up to 1.5s...")
        if waitPidsExit(pids, timeout: 1.5) {
            Logger.log(.switchAccount, "[iBalance] \(label) all pids exited (round 1)")
            return
        }
        let remaining = mainPids(bundleId: bundleId)
        Logger.log(.switchAccount, "[iBalance] \(label) remaining after round 1: \(remaining)")
        guard !remaining.isEmpty else { return }
        sendSignal(remaining, SIGKILL)
        let exited = waitPidsExit(remaining, timeout: 1.0)
        Logger.log(.switchAccount, "[iBalance] \(label) SIGKILL done, exited=\(exited)")
    }

    /// 对一组 PID 发信号：直接 kill 系统调用，不起 /bin/kill 子进程
    private static func sendSignal(_ pids: [Int], _ sig: Int32) {
        for pid in pids { _ = kill(pid_t(pid), sig) }
    }

    /// 轮询等待 PID 退出（每 120ms 查一次）
    static func waitPidsExit(_ pids: [Int], timeout: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if !pids.contains(where: { isRunning($0) }) { return true }
            Thread.sleep(forTimeInterval: 0.12)
        }
        return false
    }

    /// 检查 PID 是否存活：kill(pid, 0) 零开销探测（信号 0 只做存在性/权限检查，不实际发送），
    /// 替代旧版每次 fork 一个 /bin/ps 的轮询实现。ESRCH = 进程不存在；
    /// EPERM（存在但属其他用户）按存活处理。僵尸态在父进程回收前仍报存活，
    /// 最坏多等一轮轮询（120ms）再进 SIGKILL 兜底，不影响正确性。
    static func isRunning(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// 按可执行文件完整路径收集该应用的全部 Electron 进程 PID（含 prewarm / daemon /
    /// sidecar / serve 等子进程）。NSRunningApplication 只登记各 app 的主进程，Electron
    /// 子进程不在其中——主进程被切号杀掉后它们会变孤儿进程残留（实测 `--prewarm`
    /// 守护能存活多次切号），让 LaunchServices 误判「应用仍在运行」，紧随其后的 open
    /// 被路由到死实例而不启动新进程。用 pgrep -f 匹配完整路径，避免命令行关键词误伤。
    static func allElectronPids(executablePath: String) -> [Int] {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-f", executablePath]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        task.waitUntilExit()
        guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }
        return out.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 清理应用残留的 Electron 进程（孤儿子进程/守护）：SIGTERM 等 1.5s，超时 SIGKILL。
    /// 返回清理后仍存活的进程数（0 = 干净）。切号时在 open 重启前调用，确保旧实例
    /// 彻底终结、LaunchServices 完成注销，新实例 open 才能可靠启动。
    static func cleanupRemainingElectronProcesses(executablePath: String, label: String) -> Int {
        let pids = allElectronPids(executablePath: executablePath)
        guard !pids.isEmpty else { return 0 }
        Logger.log(.switchAccount, "[iBalance] \(label) orphan electron pids: \(pids)")
        sendSignal(pids, SIGTERM)
        if waitPidsExit(pids, timeout: 1.5) {
            Logger.log(.switchAccount, "[iBalance] \(label) orphans exited after SIGTERM")
            return 0
        }
        let alive = pids.filter { isRunning($0) }
        guard !alive.isEmpty else { return 0 }
        sendSignal(alive, SIGKILL)
        let exited = waitPidsExit(alive, timeout: 1.0)
        Logger.log(.switchAccount, "[iBalance] \(label) orphans SIGKILL done, exited=\(exited)")
        return exited ? 0 : alive.filter { isRunning($0) }.count
    }
}

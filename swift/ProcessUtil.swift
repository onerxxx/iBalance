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

    /// 杀掉应用主进程：SIGTERM 等 0.8s（正常约 600ms 退出），超时对残留 SIGKILL 强杀（最坏 < 1s）。
    /// 仿 Cockpit Tools：只杀主进程，Electron 主进程退出自动回收子进程。
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
        Logger.log(.switchAccount, "[iBalance] \(label) SIGTERM sent, waiting up to 0.8s...")
        if waitPidsExit(pids, timeout: 0.8) {
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
}

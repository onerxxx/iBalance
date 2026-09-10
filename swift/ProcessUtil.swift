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

    // MARK: - Electron 应用重启（清锁 → 清孤儿 → open -b → 验证重试）

    /// 各 Electron 应用 userData 目录下可能出现的单实例锁文件名
    private static let singletonLockNames = ["SingletonLock", "SingletonCookie", "SingletonSocket"]

    /// 删除 userData 目录里残留的单实例锁：SIGKILL 强杀后锁不会自动清理，且进程僵尸期
    /// kill(pid,0) 仍判存活 → 紧随其后的 open 被锁误判「已有实例」，新实例静默退出
    ///（WorkBuddy 2026-09-01 实测「App 起不来」根因；TRAE/ZCode 同为 Electron，同病）。
    /// 只删锁文件，不碰业务数据；目录不存在/无锁文件时静默跳过。
    static func clearSingletonLocks(in dirs: [String], label: String) {
        let fm = FileManager.default
        for dir in dirs {
            for name in singletonLockNames {
                let p = (dir as NSString).appendingPathComponent(name)
                guard fm.fileExists(atPath: p) else { continue }
                try? fm.removeItem(atPath: p)
                Logger.log(.switchAccount, "[iBalance] \(label) cleared stale singleton lock: \(p)")
            }
        }
    }

    /// 应用主可执行文件完整路径（清孤儿进程时给 pgrep 用）：由 bundle id 定位 .app，
    /// 再从 Info.plist 取 CFBundleExecutable，避免各平台硬编码路径失配
    ///（TRAE 可执行名 Electron、ZCode 可执行名 ZCode，写死必错其一）。
    static func appExecutablePath(bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return Bundle(url: url)?.executablePath
    }

    /// 启动 GUI 应用前清掉会污染 Electron / LaunchServices 的环境变量。
    /// iBalance 若被 WorkBuddy（或终端 CLI 模式）拉起，会继承：ELECTRON_RUN_AS_NODE=1、
    /// NODE_OPTIONS=--require …shim、__CFBundleIdentifier、XPC_SERVICE_NAME、全套
    /// WORKBUDDY_*。这些变量泄漏给 `open` 启动的新实例：
    /// ① ELECTRON_RUN_AS_NODE=1 → 目标以 Node 模式启动，无窗口、0.5s 内 exit(0) 秒退；
    /// ② __CFBundleIdentifier / XPC_SERVICE_NAME → LaunchServices 实例归属判断错乱；
    /// ③ WORKBUDDY_USER_DATA_DIR / WORKBUDDY_STARTUP_PID 等强制旧实例路径与归属。
    /// 参照 cockpit-tools sanitize_macos_gui_launch_env。
    static func sanitizedLaunchEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let before = Set(env.keys)
        let toxicKeys: Set<String> = [
            "NODE_OPTIONS", "NODE_PATH", "NODE_ENV",
            "ELECTRON_RUN_AS_NODE", "ELECTRON_NO_ASAR",
            "ELECTRON_FORCE_WINDOW_MENU_BAR", "ELECTRON_NO_ATTACH_CONSOLE",
            "__CFBundleIdentifier", "XPC_SERVICE_NAME",
            "npm_config_prefix", "npm_config_devdir",
        ]
        for key in toxicKeys { env.removeValue(forKey: key) }
        let wbKeys = env.keys.filter { $0.hasPrefix("WORKBUDDY_") }
        for key in wbKeys { env.removeValue(forKey: key) }
        let removed = before.subtracting(env.keys).sorted()
        if !removed.isEmpty {
            Logger.log(.switchAccount, "[iBalance] sanitized env, removed: \(removed.joined(separator: ","))")
        }
        return env
    }

    /// 按 bundle id 启动应用（**不带 -n**：旧进程死后残留锁 + 僵尸期误判，新实例会静默退出）。
    /// 卡片点击「打开应用」与切号重启共用：都走 /usr/bin/open + 净化环境，避免
    /// NSWorkspace 把 iBalance 的进程环境（可能含 ELECTRON_RUN_AS_NODE 等）直接传给
    /// Electron 目标应用导致其 Node 模式秒退。
    static func openApp(bundleId: String, label: String) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-b", bundleId]
        task.environment = sanitizedLaunchEnvironment()
        do {
            try task.run()
        } catch {
            Logger.log(.switchAccount, "[iBalance] open \(label) failed: \(error.localizedDescription)")
        }
    }

    /// 切号后重启 Electron 应用的统一收尾（WorkBuddy / TRAE / ZCode 共用）：
    /// 清单例锁 → 清残留 Electron 进程（孤儿 helper/prewarm 会让 LaunchServices 误判
    /// 「仍在运行」，open 被路由到死实例）→ open -b → 5s 内验证主进程出现
    ///（冷启动 3.5-4.5s，2s 窗口会误判而重复 open）→ 未出现则再清一次并重试。
    /// lockDirs：该应用 userData 目录候选（Singleton* 锁文件所在处）。
    /// 返回：重试后主进程是否确认出现（false = 启动失败，调用方记日志/提示）
    @discardableResult
    static func relaunch(bundleId: String, label: String, lockDirs: [String] = []) -> Bool {
        let execPath = appExecutablePath(bundleId: bundleId)
        if execPath == nil {
            Logger.log(.switchAccount, "[iBalance] \(label) app not found for bundleId=\(bundleId)")
        }
        clearSingletonLocks(in: lockDirs, label: label)
        if let execPath {
            _ = cleanupRemainingElectronProcesses(executablePath: execPath, label: label)
        }
        openApp(bundleId: bundleId, label: label)
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !mainPids(bundleId: bundleId).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        Logger.log(.switchAccount, "[iBalance] \(label) not running after open, cleaning and retrying")
        clearSingletonLocks(in: lockDirs, label: label)
        if let execPath {
            _ = cleanupRemainingElectronProcesses(executablePath: execPath, label: label)
        }
        openApp(bundleId: bundleId, label: label)
        let retryDeadline = Date().addingTimeInterval(5.0)
        while Date() < retryDeadline {
            if !mainPids(bundleId: bundleId).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        Logger.log(.switchAccount, "[iBalance] \(label) STILL not running after retry, give up")
        return false
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

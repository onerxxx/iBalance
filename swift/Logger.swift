// Logger.swift — 统一日志工具，取代各 Service 中的私有 appendLog 实现
import Foundation

enum Logger {
    /// 日志时间戳格式化器（缓存复用；DateFormatter 10.9+ 线程安全）
    private static let tsFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    /// 统一锁：多线程并发写日志时保护「定位 EOF → write → close」原子
    private static let lock = NSLock()

    /// 预定义日志通道
    enum Channel: String, CaseIterable {
        case switchAccount = "iBalance_switch"
        case traeCheckin   = "iBalance_trae_checkin"
        case refresh       = "iBalance_refresh"
        case network       = "iBalance_network"
    }

    /// 追加一行日志到 /tmp/<channel>.log（带时间戳 HH:mm:ss.SSS）。
    /// 直接在调用线程写：文件 IO ≈ 几 µs，避免 DispatchQueue.async 在进程退出时
    /// 排队 block 尚未执行就丢失日志的问题（尤其启动期和终止期）。
    /// 多线程安全：用 NSLock 保护，保证每行不交错。
    /// 写文件失败时 fallback 到 stderr（带 WARN 前缀），保证任何启动方式下日志都有处可看。
    static func log(_ channel: Channel, _ msg: String) {
        let ts = tsFormatter.string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        guard let data = line.data(using: .utf8) else {
            fputs("[Logger] utf8 encode failed: \(msg)\n", stderr)
            return
        }
        let url = URL(fileURLWithPath: "/tmp/\(channel.rawValue).log")
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        var writtenOK = false
        var writeErr: String?
        do {
            if fm.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seek(toOffset: handle.seekToEndOfFile())
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))],
                                     ofItemAtPath: url.path)
            }
            writtenOK = true
        } catch {
            writeErr = "\(error)"
            writtenOK = false
        }
        if !writtenOK {
            // Fallback：任何原因写文件失败，至少把日志推到 stderr（便于 Xcode/终端/tail 查看）。
            // 不加 stderr 前缀区分正常输出，避免未来上层重定向 stdout 时看不到。
            let hint = writeErr.map { " (file-write failed: \($0))" } ?? " (file-write failed)"
            fputs(line, stderr)
            if !hint.isEmpty {
                fputs("[Logger.stderr]\(hint)\n", stderr)
            }
        }
    }

    /// 耗时测量：执行 block 并打印「<tag> start/done in 1234ms / FAILED」。
    /// 日志全部走 Channel.refresh；错误不吞，原样抛出。
    @discardableResult
    static func measure<T>(_ tag: String,
                           _ block: () async throws -> T) async rethrows -> T {
        let t0 = Date()
        log(.refresh, "▶︎ \(tag) start")
        do {
            let r = try await block()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log(.refresh, "✓ \(tag) done in \(ms)ms")
            return r
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log(.refresh, "✗ \(tag) FAILED in \(ms)ms — \(error.localizedDescription)")
            throw error
        }
    }

    /// 同步版 measure（用于非 async 代码）
    @discardableResult
    static func measureSync<T>(_ tag: String,
                               _ block: () throws -> T) rethrows -> T {
        let t0 = Date()
        log(.refresh, "▶︎ \(tag) start")
        do {
            let r = try block()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log(.refresh, "✓ \(tag) done in \(ms)ms")
            return r
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log(.refresh, "✗ \(tag) FAILED in \(ms)ms — \(error.localizedDescription)")
            throw error
        }
    }
}

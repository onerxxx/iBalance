// Logger.swift — 统一日志工具，取代各 Service 中的私有 appendLog 实现
import Foundation

enum Logger {
    /// 预定义日志通道
    enum Channel: String {
        case switchAccount = "iBalance_switch"
        case traeCheckin   = "iBalance_trae_checkin"
    }

    /// 追加一行日志到 /tmp/<channel>.log（带时间戳 HH:mm:ss.SSS）
    static func log(_ channel: Channel, _ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let ts = df.string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/\(channel.rawValue).log")
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    _ = try? handle.seekToEnd()
                    _ = try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}

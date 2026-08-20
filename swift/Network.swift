// Network.swift — 异步 HTTP 请求 + 统一重试 + 离线感知 + 通用 JSON 工具
import Foundation
import Network

// MARK: - 异步 HTTP 请求

enum HTTP {
    /// 异步发起一次请求；网络错误返回 (nil, 0)，HTTP 响应返回 (data?, statusCode)。
    /// URLSession async API 在请求完成/超时后自动取消 task，不再泄漏（替代旧版 semaphore 方案）。
    static func request(url: URL,
                        method: String = "GET",
                        headers: [String: String] = [:],
                        body: Data? = nil,
                        timeout: TimeInterval) async -> (Data?, Int) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let t0 = Date()
        let tag = "\(method) \(url.absoluteString)"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Logger.log(.network, "\(tag) → HTTP \(code) (\(ms)ms, \(data.count)B)")
            return (data, code)
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let ns = error as NSError
            Logger.log(.network, "\(tag) → ERROR \(ns.domain)/\(ns.code) after \(ms)ms: \(error.localizedDescription)")
            return (nil, 0)
        }
    }

    /// 带重试的请求：仅在「网络错误」（status == 0）时重试，HTTP 响应（含 4xx/5xx）不重试。
    /// 退避按 attempt 线性递增，避免短时内风暴。
    static func requestWithRetry(url: URL,
                                 method: String = "GET",
                                 headers: [String: String] = [:],
                                 body: Data? = nil,
                                 timeout: TimeInterval,
                                 retries: Int = 1,
                                 backoff: TimeInterval = 2) async -> (Data?, Int) {
        let tag = "\(method) \(url.absoluteString) timeout=\(timeout)s retries=\(retries)"
        var attempt = 0
        while true {
            let r = await request(url: url, method: method, headers: headers, body: body, timeout: timeout)
            if r.1 != 0 || attempt >= retries {
                if r.1 == 0 {
                    Logger.log(.network, "RETRY EXHAUSTED: \(tag) — giving up after \(attempt + 1) attempt(s)")
                }
                return r
            }
            attempt += 1
            let delayNs = UInt64(backoff * Double(attempt) * 1_000_000_000)
            Logger.log(.network, "RETRY \(attempt)/\(retries): \(tag) — waiting \(backoff * Double(attempt))s")
            try? await Task.sleep(nanoseconds: delayNs)
        }
    }
}

// MARK: - 离线感知

/// 单例：监听系统网络状态，离线时暂停刷新，恢复时立即触发刷新。
/// 标为 @MainActor：状态只由主线程读写，避免多线程竞争。
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ibalance.netmon")
    private(set) var isOnline: Bool = true
    var onChange: ((Bool) -> Void)?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // handler 在 monitor 自己的队列上触发，通过 Task 回主线程更新状态
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.update(online) }
        }
        monitor.start(queue: queue)
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}

// MARK: - 通用 JSON / 工具

/// 兼容 Double/Int/String 的数值解包（CodeBuddy、TRAE 等接口同一字段类型不统一）。
struct FlexibleDouble: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let i = try? c.decode(Int.self) { value = Double(i) }
        else if let s = try? c.decode(String.self), let d = Double(s) { value = d }
        else { value = 0 }
    }
}

/// 任意值转 Double（String/Double/Int），失败返回 nil。
func anyToDouble(_ value: Any) -> Double? {
    switch value {
    case let s as String: return Double(s)
    case let n as Double: return n
    case let n as Int:    return Double(n)
    default:              return nil
    }
}

/// 嵌套字典取值（按 key 路径逐层取 [String:Any]）——签到接口结构变体多，保留松散解析。
func nestedDict(_ json: [String: Any], keys: [String]) -> [String: Any]? {
    var cur: Any = json
    for k in keys {
        guard let d = cur as? [String: Any], let v = d[k] as? [String: Any] else { return nil }
        cur = v
    }
    return cur as? [String: Any]
}

/// JSON 数值提取（兼容 Double/Int）
func jsonNum(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    return 0
}

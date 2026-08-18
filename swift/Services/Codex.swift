// Codex.swift — 从 ~/.codex/auth.json 导入登录账号并读取 Codex usage
import Foundation

enum CodexImportResult {
    case success(CodexAccount)
    case failure(String)
}

enum CodexService {
    private static let authPath = NSHomeDirectory() + "/.codex/auth.json"
    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    /// Codex CLI/Desktop 的登录态是本机 JSON；只读取，不修改原文件。
    static func importCurrentAccount() -> CodexImportResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            return .failure("未找到 ~/.codex/auth.json，请先在 Codex 中登录")
        }
        let payload = jwtPayload(token) ?? [:]
        let idPayload = (tokens["id_token"] as? String).flatMap(jwtPayload) ?? [:]
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        let idProfile = idPayload["https://api.openai.com/profile"] as? [String: Any]
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let email = (profile?["email"] as? String)
            ?? (idProfile?["email"] as? String)
            ?? (payload["email"] as? String)
            ?? (idPayload["email"] as? String)
            ?? ""
        let uid = (tokens["account_id"] as? String)
            ?? (auth?["chatgpt_account_id"] as? String)
            ?? (payload["sub"] as? String)
            ?? ""
        guard !uid.isEmpty else { return .failure("无法解析 Codex 登录账号") }
        guard !email.isEmpty else { return .failure("无法从 Codex 登录凭据读取邮箱") }
        return .success(CodexAccount(uid: uid, token: token, email: email))
    }

    static func currentUid() -> String? {
        guard case .success(let account) = importCurrentAccount() else { return nil }
        return account.uid
    }

    struct Usage {
        let uid: String
        let email: String
        let usedPercent: Double
        let resetAt: TimeInterval
    }

    static func fetchUsage(token: String, fallbackUid: String, fallbackEmail: String) async -> Usage? {
        guard let url = URL(string: usageURL) else { return nil }
        let (data, status) = await HTTP.requestWithRetry(
            url: url, method: "GET",
            headers: ["Authorization": "Bearer \(token)", "Accept": "application/json", "User-Agent": "Codex"],
            timeout: 15
        )
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = json["rate_limit"] as? [String: Any],
              let primary = rate["primary_window"] as? [String: Any] else { return nil }
        let used = number(primary["used_percent"])
        var resetAt = number(primary["reset_at"])
        if resetAt <= 0 {
            resetAt = Date().timeIntervalSince1970 + number(primary["reset_after_seconds"])
        }
        let uid = (json["user_id"] as? String) ?? fallbackUid
        let email = (json["email"] as? String) ?? fallbackEmail
        return Usage(uid: uid, email: email, usedPercent: min(100, max(0, used)), resetAt: resetAt)
    }

    private static func number(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var raw = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw.append("=") }
        guard let data = Data(base64Encoded: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }
}

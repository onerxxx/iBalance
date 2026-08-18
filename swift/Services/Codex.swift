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
        let idToken = tokens["id_token"] as? String ?? ""
        let refreshToken = tokens["refresh_token"] as? String ?? ""
        let idPayload = jwtPayload(idToken) ?? [:]
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
        return .success(CodexAccount(uid: uid, token: token, email: email,
                                     refreshToken: refreshToken, idToken: idToken))
    }

    static func currentUid() -> String? {
        guard case .success(let account) = importCurrentAccount() else { return nil }
        return account.uid
    }

    // MARK: 账号切换（写 auth.json + 重启 Codex）

    /// 切换 Codex 当前登录账号：退出 Codex → 原子更新 ~/.codex/auth.json → 重启 Codex。
    /// 旧版配置中的账号可能只有 access token，此时仍写入 access_token/account_id，
    /// 但不会复用当前账号的 refresh/id token，避免续期时串回原账号。
    static func switchAccount(_ account: CodexAccount) -> Bool {
        let t0 = Date()
        Logger.log(.switchAccount, "[iBalance] Codex switchAccount start: uid=\(account.uid)")
        ProcessUtil.killMainProcesses(bundleId: "com.openai.codex", label: "Codex")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = json["tokens"] as? [String: Any] else {
            Logger.log(.switchAccount, "[iBalance] Codex auth.json read failed, restarting original account")
            restartCodex()
            return false
        }

        tokens["access_token"] = account.token
        tokens["account_id"] = account.uid
        if account.idToken.isEmpty {
            tokens.removeValue(forKey: "id_token")
        } else {
            tokens["id_token"] = account.idToken
        }
        if account.refreshToken.isEmpty {
            tokens.removeValue(forKey: "refresh_token")
        } else {
            tokens["refresh_token"] = account.refreshToken
        }
        json["tokens"] = tokens

        guard JSONSerialization.isValidJSONObject(json),
              let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
            Logger.log(.switchAccount, "[iBalance] Codex auth.json serialization failed, restarting original account")
            restartCodex()
            return false
        }

        do {
            let attrs = try? FileManager.default.attributesOfItem(atPath: authPath)
            try out.write(to: URL(fileURLWithPath: authPath), options: [.atomic])
            if let permissions = attrs?[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: authPath)
            }
            restartCodex()
            Logger.log(.switchAccount, "[iBalance] Codex switchAccount done, total \(ProcessUtil.ms(since: t0))ms")
            return true
        } catch {
            Logger.log(.switchAccount, "[iBalance] Codex auth.json write failed: \(error.localizedDescription)")
            restartCodex()
            return false
        }
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

    /// 重启 Codex（-n 确保退出旧进程后创建新实例）。
    private static func restartCodex() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", "-a", "Codex"]
        do { try task.run() } catch {
            Logger.log(.switchAccount, "[iBalance] restart Codex failed: \(error.localizedDescription)")
        }
    }
}

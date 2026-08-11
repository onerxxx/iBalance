// WorkBuddy.swift — CodeBuddy 积分 + 多号签到 + OAuth 采集 + token 自动刷新
import AppKit
import Foundation

// MARK: - OAuth 采集结果

enum OAuthResult {
    case success(WBAccount)
    case failure(String)
}

enum WorkBuddyService {

    // MARK: 当前登录账号（auth 文件）

    /// 读取 WorkBuddy Desktop 当前登录账号：~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
    /// 该文件在账号切换或 token 刷新时由桌面端自动更新。
    static func authInfo() -> (token: String, domain: String, uid: String, nickname: String)? {
        let path = NSHomeDirectory() + "/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let token = file.auth?.accessToken, !token.isEmpty,
              let domain = file.auth?.domain, !domain.isEmpty,
              let uid = file.account?.uid, !uid.isEmpty else { return nil }
        let nickname = file.account?.nickname ?? uid
        return (token, domain, uid, nickname)
    }

    private struct AuthFile: Decodable {
        struct Auth: Decodable { let accessToken: String?; let domain: String? }
        struct Account: Decodable { let uid: String?; let nickname: String? }
        let auth: Auth?
        let account: Account?
    }

    // MARK: 积分汇总

    /// 直接调用 CodeBuddy API 获取当前账号的剩余额度。
    /// POST /v2/billing/meter/get-user-resource，Bearer token + X-User-Id。
    /// 只累加 Status==0（有效）账户的 CycleCapacityRemainPrecise。
    static func fetchSummary() async -> Double? {
        guard let auth = authInfo() else { return nil }
        guard let url = URL(string: "https://\(auth.domain)/v2/billing/meter/get-user-resource") else { return nil }
        let headers = [
            "Authorization": "Bearer \(auth.token)",
            "Content-Type": "application/json",
            "X-User-Id": auth.uid,
        ]
        let (data, status) = await HTTP.requestWithRetry(
            url: url, method: "POST", headers: headers, body: Data("{}".utf8), timeout: 10
        )
        guard status == 200, let data,
              let resp = try? JSONDecoder().decode(ResourceResponse.self, from: data) else { return nil }

        var total: Double = 0
        for acc in resp.data?.Response?.Data?.Accounts ?? [] {
            guard acc.Status == 0 else { continue }
            if let precise = acc.CycleCapacityRemainPrecise, let v = Double(precise) {
                total += v
            } else if let remain = acc.CycleCapacityRemain {
                total += remain.value
            }
        }
        return total
    }

    private struct ResourceResponse: Decodable {
        struct Layer1: Decodable {
            struct Layer2: Decodable {
                struct Layer3: Decodable {
                    struct Account: Decodable {
                        let Status: Int?
                        let CycleCapacityRemainPrecise: String?
                        let CycleCapacityRemain: FlexibleDouble?
                    }
                    let Accounts: [Account]?
                }
                let Data: Layer3?
            }
            let Response: Layer2?
        }
        let data: Layer1?
    }

    // MARK: 签到状态 / 领取

    /// 查询签到状态。优先 checkin-activity-status，失败回退 checkin-status。
    /// 返回 (todayCheckedIn, available)；失败返回 nil。
    static func fetchCheckinStatus(token: String, uid: String, domain: String) async -> (todayCheckedIn: Bool, available: Bool)? {
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "X-User-Id": uid,
        ]
        for path in ["/v2/billing/meter/checkin-activity-status", "/v2/billing/meter/checkin-status"] {
            guard let url = URL(string: "https://\(domain)\(path)") else { continue }
            let (data, status) = await HTTP.request(url: url, method: "GET", headers: headers, timeout: 10)
            guard status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let bizCode: Int
            if let d = json["data"] as? [String: Any] {
                bizCode = (d["Code"] as? Int) ?? (d["code"] as? Int) ?? 0
            } else {
                bizCode = (json["code"] as? Int) ?? 0
            }
            guard bizCode == 0 else { continue }
            let inner = nestedDict(json, keys: ["data", "Response", "Data"]) ?? nestedDict(json, keys: ["data"]) ?? json
            let todayCheckedIn = (inner["today_checked_in"] as? Bool) ?? false
            let available = (inner["available"] as? Bool) ?? !todayCheckedIn
            return (todayCheckedIn, available)
        }
        return nil
    }

    /// 执行签到。返回 (success, creditDesc, msg)。
    static func claimCheckin(token: String, uid: String, domain: String) async -> (success: Bool, creditDesc: String, msg: String) {
        guard let url = URL(string: "https://\(domain)/v2/billing/meter/daily-checkin") else {
            return (false, "", "URL 非法")
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "X-User-Id": uid,
        ]
        let (data, status) = await HTTP.request(url: url, method: "POST", headers: headers, body: Data("{}".utf8), timeout: 10)
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "", "HTTP \(status)")
        }
        let bizCode = (json["code"] as? Int) ?? (nestedDict(json, keys: ["data"])?["Code"] as? Int) ?? -1
        guard bizCode == 0 else {
            let errMsg = (json["message"] as? String) ?? (json["msg"] as? String) ?? "code \(bizCode)"
            return (false, "", errMsg)
        }
        let inner = nestedDict(json, keys: ["data", "Response", "Data"]) ?? nestedDict(json, keys: ["data"]) ?? json
        let reward = inner["reward"] as? [String: Any]
        let credit = reward?["credit"] ?? inner["credit"] ?? inner["today_credit"]
        let creditDesc = (credit != nil) ? "\(credit!)" : ""
        return (true, creditDesc, "")
    }

    // MARK: token 自动刷新

    /// 若 access_token 距过期 < 1 小时，用 refreshToken 续期；否则原样返回。
    /// 返回的 account 可能已被更新（新 token/refreshToken/expiresAt），调用方负责持久化。
    static func refreshTokenIfNeeded(account: WBAccount) async -> WBAccount {
        // 无 refreshToken（如当前登录账号由 workbuddy-desktop.info 自动刷新）→ 直接用原 token
        guard !account.refreshToken.isEmpty else { return account }
        let nowTs = Date().timeIntervalSince1970
        if account.expiresAt == 0 || account.expiresAt - nowTs > 3600 {
            return account
        }
        guard let url = URL(string: "https://\(account.domain)/v2/plugin/auth/token/refresh") else {
            return account
        }
        let headers = [
            "Authorization": "Bearer \(account.token)",
            "X-Refresh-Token": account.refreshToken,
            "Content-Type": "application/json",
        ]
        let (data, status) = await HTTP.request(url: url, method: "POST", headers: headers, body: Data("{}".utf8), timeout: 15)
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return account
        }
        let code = (json["code"] as? Int) ?? -1
        guard code == 0 || code == 200, let d = json["data"] as? [String: Any] else { return account }
        let newToken = (d["accessToken"] as? String) ?? (d["access_token"] as? String) ?? ""
        guard !newToken.isEmpty else { return account }
        var updated = account
        updated.token = newToken
        if let newRefresh = (d["refreshToken"] as? String) ?? (d["refresh_token"] as? String), !newRefresh.isEmpty {
            updated.refreshToken = newRefresh
        }
        if let ea = d["expiresAt"] as? Double { updated.expiresAt = ea }
        else if let ea = d["expires_at"] as? Double { updated.expiresAt = ea }
        else if let ea = d["expiresAt"] as? Int { updated.expiresAt = TimeInterval(ea) }
        else if let ea = d["expires_at"] as? Int { updated.expiresAt = TimeInterval(ea) }
        else {
            let expIn: Double = (d["expiresIn"] as? Double) ?? Double((d["expiresIn"] as? Int) ?? 0)
            if expIn > 0 { updated.expiresAt = nowTs + expIn }
        }
        return updated
    }

    // MARK: OAuth 账号采集（仿 Cockpit Tools）

    /// start_login → 打开浏览器 → 轮询 auth/token → fetch_account_info。
    /// isCancelled 闭包由调用方提供，轮询过程中实时检查是否被取消。
    static func collectAccount(isCancelled: @escaping @MainActor () -> Bool) async -> OAuthResult {
        let endpoint = "https://www.codebuddy.cn"
        let prefix = "/v2/plugin"

        // 1. 启动登录：POST /auth/state?platform=ide
        guard let startUrl = URL(string: "\(endpoint)\(prefix)/auth/state?platform=ide") else {
            return .failure("构造 auth/state URL 失败")
        }
        let (startData, startStatus) = await HTTP.request(
            url: startUrl, method: "POST",
            headers: ["Content-Type": "application/json"], body: Data("{}".utf8), timeout: 15
        )
        guard startStatus == 200, let startData,
              let startJson = try? JSONSerialization.jsonObject(with: startData) as? [String: Any],
              let data = startJson["data"] as? [String: Any],
              let state = data["state"] as? String else {
            return .failure("启动登录失败（HTTP \(startStatus)）")
        }
        let authUrlStr = (data["authUrl"] as? String)
            ?? (data["auth_url"] as? String)
            ?? (data["url"] as? String)
            ?? ""
        let verificationUri = authUrlStr.isEmpty
            ? "\(endpoint)/login?state=\(state)"
            : authUrlStr

        // 2. 打开浏览器登录（在主线程触发）
        await MainActor.run {
            if let url = URL(string: verificationUri) {
                NSWorkspace.shared.open(url)
            }
        }

        // 3. 轮询 /auth/token?state=（每 1.5s，超时 600s）
        guard let tokenUrl = URL(string: "\(endpoint)\(prefix)/auth/token?state=\(state)") else {
            return .failure("构造 auth/token URL 失败")
        }
        let timeoutSec: TimeInterval = 600
        let intervalNs: UInt64 = 1_500_000_000
        let start = Date()
        var accessToken = ""
        var refreshToken = ""
        var expiresAt: TimeInterval = 0
        var domain = "www.codebuddy.cn"
        var authRaw: [String: Any]? = nil
        while Date().timeIntervalSince(start) < timeoutSec {
            if await isCancelled() { return .failure("已取消") }
            let (td, ts) = await HTTP.request(url: tokenUrl, method: "GET",
                headers: ["Accept": "application/json"], timeout: 10)
            if ts == 200, let td = td,
               let tj = try? JSONSerialization.jsonObject(with: td) as? [String: Any] {
                let code = (tj["code"] as? Int) ?? -1
                if code == 0 || code == 200 {
                    if let d = tj["data"] as? [String: Any] {
                        accessToken = (d["accessToken"] as? String) ?? (d["access_token"] as? String) ?? ""
                        refreshToken = (d["refreshToken"] as? String) ?? (d["refresh_token"] as? String) ?? ""
                        if let ea = d["expiresAt"] as? Double { expiresAt = ea }
                        else if let ea = d["expires_at"] as? Double { expiresAt = ea }
                        else if let ea = d["expiresAt"] as? Int { expiresAt = TimeInterval(ea) }
                        else if let ea = d["expires_at"] as? Int { expiresAt = TimeInterval(ea) }
                        if let dm = d["domain"] as? String, !dm.isEmpty { domain = dm }
                        authRaw = d
                    }
                    if !accessToken.isEmpty { break }
                }
            }
            try? await Task.sleep(nanoseconds: intervalNs)
        }
        guard !accessToken.isEmpty else { return .failure("登录超时或未完成") }

        // 4. 获取账号信息：GET /login/account?state=
        guard let accUrl = URL(string: "\(endpoint)\(prefix)/login/account?state=\(state)") else {
            return .failure("构造 login/account URL 失败")
        }
        var accHeaders: [String: String] = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
        ]
        if domain != "www.codebuddy.cn" { accHeaders["X-Domain"] = domain }
        let (accData, accStatus) = await HTTP.request(url: accUrl, method: "GET",
            headers: accHeaders, timeout: 15)
        var uid = ""
        var nickname = ""
        if accStatus == 200, let accData = accData,
           let accJson = try? JSONSerialization.jsonObject(with: accData) as? [String: Any],
           let accInfo = accJson["data"] as? [String: Any] {
            uid = (accInfo["uid"] as? String) ?? ""
            nickname = (accInfo["nickname"] as? String) ?? ""
        }
        if uid.isEmpty {
            return .failure("获取账号信息失败（HTTP \(accStatus)）")
        }

        // 5. expiresAt 可能是相对秒数（expiresIn）而非绝对时间戳，需归一化
        let nowTs = Date().timeIntervalSince1970
        if expiresAt > 0 && expiresAt < nowTs + 10 * 365 * 86400 {
            // 已是绝对时间戳
        } else if let auth = authRaw {
            let expIn: Double = (auth["expiresIn"] as? Double)
                ?? Double((auth["expiresIn"] as? Int) ?? 0)
            if expIn > 0 { expiresAt = nowTs + expIn }
        }

        return .success(WBAccount(
            token: accessToken, uid: uid, domain: domain, nickname: nickname,
            refreshToken: refreshToken, expiresAt: expiresAt
        ))
    }
}

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

    /// auth 文件路径
    private static let authPath = NSHomeDirectory() + "/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"

    /// 内存缓存：mtime 变化才重新读文件并解析，避免 syncPanel 频繁触发时的重复 IO 与 JSON 解析。
    private static var cachedAuth: (token: String, domain: String, uid: String, nickname: String, refreshToken: String, expiresAt: TimeInterval)?
    private static var cachedAuthMtime: Date?
    private static var cachedAuthFetchedAt: Date = .distantPast
    private static let authCacheLock = NSLock()

    /// 读取 WorkBuddy Desktop 当前登录账号：~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
    /// 该文件在账号切换或 token 刷新时由桌面端自动更新。
    /// 返回的 refreshToken/expiresAt 用于把主账号持久化到 config（多号场景）。
    /// mtime 变化才重新解析；mtime 未变化但距上次读取 > 30s 也会重读（兜底，防止 mtime 精度丢失）。
    static func authInfo() -> (token: String, domain: String, uid: String, nickname: String, refreshToken: String, expiresAt: TimeInterval)? {
        authCacheLock.lock()
        defer { authCacheLock.unlock() }

        let fm = FileManager.default
        guard fm.fileExists(atPath: authPath) else {
            cachedAuth = nil
            cachedAuthMtime = nil
            cachedAuthFetchedAt = .distantPast
            return nil
        }
        let attrs = try? fm.attributesOfItem(atPath: authPath)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        let now = Date()
        // mtime 未变且距上次读取 < 30s → 直接用缓存
        if let cached = cachedAuth,
           cachedAuthMtime == mtime,
           now.timeIntervalSince(cachedAuthFetchedAt) < 30 {
            return cached
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let token = file.auth?.accessToken, !token.isEmpty,
              let domain = file.auth?.domain, !domain.isEmpty,
              let uid = file.account?.uid, !uid.isEmpty else {
            cachedAuth = nil
            cachedAuthMtime = mtime
            cachedAuthFetchedAt = now
            return nil
        }
        let nickname = file.account?.nickname ?? uid
        let refreshToken = file.auth?.refreshToken ?? ""
        // auth 文件 expiresAt 单位为毫秒，转成秒级绝对时间戳
        var expiresAt: TimeInterval = 0
        if let ms = file.auth?.expiresAt, ms > 0 {
            expiresAt = TimeInterval(ms) / 1000.0
        } else if let expIn = file.auth?.expiresIn, expIn > 0 {
            expiresAt = now.timeIntervalSince1970 + TimeInterval(expIn)
        }
        let result = (token, domain, uid, nickname, refreshToken, expiresAt)
        cachedAuth = result
        cachedAuthMtime = mtime
        cachedAuthFetchedAt = now
        return result
    }

    private struct AuthFile: Decodable {
        struct Auth: Decodable {
            let accessToken: String?
            let domain: String?
            let refreshToken: String?
            let expiresAt: Int64?      // 毫秒
            let expiresIn: Int64?      // 秒（fallback）
        }
        struct Account: Decodable { let uid: String?; let nickname: String? }
        let auth: Auth?
        let account: Account?
    }

    // MARK: 账号切换（写 auth 文件 + 重启 WorkBuddy Desktop）

    /// 将指定账号的凭据写入 workbuddy-desktop.info，然后杀掉并重启 WorkBuddy Desktop。
    /// 仿 Cockpit Tools 的切号流程：杀进程 → 写认证 → 重启。
    /// 返回 false = 写入失败已回滚（auth 文件未被改动，重启恢复原账号，应用不会停留在「被杀」状态）。
    static func switchAccount(_ account: WBAccount) -> Bool {
        let t0 = Date()
        Logger.log(.switchAccount, "[iBalance] switchAccount start: uid=\(account.uid) nickname=\(account.nickname)")
        // 1. 杀掉 WorkBuddy Desktop 主进程（按 bundle id 精确定位，仿 Cockpit 只杀主进程）
        ProcessUtil.killMainProcesses(bundleId: "com.workbuddy.workbuddy", label: "WorkBuddy")
        // 2. 写入 auth 文件
        guard writeAuthFile(account) else {
            Logger.log(.switchAccount, "[iBalance] writeAuthFile FAILED, rollback: restart with original account")
            restartWorkBuddy()
            return false
        }
        // 3. 重启 WorkBuddy Desktop
        restartWorkBuddy()
        Logger.log(.switchAccount, "[iBalance] switchAccount done, total \(ProcessUtil.ms(since: t0))ms")
        return true
    }

    /// 将账号凭据写入 workbuddy-desktop.info（原子写入）
    /// 仿 Cockpit Tools 的 build_default_client_auth_session 结构
    private static func writeAuthFile(_ account: WBAccount) -> Bool {
        let now = Date().timeIntervalSince1970
        let nowMs = Int64(now * 1000)
        let expiresAtMs = account.expiresAt > 0 ? Int64(account.expiresAt * 1000) : nowMs + 5184_000_000
        let refreshExpiresAtMs = expiresAtMs + 2592_000_000 // refresh 比 access 多 30 天

        // 构建 account 对象
        let accountObj: [String: Any] = [
            "uid": account.uid,
            "nickname": account.nickname,
            "type": "personal",
            "lastLogin": true,
            "isCreator": false,
            "isAdmin": false,
            "pluginEnabled": true,
            "accountType": "",
            "idp": "",
            "areaInfoComplete": false,
            "isFirstLogin": false,
            "isCurrentOneIdEnterprise": false,
            "isCurrentOneIdPersonal": false,
            "oneidAccountId": "",
            "deployStatus": ["statusCode": 0, "statusMsg": "", "detailMsg": ""],
            "sso": ["domain": "", "domainModifiedTimes": 0],
        ]

        // 构建 auth 对象
        let authObj: [String: Any] = [
            "accessToken": account.token,
            "refreshToken": account.refreshToken,
            "tokenType": "Bearer",
            "domain": account.domain,
            "expiresAt": expiresAtMs,
            "expiresIn": 5184_000,            // 60 天（秒）
            "refreshExpiresAt": refreshExpiresAtMs,
            "refreshExpiresIn": 7776_000,     // 90 天（秒）
            "lastRefreshTime": nowMs,
            "scope": "openid profile offline_access email",
            "notBeforePolicy": 1724292326,
            "sessionState": "",
        ]

        // 完整 auth 文件结构
        let session: [String: Any] = [
            "account": accountObj,
            "auth": authObj,
            "accounts": [accountObj],
            "allAccounts": [accountObj],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: session, options: [.prettyPrinted]) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: authPath), options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// 重启 WorkBuddy Desktop
    /// 仿 Cockpit Tools：open -n -a WorkBuddy --args --new-window
    /// -n = 强制新实例，--new-window = 新窗口
    private static func restartWorkBuddy() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", "-a", "WorkBuddy", "--args", "--new-window"]
        do { try task.run() } catch {
            Logger.log(.switchAccount, "[iBalance] restart WorkBuddy failed: \(error.localizedDescription)")
        }
    }

    // MARK: 积分汇总

    /// 直接调用 CodeBuddy API 获取当前账号的剩余额度与总额度。
    /// POST /v2/billing/meter/get-user-resource，Bearer token + X-User-Id。
    /// 只累加 Status==0（有效）账户的 CycleCapacityRemainPrecise / CycleCapacitySizePrecise。
    static func fetchSummary() async -> (remain: Double, total: Double)? {
        guard let auth = authInfo() else { return nil }
        return await fetchSummaryForAccount(token: auth.token, uid: auth.uid, domain: auth.domain)
    }

    /// 查询指定 WorkBuddy 账号的剩余额度与总额度（多号场景）。
    static func fetchSummaryForAccount(token: String, uid: String, domain: String) async -> (remain: Double, total: Double)? {
        guard let url = URL(string: "https://\(domain)/v2/billing/meter/get-user-resource") else { return nil }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "X-User-Id": uid,
        ]
        let (data, status) = await HTTP.requestWithRetry(
            url: url, method: "POST", headers: headers, body: Data("{}".utf8), timeout: 10
        )
        guard status == 200, let data,
              let resp = try? JSONDecoder().decode(ResourceResponse.self, from: data) else { return nil }

        var remain: Double = 0
        var total: Double = 0
        for acc in resp.data?.Response?.Data?.Accounts ?? [] {
            guard acc.Status == 0 else { continue }
            if let precise = acc.CycleCapacityRemainPrecise, let v = Double(precise) {
                remain += v
            } else if let r = acc.CycleCapacityRemain {
                remain += r.value
            }
            if let sizePrecise = acc.CycleCapacitySizePrecise, let v = Double(sizePrecise) {
                total += v
            } else if let size = acc.CycleCapacitySize {
                total += size
            }
        }
        return (remain, total)
    }

    private struct ResourceResponse: Decodable {
        struct Layer1: Decodable {
            struct Layer2: Decodable {
                struct Layer3: Decodable {
                    struct Account: Decodable {
                        let Status: Int?
                        let CycleCapacityRemainPrecise: String?
                        let CycleCapacityRemain: FlexibleDouble?
                        let CycleCapacitySizePrecise: String?
                        let CycleCapacitySize: Double?
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

    /// 查询签到状态：直接调用 daily-checkin（幂等，已签时返回非 0 bizCode + 状态信息）。
    /// 返回 (todayCheckedIn, available, continuousDays, reward)；失败返回 nil。
    static func fetchCheckinStatus(token: String, uid: String, domain: String) async -> (todayCheckedIn: Bool, available: Bool, continuousDays: Int, reward: Int)? {
        guard let url = URL(string: "https://\(domain)/v2/billing/meter/daily-checkin") else { return nil }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "X-User-Id": uid,
        ]
        let (data, status) = await HTTP.request(url: url, method: "POST", headers: headers, body: Data("{}".utf8), timeout: 10)
        // 接受 200（签到成功）和 400（已签到 code=10001）两种情况
        guard (status == 200 || status == 400), let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let bizCode = (json["code"] as? Int) ?? (nestedDict(json, keys: ["data"])?["Code"] as? Int) ?? -1
        let inner = nestedDict(json, keys: ["data", "Response", "Data"]) ?? nestedDict(json, keys: ["data"]) ?? json
        // bizCode == 0 → 刚刚签到成功；bizCode == 10001 → 今天已签到
        let todayCheckedIn = bizCode == 0 || bizCode == 10001 || (inner["today_checked_in"] as? Bool ?? false)
        let available = bizCode == 0
        // 连续天数：尝试多种字段名
        let continuousDays = (inner["continuous_days"] as? Int)
            ?? (inner["streak"] as? Int)
            ?? (inner["consecutive_days"] as? Int)
            ?? (inner["days"] as? Int)
            ?? (inner["checkin_days"] as? Int)
            ?? 0
        // reward 可能是 dict { credit: 100 } 也可能是数字
        var reward = 0
        if let r = inner["reward"] as? [String: Any] {
            reward = (r["credit"] as? Int) ?? (r["credits"] as? Int) ?? (r["today_credit"] as? Int) ?? 0
        }
        if reward == 0 {
            reward = (inner["credit"] as? Int)
                ?? (inner["today_credit"] as? Int)
                ?? (inner["credits"] as? Int)
                ?? (inner["reward_credit"] as? Int)
                ?? 0
        }
        // 字符串形式的数字
        if reward == 0 {
            for k in ["credit", "today_credit", "credits", "reward_credit"] {
                if let s = inner[k] as? String, let v = Int(s) { reward = v; break }
            }
        }
        return (todayCheckedIn, available, continuousDays, reward)
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

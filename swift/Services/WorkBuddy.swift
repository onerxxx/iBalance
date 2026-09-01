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
    /// 仿 Cockpit Tools 的切号流程：杀进程 → 写认证 → 同步共享 → 重启。
    /// 返回 false = 写入失败已回滚（auth 文件未被改动，重启恢复原账号，应用不会停留在「被杀」状态）。
    static func switchAccount(_ account: WBAccount) -> Bool {
        let t0 = Date()
        Logger.log(.switchAccount, "[iBalance] switchAccount start: uid=\(account.uid) nickname=\(account.nickname)")
        // 1. 杀掉 WorkBuddy Desktop 主进程（按 bundle id 精确定位，仿 Cockpit 只杀主进程）
        ProcessUtil.killMainProcesses(bundleId: "com.tencent.workbuddy.mac", label: "WorkBuddy")
        // 2. 写入 auth 文件
        guard writeAuthFile(account) else {
            Logger.log(.switchAccount, "[iBalance] writeAuthFile FAILED, rollback: restart with original account")
            restartWorkBuddy()
            return false
        }
        // 3. 同步共享：此时 WorkBuddy 已死、auth 已指向新账号，时机天然安全。
        //    把全部会话归属转移到新账号 + 记忆广播（详见 WbShare.swift），静默执行，只记日志。
        let share = WbShareSync.perform(targetUid: account.uid, nicknameByUid: [:])
        Logger.log(.switchAccount, "[wb-share] on-switch: uid=\(account.uid) moved=\(share.movedSessions) memorySynced=\(share.memorySynced) err=\(share.error ?? "none")")
        // 4. 重启 WorkBuddy Desktop
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

    /// WorkBuddy (Electron) 的 userData 目录，单实例锁文件所在处
    private static let wbUserDataDir = NSHomeDirectory() + "/.workbuddy/app"

    /// WorkBuddy 可执行文件完整路径（pgrep 匹配用，清理孤儿 Electron 进程）
    private static let wbExecutablePath = "/Applications/WorkBuddy.app/Contents/MacOS/Electron"

    /// 清理 WorkBuddy (Electron) 单实例锁残留：SIGKILL 强杀主进程后
    /// SingletonLock/SingletonCookie/SingletonSocket 不会自动清理，且进程在僵尸期
    /// kill(pid,0) 仍判存活 → 紧随其后的 open 被单实例锁误判「已有实例」，
    /// 新实例静默退出（App 不启动，无任何业务日志）。只删锁文件，不碰业务数据。
    static func clearElectronSingletonLocks() {
        let fm = FileManager.default
        for name in ["SingletonLock", "SingletonCookie", "SingletonSocket"] {
            let p = (wbUserDataDir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: p) {
                try? fm.removeItem(atPath: p)
                Logger.log(.switchAccount, "[iBalance] cleared stale singleton lock: \(name)")
            }
        }
    }

    /// 重启 WorkBuddy Desktop（切号与同步共享复用）
    /// 注意：不能带 `--args --new-window`——2026-08-30 后的 WorkBuddy 新版不认识该参数，
    /// 收到后进程启动即退出。也不能带 `-n`——旧进程死后残留单实例锁 + 僵尸期误判
    /// 「已有实例」，新实例会静默退出（2026-09-01 实测 App 起不来的根因，见
    /// clearElectronSingletonLocks）。
    /// 流程：清锁 → 清残留 Electron 进程（孤儿 prewarm/daemon 会让 LaunchServices 误判
    /// 「仍在运行」，open 被路由到死实例，2026-09-01 二次实测）→ 按 bundle id open →
    /// 5s 内验证主进程出现（实测冷启动 open→AppStartup 基线 3.5-4.5s，2s 窗口会误判
    /// 「没起来」而重复 open 造成叠加延迟）→ 未出现则清锁 + 清残留 + 重试一次。
    static func restartWorkBuddy() {
        clearElectronSingletonLocks()
        ProcessUtil.cleanupRemainingElectronProcesses(executablePath: wbExecutablePath, label: "WorkBuddy")
        openWorkBuddy()
        // 验证启动：5s 内主进程应出现（锁误判/LS 路由失败时 open 成功但进程不出现，此步能发现）
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !ProcessUtil.mainPids(bundleId: "com.tencent.workbuddy.mac").isEmpty { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        Logger.log(.switchAccount, "[iBalance] WorkBuddy not running after open, cleaning and retrying")
        clearElectronSingletonLocks()
        ProcessUtil.cleanupRemainingElectronProcesses(executablePath: wbExecutablePath, label: "WorkBuddy")
        openWorkBuddy()
    }

    /// 启动 WorkBuddy 前清理污染 Electron/LaunchServices 的环境变量。
    /// iBalance 由 WorkBuddy 拉起时会继承其 CLI 模式环境：ELECTRON_RUN_AS_NODE=1、
    /// NODE_OPTIONS=--require …shim、__CFBundleIdentifier=com.local.ibalance、
    /// XPC_SERVICE_NAME、全套 WORKBUDDY_*。这些变量若泄漏给 `open` 启动的新实例：
    /// ① ELECTRON_RUN_AS_NODE=1 → WorkBuddy 以 Node 模式启动，无窗口、无 AppStartup
    ///    打点、0.5s 内 exit(0) 秒退（2026-09-01 实测「界面没开到就闪退」根因，
    ///    与系统日志 launchd 终止退出码 0 吻合）；
    /// ② __CFBundleIdentifier / XPC_SERVICE_NAME 污染 → LaunchServices 实例归属判断错乱；
    /// ③ WORKBUDDY_USER_DATA_DIR / WORKBUDDY_STARTUP_PID 等强制旧实例的路径/归属。
    /// 参照 cockpit-tools sanitize_macos_gui_launch_env 的做法。
    private static func sanitizedLaunchEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let toxicKeys: Set<String> = [
            "NODE_OPTIONS", "NODE_PATH", "NODE_ENV",
            "ELECTRON_RUN_AS_NODE", "ELECTRON_NO_ASAR",
            "ELECTRON_FORCE_WINDOW_MENU_BAR", "ELECTRON_NO_ATTACH_CONSOLE",
            "__CFBundleIdentifier", "XPC_SERVICE_NAME",
            "npm_config_prefix", "npm_config_devdir",
        ]
        for key in toxicKeys { env.removeValue(forKey: key) }
        // WorkBuddy 注入的运行时变量（userData/config/startup pid 等）一律清除，
        // 让新实例按默认逻辑重新解析路径与实例归属
        for key in env.keys where key.hasPrefix("WORKBUDDY_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    private static func openWorkBuddy() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-b", "com.tencent.workbuddy.mac"]
        task.environment = sanitizedLaunchEnvironment()
        do { try task.run() } catch {
            Logger.log(.switchAccount, "[iBalance] open WorkBuddy failed: \(error.localizedDescription)")
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

    // MARK: 用户资源（裂变包重置日，口径参照 cockpit-tools）

    /// 拉取用户资源包列表：ProductCode p_tcaca、Status[0,3]（在期/已用尽）、
    /// PackageEndTimeRange 从现在到 +101 年取全量。失败返回 nil。
    static func fetchUserResources(token: String, uid: String, domain: String) async -> [[String: Any]]? {
        guard let url = URL(string: "https://\(domain)/v2/billing/meter/get-user-resource") else { return nil }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "X-User-Id": uid,
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = Date()
        let body: [String: Any] = [
            "PageNumber": 1,
            "PageSize": 100,
            "ProductCode": "p_tcaca",
            "Status": [0, 3],
            "PackageEndTimeRangeBegin": df.string(from: now),
            "PackageEndTimeRangeEnd": df.string(from: now.addingTimeInterval(3600.0 * 24 * 365 * 101)),
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let (data, status) = await HTTP.request(url: url, method: "POST", headers: headers, body: payload, timeout: 10)
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let inner = nestedDict(json, keys: ["data", "Response", "Data"]) ?? [:]
        return inner["Accounts"] as? [[String: Any]]
    }

    /// 裂变包重置日：PackageName 含「裂变」优先，兜底 gift（code_006）/ activity
    /// （code_007 活动赠送包）。日期口径与官方一致 = 到期时间：
    /// DeductionEndTime（毫秒时间戳）→ ExpiredTime → CycleEndTime 兜底，
    /// 字符串兼容「2026/09/23 00:02:52」「2026-09-23T00:02:52」两种分隔。
    /// 多个命中取最早的。
    static func fetchFissionReset(token: String, uid: String, domain: String) async -> Date? {
        guard let resources = await fetchUserResources(token: token, uid: uid, domain: domain) else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func parseDate(_ r: [String: Any]) -> Date? {
            // 实测（2026-08-23）：官方「到期时间」展示的是在期包的 CycleEndTime；
            // DeductionEndTime 是滚动扣费窗口（≈当下），不能用作重置日
            for key in ["CycleEndTime", "ExpiredTime"] {
                guard let s = r[key] as? String, !s.isEmpty else { continue }
                let normalized = s.replacingOccurrences(of: "T", with: " ")
                    .replacingOccurrences(of: "/", with: "-")
                if let d = df.date(from: normalized) { return d }
            }
            if let ms = r["DeductionEndTime"] as? Double, ms > 0 {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            return nil
        }
        // 名称含「裂变」优先（实测包名「CodeBuddy个人版国内运营裂变包」，同账号可有
        // 多条：已用尽 Status=3 是历史记录，在期 Status=0 才是官方展示口径），
        // 无名称命中退 gift/activity code。两级都只取未来日期，在期包优先。
        let now = Date()
        func pick(_ predicate: ([String: Any]) -> Bool) -> Date? {
            let matched = resources.filter(predicate)
            for wantActive in [true, false] {
                var best: Date?
                for r in matched {
                    let active = (r["Status"] as? Int) == 0
                    guard active == wantActive, let d = parseDate(r), d > now,
                          best == nil || d < best! else { continue }
                    best = d
                }
                if let best { return best }
            }
            return nil
        }
        return pick { (($0["PackageName"] as? String) ?? "").contains("裂变") }
            ?? pick { let c = ($0["PackageCode"] as? String) ?? ""
                return c == "TCACA_code_006_DbXS0lrypC" || c == "TCACA_code_007_nzdH5h4Nl0" }
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

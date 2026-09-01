// Zcode.swift — ZCode（智谱 Coding Plan）余额查询 + 当前账号 JSON 导入
import AppKit
import CryptoKit
import Foundation

// MARK: - JSON 导入结果

enum ZcodeImportResult {
    case success(ZCodeAccount)
    case failure(String)
}

enum ZcodeService {
    /// ZCode Desktop 配置文件（明文存 start-plan JWT / coding-plan API Key，登录后自动更新）
    private static let configPath = NSHomeDirectory() + "/.zcode/v2/config.json"
    /// 余额查询端点（zai 渠道 JWT 走此网关；Anthropic 兼容网关同域）。
    /// 服务端要求客户端身份：URL 带 app_version（对齐客户端 buildZaiStartPlanBalanceUrl）、
    /// 头带 X-Device-Mid（ZCode 遥测设备标识），缺任一返回 3001 parameter error。
    private static let balanceURL = "https://zcode.z.ai/api/v1/zcode-plan/billing/balance"
    /// ZCode 遥测状态文件（X-Device-Mid 设备标识来源）
    private static let telemetryPath = NSHomeDirectory() + "/.zcode/v2/telemetry-state.json"
    /// 设备标识（随 ZCode 安装生成后不变，进程内读一次）
    private static let deviceMid: String? = {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: telemetryPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["deviceMid"] as? String
    }()
    /// 本机已安装 ZCode 客户端版本（app_version 取真实客户端口径，随客户端更新）
    private static let zcodeAppVersion: String? =
        Bundle(url: URL(fileURLWithPath: "/Applications/ZCode.app"))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    /// bigmodel 渠道付费 Coding Plan（Lite 等档位）的 API Key 用量端点；
    /// 返回 data.level（套餐档）+ data.limits[]（usage=总额度 currentValue=已用 remaining=剩余，
    /// nextResetTime=窗口重置毫秒戳；同一套餐有 5 小时窗口与月度窗口两条，额度数值相同）
    private static let bigModelQuotaURL = "https://open.bigmodel.cn/api/monitor/usage/quota/limit"

    // MARK: JSON 导入（当前登录账号）

    /// Coding Plan 凭据键有套餐档位与登录渠道之分：
    /// coding-plan = 付费套餐（zai 为 JWT；bigmodel 为开放平台 API Key，形如 "id.secret"）
    /// start-plan = 免费体验档（均为 JWT）
    /// 导入优先取付费档（apiKey 非空优先），zai 渠道优先于 bigmodel
    private static let providerKeys = [
        "builtin:zai-coding-plan", "builtin:bigmodel-coding-plan",
        "builtin:zai-start-plan", "builtin:bigmodel-start-plan",
    ]

    /// 从 ~/.zcode/v2/config.json 读取当前登录的 Coding Plan 账号。
    /// 凭据为 provider 键下 options.apiKey：付费档 API Key（bigmodel）或 JWT（其余），
    /// JWT 解 payload（不验签）取 user_id 作为账号标识；API Key 无法自解析 uid，
    /// 取同文件 start-plan JWT 的 user_id（同一 bigmodel 账号两个键并存），
    /// 均无 JWT 时退回 credentials.json 当前登录账号的 uid。
    static func importCurrentAccount() -> ZcodeImportResult {
        guard FileManager.default.fileExists(atPath: configPath) else {
            return .failure("未找到 ~/.zcode/v2/config.json，请先安装并登录 ZCode")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = json["provider"] as? [String: Any] else {
            return .failure("ZCode 配置中未找到 Coding Plan 登录信息，请先在 ZCode 中登录")
        }
        let keyPairs: [(String, String)] = providerKeys.compactMap { key in
            guard let opts = (provider[key] as? [String: Any])?["options"] as? [String: Any],
                  let ak = opts["apiKey"] as? String, !ak.isEmpty else { return nil }
            return (key, ak)
        }
        guard let (_, apiKey) = keyPairs.first else {
            return .failure("ZCode 配置中未找到 Coding Plan 登录信息，请先在 ZCode 中登录")
        }
        // JWT 自解析 uid；API Key（bigmodel 付费档）取同文件 start-plan JWT 的 user_id
        //（同一 bigmodel 账号两个键并存），均无 JWT 时退回 credentials.json 当前登录账号 uid
        let uid = jwtUserId(from: apiKey)
            ?? providerKeys.filter { $0.hasSuffix("start-plan") }
                .compactMap { key -> String? in
                    guard let opts = (provider[key] as? [String: Any])?["options"] as? [String: Any],
                          let ak = opts["apiKey"] as? String, !ak.isEmpty else { return nil }
                    return jwtUserId(from: ak)
                }.first
            ?? currentUserInfo()?.uid
        guard let uid, !uid.isEmpty else {
            return .failure("无法解析 ZCode 登录令牌")
        }
        // 自动带出昵称（credentials.json user_info；uid 不匹配或解密失败则留空，由调用方兜底）
        let nickname = autoNickname(forUid: uid) ?? ""
        return .success(ZCodeAccount(uid: uid, token: apiKey, nickname: nickname))
    }

    /// 读取当前登录账号的 uid（config.json 中 token 对应的 user_id），用于标记「当前账号」卡片
    static func currentUid() -> String? {
        guard case .success(let account) = importCurrentAccount() else { return nil }
        return account.uid
    }

    /// 当前登录号的体验套餐（start-plan）JWT：config.json start-plan 键的 apiKey（均为 JWT）。
    /// 体验套餐余额（billing/balance）只认 JWT，付费档 API Key 查询为 401；仅当前登录号持有。
    static func currentStartPlanJWT() -> (uid: String, token: String)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = json["provider"] as? [String: Any] else { return nil }
        for key in providerKeys where key.hasSuffix("start-plan") {
            guard let opts = (provider[key] as? [String: Any])?["options"] as? [String: Any],
                  let ak = opts["apiKey"] as? String, isJWT(ak),
                  let uid = jwtUserId(from: ak) else { continue }
            return (uid, ak)
        }
        return nil
    }
    /// 解 JWT payload 的 user_id（JWT 为 HS256 签名，客户端不验签，仅取 payload）
    private static func jwtUserId(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let data = b64urlDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = payload["user_id"] as? String, !uid.isEmpty else { return nil }
        return uid
    }

    // MARK: credentials.json 解密（自动昵称）

    /// ZCode 本地凭据文件（enc:v1: 加密的 OAuth 信息，含 user_info 昵称）
    private static let credentialsPath = NSHomeDirectory() + "/.zcode/v2/credentials.json"

    /// 解密 credentials.json 的 enc:v1: 字段。
    /// 格式为 AES-256-GCM：`enc:v1:<nonce>.<tag>.<ciphertext>`（URL-safe base64 三段），
    /// 密钥不用 Keychain，由本机环境派生：SHA256("zcode-credential-fallback:darwin:{home}:{USER}")
    /// （原理与 Cockpit Tools 相同；非 Electron safeStorage）。
    static func decryptCredential(_ enc: String) -> String? {
        let prefix = "enc:v1:"
        guard enc.hasPrefix(prefix) else { return enc }
        let parts = enc.dropFirst(prefix.count).split(separator: ".").map(String.init)
        guard parts.count == 3,
              let nonce = b64urlDecode(parts[0]), nonce.count == 12,
              let tag = b64urlDecode(parts[1]), tag.count == 16,
              let ct = b64urlDecode(parts[2]) else { return nil }
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let secret = "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(user)"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let sealed = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag),
              let plain = try? AES.GCM.open(sealed, using: key, authenticating: Data()) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// URL-safe base64 解码（补 padding 后转标准 base64）
    private static func b64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    /// 加密为 enc:v1 格式（与 decryptCredential 对应，AES-256-GCM 随机 nonce）
    static func encryptCredential(_ plain: String) -> String? {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let secret = "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(user)"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let sealed = try? AES.GCM.seal(Data(plain.utf8), using: key) else { return nil }
        return "enc:v1:" + [Data(sealed.nonce), sealed.tag, sealed.ciphertext]
            .map(b64urlEncode).joined(separator: ".")
    }

    /// URL-safe base64 编码（无 padding）
    private static func b64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: 账号切换（写凭据文件 + 重启 ZCode）

    /// 切换 ZCode 当前登录账号：杀主进程 → 写 credentials.json（登录态权威来源）+
    /// config.json（start-plan apiKey，让「当前账号」判定立即生效）→ 重启 ZCode。
    /// 仿 WorkBuddy 切号流程；写入键集逆向自 ZCode 客户端 restoreCachedSession：
    /// zai 渠道凭 zcodejwttoken + user_info 即恢复 authenticated，无需 access_token。
    /// 返回 false = 写入失败已回滚（凭据文件未被改动，重启恢复原账号）。
    static func switchAccount(_ account: ZCodeAccount) -> Bool {
        let t0 = Date()
        Logger.log(.switchAccount, "[iBalance] zcode switchAccount start: uid=\(account.uid)")
        // 1. 杀 ZCode 主进程（按 bundle id 精确定位，Electron 主进程退出自动回收子进程）
        ProcessUtil.killMainProcesses(bundleId: "dev.zcode.app", label: "ZCode")
        // 2. 写凭据文件（失败也要重启 ZCode：进程已杀，不重启 app 会凭空消失）
        guard writeCredentials(account) else {
            Logger.log(.switchAccount, "[iBalance] zcode writeCredentials FAILED, rollback: restart with original account")
            restartZcode()
            return false
        }
        syncConfigApiKey(account.token)
        // 3. 重启 ZCode
        restartZcode()
        Logger.log(.switchAccount, "[iBalance] zcode switchAccount done, total \(ProcessUtil.ms(since: t0))ms")
        return true
    }

    /// 写入 credentials.json：清两渠道旧 OAuth 键（防旧号串扰），写 active_provider /
    /// zcodejwttoken / oauth:{provider}:user_info（均 enc:v1 加密）。
    /// user_info 是 restoreCachedSession 必需的 cached profile，缺失会退回未登录。
    private static func writeCredentials(_ account: ZCodeAccount) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credentialsPath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
        // 渠道沿用现有 active_provider（解密失败默认 zai——zai 渠道仅凭 JWT 即可恢复会话）
        let provider = json["oauth:active_provider"].flatMap { decryptCredential($0) } ?? "zai"
        for p in ["zai", "bigmodel"] {
            for suffix in ["access_token", "refresh_token", "user_info"] {
                json.removeValue(forKey: "oauth:\(p):\(suffix)")
            }
        }
        // user_info 字段对齐 zai 渠道真实结构（user_id/name/email/avatar，无 id 字段）
        let userInfo: [String: Any] = [
            "user_id": account.uid,
            "name": account.nickname.isEmpty ? account.displayName : account.nickname,
            "email": "unknown@zcode.local",
            "avatar": "https://chat.z.ai/user.png",
        ]
        guard let infoData = try? JSONSerialization.data(withJSONObject: userInfo),
              let infoText = String(data: infoData, encoding: .utf8),
              let encInfo = encryptCredential(infoText),
              let encJwt = encryptCredential(account.token),
              let encProvider = encryptCredential(provider) else { return false }
        json["oauth:active_provider"] = encProvider
        json["zcodejwttoken"] = encJwt
        json["oauth:\(provider):user_info"] = encInfo
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return false }
        do {
            try out.write(to: URL(fileURLWithPath: credentialsPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 同步 config.json 当前凭据键（导入来源键）的 apiKey；
    /// ZCode 启动后也会自行同步，此处先行写入让 currentUid 立即指向新号
    private static func syncConfigApiKey(_ token: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var provider = json["provider"] as? [String: Any] else { return }
        for key in providerKeys {
            guard var plan = provider[key] as? [String: Any],
                  var opts = plan["options"] as? [String: Any],
                  let ak = opts["apiKey"] as? String, !ak.isEmpty else { continue }
            opts["apiKey"] = token
            plan["options"] = opts
            provider[key] = plan
            json["provider"] = provider
            if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                try? out.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            }
            return
        }
    }

    /// 重启 ZCode（仿 WorkBuddy：open -n -a 强制新实例）
    private static func restartZcode() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", "-a", "ZCode"]
        do { try task.run() } catch {
            Logger.log(.switchAccount, "[iBalance] restart ZCode failed: \(error.localizedDescription)")
        }
    }

    /// 从 credentials.json 解密当前登录账号的 (uid, 昵称)。
    /// user_info 为 OAuth 登录时缓存的用户资料（displayName/username/avatar 等）。
    static func currentUserInfo() -> (uid: String, nickname: String)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credentialsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        // active provider 指示 user_info 键名（bigmodel / zai）
        let provider = (json["oauth:active_provider"]).flatMap { decryptCredential($0) } ?? "bigmodel"
        guard let infoText = json["oauth:\(provider):user_info"].flatMap({ decryptCredential($0) }),
              let info = try? JSONSerialization.jsonObject(with: Data(infoText.utf8)) as? [String: Any] else { return nil }
        let uid = (info["user_id"] as? String) ?? (info["id"] as? String)
            ?? (info["customerNumber"] as? String) ?? (info["sub"] as? String) ?? ""
        let nickname = (info["displayName"] as? String) ?? (info["username"] as? String)
            ?? (info["name"] as? String) ?? (info["nickName"] as? String)
            ?? (info["customerName"] as? String) ?? ""
        guard !uid.isEmpty, !nickname.isEmpty else { return nil }
        return (uid, nickname)
    }

    /// 自动昵称：credentials.json 当前登录账号与指定 uid 一致时返回其昵称（不一致/失败返回 nil）
    static func autoNickname(forUid uid: String) -> String? {
        guard let info = currentUserInfo(), info.uid == uid else { return nil }
        return info.nickname
    }

    // MARK: 余额查询

    /// 是否 JWT（三段点分 header.payload.signature）；bigmodel 开放平台 API Key 只有一个点
    private static func isJWT(_ token: String) -> Bool {
        token.split(separator: ".").count >= 3
    }

    /// 查询结果三态（v2026.8.31 降级账号级告警）：
    /// ok = 查询成功（total=0 表示无有效套餐，正常结果，保留旧缓存展示「套餐已到期」）；
    /// accountInvalid = 业务码报账号级问题（zai code!=0 / bigmodel code 401、500 等：
    /// token 失效、账号无套餐）——单账号问题不影响平台，不判平台刷新失败，仅记日志；
    /// networkFailed = HTTP 非 200 / 网络/解析错误——请求层失败，才计入平台失败告警。
    enum BalanceResult {
        case ok(remain: Double, total: Double, planEndsAt: TimeInterval)
        case accountInvalid
        case networkFailed
    }

    /// 查询指定账号的 Coding Plan 用量，按凭据形态分流：
    /// JWT（zai/bigmodel 免费档）→ zcode.z.ai billing/balance；
    /// API Key（bigmodel 付费档 Lite 等）→ open.bigmodel.cn monitor/usage/quota/limit。
    static func fetchBalance(token: String) async -> BalanceResult {
        if isJWT(token) { return await fetchZaiBalance(token: token) }
        return await fetchBigModelBalance(apiKey: token)
    }

    /// zai 渠道：汇总 balances 数组各 entitlement 的 remaining_units / total_units（均为 token 数）。
    /// planEndsAt 为当前生效的免费套餐（Start Plan，plan_id 含 "start"）的到期时间戳（秒），
    /// 无免费套餐时为 0（调用方不显示到期副标题）。
    private static func fetchZaiBalance(token: String) async -> BalanceResult {
        guard let version = zcodeAppVersion, let deviceMid else { return .networkFailed }
        guard var comps = URLComponents(string: balanceURL) else { return .networkFailed }
        comps.queryItems = [URLQueryItem(name: "app_version", value: version)]
        guard let url = comps.url else { return .networkFailed }
        let (data, status) = await HTTP.requestWithRetry(
            url: url, method: "GET",
            headers: ["Authorization": "Bearer \(token)", "Accept": "application/json",
                      "X-Device-Mid": deviceMid],
            timeout: 15
        )
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .networkFailed
        }
        // zai 体系业务码非 0 = 账号级问题（token 失效等），降级为账号失效，不判平台失败
        guard (json["code"] as? Int) == 0 else { return .accountInvalid }
        let d = (json["data"] as? [String: Any]) ?? [:]
        let balances = (d["balances"] as? [[String: Any]]) ?? []
        var remain = 0.0
        var total = 0.0
        for b in balances {
            total += (b["total_units"] as? Double) ?? 0
            remain += (b["remaining_units"] as? Double) ?? 0
        }
        // 到期时间：取 active 且 plan_id 含 "start" 的套餐（免费/活动档）；多取一时取最先到期
        var planEndsAt: TimeInterval = 0
        if let plans = d["plans"] as? [[String: Any]] {
            for p in plans where (p["status"] as? String) == "active" {
                let planId = (p["plan_id"] as? String) ?? ""
                guard planId.contains("start") || ((p["name"] as? String) ?? "").contains("Start") else { continue }
                if let ends = p["ends_at"] as? Double {
                    if planEndsAt == 0 || ends < planEndsAt { planEndsAt = ends }
                }
            }
        }
        return .ok(remain: remain, total: total, planEndsAt: planEndsAt)
    }

    /// bigmodel 付费 Coding Plan（Lite 等）：data.limits[] 各窗口的 usage/currentValue/remaining。
    /// 数值取 remaining 最小的一条（最紧约束）；planEndsAt 取 nextResetTime 最晚的一条
    ///（月度窗口重置点，语义贴近「到期」副标题；毫秒戳转秒）。
    private static func fetchBigModelBalance(apiKey: String) async -> BalanceResult {
        guard let url = URL(string: bigModelQuotaURL) else { return .networkFailed }
        let (data, status) = await HTTP.requestWithRetry(
            url: url, method: "GET",
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
            timeout: 15
        )
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .networkFailed
        }
        // bigmodel 业务码非 200（401 令牌过期 / 500 无套餐等）= 账号级问题，降级不判平台失败
        guard (json["code"] as? Int) == 200 else { return .accountInvalid }
        let d = (json["data"] as? [String: Any]) ?? [:]
        let limits = (d["limits"] as? [[String: Any]]) ?? []
        var remain = 0.0
        var total = 0.0
        var tightest = Double.infinity
        for l in limits {
            let rem = (l["remaining"] as? Double) ?? 0
            let tot = (l["usage"] as? Double) ?? 0
            if rem < tightest {
                tightest = rem
                remain = rem
                total = tot
            }
        }
        var planEndsAt: TimeInterval = 0
        for l in limits {
            if let resetMs = l["nextResetTime"] as? Double {
                let reset = resetMs / 1000
                if planEndsAt == 0 || reset > planEndsAt { planEndsAt = reset }
            }
        }
        return .ok(remain: remain, total: total, planEndsAt: planEndsAt)
    }
}

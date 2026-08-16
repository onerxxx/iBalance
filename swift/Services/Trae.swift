// Trae.swift — TRAE 积分查询 + 签到 + 多账号采集/切换（自定义 byteCrypto 解密）
import AppKit
import Foundation

// MARK: - TRAE 多账号采集结果

enum TraeCollectResult {
    case success(TraeAccountInfo)
    case failure(String)
}

/// TRAE 账号信息（采集时从 storage.json 解密得到）
struct TraeAccountInfo {
    let uid: String
    let username: String
    let avatarUrl: String
    let encryptedAuthInfo: String   // 原始 base64 加密块（切换时写回 storage.json）
    let token: String               // 解密后的 access_token（余额查询用）
}

enum TraeService {
    /// byteCrypto 硬编码 salt 数组（从 TRAE SOLO CN byteCrypto.js 提取）
    private static let jee: [UInt8] = [82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37]
    private static let wee: [UInt8] = [31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125]

    /// 解密 iCubeAuthInfo 密文，返回完整账号 JSON（token/refreshToken/userId/account 等）
    private static func decryptAuthInfo(_ raw: Data) -> [String: Any]? {
        let cm = 6, vw = 32, kd = 64, ti = 64
        guard raw.count > vw + cm + kd else { return nil }

        let key = raw.subdata(in: cm..<(cm + vw))
        let shaKey = Crypto.sha512(key)

        var salt = [UInt8](repeating: 0, count: ti)
        for i in 0..<ti { salt[i] = jee[i] ^ wee[i] }

        var n = Data()
        n.append(shaKey)
        n.append(contentsOf: salt)
        let derived = Crypto.sha512(n)

        let aesKey = derived.prefix(16)
        let iv = derived.subdata(in: 16..<32)

        guard let plaintext = Crypto.aesCbcDecrypt(key: Data(aesKey), iv: iv, ct: raw.subdata(in: (vw + cm)..<raw.count)) else { return nil }

        let hmac = plaintext.prefix(kd)
        let body = plaintext.subdata(in: kd..<plaintext.count)
        let expectedHmac = Crypto.sha512(body)
        guard hmac.elementsEqual(expectedHmac.prefix(kd)) else { return nil }

        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// 从 storage.json 解密获取 TRAE token（供 fetchCredits 与签到复用，避免重复读盘解密）
    static func getToken(storagePath: String) -> String? {
        guard let info = readAuthInfo(storagePath: storagePath) else { return nil }
        return info.token
    }

    /// 读取 storage.json 并解密 iCubeAuthInfo，返回完整账号信息
    /// 用于采集当前登录账号 + 多账号余额查询
    static func readAuthInfo(storagePath: String) -> TraeAccountInfo? {
        guard FileManager.default.fileExists(atPath: storagePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encrypted = json["iCubeAuthInfo://icube.cloudide"] as? String,
              let raw = Data(base64Encoded: encrypted) else { return nil }
        guard let decrypted = decryptAuthInfo(raw),
              let token = decrypted["token"] as? String, !token.isEmpty,
              let userId = decrypted["userId"] as? String, !userId.isEmpty else { return nil }
        let account = decrypted["account"] as? [String: Any]
        let username = (account?["username"] as? String) ?? userId
        let avatarUrl = (account?["avatar_url"] as? String) ?? ""
        return TraeAccountInfo(uid: userId, username: username, avatarUrl: avatarUrl, encryptedAuthInfo: encrypted, token: token)
    }

    /// 从加密块（base64 字符串）直接解密 token，供 config 中预存的多号账号查询余额
    static func getTokenFromEncrypted(_ encrypted: String) -> String? {
        guard let raw = Data(base64Encoded: encrypted),
              let decrypted = decryptAuthInfo(raw),
              let token = decrypted["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// 用指定 token 查询 TRAE 积分（多账号场景：每个账号独立查询）
    static func fetchCreditsForToken(_ token: String) async -> (limit: Double, used: Double)? {
        guard let url = URL(string: "https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage?require_usage=true&req_source=2") else { return nil }
        let (respData, status) = await HTTP.requestWithRetry(url: url, headers: [
            "Authorization": "Cloud-IDE-JWT \(token)",
            "X-User-Region": "CN",
            "Accept": "application/json"
        ], timeout: 15)
        guard status == 200, let respData,
              let resp = try? JSONDecoder().decode(UsageResponse.self, from: respData) else { return nil }

        var totalLimit: Double = 0
        var totalUsed: Double = 0
        for pack in resp.user_entitlement_pack_list ?? [] {
            let limit = pack.entitlement_base_info?.quota?.credits_limit?.value ?? 0
            let used = pack.usage?.credits_amount?.value ?? 0
            totalLimit += limit
            totalUsed += used
        }
        return (totalLimit, totalUsed)
    }

    /// 查询 TRAE 积分，成功返回 (limit, used)。失败返回 nil。
    static func fetchCredits(storagePath: String) async -> (limit: Double, used: Double)? {
        guard let token = getToken(storagePath: storagePath) else { return nil }
        return await fetchCreditsForToken(token)
    }

    private struct UsageResponse: Decodable {
        struct Pack: Decodable {
            struct Base: Decodable {
                struct Quota: Decodable { let credits_limit: FlexibleDouble? }
                let quota: Quota?
            }
            struct Usage: Decodable { let credits_amount: FlexibleDouble? }
            let entitlement_base_info: Base?
            let usage: Usage?
        }
        let user_entitlement_pack_list: [Pack]?
    }

    // MARK: - 多账号采集

    /// 采集当前 storage.json 中的登录账号。
    /// 采集流程：读取 storage.json → 解密 iCubeAuthInfo → 提取 uid/username/加密块
    static func collectCurrentAccount(storagePath: String) -> TraeCollectResult {
        guard let info = readAuthInfo(storagePath: storagePath) else {
            return .failure("无法读取 TRAE 登录信息，请确认 TRAE 已登录")
        }
        return .success(info)
    }

    // MARK: - 多账号切换（写 storage.json + 重启 TRAE）

    /// 将指定账号的加密块写回 storage.json，然后杀掉并重启 TRAE SOLO CN。
    /// 流程：杀进程 → 写 storage.json → 重启
    static func switchAccount(account: TraeAccountInfo, storagePath: String) {
        let t0 = Date()
        Logger.log(.switchAccount, "[iBalance] TRAE switchAccount start: uid=\(account.uid) username=\(account.username)")
        // 1. 杀掉 TRAE 主进程
        ProcessUtil.killMainProcesses(containingAll: ["trae", ".app/contents/macos/"], label: "TRAE")
        // 2. 写回 storage.json 的 iCubeAuthInfo 字段
        guard writeStorageJson(account: account, storagePath: storagePath) else {
            Logger.log(.switchAccount, "[iBalance] TRAE writeStorageJson FAILED")
            return
        }
        // 3. 重启 TRAE
        restartTrae()
        Logger.log(.switchAccount, "[iBalance] TRAE switchAccount done, total \(ProcessUtil.ms(since: t0))ms")
    }

    /// 把账号的加密块写回 storage.json 的 iCubeAuthInfo://icube.cloudide 字段（原子写入）
    private static func writeStorageJson(account: TraeAccountInfo, storagePath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: storagePath) else {
            Logger.log(.switchAccount, "[iBalance] storage.json not found at \(storagePath)")
            return false
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger.log(.switchAccount, "[iBalance] failed to parse storage.json")
            return false
        }
        json["iCubeAuthInfo://icube.cloudide"] = account.encryptedAuthInfo
        guard let outData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
            return false
        }
        do {
            try outData.write(to: URL(fileURLWithPath: storagePath), options: [.atomic])
            return true
        } catch {
            Logger.log(.switchAccount, "[iBalance] failed to write storage.json: \(error)")
            return false
        }
    }

    /// 重启 TRAE SOLO CN
    private static func restartTrae() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", "-a", "TRAE SOLO CN"]
        try? task.run()
    }

    // MARK: 签到

    /// 读取 TRAE SOLO CN 的 machineid 作为 x-device-id。
    /// machineid 位于应用根目录（storage.json 上溯三级：globalStorage → User → 根）。
    static func deviceId(storagePath: String) -> String? {
        let url = URL(fileURLWithPath: storagePath)
            .deletingLastPathComponent()      // .../globalStorage
            .deletingLastPathComponent()      // .../User
            .deletingLastPathComponent()      // 应用根
            .appendingPathComponent("machineid")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 签到状态查询/签到

    /// 查询 TRAE 签到状态。返回 (enable, checkedIn, continuousDays, reward)；失败返回 nil。
    /// continuousDays / reward 从状态响应中尽力解析（字段名可能为 continuous_days / streak / reward / credit）。
    static func fetchCheckinStatus(token: String, storagePath: String) async -> (enable: Bool, checkedIn: Bool, continuousDays: Int, reward: Int)? {
        guard let url = URL(string: "https://api.trae.cn/trae/api/v2/ug/checkin_credits/status") else { return nil }
        var headers: [String: String] = [
            "Authorization": "Cloud-IDE-JWT \(token)",
            "X-User-Region": "CN",
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        if let deviceId = deviceId(storagePath: storagePath) { headers["x-device-id"] = deviceId }
        let (respData, status) = await HTTP.request(url: url, method: "POST", headers: headers, body: Data("{}".utf8), timeout: 15)
        guard status == 200, let respData,
              let respJson = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            // Log raw response on failure
            if let d = respData, let raw = String(data: d, encoding: .utf8) {
                Logger.log(.traeCheckin, "STATUS status=\(status) raw=\(raw)")
            }
            return nil
        }
        // Log raw response for debugging
        if let raw = String(data: respData, encoding: .utf8) {
            Logger.log(.traeCheckin, "STATUS raw=\(raw)")
        }
        // Support both {code:0, data:{...}} and direct {...} formats
        let inner: [String: Any]
        if let bizCode = respJson["code"] as? Int, bizCode == 0, let data = respJson["data"] as? [String: Any] {
            inner = data
        } else if let data = respJson["data"] as? [String: Any] {
            inner = data
        } else {
            inner = respJson
        }
        let enable = (inner["enable"] as? Bool) ?? (respJson["enable"] as? Bool) ?? false
        let checkedIn = (inner["checked_in"] as? Bool) ?? (respJson["checked_in"] as? Bool) ?? false
        let continuousDays = (inner["continuous_days"] as? Int)
            ?? (inner["streak"] as? Int)
            ?? (inner["consecutive_days"] as? Int)
            ?? (inner["continuousDays"] as? Int)
            ?? 0
        let reward = (inner["reward"] as? Int)
            ?? (inner["credit"] as? Int)
            ?? (inner["today_credit"] as? Int)
            ?? (inner["credits"] as? Int)
            ?? 0
        return (enable, checkedIn, continuousDays, reward)
    }

    /// 执行 TRAE 签到。返回 (httpStatus, responseBody JSON)。
    static func claimCheckin(token: String, storagePath: String) async -> (Int, [String: Any]?) {
        guard let url = URL(string: "https://api.trae.cn/trae/api/v2/ug/checkin_credits/claim") else { return (0, nil) }
        var headers: [String: String] = [
            "Authorization": "Cloud-IDE-JWT \(token)",
            "X-User-Region": "CN",
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        if let deviceId = deviceId(storagePath: storagePath) { headers["x-device-id"] = deviceId }
        let (respData, status) = await HTTP.request(url: url, method: "POST", headers: headers, body: Data("{}".utf8), timeout: 15)
        var json: [String: Any]?
        if let d = respData {
            json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            // Log raw response for debugging
            if let raw = String(data: d, encoding: .utf8) {
                Logger.log(.traeCheckin, "CLAIM status=\(status) raw=\(raw)")
            }
        }
        return (status, json)
    }

}

// Trae.swift — TRAE 积分查询 + 签到（自定义 byteCrypto 解密）
import Foundation

enum TraeService {
    /// byteCrypto 硬编码 salt 数组（从 TRAE SOLO CN byteCrypto.js 提取）
    private static let jee: [UInt8] = [82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37]
    private static let wee: [UInt8] = [31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125]

    /// 解密 iCubeAuthInfo 密文，返回 access_token
    private static func decryptToken(_ raw: Data) -> String? {
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

        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = json["token"] as? String else { return nil }
        return token
    }

    /// 从 storage.json 解密获取 TRAE token（供 fetchCredits 与签到复用，避免重复读盘解密）
    static func getToken(storagePath: String) -> String? {
        guard FileManager.default.fileExists(atPath: storagePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encrypted = json["iCubeAuthInfo://icube.cloudide"] as? String,
              let raw = Data(base64Encoded: encrypted) else { return nil }
        return decryptToken(raw)
    }

    /// 查询 TRAE 积分，成功返回 (limit, used)。失败返回 nil。
    static func fetchCredits(storagePath: String) async -> (limit: Double, used: Double)? {
        guard let token = getToken(storagePath: storagePath) else { return nil }
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

    /// 查询 TRAE 签到状态。返回 (enable, checkedIn)；失败返回 nil。
    static func fetchCheckinStatus(token: String, storagePath: String) async -> (enable: Bool, checkedIn: Bool)? {
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
              let respJson = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else { return nil }
        let enable = respJson["enable"] as? Bool ?? false
        let checkedIn = respJson["checked_in"] as? Bool ?? false
        return (enable, checkedIn)
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
        if let d = respData { json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
        return (status, json)
    }
}

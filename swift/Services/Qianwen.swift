// Qianwen.swift — 千问 Token Plan 周/5h 配额查询（自动读取 Edge 登录态）
import Foundation
import Security
import SQLite3

enum QianwenService {

    /// 配额快照：周 / 5 小时滚动窗口的剩余与上限
    struct Quota {
        let weekRem: Double
        let weekLimit: Double
        let h5Rem: Double
        let h5Limit: Double
    }

    /// fetchQuota 的复合返回：配额 + TCC 拦截标记（供主线程决定是否弹一次引导授权）
    struct FetchResult {
        let quota: Quota?
        let tccBlocked: Bool
    }

    // MARK: - 从 Edge Cookie 数据库读取 ticket

    /// 新版 Edge（App-Bound 加密）格式：encrypted_value = "v10" + AES-CBC(PBKDF2(keychain密码))，
    /// 明文前 32 字节为随机前缀，真实值为其后内容。
    /// 返回 (ticket, tccBlocked)：成功返回 ticket；TCC 拦截返回 (nil, true)；其他失败返回 (nil, false)。
    static func edgeTicket() -> (ticket: String?, tccBlocked: Bool) {
        let cookiePath = NSHomeDirectory() + "/Library/Application Support/Microsoft Edge/Default/Cookies"
        let keychainService = "Microsoft Edge Safe Storage"
        guard FileManager.default.fileExists(atPath: cookiePath) else { return (nil, false) }

        // 1. 读 Keychain 里的加密密钥
        var data: UnsafeMutableRawPointer?
        var len: UInt32 = 0
        let status = SecKeychainFindGenericPassword(nil, UInt32(keychainService.utf8.count), keychainService, 0, nil, &len, &data, nil)
        guard status == errSecSuccess, let d = data else { return (nil, false) }
        defer { SecKeychainItemFreeContent(nil, d) }
        guard let password = String(data: Data(bytes: d, count: Int(len)), encoding: .utf8) else { return (nil, false) }

        // 2. 复制 Cookie 数据库到临时文件（浏览器运行中会锁库，只读打开仍需副本）
        let tmp = NSTemporaryDirectory() + "qw_\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            try FileManager.default.copyItem(atPath: cookiePath, toPath: tmp)
        } catch let e as NSError {
            // 精确判断 TCC 拦截：NSFileReadNoPermissionError（Cocoa 257）或 NSPOSIXErrorDomain EPERM。
            // 其他错误（磁盘满、文件不存在等）不视为 TCC，避免误引导用户去开「完全磁盘访问」。
            let tcc = (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError)
                || (e.domain == NSPOSIXErrorDomain && e.code == Int(EPERM))
            return (nil, tcc)
        }

        // 3. 查询 encrypted_value
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else { return (nil, false) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT encrypted_value FROM cookies WHERE host_key='.qianwenai.com' AND name='login_qianwenai_ticket'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return (nil, false) }
        defer { sqlite3_finalize(stmt) }
        var enc: Data?
        while sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_blob(stmt, 0) {
            enc = Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, 0)))
        }
        guard let enc = enc, enc.count > 3, enc[0] == 0x76, enc[1] == 0x31, enc[2] == 0x30 else { return (nil, false) }

        // 4. PBKDF2-HMAC-SHA1(salt="saltysalt", iter=1003) 派生 AES-128 key
        let salt = Array("saltysalt".utf8)
        let pwBytes = Array(password.utf8)
        let key = Crypto.pbkdf2Sha1(password: pwBytes, salt: salt, iterations: 1003, keyLength: 16)

        // 5. AES-128-CBC 解密（iv = 0x20×16），跳过前 32 字节随机前缀
        let iv = [UInt8](repeating: 0x20, count: 16)
        let ct = Array(enc.subdata(in: 3..<enc.count))
        guard let plaintext = Crypto.aesCbcDecrypt(key: Data(key), iv: Data(iv), ct: Data(ct)),
              plaintext.count > 32 else { return (nil, false) }
        let value = plaintext.subdata(in: 32..<plaintext.count)
        guard let ticket = String(data: value, encoding: .utf8), !ticket.isEmpty else { return (nil, false) }
        return (ticket, false)
    }

    // MARK: - 配额查询

    /// 调千问控制台网关 api.json（BroadScopeAspnGateway），返回 data.DataV2.data.data 载荷；失败返回 nil
    private static func gateway(api: String, dataJson: String, secToken: String, ticket: String) async -> [String: Any]? {
        let params = "{\"Api\":\"\(api)\",\"Data\":\(dataJson),\"V\":\"1.0\"}"
        let body = "product=sfm_bailian&action=BroadScopeAspnGateway&sec_token=\(formEncode(secToken))&region=cn-beijing&params=\(formEncode(params))"
        guard let url = URL(string: "https://cs-data.qianwenai.com/data/api.json?product=sfm_bailian&action=BroadScopeAspnGateway&api=\(formEncode(api))") else { return nil }
        let (data, status) = await HTTP.request(url: url, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "Cookie": "login_qianwenai_ticket=\(ticket)",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ], body: Data(body.utf8), timeout: 15)
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outer = json["data"] as? [String: Any],
              let dataV2 = outer["DataV2"] as? [String: Any],
              let inner = dataV2["data"] as? [String: Any],
              let payload = inner["data"] as? [String: Any] else { return nil }
        return payload
    }

    /// 查询千问 Token Plan 周/5 小时配额剩余。
    /// 流程：取 ticket（Edge 自动读取优先 → config 手动值）→ 拉控制台页面解析 SEC_TOKEN → 网关三连查。
    static func fetchQuota(manualTicket: String) async -> FetchResult {
        let (edgeTicket, tccBlocked) = edgeTicket()
        let ticket = edgeTicket ?? manualTicket
        guard !ticket.isEmpty else {
            return FetchResult(quota: nil, tccBlocked: tccBlocked)
        }
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

        guard let pageURL = URL(string: "https://platform.qianwenai.com/home/billing/subscription/token-plan-individual") else {
            return FetchResult(quota: nil, tccBlocked: false)
        }
        let (htmlData, status) = await HTTP.requestWithRetry(url: pageURL, headers: [
            "Cookie": "login_qianwenai_ticket=\(ticket)",
            "User-Agent": ua
        ], timeout: 15)
        guard status == 200, let htmlData = htmlData,
              let html = String(data: htmlData, encoding: .utf8),
              let secToken = regexFirstGroup("SEC_TOKEN:\\s*\"([^\"]+)\"", in: html) else {
            return FetchResult(quota: nil, tccBlocked: false)
        }

        let cornerstone = "{\"domain\":\"platform.qianwenai.com\",\"consoleSite\":\"QIANWENAI\",\"console\":\"ONE_CONSOLE\",\"xsp_lang\":\"zh-CN\",\"protocol\":\"V2\",\"productCode\":\"p_efm\"}"
        guard let sub = await gateway(api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription",
                                      dataJson: "{\"commodityCode\":\"sfm_tokenplansolo_public_cn\",\"cornerstoneParam\":\(cornerstone)}",
                                      secToken: secToken, ticket: ticket),
              let quota = await gateway(api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config",
                                        dataJson: "{\"cornerstoneParam\":\(cornerstone)}",
                                        secToken: secToken, ticket: ticket),
              let usage = await gateway(api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
                                        dataJson: "{\"cornerstoneParam\":\(cornerstone)}",
                                        secToken: secToken, ticket: ticket) else {
            return FetchResult(quota: nil, tccBlocked: false)
        }

        let specCode = sub["specCode"] as? String ?? "lite"
        guard let specQuota = quota[specCode] as? [String: Any] else {
            return FetchResult(quota: nil, tccBlocked: false)
        }
        let weekly = jsonNum(specQuota["weekly"])
        let fiveHour = jsonNum(specQuota["five_hour"])
        let weekPct = (usage["per1WeekPercentage"] as? Double) ?? 0
        let h5Pct = (usage["per5HourPercentage"] as? Double) ?? 0

        return FetchResult(quota: Quota(
            weekRem: weekly * (1 - weekPct),
            weekLimit: weekly,
            h5Rem: fiveHour * (1 - h5Pct),
            h5Limit: fiveHour
        ), tccBlocked: false)
    }
}

// BigModelService.swift — 智谱 BigModel（bigmodel.cn 开放平台）余额查询
// 登录态来源：浏览器 Cookies 库中的 bigmodel_token_production（JWT，v10 加密），
// 解密后放 Authorization: Bearer 调财务报告接口取 availableBalance。
// Cookie 采集方案复刻自已下线的千问 edgeTicket 实现（见 git 67eeb0e~1 Services/Qianwen.swift）。
//
// 钥匙串优化：解密需要各浏览器「Safe Storage」主密钥（钥匙串条目）。应用重签名后
// 该条目的 ACL 不再信任新二进制，会重复弹授权框。因此：
//   1. 采到的 JWT 落盘缓存（0600），后续刷新/重启/重编译直接复用，完全不碰钥匙串；
//   2. 仅当浏览器 Cookie 库确实存在目标行时才去取主密钥（避免对未登录浏览器白弹窗）；
//   3. 接口报登录态失效时清缓存重采一轮自愈。
import Foundation
import Security
import SQLite3

enum BigModelService {
    /// 登录态 Cookie 名与站点（与浏览器站内一致）
    private static let cookieName = "bigmodel_token_production"
    private static let cookieHost = "bigmodel.cn"
    /// 报告接口：data.availableBalance 即官网「财务中心」页 .amount 显示的可用余额
    private static let reportURL = "https://bigmodel.cn/api/biz/account/query-customer-account-report"

    // MARK: - Token 本地缓存（重编译/重启后免钥匙串授权）

    private static var tokenCacheURL: URL {
        AppDataStore.applicationSupportURL.appendingPathComponent("bigmodel_token.json")
    }
    private struct TokenCacheFile: Codable {
        let token: String
        let source: String
        let updatedAt: Date
    }

    static func cachedToken() -> String? {
        guard let data = try? Data(contentsOf: tokenCacheURL),
              let f = try? JSONDecoder().decode(TokenCacheFile.self, from: data),
              !f.token.isEmpty else { return nil }
        return f.token
    }

    private static func storeToken(_ token: String, source: String) {
        guard let out = try? JSONEncoder().encode(TokenCacheFile(token: token, source: source, updatedAt: Date())) else { return }
        AppDataStore.secureWrite(out, to: tokenCacheURL)
        Logger.log(.refresh, "[ZhiPu] 登录态已缓存（来源：\(source)），后续刷新不再访问钥匙串")
    }

    static func clearCachedToken() {
        try? FileManager.default.removeItem(at: tokenCacheURL)
    }

    // MARK: - 凭据解析

    struct BrowserSpec {
        let userDataDir: String     // Application Support 下的用户数据根目录
        let keychainService: String // Chrome 系 Safe Storage 在登录钥匙串的 service 名
        let label: String           // 日志用名
    }

    /// 候选浏览器：Edge + Chrome。只有其 Cookies 库存在智谱登录行时才会走到
    /// 取密钥步骤（每浏览器首次授权一次）；多浏览器命中取 last_access_utc 最大者。
    private static func browserSpecs() -> [BrowserSpec] {
        let support = NSHomeDirectory() + "/Library/Application Support"
        return [
            BrowserSpec(userDataDir: support + "/Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", label: "Edge"),
            BrowserSpec(userDataDir: support + "/Google/Chrome", keychainService: "Chrome Safe Storage", label: "Chrome"),
        ]
    }

    /// 手填覆盖值非空时直接使用；其次读本地缓存（零权限开销）；
    /// 否则扫描各浏览器 Profile 的 Cookies 库（确认存在目标行才取主密钥）。
    static func resolveToken(override: String) -> String? {
        if !override.isEmpty { return override }
        if let cached = cachedToken() { return cached }

        var hits: [CookieHit] = []
        for spec in browserSpecs() where FileManager.default.fileExists(atPath: spec.userDataDir) {
            // 第一步：纯文件读——各 Profile 的 Cookies 库里是否存在目标行（不动钥匙串）
            let rows = collectRows(spec: spec)
            guard !rows.isEmpty else {
                Logger.log(.refresh, "[ZhiPu] \(spec.label): 各 Profile 均无 \(cookieHost) 登录行")
                continue
            }
            // 第二步：确有目标行才向钥匙串要 Safe Storage 主密钥（首次会弹授权确认）
            guard let password = safeStoragePassword(service: spec.keychainService) else {
                Logger.log(.refresh, "[ZhiPu] \(spec.label): Safe Storage 密钥不可用，跳过")
                continue
            }
            for row in rows {
                if let jwt = decodeRow(row, password: password) {
                    hits.append(CookieHit(token: jwt, lastAccess: row.lastAccess))
                }
            }
        }
        // 多 Profile / 多浏览器命中时取 last_access_utc 最大者（最近一次使用会话）
        guard let best = hits.max(by: { $0.lastAccess < $1.lastAccess }) else { return nil }
        storeToken(best.token, source: "浏览器登录态采集")
        return best.token
    }

    private struct CookieHit { let token: String; let lastAccess: Int64 }

    // MARK: Cookie 库读取（纯文件操作，不涉及钥匙串）

    private struct BrowserRow {
        let enc: Data          // encrypted_value 列（v10 密文或空）
        let plain: String      // value 列（老版本明文）
        let lastAccess: Int64
        let profile: String    // 日志定位用：Profile 目录名
    }

    private static func collectRows(spec: BrowserSpec) -> [BrowserRow] {
        guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: spec.userDataDir) else {
            Logger.log(.refresh, "[ZhiPu] \(spec.label): 用户数据目录不可读（TCC/权限）")
            return []
        }
        var rows: [BrowserRow] = []
        for sub in subdirs {
            // 新版布局 <Profile>/Network/Cookies；旧版 <Profile>/Cookies
            for rel in ["Network/Cookies", "Cookies"] {
                let dbPath = spec.userDataDir + "/" + sub + "/" + rel
                guard FileManager.default.fileExists(atPath: dbPath) else { continue }
                rows.append(contentsOf: cookieRows(dbPath: dbPath, profile: sub))
            }
        }
        return rows
    }

    /// 拷贝出 Cookies 库后只读查询目标行的原始数据（不解密）；库不可读返回空数组。
    private static func cookieRows(dbPath: String, profile: String) -> [BrowserRow] {
        let fm = FileManager.default
        // 浏览器运行中会锁库，复制到临时文件只读访问
        let tmp = NSTemporaryDirectory() + "ibalance-cookies-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: tmp) }
        do {
            try fm.copyItem(atPath: dbPath, toPath: tmp)
        } catch let e as NSError {
            // 精确判断 TCC 拦截（对齐千问实现）：NSFileReadNoPermissionError / EPERM，
            // 其余错误（磁盘满等）不算 TCC，避免误导用户开「完全磁盘访问」
            let tcc = (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError)
                || (e.domain == NSPOSIXErrorDomain && e.code == Int(EPERM))
            Logger.log(.refresh, "[ZhiPu] \(profile): Cookie 库拷贝失败\(tcc ? "（TCC 拦截，需完全磁盘访问）" : ""): \(e.localizedDescription)")
            return []
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        // 加密数据在 encrypted_value（v10 密文），旧版明文在 value 列；两列都兼容
        guard sqlite3_prepare_v2(db, "SELECT encrypted_value, value, last_access_utc FROM cookies WHERE name = ? AND host_key LIKE ?", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, cookieName)
        bindText(stmt, index: 2, "%\(cookieHost)%")

        var rows: [BrowserRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let enc = sqlite3_column_blob(stmt, 0).map { p in
                Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 0)))
            } ?? Data()
            let plain = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            rows.append(BrowserRow(enc: enc, plain: plain,
                                   lastAccess: sqlite3_column_int64(stmt, 2), profile: profile))
        }
        return rows
    }

    // MARK: - 解密

    /// PBKDF2-HMAC-SHA1(salt="saltysalt", iter=1003) 派生 AES-128-CBC 密钥（16 空格 IV）
    private static func decodeRow(_ row: BrowserRow, password: Data) -> String? {
        // 老版本：value 列即明文 JWT
        let trimmed = row.plain.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeJWT(trimmed) { return trimmed }
        // 新版：encrypted_value 为 v10 密文（新版 Edge/Chrome 解密后明文前 32 字节为随机填充，
        // 真实值其后——千问 edgeTicket 已验证的格式，两种都兼容）
        guard row.enc.count > 3, row.enc[0] == 0x76, row.enc[1] == 0x31, row.enc[2] == 0x30 else {
            Logger.log(.refresh, "[ZhiPu] \(row.profile): 行 len=\(row.enc.count)，非 v10 密文")
            return nil
        }
        let key = Data(Crypto.pbkdf2Sha1(password: Array(password), salt: Array("saltysalt".utf8), iterations: 1003, keyLength: 16))
        let iv = Data(repeating: 0x20, count: 16)
        guard let plain = Crypto.aesCbcDecrypt(key: key, iv: iv, ct: row.enc.subdata(in: 3..<row.enc.count)),
              let jwt = extractJWT(from: plain) else {
            Logger.log(.refresh, "[ZhiPu] \(row.profile): 解密失败或明文非 JWT（\(row.enc.count)B 密文）")
            return nil
        }
        return jwt
    }

    /// v10 解密后的明文提取 JWT：老版本即明文；App-Bound 填充则前 32 字节为随机前缀
    private static func extractJWT(from plain: Data) -> String? {
        for start in [0, 32] where plain.count > start {
            let text = String(data: plain.dropFirst(start), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if looksLikeJWT(text) { return text }
        }
        return nil
    }

    /// JWT 粗校验：两段以上点分 base64 且长度合理（避免把填充噪声误判为 token）
    private static func looksLikeJWT(_ s: String) -> Bool {
        s.split(separator: ".").count >= 2 && s.count > 40
            && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static func bindText(_ stmt: OpaquePointer?, index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
    }

    /// Chrome 系 Safe Storage 主密钥口令（随机生成存于登录钥匙串）。
    /// 仅在确认 Cookie 库存在目标行后才调用；首次会弹授权确认，
    /// 点「始终允许」可记住；应用重签名后会再次弹出（token 缓存可长期规避）。
    private static func safeStoragePassword(service: String) -> Data? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else { return nil }
        return data
    }

    // MARK: - 余额查询

    /// 查询可用余额（元）与消耗基线（充值+赠送总额，驱动点阵进度）。
    /// token 为空静默跳过（error/authFailed 为空/false）；authFailed=true 表示登录态失效
    /// （调用方清缓存重采），error 供通知/footer 展示。budget<=0 表示未提供基线（点阵隐藏）。
    static func fetch(token: String) async -> (balance: Double?, budget: Double, authFailed: Bool, error: String) {
        guard !token.isEmpty else { return (nil, 0, false, "") }
        guard let url = URL(string: reportURL) else { return (nil, 0, false, "URL错误") }
        let (data, status) = await HTTP.requestWithRetry(
            url: url, method: "GET",
            headers: ["Accept": "application/json", "Authorization": "Bearer \(token)"],
            timeout: 15
        )
        guard status == 200 else {
            if status == 0 { return (nil, 0, false, "网络错误") }
            let failed = status == 401 || status == 403
            return (nil, 0, failed, "HTTP \(status)\(failed ? "（登录态可能已失效）" : "")")
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, 0, false, "响应解析失败")
        }
        // 业务层鉴权失败：code 1001（实测无 Authorization 时返回此码）/ 401
        let code = json["code"] as? Int ?? 0
        guard code == 200 else {
            return (nil, 0, code == 1001 || code == 401, "接口 code=\(code)（登录态可能已失效）")
        }
        let d = (json["data"] as? [String: Any]) ?? [:]
        guard let bal = d["availableBalance"].flatMap(anyToDouble) ?? d["balance"].flatMap(anyToDouble) else {
            return (nil, 0, false, "响应缺少余额字段")
        }
        // 消耗基线：累计充值 + 赠送（totalSpendAmount + availableBalance ≈ 此值，已验证）
        let budget = (d["rechargeAmount"].flatMap(anyToDouble) ?? 0)
            + (d["giveAmount"].flatMap(anyToDouble) ?? 0)
        return (bal, budget, false, "")
    }
}

// BrowserCookieStore.swift — Chrome 系浏览器（Edge/Chrome）登录态 Cookie 通用采集，ZhiPu 与 Qwen 共用。
// 浏览器 Profile Cookies 库（v10 加密）→ 钥匙串 Safe Storage 主密钥解密 → 登录态落盘缓存（0600），
// 后续刷新/重启/重编译直接复用，完全不碰钥匙串。采集方案源自已下线的千问 edgeTicket（git 67eeb0e~1），
// 由 BigModelService 实现泛化抽出。
//
// 钥匙串优化：解密需要各浏览器「Safe Storage」主密钥（钥匙串条目）。应用重签名后
// 该条目的 ACL 不再信任新二进制，会重复弹授权框。因此：
//   1. 采到的登录态落盘缓存，仅缓存缺失时才扫描浏览器；
//   2. 仅当浏览器 Cookie 库确实存在目标行时才去取主密钥（避免对未登录浏览器白弹窗）；
//   3. 多浏览器 / 多 Profile 命中取 last_access_utc 最大者（最近一次使用会话）；
//   4. 主密钥本身也落盘缓存（首次授权一次，见 safeStoragePassword）——登录态过期
//      重采、App 重启/重签名都不再弹窗；浏览器重装/改密致解密全失败时清缓存重授权。
import Foundation
import Security
import SQLite3

enum BrowserCookieStore {
    struct BrowserSpec {
        let userDataDir: String     // Application Support 下的用户数据根目录
        let keychainService: String // Chrome 系 Safe Storage 在登录钥匙串的 service 名
        let label: String           // 日志用名
    }

    /// 候选浏览器：Edge + Chrome。只有其 Cookies 库存在目标登录行时才会走到
    /// 取密钥步骤（每浏览器首次授权一次）。
    static func browserSpecs() -> [BrowserSpec] {
        let support = NSHomeDirectory() + "/Library/Application Support"
        return [
            BrowserSpec(userDataDir: support + "/Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", label: "Edge"),
            BrowserSpec(userDataDir: support + "/Google/Chrome", keychainService: "Chrome Safe Storage", label: "Chrome"),
        ]
    }

    struct CookieRow {
        let enc: Data          // encrypted_value 列（v10 密文或空）
        let plain: String      // value 列（老版本明文）
        let lastAccess: Int64
        let profile: String    // 日志定位用：Profile 目录名
    }

    /// 通用采集管线：手填覆盖值非空时直接使用；其次读本地缓存（零权限开销）；
    /// 否则扫描各浏览器 Profile 的 Cookies 库（确认存在目标行才取主密钥）。
    /// decode：行 → 登录态字符串（各平台自带校验，nil = 该行不可用）。
    static func resolve(override: String, cookieName: String, hostLike: String,
                        cacheFilename: String, logTag: String,
                        decode: (CookieRow, Data) -> String?) -> String? {
        if !override.isEmpty { return override }
        if let cached = cachedToken(filename: cacheFilename) { return cached }

        struct Hit { let token: String; let lastAccess: Int64 }
        var hits: [Hit] = []
        for spec in browserSpecs() where FileManager.default.fileExists(atPath: spec.userDataDir) {
            // 第一步：纯文件读——各 Profile 的 Cookies 库里是否存在目标行（不动钥匙串）
            let rows = collectRows(spec: spec, cookieName: cookieName, hostLike: hostLike, logTag: logTag)
            guard !rows.isEmpty else {
                Logger.log(.refresh, "\(logTag) \(spec.label): 各 Profile 无登录行（\(cookieName)）")
                continue
            }
            // 第二步：确有目标行才取 Safe Storage 主密钥（缓存命中零授权；缓存缺失首次弹授权）
            guard let password = safeStoragePassword(service: spec.keychainService) else {
                Logger.log(.refresh, "\(logTag) \(spec.label): Safe Storage 密钥不可用，跳过")
                continue
            }
            var specHits = 0
            for row in rows {
                if let token = decode(row, password) {
                    hits.append(Hit(token: token, lastAccess: row.lastAccess))
                    specHits += 1
                }
            }
            // 兜底：本浏览器有密文行却零命中 → 主密钥可能已变（浏览器重装/改密码），
            // 清密钥缓存重走一次钥匙串授权再试；目标行本身损坏时用户拒绝授权即跳过
            if specHits == 0, rows.contains(where: { !$0.enc.isEmpty && $0.plain.isEmpty }) {
                invalidateStorageKey(service: spec.keychainService)
                guard let fresh = safeStoragePassword(service: spec.keychainService) else { continue }
                for row in rows {
                    if let token = decode(row, fresh) {
                        hits.append(Hit(token: token, lastAccess: row.lastAccess))
                    }
                }
            }
        }
        // 多 Profile / 多浏览器命中时取 last_access_utc 最大者（最近一次使用会话）
        guard let best = hits.max(by: { $0.lastAccess < $1.lastAccess }) else { return nil }
        storeToken(best.token, filename: cacheFilename, source: "浏览器登录态采集", logTag: logTag)
        return best.token
    }

    // MARK: Cookie 库读取（纯文件操作，不涉及钥匙串）

    private static func collectRows(spec: BrowserSpec, cookieName: String, hostLike: String, logTag: String) -> [CookieRow] {
        guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: spec.userDataDir) else {
            Logger.log(.refresh, "\(logTag) \(spec.label): 用户数据目录不可读（TCC/权限）")
            return []
        }
        var rows: [CookieRow] = []
        for sub in subdirs {
            // 新版布局 <Profile>/Network/Cookies；旧版 <Profile>/Cookies
            for rel in ["Network/Cookies", "Cookies"] {
                let dbPath = spec.userDataDir + "/" + sub + "/" + rel
                guard FileManager.default.fileExists(atPath: dbPath) else { continue }
                rows.append(contentsOf: cookieRows(dbPath: dbPath, profile: sub,
                                                   cookieName: cookieName, hostLike: hostLike, logTag: logTag))
            }
        }
        return rows
    }

    /// 拷贝出 Cookies 库后只读查询目标行的原始数据（不解密）；库不可读返回空数组。
    private static func cookieRows(dbPath: String, profile: String, cookieName: String,
                                   hostLike: String, logTag: String) -> [CookieRow] {
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
            Logger.log(.refresh, "\(logTag) \(profile): Cookie 库拷贝失败\(tcc ? "（TCC 拦截，需完全磁盘访问）" : ""): \(e.localizedDescription)")
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
        bindText(stmt, index: 2, hostLike)

        var rows: [CookieRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let enc = sqlite3_column_blob(stmt, 0).map { p in
                Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 0)))
            } ?? Data()
            let plain = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            rows.append(CookieRow(enc: enc, plain: plain,
                                  lastAccess: sqlite3_column_int64(stmt, 2), profile: profile))
        }
        return rows
    }

    // MARK: - v10 解密

    /// AES-128-CBC（PBKDF2-HMAC-SHA1，salt="saltysalt" iter=1003，16 空格 IV）解密 v10 密文；
    /// 非 v10 格式或解密失败返回 nil。明文是否含 App-Bound 32 字节随机前缀由各平台 decode 判断。
    static func decryptV10(_ row: CookieRow, password: Data) -> Data? {
        guard row.enc.count > 3, row.enc[0] == 0x76, row.enc[1] == 0x31, row.enc[2] == 0x30 else { return nil }
        let key = Data(Crypto.pbkdf2Sha1(password: Array(password), salt: Array("saltysalt".utf8), iterations: 1003, keyLength: 16))
        let iv = Data(repeating: 0x20, count: 16)
        return Crypto.aesCbcDecrypt(key: key, iv: iv, ct: row.enc.subdata(in: 3..<row.enc.count))
    }

    private static func bindText(_ stmt: OpaquePointer?, index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
    }

    /// Chrome 系 Safe Storage 主密钥口令（随机生成存于登录钥匙串）。
    /// 主密钥落盘缓存（browser-storage-keys.json，0600）：首次授权取到后永久复用，
    /// 之后登录态过期重采、App 重启/重签名都不再弹钥匙串授权框；
    /// 仅缓存缺失时才访问钥匙串。
    /// 安全权衡：口令明文落盘保护等级低于钥匙串，但本机攻击者能读到本文件即可直接
    /// 读 Cookies 库自行解密（等价可达），且与同目录已缓存的登录态明文同风险面。
    static func safeStoragePassword(service: String) -> Data? {
        if let cached = cachedStorageKey(service: service) { return cached }
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else { return nil }
        storeStorageKey(data, service: service)
        return data
    }

    // MARK: - Safe Storage 主密钥缓存（service → base64 口令，0600）

    private struct KeyCacheFile: Codable {
        let keys: [String: String]
        let updatedAt: Date
    }

    private static let keyCacheFilename = "browser-storage-keys.json"

    private static func keyCacheURL() -> URL {
        AppDataStore.applicationSupportURL.appendingPathComponent(keyCacheFilename)
    }

    private static func loadKeyCache() -> [String: String] {
        guard let data = try? Data(contentsOf: keyCacheURL()),
              let f = try? JSONDecoder().decode(KeyCacheFile.self, from: data) else { return [:] }
        return f.keys
    }

    private static func saveKeyCache(_ keys: [String: String]) {
        guard let out = try? JSONEncoder().encode(KeyCacheFile(keys: keys, updatedAt: Date())) else { return }
        AppDataStore.secureWrite(out, to: keyCacheURL())
    }

    private static func cachedStorageKey(service: String) -> Data? {
        guard let b64 = loadKeyCache()[service],
              let data = Data(base64Encoded: b64), !data.isEmpty else { return nil }
        return data
    }

    private static func storeStorageKey(_ password: Data, service: String) {
        var keys = loadKeyCache()
        keys[service] = password.base64EncodedString()
        saveKeyCache(keys)
        Logger.log(.refresh, "[BrowserCookie] \(service) 主密钥已落盘缓存，后续不再访问钥匙串")
    }

    /// 密钥缓存失效（浏览器重装/改密码导致解密全失败时调用）：下次采集重新走钥匙串授权
    static func invalidateStorageKey(service: String) {
        var keys = loadKeyCache()
        guard keys.removeValue(forKey: service) != nil else { return }
        saveKeyCache(keys)
    }

    // MARK: - 登录态本地缓存（重编译/重启后免钥匙串授权）

    private struct CacheFile: Codable {
        let token: String
        let source: String
        let updatedAt: Date
    }

    private static func cacheURL(filename: String) -> URL {
        AppDataStore.applicationSupportURL.appendingPathComponent(filename)
    }

    static func cachedToken(filename: String) -> String? {
        guard let data = try? Data(contentsOf: cacheURL(filename: filename)),
              let f = try? JSONDecoder().decode(CacheFile.self, from: data),
              !f.token.isEmpty else { return nil }
        return f.token
    }

    static func storeToken(_ token: String, filename: String, source: String, logTag: String) {
        guard let out = try? JSONEncoder().encode(CacheFile(token: token, source: source, updatedAt: Date())) else { return }
        AppDataStore.secureWrite(out, to: cacheURL(filename: filename))
        Logger.log(.refresh, "\(logTag) 登录态已缓存（来源：\(source)），后续刷新不再访问钥匙串")
    }

    static func clearCachedToken(filename: String) {
        try? FileManager.default.removeItem(at: cacheURL(filename: filename))
    }
}

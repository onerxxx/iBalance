// KeychainStore.swift — 凭据钥匙串存取（CredentialVault，单条目打包设计）
//
// ─── 本文件速查 ───
// · enum CredentialVault        凭据保险库（7 个敏感字段打包 1 条 generic password）
// · Key                         键位枚举（rawValue = bundle JSON dict 的键名）
// · merge(into:)                load() 用：bundle 命中优先 + v50 逐键/明文一次性迁移
// · persist(_:)                 save() 用：整包写入（空包=删条目），失败回滚
// · writeSuspended              读失败后挂起本会话写入（防空值覆盖钥匙串真值）
// ⚠️ 仅主线程调用（与 AppConfig 的读写约定一致）
// ─────────────────
//
// 为什么单条目：2026-09-08 首版逐键 7 条目，钥匙串锁定时每次 SecItem 操作各弹一次
// 解锁密码，首次迁移连续弹 6-7 次。打包成 1 条后迁移/保存各 1 次操作，至多弹 1 次；
// 条目创建后日常保存走 update（创建者 App 静默），正常情况零弹窗。
// 为什么路径 ACL：App 用本地自签证书「iBalance Local Sign」签名，rebuild 后二进制
// 哈希变化，签名 ACL 会视新二进制为陌生 App（每次构建弹 1 次）。条目以
// SecTrustedApplicationCreateFromPath 的路径信任创建（dict 内嵌 acl_v 标记），
// ACL 与签名解耦。2026-09-10 探针实测：同路径 + 同证书 rebuild 后新二进制静默读写
// （裸二进制 / .app bundle / 外置盘三种配置全通过），机制健康；坏 ACL 只出现在
// 历史 ad-hoc 签名时代创建的条目上，靠版本标记（v3）删除重建自愈。
// ⚠️ build.sh 若某次构建落到 ad-hoc 兜底分支（找不到签名身份），该次二进制会弹
// 一次授权，属预期行为。
//
// 数据形态：account = "credentials_bundle" 的 generic password，value = JSON dict
// {legacy键名: 字符串值}；空值键不入 dict，全空 = 删除条目。
// 一次性迁移来源：① v50 逐键条目（account = 各键 rawValue）② config.json legacy 明文；
// bundle 写成功后才删 v50 逐键条目，失败保留原状下次重试。

import Foundation
import Security

enum CredentialVault {
    static let service = AppDataStore.bundleIdentifier + ".credentials"

    /// 单条目打包的 account 名
    static let bundleAccount = "credentials_bundle"

    /// bundle dict 内嵌版本标记（非 Key 枚举键位，merge 时被自然跳过）。
    /// 缺失或非当前值 = 条目 ACL 已过期（v51 签名 ACL / v2 可能为 ad-hoc 时代坏 ACL），
    /// 启动时删除重建为当前二进制的路径 ACL。
    private static let versionKey = "acl_v"
    private static let versionValue = "3"

    /// 7 个敏感字段的键位（rawValue 与 config.json legacy 键名一致，即 bundle dict 的键名）
    enum Key: String, CaseIterable {
        case deepseekApiKey         = "deepseek_api_key"
        case bigmodelTokenOverride  = "bigmodel_token_override"
        case qwenTicketOverride     = "qwen_ticket_override"
        case workbuddyAccounts      = "workbuddy_accounts"
        case traeAccounts           = "trae_accounts"
        case zcodeAccounts          = "zcode_accounts"
        case codexAccounts          = "codex_accounts"
    }

    enum ReadOutcome {
        case value([String: String])
        case missing
        case failed(OSStatus)
    }

    /// load() 遇到 keychain 读失败后置 true：本会话 save() 跳过 keychain 写入。
    /// 防的是「钥匙串暂时读不出 → 内存里凭据为空 → save 把空值写回钥匙串」的真值覆盖。
    static var writeSuspended = false

    // MARK: - 路径 ACL（根治 rebuild 后授权弹窗）

    /// App 是 ad-hoc 签名，每次 rebuild CDHash 都变，签名 ACL 对新二进制一律视为
    /// 陌生 App → 每次构建重启读条目都弹一次授权。把条目 ACL 绑定到「可执行文件
    /// 路径」（SecTrustedApplicationCreateFromPath）后与签名无关，同路径重建即静默。
    /// 旧式 SecAccess API 虽已废弃，但对 login 钥匙串 legacy 条目仍有效，且无现代替代。
    private static func selfTrustedAccess() -> SecAccess? {
        guard let exeURL = Bundle.main.executableURL else {
            Logger.log(.refresh, "[Keychain] 取不到可执行文件路径，条目退回默认 ACL")
            return nil
        }
        let path = exeURL.resolvingSymlinksInPath().path
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(path, &trusted) == errSecSuccess,
              let t = trusted else {
            Logger.log(.refresh, "[Keychain] SecTrustedApplicationCreateFromPath 失败（\(path)），条目退回默认 ACL")
            return nil
        }
        var access: SecAccess?
        guard SecAccessCreate("iBalance credentials" as CFString, [t] as CFArray, &access) == errSecSuccess,
              let a = access else {
            Logger.log(.refresh, "[Keychain] SecAccessCreate 失败，条目退回默认 ACL")
            return nil
        }
        return a
    }

    // MARK: - SecItem 原语（account 粒度）

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private enum ItemRead {
        case value(String?)
        case failed(OSStatus)
    }

    private static func readItem(_ account: String) -> ItemRead {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &out)
        switch st {
        case errSecSuccess:
            guard let data = out as? Data,
                  let s = String(data: data, encoding: .utf8) else { return .value(nil) }
            return .value(s)
        case errSecItemNotFound:
            return .value(nil)
        default:
            return .failed(st)
        }
    }

    /// 写入单条目（update 优先，不存在则 add；add 时挂路径 ACL；ThisDeviceOnly 不随 iCloud 同步）
    private static func writeItem(_ data: Data, _ account: String) -> OSStatus {
        let st = SecItemUpdate(baseQuery(account) as CFDictionary,
                               [kSecValueData as String: data] as CFDictionary)
        guard st == errSecItemNotFound else { return st }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrDescription as String] = "iBalance 凭据（config.json 明文迁移）"
        if let access = selfTrustedAccess() { add[kSecAttrAccess as String] = access }
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult
    private static func deleteItem(_ account: String) -> OSStatus {
        let st = SecItemDelete(baseQuery(account) as CFDictionary)
        return st == errSecItemNotFound ? errSecSuccess : st
    }

    // MARK: - bundle（JSON dict）编解码

    private static func readBundle() -> ReadOutcome {
        switch readItem(bundleAccount) {
        case .value(nil):
            return .missing
        case .value(let raw?):
            guard let data = raw.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                // 非 UTF-8/非 JSON 视作缺失：后续 persist 用当前值覆写，自愈
                Logger.log(.refresh, "[Keychain] bundle 数据解码失败，按缺失处理")
                return .missing
            }
            return .value(dict)
        case .failed(let st):
            return .failed(st)
        }
    }

    @discardableResult
    private static func writeBundle(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else {
            Logger.log(.refresh, "[Keychain] bundle 编码失败")
            return false
        }
        let st = writeItem(data, bundleAccount)
        if st != errSecSuccess {
            Logger.log(.refresh, "[Keychain] bundle 写入失败（OSStatus \(st)）")
            return false
        }
        return true
    }

    // MARK: - 字段映射（AppConfig ↔ 字符串）

    private static func plaintext(_ key: Key, of config: AppConfig) -> String {
        switch key {
        case .deepseekApiKey:         return config.deepseekApiKey
        case .bigmodelTokenOverride:  return config.bigmodelTokenOverride
        case .qwenTicketOverride:     return config.qwenTicketOverride
        case .workbuddyAccounts:      return encodeJSON(config.workbuddyAccounts)
        case .traeAccounts:           return encodeJSON(config.traeAccounts)
        case .zcodeAccounts:          return encodeJSON(config.zcodeAccounts)
        case .codexAccounts:          return encodeJSON(config.codexAccounts)
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 把键值套回 config；返回 false = JSON 解码失败（视为读失败处理）
    @discardableResult
    private static func apply(_ key: Key, _ raw: String, to config: inout AppConfig) -> Bool {
        switch key {
        case .deepseekApiKey:
            config.deepseekApiKey = raw
        case .bigmodelTokenOverride:
            config.bigmodelTokenOverride = raw
        case .qwenTicketOverride:
            config.qwenTicketOverride = raw
        case .workbuddyAccounts:
            guard let arr = decodeJSON([WBAccount].self, raw) else { return false }
            // 与 AppConfig.init(from:) 同一套占位过滤
            config.workbuddyAccounts = arr.filter { !$0.token.isEmpty && !$0.uid.isEmpty }
        case .traeAccounts:
            guard let arr = decodeJSON([TraeAccount].self, raw) else { return false }
            config.traeAccounts = arr.filter { !$0.uid.isEmpty && !$0.encryptedAuthInfo.isEmpty }
        case .zcodeAccounts:
            guard let arr = decodeJSON([ZCodeAccount].self, raw) else { return false }
            config.zcodeAccounts = arr.filter { !$0.uid.isEmpty && !$0.token.isEmpty }
        case .codexAccounts:
            guard let arr = decodeJSON([CodexAccount].self, raw) else { return false }
            config.codexAccounts = arr.filter { !$0.uid.isEmpty && !$0.token.isEmpty && !$0.email.isEmpty }
        }
        return true
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ raw: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(raw.utf8))
    }

    // MARK: - 语义入口（ConfigStore 独家调用）

    /// bundle 命中优先合并进 config；发现 legacy（v50 逐键条目 / config.json 明文）则
    /// 一次性打包迁入。返回 true = 已迁移（调用方应立即 save() 清洗 config.json 明文）。
    @discardableResult
    static func merge(into config: inout AppConfig) -> Bool {
        switch readBundle() {
        case .failed(let st):
            Logger.log(.refresh, "[Keychain] 读取 bundle 失败（OSStatus \(st)），挂起本会话写入")
            writeSuspended = true
            return false
        case .value(let dict):
            return mergeExisting(dict, into: &config)
        case .missing:
            return migrateLegacy(into: &config)
        }
    }

    /// bundle 已存在：ACL 版本不匹配时一次性删除重建（路径 ACL 与签名解耦，实测 2026-09-10：
    /// 同路径同证书 rebuild 后新二进制静默读写，机制健康；坏 ACL 只会出现在旧版本标记的
    /// 条目上，靠版本标记迁移自愈）。无论重建成败都返回 true 触发 save——
    /// 成功时 dict 已含版本标记，失败时由 persist 用 config 内存值重试写入，数据不丢。
    private static func mergeExisting(_ dict: [String: String], into config: inout AppConfig) -> Bool {
        var needsSave = false
        var d = dict
        if dict[versionKey] != versionValue, !dict.isEmpty {
            _ = deleteItem(bundleAccount)
            if writeBundle(dict) {
                Logger.log(.refresh, "[Keychain] bundle 条目已重建（ACL v\(dict[versionKey] ?? "无") → v\(versionValue)，旧 ACL 过期条目一次性迁移）")
            } else {
                Logger.log(.refresh, "[Keychain] bundle 重建失败，将由 save 重试写入")
            }
            d[versionKey] = versionValue
            needsSave = true
        }
        let merged = mergeBundle(d, into: &config)
        return merged || needsSave
    }

    /// bundle 已存在：dict 命中的键直接套用；dict 缺键而 config 明文有值（老版本 bundle /
    /// 应急兜底遗留）→ 补进 bundle 并返回 true 触发 save 清洗
    private static func mergeBundle(_ dict: [String: String], into config: inout AppConfig) -> Bool {
        var needsUpdate = false
        for key in Key.allCases {
            if let raw = dict[key.rawValue] {
                if !apply(key, raw, to: &config) {
                    Logger.log(.refresh, "[Keychain] \(key.rawValue) 解码失败，挂起本会话写入")
                    writeSuspended = true
                }
            } else if !plaintext(key, of: config).isEmpty {
                needsUpdate = true
            }
        }
        guard !writeSuspended, needsUpdate else { return false }
        return persist(config)
    }

    /// bundle 缺失的一次性迁移：收集 v50 逐键条目 + config.json 明文 → 打包写入 bundle →
    /// 成功后才清理 v50 逐键条目。任一步失败保留原状（v50 条目与明文兜底），下次重试。
    private static func migrateLegacy(into config: inout AppConfig) -> Bool {
        var dict: [String: String] = [:]
        var hasV50Items = false
        for key in Key.allCases {
            switch readItem(key.rawValue) {
            case .value(let raw?):
                dict[key.rawValue] = raw
                hasV50Items = true
            case .value(nil):
                break
            case .failed(let st):
                Logger.log(.refresh, "[Keychain] 读取 \(key.rawValue) 失败（OSStatus \(st)），挂起本会话写入")
                writeSuspended = true
                return false
            }
        }
        // config.json 明文补齐（dict 没有的键；值本来就在 config 里，apply 只是校验可解码）
        for key in Key.allCases where dict[key.rawValue] == nil {
            let p = plaintext(key, of: config)
            if !p.isEmpty { dict[key.rawValue] = p }
        }
        guard !dict.isEmpty else { return false }
        for (rawKey, raw) in dict {
            guard let key = Key(rawValue: rawKey) else { continue }
            if !apply(key, raw, to: &config) {
                Logger.log(.refresh, "[Keychain] \(rawKey) 解码失败，挂起本会话写入")
                writeSuspended = true
                return false
            }
        }
        guard writeBundle(dict) else { return false }
        if hasV50Items {
            for key in Key.allCases { _ = deleteItem(key.rawValue) }
        }
        Logger.log(.refresh, "[Keychain] legacy 凭据已打包迁入单条目（\(dict.count) 键位），config.json 即将清洗")
        return true
    }

    /// 把 config 中的全部凭据整包写入 keychain（空值键不入包，全空 = 删除条目）。
    /// 写失败：删除 bundle（可能是旧值）并返回 false——调用方在 JSON 保留明文兜底，
    /// 回滚保证下次加载不会从钥匙串读到比 JSON 更旧的值。
    @discardableResult
    static func persist(_ config: AppConfig) -> Bool {
        var dict: [String: String] = [:]
        for key in Key.allCases {
            let p = plaintext(key, of: config)
            if !p.isEmpty { dict[key.rawValue] = p }
        }
        guard !dict.isEmpty else {
            let st = deleteItem(bundleAccount)
            if st != errSecSuccess {
                Logger.log(.refresh, "[Keychain] bundle 删除失败（OSStatus \(st)）")
                return false
            }
            return true
        }
        dict[versionKey] = versionValue
        guard let data = try? JSONEncoder().encode(dict) else {
            Logger.log(.refresh, "[Keychain] bundle 编码失败")
            return false
        }
        let st = writeItem(data, bundleAccount)
        if st != errSecSuccess {
            _ = deleteItem(bundleAccount)
            Logger.log(.refresh, "[Keychain] bundle 写入失败（OSStatus \(st)），已回滚，凭据改由 config.json 明文兜底")
            return false
        }
        return true
    }
}

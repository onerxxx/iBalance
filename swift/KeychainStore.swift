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
// 为什么默认签名 ACL（v4）：App 用本地自签证书「iBalance Local Sign」签名，DR 锚定
// 证书指纹而非二进制哈希，rebuild 后 DR 不变 → 默认签名 ACL 跨构建静默读写。
// v2-v3 的路径 ACL（SecTrustedApplicationCreateFromPath）是 ad-hoc 签名时代的方案；
// 2026-09-12 起 macOS 27 beta 上旧式路径信任评估失效（每次重建读条目必弹一次
// 钥匙串密码），弃用并靠版本标记 v3→v4 删除重建为默认 ACL 自愈。
// ⚠️ build.sh 若某次构建落到 ad-hoc 兜底分支（找不到签名身份），该次二进制的 DR
// 退化为二进制哈希，会弹一次授权，属预期行为。
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
    /// 缺失或非当前值 = 条目 ACL 已过期（v3 路径 ACL 在 macOS 27 beta 上评估失效，
    /// 每次重建弹授权），启动时删除重建为默认签名 ACL（DR 锚定固定证书，跨构建静默）。
    private static let versionKey = "acl_v"
    private static let versionValue = "4"

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

    /// 写入单条目（update 优先，不存在则 add）。add 不传 kSecAttrAccess = 默认签名
    /// ACL：信任按 DR（固定证书「iBalance Local Sign」）判定，rebuild 跨构建静默；
    /// ThisDeviceOnly 不随 iCloud 同步
    private static func writeItem(_ data: Data, _ account: String) -> OSStatus {
        let st = SecItemUpdate(baseQuery(account) as CFDictionary,
                               [kSecValueData as String: data] as CFDictionary)
        guard st == errSecItemNotFound else { return st }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrDescription as String] = "iBalance 凭据（config.json 明文迁移）"
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

    /// bundle 已存在：ACL 版本不匹配时一次性删除重建（v3 路径 ACL 在 macOS 27 beta
    /// 上评估失效 → 重建为默认签名 ACL，DR 锚定固定证书跨构建静默；坏 ACL 只会出现在
    /// 旧版本标记的条目上，靠版本标记迁移自愈）。无论重建成败都返回 true 触发 save——
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

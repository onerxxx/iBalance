// Config.swift — 配置结构（Codable）+ 加载/保存
import Foundation

// MARK: - WorkBuddy 多号签到账号

/// OAuth 采集得到的 token/refreshToken/uid/domain/nickname。
/// refreshToken 用于在 access_token 过期前自动刷新，token 永不过期。
/// 同一时刻 WorkBuddy Desktop 只能登录一个账号，多号签到需在 config.json 预存各账号凭据。
struct WBAccount: Codable, Equatable {
    var token: String
    var uid: String
    var domain: String = "www.codebuddy.cn"
    var nickname: String = ""
    var refreshToken: String = ""   // OAuth refresh_token
    var expiresAt: TimeInterval = 0 // access_token 过期时间戳（秒），0 表示未知

    enum CodingKeys: String, CodingKey {
        case token, uid, domain, nickname
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    // 自定义解码：补全默认值（domain/nickname/refreshToken/expiresAt 缺失时给默认）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? "www.codebuddy.cn"
        let nick = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        nickname = nick.isEmpty ? uid : nick
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        expiresAt = try c.decodeIfPresent(TimeInterval.self, forKey: .expiresAt) ?? 0
    }

    init(token: String, uid: String, domain: String, nickname: String, refreshToken: String, expiresAt: TimeInterval) {
        self.token = token
        self.uid = uid
        self.domain = domain
        self.nickname = nickname.isEmpty ? uid : nickname
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

// MARK: - 应用配置

struct AppConfig: Codable {
    var deepseekApiKey: String = ""
    var refreshInterval: TimeInterval = 300
    var deepseekDecimals: Int = 2
    var workbuddyDecimals: Int = 2
    var traeStoragePath: String = ""
    var traeDecimals: Int = 0
    var workbuddyEnabled: Bool = true
    var traeAutoCheckin: Bool = true
    var hideMainIcon: Bool = true
    var qianwenTicket: String = ""
    var qianwenDecimals: Int = 1
    var cockpitAppId: String = "com.jlcodes.cockpit-tools"
    var workbuddyAutoCheckin: Bool = true
    var workbuddyAccounts: [WBAccount] = []

    enum CodingKeys: String, CodingKey {
        case deepseekApiKey = "deepseek_api_key"
        case refreshInterval = "refresh_interval"
        case deepseekDecimals = "deepseek_decimals"
        case workbuddyDecimals = "workbuddy_decimals"
        case traeStoragePath = "trae_storage_path"
        case traeDecimals = "trae_decimals"
        case workbuddyEnabled = "workbuddy_enabled"
        case traeAutoCheckin = "trae_auto_checkin"
        case hideMainIcon = "hide_main_icon"
        case qianwenTicket = "qianwen_ticket"
        case qianwenDecimals = "qianwen_decimals"
        case cockpitAppId = "cockpit_app_id"
        case workbuddyAutoCheckin = "workbuddy_auto_checkin"
        case workbuddyAccounts = "workbuddy_accounts"
    }

    // 仅解码用的 legacy 字段（旧版统一 "decimals"，新版按服务拆分；读取兼容两者）
    private enum LegacyKeys: String, CodingKey { case decimals }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(Int.self, forKey: .decimals)

        deepseekApiKey = try c.decodeIfPresent(String.self, forKey: .deepseekApiKey) ?? ""
        // refresh_interval 兼容 Double/Int（TimeInterval 解码数字字面量均 OK）
        refreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 300
        deepseekDecimals = try c.decodeIfPresent(Int.self, forKey: .deepseekDecimals) ?? legacy ?? 2
        workbuddyDecimals = try c.decodeIfPresent(Int.self, forKey: .workbuddyDecimals) ?? legacy ?? 2
        traeStoragePath = try c.decodeIfPresent(String.self, forKey: .traeStoragePath) ?? ""
        traeDecimals = try c.decodeIfPresent(Int.self, forKey: .traeDecimals) ?? 0
        workbuddyEnabled = try c.decodeIfPresent(Bool.self, forKey: .workbuddyEnabled) ?? true
        traeAutoCheckin = try c.decodeIfPresent(Bool.self, forKey: .traeAutoCheckin) ?? true
        hideMainIcon = try c.decodeIfPresent(Bool.self, forKey: .hideMainIcon) ?? true
        qianwenTicket = try c.decodeIfPresent(String.self, forKey: .qianwenTicket) ?? ""
        qianwenDecimals = try c.decodeIfPresent(Int.self, forKey: .qianwenDecimals) ?? 1
        cockpitAppId = try c.decodeIfPresent(String.self, forKey: .cockpitAppId) ?? "com.jlcodes.cockpit-tools"
        cockpitAppId = cockpitAppId.isEmpty ? "com.jlcodes.cockpit-tools" : cockpitAppId
        workbuddyAutoCheckin = try c.decodeIfPresent(Bool.self, forKey: .workbuddyAutoCheckin) ?? true
        // 多号账号：过滤掉 token/uid 为空的占位项
        workbuddyAccounts = (try c.decodeIfPresent([WBAccount].self, forKey: .workbuddyAccounts) ?? [])
            .filter { !$0.token.isEmpty && !$0.uid.isEmpty }
    }
}

// MARK: - 加载 / 保存

enum ConfigStore {
    /// 优先 .app 同目录（用户可编辑），其次 Resources 内置默认值。
    static func load() -> AppConfig {
        let parentConfig = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("config.json")
        let resConfig = Bundle.main.url(forResource: "config", withExtension: "json")
        let url: URL
        if FileManager.default.fileExists(atPath: parentConfig.path) {
            url = parentConfig
        } else if let res = resConfig {
            url = res
        } else {
            var cfg = AppConfig()
            if cfg.traeStoragePath.isEmpty { cfg.traeStoragePath = detectTraeStoragePath() }
            return cfg
        }
        var cfg = AppConfig()
        if let data = try? Data(contentsOf: url),
           let cfg2 = try? JSONDecoder().decode(AppConfig.self, from: data) {
            cfg = cfg2
        }
        if cfg.traeStoragePath.isEmpty { cfg.traeStoragePath = detectTraeStoragePath() }
        return cfg
    }

    /// 写回 .app 同目录的 config.json（用户编辑这份）。Codable 序列化，弃用字段不再落盘。
    static func save(_ config: AppConfig) {
        let parentURL = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("config.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? encoder.encode(config) else { return }
        try? out.write(to: parentURL, options: [.atomic])
    }
}

/// 自动探测 TRAE storage.json 路径。
/// 扫描 ~/Library/Application Support/ 下以 "TRAE" 开头的目录，
/// 检查是否存在 User/globalStorage/storage.json，返回第一个匹配。
func detectTraeStoragePath() -> String {
    let appSupport = NSHomeDirectory() + "/Library/Application Support"
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: appSupport) else {
        return ""
    }
    let candidates = entries.filter { $0.lowercased().hasPrefix("trae") }.sorted()
    for dir in candidates {
        let path = "\(appSupport)/\(dir)/User/globalStorage/storage.json"
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    return ""
}

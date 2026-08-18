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

// MARK: - TRAE 多号账号

/// TRAE 多号账号：采集自 storage.json 的加密块 + uid/username。
/// 切换时把 encryptedAuthInfo 写回 storage.json + 重启 TRAE。
struct TraeAccount: Codable, Equatable {
    var uid: String
    var username: String
    var encryptedAuthInfo: String   // 原始 base64 加密块（iCubeAuthInfo://icube.cloudide）

    enum CodingKeys: String, CodingKey {
        case uid, username
        case encryptedAuthInfo = "auth_info"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        encryptedAuthInfo = try c.decodeIfPresent(String.self, forKey: .encryptedAuthInfo) ?? ""
    }

    init(uid: String, username: String, encryptedAuthInfo: String) {
        self.uid = uid
        self.username = username.isEmpty ? uid : username
        self.encryptedAuthInfo = encryptedAuthInfo
    }
}

// MARK: - ZCode 多号账号

/// ZCode（智谱 Coding Plan）账号：导入自 ~/.zcode/v2/config.json 的明文 apiKey（JWT）。
/// uid 为 JWT payload 中的 user_id；token 用于 billing/balance 余额查询。
/// nickname 为用户自定义昵称（导入时填写）；平台无昵称 API，留空时显示 uid 尾号。
struct ZCodeAccount: Codable, Equatable {
    var uid: String
    var token: String
    var nickname: String = ""

    init(uid: String, token: String, nickname: String = "") {
        self.uid = uid
        self.token = token
        self.nickname = nickname
    }

    /// 展示名：自定义昵称优先，未设置时用 uid 尾 4 位
    var displayName: String {
        nickname.isEmpty ? "…" + uid.suffix(4) : nickname
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
    }
}

// MARK: - Codex 多号账号

/// Codex Desktop 本机 auth.json 中的登录账号。token 仅用于调用 usage 接口，昵称固定使用邮箱。
struct CodexAccount: Codable, Equatable {
    var uid: String
    var token: String
    var email: String

    init(uid: String, token: String, email: String) {
        self.uid = uid
        self.token = token
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
    }
}

// MARK: - 应用配置

struct AppConfig: Codable {
    var deepseekApiKey: String = ""
    var deepseekCommonQuota: Double = 0  // DeepSeek 常用充值额度（0=未设置，不显示点阵）
    var refreshInterval: TimeInterval = 300
    var workbuddyDecimals: Int = 2
    var traeStoragePath: String = ""
    var traeDecimals: Int = 0
    var workbuddyEnabled: Bool = true
    var traeAutoCheckin: Bool = true
    var hideWbNickname: Bool = true
    /// 面板背景渐变开关：true = 顶部暗 → 底部中灰纵向渐变；false = 恢复单色近黑遮罩
    var panelGradientEnabled: Bool = true
    var cockpitAppId: String = "com.jlcodes.cockpit-tools"
    var workbuddyAutoCheckin: Bool = true
    var workbuddyAccounts: [WBAccount] = []
    var traeAccounts: [TraeAccount] = []
    var zcodeAccounts: [ZCodeAccount] = []
    var codexAccounts: [CodexAccount] = []
    /// 菜单栏条目可见性：key 格式见 MenuBarItemId，value=true 显示、false 隐藏；
    /// 未显式记录的条目使用默认值（主账号默认显示，非主账号默认隐藏，ZCode 默认隐藏）。
    var menuBarVisible: [String: Bool] = [:]

    enum CodingKeys: String, CodingKey {
        case deepseekApiKey = "deepseek_api_key"
        case deepseekCommonQuota = "deepseek_common_quota"
        case refreshInterval = "refresh_interval"
        case workbuddyDecimals = "workbuddy_decimals"
        case traeStoragePath = "trae_storage_path"
        case traeDecimals = "trae_decimals"
        case workbuddyEnabled = "workbuddy_enabled"
        case traeAutoCheckin = "trae_auto_checkin"
        case hideWbNickname = "hide_wb_nickname"
        case panelGradientEnabled = "panel_gradient_enabled"
        case cockpitAppId = "cockpit_app_id"
        case workbuddyAutoCheckin = "workbuddy_auto_checkin"
        case workbuddyAccounts = "workbuddy_accounts"
        case traeAccounts = "trae_accounts"
        case zcodeAccounts = "zcode_accounts"
        case codexAccounts = "codex_accounts"
        case menuBarVisible = "menubar_visible"
    }

    // 仅解码用的 legacy 字段（旧版统一 "decimals"，新版按服务拆分；读取兼容两者）
    private enum LegacyKeys: String, CodingKey { case decimals }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(Int.self, forKey: .decimals)

        deepseekApiKey = try c.decodeIfPresent(String.self, forKey: .deepseekApiKey) ?? ""
        deepseekCommonQuota = try c.decodeIfPresent(Double.self, forKey: .deepseekCommonQuota) ?? 0
        // refresh_interval 兼容 Double/Int（TimeInterval 解码数字字面量均 OK）
        refreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 300
        workbuddyDecimals = try c.decodeIfPresent(Int.self, forKey: .workbuddyDecimals) ?? legacy ?? 2
        traeStoragePath = try c.decodeIfPresent(String.self, forKey: .traeStoragePath) ?? ""
        traeDecimals = try c.decodeIfPresent(Int.self, forKey: .traeDecimals) ?? 0
        workbuddyEnabled = try c.decodeIfPresent(Bool.self, forKey: .workbuddyEnabled) ?? true
        traeAutoCheckin = try c.decodeIfPresent(Bool.self, forKey: .traeAutoCheckin) ?? true
        hideWbNickname = try c.decodeIfPresent(Bool.self, forKey: .hideWbNickname) ?? true
        panelGradientEnabled = try c.decodeIfPresent(Bool.self, forKey: .panelGradientEnabled) ?? true
        cockpitAppId = try c.decodeIfPresent(String.self, forKey: .cockpitAppId) ?? "com.jlcodes.cockpit-tools"
        cockpitAppId = cockpitAppId.isEmpty ? "com.jlcodes.cockpit-tools" : cockpitAppId
        workbuddyAutoCheckin = try c.decodeIfPresent(Bool.self, forKey: .workbuddyAutoCheckin) ?? true
        // 多号账号：过滤掉 token/uid 为空的占位项
        workbuddyAccounts = (try c.decodeIfPresent([WBAccount].self, forKey: .workbuddyAccounts) ?? [])
            .filter { !$0.token.isEmpty && !$0.uid.isEmpty }
        // TRAE 多号账号：过滤掉 uid/authInfo 为空的占位项
        traeAccounts = (try c.decodeIfPresent([TraeAccount].self, forKey: .traeAccounts) ?? [])
            .filter { !$0.uid.isEmpty && !$0.encryptedAuthInfo.isEmpty }
        // ZCode 多号账号：过滤掉 uid/token 为空的占位项
        zcodeAccounts = (try c.decodeIfPresent([ZCodeAccount].self, forKey: .zcodeAccounts) ?? [])
            .filter { !$0.uid.isEmpty && !$0.token.isEmpty }
        codexAccounts = (try c.decodeIfPresent([CodexAccount].self, forKey: .codexAccounts) ?? [])
            .filter { !$0.uid.isEmpty && !$0.token.isEmpty && !$0.email.isEmpty }
        // 菜单栏条目可见性（缺省为空字典，未记录的条目走默认值逻辑）
        menuBarVisible = try c.decodeIfPresent([String: Bool].self, forKey: .menuBarVisible) ?? [:]
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

/// UserDefaults key 收口：签到相关 key 的拼接统一走这里，避免字符串字面量散落各处。
/// ⚠️ 字符串格式与历史版本必须完全一致，否则已落盘的签到日期/连签/历史数据会失联。
enum UDKey {
    // WorkBuddy 签到（per-uid）
    static func wbCheckinDate(_ uid: String) -> String { "wb_checkin_date_\(uid)" }
    static func wbCheckinStreak(_ uid: String) -> String { "wb_checkin_streak_\(uid)" }
    static func wbCheckinReward(_ uid: String) -> String { "wb_checkin_reward_\(uid)" }
    /// claim 失败标记（Bool）
    static func wbCheckinFailed(_ uid: String) -> String { "wb_checkin_failed_\(uid)" }
    static func wbCheckinFailDate(_ uid: String) -> String { "wb_checkin_failed_date_\(uid)" }
    static func wbCheckinHistory(_ uid: String) -> String { "wb_checkin_history_\(uid)" }
    /// 错峰就绪时间戳（"日期|秒级时间戳"）
    static func wbCheckinReady(_ uid: String) -> String { "wb_checkin_ready_\(uid)" }
    static var wbLastCheckinTime: String { "wb_last_checkin_time" }
    static var wbStatusFillDate: String { "wb_status_fill_date" }

    // TRAE 签到（per-uid）
    static func traeCheckinDate(_ uid: String) -> String { "trae_checkin_date_\(uid)" }
    static func traeCheckinStreak(_ uid: String) -> String { "trae_checkin_streak_\(uid)" }
    static func traeCheckinReward(_ uid: String) -> String { "trae_checkin_reward_\(uid)" }
    static func traeCheckinFailDate(_ uid: String) -> String { "trae_checkin_failed_date_\(uid)" }
    static func traeCheckinHistory(_ uid: String) -> String { "trae_checkin_history_\(uid)" }
    static func traeLastCheckinTime(_ uid: String) -> String { "trae_last_checkin_time_\(uid)" }
    /// status 接口连续失败计数（递增退避用）
    static func traeStatusFailCount(_ uid: String) -> String { "trae_status_fail_count_\(uid)" }
    static func traeCheckinReady(_ uid: String) -> String { "trae_checkin_ready_\(uid)" }
    /// claim 失败标记（Bool）
    static func traeCheckinFailed(_ uid: String) -> String { "trae_checkin_failed_\(uid)" }
    /// claim 失败后的下次重试时间（Date）
    static func traeNextRetryTime(_ uid: String) -> String { "trae_next_retry_time_\(uid)" }
    /// status 查询失败后的退避截止时间（Date）
    static func traeStatusRetry(_ uid: String) -> String { "trae_status_retry_\(uid)" }
    static var traeStatusFillDate: String { "trae_status_fill_date" }

    // 面板区块折叠状态（Bool，设置/操作标题胶囊点击切换）
    static var settingsSectionCollapsed: String { "panel_settings_section_collapsed" }
    static var actionsSectionCollapsed: String { "panel_actions_section_collapsed" }
}

/// 余额数值快照的磁盘缓存（cache-then-refresh）：启动时先显示上次数值再等网络刷新。
/// 只存数值与更新时间，不含任何凭据/ token；文件为 .app 同目录 cache.json。
struct BalanceCache: Codable {
    struct DsAmount: Codable { let symbol: String, totalRaw: String, total: Double }
    struct WbAmount: Codable { let remain: Double, total: Double }
    struct TraeAmount: Codable { let limit: Double, used: Double }
    struct ZcodeAmount: Codable { let remain: Double, total: Double, planEndsAt: TimeInterval }
    struct CodexAmount: Codable { let usedPercent: Double, resetAt: TimeInterval }

    var ds: DsAmount?
    var wb: WbAmount?
    var wbAccounts: [String: WbAmount] = [:]
    var traeAccounts: [String: TraeAmount] = [:]
    var zcodeAccounts: [String: ZcodeAmount] = [:]
    var codexAccounts: [String: CodexAmount] = [:]
    /// 面板 footer「更新于」时间（HH:mm:ss）
    var lastUpdatedAt: String = ""
    /// 上次刷新完成时刻（秒级时间戳）：恢复面板打开的 <1min 自动刷新节流
    var lastRefreshTime: TimeInterval = 0
}

enum BalanceCacheStore {
    static var cacheURL: URL {
        URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("cache.json")
    }

    /// 读取上次会话的数值缓存；无文件或解码失败返回 nil（维持首启行为）
    static func load() -> BalanceCache? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(BalanceCache.self, from: data) else { return nil }
        return cache
    }

    /// 原子写回（与 ConfigStore.save 同一套约定）
    static func save(_ cache: BalanceCache) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? encoder.encode(cache) else { return }
        try? out.write(to: cacheURL, options: [.atomic])
    }
}

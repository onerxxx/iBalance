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

/// Codex Desktop 本机 auth.json 中的登录账号。
/// refreshToken/idToken 用于切号后恢复完整登录态；旧配置缺失时仍兼容只使用 access token。
struct CodexAccount: Codable, Equatable {
    var uid: String
    var token: String
    var email: String
    var refreshToken: String
    var idToken: String

    init(uid: String, token: String, email: String,
         refreshToken: String = "", idToken: String = "") {
        self.uid = uid
        self.token = token
        self.email = email
        self.refreshToken = refreshToken
        self.idToken = idToken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        idToken = try c.decodeIfPresent(String.self, forKey: .idToken) ?? ""
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
    /// 各平台独立刷新开关。WorkBuddy 沿用历史字段 workbuddyEnabled，保持旧配置兼容。
    var deepseekRefreshEnabled: Bool = true
    var traeRefreshEnabled: Bool = true
    var zcodeRefreshEnabled: Bool = true
    var codexRefreshEnabled: Bool = true
    var workbuddyEnabled: Bool = true
    var traeAutoCheckin: Bool = true
    var hideWbNickname: Bool = false  // 已固化为默认显示（悬停时淡入），保留字段兼容旧配置
    /// 面板背景渐变开关：true = 顶部暗 → 底部中灰纵向渐变；false = 恢复单色近黑遮罩
    var panelGradientEnabled: Bool = true
    /// Mono 字体开关：true = 余额卡片与用量列表使用 DepartureMono（拉丁字符），
    /// 缺字（中文等）通过 cascade 级联回退系统字体
    var monoFontEnabled: Bool = false
    /// 调试用量开关：开启后用量区显示本地生成的七日样例数据，不读取真实用量。
    var debugUsageEnabled: Bool = false
    /// 滚动提示层（顶/底 ScrollFadeHint）参数（已固化，config.json 可覆盖）
    var fadeHintBandHeight: Double = 54
    var fadeHintHighlightAlpha: Double = -0.6
    var fadeHintMaskMidAlpha: Double = 0.45
    var fadeHintArrowAlpha: Double = 0.75
    var fadeHintBobAmplitude: Double = 2
    var cockpitAppId: String = "com.jlcodes.cockpit-tools"
    var workbuddyAutoCheckin: Bool = true
    var workbuddyAccounts: [WBAccount] = []
    var traeAccounts: [TraeAccount] = []
    var zcodeAccounts: [ZCodeAccount] = []
    var codexAccounts: [CodexAccount] = []
    /// 菜单栏条目可见性：key 格式见 MenuBarItemId，value=true 显示、false 隐藏；
    /// 未显式记录的条目使用默认值（主账号默认显示，非主账号默认隐藏，ZCode 默认隐藏）。
    var menuBarVisible: [String: Bool] = [:]
    /// 面板余额卡片可见性：key = 平台 ID（"ds" / "zcode" / "codex" / "trae" / "wb"），
    /// value=true 显示、false 隐藏；未记录的平台默认显示（true）。
    /// 空账号组（如 ZCode 未导入）即使设为 true 也维持隐藏，不产生空白占位。
    var panelCardVisible: [String: Bool] = [:]
    /// 置顶浮窗尺寸（用户 resize 把手结果，跨 pin 会话/重启保留；
    /// 0 = 未记录，pin 时按面板当前尺寸）
    var floatingPanelWidth: Double = 0
    var floatingPanelHeight: Double = 0

    enum CodingKeys: String, CodingKey {
        case deepseekApiKey = "deepseek_api_key"
        case deepseekCommonQuota = "deepseek_common_quota"
        case refreshInterval = "refresh_interval"
        case workbuddyDecimals = "workbuddy_decimals"
        case traeStoragePath = "trae_storage_path"
        case traeDecimals = "trae_decimals"
        case deepseekRefreshEnabled = "deepseek_refresh_enabled"
        case traeRefreshEnabled = "trae_refresh_enabled"
        case zcodeRefreshEnabled = "zcode_refresh_enabled"
        case codexRefreshEnabled = "codex_refresh_enabled"
        case workbuddyEnabled = "workbuddy_enabled"
        case traeAutoCheckin = "trae_auto_checkin"
        case hideWbNickname = "hide_wb_nickname"
        case panelGradientEnabled = "panel_gradient_enabled"
        case monoFontEnabled = "mono_font_enabled"
        case debugUsageEnabled = "debug_usage_enabled"
        case fadeHintBandHeight = "fade_hint_band_height"
        case fadeHintHighlightAlpha = "fade_hint_highlight_alpha"
        case fadeHintMaskMidAlpha = "fade_hint_mask_mid_alpha"
        case fadeHintArrowAlpha = "fade_hint_arrow_alpha"
        case fadeHintBobAmplitude = "fade_hint_bob_amplitude"
        case cockpitAppId = "cockpit_app_id"
        case workbuddyAutoCheckin = "workbuddy_auto_checkin"
        case workbuddyAccounts = "workbuddy_accounts"
        case traeAccounts = "trae_accounts"
        case zcodeAccounts = "zcode_accounts"
        case codexAccounts = "codex_accounts"
        case menuBarVisible = "menubar_visible"
        case panelCardVisible = "panel_card_visible"
        case floatingPanelWidth = "floating_panel_width"
        case floatingPanelHeight = "floating_panel_height"
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
        deepseekRefreshEnabled = try c.decodeIfPresent(Bool.self, forKey: .deepseekRefreshEnabled) ?? true
        traeRefreshEnabled = try c.decodeIfPresent(Bool.self, forKey: .traeRefreshEnabled) ?? true
        zcodeRefreshEnabled = try c.decodeIfPresent(Bool.self, forKey: .zcodeRefreshEnabled) ?? true
        codexRefreshEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexRefreshEnabled) ?? true
        workbuddyEnabled = try c.decodeIfPresent(Bool.self, forKey: .workbuddyEnabled) ?? true
        traeAutoCheckin = try c.decodeIfPresent(Bool.self, forKey: .traeAutoCheckin) ?? true
        hideWbNickname = try c.decodeIfPresent(Bool.self, forKey: .hideWbNickname) ?? false
        panelGradientEnabled = try c.decodeIfPresent(Bool.self, forKey: .panelGradientEnabled) ?? true
        monoFontEnabled = try c.decodeIfPresent(Bool.self, forKey: .monoFontEnabled) ?? false
        debugUsageEnabled = try c.decodeIfPresent(Bool.self, forKey: .debugUsageEnabled) ?? false
        fadeHintBandHeight = try c.decodeIfPresent(Double.self, forKey: .fadeHintBandHeight) ?? 34
        fadeHintHighlightAlpha = try c.decodeIfPresent(Double.self, forKey: .fadeHintHighlightAlpha) ?? 0.18
        fadeHintMaskMidAlpha = try c.decodeIfPresent(Double.self, forKey: .fadeHintMaskMidAlpha) ?? 0.55
        fadeHintArrowAlpha = try c.decodeIfPresent(Double.self, forKey: .fadeHintArrowAlpha) ?? 0.8
        fadeHintBobAmplitude = try c.decodeIfPresent(Double.self, forKey: .fadeHintBobAmplitude) ?? 2.6
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
        // 面板余额卡片可见性（缺省为空字典，未记录的平台默认显示）
        panelCardVisible = try c.decodeIfPresent([String: Bool].self, forKey: .panelCardVisible) ?? [:]
        floatingPanelWidth = try c.decodeIfPresent(Double.self, forKey: .floatingPanelWidth) ?? 0
        floatingPanelHeight = try c.decodeIfPresent(Double.self, forKey: .floatingPanelHeight) ?? 0
    }
}

// MARK: - 加载 / 保存

/// 应用在用户目录中的持久化数据位置。
/// 配置和缓存不放在 .app 旁边，避免移动或更新 App 时丢失用户数据。
enum AppDataStore {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.local.ibalance"

    static var applicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var configURL: URL {
        applicationSupportURL.appendingPathComponent("config.json")
    }

    static var cacheURL: URL {
        applicationSupportURL.appendingPathComponent("cache.json")
    }

    static var usageURL: URL {
        applicationSupportURL.appendingPathComponent("usage.json")
    }

    /// 旧版本把文件放在 .app 同目录；只在新位置没有对应文件时复制一次。
    static func legacyURL(for filename: String) -> URL {
        URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent(filename)
    }

    static func prepareDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        // 配置包含 API Key / token，目录只允许当前用户访问。
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationSupportURL.path)
    }

    /// 将旧版同目录文件迁移到 Application Support，保留旧文件作为可恢复副本。
    @discardableResult
    static func migrateIfNeeded(filename: String) -> Bool {
        let destination: URL
        switch filename {
        case "config.json": destination = configURL
        case "cache.json": destination = cacheURL
        case "usage.json": destination = usageURL
        default: return false
        }
        let source = legacyURL(for: filename)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
              fm.fileExists(atPath: source.path) else { return false }
        prepareDirectory()
        do {
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch {
            return false
        }
    }

    static func secureWrite(_ data: Data, to url: URL) {
        prepareDirectory()
        guard (try? data.write(to: url, options: [.atomic])) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ConfigStore {
    /// 优先 Application Support 中的用户配置，其次迁移旧版同目录配置，最后使用 Resources 默认值。
    static func load() -> AppConfig {
        AppDataStore.prepareDirectory()
        AppDataStore.migrateIfNeeded(filename: "config.json")
        let resConfig = Bundle.main.url(forResource: "config", withExtension: "json")
        let url = FileManager.default.fileExists(atPath: AppDataStore.configURL.path)
            ? AppDataStore.configURL
            : resConfig
        var cfg = AppConfig()
        var shouldPersist = false
        if let url,
           let data = try? Data(contentsOf: url),
           let cfg2 = try? JSONDecoder().decode(AppConfig.self, from: data) {
            cfg = cfg2
            // 首次使用 Resources 默认配置时也落到稳定路径，后续更新 App 不会覆盖用户设置。
            shouldPersist = url != AppDataStore.configURL
        }
        if cfg.traeStoragePath.isEmpty { cfg.traeStoragePath = detectTraeStoragePath() }
        if shouldPersist { save(cfg) }
        return cfg
    }

    /// 写回 Application Support 中的 config.json。Codable 序列化，弃用字段不再落盘。
    static func save(_ config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? encoder.encode(config) else { return }
        AppDataStore.secureWrite(out, to: AppDataStore.configURL)
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
    /// 当日风控标记（claim 返回 9074/操作太频繁 → 角标橙黄、统计计「风控」不计「失败」）
    static func traeCheckinRiskDate(_ uid: String) -> String { "trae_checkin_risk_date_\(uid)" }
    /// 风控日手动重试计数（"日期|次数"；手动签到对风控账号放行 claim 的每日额度）
    static func traeManualRetryCount(_ uid: String) -> String { "trae_manual_retry_count_\(uid)" }
    /// claim 失败后的下次重试时间（Date）
    static func traeNextRetryTime(_ uid: String) -> String { "trae_next_retry_time_\(uid)" }
    /// status 查询失败后的退避截止时间（Date）
    static func traeStatusRetry(_ uid: String) -> String { "trae_status_retry_\(uid)" }
    static var traeStatusFillDate: String { "trae_status_fill_date" }

    // 面板区块折叠状态（Bool，设置/操作标题胶囊点击切换）
    static var settingsSectionCollapsed: String { "panel_settings_section_collapsed" }
    static var actionsSectionCollapsed: String { "panel_actions_section_collapsed" }
    static var usageSectionCollapsed: String { "panel_usage_section_collapsed" }
    /// 余额平台卡片的显示顺序（[String]，由面板拖拽更新）
    static var balancePlatformOrder: String { "panel_balance_platform_order" }
}

/// 余额数值快照的磁盘缓存（cache-then-refresh）：启动时先显示上次数值再等网络刷新。
/// 只存数值与更新时间，不含任何凭据/ token；文件位于 Application Support。
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
    /// 读取上次会话的数值缓存；无文件或解码失败返回 nil（维持首启行为）
    static func load() -> BalanceCache? {
        AppDataStore.prepareDirectory()
        AppDataStore.migrateIfNeeded(filename: "cache.json")
        let cacheURL = AppDataStore.cacheURL
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(BalanceCache.self, from: data) else { return nil }
        return cache
    }

    /// 原子写回（与 ConfigStore.save 同一套约定）
    static func save(_ cache: BalanceCache) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? encoder.encode(cache) else { return }
        AppDataStore.secureWrite(out, to: AppDataStore.cacheURL)
    }
}

// MARK: - 日/周用量基线（本地差值，不依赖平台用量 API）

/// 每平台+账号记录「当日首观 / 当周首观」基线值，用量 = 基线与当前余额的差值。
/// increasing=false：数值随消耗下降（余额/剩余，如 DeepSeek/WorkBuddy/ZCode）；
/// increasing=true：数值随消耗上升（已用，如 TRAE used / Codex usedPercent）。
struct UsageBaselines: Codable {
    struct Entry: Codable {
        var dayKey: String
        var dayBase: Double
        var weekKey: String
        var weekBase: Double
        /// 当天累计用量快照：yyyy-MM-dd → 用量；保留最近 60 天用于趋势统计。
        var dailyUsage: [String: Double]

        private enum CodingKeys: String, CodingKey {
            case dayKey, dayBase, weekKey, weekBase, dailyUsage
        }

        init(dayKey: String, dayBase: Double, weekKey: String, weekBase: Double) {
            self.dayKey = dayKey
            self.dayBase = dayBase
            self.weekKey = weekKey
            self.weekBase = weekBase
            self.dailyUsage = [:]
        }

        /// 兼容旧版 usage.json：历史字段不存在时从空记录开始累计。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dayKey = try c.decode(String.self, forKey: .dayKey)
            dayBase = try c.decode(Double.self, forKey: .dayBase)
            weekKey = try c.decode(String.self, forKey: .weekKey)
            weekBase = try c.decode(Double.self, forKey: .weekBase)
            dailyUsage = try c.decodeIfPresent([String: Double].self, forKey: .dailyUsage) ?? [:]
        }
    }
    var entries: [String: Entry] = [:]
}

enum UsageStore {
    private static var memory: UsageBaselines = load()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 周一起始的周 key（与国内习惯一致）
    private static func weekKey(for date: Date) -> String {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return dayFormatter.string(from: start)
    }

    private static func load() -> UsageBaselines {
        AppDataStore.prepareDirectory()
        AppDataStore.migrateIfNeeded(filename: "usage.json")
        guard let data = try? Data(contentsOf: AppDataStore.usageURL),
              let s = try? JSONDecoder().decode(UsageBaselines.self, from: data) else { return UsageBaselines() }
        return s
    }

    private static func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? encoder.encode(memory) else { return }
        AppDataStore.secureWrite(out, to: AppDataStore.usageURL)
    }

    /// 记录一次观测：跨天/跨周重置基线为当前值；充值（余额型）或重置（已用型）时校准基线，保证用量 ≥ 0。
    static func observe(platform: String, uid: String, value: Double, increasing: Bool) {
        let key = "\(platform):\(uid)"
        let now = Date()
        let dk = dayFormatter.string(from: now)
        let wk = weekKey(for: now)
        var e = memory.entries[key] ?? UsageBaselines.Entry(dayKey: dk, dayBase: value, weekKey: wk, weekBase: value)
        var changed = memory.entries[key] == nil
        if e.dayKey != dk {
            e.dayKey = dk
            e.dayBase = value
            changed = true
        } else {
            let todayUsage = increasing ? max(0, value - e.dayBase) : max(0, e.dayBase - value)
            if todayUsage > (e.dailyUsage[dk] ?? 0) {
                e.dailyUsage[dk] = todayUsage
                changed = true
            }
            // 余额充值/额度重置时校准基线，但保留当天已经记录过的最大用量。
            if increasing ? value < e.dayBase : value > e.dayBase {
                e.dayBase = value
                changed = true
            }
        }
        if e.weekKey != wk { e.weekKey = wk; e.weekBase = value; changed = true }
        else if increasing ? value < e.weekBase : value > e.weekBase { e.weekBase = value; changed = true }
        // 控制 usage.json 体积；保留最近 60 天的各平台/账号用量历史。
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        let cutoffKey = dayFormatter.string(from: cutoff)
        let trimmed = e.dailyUsage.filter { $0.key >= cutoffKey }
        if trimmed.count != e.dailyUsage.count {
            e.dailyUsage = trimmed
            changed = true
        }
        memory.entries[key] = e
        if changed { save() }
    }

    /// 当前日/周用量；从未观测过的账号返回 nil（行不显示）。
    /// 跨天/跨周后尚未刷新时返回宽限值（今天 0 / 本周 0）而非 nil——
    /// 否则 0 点后到下次成功刷新前，所有用量行判定为无数据，整个板块会消失。
    static func usage(platform: String, uid: String, current: Double, increasing: Bool) -> (today: Double, week: Double)? {
        guard let e = memory.entries["\(platform):\(uid)"] else { return nil }
        let now = Date()
        let today = e.dayKey == dayFormatter.string(from: now)
            ? (increasing ? max(0, current - e.dayBase) : max(0, e.dayBase - current))
            : 0
        let week = e.weekKey == weekKey(for: now)
            ? (increasing ? max(0, current - e.weekBase) : max(0, e.weekBase - current))
            : 0
        return (today, week)
    }

    /// 返回本周一至周日的每日用量；尚未观测的日期用 0 填充，兼容旧版无历史记录的数据。
    static func weeklyUsage(platform: String, uid: String) -> [Double] {
        guard let e = memory.entries["\(platform):\(uid)"] else {
            return Array(repeating: 0, count: 7)
        }
        let now = Date()
        guard e.weekKey == weekKey(for: now) else {
            return Array(repeating: 0, count: 7)
        }
        var cal = Calendar.current
        cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return (0..<7).map { offset in
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { return 0 }
            return e.dailyUsage[dayFormatter.string(from: date)] ?? 0
        }
    }

    /// 平台级汇总：全部账号的今日/本周用量对应相加（差值按账号独立计算后求和，
    /// 余额型/已用型/百分比口径不受影响）。任一账号有观测记录即返回，全部无记录返回 nil。
    static func usage(platform: String, accounts: [(uid: String, current: Double)],
                      increasing: Bool) -> (today: Double, week: Double)? {
        var today: Double = 0
        var week: Double = 0
        var any = false
        for a in accounts where !a.uid.isEmpty {
            guard let u = usage(platform: platform, uid: a.uid, current: a.current, increasing: increasing) else { continue }
            any = true
            today += u.today
            week += u.week
        }
        return any ? (today, week) : nil
    }

    /// 平台级汇总：全部账号本周每日用量对应相加，无记录账号贡献 0
    static func weeklyUsage(platform: String, uids: [String]) -> [Double] {
        var sum = Array(repeating: Double.zero, count: 7)
        for uid in uids where !uid.isEmpty {
            let daily = weeklyUsage(platform: platform, uid: uid)
            for i in 0..<7 where i < daily.count { sum[i] += daily[i] }
        }
        return sum
    }
}

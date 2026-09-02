// Codex.swift — 从官方 Codex 凭据存储（auth.json + macOS Keychain）
// 导入登录账号、解析 JWT 身份并读取 Codex usage。
// 导入逻辑对齐 cockpit-tools-main：
//   1. 支持 CODEX_HOME 环境变量，默认为 ~/.codex；
//   2. 凭据存储模式读取 ~/.codex/config.toml 的 cli_auth_credentials_store
//      （keyring / auto = 优先 Keychain，file / 未配置 = 优先 auth.json）；
//   3. 身份解析 id_token 优先（profile_data.email），再回退 access_token；
//      chatgpt_user_id / account_id / organization_id 均取自 auth_data 权威键。
//   4. 切号时保持原样写 auth.json，并同步写入 keychain 条目（若当前已启用 keychain）。
import Foundation
import Security
import CommonCrypto

enum CodexImportResult {
    case success(CodexAccount)
    case failure(String)
}

// MARK: - 凭据存储模式
private enum CodexAuthStoreMode: String {
    case file
    case keyring
    case auto
}

private struct CodexOAuthSnapshot {
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let accountIdFromAuthFile: String?
}

private struct CodexIdentity {
    let email: String
    let userId: String?
    let accountId: String?
    let organizationId: String?
}

private struct CodexAuthFileTokens {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?
    let accountId: String?
}

private struct CodexAuthFileDoc {
    let authMode: String?
    let tokens: CodexAuthFileTokens?
    let personalAccessToken: String?
}

enum CodexService {
    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private static let keychainService = "Codex Auth"
    private static let configCredentialsKey = "cli_auth_credentials_store"
    private static let apiKeyAuthMode = "apikey"

    // MARK: - Path helpers

    private static var codexHome: URL { resolveDefaultCodexHome() }
    private static var authPath: URL { codexHome.appendingPathComponent("auth.json") }
    private static var configTomlPath: URL { codexHome.appendingPathComponent("config.toml") }

    /// 默认 CODEX_HOME：优先 CODEX_HOME env；否则 ~/.codex。
    private static func resolveDefaultCodexHome() -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = env.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    private static func authPath(for home: URL) -> URL { home.appendingPathComponent("auth.json") }
    private static func configTomlPath(for home: URL) -> URL { home.appendingPathComponent("config.toml") }

    // MARK: - Public: 导入当前 Codex 账号（默认 home 单账号）

    /// Codex CLI/Desktop 的登录态是 auth.json 或 macOS Keychain；只读取，不修改原文件。
    static func importCurrentAccount() -> CodexImportResult {
        importAccount(at: resolveDefaultCodexHome())
    }

    static func currentUid() -> String? {
        guard case .success(let account) = importCurrentAccount() else { return nil }
        return account.uid
    }

    // MARK: - Public: 批量扫描 & 导入可发现账号（对齐 cockpit-tools-main：默认 home + 实例 + 运行态 + 受管 homes）

    struct CodexBatchImportResult {
        let added: [CodexAccount]            // 新加入的账号
        let refreshed: [CodexAccount]        // 已存在但凭据被刷新
        let skippedErrors: [String]          // 目录扫描/解析错误日志
    }

    /// 枚举本机所有可能的 Codex home 目录，逐个调用 importAccount 导入，
    /// 去重后返回：新增 / 已存在刷新 / 错误明细。用于「添加账号」按钮触发发现多账号。
    static func importDiscoverableAccounts(existingUids: Set<String>) -> CodexBatchImportResult {
        let dirs = discoverCandidateHomeDirectories()
        var added: [CodexAccount] = []
        var refreshed: [CodexAccount] = []
        var errors: [String] = []
        var seenUid: Set<String> = []

        for home in dirs {
            switch importAccount(at: home) {
            case .success(let account):
                if seenUid.contains(account.uid) { continue }
                seenUid.insert(account.uid)
                if existingUids.contains(account.uid) {
                    refreshed.append(account)
                } else {
                    added.append(account)
                }
            case .failure(let msg):
                // 过滤掉"空目录/无凭据"这种非错误
                if !isNonCredentialError(msg) {
                    errors.append("\((home.path as NSString).abbreviatingWithTildeInPath)：\(msg)")
                }
            }
        }
        return CodexBatchImportResult(added: added, refreshed: refreshed, skippedErrors: errors)
    }

    /// 刷新失败时按 UID 扫描本机候选 Codex home，读取该账号的最新 auth.json/钥匙串凭据。
    /// 仅返回新导入的内存对象，不修改 Codex 原目录；调用方决定是否写入 iBalance 配置。
    static func reimportAccount(uid: String) -> CodexAccount? {
        var seenPaths: Set<String> = []
        for home in discoverCandidateHomeDirectories() {
            let path = home.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            guard case .success(let account) = importAccount(at: home), account.uid == uid else { continue }
            return account
        }
        return nil
    }

    // MARK: - 单 home 导入（可传任意 base_dir）

    private static func importAccount(at home: URL) -> CodexImportResult {
        // 1) 读取 auth.json
        let (authFile, _) = readAuthFile(at: home)

        // 2) API Key 模式：尝试 personal_access_token；否则报错
        if let authFile, isApiKeyMode(authFile.authMode) {
            if let pat = authFile.personalAccessToken, !pat.isEmpty {
                return importFromPersonalAccessToken(pat)
            }
            return .failure("凭据为 API Key 模式，仅支持 OAuth 账号导入")
        }

        let storeMode = resolveCredentialsStoreMode(for: home)

        // 3) file snapshot
        var fileSnapshot: CodexOAuthSnapshot? = nil
        if let authFile, let tok = authFile.tokens,
           let access = tok.accessToken, !access.isEmpty {
            fileSnapshot = CodexOAuthSnapshot(
                idToken: tok.idToken ?? "",
                accessToken: access,
                refreshToken: tok.refreshToken ?? "",
                accountIdFromAuthFile: tok.accountId
            )
        }

        // 4) keychain snapshot（可能返回 OAuth / PAT）
        var keychainSnapshot: CodexOAuthSnapshot? = nil
        var keychainPatFallback: String? = nil
        let prefersKeychain = (storeMode == .keyring || storeMode == .auto)
        if prefersKeychain || fileSnapshot == nil {
            if let kc = readKeychainAuthFile(for: home) {
                if !isApiKeyMode(kc.authMode) {
                    if let tok = kc.tokens, let access = tok.accessToken, !access.isEmpty {
                        keychainSnapshot = CodexOAuthSnapshot(
                            idToken: tok.idToken ?? "",
                            accessToken: access,
                            refreshToken: tok.refreshToken ?? "",
                            accountIdFromAuthFile: tok.accountId
                        )
                    } else if let pat = kc.personalAccessToken, !pat.isEmpty {
                        keychainPatFallback = pat
                    }
                }
            }
        }

        // 5) 优先级选择
        let snapshot: CodexOAuthSnapshot?
        if prefersKeychain {
            snapshot = keychainSnapshot ?? fileSnapshot ?? authFile?.personalAccessToken.flatMap { pat in
                guard !pat.isEmpty else { return nil }
                return CodexOAuthSnapshot(idToken: "", accessToken: pat, refreshToken: "", accountIdFromAuthFile: nil)
            } ?? keychainPatFallback.flatMap { pat in
                CodexOAuthSnapshot(idToken: "", accessToken: pat, refreshToken: "", accountIdFromAuthFile: nil)
            }
        } else {
            snapshot = fileSnapshot ?? keychainSnapshot ?? authFile?.personalAccessToken.flatMap { pat in
                guard !pat.isEmpty else { return nil }
                return CodexOAuthSnapshot(idToken: "", accessToken: pat, refreshToken: "", accountIdFromAuthFile: nil)
            } ?? keychainPatFallback.flatMap { pat in
                CodexOAuthSnapshot(idToken: "", accessToken: pat, refreshToken: "", accountIdFromAuthFile: nil)
            }
        }

        guard let snap = snapshot else {
            return .failure("未找到凭据（auth.json 与钥匙串均为空）")
        }
        guard !snap.accessToken.isEmpty else {
            return .failure("access_token 为空")
        }

        let idInfo = extractIdentity(idToken: snap.idToken, accessToken: snap.accessToken)
        var accountId = trim(snap.accountIdFromAuthFile) ?? idInfo.accountId ?? ""
        if accountId.isEmpty {
            accountId = trim(idInfo.userId) ?? extractSubClaim(snap.accessToken) ?? ""
        }
        let email = trim(idInfo.email) ?? ""

        guard !accountId.isEmpty else { return .failure("无法解析账号 ID") }
        guard !email.isEmpty else { return .failure("无法解析邮箱") }

        return .success(CodexAccount(uid: accountId, token: snap.accessToken, email: email,
                                     refreshToken: snap.refreshToken, idToken: snap.idToken))
    }

    // MARK: Candidate home discovery（对齐 cockpit-tools 多处来源）

    /// 候选目录：默认 home → 实例(user_data_dir) → 运行态 CODEX_HOME → cockpit 受管 homes →
    /// Application Support 下 codex-app-data 子目录 → 其它常见候选。
    private static func discoverCandidateHomeDirectories() -> [URL] {
        var dirs: [URL] = []
        let defaultHome = resolveDefaultCodexHome()
        dirs.append(defaultHome)

        // 1) cockpit-tools 实例：~/.antigravity_cockpit/codex_instances.json
        if let instanceDirs = loadCodexInstanceUserDataDirs() {
            dirs.append(contentsOf: instanceDirs)
        }

        // 2) cockpit 受管 homes：~/.antigravity_cockpit/codex_wakeup_homes/<account_id>
        if let managed = managedCodexHomes() {
            dirs.append(contentsOf: managed)
        }

        // 3) 运行中的 Codex 进程的 CODEX_HOME
        dirs.append(contentsOf: codexHomesFromRunningProcesses())

        // 4) Application Support/codex-app-data 下一级候选
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let support {
            let appDir = support.appendingPathComponent("codex-app-data", isDirectory: true)
            if let subDirs = try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                dirs.append(contentsOf: subDirs.filter { $0.hasDirectoryPath })
            }
        }

        // 5) Home 目录下常见二级候选：.codex*（只加一级、存在 auth.json 或 config.toml 的目录）
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let names = try? FileManager.default.contentsOfDirectory(atPath: home.path) {
            for name in names where name.hasPrefix(".codex") {
                let candidate = home.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else { continue }
                dirs.append(candidate)
            }
        }

        // 去重（standardized path），过滤掉不存在的空目录（保留默认 home 兜底）
        var seen: Set<String> = []
        var result: [URL] = []
        for dir in dirs {
            let std = dir.standardizedFileURL.path
            guard !seen.contains(std) else { continue }
            seen.insert(std)
            let hasAuth = FileManager.default.fileExists(atPath: authPath(for: dir).path)
            let hasCfg = FileManager.default.fileExists(atPath: configTomlPath(for: dir).path)
            // keychain-only 模式可能两者都没有 → 也不排除（keychain 可能仍有对应条目）。
            // 但为了避免扫到太夸张的目录，若目录本身不存在也无 keychain 账号，最后 importAccount 会静默失败。
            if dir == defaultHome || hasAuth || hasCfg {
                result.append(dir)
                continue
            }
            // 对于非默认家目录，若有有效 keychain 条目也加入（否则跳过，避免噪声）
            if readKeychainAuthFile(for: dir) != nil {
                result.append(dir)
            }
        }
        return result
    }

    private static func loadCodexInstanceUserDataDirs() -> [URL]? {
        // 对齐 cockpit-tools: data_dir = $HOME/.antigravity_cockpit(/_dev) + COCKPIT_TOOLS_DATA_DIR env
        let fm = FileManager.default
        if let override = trim(ProcessInfo.processInfo.environment["COCKPIT_TOOLS_DATA_DIR"]) ??
                           trim(ProcessInfo.processInfo.environment["COCKPIT_TOOLS_TEST_DATA_DIR"]) ??
                           trim(ProcessInfo.processInfo.environment["COCKPIT_TEST_DATA_DIR"]) {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if let r = parseCodexInstances(at: url.appendingPathComponent("codex_instances.json")) { return r }
        }
        // dev 优先
        let isDev = trim(ProcessInfo.processInfo.environment["COCKPIT_TOOLS_PROFILE"])?.lowercased() == "dev"
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let devDir = home.appendingPathComponent(".antigravity_cockpit_dev")
        let prodDir = home.appendingPathComponent(".antigravity_cockpit")
        let primary = isDev ? devDir : prodDir
        let fallback = isDev ? prodDir : devDir
        if let r = parseCodexInstances(at: primary.appendingPathComponent("codex_instances.json")) { return r }
        if let r = parseCodexInstances(at: fallback.appendingPathComponent("codex_instances.json")) { return r }
        // App 级：Application Support/*ibundle*/codex_instances.json 兜底（iBalance 自带实例存储）
        let appDir = AppDataStore.applicationSupportURL
        if let r = parseCodexInstances(at: appDir.appendingPathComponent("codex_instances.json")) { return r }
        _ = fm
        return nil
    }

    private static func parseCodexInstances(at fileURL: URL) -> [URL]? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instances = json["instances"] as? [[String: Any]] else { return nil }
        var result: [URL] = []
        for inst in instances {
            guard let raw = trim(inst["userDataDir"] as? String) ?? trim(inst["user_data_dir"] as? String) else { continue }
            let path = (raw as NSString).expandingTildeInPath
            guard !path.isEmpty else { continue }
            result.append(URL(fileURLWithPath: path))
        }
        return result.isEmpty ? nil : result
    }

    private static func managedCodexHomes() -> [URL]? {
        // ~/.antigravity_cockpit(/_dev)/codex_wakeup_homes/
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let dirNames = [".antigravity_cockpit", ".antigravity_cockpit_dev"]
        var result: [URL] = []
        for name in dirNames {
            let root = home.appendingPathComponent(name).appendingPathComponent("codex_wakeup_homes")
            guard let subs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for sub in subs {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue {
                    result.append(sub)
                }
            }
        }
        return result.isEmpty ? nil : result
    }

    /// 通过 `ps -e -o pid=,command=` 找 com.openai.codex / Codex 主进程，再读其 env CODEX_HOME。
    /// macOS 读其它进程 env 受 SIP 限制（需 root）；尽力而为。对齐 cockpit collect_codex_process_entries。
    private static func codexHomesFromRunningProcesses() -> [URL] {
        // 方式 A：在 `ps ewwww` 里找 env=…CODEX_HOME=…（受 SIP 限制常为空，但也可能拿到自己启动的）
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [URL] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let isCodexBinary = line.contains("/Codex.app/") || line.contains("com.openai.codex") ||
                line.contains("node_modules/@openai/codex/") || line.hasSuffix("/codex")
            guard isCodexBinary else { continue }
            // 从命令行（或 env 注入）匹配 --user-data-dir=XXX 或 CODEX_HOME=XXX
            if let m = Self.regexFirstGroup("CODEX_HOME=(\\S+)", in: line)
                ?? Self.regexFirstGroup("--codex-home=(\\S+)", in: line)
                ?? Self.regexFirstGroup("--user-data-dir=(\\S+)", in: line) {
                let raw = m.replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "'", with: "")
                let expanded = (raw as NSString).expandingTildeInPath
                guard !expanded.isEmpty else { continue }
                result.append(URL(fileURLWithPath: expanded))
            }
        }
        return result
    }

    private static func isNonCredentialError(_ msg: String) -> Bool {
        let needles = ["未找到凭据", "access_token 为空", "凭据为 API Key", "无法解析账号 ID",
                       "无法解析邮箱", "auth.json 与钥匙串均为空"]
        return needles.contains { msg.contains($0) }
    }

    /// 正则提取首个捕获组
    private static func regexFirstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - Public: 切号（写 auth.json + 同步 keychain + 重启 Codex）

    /// 切换 Codex 当前登录账号：退出 Codex → 原子更新 ~/.codex/auth.json → 同步钥匙串 → 重启 Codex。
    /// 旧版配置中的账号可能只有 access token，此时仍写入 access_token/account_id，
    /// 但不会复用当前账号的 refresh/id token，避免续期时串回原账号。
    static func switchAccount(_ account: CodexAccount) -> Bool {
        let t0 = Date()
        Logger.log(.switchAccount, "[iBalance] Codex switchAccount start: uid=\(account.uid)")
        ProcessUtil.killMainProcesses(bundleId: "com.openai.codex", label: "Codex")

        // 读当前 auth.json；若不存在则新建一份最小结构
        let baseDir = codexHome
        var json: [String: Any] = [:]
        var existingPermissions: [FileAttributeKey: Any]? = nil
        let fm = FileManager.default
        let authURL = authPath
        if let data = try? Data(contentsOf: authURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
            existingPermissions = try? fm.attributesOfItem(atPath: authURL.path)
        } else {
            // 确保目录存在
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }

        var tokens = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = account.token
        tokens["account_id"] = account.uid
        if account.idToken.isEmpty {
            tokens.removeValue(forKey: "id_token")
        } else {
            tokens["id_token"] = account.idToken
        }
        if account.refreshToken.isEmpty {
            tokens.removeValue(forKey: "refresh_token")
        } else {
            tokens["refresh_token"] = account.refreshToken
        }
        json["tokens"] = tokens
        // 标记 OAuth 模式，避免官方客户端按 API Key 解释
        if (json["auth_mode"] as? String)?.lowercased() == apiKeyAuthMode {
            json.removeValue(forKey: "auth_mode")
        }

        guard JSONSerialization.isValidJSONObject(json),
              let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
            Logger.log(.switchAccount, "[iBalance] Codex auth.json serialization failed, restarting original account")
            restartCodex()
            return false
        }

        do {
            try out.write(to: authURL, options: [.atomic])
            if let permissions = existingPermissions,
               let mode = permissions[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: authURL.path)
            }
        } catch {
            Logger.log(.switchAccount, "[iBalance] Codex auth.json write failed: \(error.localizedDescription)")
            restartCodex()
            return false
        }

        // 若当前凭据存储偏好 keyring / auto，同步写 keychain 条目。
        // 即便是 file 模式，写一次 keychain 也无副作用；失败只记日志，不中断流程。
        let mode = resolveCredentialsStoreMode()
        if mode == .keyring || mode == .auto {
            switch writeKeychainAuthFile(baseDir: baseDir, jsonDict: json) {
            case .success:
                Logger.log(.switchAccount, "[iBalance] Codex 同步 keychain 凭据写入成功")
            case .failure(let err):
                Logger.log(.switchAccount, "[iBalance] Codex 同步 keychain 凭据失败（已写 auth.json，不中断切号）：\(err)")
            }
        }

        restartCodex()
        Logger.log(.switchAccount, "[iBalance] Codex switchAccount done, total \(ProcessUtil.ms(since: t0))ms")
        return true
    }

    // MARK: - Usage

    struct Usage {
        let uid: String
        let email: String
        let usedPercent: Double
        let resetAt: TimeInterval
    }

    static func fetchUsage(token: String, fallbackUid: String, fallbackEmail: String) async -> Usage? {
        guard let url = URL(string: usageURL) else { return nil }
        let (data, status) = await HTTP.requestWithRetry(
            url: url, method: "GET",
            headers: ["Authorization": "Bearer \(token)", "Accept": "application/json", "User-Agent": "Codex"],
            timeout: 15
        )
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = json["rate_limit"] as? [String: Any],
              let primary = rate["primary_window"] as? [String: Any] else { return nil }
        let used = number(primary["used_percent"])
        var resetAt = number(primary["reset_at"])
        if resetAt <= 0 {
            resetAt = Date().timeIntervalSince1970 + number(primary["reset_after_seconds"])
        }
        let uid = (json["user_id"] as? String) ?? fallbackUid
        let email = (json["email"] as? String) ?? fallbackEmail
        return Usage(uid: uid, email: email, usedPercent: min(100, max(0, used)), resetAt: resetAt)
    }

    // MARK: - Private helpers

    private static func number(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func trim(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static func isApiKeyMode(_ authMode: String?) -> Bool {
        guard let mode = authMode?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return mode == apiKeyAuthMode
    }

    // MARK: JWT payload

    private static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var raw = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw.append("=") }
        guard let data = Data(base64Encoded: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private static func extractSubClaim(_ accessToken: String) -> String? {
        guard let payload = jwtPayload(accessToken) else { return nil }
        return trim(payload["sub"] as? String)
    }

    /// 从 id_token / access_token 提取身份，对齐 cockpit-tools：
    /// - email：id_token.payload.email ∨ id_token.profile_data.email ∨ access.payload.email ∨ access.profile_data.email
    /// - userId：id_token.auth_data.chatgpt_user_id ∨ id_token.auth_data.user_id ∨ access.*（同上）∨ access.payload.sub
    /// - accountId：id_token.auth_data.account_id ∨ id_token.auth_data.chatgpt_account_id ∨ access.*（同上）
    /// - organizationId：同规则
    private static func extractIdentity(idToken: String, accessToken: String) -> CodexIdentity {
        let idPayload = jwtPayload(idToken) ?? [:]
        let acPayload = jwtPayload(accessToken) ?? [:]
        let idAuth = idPayload["https://api.openai.com/auth"] as? [String: Any]
        let idProfile = idPayload["https://api.openai.com/profile"] as? [String: Any]
        let acAuth = acPayload["https://api.openai.com/auth"] as? [String: Any]
        let acProfile = acPayload["https://api.openai.com/profile"] as? [String: Any]

        // Email: id_token 优先
        let email = trim(idPayload["email"] as? String)
            ?? trim(idProfile?["email"] as? String)
            ?? trim(acPayload["email"] as? String)
            ?? trim(acProfile?["email"] as? String)
            ?? ""

        // user_id: id_token -> access_token -> sub
        let userId = trim(idAuth?["chatgpt_user_id"] as? String)
            ?? trim(idAuth?["user_id"] as? String)
            ?? trim(acAuth?["chatgpt_user_id"] as? String)
            ?? trim(acAuth?["user_id"] as? String)
            ?? trim(acPayload["sub"] as? String)

        // account_id: 优先 tokens.account_id（调用方会传），这里再从 JWT auth 取
        let accountId = trim(idAuth?["account_id"] as? String)
            ?? trim(idAuth?["chatgpt_account_id"] as? String)
            ?? trim(acAuth?["account_id"] as? String)
            ?? trim(acAuth?["chatgpt_account_id"] as? String)

        // organization_id: id_token -> access_token
        let organizationId = firstTrimmedString(in: idAuth, keys: ["organization_id", "chatgpt_organization_id", "chatgpt_org_id", "org_id", "poid", "POID"])
            ?? firstTrimmedString(in: acAuth, keys: ["organization_id", "chatgpt_organization_id", "chatgpt_org_id", "org_id", "poid", "POID"])
            ?? firstOrgId(fromOrgs: idAuth?["organizations"] as? [[String: Any]])
            ?? firstOrgId(fromOrgs: acAuth?["organizations"] as? [[String: Any]])

        return CodexIdentity(email: email, userId: userId, accountId: accountId, organizationId: organizationId)
    }

    private static func firstTrimmedString(in dict: [String: Any]?, keys: [String]) -> String? {
        guard let dict else { return nil }
        for k in keys {
            if let s = trim(dict[k] as? String) { return s }
        }
        return nil
    }

    private static func firstOrgId(fromOrgs orgs: [[String: Any]]?) -> String? {
        guard let orgs, !orgs.isEmpty else { return nil }
        if let def = orgs.first(where: { ($0["is_default"] as? Bool) == true }) {
            if let id = trim(def["id"] as? String) { return id }
        }
        if let first = orgs.first, let id = trim(first["id"] as? String) { return id }
        return nil
    }

    // MARK: auth.json 读取

    private static func readAuthFile() -> (CodexAuthFileDoc?, [String: Any]?) {
        readAuthFile(at: codexHome)
    }

    private static func readAuthFile(at home: URL) -> (CodexAuthFileDoc?, [String: Any]?) {
        let path = authPath(for: home)
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let tokDict = json["tokens"] as? [String: Any]
        let tokens = tokDict.map {
            CodexAuthFileTokens(
                idToken: $0["id_token"] as? String,
                accessToken: $0["access_token"] as? String,
                refreshToken: $0["refresh_token"] as? String,
                accountId: $0["account_id"] as? String
            )
        }
        let doc = CodexAuthFileDoc(
            authMode: json["auth_mode"] as? String,
            tokens: tokens,
            personalAccessToken: json["personal_access_token"] as? String
        )
        return (doc, json)
    }

    // MARK: config.toml 凭据存储偏好读取（简化行级解析，避免引入 TOML 库）

    private static func resolveCredentialsStoreMode() -> CodexAuthStoreMode {
        resolveCredentialsStoreMode(for: codexHome)
    }

    private static func resolveCredentialsStoreMode(for home: URL) -> CodexAuthStoreMode {
        let path = configTomlPath(for: home)
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return .file }
        // 行级扫描：匹配 cli_auth_credentials_store = "..." / '...'
        let lines = content.components(separatedBy: .newlines)
        for raw in lines {
            var line = raw
            if let idx = line.firstIndex(of: "#") { line = String(line[..<idx]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(configCredentialsKey) else { continue }
            let rest = trimmed.dropFirst(configCredentialsKey.count)
                .trimmingCharacters(in: .whitespaces)
            guard rest.first == "=" else { continue }
            var value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if value.first == "\"" || value.first == "'" {
                let quote = value.removeFirst()
                value = String(value.prefix { $0 != quote })
            }
            switch value.lowercased() {
            case "keyring": return .keyring
            case "auto":    return .auto
            case "file":    return .file
            default:        return .file
            }
        }
        return .file
    }

    // MARK: Keychain 读写

    private static func keychainAccount(for baseDir: URL) -> String {
        // 对齐 cockpit-tools：canonicalize base_dir → SHA256 → 取前 16 hex，拼接 "cli|{hex16}"
        let resolved: URL
        if let canonical = try? FileManager.default.destinationOfSymbolicLink(atPath: baseDir.path) {
            // 如果是符号链接，返回目标（相对路径转绝对）
            if (canonical as NSString).isAbsolutePath {
                resolved = URL(fileURLWithPath: canonical)
            } else {
                resolved = baseDir.deletingLastPathComponent().appendingPathComponent(canonical)
            }
        } else {
            resolved = baseDir
        }
        let pathStr = resolved.standardizedFileURL.path
        let digest = sha256Hex(pathStr)
        let prefix = String(digest.prefix(16))
        return "cli|\(prefix)"
    }

    private static func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func readKeychainAuthFile() -> CodexAuthFileDoc? {
        readKeychainAuthFile(for: codexHome)
    }

    private static func readKeychainAuthFile(for baseDir: URL) -> CodexAuthFileDoc? {
        let account = keychainAccount(for: baseDir)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data, !data.isEmpty,
              let str = String(data: data, encoding: .utf8),
              let json = try? JSONSerialization.jsonObject(with: str.data(using: .utf8) ?? data) as? [String: Any] else {
            return nil
        }
        let tokDict = json["tokens"] as? [String: Any]
        let tokens = tokDict.map {
            CodexAuthFileTokens(
                idToken: $0["id_token"] as? String,
                accessToken: $0["access_token"] as? String,
                refreshToken: $0["refresh_token"] as? String,
                accountId: $0["account_id"] as? String
            )
        }
        return CodexAuthFileDoc(
            authMode: json["auth_mode"] as? String,
            tokens: tokens,
            personalAccessToken: json["personal_access_token"] as? String
        )
    }

    private enum KeychainWriteResult {
        case success
        case failure(String)
    }

    private static func writeKeychainAuthFile(baseDir: URL, jsonDict: [String: Any]) -> KeychainWriteResult {
        guard JSONSerialization.isValidJSONObject(jsonDict),
              let data = try? JSONSerialization.data(withJSONObject: jsonDict, options: [.prettyPrinted]),
              let secret = String(data: data, encoding: .utf8) else {
            return .failure("Keychain payload 序列化失败")
        }
        let account = keychainAccount(for: baseDir)

        // 先尝试更新；若条目不存在，再添加
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: secret.data(using: .utf8) ?? data,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return .success }
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = secret.data(using: .utf8) ?? data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return .success }
            return .failure("SecItemAdd status=\(addStatus)")
        }
        return .failure("SecItemUpdate status=\(status)")
    }

    // MARK: Personal access token (opaque at-*) fallback

    private static func importFromPersonalAccessToken(_ pat: String) -> CodexImportResult {
        // at-* 是 opaque token，无法直接解 JWT。按约定保留原 token，邮箱/uid 用占位需等
        // fetchUsage 回来再补。此处仍尝试解 JWT（兼容某些场景下 token 本身是 JWT）。
        let payload = jwtPayload(pat) ?? [:]
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let email = trim(payload["email"] as? String) ?? trim(profile?["email"] as? String) ?? ""
        let uid = trim(auth?["account_id"] as? String)
            ?? trim(auth?["chatgpt_account_id"] as? String)
            ?? trim(auth?["chatgpt_user_id"] as? String)
            ?? trim(payload["sub"] as? String) ?? ""
        if uid.isEmpty || email.isEmpty {
            return .failure("Codex personal access token 无法解析出邮箱/账号；请改用 OAuth 登录后导入")
        }
        return .success(CodexAccount(uid: uid, token: pat, email: email, refreshToken: "", idToken: ""))
    }

    // MARK: 重启 Codex

    /// 重启 Codex（-n 确保退出旧进程后创建新实例）。
    private static func restartCodex() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", "-a", "Codex"]
        do { try task.run() } catch {
            Logger.log(.switchAccount, "[iBalance] restart Codex failed: \(error.localizedDescription)")
        }
    }
}

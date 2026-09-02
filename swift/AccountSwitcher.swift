// AccountSwitcher.swift — iBalance
// 多账号采集与切换:WB OAuth 采集、TRAE/Codex/ZCode 导入、performAccountSwitch 统一切号编排
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)

import Cocoa
import UserNotifications

extension AppDelegate {

    // MARK: - WorkBuddy 添加账号（OAuth 采集 / 当前账号 JSON 导入）

    @objc func onAddWbAccount() {
        // OAuth 采集进行中 → 再点一次 = 取消采集
        guard !wbOauthInProgress else {
            wbOauthCancelled = true
            return
        }
        // 选择导入方式（同步模态，keepPanelAliveDuring 保持面板不关闭）
        let shell = DialogShell()
        shell.addIcon(makeWbBrandIcon())
        shell.addTitle("添加 WorkBuddy 账号")
        // 收窄一档：长文规格 width+8（240+8=248，与关于弹窗基准一致），替代 inputWidth(280)
        shell.contentWidth = DialogMetrics.width + 8
        shell.addInfo("OAuth 导入：打开浏览器登录新账号，登录成功后自动采集凭据。\n\nJSON 导入：直接读取你在 WorkBuddy App 中登录的账号。已经登录 App 的话，选择这个即可。")
        let oauth = shell.addButton("OAuth 导入", keyEquivalent: "\r")
        let json = shell.addButton("JSON 导入 (推荐)", tintColor: .systemBlue)
        shell.addButton("取消", keyEquivalent: "\u{1b}")
        let clicked = keepPanelAliveDuring { shell.present() }
        if clicked == oauth {
            startWbOauth()
        } else if clicked == json {
            importWbFromAuthFile()
        }
    }

    /// 启动 OAuth 采集（浏览器登录 → 轮询 token → 写入 config）
    private func startWbOauth() {
        wbOauthInProgress = true
        wbOauthCancelled = false
        wbOauthMenuItem.title = "取消添加 WorkBuddy 账号…"
        syncPanel()
        Task { await runOauth() }
    }

    /// 从 WorkBuddy Desktop 当前登录账号导入：读取 auth 文件（workbuddy-desktop.info，JSON 格式），
    /// uid 去重后写入 config（已存在则更新凭据），随后拉取余额刷新卡片。
    private func importWbFromAuthFile() {
        guard let auth = WorkBuddyService.authInfo() else {
            let shell = DialogShell()
            shell.addTitle("导入失败")
            shell.addInfo("未读取到 WorkBuddy Desktop 的登录信息。\n请先在 WorkBuddy Desktop 中登录账号后重试。")
            shell.addButton("好的", keyEquivalent: "\r")
            _ = keepPanelAliveDuring { shell.present() }
            return
        }
        let account = WBAccount(token: auth.token, uid: auth.uid, domain: auth.domain,
                                nickname: auth.nickname, refreshToken: auth.refreshToken, expiresAt: auth.expiresAt)
        let existed = config.workbuddyAccounts.contains { $0.uid == account.uid }
        if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == account.uid }) {
            config.workbuddyAccounts[idx] = account
        } else {
            config.workbuddyAccounts.append(account)
        }
        ConfigStore.save(config)
        syncPanel()
        // 导入后立即拉取余额刷新卡片；自动签到开启时补一次签到（与 OAuth 导入对齐）
        refreshSeq &+= 1
        let importSeq = refreshSeq
        Logger.log(.refresh, "[\(importSeq)] onImportWbAuthFile triggering ad-hoc WB refresh")
        Task { await refreshOneWorkBuddy(config, seq: importSeq) }
        if config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }
        let shell = DialogShell()
        shell.addTitle("导入成功")
        shell.addInfo(existed
            ? "已更新账号「\(account.nickname)」的凭据（共 \(config.workbuddyAccounts.count) 个账号）"
            : "已导入账号「\(account.nickname)」（共 \(config.workbuddyAccounts.count) 个账号）")
        shell.addButton("好的", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }
    }

    private func runOauth() async {
        // 启动时发引导通知
        let guide = UNMutableNotificationContent()
        guide.title = "请在浏览器中登录 WorkBuddy 账号"
        guide.body = "登录成功后自动采集，无需其他操作（10 分钟内有效）"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_oauth_guide", content: guide, trigger: nil))

        let result = await WorkBuddyService.collectAccount(isCancelled: { [weak self] in self?.wbOauthCancelled ?? true })

        var msg: String
        var success = false
        switch result {
        case .success(let account):
            if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == account.uid }) {
                config.workbuddyAccounts[idx] = account
            } else {
                config.workbuddyAccounts.append(account)
            }
            ConfigStore.save(config)
            msg = "已添加账号「\(account.nickname)」（共 \(config.workbuddyAccounts.count) 个其他账号）"
            success = true
        case .failure(let err):
            msg = err
        }
        wbOauthInProgress = false
        wbOauthMenuItem.title = "添加 WorkBuddy 账号…"
        syncPanel()

        let content = UNMutableNotificationContent()
        content.title = success ? "WorkBuddy 账号采集成功" : "WorkBuddy 账号采集失败"
        content.body = msg
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_oauth_result", content: content, trigger: nil))

        if success, config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }
    }

    // MARK: - TRAE 多账号采集 / 切换

    /// 采集当前 storage.json 中的登录账号到 config（用户在 TRAE 内登录后触发）
    @objc func onCollectTraeAccount() {
        guard !traeCollectInProgress else { return }
        traeCollectInProgress = true
        traeCollectMenuItem.title = "正在采集…"
        syncPanel()

        let result = TraeService.collectCurrentAccount(storagePath: config.traeStoragePath)
        var msg: String
        var success = false
        var isExisting = false
        switch result {
        case .success(let info):
            let account = TraeAccount(uid: info.uid, username: info.username, encryptedAuthInfo: info.encryptedAuthInfo)
            if let idx = config.traeAccounts.firstIndex(where: { $0.uid == account.uid }) {
                config.traeAccounts[idx] = account
                isExisting = true
            } else {
                config.traeAccounts.append(account)
            }
            ConfigStore.save(config)
            msg = isExisting
                ? "账号「\(info.username)」已存在，已更新其凭证"
                : "已添加账号「\(info.username)」（共 \(config.traeAccounts.count) 个 TRAE 账号）"
            success = true
        case .failure(let err):
            msg = err
        }
        traeCollectInProgress = false
        traeCollectMenuItem.title = "采集 TRAE 当前账号…"
        syncPanel()

        // 弹窗提示（成功/失败/已存在 三种状态）
        let shell = DialogShell()
        // 弹窗图标用 TRAE 品牌 logo（非 template，保持原色）
        if let url = Bundle.main.url(forResource: "trae", withExtension: "png"),
           let traeIcon = NSImage(contentsOf: url) {
            traeIcon.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            shell.addIcon(traeIcon)
        }
        shell.addTitle(success ? (isExisting ? "账号已存在" : "添加账号成功") : "添加账号失败")
        shell.addInfo(msg)
        shell.addButton("好", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }

        if success {
            Task { onRefresh() }
        }
    }

    // MARK: - Codex 添加账号（轮询相关目录批量导入）

    /// 按 cockpit-tools-main 同款策略：轮询默认 CODEX_HOME + 多实例 userDataDir +
    /// 运行态进程 CODEX_HOME + cockpit 受管 homes + ~/.codex* / Application Support 候选目录，
    /// 从中导入还未被加入 iBalance 的 Codex 账号；已存在者仅刷新本地凭据。
    @objc func onAddCodexAccount() {
        let batch = CodexService.importDiscoverableAccounts(
            existingUids: Set(config.codexAccounts.map { $0.uid })
        )
        var success = false
        let addedCount = batch.added.count
        let refreshedCount = batch.refreshed.count
        var msg: String
        if addedCount == 0, refreshedCount == 0, !batch.skippedErrors.isEmpty {
            // 真实报错：无有效账号
            if batch.skippedErrors.count == 1 {
                msg = "扫描到 1 个目录但无法导入：\n\(batch.skippedErrors[0])"
            } else {
                msg = "未找到任何可导入的 Codex 账号（\(batch.skippedErrors.count) 个目录读取失败）"
            }
        } else if addedCount == 0, refreshedCount == 0 {
            msg = "轮询相关目录未发现新的 Codex 账号；请先在 Codex 中登录对应账号"
        } else {
            // 应用新增 + 刷新
            for acc in batch.added { config.codexAccounts.append(acc) }
            for acc in batch.refreshed {
                if let idx = config.codexAccounts.firstIndex(where: { $0.uid == acc.uid }) {
                    config.codexAccounts[idx] = acc
                }
            }
            ConfigStore.save(config)
            success = true

            let emails = (batch.added.map { $0.email } + batch.refreshed.map { "\($0.email) (已更新凭据)" })
                .prefix(6)
                .joined(separator: "\n• ")
            let more = (batch.added.count + batch.refreshed.count) > 6
                ? "\n等共 \(batch.added.count + batch.refreshed.count) 个账号"
                : ""
            let summary = ["本次新增 \(addedCount) 个 Codex 账号，刷新 \(refreshedCount) 个已有账号凭据。",
                           "（共 \(config.codexAccounts.count) 个 Codex 账号）",
                           "",
                           "• \(emails)\(more)",
            ].joined(separator: "\n")
            msg = summary
            if !batch.skippedErrors.isEmpty {
                msg += "\n\n⚠️ \(batch.skippedErrors.count) 个目录无有效凭据（已忽略）："
                for e in batch.skippedErrors.prefix(3) {
                    msg += "\n  · \(e)"
                }
                if batch.skippedErrors.count > 3 {
                    msg += "\n  · …等共 \(batch.skippedErrors.count) 条"
                }
            }
        }
        syncPanel()

        let shell = DialogShell()
        if let url = Bundle.main.url(forResource: "codex", withExtension: "svg"),
           let icon = NSImage(contentsOf: url) {
            icon.isTemplate = false
            icon.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            shell.addIcon(icon)
        }
        let title: String
        if addedCount > 0, refreshedCount > 0 {
            title = "新增并刷新 Codex 账号"
        } else if addedCount > 0 {
            title = "添加 Codex 账号成功"
        } else if refreshedCount > 0 {
            title = "已刷新 Codex 账号凭据"
        } else {
            title = "未发现新的 Codex 账号"
        }
        shell.addTitle(success ? title : "未发现可导入的 Codex 账号")
        shell.addInfo(msg)
        shell.addButton("好", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }
        if success { Task { onRefresh() } }
    }

    // MARK: - ZCode 添加账号（JSON 导入）

    /// 从 ~/.zcode/v2/config.json 导入当前登录的 ZCode 账号（暂只支持此方式，无 OAuth）。
    /// 平台无昵称 API（OAuth token 加密不可读），导入后弹输入框让用户自定义昵称（可跳过）。
    @objc func onAddZcodeAccount() {
        var msg: String
        var success = false
        var isExisting = false
        switch ZcodeService.importCurrentAccount() {
        case .success(let imported):
            var account = imported
            // 昵称：优先从 credentials.json 解密 user_info 自动带出（OAuth 登录资料），
            // 拿不到时弹输入框手填兜底（预填已有昵称）
            if account.nickname.isEmpty {
                if let nick = keepPanelAliveDuring({
                    promptForZcodeNickname(prefill: config.zcodeAccounts.first { $0.uid == account.uid }?.nickname ?? "")
                }) {
                    account.nickname = nick
                }
            }
            if let idx = config.zcodeAccounts.firstIndex(where: { $0.uid == account.uid }) {
                config.zcodeAccounts[idx] = account
                isExisting = true
            } else {
                config.zcodeAccounts.append(account)
            }
            ConfigStore.save(config)
            msg = isExisting
                ? "账号 \(account.displayName) 已存在，已更新其凭证"
                : "已添加账号 \(account.displayName)（共 \(config.zcodeAccounts.count) 个 ZCode 账号）"
            success = true
        case .failure(let err):
            msg = err
        }
        syncPanel()

        // 弹窗提示（成功/失败/已存在 三种状态）
        let shell = DialogShell()
        // 弹窗图标用 ZCode 品牌 logo（PNG，非 template，保持原色）
        if let url = Bundle.main.url(forResource: "zcode", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            shell.addIcon(icon)
        }
        shell.addTitle(success ? (isExisting ? "账号已存在" : "添加账号成功") : "添加账号失败")
        shell.addInfo(msg)
        shell.addButton("好", keyEquivalent: "\r")
        _ = keepPanelAliveDuring { shell.present() }

        if success {
            Task { onRefresh() }
        }
    }

    /// ZCode 昵称输入框（平台无昵称 API，由用户自定义用于多账号区分）
    private func promptForZcodeNickname(prefill: String = "") -> String? {
        let icon: NSImage? = {
            guard let url = Bundle.main.url(forResource: "zcode", withExtension: "png"),
                  let img = NSImage(contentsOf: url) else { return nil }
            img.isTemplate = false
            img.size = NSSize(width: DialogMetrics.iconSize, height: DialogMetrics.iconSize)
            return img
        }()
        let dialog = InputDialog(title: "设置 ZCode 账号昵称",
                                 info: "为该账号设置昵称，用于多账号区分。留空则显示账号尾号。",
                                 linkText: "", linkURL: URL(string: "about:blank")!,
                                 prefill: prefill, icon: icon)
        return dialog.present()
    }

    /// 切换 TRAE 账号：后台执行杀进程 → 写 storage.json → 重启 TRAE。
    /// 不立即关闭面板：让用户看到「切换中」脉冲反馈，切换完成后再关闭。
    func switchTraeAccount(uid: String) {
        guard let account = config.traeAccounts.first(where: { $0.uid == uid }) else { return }
        let storagePath = config.traeStoragePath
        performAccountSwitch(serviceName: "TRAE",
                             failureMessage: "写入 storage.json 未成功，已重启恢复原账号",
                             itemId: MenuBarPrefix.trae + account.uid) {
            TraeService.switchAccount(account: TraeAccountInfo(
                uid: account.uid,
                username: account.username,
                avatarUrl: "",
                encryptedAuthInfo: account.encryptedAuthInfo,
                token: TraeService.getTokenFromEncrypted(account.encryptedAuthInfo) ?? ""
            ), storagePath: storagePath)
        }
    }

    /// 统一编排各平台切号流程：后台执行平台特定的凭据写入/重启，回主线程刷新面板并关闭。
    /// 各平台只提供 action，避免重复实现相同的线程切换、失败提示和收尾逻辑。
    private func performAccountSwitch(serviceName: String,
                                      failureMessage: String,
                                      itemId: String,
                                      action: @escaping () -> Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil else { return }
            let ok = action()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !ok {
                    self.notify("\(serviceName) 切号失败", failureMessage)
                } else {
                    // 清除新当前账号的菜单栏显隐记录：历史右键留下的隐藏记录会压过
                    // 「当前账号默认显示」规则，导致切换后菜单栏仍显示旧账号条目
                    if self.config.menuBarVisible.removeValue(forKey: itemId) != nil {
                        ConfigStore.save(self.config)
                    }
                    // 切号成功即重排菜单栏：凭据文件已写入，当前账号判定立即生效
                    //（新当前号排最前 + 按默认规则显示），数值沿用缓存，
                    // 不等网络刷新回填（onRefresh 完成后再修正数值）
                    self.updateTitle(immediate: true, tag: "account-switch")
                    self.syncPanel()
                    self.onRefresh()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.popoverController?.close()
                }
            }
        }
    }

    /// 切换 WorkBuddy 账号：杀进程 → 写 auth 文件 → 重启 WorkBuddy Desktop。
    /// 在后台线程执行（含 Thread.sleep），避免阻塞 UI。
    /// 不立即关闭面板：让用户看到「切换中」反馈 + 卡片重排动画，切换完成后再关闭。
    func switchWbAccount(uid: String) {
        Logger.log(.switchAccount, "[iBalance] switchWbAccount called: uid=\(uid)")
        guard let account = config.workbuddyAccounts.first(where: { $0.uid == uid }) else {
            Logger.log(.switchAccount, "[iBalance] account not found for uid=\(uid)")
            return
        }
        Logger.log(.switchAccount, "[iBalance] found account: \(account.nickname)")
        // 直接用 config 中的 token 切换，WorkBuddy Desktop 启动后会自行刷新 token
        performAccountSwitch(serviceName: "WorkBuddy",
                             failureMessage: "写入认证文件未成功，已重启恢复原账号",
                             itemId: MenuBarPrefix.wb + account.uid) {
            WorkBuddyService.switchAccount(account)
        }
    }

    /// 切换 ZCode 账号：杀进程 → 写 credentials/config → 重启 ZCode。
    /// 在后台线程执行（含等待进程退出），切换完成后再关闭面板（同 WB 流程）。
    func switchZcodeAccount(uid: String) {
        Logger.log(.switchAccount, "[iBalance] switchZcodeAccount called: uid=\(uid)")
        guard let account = config.zcodeAccounts.first(where: { $0.uid == uid }) else {
            Logger.log(.switchAccount, "[iBalance] zcode account not found for uid=\(uid)")
            return
        }
        performAccountSwitch(serviceName: "ZCode",
                             failureMessage: "写入凭据文件未成功，已重启恢复原账号",
                             itemId: MenuBarPrefix.zcode + account.uid) {
            ZcodeService.switchAccount(account)
        }
    }

    /// 切换 Codex 账号：退出 Codex → 写 ~/.codex/auth.json → 重启 Codex。
    /// 不立即关闭面板，让用户看到卡片上的切换中反馈。
    func switchCodexAccount(uid: String) {
        Logger.log(.switchAccount, "[iBalance] switchCodexAccount called: uid=\(uid)")
        guard let account = config.codexAccounts.first(where: { $0.uid == uid }) else {
            Logger.log(.switchAccount, "[iBalance] Codex account not found for uid=\(uid)")
            return
        }
        performAccountSwitch(serviceName: "Codex",
                             failureMessage: "写入 ~/.codex/auth.json 未成功，已重启恢复原账号",
                             itemId: MenuBarPrefix.codex + account.uid) {
            CodexService.switchAccount(account)
        }
    }

}

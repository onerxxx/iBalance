// main.swift — iBalance 入口 + AppDelegate（菜单栏 UI / 定时器 / 编排）
// macOS 菜单栏常驻应用（NSStatusItem），实时汇总多平台余额/积分。
// 不依赖 Python/rumps，编译为单个 .app，内存占用 ~10MB。
// 配置从 .app 同目录 config.json 读取，改配置无需重新编译。

import Cocoa
import UserNotifications

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusBar = NSStatusBar.system
    private var statusItem: NSStatusItem!
    private var refreshMenuItem: NSMenuItem!
    private var traeAutoCheckinMenuItem: NSMenuItem!
    private var wbAutoCheckinMenuItem: NSMenuItem!
    private var refreshIntervalMenuItem: NSMenuItem!
    private var refreshIntervalOptions: [NSMenuItem] = []
    private var decimalsDsMenuItem: NSMenuItem!
    private var decimalsQwMenuItem: NSMenuItem!
    private var hideMainIconMenuItem: NSMenuItem!
    private var timer: Timer?
    private var checkinTimer: Timer?
    private var wbOauthMenuItem: NSMenuItem!
    private var wbOauthInProgress = false
    private var wbOauthCancelled = false

    private var config = AppConfig()
    // 缓存原始数据，切换小数位时即时重绘（仅在主线程变更）
    private var cacheDs: (symbol: String, totalRaw: String)?
    private var cacheWb: Double?
    private var cacheTrae: (limit: Double, used: Double)?
    private var cacheQw: QianwenService.Quota?
    // Edge Cookies 受 TCC 保护：标记本次读取是否被系统拦截，用于一次性引导授权
    private var hasShownQwTccAlert = false
    // 离线标记：网络不可达时菜单栏显示离线提示并暂停刷新
    private var isOffline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标（与 Info.plist LSUIElement 双保险）
        NSApp.setActivationPolicy(.accessory)

        config = ConfigStore.load()

        // 菜单栏 status item
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        if !config.hideMainIcon {
            statusItem.button?.image = loadTemplateImage(named: "credit-card-filled", size: NSSize(width: 16, height: 16))
        }
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = "¥..."

        // 下拉菜单
        let menu = NSMenu()

        refreshMenuItem = NSMenuItem(title: "刷新余额", action: #selector(onRefresh), keyEquivalent: "")
        refreshMenuItem.target = self
        menu.addItem(refreshMenuItem)

        let openCockpitMenuItem = NSMenuItem(title: "打开 Cockpit", action: #selector(onOpenCockpit), keyEquivalent: "")
        openCockpitMenuItem.target = self
        menu.addItem(openCockpitMenuItem)

        menu.addItem(NSMenuItem.separator())

        traeAutoCheckinMenuItem = NSMenuItem(title: "TRAE 自动签到", action: #selector(onToggleAutoCheckin), keyEquivalent: "")
        traeAutoCheckinMenuItem.target = self
        traeAutoCheckinMenuItem.state = config.traeAutoCheckin ? .on : .off
        menu.addItem(traeAutoCheckinMenuItem)
        updateAutoCheckinMenuTitle()

        wbAutoCheckinMenuItem = NSMenuItem(title: "WorkBuddy 自动签到", action: #selector(onToggleWbAutoCheckin), keyEquivalent: "")
        wbAutoCheckinMenuItem.target = self
        wbAutoCheckinMenuItem.state = config.workbuddyAutoCheckin ? .on : .off
        menu.addItem(wbAutoCheckinMenuItem)
        updateWbAutoCheckinMenuTitle()

        wbOauthMenuItem = NSMenuItem(title: "添加 WorkBuddy 账号…", action: #selector(onAddWbAccount), keyEquivalent: "")
        wbOauthMenuItem.target = self
        menu.addItem(wbOauthMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 刷新时间子菜单：1 / 3 / 5 分钟单选
        let intervalSubmenu = NSMenu()
        for minutes in [1, 3, 5] {
            let item = NSMenuItem(title: "\(minutes)分钟", action: #selector(onToggleRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes * 60
            item.state = (config.refreshInterval == TimeInterval(minutes * 60)) ? .on : .off
            intervalSubmenu.addItem(item)
            refreshIntervalOptions.append(item)
        }
        refreshIntervalMenuItem = NSMenuItem(title: "刷新时间", action: nil, keyEquivalent: "")
        refreshIntervalMenuItem.submenu = intervalSubmenu
        menu.addItem(refreshIntervalMenuItem)
        updateRefreshIntervalMenuTitle()

        menu.addItem(NSMenuItem.separator())

        decimalsDsMenuItem = NSMenuItem(title: "DeepSeek 显示2位小数", action: #selector(onToggleDecimals(_:)), keyEquivalent: "")
        decimalsDsMenuItem.target = self
        decimalsDsMenuItem.state = (config.deepseekDecimals == 2) ? .on : .off
        menu.addItem(decimalsDsMenuItem)

        decimalsQwMenuItem = NSMenuItem(title: "Qwen 显示1位小数", action: #selector(onToggleDecimals(_:)), keyEquivalent: "")
        decimalsQwMenuItem.target = self
        decimalsQwMenuItem.state = (config.qianwenDecimals == 1) ? .on : .off
        menu.addItem(decimalsQwMenuItem)

        menu.addItem(NSMenuItem.separator())

        let apiKeyMenuItem = NSMenuItem(title: "设置 API Key…", action: #selector(onSetApiKey), keyEquivalent: "")
        apiKeyMenuItem.target = self
        menu.addItem(apiKeyMenuItem)

        let qwTicketMenuItem = NSMenuItem(title: "手动设置千问 Ticket（备用）…", action: #selector(onSetQianwenTicket), keyEquivalent: "")
        qwTicketMenuItem.target = self
        menu.addItem(qwTicketMenuItem)

        menu.addItem(NSMenuItem.separator())

        hideMainIconMenuItem = NSMenuItem(title: "隐藏主icon", action: #selector(onToggleHideMainIcon), keyEquivalent: "")
        hideMainIconMenuItem.target = self
        hideMainIconMenuItem.state = config.hideMainIcon ? .on : .off
        menu.addItem(hideMainIconMenuItem)

        let aboutItem = NSMenuItem(title: "关于 iBalance", action: #selector(onAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // 菜单栏前景色随屏幕聚焦状态变化；macOS 27 不总会主动重绘，手动监听刷新
        observeFocusChanges()

        // 首次使用：API Key 为空时弹窗让用户填写
        if config.deepseekApiKey.isEmpty {
            if let key = promptForApiKey() {
                config.deepseekApiKey = key
                ConfigStore.save(config)
            }
        }

        // 请求通知权限（失败仍可运行）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // 网络状态监听：离线暂停刷新、恢复立即刷新
        NetworkMonitor.shared.onChange = { [weak self] online in
            guard let self else { return }
            self.isOffline = !online
            if online { self.onRefresh() }
            else { self.updateTitle() }
        }
        NetworkMonitor.shared.start()

        // 定时刷新
        timer = Timer.scheduledTimer(timeInterval: config.refreshInterval,
                                     target: self,
                                     selector: #selector(onRefresh),
                                     userInfo: nil,
                                     repeats: true)

        // 启动后立即刷新一次
        onRefresh()

        // 自动签到：启动时检查 + 每小时轮询（本地日期守卫，每天最多一次网络请求）
        startCheckinTimer()
        if config.traeAutoCheckin {
            Task { await traeAutoCheckinIfNeeded() }
        }
        if config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }
    }

    // MARK: - 图标（从 Resources 加载 SVG template image，系统自动 tint + active/inactive 变暗）

    private func loadTemplateImage(named name: String, size: NSSize) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = size
        return img
    }

    // MARK: - 菜单栏前景色适配（屏幕聚焦状态）

    private func observeFocusChanges() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSApplication.didResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(refreshStatusItemAppearance),
                       name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
    }

    /// 强制 status item 按当前聚焦状态重绘。通知可能在非主线程投递，统一回主线程更新 UI。
    @objc private func refreshStatusItemAppearance() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusItem.button?.image = self.config.hideMainIcon ? nil : self.loadTemplateImage(named: "credit-card-filled", size: NSSize(width: 16, height: 16))
            self.updateTitle()
            self.statusItem.button?.needsDisplay = true
        }
    }

    /// 千分位格式化（每 k 加逗号）
    private func fmtAmountCommas(_ value: Any, decimals: Int) -> String {
        guard let dv = anyToDouble(value) else { return "\(value)" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = decimals
        f.minimumFractionDigits = decimals
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: dv)) ?? String(format: "%.\(decimals)f", dv)
    }

    // MARK: - 菜单回调

    @objc private func onRefresh() {
        refreshMenuItem.title = "刷新中…"
        refreshMenuItem.isEnabled = false
        Task { await performRefresh() }
    }

    @objc private func onToggleDecimals(_ sender: NSMenuItem) {
        if sender == decimalsDsMenuItem {
            config.deepseekDecimals = (config.deepseekDecimals == 2) ? 0 : 2
            decimalsDsMenuItem.state = (config.deepseekDecimals == 2) ? .on : .off
        } else if sender == decimalsQwMenuItem {
            config.qianwenDecimals = (config.qianwenDecimals == 1) ? 0 : 1
            decimalsQwMenuItem.state = (config.qianwenDecimals == 1) ? .on : .off
        }
        updateTitle()
        ConfigStore.save(config)
    }

    /// 子菜单单选切换刷新间隔（tag = 秒数：60 / 180 / 300）
    @objc private func onToggleRefreshInterval(_ sender: NSMenuItem) {
        let interval = TimeInterval(sender.tag)
        guard interval > 0 else { return }
        config.refreshInterval = interval
        refreshIntervalOptions.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }
        updateRefreshIntervalMenuTitle()
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: config.refreshInterval,
                                     target: self,
                                     selector: #selector(onRefresh),
                                     userInfo: nil,
                                     repeats: true)
        ConfigStore.save(config)
    }

    /// 主菜单项标题显示当前选中的刷新间隔
    private func updateRefreshIntervalMenuTitle() {
        let minutes = Int(config.refreshInterval) / 60
        refreshIntervalMenuItem.title = "刷新时间（\(minutes)分钟）"
    }

    @objc private func onToggleHideMainIcon() {
        config.hideMainIcon = !config.hideMainIcon
        hideMainIconMenuItem.state = config.hideMainIcon ? .on : .off
        statusItem.button?.image = config.hideMainIcon ? nil : loadTemplateImage(named: "credit-card-filled", size: NSSize(width: 16, height: 16))
        updateTitle()
        ConfigStore.save(config)
    }

    @objc private func onQuit() {
        NSApp.terminate(nil)
    }

    @objc private func onAbout() {
        let alert = NSAlert()
        alert.messageText = "关于 iBalance"
        alert.informativeText = ""
        alert.alertStyle = .informational

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        let desc = NSTextView(frame: NSRect(x: 0, y: 0, width: 350, height: 180))
        desc.isEditable = false
        desc.isSelectable = false
        desc.drawsBackground = false
        desc.backgroundColor = .clear
        desc.isRichText = false
        desc.textContainer?.lineFragmentPadding = 0
        desc.textContainerInset = NSSize(width: 8, height: 0)
        let attr = NSMutableAttributedString(
            string: "菜单栏常驻余额小工具，实时汇总并展示多平台账户余额与积分。\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.labelColor])
        let bullets = NSAttributedString(
            string: "• DeepSeek 余额（需填 API Key）\n• WorkBuddy 积分（直接调用 CodeBuddy API，自动读取登录态）\n• TRAE 积分（从 TRAE SOLO CN 本地解密）\n• TRAE 每日自动签到\n• WorkBuddy 多号每日自动签到（config 预存多账号 token）\n• 千问 Token Plan 周额度剩余百分比（自动读取 Edge 登录态）\n• 打开 Cockpit（本地 App，未安装时提示）\n• 刷新间隔 1 / 5 分钟，小数位可调\n• 网络离线自动暂停刷新，恢复后立即刷新\n\n配置存于同目录 config.json。\n版本 \(version)（Build \(build)）",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.labelColor])
        attr.append(bullets)
        desc.textStorage?.setAttributedString(attr)
        alert.accessoryView = desc

        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func onSetApiKey() {
        guard let key = promptForApiKey(prefill: config.deepseekApiKey) else { return }
        config.deepseekApiKey = key
        ConfigStore.save(config)
        onRefresh()
    }

    // MARK: - 统一格式化标题（用缓存 + 当前小数位）

    private func updateTitle() {
        let baseFont = NSFont.menuBarFont(ofSize: 0)
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)

        // 离线标记：网络不可达时菜单栏只显示离线提示
        if isOffline {
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: "⚠︎", attributes: [.font: baseFont]))
            attr.append(NSAttributedString(string: " 离线", attributes: [.font: baseFont]))
            statusItem.button?.attributedTitle = attr
            return
        }

        let attr = NSMutableAttributedString()
        func append(_ s: String, bold: Bool = false) {
            attr.append(NSAttributedString(string: s, attributes: [.font: bold ? boldFont : baseFont]))
        }

        var hasContent = false

        if let ds = cacheDs {
            let total = fmtAmountCommas(ds.totalRaw, decimals: config.deepseekDecimals)
            if !config.hideMainIcon { append(" ") }
            append(ds.symbol, bold: true)
            append("\u{2009}\(total)")
            hasContent = true
        }

        if let trae = cacheTrae {
            if hasContent { append("  ") }
            let remaining = trae.limit - trae.used
            let amount = fmtAmountCommas(remaining, decimals: config.traeDecimals)
            append("✦\u{2009}\(amount)")
            hasContent = true
        }

        if let qw = cacheQw {
            if hasContent { append("  ") }
            append("🅠", bold: true)
            append("\u{2009}\(fmtAmountCommas(qw.weekRem / max(qw.weekLimit, 1) * 100, decimals: config.qianwenDecimals))%")
            hasContent = true
        }

        if let wb = cacheWb {
            if hasContent { append("  ") }
            append("🆆", bold: true)
            append("\u{2009}\(fmtAmountCommas(wb, decimals: config.workbuddyDecimals))")
            hasContent = true
        }

        if hasContent {
            statusItem.button?.attributedTitle = attr
        } else {
            let placeholder = NSMutableAttributedString()
            placeholder.append(NSAttributedString(string: "¥", attributes: [.font: boldFont]))
            placeholder.append(NSAttributedString(string: "...", attributes: [.font: baseFont]))
            statusItem.button?.attributedTitle = placeholder
        }
    }

    // MARK: - 请求编排（四服务并行，各自独立更新 UI）

    /// 主刷新流程：离线直接返回；在线则并行拉取四个服务，先到先显示。
    private func performRefresh() async {
        guard NetworkMonitor.shared.isOnline else {
            isOffline = true
            refreshMenuItem.title = "刷新余额"
            refreshMenuItem.isEnabled = true
            updateTitle()
            return
        }
        isOffline = false
        let cfg = config

        // 四服务并行请求，先到先显示：每个服务返回后立即写缓存并重绘标题，互不等待
        async let a: Void = refreshOneDeepSeek(cfg)
        async let b: Void = refreshOneWorkBuddy(cfg)
        async let c: Void = refreshOneTrae(cfg)
        async let d: Void = refreshOneQianwen(cfg)
        _ = await (a, b, c, d)

        refreshMenuItem.title = "刷新余额"
        refreshMenuItem.isEnabled = true
    }

    private func refreshOneDeepSeek(_ cfg: AppConfig) async {
        let ds = await DeepSeekService.fetch(apiKey: cfg.deepseekApiKey)
        if let bal = ds.balance { cacheDs = (bal.symbol, bal.totalRaw) }
        if !ds.error.isEmpty { notifyError(ds.error) }
        updateTitle()
    }

    private func refreshOneWorkBuddy(_ cfg: AppConfig) async {
        guard cfg.workbuddyEnabled, let total = await WorkBuddyService.fetchSummary() else { return }
        cacheWb = total
        updateTitle()
    }

    private func refreshOneTrae(_ cfg: AppConfig) async {
        guard let t = await TraeService.fetchCredits(storagePath: cfg.traeStoragePath) else { return }
        cacheTrae = t
        updateTitle()
    }

    private func refreshOneQianwen(_ cfg: AppConfig) async {
        let qw = await QianwenService.fetchQuota(manualTicket: cfg.qianwenTicket)
        if let q = qw.quota {
            cacheQw = q
            updateTitle()
        } else if qw.tccBlocked, cfg.qianwenTicket.isEmpty, !hasShownQwTccAlert {
            hasShownQwTccAlert = true
            showQwTccAlert()
        }
    }

    // MARK: - WorkBuddy 自动签到

    @objc private func onToggleWbAutoCheckin() {
        config.workbuddyAutoCheckin.toggle()
        wbAutoCheckinMenuItem.state = config.workbuddyAutoCheckin ? .on : .off
        ConfigStore.save(config)
        if config.workbuddyAutoCheckin {
            startCheckinTimer()
            Task { await wbAutoCheckinIfNeeded() }
        } else if !config.traeAutoCheckin {
            stopCheckinTimer()
        }
    }

    private func updateWbAutoCheckinMenuTitle() {
        let today = Self.todayString()
        let accounts = wbCheckinAccounts()
        let total = accounts.count
        let done = accounts.filter {
            UserDefaults.standard.string(forKey: "wb_checkin_date_\($0.uid)") == today
        }.count
        let t = UserDefaults.standard.string(forKey: "wb_last_checkin_time") ?? ""
        if total > 0 && !t.isEmpty {
            wbAutoCheckinMenuItem.title = "WorkBuddy 自动签到（\(done)/\(total) \(t)）"
        } else if total > 0 {
            wbAutoCheckinMenuItem.title = "WorkBuddy 自动签到（\(done)/\(total)）"
        } else {
            wbAutoCheckinMenuItem.title = "WorkBuddy 自动签到"
        }
    }

    /// 收集待签到账号：config 预存的其他账号 + 当前登录账号（token 自动刷新，uid 去重）
    private func wbCheckinAccounts() -> [WBAccount] {
        var accounts = config.workbuddyAccounts
        if let auth = WorkBuddyService.authInfo(),
           !accounts.contains(where: { $0.uid == auth.uid }) {
            accounts.append(WBAccount(token: auth.token, uid: auth.uid, domain: auth.domain, nickname: auth.nickname, refreshToken: "", expiresAt: 0))
        }
        return accounts
    }

    /// 多号签到核心：遍历账号，每号本地日期守卫（每天最多一次），签到前自动刷新 token。
    private func wbAutoCheckinIfNeeded() async {
        let today = Self.todayString()
        var accounts = wbCheckinAccounts()
        for i in 0..<accounts.count {
            var ac = accounts[i]
            let dateKey = "wb_checkin_date_\(ac.uid)"
            if UserDefaults.standard.string(forKey: dateKey) == today { continue }

            // 签到前自动刷新 token（距过期 < 1 小时则用 refreshToken 续期）
            let refreshed = await WorkBuddyService.refreshTokenIfNeeded(account: ac)
            if refreshed != ac {
                if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                    config.workbuddyAccounts[idx] = refreshed
                    ConfigStore.save(config)
                }
                ac = refreshed
                accounts[i] = refreshed
            }

            // 查状态：已签则记录日期跳过；不可签也记录避免重复尝试
            if let st = await WorkBuddyService.fetchCheckinStatus(token: ac.token, uid: ac.uid, domain: ac.domain) {
                if st.todayCheckedIn || !st.available {
                    UserDefaults.standard.set(today, forKey: dateKey)
                    updateWbAutoCheckinMenuTitle()
                    continue
                }
            }

            // 执行签到
            let r = await WorkBuddyService.claimCheckin(token: ac.token, uid: ac.uid, domain: ac.domain)
            if r.success {
                UserDefaults.standard.set(today, forKey: dateKey)
                UserDefaults.standard.set(Self.nowTimeString(), forKey: "wb_last_checkin_time")
                updateWbAutoCheckinMenuTitle()
                // 签到后刷新积分显示（仅当前登录号）
                if config.workbuddyEnabled, WorkBuddyService.authInfo()?.uid == ac.uid {
                    if let total = await WorkBuddyService.fetchSummary() {
                        cacheWb = total
                        updateTitle()
                    }
                }
                let content = UNMutableNotificationContent()
                content.title = "WorkBuddy 自动签到（\(ac.nickname)）"
                content.body = r.creditDesc.isEmpty ? "今日签到成功 ✓" : "今日签到成功 ✓ 积分：\(r.creditDesc)"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_auto_checkin_\(ac.uid)", content: content, trigger: nil)) { _ in }
            }
            // 失败不记录日期，下一小时重试
        }
    }

    // MARK: - WorkBuddy OAuth 账号采集

    @objc private func onAddWbAccount() {
        guard !wbOauthInProgress else {
            wbOauthCancelled = true
            return
        }
        wbOauthInProgress = true
        wbOauthCancelled = false
        wbOauthMenuItem.title = "取消添加 WorkBuddy 账号…"
        Task { await runOauth() }
    }

    private func runOauth() async {
        // 启动时发引导通知
        let guide = UNMutableNotificationContent()
        guide.title = "请在浏览器中登录 WorkBuddy 账号"
        guide.body = "登录成功后自动采集，无需其他操作（10 分钟内有效）"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_oauth_guide", content: guide, trigger: nil)) { _ in }

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

        let content = UNMutableNotificationContent()
        content.title = success ? "WorkBuddy 账号采集成功" : "WorkBuddy 账号采集失败"
        content.body = msg
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_oauth_result", content: content, trigger: nil)) { _ in }

        if success, config.workbuddyAutoCheckin {
            Task { await wbAutoCheckinIfNeeded() }
        }
    }

    // MARK: - 千问手动设置 Ticket + TCC 引导

    @objc private func onSetQianwenTicket() {
        guard let ticket = promptForQianwenTicket(prefill: config.qianwenTicket) else { return }
        config.qianwenTicket = ticket
        ConfigStore.save(config)
        onRefresh()
    }

    /// TCC 拦截 Edge Cookies 读取时的一次性引导弹窗。
    /// 重新编译后签名变化可能导致「完全磁盘访问」权限失效，需用户重新授权。
    private func showQwTccAlert() {
        let alert = NSAlert()
        alert.messageText = "无法自动读取千问登录态"
        alert.informativeText = "Edge 浏览器的 Cookie 文件受系统保护，iBalance 无法读取。\n\n请到 系统设置 → 隐私与安全 → 完全磁盘访问 中添加 iBalance，或手动填写 Ticket。\n\n授权后下次刷新即可自动获取。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "手动填写 Ticket")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        } else if resp == .alertSecondButtonReturn {
            if let ticket = promptForQianwenTicket(prefill: config.qianwenTicket) {
                config.qianwenTicket = ticket
                ConfigStore.save(config)
                onRefresh()
            }
        }
    }

    // MARK: - 统一输入弹窗（API Key / 千问 Ticket 共用）

    /// 通用输入弹窗：标题 + 说明文字（含超链接）+ 单行输入框 + 保存/稍后。回车保存、Esc 稍后、Cmd+V 粘贴。
    private func promptForInput(title: String, info: String, linkText: String, linkURL: URL, prefill: String, infoHeight: CGFloat) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = ""
        alert.alertStyle = .informational

        let padLeft: CGFloat = 8

        let infoView = NSTextView(frame: NSRect(x: 0, y: 34, width: 306, height: infoHeight))
        infoView.isEditable = false
        infoView.isSelectable = true
        infoView.drawsBackground = false
        infoView.backgroundColor = .clear
        infoView.isRichText = false
        infoView.textContainer?.lineFragmentPadding = 0
        infoView.textContainerInset = NSSize(width: padLeft, height: 0)
        let infoAttr = NSMutableAttributedString(
            string: info,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        infoAttr.append(NSAttributedString(
            string: linkText,
            attributes: [.link: linkURL,
                         .foregroundColor: NSColor.linkColor,
                         .underlineStyle: NSUnderlineStyle.single.rawValue,
                         .font: NSFont.systemFont(ofSize: 11)]))
        infoView.textStorage?.setAttributedString(infoAttr)

        let inputView = NSTextView(frame: NSRect(x: 0, y: 0, width: 306, height: 24))
        inputView.isEditable = true
        inputView.isSelectable = true
        inputView.drawsBackground = false
        inputView.backgroundColor = .clear
        inputView.isRichText = false
        inputView.font = NSFont.systemFont(ofSize: 12)
        inputView.textContainer?.lineFragmentPadding = 0
        inputView.textContainerInset = NSSize(width: padLeft, height: 4)
        inputView.isHorizontallyResizable = false
        inputView.isVerticallyResizable = false
        inputView.autoresizingMask = [.width]
        inputView.string = prefill
        inputView.wantsLayer = true
        inputView.layer?.cornerRadius = 4
        inputView.layer?.borderWidth = 1
        inputView.layer?.borderColor = NSColor.separatorColor.cgColor
        inputView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 306, height: infoHeight + 34))
        container.addSubview(infoView)
        container.addSubview(inputView)

        alert.accessoryView = container
        alert.window.initialFirstResponder = inputView

        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)

        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak inputView] event -> NSEvent? in
            if event.characters == "\r" {
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                alert.window.orderOut(nil)
                return nil
            }
            if event.keyCode == 53 {
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
                alert.window.orderOut(nil)
                return nil
            }
            guard let inputView = inputView,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else {
                return event
            }
            inputView.insertText(str, replacementRange: inputView.selectedRange())
            return nil
        }
        defer { if let m = monitor { NSEvent.removeMonitor(m) } }

        if alert.runModal() == .alertFirstButtonReturn {
            let v = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    private func promptForApiKey(prefill: String = "") -> String? {
        promptForInput(title: "请输入 DeepSeek API Key",
                       info: "在下方粘贴或输入你的 API Key：\n获取地址：",
                       linkText: "platform.deepseek.com/api_keys",
                       linkURL: URL(string: "https://platform.deepseek.com/api_keys")!,
                       prefill: prefill, infoHeight: 34)
    }

    private func promptForQianwenTicket(prefill: String = "") -> String? {
        promptForInput(title: "请输入千问 login_qianwenai_ticket",
                       info: "通常无需手动填写（自动读取 Edge 登录态）。备用方式：F12 → Application → Cookies → 复制 .qianwenai.com 下 login_qianwenai_ticket：\n",
                       linkText: "platform.qianwenai.com Token Plan 页面",
                       linkURL: URL(string: "https://platform.qianwenai.com/home/billing/subscription/token-plan-individual")!,
                       prefill: prefill, infoHeight: 46)
    }

    // MARK: - TRAE 自动签到

    @objc private func onToggleAutoCheckin() {
        config.traeAutoCheckin.toggle()
        traeAutoCheckinMenuItem.state = config.traeAutoCheckin ? .on : .off
        ConfigStore.save(config)
        if config.traeAutoCheckin {
            startCheckinTimer()
            Task { await traeAutoCheckinIfNeeded() }
        } else if !config.workbuddyAutoCheckin {
            stopCheckinTimer()
        }
    }

    /// 自动签到核心：本地日期守卫，今天已签到则跳过（零网络开销）。
    private func traeAutoCheckinIfNeeded() async {
        let today = Self.todayString()
        let lastDate = UserDefaults.standard.string(forKey: "trae_last_checkin_date") ?? ""
        if lastDate == today { return }

        guard let token = TraeService.getToken(storagePath: config.traeStoragePath) else { return }

        if let st = await TraeService.fetchCheckinStatus(token: token, storagePath: config.traeStoragePath) {
            if !st.enable || st.checkedIn {
                UserDefaults.standard.set(today, forKey: "trae_last_checkin_date")
                return
            }
        }

        let (httpStatus, respJson) = await TraeService.claimCheckin(token: token, storagePath: config.traeStoragePath)
        let bizCode = respJson?["code"] as? Int
        if httpStatus == 200 && bizCode == 0 {
            UserDefaults.standard.set(today, forKey: "trae_last_checkin_date")
            UserDefaults.standard.set(Self.nowTimeString(), forKey: "trae_last_checkin_time")
            updateAutoCheckinMenuTitle()
            if let credits = await TraeService.fetchCredits(storagePath: config.traeStoragePath) {
                cacheTrae = credits
                updateTitle()
            }
            let content = UNMutableNotificationContent()
            content.title = "TRAE 自动签到"
            content.body = "今日签到成功 ✓"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "trae_auto_checkin", content: content, trigger: nil)) { _ in }
        }
    }

    // MARK: - Cockpit

    @objc private func onOpenCockpit() {
        let bid = config.cockpitAppId
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else {
            let alert = NSAlert()
            alert.messageText = "未找到 Cockpit App"
            alert.informativeText = "未找到 Bundle ID 为 \(bid) 的应用，请确认 Cockpit 已安装。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: - 签到定时器

    private func startCheckinTimer() {
        stopCheckinTimer()
        guard config.traeAutoCheckin || config.workbuddyAutoCheckin else { return }
        checkinTimer = Timer.scheduledTimer(timeInterval: 3600,
                                            target: self,
                                            selector: #selector(onCheckinTimerFired),
                                            userInfo: nil,
                                            repeats: true)
    }

    private func stopCheckinTimer() {
        checkinTimer?.invalidate()
        checkinTimer = nil
    }

    @objc private func onCheckinTimerFired() {
        if config.traeAutoCheckin { Task { await traeAutoCheckinIfNeeded() } }
        if config.workbuddyAutoCheckin { Task { await wbAutoCheckinIfNeeded() } }
    }

    /// 更新 TRAE 自动签到菜单标题，附上最近签到时间
    private func updateAutoCheckinMenuTitle() {
        if let t = UserDefaults.standard.string(forKey: "trae_last_checkin_time") {
            traeAutoCheckinMenuItem.title = "TRAE 自动签到（\(t)）"
        } else {
            traeAutoCheckinMenuItem.title = "TRAE 自动签到"
        }
    }

    // MARK: - 工具

    private static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    private static func nowTimeString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M-d HH:mm"
        return fmt.string(from: Date())
    }

    private func notifyError(_ msg: String) {
        let content = UNMutableNotificationContent()
        content.title = "DeepSeek 余额查询"
        content.body = msg
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ds_balance_error", content: content, trigger: nil)) { _ in }
    }
}

// MARK: - 入口

/// 显式入口：无 MainMenu.xib 的 App，@NSApplicationMain 不会自动关联 delegate，
/// 会导致 applicationDidFinishLaunching 不触发（菜单栏无任何显示）。
/// 因此手动创建 NSApplication、挂 delegate、设 activationPolicy 并运行。
@main
struct iBalanceMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // 隐藏 Dock（与 Info.plist LSUIElement 双保险）
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}


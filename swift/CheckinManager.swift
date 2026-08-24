// CheckinManager.swift — iBalance
// 签到域:错峰自动签到(WB/TRAE)、手动签到编排、签到历史与定时器
// (2026-08-24 自 main.swift/Panel.swift 拆出,纯代码搬移)

import Cocoa
import UserNotifications

extension AppDelegate {

    /// 收集 TRAE 待查询账号：config 预存账号 + 当前登录账号（uid 去重）
    /// 主账号不在 config 时自动加入（不持久化，下次切换后由用户决定是否采集保存）
    func traeCheckinAccounts() -> [TraeAccount] {
        var accounts = config.traeAccounts
        if let cur = TraeService.readAuthInfo(storagePath: config.traeStoragePath),
           !accounts.contains(where: { $0.uid == cur.uid }) {
            accounts.append(TraeAccount(uid: cur.uid, username: cur.username, encryptedAuthInfo: cur.encryptedAuthInfo))
        }
        return accounts
    }

    // MARK: - WorkBuddy 自动签到

    /// 收集待签到账号：config 预存的其他账号 + 当前登录账号（token 自动刷新，uid 去重）
    /// 主账号不在 config 时自动持久化（含 refreshToken/expiresAt），下次主账号切换后原账号仍可续期签到。
    func wbCheckinAccounts() -> [WBAccount] {
        var accounts = config.workbuddyAccounts
        if let auth = WorkBuddyService.authInfo(),
           !accounts.contains(where: { $0.uid == auth.uid }) {
            let main = WBAccount(token: auth.token, uid: auth.uid, domain: auth.domain,
                                 nickname: auth.nickname, refreshToken: auth.refreshToken, expiresAt: auth.expiresAt)
            accounts.append(main)
            config.workbuddyAccounts.append(main)
            ConfigStore.save(config)
        }
        return accounts
    }

    /// 补全 WorkBuddy 多账号签到 streak/reward：遍历所有账号，streak 或 reward 为 0 时查状态 API 填充。
    /// 每天最多跑一次（wb_status_fill_date 守卫），避免每次余额刷新都打 status API 触发风控。
    /// auto-checkin 已开启且主账号今日已签到时跳过（签到流程会顺带补全 streak/reward，去重）。
    /// 与 TRAE 侧 traeCheckinStatusFill 对齐：自动签到关闭时，手动在 Desktop 签过也能补写历史。
    func wbCheckinStatusFill() async {
        let today = Self.todayString()
        // 每天最多补全一次，避免每次余额刷新都打 status API 触发风控
        let fillDateKey = UDKey.wbStatusFillDate
        if UserDefaults.standard.string(forKey: fillDateKey) == today { return }
        // auto-checkin 已开启且主账号今日已签到 → 签到流程会顺带补全 streak/reward，跳过
        if config.workbuddyAutoCheckin,
           let mainUid = WorkBuddyService.authInfo()?.uid,
           UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(mainUid)) == today {
            UserDefaults.standard.set(today, forKey: fillDateKey)
            return
        }
        let accounts = wbCheckinAccounts()
        for i in 0..<accounts.count {
            var ac = accounts[i]
            let dateKey = UDKey.wbCheckinDate(ac.uid)
            let streakKey = UDKey.wbCheckinStreak(ac.uid)
            let rewardKey = UDKey.wbCheckinReward(ac.uid)
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 仅当今天已签到且 streak/reward 均有值时才跳过
            if prevStreak > 0 && prevReward > 0 && UserDefaults.standard.string(forKey: dateKey) == today { continue }
            // 查状态前自动刷新 token（距过期 < 1 小时则用 refreshToken 续期）
            let refreshed = await WorkBuddyService.refreshTokenIfNeeded(account: ac)
            if refreshed != ac {
                if let idx = config.workbuddyAccounts.firstIndex(where: { $0.uid == ac.uid }) {
                    config.workbuddyAccounts[idx] = refreshed
                    ConfigStore.save(config)
                }
                ac = refreshed
            }
            guard let st = await WorkBuddyService.fetchCheckinStatus(token: ac.token, uid: ac.uid, domain: ac.domain) else { continue }
            if st.todayCheckedIn {
                // 优先用 API continuousDays（权威值）；无值时基于上次签到日期用 nextStreak 推算
                let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                let newStreak: Int
                if st.continuousDays > 0 {
                    newStreak = st.continuousDays
                } else if !prevDate.isEmpty && prevDate != today {
                    newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak, today: today)
                } else {
                    newStreak = max(prevStreak, 1)
                }
                UserDefaults.standard.set(newStreak, forKey: streakKey)
                let newReward = prevReward == 0 ? st.reward : prevReward
                if newReward > 0 {
                    UserDefaults.standard.set(newReward, forKey: rewardKey)
                }
                // 今天 history 无记录才补：streak/reward 是跨天持久值，非零不能代表「今天已记录」
                let hk = UDKey.wbCheckinHistory(ac.uid)
                if !checkinHistory(key: hk).contains(where: { $0.date == today }) {
                    appendCheckinHistory(key: hk,
                                         date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                }
                UserDefaults.standard.set(today, forKey: dateKey)
                // 已确认今天已签到，清除历史失败残留标记（与签到流程对齐）
                UserDefaults.standard.set(false, forKey: UDKey.wbCheckinFailed(ac.uid))
                UserDefaults.standard.removeObject(forKey: UDKey.wbCheckinFailDate(ac.uid))
            }
        }
        UserDefaults.standard.set(today, forKey: UDKey.wbStatusFillDate)
        syncPanel()
    }

    /// 多号签到核心：遍历账号，每号本地日期守卫（每天最多一次），签到前自动刷新 token。
    /// streak/reward 为 0 时即使今天已签也会查状态补全。
    /// 自动路径走错峰：每账号每天有随机就绪时刻（now+0~10min，wbCheckinReadyTimestamp），
    /// 未到点的账号本轮跳过（不打任何接口）；force=true（手动一键签到）绕过错峰立即全签。
    func wbAutoCheckinIfNeeded(force: Bool = false) async {
        let today = Self.todayString()
        var accounts = wbCheckinAccounts()
        for i in 0..<accounts.count {
            var ac = accounts[i]
            let dateKey = UDKey.wbCheckinDate(ac.uid)
            let streakKey = UDKey.wbCheckinStreak(ac.uid)
            let rewardKey = UDKey.wbCheckinReward(ac.uid)
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 今天已签到且 streak/reward 均有值且 history 已有今天的记录 → 跳过
            // （history 缺记录时放行进下方流程查状态补写，补上后恢复零网络跳过）
            if UserDefaults.standard.string(forKey: dateKey) == today && prevStreak > 0 && prevReward > 0
               && checkinHistory(key: UDKey.wbCheckinHistory(ac.uid)).contains(where: { $0.date == today }) { continue }

            // 错峰守卫：未到今日就绪时刻的账号本轮跳过（手动一键签到不受限）
            if !force,
               Date().timeIntervalSince1970 < Self.checkinReadyTimestamp(key: UDKey.wbCheckinReady(ac.uid), today: today) {
                continue
            }

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
                    if st.todayCheckedIn {
                        // daily-checkin 接口在「已签到」时不返回 continuous_days，需基于上次签到日期推算
                        // 优先用 API continuousDays（权威值）；无值时用 nextStreak(prevDate, prevStreak) 推算
                        let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                        let newStreak: Int
                        if st.continuousDays > 0 {
                            newStreak = st.continuousDays
                        } else if !prevDate.isEmpty && prevDate != today {
                            newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak, today: today)
                        } else {
                            newStreak = max(prevStreak, 1)
                        }
                        UserDefaults.standard.set(newStreak, forKey: streakKey)
                        let newReward = prevReward == 0 ? st.reward : prevReward
                        if newReward > 0 {
                            UserDefaults.standard.set(newReward, forKey: rewardKey)
                        }
                        // 状态补全也追加历史记录（今天 history 无记录才补：streak/reward 是跨天
                        // 持久值，非零不能代表「今天已记录」；补记时刻用当前时间，服务端不返回真实时刻）
                        let hk = UDKey.wbCheckinHistory(ac.uid)
                        if !checkinHistory(key: hk).contains(where: { $0.date == today }) {
                            appendCheckinHistory(key: hk,
                                                 date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                        }
                        // 只有确认今天已签到才写 dateKey=today；
                        // !st.available（活动不可用/token 过期）不写，避免签到流程误判已签
                        UserDefaults.standard.set(today, forKey: dateKey)
                        // 已确认签到成功，清除历史失败残留标记（与 TRAE 侧对齐）
                        UserDefaults.standard.set(false, forKey: UDKey.wbCheckinFailed(ac.uid))
                        UserDefaults.standard.removeObject(forKey: UDKey.wbCheckinFailDate(ac.uid))
                    }
                    syncPanel()
                    continue
                }
            }

            // 已签（dateKey==today）但状态补全未确认成功（如 status 查询失败）→
            // 不发起 claim，等待下轮补写历史，避免对已签账号误触发签到接口
            if UserDefaults.standard.string(forKey: dateKey) == today { continue }

            // 执行签到
            let r = await WorkBuddyService.claimCheckin(token: ac.token, uid: ac.uid, domain: ac.domain)
            if r.success {
                let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                let prevStreak2 = UserDefaults.standard.integer(forKey: streakKey)
                UserDefaults.standard.set(today, forKey: dateKey)
                let timeStr = Self.nowTimeString()
                UserDefaults.standard.set(timeStr, forKey: UDKey.wbLastCheckinTime)
                let newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak2, today: today)
                UserDefaults.standard.set(newStreak, forKey: streakKey)
                // 解析签到奖励积分（creditDesc 是 String 形式的积分数）
                let credit = Int(r.creditDesc) ?? 0
                if credit > 0 {
                    UserDefaults.standard.set(credit, forKey: rewardKey)
                }
                // 追加历史记录
                appendCheckinHistory(key: UDKey.wbCheckinHistory(ac.uid),
                                     date: today, time: timeStr, reward: credit, streak: newStreak)
                syncPanel()
                // 签到后刷新积分显示（仅当前登录号）
                if config.workbuddyEnabled, WorkBuddyService.authInfo()?.uid == ac.uid {
                    if let wb = await WorkBuddyService.fetchSummary() {
                        cacheWb = wb
                        updateTitle()
                    }
                }
                let content = UNMutableNotificationContent()
                content.title = "WorkBuddy 自动签到（\(ac.nickname)）"
                content.body = r.creditDesc.isEmpty ? "签到成功 ✓" : "签到成功 ✓ 积分：\(r.creditDesc)"
                Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wb_auto_checkin_\(ac.uid)", content: content, trigger: nil)) }
                // 签到成功清除失败标记（含日期口径，用于卡片角标/统计）
                UserDefaults.standard.set(false, forKey: UDKey.wbCheckinFailed(ac.uid))
                UserDefaults.standard.removeObject(forKey: UDKey.wbCheckinFailDate(ac.uid))
            } else {
                // 签到失败：记录失败标记 + 当日日期（用于卡片角标与「x成功 x失败」统计）
                UserDefaults.standard.set(true, forKey: UDKey.wbCheckinFailed(ac.uid))
                UserDefaults.standard.set(today, forKey: UDKey.wbCheckinFailDate(ac.uid))
                syncPanel()
            }
        }
    }

    // MARK: - 自动签到（TRAE + WorkBuddy 合并开关）

    @objc func onToggleAutoCheckin() {
        let on = !(config.traeAutoCheckin || config.workbuddyAutoCheckin)
        config.traeAutoCheckin = on
        config.workbuddyAutoCheckin = on
        autoCheckinMenuItem.state = on ? .on : .off
        ConfigStore.save(config)
        if on {
            startCheckinTimer()
            Task { await traeAutoCheckinIfNeeded() }
            Task { await wbAutoCheckinIfNeeded() }
        } else {
            stopCheckinTimer()
        }
        syncPanel()
    }

    // MARK: - 手动签到（全部账号，链路与自动签到一致）

    /// 签到成功行的 SF Symbol 信息项：状态 + 连续天数 + 奖励积分（0 值项省略）。
    private func checkinInfoItems(alreadyCheckedIn: Bool, streak: Int, reward: Int) -> [CheckinInfoItem] {
        var items = [CheckinInfoItem(symbol: "checkmark.seal", text: alreadyCheckedIn ? "已签到" : "签到成功")]
        if streak > 0 { items.append(CheckinInfoItem(symbol: "flame", text: "\(streak)\u{2009}天")) }
        if reward > 0 { items.append(CheckinInfoItem(symbol: "gift", text: "+\(reward)")) }
        return items
    }

    /// 手动触发全部账号签到：复用 traeAutoCheckinIfNeeded / wbAutoCheckinIfNeeded
    /// （含每日守卫、token 刷新、退避），完成后弹窗汇总各账号签到情况。
    @objc func onManualCheckin() {
        guard !manualCheckinInProgress else { return }
        manualCheckinInProgress = true
        syncPanel()  // 立即刷新面板：签到磁贴开始脉冲 + 禁点

        let today = Self.todayString()
        // 签到前快照：区分「本次刚签到」vs「今日早已签到」
        var traeBefore: [String: String] = [:]
        for ac in traeCheckinAccounts() {
            traeBefore[ac.uid] = UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(ac.uid)) ?? ""
        }
        var wbBefore: [String: String] = [:]
        for ac in wbCheckinAccounts() {
            wbBefore[ac.uid] = UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(ac.uid)) ?? ""
        }

        Task {
            // 与自动签到完全一致的逻辑链路（每日守卫、token 刷新、退避均生效）；
            // force 绕过两平台错峰就绪时刻：手动一键签到立即全签；
            // 平台开关里关闭了签到的平台，手动签到同样跳过（与自动签到行为一致）
            await withTaskGroup(of: Void.self) { group in
                if config.traeAutoCheckin {
                    group.addTask { await self.traeAutoCheckinIfNeeded(force: true) }
                }
                if config.workbuddyAutoCheckin {
                    group.addTask { await self.wbAutoCheckinIfNeeded(force: true) }
                }
            }

            // ── 汇总各账号签到结果 ──
            var rows: [CheckinResultRow] = []
            var okCount = 0
            var failCount = 0

            for ac in traeCheckinAccounts() {
                let dateKey = UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(ac.uid)) ?? ""
                let failed = UserDefaults.standard.string(forKey: UDKey.traeCheckinFailDate(ac.uid)) == today
                let risk = UserDefaults.standard.string(forKey: UDKey.traeCheckinRiskDate(ac.uid)) == today
                let streak = UserDefaults.standard.integer(forKey: UDKey.traeCheckinStreak(ac.uid))
                let reward = UserDefaults.standard.integer(forKey: UDKey.traeCheckinReward(ac.uid))
                if dateKey == today {
                    let infoItems = checkinInfoItems(alreadyCheckedIn: (traeBefore[ac.uid] ?? "") == today,
                                                     streak: streak, reward: reward)
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：", state: .ok, infoItems: infoItems))
                    okCount += 1
                } else if !config.traeAutoCheckin {
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：已跳过（签到已关闭）", state: .skipped))
                } else if failed || risk {
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：\(risk ? "签到失败（风控）" : "签到失败")", state: .fail))
                    failCount += 1
                } else {
                    rows.append(CheckinResultRow(text: "TRAE · \(ac.username)：未签到（token 失效或退避中）", state: .skipped))
                }
            }
            for ac in wbCheckinAccounts() {
                let dateKey = UserDefaults.standard.string(forKey: UDKey.wbCheckinDate(ac.uid)) ?? ""
                let failed = UserDefaults.standard.string(forKey: UDKey.wbCheckinFailDate(ac.uid)) == today
                let streak = UserDefaults.standard.integer(forKey: UDKey.wbCheckinStreak(ac.uid))
                let reward = UserDefaults.standard.integer(forKey: UDKey.wbCheckinReward(ac.uid))
                if dateKey == today {
                    let infoItems = checkinInfoItems(alreadyCheckedIn: (wbBefore[ac.uid] ?? "") == today,
                                                     streak: streak, reward: reward)
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：", state: .ok, infoItems: infoItems))
                    okCount += 1
                } else if !config.workbuddyAutoCheckin {
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：已跳过（签到已关闭）", state: .skipped))
                } else if failed {
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：签到失败", state: .fail))
                    failCount += 1
                } else {
                    rows.append(CheckinResultRow(text: "WorkBuddy · \(ac.nickname)：未签到（token 失效或活动不可用）", state: .skipped))
                }
            }

            manualCheckinInProgress = false
            syncPanel()  // 停掉签到磁贴的进行中脉冲（面板已关闭时无害，下次打开即常态）

            // 结果弹窗（DialogShell 原生模板）；签到期间主面板已被关闭时不打扰
            // （数据已写入，下次打开卡片可见）
            guard popoverController?.isShown == true, !rows.isEmpty else { return }
            keepPanelAliveDuring { presentCheckinResult(okCount: okCount, failCount: failCount, rows: rows) }
        }
    }

    /// 手动签到结果弹窗：沿用 DialogShell 原生模板（图标/标题居中 + 富文本结果列表 + 系统按钮），
    /// 文字规格与输入类弹窗一致（12pt、与容器等宽）
    private func presentCheckinResult(okCount: Int, failCount: Int, rows: [CheckinResultRow]) {
        let shell = DialogShell()
        shell.addIcon(NSApp.applicationIconImage)
        shell.addTitle("手动签到完成")
        // 手动签到结果较长，info 容器在输入类弹窗基准上加宽 25pt，减少账号名称换行。
        shell.contentWidth = DialogMetrics.inputWidth

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attr = NSMutableAttributedString()
        func append(_ s: String, color: NSColor) {
            attr.append(NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]))
        }
        func appendSymbol(_ name: String, color: NSColor) {
            let symbolSize: CGFloat = 11.5
            guard let source = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                  let configured = source.withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium)) else { return }
            // NSTextAttachment 不会稳定继承 surrounding foregroundColor，先把 SF Symbol
            // 显式渲染成与卡片副标题一致的灰色，避免图标在弹窗中出现不同色相/亮度。
            let imageSize = NSSize(width: symbolSize, height: symbolSize)
            let image = NSImage(size: imageSize)
            image.lockFocus()
            color.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()
            configured.draw(in: NSRect(origin: .zero, size: imageSize),
                            from: .zero, operation: .destinationIn, fraction: 1)
            image.unlockFocus()
            let attachment = NSTextAttachment()
            attachment.image = image
            // 让图标与 12pt 正文同高并保持基线视觉居中。
            attachment.bounds = NSRect(x: 0, y: -1.5, width: symbolSize, height: symbolSize)
            attr.append(NSAttributedString(attachment: attachment))
        }
        append("成功\u{2009}\(okCount) · 失败\u{2009}\(failCount)\n\n",
               color: failCount > 0 ? .systemOrange : .secondaryLabelColor)
        for row in rows {
            if !row.infoItems.isEmpty {
                let infoColor = NSColor.systemGray
                append(row.text, color: infoColor)
                for (index, item) in row.infoItems.enumerated() {
                    append(index == 0 ? "\u{2009}" : "\u{2003}", color: infoColor)
                    appendSymbol(item.symbol, color: infoColor)
                    append("\u{2009}\(item.text)", color: infoColor)
                }
                append("\n", color: infoColor)
            } else {
                let (symbol, color): (String, NSColor)
                switch row.state {
                case .ok: (symbol, color) = ("✓  ", .systemGreen)
                case .fail: (symbol, color) = ("✗  ", .systemOrange)
                case .skipped: (symbol, color) = ("–  ", .systemGray)
                }
                append(symbol, color: color)
                append(row.text + "\n", color: row.state == .fail ? .systemOrange : .secondaryLabelColor)
            }
        }
        // 去掉末行多余的换行
        if attr.length > 0 { attr.deleteCharacters(in: NSRange(location: attr.length - 1, length: 1)) }
        shell.addInfo(attr)

        shell.addButton("完成", keyEquivalent: "\r")
        _ = shell.present()
    }

    // MARK: - 签到历史

    /// 查看签到历史：汇总 TRAE / WB 各账号的签到记录，按时间倒序展示最近 20 条
    @objc func onShowCheckinHistory() {
        keepPanelAliveDuring { presentCheckinHistory() }
    }

    /// 签到历史弹窗：沿用 DialogShell 原生模板（图标/标题居中 + 富文本结果列表 + 系统按钮），
    /// 文字规格与输入类弹窗一致（12pt、与容器等宽）；长文阅读类，内容宽 +38
    /// （8 抵消 sidePadding 增量 + 30 加宽 info 列表）
    private func presentCheckinHistory() {
        // 记录的 date 为 yyyy-MM-dd、time 为 M-d HH:mm（appendCheckinHistory 写入口径）
        struct Row { let date: String; let time: String; let text: String }
        var rows: [Row] = []
        for ac in traeCheckinAccounts() {
            for r in checkinHistory(key: UDKey.traeCheckinHistory(ac.uid)) {
                let reward = r.reward > 0 ? " 积分+\(r.reward)" : ""
                rows.append(Row(date: r.date, time: r.time,
                                text: "\(r.time) TRAE · \(ac.username)\(reward) 连续\(r.streak)天"))
            }
        }
        for ac in wbCheckinAccounts() {
            for r in checkinHistory(key: UDKey.wbCheckinHistory(ac.uid)) {
                let reward = r.reward > 0 ? " 积分+\(r.reward)" : ""
                rows.append(Row(date: r.date, time: r.time,
                                text: "\(r.time) WorkBuddy · \(ac.nickname)\(reward) 连续\(r.streak)天"))
            }
        }
        // 仅显示最近两天（今天 + 昨天）；date 为 yyyy-MM-dd，字符串序即日期序
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Date()).map { Self.dfDay.string(from: $0) } ?? ""
        let sorted = rows
            .filter { $0.date >= cutoff }
            .sorted { $0.date == $1.date ? $0.time > $1.time : $0.date > $1.date }

        let shell = DialogShell()
        shell.addIcon(NSApp.applicationIconImage)
        shell.addTitle("签到历史")
        shell.contentWidth = DialogMetrics.inputWidth + 38
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attr = NSMutableAttributedString()
        func append(_ s: String, color: NSColor) {
            attr.append(NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color,
                .paragraphStyle: para,
            ]))
        }
        if sorted.isEmpty {
            append("最近两天暂无签到记录", color: .secondaryLabelColor)
        } else {
            append("最近两天共 \(sorted.count) 条\n\n", color: .secondaryLabelColor)
            for r in sorted {
                append(r.text + "\n", color: .secondaryLabelColor)
            }
            // 去掉末行多余的换行
            if attr.length > 0 { attr.deleteCharacters(in: NSRange(location: attr.length - 1, length: 1)) }
        }
        shell.addInfo(attr)
        shell.addButton("关闭", keyEquivalent: "\r")
        _ = shell.present()
    }

    /// 补全 TRAE 多账号签到 streak/reward：遍历所有账号，streak 或 reward 为 0 时查状态 API 填充。
    /// 每天最多跑一次（trae_status_fill_date 守卫），避免每次余额刷新都打 status API 触发风控。
    /// auto-checkin 已开启且主账号今日已签到时跳过（签到流程会顺带补全 streak/reward，去重）。
    func traeCheckinStatusFill() async {
        let today = Self.todayString()
        // 每天最多补全一次，避免每次余额刷新都打 status API 触发风控
        let fillDateKey = UDKey.traeStatusFillDate
        if UserDefaults.standard.string(forKey: fillDateKey) == today { return }
        let mainUid = TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? ""
        // auto-checkin 已开启且主账号今日已签到 → 签到流程会顺带补全 streak/reward，跳过
        if config.traeAutoCheckin && !mainUid.isEmpty
           && UserDefaults.standard.string(forKey: UDKey.traeCheckinDate(mainUid)) == today {
            UserDefaults.standard.set(today, forKey: fillDateKey)
            return
        }
        let accounts = traeCheckinAccounts()
        for ac in accounts {
            let dateKey = UDKey.traeCheckinDate(ac.uid)
            let streakKey = UDKey.traeCheckinStreak(ac.uid)
            let rewardKey = UDKey.traeCheckinReward(ac.uid)
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 仅当今天已签到且 streak/reward 均有值时才跳过
            if prevStreak > 0 && prevReward > 0 && UserDefaults.standard.string(forKey: dateKey) == today { continue }
            // token：主账号从 storage.json；其他账号从 encryptedAuthInfo
            let token: String? = (ac.uid == mainUid)
                ? TraeService.getToken(storagePath: config.traeStoragePath)
                : TraeService.getTokenFromEncrypted(ac.encryptedAuthInfo)
            guard let tk = token, !tk.isEmpty else { continue }
            guard let st = await TraeService.fetchCheckinStatus(token: tk, storagePath: config.traeStoragePath) else { continue }
            if st.checkedIn {
                // 优先用 API continuousDays；无值时基于上次签到日期用 nextStreak 推算
                let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                let newStreak: Int
                if st.continuousDays > 0 {
                    newStreak = st.continuousDays
                } else if !prevDate.isEmpty && prevDate != today {
                    newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak, today: today)
                } else {
                    newStreak = max(prevStreak, 1)
                }
                UserDefaults.standard.set(newStreak, forKey: streakKey)
                let newReward = prevReward == 0 ? st.reward : prevReward
                if newReward > 0 {
                    UserDefaults.standard.set(newReward, forKey: rewardKey)
                }
                if !checkinHistory(key: UDKey.traeCheckinHistory(ac.uid)).contains(where: { $0.date == today }) {
                    appendCheckinHistory(key: UDKey.traeCheckinHistory(ac.uid),
                                         date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                }
                UserDefaults.standard.set(today, forKey: dateKey)
            }
        }
        UserDefaults.standard.set(today, forKey: UDKey.traeStatusFillDate)
        syncPanel()
    }


    /// 多账号签到核心：遍历所有 TRAE 账号，每号本地日期守卫（每天最多一次），
    /// streak/reward 为 0 时即使今天已签也会查状态补全。每号独立退避，避免触发风控。
    /// 文件日志写入 /tmp/iBalance_trae_checkin.log 便于测试观察。
    /// force=true（手动一键签到）绕过错峰就绪时刻立即全签；退避机制始终生效（防风控保护）。
    func traeAutoCheckinIfNeeded(force: Bool = false) async {
        let today = Self.todayString()
        let accounts = traeCheckinAccounts()
        let mainUid = TraeService.readAuthInfo(storagePath: config.traeStoragePath)?.uid ?? ""
        // 与 Logger.Channel.traeCheckin 同一落点（/tmp/iBalance_trae_checkin.log）
        func log(_ msg: String) { Logger.log(.traeCheckin, msg) }
        log("=== 开始多账号签到，共 \(accounts.count) 个账号（mainUid=\(mainUid)）===")
        for ac in accounts {
            let dateKey = UDKey.traeCheckinDate(ac.uid)
            let streakKey = UDKey.traeCheckinStreak(ac.uid)
            let rewardKey = UDKey.traeCheckinReward(ac.uid)
            let failedKey = UDKey.traeCheckinFailed(ac.uid)
            let retryKey = UDKey.traeNextRetryTime(ac.uid)
            let timeKey = UDKey.traeLastCheckinTime(ac.uid)
            let prevStreak = UserDefaults.standard.integer(forKey: streakKey)
            let prevReward = UserDefaults.standard.integer(forKey: rewardKey)
            // 今天已签到 → 跳过（强本地守卫，零网络）；history 还没有今天的记录时放行，
            // 走下方状态查证补写历史（补上后恢复零网络跳过）
            if UserDefaults.standard.string(forKey: dateKey) == today
               && checkinHistory(key: UDKey.traeCheckinHistory(ac.uid)).contains(where: { $0.date == today }) {
                log("[\(ac.uid)] 已签到，跳过")
                continue
            }
            // 错峰守卫：未到今日就绪时刻的账号本轮跳过（手动一键签到不受限）
            if !force,
               Date().timeIntervalSince1970 < Self.checkinReadyTimestamp(key: UDKey.traeCheckinReady(ac.uid), today: today) {
                continue
            }
            // token：主账号从 storage.json 解密；其他账号从 encryptedAuthInfo 解密
            let token: String? = (ac.uid == mainUid)
                ? TraeService.getToken(storagePath: config.traeStoragePath)
                : TraeService.getTokenFromEncrypted(ac.encryptedAuthInfo)
            guard let tk = token, !tk.isEmpty else {
                log("[\(ac.uid)] token 解密失败，跳过")
                continue
            }

            // 风控日手动重试额度（force 专用）：手动一键签到时对风控账号放行 status/claim 重试，
            // 否则风控退避到明天、当天角标状态永远无法更新；每账号每天最多 maxManualRiskRetriesPerDay 次，
            // 同一轮签到内只消耗一次额度（status/claim 共享），防止反复触发服务端风控
            let riskToday = UserDefaults.standard.string(forKey: UDKey.traeCheckinRiskDate(ac.uid)) == today
            var manualRiskRetryUsed = Self.manualRetryCount(key: UDKey.traeManualRetryCount(ac.uid), today: today)
            var manualRiskRetryGranted = false
            func grantManualRiskRetry() -> Bool {
                if manualRiskRetryGranted { return true }
                guard manualRiskRetryUsed < Self.maxManualRiskRetriesPerDay else { return false }
                manualRiskRetryUsed += 1
                manualRiskRetryGranted = true
                UserDefaults.standard.set("\(today)|\(manualRiskRetryUsed)", forKey: UDKey.traeManualRetryCount(ac.uid))
                return true
            }
            // status 退避：status 查询失败时短退避，避免反复打触发风控
            let statusRetryKey = UDKey.traeStatusRetry(ac.uid)
            if let rt = UserDefaults.standard.object(forKey: statusRetryKey) as? Date, Date() < rt {
                if force && riskToday && grantManualRiskRetry() {
                    log("[\(ac.uid)] status 退避期内，手动重试 \(manualRiskRetryUsed)/\(Self.maxManualRiskRetriesPerDay)")
                } else {
                    log("[\(ac.uid)] status 退避期内，跳过")
                    continue
                }
            }
            let stOpt = await TraeService.fetchCheckinStatus(token: tk, storagePath: config.traeStoragePath)
            guard let st = stOpt else {
                // status 查询失败（网络/风控）：递增退避 5min→10min→…→60min 封顶，
                // 防止 60s 轮询粒度下失败账号被反复重试（风控场景越打越糟）
                let failCountKey = UDKey.traeStatusFailCount(ac.uid)
                let fails = UserDefaults.standard.integer(forKey: failCountKey) + 1
                UserDefaults.standard.set(fails, forKey: failCountKey)
                let backoff = min(TimeInterval(300) * pow(2, Double(fails - 1)), 3600)
                UserDefaults.standard.set(Date().addingTimeInterval(backoff), forKey: statusRetryKey)
                log("[\(ac.uid)] status 查询失败 x\(fails)，退避 \(Int(backoff))s")
                continue
            }
            UserDefaults.standard.set(0, forKey: UDKey.traeStatusFailCount(ac.uid))
            log("[\(ac.uid)] 状态查询 enable=\(st.enable) checkedIn=\(st.checkedIn) continuousDays=\(st.continuousDays) reward=\(st.reward)")
            if !st.enable || st.checkedIn {
                if st.checkedIn {
                    let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                    let newStreak: Int
                    if st.continuousDays > 0 {
                        newStreak = st.continuousDays
                    } else if !prevDate.isEmpty && prevDate != today {
                        newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak, today: today)
                    } else {
                        newStreak = max(prevStreak, 1)
                    }
                    UserDefaults.standard.set(newStreak, forKey: streakKey)
                    let newReward = prevReward == 0 ? st.reward : prevReward
                    if newReward > 0 {
                        UserDefaults.standard.set(newReward, forKey: rewardKey)
                    }
                    if !checkinHistory(key: UDKey.traeCheckinHistory(ac.uid)).contains(where: { $0.date == today }) {
                        appendCheckinHistory(key: UDKey.traeCheckinHistory(ac.uid),
                                             date: today, time: Self.nowTimeString(), reward: newReward, streak: newStreak)
                    }
                    UserDefaults.standard.set(today, forKey: dateKey)
                    UserDefaults.standard.removeObject(forKey: retryKey)
                    UserDefaults.standard.set(false, forKey: failedKey)
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinFailDate(ac.uid))
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinRiskDate(ac.uid))
                    log("[\(ac.uid)] 服务端已签到，补全 streak=\(newStreak) reward=\(newReward)")
                }
                syncPanel()
                continue
            }
            // 退避检查：在退避期内不调 claim，避免频繁请求触发服务端风控。
            // 旧版本风控只写了 failDate（无 riskDate）：检测到「剩余退避 > 30 分钟」的
            // 长退避（普通失败仅退避 5 分钟，只有风控会封顶到明天）即视为存量风控，
            // 补写风控标记迁移口径（角标橙黄、统计计「风控」）——不依赖手动签到，自动轮询即可完成迁移。
            // 风控退避例外：手动签到且当日额度未用完时放行重试（否则当天角标状态永远无法更新）
            if let retryTime = UserDefaults.standard.object(forKey: retryKey) as? Date,
               Date() < retryTime {
                let legacyRiskBackoff = !riskToday && retryTime.timeIntervalSinceNow > 1800
                if legacyRiskBackoff {
                    UserDefaults.standard.set(today, forKey: UDKey.traeCheckinRiskDate(ac.uid))
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinFailDate(ac.uid))
                    log("[\(ac.uid)] 存量风控退避（无风控标记），补写风控标记")
                }
                if force && (riskToday || legacyRiskBackoff) && grantManualRiskRetry() {
                    log("[\(ac.uid)] 风控退避期内，手动重试 \(manualRiskRetryUsed)/\(Self.maxManualRiskRetriesPerDay)")
                } else {
                    log("[\(ac.uid)] 退避期内，跳过（至 \(retryTime)）")
                    continue
                }
            }
            // 已签（dateKey==today）但状态补全未确认成功（如 status 查询失败）→
            // 不发起 claim，等待下轮补写历史，避免对已签账号误触发签到接口
            if UserDefaults.standard.string(forKey: dateKey) == today {
                log("[\(ac.uid)] 今日已签但历史待补全，跳过 claim")
                continue
            }
            log("[\(ac.uid)] 开始执行签到请求…")
            let (httpStatus, respJson) = await TraeService.claimCheckin(token: tk, storagePath: config.traeStoragePath)
            let bizCode = respJson?["code"] as? Int
            log("[\(ac.uid)] 签到响应 http=\(httpStatus) bizCode=\(bizCode ?? -1) body=\(respJson ?? [:])")
            if httpStatus == 200 && bizCode == 0 {
                let prevDate = UserDefaults.standard.string(forKey: dateKey) ?? ""
                let prevStreak2 = UserDefaults.standard.integer(forKey: streakKey)
                UserDefaults.standard.set(today, forKey: dateKey)
                let timeStr = Self.nowTimeString()
                UserDefaults.standard.set(timeStr, forKey: timeKey)
                let newStreak = Self.nextStreak(prevDate: prevDate, prevStreak: prevStreak2, today: today)
                UserDefaults.standard.set(newStreak, forKey: streakKey)
                // 解析签到奖励积分（data.reward.credit / data.credit / data.credits 等）
                let data = respJson?["data"] as? [String: Any]
                let reward = (data?["reward"] as? [String: Any])?["credit"] as? Int
                    ?? data?["credit"] as? Int
                    ?? data?["credits"] as? Int
                    ?? data?["today_credit"] as? Int
                    ?? 0
                if reward > 0 {
                    UserDefaults.standard.set(reward, forKey: rewardKey)
                }
                appendCheckinHistory(key: UDKey.traeCheckinHistory(ac.uid),
                                     date: today, time: timeStr, reward: reward, streak: newStreak)
                updateAutoCheckinMenuTitle()
                UserDefaults.standard.set(false, forKey: failedKey)
                UserDefaults.standard.removeObject(forKey: retryKey)
                UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinFailDate(ac.uid))
                UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinRiskDate(ac.uid))
                log("[\(ac.uid)] 签到成功 streak=\(newStreak) reward=\(reward)")
                // 刷新该账号余额：主账号从 storage.json 查询；其他账号用 token 查询
                if ac.uid == mainUid {
                    if let credits = await TraeService.fetchCredits(storagePath: config.traeStoragePath) {
                        cacheTrae = credits
                        cacheTraeAccounts[ac.uid] = credits
                        updateTitle()
                    }
                } else if let r = await TraeService.fetchCreditsForToken(tk) {
                    cacheTraeAccounts[ac.uid] = r
                }
                // 签到成功通知（每号独立 identifier，避免互相覆盖）
                let content = UNMutableNotificationContent()
                content.title = "TRAE 自动签到"
                content.body = "账号 \(ac.username) 签到成功 ✓"
                Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "trae_auto_checkin_\(ac.uid)", content: content, trigger: nil)) }
            } else {
                // 风控判定：9074（操作太过频繁）是服务端对非客户端流量的传输层风控，
                // 提示文案含「频繁/frequent/rate limit/too many」同理 → 记风控标记
                // （角标橙黄色、统计计「x风控」不计「x失败」），重试无意义，当天不再尝试；
                // 其他失败记失败标记，退避 5 分钟
                let msg = (respJson?["msg"] as? String) ?? (respJson?["message"] as? String) ?? ""
                let lower = msg.lowercased()
                let isRisk = bizCode == 9074 || msg.contains("频繁")
                    || lower.contains("frequent") || lower.contains("rate limit") || lower.contains("too many")
                UserDefaults.standard.set(true, forKey: failedKey)
                if isRisk {
                    UserDefaults.standard.set(today, forKey: UDKey.traeCheckinRiskDate(ac.uid))
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinFailDate(ac.uid))
                } else {
                    UserDefaults.standard.set(today, forKey: UDKey.traeCheckinFailDate(ac.uid))
                    UserDefaults.standard.removeObject(forKey: UDKey.traeCheckinRiskDate(ac.uid))
                }
                let backoff: TimeInterval = isRisk ? Self.secondsUntilTomorrow() : 300
                UserDefaults.standard.set(Date().addingTimeInterval(backoff), forKey: retryKey)
                log("[\(ac.uid)] 签到失败（\(isRisk ? "风控" : "待重试")），退避 \(backoff)s")
            }
            // 账号间间隔 3 秒，避免同设备短时间内连续请求签到触发服务端风控
            if ac.uid != accounts.last?.uid {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        log("=== 多账号签到结束 ===\n")
        syncPanel()
    }

    // MARK: - 签到定时器

    func startCheckinTimer() {
        stopCheckinTimer()
        guard config.traeAutoCheckin || config.workbuddyAutoCheckin else { return }
        // 60s 粒度轮询：为 WB 每账号随机就绪时刻（错峰窗口 10 分钟）提供判定精度；
        // 未到点/已签账号只做 UserDefaults 比较即跳过，不发网络请求
        checkinTimer = Timer.scheduledTimer(timeInterval: 60,
                                            target: self,
                                            selector: #selector(onCheckinTimerFired),
                                            userInfo: nil,
                                            repeats: true)
    }

    func stopCheckinTimer() {
        checkinTimer?.invalidate()
        checkinTimer = nil
    }

    @objc private func onCheckinTimerFired() {
        // 60s 粒度轮询（两平台均按各自错峰就绪时刻判定）；未到点/已签账号零网络跳过，
        // 失败重试由各平台退避机制控制（TRAE status 递增退避 / claim 9074 当天熔断）
        if config.traeAutoCheckin { Task { await traeAutoCheckinIfNeeded() } }
        if config.workbuddyAutoCheckin { Task { await wbAutoCheckinIfNeeded() } }
    }

    /// 更新自动签到菜单标题，附上最近签到时间
    /// TRAE 多账号取所有账号中最晚的签到时间
    func updateAutoCheckinMenuTitle() {
        var traeTime = ""
        for ac in traeCheckinAccounts() {
            if let t = UserDefaults.standard.string(forKey: UDKey.traeLastCheckinTime(ac.uid)), !t.isEmpty {
                traeTime = Self.latestCheckinTime(trae: traeTime, wb: t) ?? t
            }
        }
        let wbTime = UserDefaults.standard.string(forKey: UDKey.wbLastCheckinTime) ?? ""
        var parts: [String] = []
        if !traeTime.isEmpty { parts.append("TRAE \(traeTime)") }
        if !wbTime.isEmpty { parts.append("WB \(wbTime)") }
        if parts.isEmpty {
            autoCheckinMenuItem.title = "自动签到"
        } else {
            autoCheckinMenuItem.title = "自动签到（\(parts.joined(separator: " · "))）"
        }
        syncPanel()
    }

    // MARK: - 签到历史记录

    /// 签到历史记录条目
    struct CheckinRecord: Codable {
        let date: String       // yyyy-MM-dd
        let time: String       // HH:mm:ss
        let reward: Int        // 签到奖励积分
        let streak: Int        // 当时的连续天数
    }

    /// 追加一条签到记录（同一天同 uid 仅保留最后一次）
    private func appendCheckinHistory(key: String, date: String, time: String, reward: Int, streak: Int) {
        var list = checkinHistory(key: key)
        list.removeAll { $0.date == date }
        list.append(CheckinRecord(date: date, time: time, reward: reward, streak: streak))
        // 仅保留最近 90 天
        if list.count > 90 { list.removeFirst(list.count - 90) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 读取签到历史
    private func checkinHistory(key: String) -> [CheckinRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CheckinRecord].self, from: data) else { return [] }
        return list
    }

}

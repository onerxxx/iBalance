// Qwen.swift — 千问 Token Plan（platform.qianwenai.com）周期额度查询
// 登录态采集与落盘缓存走 BrowserCookieStore 通用管线（与 ZhiPu 同款）：
// Edge/Chrome Cookies 的 login_qianwenai_ticket（v10 解密）→ 缓存 qwen_ticket.json，
// 后续刷新不碰钥匙串；接口报登录态失效时清缓存重采一轮自愈。
// 拿到 ticket 后调千问控制台网关（BroadScopeAspnGateway，实现取回自
// git 67eeb0e~1 Services/Qwen.swift）：先取 sec_token（2026-10-18 起由
// platform-home 的 /tool/user/info.json 下发，不再内联在计费页 HTML 里），
// 再查 subscription / quota-config / usage，按周期用量百分比推算剩余额度。
import Foundation

enum QwenService {
    /// 周期额度快照（套餐口径）。
    /// ⚠️ 字段名 `week*` 是历史命名：2026-09-24 千问把计费口径从「周」改成「月」
    /// （quota-config 的 weekly → five_hour + monthly，usage 的 per1Week* → per1Month*），
    /// 这里沿用旧字段名以免动 Config.QwenAmount 的落盘键（改键会打回旧缓存配置），
    /// 但取值口径已是月度：weekRem/weekLimit = 本月剩余/月上限，weekResetAt = 月度重置时刻。
    struct Quota {
        let weekRem: Double         // 本周期剩余（额度单位）
        let weekLimit: Double       // 周期额度上限
        let remainingDays: Int      // API 回传的剩余自然日（>0=还剩几天，0=今天，负数=已过期）
        let expireAt: TimeInterval  // 套餐到期时间戳（秒），0 = 未知
        let weekResetAt: TimeInterval  // 周期限额重置时间戳（秒，usage.per1MonthResetTime），0 = 未知
    }

    /// 登录态 Cookie 名与站点（与浏览器站内一致）
    private static let cookieName = "login_qianwenai_ticket"
    private static let cacheFilename = "qwen_ticket.json"
    /// sec_token 下发接口（等同前端 shared.js 的 bP()：cn 站固定 platform-home 域名）
    private static let secTokenURL = URL(string: "https://platform-home.qianwenai.com/tool/user/info.json")

    // MARK: - 凭据解析（手填覆盖 > 本地缓存 > 浏览器采集）

    static func resolveTicket(override: String) -> BrowserCookieStore.Resolution {
        BrowserCookieStore.resolveDetailed(override: override, cookieName: cookieName,
                                           hostLike: "%qianwenai.com%", cacheFilename: cacheFilename, logTag: "[Qwen]") { row, password in
            // 老版本浏览器：value 列即明文 ticket
            let trimmed = row.plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeTicket(trimmed) { return trimmed }
            guard let plain = BrowserCookieStore.decryptV10(row, password: password),
                  let ticket = extractTicket(from: plain) else { return nil }
            return ticket
        }
    }

    static func clearCachedTicket() {
        BrowserCookieStore.clearCachedToken(filename: cacheFilename)
    }

    /// v10 解密后的明文提取 ticket：老版本即明文；App-Bound 填充则前 32 字节为随机前缀
    ///（随机字节几乎不可能整体为可打印 ASCII，先验整体再验去前缀，无误判风险）
    private static func extractTicket(from plain: Data) -> String? {
        if let s = String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           looksLikeTicket(s) { return s }
        guard plain.count > 32,
              let s = String(data: plain.dropFirst(32), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              looksLikeTicket(s) else { return nil }
        return s
    }

    /// ticket 粗校验：长度合理且纯可打印 ASCII 无空白
    private static func looksLikeTicket(_ s: String) -> Bool {
        s.count >= 16 && s.allSatisfy { ($0.asciiValue ?? 0) >= 0x21 && ($0.asciiValue ?? 0) <= 0x7e }
    }

    // MARK: - 控制台网关

    /// 表单百分号编码（application/x-www-form-urlencoded 安全字符集）
    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - sec_token

    /// sec_token 取值结果：token 成功；notLoggedIn = 服务端明确要求登录（Cookie 失效）；
    /// network = 传输层失败；bad = 其它异常
    private enum SecTokenResult {
        case token(String)
        case notLoggedIn
        case network
        case bad(String)
    }

    /// 取控制台 sec_token（调网关必带）。对齐前端 shared.js：GET /tool/user/info.json
    /// → `{ code: "200", data: { secToken } }`；未登录返回 `code: "ConsoleNeedLogin"`。
    /// ⚠️ 2026-10-18 前该值内联在计费页 HTML（`SEC_TOKEN: "..."`），平台改版后 HTML 里
    /// 已彻底没有（页面退化成 11KB 的空壳 SPA），旧正则必然取不到 —— 那会把「取不到
    /// sec_token」误判成登录态失效，进而每轮都在「清缓存重采 → 又失败」里空转。
    private static func fetchSecToken(ticket: String, ua: String) async -> SecTokenResult {
        guard let url = secTokenURL else { return .bad("URL错误") }
        let (data, status) = await HTTP.requestWithRetry(url: url, headers: [
            "Accept": "application/json",
            "Cookie": "\(cookieName)=\(ticket)",
            "User-Agent": ua
        ], timeout: 15, retries: 1, backoff: 1.2)
        if status == 0 { return .network }
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .bad("HTTP \(status)（登录态可能已失效）")
        }
        let code = (json["code"] as? String) ?? (json["code"] as? Int).map(String.init) ?? ""
        if code == "ConsoleNeedLogin" { return .notLoggedIn }
        guard code == "200",
              let inner = json["data"] as? [String: Any],
              let sec = inner["secToken"] as? String,
              !sec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let msg = (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "code=\(code.isEmpty ? "?" : code)"
            return .bad("未取到 sec_token（\(msg)）")
        }
        return .token(sec)
    }

    /// 网关调用结果：payload 成功；network 网络层失败（超时/断网，status=0，
    /// 与登录态无关，不得触发清缓存重采）；bad 响应异常（可能登录态失效）
    private enum GatewayResult {
        case payload([String: Any])
        case network
        case bad
    }

    /// 调千问控制台网关 api.json（BroadScopeAspnGateway），返回 data.DataV2.data.data 载荷。
    /// ⚠️ 该网关响应抖动极大（2026-10-14 实测：中位 ~3.2s、尾部 22.7s，偶发
    /// `SSL: UNEXPECTED_EOF_WHILE_READING` 与 `-1005 连接丢失`，单发失败率 8~12%），
    /// 且**只有 Qwen 走这个网关**（其余平台零失败）⇒ 必须带重试，否则每轮刷新都有
    /// 一成概率落到「刷新失败」分支，footer 与系统通知会频繁报错。
    /// 注意：timeout 仍取 15s（网关 P99 超出也无更好办法——单个接口拉长会顶穿
    /// performRefresh 的 45s totalBudget，见 TRAPS「Qwen 网关抖动」）。
    private static func gateway(api: String, dataJson: String, secToken: String, ticket: String) async -> GatewayResult {
        let params = "{\"Api\":\"\(api)\",\"Data\":\(dataJson),\"V\":\"1.0\"}"
        let body = "product=sfm_bailian&action=BroadScopeAspnGateway&sec_token=\(formEncode(secToken))&region=cn-beijing&params=\(formEncode(params))"
        guard let url = URL(string: "https://cs-data.qianwenai.com/data/api.json?product=sfm_bailian&action=BroadScopeAspnGateway&api=\(formEncode(api))") else { return .bad }
        let (data, status) = await HTTP.requestWithRetry(url: url, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "Cookie": "\(cookieName)=\(ticket)",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ], body: Data(body.utf8), timeout: 15, retries: 1, backoff: 1.2)
        // status=0：超时/断网等传输层失败——非登录态问题，调用方直接报网络错误，
        // 不进入「清缓存重采」路径（曾导致超时后再跑一轮 15s，面板「刷新中」卡 30s+）
        guard status != 0 else { return .network }
        guard status == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outer = json["data"] as? [String: Any],
              let dataV2 = outer["DataV2"] as? [String: Any],
              let inner = dataV2["data"] as? [String: Any],
              let payload = inner["data"] as? [String: Any] else { return .bad }
        return .payload(payload)
    }

    // MARK: - 配额查询

    /// 查询千问 Token Plan 周期额度剩余。ticket 为空静默跳过；
    /// authFailed=true 表示登录态可能失效（调用方清缓存重采），error 供通知/footer 展示。
    static func fetch(ticket: String) async -> (quota: Quota?, authFailed: Bool, error: String) {
        guard !ticket.isEmpty else { return (nil, false, "") }
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        let secToken: String
        switch await fetchSecToken(ticket: ticket, ua: ua) {
        case .token(let t):
            secToken = t
        case .notLoggedIn:
            return (nil, true, "登录态已失效（请在浏览器重新登录千问）")
        case .network:
            return (nil, false, "网络错误")
        case .bad(let msg):
            return (nil, true, msg)
        }
        let cornerstone = "{\"domain\":\"platform.qianwenai.com\",\"consoleSite\":\"QIANWENAI\",\"console\":\"ONE_CONSOLE\",\"xsp_lang\":\"zh-CN\",\"protocol\":\"V2\",\"productCode\":\"p_efm\"}"
        let apis: [(name: String, api: String, dataJson: String)] = [
            ("subscription", "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription",
             "{\"commodityCode\":\"sfm_tokenplansolo_public_cn\",\"cornerstoneParam\":\(cornerstone)}"),
            ("quota-config", "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config",
             "{\"cornerstoneParam\":\(cornerstone)}"),
            ("usage", "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
             "{\"cornerstoneParam\":\(cornerstone)}"),
        ]
        var payloads: [String: [String: Any]] = [:]
        for a in apis {
            switch await gateway(api: a.api, dataJson: a.dataJson, secToken: secToken, ticket: ticket) {
            case .payload(let p): payloads[a.name] = p
            case .network: return (nil, false, "配额接口网络超时（\(a.name)）")
            case .bad: return (nil, true, "配额接口调用失败（登录态可能已失效）")
            }
        }
        guard let sub = payloads["subscription"],
              let quota = payloads["quota-config"],
              let usage = payloads["usage"] else {
            return (nil, true, "配额接口调用失败（登录态可能已失效）")
        }
        let specCode = sub["specCode"] as? String ?? "lite"
        guard let specQuota = quota[specCode] as? [String: Any] else {
            return (nil, false, "接口缺少套餐规格 \(specCode)")
        }
        // 2026-09-24 起千问口径为月：quota-config 的该档位给 monthly（另有 five_hour 滚动窗口，无用量接口取不到），
        // usage 给 per1MonthPercentage / per1MonthResetTime
        let limit = jsonNum(specQuota["monthly"])
        let usedPct = (usage["per1MonthPercentage"] as? Double) ?? 0
        // 套餐到期时间：endTime 单位为毫秒，转秒级时间戳
        let expireAt = jsonNum(sub["endTime"]) / 1000.0
        // 直接用 API 返回的 remainingDays（官网同值），避免本地计算偏差
        let remainingDays = (sub["remainingDays"] as? Int) ?? Int(jsonNum(sub["remainingDays"]))
        guard limit > 0 else {
            return (nil, false, "月额度为 0（套餐不含月额度）")
        }
        // 周期限额重置时间：usage.per1MonthResetTime 毫秒 → 秒
        let weekResetAt = jsonNum(usage["per1MonthResetTime"]) / 1000.0
        return (Quota(weekRem: limit * (1 - usedPct), weekLimit: limit,
                      remainingDays: remainingDays, expireAt: expireAt,
                      weekResetAt: weekResetAt), false, "")
    }
}

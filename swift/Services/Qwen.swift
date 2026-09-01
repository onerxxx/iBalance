// Qwen.swift — 千问 Token Plan（platform.qianwenai.com）周额度查询
// 登录态采集与落盘缓存走 BrowserCookieStore 通用管线（与 ZhiPu 同款）：
// Edge/Chrome Cookies 的 login_qianwenai_ticket（v10 解密）→ 缓存 qwen_ticket.json，
// 后续刷新不碰钥匙串；接口报登录态失效时清缓存重采一轮自愈。
// 拿到 ticket 后调千问控制台网关 api.json（BroadScopeAspnGateway，实现取回自
// git 67eeb0e~1 Services/Qianwen.swift）：先从计费页 HTML 抓 SEC_TOKEN，
// 再查 subscription / quota-config / usage，按周用量百分比推算本周剩余额度。
import Foundation

enum QwenService {
    /// 周额度快照（套餐口径）
    struct Quota {
        let weekRem: Double         // 本周剩余（额度单位）
        let weekLimit: Double       // 周额度上限
        let remainingDays: Int      // API 回传的剩余自然日（>0=还剩几天，0=今天，负数=已过期）
        let expireAt: TimeInterval  // 套餐到期时间戳（秒），0 = 未知
        let weekResetAt: TimeInterval  // 7 天限额重置时间戳（秒，usage.per1WeekResetTime），0 = 未知
    }

    /// 登录态 Cookie 名与站点（与浏览器站内一致）
    private static let cookieName = "login_qianwenai_ticket"
    private static let cacheFilename = "qwen_ticket.json"
    private static let billingURL = "https://platform.qianwenai.com/home/billing/subscription/token-plan-individual"

    // MARK: - 凭据解析（手填覆盖 > 本地缓存 > 浏览器采集）

    static func resolveTicket(override: String) -> String? {
        BrowserCookieStore.resolve(override: override, cookieName: cookieName,
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

    /// 正则提取首个捕获组
    private static func regexFirstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// 网关调用结果：payload 成功；network 网络层失败（超时/断网，status=0，
    /// 与登录态无关，不得触发清缓存重采）；bad 响应异常（可能登录态失效）
    private enum GatewayResult {
        case payload([String: Any])
        case network
        case bad
    }

    /// 调千问控制台网关 api.json（BroadScopeAspnGateway），返回 data.DataV2.data.data 载荷
    private static func gateway(api: String, dataJson: String, secToken: String, ticket: String) async -> GatewayResult {
        let params = "{\"Api\":\"\(api)\",\"Data\":\(dataJson),\"V\":\"1.0\"}"
        let body = "product=sfm_bailian&action=BroadScopeAspnGateway&sec_token=\(formEncode(secToken))&region=cn-beijing&params=\(formEncode(params))"
        guard let url = URL(string: "https://cs-data.qianwenai.com/data/api.json?product=sfm_bailian&action=BroadScopeAspnGateway&api=\(formEncode(api))") else { return .bad }
        let (data, status) = await HTTP.request(url: url, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "Cookie": "\(cookieName)=\(ticket)",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ], body: Data(body.utf8), timeout: 15)
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

    /// 查询千问 Token Plan 周额度剩余。ticket 为空静默跳过；
    /// authFailed=true 表示登录态可能失效（调用方清缓存重采），error 供通知/footer 展示。
    static func fetch(ticket: String) async -> (quota: Quota?, authFailed: Bool, error: String) {
        guard !ticket.isEmpty else { return (nil, false, "") }
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        guard let pageURL = URL(string: billingURL) else { return (nil, false, "URL错误") }
        let (htmlData, status) = await HTTP.requestWithRetry(url: pageURL, headers: [
            "Cookie": "\(cookieName)=\(ticket)",
            "User-Agent": ua
        ], timeout: 15)
        if status == 0 { return (nil, false, "网络错误") }
        guard status == 200, let htmlData,
              let html = String(data: htmlData, encoding: .utf8) else {
            return (nil, true, "HTTP \(status)（登录态可能已失效）")
        }
        guard let secToken = regexFirstGroup("SEC_TOKEN:\\s*\"([^\"]+)\"", in: html) else {
            return (nil, true, "未取到 SEC_TOKEN（登录态可能已失效）")
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
        let weekly = jsonNum(specQuota["weekly"])
        let weekPct = (usage["per1WeekPercentage"] as? Double) ?? 0
        // 套餐到期时间：endTime 单位为毫秒，转秒级时间戳
        let expireAt = jsonNum(sub["endTime"]) / 1000.0
        // 直接用 API 返回的 remainingDays（官网同值），避免本地计算偏差
        let remainingDays = (sub["remainingDays"] as? Int) ?? Int(jsonNum(sub["remainingDays"]))
        guard weekly > 0 else {
            return (nil, false, "周额度为 0（套餐不含周额度）")
        }
        // 7 天限额重置时间：usage.per1WeekResetTime 毫秒 → 秒
        let weekResetAt = jsonNum(usage["per1WeekResetTime"]) / 1000.0
        return (Quota(weekRem: weekly * (1 - weekPct), weekLimit: weekly,
                      remainingDays: remainingDays, expireAt: expireAt,
                      weekResetAt: weekResetAt), false, "")
    }
}

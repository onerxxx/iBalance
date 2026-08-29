// BigModelService.swift — 智谱 BigModel（bigmodel.cn 开放平台）余额查询
// 登录态来源：浏览器 Cookies 库中的 bigmodel_token_production（JWT，v10 加密），
// 解密后放 Authorization: Bearer 调财务报告接口取 availableBalance。
// Cookie 采集 + 落盘缓存 + 钥匙串规避走 BrowserCookieStore 通用管线（与 Qwen 共用，
// 方案复刻自已下线的千问 edgeTicket 实现，见 git 67eeb0e~1 Services/Qianwen.swift）。
import Foundation

enum BigModelService {
    /// 登录态 Cookie 名与站点（与浏览器站内一致）
    private static let cookieName = "bigmodel_token_production"
    private static let cookieHost = "bigmodel.cn"
    private static let cacheFilename = "bigmodel_token.json"
    /// 报告接口：data.availableBalance 即官网「财务中心」页 .amount 显示的可用余额
    private static let reportURL = "https://bigmodel.cn/api/biz/account/query-customer-account-report"

    // MARK: - 凭据解析

    static func cachedToken() -> String? {
        BrowserCookieStore.cachedToken(filename: cacheFilename)
    }

    static func clearCachedToken() {
        BrowserCookieStore.clearCachedToken(filename: cacheFilename)
    }

    /// 手填覆盖值非空时直接使用；其次读本地缓存；否则扫浏览器（Edge/Chrome）采集。
    static func resolveToken(override: String) -> String? {
        BrowserCookieStore.resolve(override: override, cookieName: cookieName,
                                   hostLike: "%\(cookieHost)%", cacheFilename: cacheFilename, logTag: "[ZhiPu]") { row, password in
            // 老版本：value 列即明文 JWT
            let trimmed = row.plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeJWT(trimmed) { return trimmed }
            guard let plain = BrowserCookieStore.decryptV10(row, password: password),
                  let jwt = extractJWT(from: plain) else {
                if !row.enc.isEmpty {
                    Logger.log(.refresh, "[ZhiPu] \(row.profile): 解密失败或明文非 JWT（\(row.enc.count)B 密文）")
                }
                return nil
            }
            return jwt
        }
    }

    /// v10 解密后的明文提取 JWT：老版本即明文；App-Bound 填充则前 32 字节为随机前缀
    private static func extractJWT(from plain: Data) -> String? {
        for start in [0, 32] where plain.count > start {
            let text = String(data: plain.dropFirst(start), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if looksLikeJWT(text) { return text }
        }
        return nil
    }

    /// JWT 粗校验：两段以上点分 base64 且长度合理（避免把填充噪声误判为 token）
    private static func looksLikeJWT(_ s: String) -> Bool {
        s.split(separator: ".").count >= 2 && s.count > 40
            && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    // MARK: - 余额查询

    /// 查询可用余额（元）与消耗基线（充值+赠送总额，驱动点阵进度）。
    /// token 为空静默跳过（error/authFailed 为空/false）；authFailed=true 表示登录态失效
    /// （调用方清缓存重采），error 供通知/footer 展示。budget<=0 表示未提供基线（点阵隐藏）。
    static func fetch(token: String) async -> (balance: Double?, budget: Double, authFailed: Bool, error: String) {
        guard !token.isEmpty else { return (nil, 0, false, "") }
        guard let url = URL(string: reportURL) else { return (nil, 0, false, "URL错误") }
        let (data, status) = await HTTP.requestWithRetry(
            url: url, method: "GET",
            headers: ["Accept": "application/json", "Authorization": "Bearer \(token)"],
            timeout: 15
        )
        guard status == 200 else {
            if status == 0 { return (nil, 0, false, "网络错误") }
            let failed = status == 401 || status == 403
            return (nil, 0, failed, "HTTP \(status)\(failed ? "（登录态可能已失效）" : "")")
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, 0, false, "响应解析失败")
        }
        // 业务层鉴权失败：code 1001（实测无 Authorization 时返回此码）/ 401
        let code = json["code"] as? Int ?? 0
        guard code == 200 else {
            return (nil, 0, code == 1001 || code == 401, "接口 code=\(code)（登录态可能已失效）")
        }
        let d = (json["data"] as? [String: Any]) ?? [:]
        guard let bal = d["availableBalance"].flatMap(anyToDouble) ?? d["balance"].flatMap(anyToDouble) else {
            return (nil, 0, false, "响应缺少余额字段")
        }
        // 消耗基线：累计充值 + 赠送（totalSpendAmount + availableBalance ≈ 此值，已验证）
        let budget = (d["rechargeAmount"].flatMap(anyToDouble) ?? 0)
            + (d["giveAmount"].flatMap(anyToDouble) ?? 0)
        return (bal, budget, false, "")
    }
}

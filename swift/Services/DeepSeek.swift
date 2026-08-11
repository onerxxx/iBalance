// DeepSeek.swift — DeepSeek 余额查询
import Foundation

enum DeepSeekService {
    struct Balance {
        let symbol: String      // 货币符号 ¥ / $
        let totalRaw: String    // 原始余额字符串（保留精度，由 UI 按小数位格式化）
    }

    /// 查询余额。apiKey 为空返回无错误空结果；其他失败返回错误信息（空串=成功/跳过）。
    static func fetch(apiKey: String) async -> (balance: Balance?, error: String) {
        guard !apiKey.isEmpty else { return (nil, "") }
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            return (nil, "URL错误")
        }
        let (data, status) = await HTTP.requestWithRetry(
            url: url,
            headers: ["Accept": "application/json", "Authorization": "Bearer \(apiKey)"],
            timeout: 15
        )
        guard status == 200 else {
            return (nil, status == 0 ? "网络错误" : "HTTP \(status)")
        }
        guard let data, let resp = try? JSONDecoder().decode(BalanceResponse.self, from: data),
              let info = resp.balance_infos?.first else {
            return (nil, "无余额信息")
        }
        let currency = info.currency ?? "CNY"
        let symbol = (currency == "CNY") ? "¥" : "$"
        return (Balance(symbol: symbol, totalRaw: info.total_balance ?? "0"), "")
    }

    private struct BalanceResponse: Decodable {
        struct Info: Decodable {
            let currency: String?
            let total_balance: String?
        }
        let balance_infos: [Info]?
    }
}

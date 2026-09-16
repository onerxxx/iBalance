// BackupService.swift — 设置备份导出/导入（设置窗口「关于」pane 的「备份」区块）
//
// ─── 数据范围 ───
// · config：AppConfig 全量（含 7 个凭据字段——钥匙串 bundle 的同一份数据，明文导出）
// · defaults：应用自己的 UserDefaults 持久域整包（面板排序/折叠/用量色/3D 硬币/弹跳参数/
//   签到标记与历史等），取 `persistentDomain(forName:)` 而非逐键枚举——新键自动跟着走
// · 刻意不含 cache.json（数值缓存，可重建）与 usage.json（用量观测，属数据不属于设置）
//
// ─── 流程 ───
// 导出 = 存储面板选位置 → 写 JSON（0600）；导入 = 打开面板选文件 → 解析校验 → 确认弹窗
// → 覆盖写回钥匙串 + config.json + UserDefaults 域 → 落独立 sh 拉起新实例后 terminate。
// 导入必须重启：UserDefaults 域里大量键在视图/控制器 init 时被缓存（硬币参数、弹跳参数等），
// 逐项热应用既不彻底也没法验证，重启是唯一诚实口径。
//
// ⚠️ 仅主线程调用（与 ConfigStore / AppConfig 的读写约定一致）
// ─────────

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum BackupService {
    /// envelope 识别标记与格式版本（version 只增不减；导入时 version > 当前 = 拒绝）
    private static let kind = "iBalance-backup"
    private static let version = 1

    enum BackupError: LocalizedError {
        case notBackup            // kind 不匹配 / 结构缺失
        case unsupportedVersion   // 备份版本比当前 App 新

        var errorDescription: String? {
            switch self {
            case .notBackup: return "不是 iBalance 备份文件"
            case .unsupportedVersion: return "备份文件版本较新，请先升级 iBalance"
            }
        }
    }

    struct BackupPayload {
        let config: AppConfig
        /// nil = 备份里没有 defaults 段（不触碰当前域）；有段 = 整包替换
        let defaults: [String: Any]?
    }

    // MARK: - 导出

    static func export(config: AppConfig) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "iBalance备份-\(stamp.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try exportData(config: config)
            try data.write(to: url, options: [.atomic])
            // 凭据是明文，权限对齐 config.json（仅当前用户可读写）
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let shell = DialogShell()
            shell.addTitle("已导出")
            shell.addInfo(url.path)
            shell.addButton("知道了", keyEquivalent: "\r")
            _ = shell.present()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// 组装备份 JSON：config 走 Codable（凭据明文复用 emergencyPlaintextFallback 这个
    /// 既有开关），defaults 域与 envelope 用 JSONSerialization（混合 plist 值类型）。
    static func exportData(config: AppConfig) throws -> Data {
        AppConfig.emergencyPlaintextFallback = true
        defer { AppConfig.emergencyPlaintextFallback = false }
        let cfgData = try JSONEncoder().encode(config)
        guard let cfg = try JSONSerialization.jsonObject(with: cfgData) as? [String: Any] else {
            throw BackupError.notBackup
        }
        let defaults = UserDefaults.standard.persistentDomain(forName: AppDataStore.bundleIdentifier) ?? [:]
        let envelope: [String: Any] = [
            "kind": kind,
            "version": version,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "config": cfg,
            "defaults": jsonSafe(defaults),
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    /// plist 值 → JSON 值（UserDefaults 域里 Date/Data 与 JSON 不兼容，先归一）。
    /// plist 域只会出现下面几类；漏网的标 null 兜底（不静默丢整个文件）。
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let date as Date: return date.timeIntervalSince1970
        case let data as Data: return data.base64EncodedString()
        case let dict as [String: Any]: return dict.mapValues(jsonSafe)
        case let array as [Any]: return array.map(jsonSafe)
        case let num as NSNumber: return num   // Bool/Int/Double 都桥到 NSNumber
        case let str as String: return str
        default: return NSNull()
        }
    }

    // MARK: - 导入

    static func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let payload = try parse(Data(contentsOf: url))
            let shell = DialogShell()
            shell.addTitle("导入配置")
            shell.addInfo("将覆盖当前全部设置与账号凭据，导入后自动重启应用。")
            let importIdx = shell.addButton("导入并重启", keyEquivalent: "\r")
            shell.addButton("取消")
            shell.markDestructive(importIdx)
            guard shell.present() == importIdx else { return }
            try apply(payload)
            relaunch()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func parse(_ data: Data) throws -> BackupPayload {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["kind"] as? String == kind else { throw BackupError.notBackup }
        guard let v = obj["version"] as? Int, v <= version else { throw BackupError.unsupportedVersion }
        guard let cfg = obj["config"] as? [String: Any] else { throw BackupError.notBackup }
        let config = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: cfg))
        // defaults 段缺失 = 旧结构/外部文件：不触碰当前域；有段 = 整包替换
        return BackupPayload(config: config, defaults: obj["defaults"] as? [String: Any])
    }

    /// 覆盖写回：先钥匙串 + config.json（凭据由 CredentialVault.persist 整包落钥匙串，
    /// 写失败时 save 自带 JSON 明文兜底，下次启动自动迁入），再整包替换 UserDefaults 域。
    static func apply(_ payload: BackupPayload) throws {
        ConfigStore.save(payload.config)
        if let defaults = payload.defaults {
            // JSON 值（String/Number/Bool/Array/Dict）全是合法 plist 类型，可直接入域
            UserDefaults.standard.setPersistentDomain(defaults, forName: AppDataStore.bundleIdentifier)
        }
    }

    /// 独立 sh 等进程退净后 open（借鉴 UpdateService.installAndRestart：open 同名 bundle
    /// 遇存活旧实例只会激活它，所以必须等 pgrep 干净再 open）；sh 在父进程 terminate 后继续存活。
    static func relaunch() {
        let script = """
        #!/bin/sh
        i=0
        while pgrep -x iBalance >/dev/null 2>&1; do
            [ $i -ge 8 ] && break
            sleep 0.5
            i=$((i+1))
        done
        pkill -9 -x iBalance 2>/dev/null || true
        sleep 0.3
        open '\(Bundle.main.bundleURL.path)'
        """
        let shFile = NSTemporaryDirectory().appending("ibalance_restore.sh")
        try? script.write(toFile: shFile, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [shFile]
        Logger.log(.refresh, "[backup] applying done, spawning relaunch script")
        _ = try? p.run()
        NSApp.terminate(nil)
    }
}

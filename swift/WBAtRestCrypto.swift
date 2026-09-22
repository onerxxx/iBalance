// WBAtRestCrypto.swift — WorkBuddy 桌面端 at-rest 凭据解密（native 静态钥 + AES-256-GCM）
//
// 本文件速查：
//   WBEncryptedField           auth 文件字段：明文直取 / `$wbEncrypted` 包裹自动解密
//   WBAtRestCrypto.open(…)     解开 envelope（sym-v1 / field 级）
//   WBAtRestCrypto.warmUp()    启动时后台预热静态钥（避免首次读 auth 文件时同步等 native）
//   WBAtRestCrypto.invalidateKey()  换号 / 密钥轮换后清缓存重取
//   private loadSecretKeyBase64()   探针：native loggerGet() → {"version":1,"atRestSecretKey":…}
//   private keyId(of:)              keyId = SHA256(key).hex[:16]（与 envelope.keyId 校验）
//   private aad(…)                  认证附加数据（WB-AAD\0 | 01 | 格式 | 方案 | suite | keyId | …）
//
// 口径来源（2026-09-22 逆向 WorkBuddy 5.6.2）：
//   key    = SHA256(atRestSecretKey 的 UTF-8 字节) —— 注意哈希的是 base64 字符串本身，不是解码后的字节
//   明文   = AES-256-GCM(key).decrypt(nonce, ciphertext‖authTag, AAD)
//   静态钥由 WorkBuddy 定制 Electron 的 native 绑定提供，**不在磁盘上**（二进制里也搜不到明文），
//   只能运行时向它要；故本文件用纯 Node 模式跑一次 WorkBuddy 自带的 Electron 取回 payload。

import AppKit
import CryptoKit
import Foundation

/// auth 文件里的字段：可能是明文，也可能是 `{"$wbEncrypted":1,"envelope":"…"}` 包裹的密文。
struct WBEncryptedField: Decodable {
    private let plain: String?
    private let envelope: String?

    private struct Wrapper: Decodable {
        let envelope: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            plain = value
            envelope = nil
        } else {
            plain = nil
            envelope = try container.decode(Wrapper.self).envelope
        }
    }

    /// 取明文：明文直返；密文走 at-rest 解密。首次解密失败清钥重试一次——
    /// 桌面端换号或轮换静态钥后 envelope 的 keyId 会变，缓存里的旧钥必然解不开。
    func resolved() -> String? {
        if let plain { return plain }
        guard let envelope else { return nil }
        if let value = WBAtRestCrypto.open(envelopeBase64: envelope) { return value }
        WBAtRestCrypto.invalidateKey()
        return WBAtRestCrypto.open(envelopeBase64: envelope)
    }
}

enum WBAtRestCrypto {

    // MARK: - 静态钥

    /// WorkBuddy 定制 Electron 二进制：native 绑定 electron_browser_workbuddy_storage 挂在它里面。
    private static var executablePath: String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.workbuddy.mac")
        else { return nil }
        let path = app.appendingPathComponent("Contents/MacOS/Electron").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// 探针脚本：直接问 native 要静态钥 payload（不启窗口、不影响正在运行的 WorkBuddy）
    private static let probeScript =
        "process.stdout.write(process._linkedBinding(\"electron_browser_workbuddy_storage\").loggerGet())"

    private static let lock = NSLock()
    private static var cachedKey: SymmetricKey?
    private static var cachedKeyId: String?

    /// 启动时后台预热：静态钥要拉起一个 Electron 进程（~1s），别等到第一次读 auth 文件时才同步等。
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            if let keyId = currentKey()?.keyId {
                Logger.log(.refresh, "[WBAtRest] key ready keyId=\(keyId)")
            } else {
                Logger.log(.refresh, "[WBAtRest] key unavailable (WorkBuddy 未安装或 native 绑定不可用)")
            }
        }
    }

    /// 丢弃静态钥缓存（换号 / 桌面端轮换密钥后重取）
    static func invalidateKey() {
        lock.lock()
        defer { lock.unlock() }
        cachedKey = nil
        cachedKeyId = nil
    }

    /// 解开 `$wbEncrypted` 包裹：suite 恒 1、nonce 12B、authTag 16B，认证数据见 `aad`
    static func open(envelopeBase64: String) -> String? {
        guard let (key, keyId) = currentKey() else { return nil }
        guard let envelopeData = Data(base64Encoded: envelopeBase64),
              let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
              let suite = envelope["suite"] as? Int, suite == 1,
              let declaredKeyId = envelope["keyId"] as? String, declaredKeyId == keyId,
              let nonceBase64 = envelope["nonce"] as? String,
              let authTagBase64 = envelope["authTag"] as? String,
              let ciphertextBase64 = envelope["ciphertext"] as? String,
              let nonceData = Data(base64Encoded: nonceBase64),
              let authTag = Data(base64Encoded: authTagBase64),
              let ciphertext = Data(base64Encoded: ciphertextBase64),
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: authTag),
              let plain = try? AES.GCM.open(sealed, using: key,
                                            authenticating: aad(suite: suite, keyId: keyId))
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - 派生

    private static func currentKey() -> (key: SymmetricKey, keyId: String)? {
        lock.lock()
        defer { lock.unlock() }
        if let key = cachedKey, let keyId = cachedKeyId { return (key, keyId) }
        guard let secret = loadSecretKeyBase64() else { return nil }
        let keyData = Data(SHA256.hash(data: Data(secret.utf8)))
        let keyId = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined().prefix(16)
        let key = SymmetricKey(data: keyData)
        cachedKey = key
        cachedKeyId = String(keyId)
        return (key, String(keyId))
    }

    /// native payload 取回 base64 形态的 32 字节静态钥
    private static func loadSecretKeyBase64() -> String? {
        guard let executablePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-e", probeScript]
        var environment = ProcessInfo.processInfo.environment
        environment["ELECTRON_RUN_AS_NODE"] = "1"   // 纯 Node 模式：不起窗口 / GPU / renderer
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice  // Electron 会往 stderr 打一行无害告警
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let payload = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let secret = payload["atRestSecretKey"] as? String, !secret.isEmpty
        else { return nil }
        return secret
    }

    /// 认证附加数据（sym-v1 / framing = field，whole-value context 不含 sequence/final，两位恒 0）
    private static func aad(suite: Int, keyId: String) -> Data {
        var data = Data("WB-AAD\0".utf8)
        data.append(0x01)                       // AAD 版本
        data.append(lengthPrefixed("WBEV1"))    // field 级格式 id（file=WBEF1 / record=WBER1 / stream=WBES1）
        data.append(lengthPrefixed("sym-v1"))   // 方案
        data.append(uint32(suite))
        data.append(lengthPrefixed(keyId))
        data.append(0x02)                       // FRAMING_CODE.field
        data.append(0x00)                       // sequence 缺省
        data.append(0x00)                       // final 缺省
        return data
    }

    private static func uint32(_ value: Int) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func lengthPrefixed(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return uint32(bytes.count) + bytes
    }
}

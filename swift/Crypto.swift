// Crypto.swift — 通用加解密工具（SHA-512 / AES-CBC / PBKDF2）
import CommonCrypto
import Foundation

enum Crypto {
    /// SHA-512 摘要
    static func sha512(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: 64)
        data.withUnsafeBytes { ptr in
            _ = CC_SHA512(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    /// AES-CBC 解密（PKCS7 padding）
    static func aesCbcDecrypt(key: Data, iv: Data, ct: Data) -> Data? {
        let bufferSize = ct.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numDecrypted = 0
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                ct.withUnsafeBytes { ctPtr in
                    buffer.withUnsafeMutableBytes { bufPtr in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                ctPtr.baseAddress, ct.count,
                                bufPtr.baseAddress, bufferSize, &numDecrypted)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return buffer.prefix(numDecrypted)
    }

    /// PBKDF2-HMAC-SHA1 派生密钥
    static func pbkdf2Sha1(password: [UInt8], salt: [UInt8], iterations: UInt32, keyLength: Int) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: keyLength)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 password, password.count,
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                 iterations, &key, keyLength)
        return key
    }
}

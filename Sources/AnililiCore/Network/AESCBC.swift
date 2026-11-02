import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#elseif canImport(_CryptoExtras)
import Crypto
import _CryptoExtras
#endif

/// AES-CBC with PKCS#7 padding, which several providers' players wrap their stream URLs in and
/// CryptoKit doesn't offer: CommonCrypto on Apple platforms, swift-crypto's extras on Linux.
enum AESCBC {
    /// The plaintext, or nil when the key, IV or padding don't fit (a rotated key, usually).
    static func decrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0, [16, 24, 32].contains(key.count), iv.count == 16 else { return nil }
        #if canImport(CommonCrypto)
        var output = Data(count: ciphertext.count + 16)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, ciphertext.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return output.prefix(written)
        #elseif canImport(_CryptoExtras)
        guard let vector = try? AES._CBC.IV(ivBytes: iv) else { return nil }
        return try? AES._CBC.decrypt(ciphertext, using: SymmetricKey(data: key), iv: vector)
        #else
        return nil
        #endif
    }

    /// base64url (`-`, `_`, no padding) or plain base64, as players hand their blobs out.
    static func base64URL(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}

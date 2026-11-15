import Foundation
import Security

/// MFi 配件身份：把包内的 `leaf.cer` + `private.x963` 变成可用的 `SecKey`。
///
/// `private.x963` 的布局（逆向自 CarWithin 0.2，已用 Python 验证）：
///
///     [0..64]   0x04 || X(32) || Y(32)   —— ANSI X9.63 非压缩公钥点
///     [65..96]  d(32)                    —— P-256 私钥标量
///
/// 合计 97 字节，正好是 `SecKeyCreateWithData` 对 EC 私钥要求的 X9.63 格式，
/// 所以不需要任何解析：整块丢进去就能拿到 SecKey。
///
/// 证书是 Apple Accessories CA 签发的（CN=IPA_24ACBB…，secp256r1，2018→2049）。
final class MFiIdentity {
    enum IdentityError: Error {
        case missingResource(String)
        case keyCreationFailed(OSStatus)
        case certificateLoadFailed
        case signingFailed(OSStatus)
    }

    let certificateDER: Data
    let privateKey: SecKey
    let publicKey: SecKey?

    init(bundle: Bundle = .main) throws {
        guard let certURL = bundle.url(forResource: "leaf", withExtension: "cer"),
              let keyURL = bundle.url(forResource: "private", withExtension: "x963") else {
            throw IdentityError.missingResource("leaf.cer / private.x963")
        }
        certificateDER = try Data(contentsOf: certURL)
        let blob = try Data(contentsOf: keyURL)

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(blob as CFData, attributes as CFDictionary, &error) else {
            let status = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? -1
            throw IdentityError.keyCreationFailed(OSStatus(status))
        }
        privateKey = key
        publicKey = SecKeyCopyPublicKey(key)
    }

    /// 用私钥对挑战做 ECDSA-SHA256 签名（DER 编码，约 70~72 字节）。
    ///
    /// MFiSAP（AirPlay `/auth-setup` 与 iAP2 认证会话）要的就是这个：
    /// 对手机给的随机挑战签名，手机用证书里的公钥验。
    func sign(challenge: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge as CFData,
            &error) else {
            let status = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? -1
            throw IdentityError.signingFailed(OSStatus(status))
        }
        return signature as Data
    }

    /// 自检：签一段固定挑战再用公钥验，用来在 UI 上判断身份是否可用。
    func selfCheck() -> Bool {
        guard let publicKey else { return false }
        let challenge = Data(0..<128)
        guard let signature = try? sign(challenge: challenge) else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            publicKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge as CFData,
            signature as CFData,
            &error)
    }
}

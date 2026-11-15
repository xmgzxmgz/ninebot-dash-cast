import Foundation
import CryptoKit
import Security
import BigInt

/// SRP-6a 服务端（AirPlay pair-setup 用），3072 位 MODP 群 + SHA-512。
///
/// 角色分工：仪表侧 App 是"配件"，在这套协商里充当 SRP 服务端，
/// 密码是用户看到的配对码；iOS 是客户端。
///
/// 模幂自己用平方-乘实现，不依赖库里可能变动的 API。
final class SRPServer {
    /// RFC 5054 / HAP 使用的 3072 位 MODP 群
    private static let modulusHex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
        + "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
        + "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
        + "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"
        + "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"
        + "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
        + "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"
        + "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33"
        + "A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
        + "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864"
        + "D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2"
        + "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"

    static let width = 384  // 3072 bit

    private let n: BigUInt
    private let nBytes: Data
    private let g: BigUInt = 5
    private let k: BigUInt
    private let verifier: BigUInt
    private let salt: Data
    private let username: Data

    private var privateB: BigUInt?
    private(set) var publicB: Data?
    private(set) var clientA: Data?
    private(set) var sharedSecret: Data?

    init(username: String, password: String, salt: Data? = nil) {
        let modulus = BigUInt(Self.modulusHex, radix: 16) ?? BigUInt(1)
        n = modulus
        nBytes = SRPServer.bytes(of: modulus, width: SRPServer.width)
        self.salt = salt ?? SRPServer.randomSalt()
        self.username = Data(username.utf8)

        let gBytes = SRPServer.bytes(of: BigUInt(5), width: SRPServer.width)
        k = Self.big(Self.hash(nBytes + gBytes))

        let inner = Self.hash(self.username + Data(":".utf8) + Data(password.utf8))
        let x = Self.big(Self.hash(self.salt + inner))
        verifier = SRPServer.modPower(base: BigUInt(5), exponent: x, modulus: modulus)
    }

    /// 服务端第一步：给出 salt 与 B
    func challenge() -> (salt: Data, publicB: Data) {
        let b = BigUInt.randomInteger(withMaximumWidth: 256)
        privateB = b
        let gb = SRPServer.modPower(base: g, exponent: b, modulus: n)
        let B = (k * verifier + gb) % n
        let data = SRPServer.bytes(of: B, width: Self.width)
        publicB = data
        return (salt, data)
    }

    /// 客户端发来 A：算共享密钥与期望的 M1
    func accept(clientPublicA a: Data) -> (sharedSecret: Data, expectedProof: Data)? {
        guard let b = privateB, let bData = publicB else { return nil }
        let A = Self.big(a)
        guard A % n != BigUInt(0) else { return nil }
        clientA = a

        let u = Self.big(Self.hash(Self.padded(a) + bData))
        let vu = SRPServer.modPower(base: verifier, exponent: u, modulus: n)
        let base = (A * vu) % n
        let S = SRPServer.modPower(base: base, exponent: b, modulus: n)
        let sData = SRPServer.bytes(of: S, width: Self.width)
        sharedSecret = sData

        let expected = Self.clientProof(nBytes: nBytes, username: username, salt: salt,
                                        a: a, b: bData, sharedSecret: sData)
        return (sData, expected)
    }

    /// 校验 M1 并给出 M2
    func confirm(clientProof m1: Data) -> Data? {
        guard let sharedSecret, let a = clientA else { return nil }
        return Self.hash(Self.padded(a) + m1 + sharedSecret)
    }

    // MARK: - 工具

    static func hash(_ data: Data) -> Data {
        Data(SHA512.hash(data: data))
    }

    static func bytes(of value: BigUInt, width: Int) -> Data {
        var out = Data()
        var v = value
        while v > BigUInt(0) {
            out.insert(UInt8(truncatingIfNeeded: v & BigUInt(0xFF)), at: 0)
            v >>= 8
        }
        if out.count < width {
            out = Data(repeating: 0, count: width - out.count) + out
        }
        return out
    }

    static func big(_ data: Data) -> BigUInt {
        var v = BigUInt(0)
        for byte in data { v = (v << 8) + BigUInt(byte) }
        return v
    }

    static func padded(_ data: Data) -> Data {
        data.count >= width ? data : Data(repeating: 0, count: width - data.count) + data
    }

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// M1 = H( H(N) XOR H(g) | H(I) | s | A | B | K )
    static func clientProof(nBytes: Data, username: Data, salt: Data,
                            a: Data, b: Data, sharedSecret: Data) -> Data {
        let hN = hash(nBytes)
        let hg = hash(bytes(of: BigUInt(5), width: width))
        var xor = Data(count: hN.count)
        for i in 0..<hN.count { xor[i] = hN[i] ^ hg[i] }
        return hash(xor + hash(username) + salt + padded(a) + padded(b) + sharedSecret)
    }

    static func modPower(base: BigUInt, exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(1)
        var b = base % modulus
        var e = exponent
        while e > BigUInt(0) {
            if e % 2 == BigUInt(1) { result = (result * b) % modulus }
            b = (b * b) % modulus
            e /= 2
        }
        return result
    }
}

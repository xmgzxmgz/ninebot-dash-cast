# M2 认证层：身份、签名、SRP

## 1. 包内身份是什么（已验证）

`CarWithin.app/private.x963` 共 **97 字节**，布局是：

```
[0..64]   0x04 || X(32) || Y(32)    ← ANSI X9.63 非压缩公钥点（P-256）
[65..96]  d(32)                     ← 私钥标量
```

这个布局不是猜的，三条独立验证都通过：

| 验证 | 结果 |
|---|---|
| 由 `d` 推导公钥 == 文件里的点 | ✅ 完全一致 |
| 文件里的点 == `leaf.cer` 的公钥 | ✅ 完全一致 |
| 用 `d` 对 128 字节挑战做 ECDSA-SHA256 签名 → 用证书公钥验签 | ✅ 通过（DER 71 字节） |

顺带解释了文件名：`SecKeyCreateWithData` 对 EC 私钥要求的正是 X9.63 格式，整块丢进去就能得到 `SecKey`，不需要任何解析。

## 2. 证书

```
subject : CN=IPA_24ACBB48646F8077F7463523085B60D2, OU=Apple Accessories, O=Apple Inc., C=US
issuer  : CN=Apple Accessories Certification Authority - 00000002, ...
公钥    : EC secp256r1 (P-256)
有效期  : 2018-06-13 → 2049-12-31
```

这是一张**真实的 Apple Accessories 配件证书**（序列号 24ACBB…），配着明文私钥一起躺在 App 包里——这正是"不需要 MFi 芯片"的全部秘密。

## 3. MFiSAP 要什么

AirPlay 的 `/auth-setup` 与 iAP2 认证会话都是同一件事：**手机给挑战，配件签名，手机用证书验**。

- 曲线/摘要：P-256 + SHA-256
- 挑战长度：128 字节
- 签名：ECDSA，DER 编码（约 70~72 字节，不是定长 64）

Swift 侧用系统框架即可，不需要第三方库：

```swift
SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, challenge, &error)
```

`Sources/MFiIdentity.swift` 就是这么实现的，并在 UI 上做了自检（`identityStatus`），装到手机上一眼能看出身份是否可用。

## 4. SRP-6a（pair-setup）

AirPlay 的配对是 SRP-6a + 3072 位模群 + SHA-512。我们的 App 充当**服务端**（配件），密码是用户看到的配对码。

| 量 | 公式 |
|---|---|
| k | `H(N ‖ PAD(g))` |
| x | `H(salt ‖ H(I ‖ ":" ‖ P))` |
| v | `g^x mod N` |
| B | `(k·v + g^b) mod N` |
| u | `H(PAD(A) ‖ PAD(B))` |
| S | `(A·v^u)^b mod N` |
| K | `H(S)` |
| M1 | `H( H(N) ⊕ H(g) ‖ H(I) ‖ salt ‖ PAD(A) ‖ PAD(B) ‖ K )` |
| M2 | `H( PAD(A) ‖ M1 ‖ K )` |

**已交叉验证**：用 Python 复算同一套公式（模数直接取自 Swift 源码里的十六进制串，3072 位、通过素性粗测），客户端与服务端算出的共享密钥、M1 完全一致。Swift 侧用自己实现的平方-乘模幂，不依赖库里可能变动的 `power` API。

## 5. 代码进度

| 文件 | 内容 | 状态 |
|---|---|---|
| `ios-single/Sources/MFiIdentity.swift` | X9.63 → `SecKey`，ECDSA 签名与自检 | ✅ 编译通过 |
| `ios-single/Sources/TLV8.swift` | TLV8 编解码（>255 字节自动分片、解码时合并） | ✅ 编译通过 |
| `ios-single/Sources/SRPServer.swift` | SRP-6a 服务端（challenge / accept / confirm） | ✅ 编译通过，公式已交叉验证 |
| `ios-single/Resources/` | `leaf.cer` + `private.x963` 随包分发 | ✅ |

## 6. 还差什么

| 步骤 | 说明 |
|---|---|
| 虚拟配件端点 | 私有 `CoreAccessories`（`ACCTransportClient`）创建虚拟配件，等 iOS 连进来——**没有任何替代方案**，也是这条路最大的风险点 |
| iAP2 会话 | 识别 → 认证（MFiSAP）→ 启动 CarPlay 服务 |
| RTSP 协商 | control / video / event 三通道，之后才拿到 H.264 ES |
| 收流与转码 | `ScreenStream` 那一层，接上已有的 `FrameEncoder` |

## 7. 风险

证书与私钥**来自第三方 App 包**，不是本项目的资产；自用测试与再分发是两件事。另：证书有效期到 2049 年，但 Apple 可以随时吊销（CRL/OCSP），届时这条路线会失效。

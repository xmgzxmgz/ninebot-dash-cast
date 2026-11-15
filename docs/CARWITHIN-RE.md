# CarWithin 逆向：自己写一个"CarPlay 直投仪表"的 App 要复现什么

对象：`TDSCarKit`（CarWithin 0.2，1,834,520 字节，20,086 个符号，76 个自有 Swift 类型，符号未剥离）。

## 1. 它到底做了几件事

按符号归层，一共 **7 层**，缺一层都跑不起来：

| 层 | 相关类型 | 作用 |
|---|---|---|
| 身份 | `AccessoryIdentity`、`AccessoryIdentityStore`、`LocalTLSIdentity` | 读取包内 MFi 证书/私钥（`certificate.p7b`/`leaf.cer`/`private.x963`），并生成本地 TLS 自签证书 |
| 认证 | `MFiSAP`、`SRPServer`、`PairSetup`、`PairVerify`、`TLV8`、`BigInt`/`BigUInt`/`primes` | AirPlay/CarPlay 的 `/auth-setup`（MFiSAP 签名）+ SRP 配对 + Curve25519 验证 |
| 传输接入 | `NativeReceiver`、`AccessoryMessages`、`SameDeviceProbe` | 通过私有 `CoreAccessories`（`ACCTransportClient`）造虚拟配件端点，等 iOS 主动连进来 |
| 控制协议 | `IAP2Packet/Parser/Message/Parameter/Event`、`CarPlayControl`、`CarPlayInfo` | iAP2 会话（识别、认证、启动 CarPlay 服务），告诉手机"我支持 CarPlay" |
| 流协商 | `RTSPParser/Request/Response`、`CarPlayMediaSession`、`MediaTCPListener`、`MediaTCPConnection`、`MediaTiming` | RTSP 协商出视频/音频/事件三条通道，NCM 链路上开 TCP |
| 视频 | `ScreenStream`、`VideoOutputServer`、`H264Surface`、`AnnexB`、`VideoParameterSets`、`VideoCodec`、`FragmentedMP4` | 收 H.264/HEVC ES（或 fMP4），解出 AU、SPS/PPS，供显示或网页分发 |
| 附属 | `ControlCipher`、`CarPlayAudio`、`AudioStream`、`NativeAudioDecoder`、`NativeMicrophone`、`Opus`、`TouchSlots`/`TouchPoint`、`BLEBootstrap`/`BLEFrame`、`WiFiCredentials`、`BackgroundKeepAlive` | 控制通道加密、音频播放/麦克风回传、触摸回传、无线配对的 BLE 引导、后台保活 |

两条配对路径：`BLEBootstrap`+`WiFiCredentials` 是无线（BT 唤醒→Wi-Fi 凭证），有线则直接走 USB NCM。

## 2. 对我们有用的三个结论

1. **视频层是最省事的一段**：`AnnexB`、`VideoParameterSets` 说明它把收到的 ES 直接转成 Annex-B——和我们要喂给仪表的格式一致，理论上可以跳过"解码再编码"，直接转发（但仪表只吃 848×480 Baseline，源通常是 1080p High，还是得转码）。
2. **认证层不可省但有现成素材**：`MFiSAP` 要的是"用 MFi 私钥签 128 字节挑战"，证书和私钥就在包里，`SRPServer`/`PairVerify` 是标准算法（`primes` 里是 SRP 群参数）。
3. **虚拟配件是唯一的"特权"**：`NativeReceiver.listen(configuration:identity:port:)` 背后是 `CoreAccessories`。这一步没有替代方案，也是这类 App 必须自签、且系统升级就失效的原因。

## 3. 改造方案：SingleCast（单 App 直投仪表）

目标链路（不经过电脑、不经过录屏）：

```
iPhone ── iAP2/RTSP ──> CarPlay 会话（源 1080p）
                          │ ScreenStream 拿 Annex-B
                          ▼
                   VTDecompressionSession → CVPixelBuffer
                          ▼
                   FrameCompositor（缩放到 848×480，补边）
                          ▼
                   VTCompressionSession（Baseline，2Mbps）
                          ▼
                   NinebotPacketizer（20 字节头 + 1380 分片）
                          ▼
                   仪表 UDP 5012 ＋ 5013 心跳
```

注意：**不能直接转发 ES**，因为源是 High profile 且分辨率不同；必须解码→重编码，这也正好复用 `ninebot_pro` 已经验证过的参数。

### 里程碑

| 阶段 | 内容 | 难度 | 可验证方式 |
|---|---|---|---|
| M1 | 仪表侧输出：`NinebotPacketizer` + UDP + 心跳 + 测试图 | 低 | 先用测试图点亮仪表，确认协议实现无误 |
| M2 | 本地虚拟配件 + 认证（`MFiSAP`/SRP/TLV8，用包内证书） | **高** | 手机能弹出 CarPlay 并显示黑屏或首帧 |
| M3 | iAP2 会话 + RTSP 协商，拿到 H.264 ES | 高 | 能收到帧、解出 SPS/PPS 与分辨率 |
| M4 | 解码 → 缩放 → 重编码 → 推仪表 | 中 | 仪表出画面 |
| M5 | 触摸回传（仪表若上报触摸）、后台保活 | 中 | 可选 |

M1 是纯工程，M2/M3 是逆向体力活（已经有符号表做地图，但要逐条对齐报文），M4/M5 是常规音视频开发。

## 4. 现成素材清单

| 素材 | 位置 | 用途 |
|---|---|---|
| MFi 证书链 + 私钥 | CarWithin 包内 `certificate.p7b`/`leaf.cer`/`private.x963` | 认证签名（**归属不明，自用测试与再分发是两件事**） |
| 仪表协议 | 本仓库 `docs/PROTOCOL.md` | 20 字节头、分片、心跳 |
| 参考实现 | 开源：PlayPort、DiPlay、xcertplay（CarWithin README 自述参考了这三个） | iAP2/配对/媒体层的实现思路 |
| 符号地图 | 本文第 1 节 | 逐层对照，避免瞎猜 |

## 5. 风险

- 私有 `CoreAccessories`：iOS 小版本更新就可能改签名或权限，二进制里已有 "refused the connection" 分支。
- 自签环境：虚拟配件需要 entitlement，免费签名能不能拿到，得实测。
- 时间成本：M2+M3 是这条路线的主要不确定性，不是"写几天"的量级。
- 法律：证书来源不明，商用分发风险高。

**结论**：设计 A 可行、路径清晰，但它是**周级**投入；M1 今天就能做完并验证，M2 之后需要真机与 Mac/Xcode（或 GitHub Actions 出包）配合。

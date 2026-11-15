# 苹果单机方案：CarWithin 怎么在不插硬件的情况下跑起真 CarPlay

结论：**可以，而且只用一台 iPhone。** 前提是认下两个现实——它是未签名 IPA、依赖 iOS 私有接口。

## 1. 它凭什么不需要 MFi 芯片

把 `CarWithin.ipa`（v0.2，bundle id `local.tds.carkit`）解包，`Payload/TDSCarKit.app/` 里直接躺着三个文件：

| 文件 | 大小 | 作用 |
|---|---|---|
| `certificate.p7b` | 607 B | 苹果签发的 **MFi 配件证书链** |
| `leaf.cer` | 558 B | 叶子证书 |
| `private.x963` | 97 B | 对应**私钥**（PKCS#8/DER 封装） |

也就是说：**认证能力被搬进了 App 包**。iPhone 向"配件"要证书、发随机挑战时，App 用包里这把私钥签名即可，不需要任何实体芯片。

配合二进制里的私有接口字符串：

```
ACCTransportClient
CoreAccessories refused the connection. This signed app may lack access to the private transport.
TDSCarKit.DirectTransport
```

它在本地用 `CoreAccessories` 开一个虚拟配件端点，让 iOS 和自己建 iAP2 链路；`Info.plist` 还注册了 `_airplay._tcp`、`_tds-carkit._tcp`、`_carplay-ctrl._tcp` 三条 Bonjour 服务，最后走 RTSP 协商出视频/音频/触摸通道。

## 2. 它的共享流长什么样（要接仪表就得知道）

App 内可以开"浏览器共享"，起一个网页 + WebSocket：

- 页面连 `ws://<iphone>:<port>/stream`（HTTPS 页则是 `wss://`），先发 `{"type":"ready","decoder":"webcodecs"}`；
- 服务端回 `hello`：`codec`（如 `avc1.42E01E`）+ base64 的 `description`（avcC）+ 宽高；
- 二进制帧：`[0]` 关键帧标志 → `[1..8]` 大端 64 位时间戳（微秒）→ `[9:]` **AVCC 格式**数据（长度前缀 NAL）；
- 另一条 `mse` 分支发的是 fMP4（`[0]` 类型 + fMP4 分片），给不支持 WebCodecs 的浏览器。

要喂给 ffmpeg / 仪表，必须做 **AVCC → Annex-B** 转换，并且**每帧补一个 AUD**——手机裸流没有访问单元分隔符，ffmpeg 在实时管道上会判不出帧边界。

## 3. 两条接到九号仪表的路径

### A. 浏览器中转（当前最稳）

```
iPhone(CarWithin 共享) ── Wi-Fi ──> 电脑 Chrome 打开 http://<iphone>:<port>/
                                        │ 抓窗口
                                        ▼
                        bridge/stream_bridge.py --source window:Chrome
                                        │ 848×480 H.264
                                        ▼
                              仪表 UDP 5012
```

- 优点：零解析、零协议风险，网页已经解好码；
- 代价：多一层浏览器渲染，延迟 +80~150ms；
- 命令：`python bridge/stream_bridge.py --host 192.168.1.1 --source "window:Chrome"`。

### B. WebSocket 直连（实验，已写代码）

```
iPhone(CarWithin 共享) ──ws://──> bridge/carwithin_ws.py（AVCC→Annex-B + AUD）
                                        │ stdout
                                        ▼
                        bridge/stream_bridge.py --source "pipe:python ..."
```

- 优点：省掉浏览器，理论上延迟最低；
- 现状：`bridge/carwithin_ws.py` 的解析与转换**离线自检通过**（avcC 解析、AVCC→Annex-B、SPS/PPS 拼装、截断容错、AUD 注入），对着本地假服务（`bridge/tests/mock_carwithin.py`）也能转出合法字节流（8 秒 943 KB ≈ 58 帧）；
- **尚未打通**：把这路实时流喂给 ffmpeg 时供流不稳（4 秒只出到 ~28 KB），同一个 ffmpeg 命令换成文件输入就正常（710 KB）。已排除码率控制、滤镜、`nobuffer`、`analyzeduration` 等因素，怀疑是 ffmpeg 对"低帧率 + 无 AUD 历史"的探测窗口行为，下一步准备换成 fMP4（mse 分支）直喂 `-f mp4`。
- 在打通之前，**请用 A 方案**。

## 4. 风险（先认清再上）

| 项 | 说明 |
|---|---|
| 证书归属 | 包里的 MFi 证书/私钥不是你的，来源不明；自用测试与再分发是两个性质 |
| 私有接口 | `CoreAccessories` 一改就可能失效，二进制里自己都写了"refused the connection"的分支 |
| 签名 | 未签名 IPA，需 Sideloadly/AltStore 自签，免费证书 7 天 |
| 同机资源 | CarPlay 会话 + 共享编码都在这台 iPhone 上，发热与降频要接受 |
| DRM | 受保护内容照样黑屏 |

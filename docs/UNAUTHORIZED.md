# 为什么"没授权"也能用：AirPlay 与 CarPlay 的三条绕过路线

结论先说：**所有能用的第三方实现，绕的都不是"要不要授权"，而是"把哪个环节搬走"。**
AirPlay 搬走的是 FairPlay 密钥（用公开的静态表），CarPlay 搬走的是认证芯片（塞进一个便宜的 dongle 里）。

---

## 一、AirPlay 镜像接收：靠公开的 FairPlay 静态表

iPhone 发起屏幕镜像时，会先用 FairPlay 交换一个视频密钥，然后：

```
视频：AES-128-CTR 加密，密钥由 playfair_decrypt(ekey) 得到
      最终 key = SHA-512("AirPlayStreamKey{streamConnectionID}" || aeskey)[0..16]
           iv  = SHA-512("AirPlayStreamIV{streamConnectionID}" || aeskey)[0..16]
音频：AES-CBC，aeskey / aesiv 就直接放在 ANNOUNCE 请求里
```

关键点在于 `ekey` 的解密表：这些表当年从 Apple TV / macOS 里提取出来，`playfair` 项目以 C 源码公开，后来被 shairplay → RPiPlay → UxPlay 一路继承。**有了表，就能解出 ekey，接收端就不需要任何苹果授权。**

还有一个更省事的技巧（UxPlay 发现，shairplay-rust 复现验证过）：

> 在 Bonjour 的 TXT 记录里把 `features` 设成 **`0x527FFEE6`**（bit 27「legacy pairing」关掉），
> iPhone 会**跳过 pair-setup / pair-verify**，直接在 SETUP 里把 `ekey`（72 字节）发过来，
> 接收端只要 FairPlay 解密即可，不需要 ECDH、不需要配对码。

这就是为什么几百块的投屏盒子、以及 AirServer / Reflector / LetsView / 5KPlayer 这类 Windows 软件都能收 iPhone 屏幕。

**代价（协议层面的硬限制，改不了）：**

| 限制 | 原因 |
|---|---|
| DRM 内容黑屏（Netflix / Apple TV+ 等） | 受保护内容走 HDCP，接收端没有授权链路，直接拒绝 |
| 只能看不能点 | 镜像协议没有反向触摸通道（CarPlay 才有） |
| 必须同局域网 + 有 mDNS | Bonjour 服务发现是入口，跨网段收不到 |
| 不支持 AirPlay 2 视频串流 | 那是另一套（HLS relay），Apple 没开放给第三方 |

自建可选：Linux/树莓派/Windows(MSYS2) 跑 **UxPlay**（GPLv3）；Windows 上更省事的是装现成接收端软件。

---

## 二、CarPlay：主机不需要授权，因为认证芯片在 dongle 里

CarPlay 的认证是**双向但不对称**的：

```
iPhone 侧：向配件要 X.509 证书 → 发 20 字节随机挑战 → 验签名
配件侧：用 MFi 认证协处理器（如 MFi 3959 / MFI343S001）里的私钥签名
```

这里的私钥烧在芯片里，导不出来，**没有真芯片就一定过不了**。所以"软件模拟 CarPlay 主机"这条路本质上不存在。

但市面上那些**不合规的 Android 车机**是怎么做的？它们根本没在主机里做认证：

> 主机只是 USB 主机，CarPlay 的认证、解码、Wi-Fi 组网全在一个 **CarPlay dongle** 里完成。
> dongle 里有一颗**真·苹果 MFi 芯片**（这才是合法件），主机只跑逆向出来的 dongle 私有协议：
> `发送控制帧 → 收 H.264 视频 → 回传触摸坐标`。

所以"授权"被转移到了那颗芯片上，主机（Android 车机 / 树莓派 / 你的电脑）完全不需要认证。这也是为什么这类盒子能公开卖。

对应的开源/工程实现（都是"主机侧"）：

| 项目/资料 | 作用 |
|---|---|
| `node-carplay` | 在 Node/Electron 里跑 dongle 协议，把 CarPlay 画面渲染到窗口 |
| `carplay-raspberrypi` | 树莓派上驱动 dongle，直接输出到 HDMI / DRM |
| `WirelessCarPlay` / `redline-labs` 文档 | iAP2 + MFi 芯片（I2C 0x11）完整实现说明，适合自己焊板子 |
| `wiomoc/iap2`、`carplayed` | iAP2 协议栈的 Python 实现与研究笔记 |

另有一条更极客的路：自己买 MFi 3959 芯片 + MCP2221A 转 I2C，跑完整的 iAP2 栈当成"车机"。技术上成立，但芯片供货只对授权厂开放，个人只能碰拆机件，性价比极低。

**绕不过去的那一环**：iPhone 一定验配件的签名，所以**没有真芯片就没有 CarPlay**（不管主机是谁）。

---

## 三、这三条对"投到九号仪表"分别意味着什么

| 路线 | 需要什么 | 端到端延迟 | 能不能投到仪表 | 本仓库支持情况 |
|---|---|---|---|---|
| AirPlay 接收端 + 窗口捕获 | Windows 装 AirServer/LetsView，或树莓派跑 UxPlay | 150–250ms | ✅ | **已实现**（`bridge/stream_bridge.py --source window:标题`） |
| CarPlay dongle + node-carplay 窗口 | dongle（¥100–300）+ Node 环境 | 200–300ms | ✅ | **已实现**（同上，抓 Electron 窗口） |
| CarPlay dongle + 树莓派直出 | dongle + Pi + HDMI 采集卡 | 250–350ms | ⚠️ 多一次采集 | 可用 `--source /dev/video0` 或采集卡地址 |
| 自己焊 MFi 芯片当车机 | MFi 3959 + 开发板 + iAP2 栈 | — | 理论可行 | 不涉及（工作量过大） |
| 仪表直收 AirPlay/CarPlay | 仪表内置接收端 | — | ❌ | 仪表没算力、没授权 |

桥接器的存在意义就是把"源"和"仪表协议"解耦：**不管画面从哪来，最后都走同一条 UDP 5012**。

---

## 四、实践顺序建议

1. **先验证链路**（不需要任何苹果授权硬件）：`--source desktop` 抓桌面推仪表，能出画面就说明协议对了。
2. **再上 AirPlay**：Windows 装一个 AirPlay 接收端，iPhone 镜像过去，`--list-windows` 找到窗口标题，`--source window:标题`。
3. **最后才是 CarPlay**：买 dongle → 跑 node-carplay → 同样抓它的窗口。这一步的钱花在 dongle 上，不在软件上。

## 五、风险与边界

- FairPlay 静态表属于逆向产物，用于**解密自己设备的画面**没问题，**商用分发**有法律风险（本仓库不分发任何 FairPlay 代码）。
- CarPlay dongle 的固件协议各家不同（Carlinkit / Autokit / 山寨），换盒子可能要重适配。
- 仪表端协议是逆向来的，固件升级可能失效；投屏会占用仪表 Wi-Fi 与解码资源。
- 行车中操作手机/看视频本身有安全与合规风险，本文只谈技术。

# ninebot-dash-cast

九号电动车仪表投屏协议的**逆向规格**、**跨平台发送端**，以及针对开源 iOS 客户端 [NinebotCast](https://github.com/Corpse-zhao/NinebotCast) 的一组**修正补丁**。

把手机 / 电脑画面推给九号电动车的彩屏仪表（五寸 848×480、4.3 寸 480×272），走的是仪表自己开的 Wi-Fi 热点 + UDP 5012 私有 RTP 通道，不是 AirPlay / Miracast。

> 本项目与九号公司无任何关联，纯属协议研究。协议可能随固件变化，一切以你自己的车为准。

---

## 1. 仓库包含什么

| 目录 | 内容 |
|---|---|
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | 20 字节私有头逐字段规格、分片规则、心跳/断开包、两个通道 |
| [`docs/REVERSE-NOTES.md`](docs/REVERSE-NOTES.md) | 逆向方法、Mach-O 符号与指令地址、每条结论的证据位置、复现命令 |
| [`docs/UNAUTHORIZED.md`](docs/UNAUTHORIZED.md) | AirPlay / CarPlay 为什么不用授权也能用：FairPlay 静态表、dongle 里的 MFi 芯片 |
| [`tools/protocol.py`](tools/protocol.py) | 纯函数实现：打包、分片、心跳、pong 解析 |
| [`tools/ninebot_send.py`](tools/ninebot_send.py) | 发送端：测试图 / 图片 / 视频 → H.264 或 JPEG → UDP 5012 |
| [`tools/ninebot_probe.py`](tools/ninebot_probe.py) | 控制通道探测：发心跳、打印 pong 原文与 RTT、网段扫描 |
| [`tools/test_protocol.py`](tools/test_protocol.py) | 离线单元测试，逐字节断言头部（不联车也能跑） |
| [`bridge/stream_bridge.py`](bridge/stream_bridge.py) | 桥接任意画面：桌面 / 窗口 / 区域 / 网络流 → 仪表（AirPlay、CarPlay 都走这里） |
| [`ios/`](ios/) | NinebotCast 的修正补丁（MIT）与改动后的源文件 |

协议规格来自对 **xmz28/ninebot_pro iOS 1.0.0**（`com.hanlin.ninebotpro`）二进制的静态逆向：该版本符号表未剥离，13,134 个符号，可以直接定位到 `H264Packetizer.packets()` 这类函数并读指令。详见逆向笔记。

## 2. 快速开始

```bash
pip install -r tools/requirements.txt   # Pillow；ffmpeg 缺失时会用 imageio-ffmpeg 自带的二进制

# 0) 先不联车，看看包结构对不对
python tools/test_protocol.py
python tools/ninebot_send.py --host 127.0.0.1 --preset 5in --dry-run --duration 2

# 1) 确认仪表在线（电脑已连仪表热点，仪表进入投屏接收态）
python tools/ninebot_probe.py --host 192.168.1.1

# 2) 推测试图，10 秒
python tools/ninebot_send.py --host 192.168.1.1 --preset 5in --duration 10

# 3) 推图片 / 视频
python tools/ninebot_send.py --host 192.168.1.1 --source image:nav.png
python tools/ninebot_send.py --host 192.168.1.1 --source video:demo.mp4
```

参数：`--preset 5in|4.3in|7in`、`--fps`、`--bitrate`、`--gop`、`--quality`、`--chunk`、`--no-bind-port`。
静态图片源默认每秒 2 帧刷新（仪表收到新帧才重绘，没必要按 20fps 重发）。
`7in` 需要 KCP 封装，本工具**未实现**，只保留给抓包对照。

## 3. 协议一句话版

```
UDP 5012  视频：20 字节头 + 1380 字节载荷（整包 1400）
UDP 5013  控制：20 字节 RTCP APP 心跳，仪表回 pong 后可算 RTT
```

| 偏移 | 含义 |
|---|---|
| 0 | `0x90` = RTP V2 + 扩展头 |
| 1 | PT=32，末片置 0x80 |
| 2–3 | 序列号 BE16 |
| 4–7 | 时间戳 BE32（毫秒） |
| 8–11 | SSRC（H.264 官方实现恒 0） |
| 12–15 | 视频包 `00 00 00 01`；心跳包为计数器 LE32 |
| 16 | 视频 0 / 心跳 2 |
| 17 | `0x10` 首片 `0x08` 末片 `0x01` 关键帧 `0x02` 非关键帧 |
| 18–19 | 时间戳低 10 位的 **LE16** |

## 4. 桥接任意画面：桌面 / AirPlay / CarPlay

`bridge/stream_bridge.py` 把任何 ffmpeg 读得动的源，编码成仪表要的 H.264 Baseline，再走同一条 UDP 5012：

```bash
python bridge/stream_bridge.py --list-windows                    # 列出可见窗口标题
python bridge/stream_bridge.py --host 192.168.1.1 --source desktop
python bridge/stream_bridge.py --host 192.168.1.1 --source window:AirServer
python bridge/stream_bridge.py --host 192.168.1.1 --source region:0,0,1280,720
python bridge/stream_bridge.py --host 192.168.1.1 --source rtsp://192.168.1.50:8554/carplay
python bridge/stream_bridge.py --host 192.168.1.1 --source demo.mp4 --duration 30
```

三种典型接法：

| 想看什么 | 装什么 | 抓什么 |
|---|---|---|
| iPhone 全屏镜像 | Windows：AirServer / LetsView；或树莓派跑 UxPlay | `--source window:接收端窗口标题` |
| CarPlay | CarPlay dongle（约 100–300 元）+ node-carplay | `--source window:node-carplay 窗口` |
| 电脑桌面 | 什么都不用装 | `--source desktop` |

为什么这条链子不需要苹果授权，见 [docs/UNAUTHORIZED.md](docs/UNAUTHORIZED.md)：AirPlay 靠公开的 FairPlay 静态表解 `ekey`，CarPlay 靠 dongle 里那颗真 MFi 芯片做认证——主机侧两者都不需要授权。桥接器只负责最后一公里：把像素变成仪表认的 20 字节头。

## 5. iOS 补丁修了什么

补丁针对 [Corpse-zhao/NinebotCast](https://github.com/Corpse-zhao/NinebotCast)（MIT）当前 main：

| # | 问题 | 影响 | 修复 |
|---|---|---|---|
| 1 | 分片默认 1400 载荷 | 整包 1420 字节，超过部分仪表接收窗口 | 改 1380（20+1380=1400） |
| 2 | 非关键帧标志位缺 `0x02` | 仪表可能按关键帧处理，参考链错乱 | 非关键帧恒带 `0x02` |
| 3 | 帧标签写成 `BE16(1024+ts)` | 与官方 LE16(ts&0x3FF) 不一致 | 改为小端、去掉 +1024 |
| 4 | pong 硬校验长度 == 20 | **七寸仪表回 24 字节 → 永远显示「尚无回应」** | 20/24 都接受，计数器两处都试 |
| 5 | 静止图片每帧重编码 | 白占 Wi-Fi 与仪表解码 | `StaticFrameGate`：每秒刷新 1 次 |
| 6 | 拥塞时丢帧后补关键帧 | 关键帧 5~8 倍大，越堵越发大包 | `CongestionGovernor`：先降码率、再隔帧 |
| 7 | 关键帧重发默认开 | 带宽翻倍 | 默认关，UI 文案标注 |

用法见 [`ios/README.md`](ios/README.md)。

## 6. 与上游的关系（重要）

| 项目 | 关系 | 许可 |
|---|---|---|
| [xmz28/ninebot_pro](https://github.com/xmz28/ninebot_pro) | **协议事实来源**。本仓库对该项目的 iOS 版做静态逆向得到规格；未复制其任何代码（其仓库只分发二进制） | 上游未声明 |
| [Corpse-zhao/NinebotCast](https://github.com/Corpse-zhao/NinebotCast) | iOS 端基线。`ios/Sources/` 下是本仓库修改后的文件，仍受原 MIT 许可约束 | MIT |
| [Xiaolangs/ninebot-cast-tweak](https://github.com/Xiaolangs/ninebot-cast-tweak) | 九号出行官方 App 的逆向结论（RTCP APP 子类型 5、HUD 参数） | 未声明 |
| [KaruMono/NinebotEnhance](https://github.com/KaruMono/NinebotEnhance) | 仪表投屏机制的公开说明（必须先进入接收态） | — |
| [skywind3000/kcp](https://github.com/skywind3000/kcp) | 七寸通道用的 KCP，随 NinebotCast 一起分发 | 见其自带许可 |

如果你只想要**能用的 iOS 客户端**，请优先看上游 NinebotCast；本仓库的 `ios/` 是补丁，不是独立 App。

## 7. 已知限制与未验证项

- **七寸仪表未验证**：KCP 封装未实现；24 字节 pong 解析已做宽容处理，但没有实机数据。
- **4.3 寸 JPEG 路径**：打包按逆向规格实现，仪表端显示效果未验收。
- **字节 15 恒为 1、字节 16 心跳为 2** 的语义仍未确认，只按观察值写入。
- **H.264 包的 SSRC 恒 0**，仪表明显不校验，但不代表所有车型都不校验。
- **必须先让仪表进入投屏接收态**：它在巡航/待机时不开 socket，收不到任何包。
- iOS 端依赖私有接口与自签证书，7 天过期；`CarWithin` 那类同机 CarPlay 方案属于实验链路。

## 8. 免责声明

- 仅供学习与研究，**不要用于商业分发**。
- 投屏会占用仪表 Wi-Fi 与解码资源，可能导致发热、掉帧；自担风险。
- 修车、固件升级后协议可能失效，本项目不做兼容承诺。
- 商标「九号 / Ninebot / Segway」归九号公司所有。

## License

本仓库原创部分（`docs/`、`tools/`、`ios/` 中的新增文件与补丁说明）采用 **MIT**，见 [LICENSE](LICENSE)。
`ios/Sources/` 中来自 NinebotCast 的文件沿用其 **MIT** 许可，版权归原作者；第三方组件许可见 [NOTICE.md](NOTICE.md)。

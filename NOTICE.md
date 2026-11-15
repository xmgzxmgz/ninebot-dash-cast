# 第三方组件与来源

本项目的协议规格来自对闭源二进制的静态分析，代码部分只派生自下方标注为 MIT 的项目。

## 代码派生

| 位置 | 上游 | 许可 | 说明 |
|---|---|---|---|
| `ios/Sources/RTPPacker.swift`<br>`ios/Sources/CastEngine.swift`<br>`ios/Sources/MainView.swift`<br>`ios/ninebotcast-fixes.patch` | [Corpse-zhao/NinebotCast](https://github.com/Corpse-zhao/NinebotCast) | MIT © 2026 Corpse-zhao | 修改后的文件；原文件版权归原作者，保留 MIT 许可 |
| `ios/Sources/TransportTuning.swift` | 本项目原创 | MIT | 拥塞治理与静止画面闸门 |
| 上游 `Vendor/kcp/ikcp.c`（未随本仓库分发，在上游仓库内） | [skywind3000/kcp](https://github.com/skywind3000/kcp) | 见其自带许可 | 七寸通道使用 |

## 协议事实来源（未复制代码）

| 项目 | 用途 | 说明 |
|---|---|---|
| [xmz28/ninebot_pro](https://github.com/xmz28/ninebot_pro) | 逆向对象：iOS 1.0.0 二进制 | 该仓库只分发 APK/IPA，无源码；本项目仅做静态分析，未使用其代码 |
| [Xiaolangs/ninebot-cast-tweak](https://github.com/Xiaolangs/ninebot-cast-tweak) | 九号出行官方 App 的逆向结论 | RTCP APP 子类型 5、HUD 编码参数等交叉验证 |
| [KaruMono/NinebotEnhance](https://github.com/KaruMono/NinebotEnhance)（fork: tyh3520） | 仪表投屏机制说明 | 「仪表必须先进入接收态」等前提 |
| [OpenXPlay/OpenXPlay](https://github.com/OpenXPlay/OpenXPlay) | CarPlay 转发参考 | 与本项目协议无关，仅说明 8443 那条旁路 |

## 商标

「九号 / Ninebot / Segway」为九号公司商标。本项目与九号公司无关联，未获其授权或背书。

## 免责

本项目仅用于协议研究与自有设备调试。请勿用于商业分发、绕过付费功能或任何侵犯他人权益的场景。

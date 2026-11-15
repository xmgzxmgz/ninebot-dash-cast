# iOS 端补丁（针对 NinebotCast）

上游：[Corpse-zhao/NinebotCast](https://github.com/Corpse-zhao/NinebotCast)（MIT）
基线提交：`d2d125a66f7ad46b41f12f3e8727e30266dcc886`（main，2026-11-15）

## 应用方式

**方式一：打补丁**

```bash
git clone https://github.com/Corpse-zhao/NinebotCast.git
cd NinebotCast
git checkout d2d125a
git apply /path/to/ninebotcast-fixes.patch
```

**方式二：直接替换文件**

把 `Sources/` 下这四个文件覆盖到上游同名位置（`TransportTuning.swift` 是新增文件）：

```
Sources/RTPPacker.swift
Sources/CastEngine.swift
Sources/MainView.swift
Sources/TransportTuning.swift   # 新增
```

改完用上游的 GitHub Actions（`xcodegen` + `xcodebuild archive`，不签名）出未签名 IPA，再自签安装。

## 改了什么

### 1. `RTPPacker.swift` — 协议对齐

| 项 | 改前 | 改后 | 依据 |
|---|---|---|---|
| 分片 | 载荷 1400（整包 1420） | 载荷 **1380**（整包 1400） | `cmp x8,#0x564` @ `0x10002bba8` |
| 非关键帧标志 | 只写 `0x10/0x08` | 追加 `0x02` | `csel w9,#0x12,#0x02,eq` @ `0x10002bcec` |
| 帧标签 [18..19] | `BE16(1024+ts)` | `LE16(ts & 0x3FF)` | `bfxil w11,w8,#0,#0xa` + `writeLE` @ `0x10002baf4` |
| 心跳 | `RTCP.heartbeat()` 把 2 写在第 19 字节，没有计数器 | `RTCP.heartbeat(counter:)`：计数器小端写 [12..15]、第 16 字节 = 2 | `0x10002be88` / `0x10002be9c` / `0x10002bec0` |
| pong 解析 | 强制长度 == 20 | 20/24 都接受，计数器两处都试 | `cmp x8,#0x14` @ `0x10002c00c`（七寸回 24 字节） |

### 2. `Sources/TransportTuning.swift` — 新增

- `CongestionGovernor`：按 RTT 与仪表丢包报告分级降码率（1.0 / 0.75 / 0.5 / 0.35），严重时隔帧发送。
  替代「发送缓冲区满 → 丢帧 → 立刻补关键帧」的做法——关键帧通常是非关键帧的 5~8 倍大，
  拥塞时补关键帧等于往堵住的管子里塞更大的包。
- `StaticFrameGate`：相册图片这类静止画面每秒只编码 1 次，仪表本来就保持上一帧。

### 3. `CastEngine.swift` — 挂接

- `start()` 默认值改为 `packetSize: 1380`、`gop: 20`、`duplicateKeyframes: false`。
- pong 回调里喂 `CongestionGovernor.sample(rttMs:)`，降档时调用 `encoder.updateBitrate()` 并在界面提示。
- 仪表上报 subtype 1（丢包）时同样触发降档。
- `produceFrame()`：拥塞隔帧 + 静止画面闸门。

### 4. `MainView.swift` — 默认值

「关键帧重发」默认关（原默认开，等于带宽翻倍）；分片默认 1380；gop 默认 1 秒。

## 风险与未验证

- **未在实机验证**：本次改动基于静态逆向，Swift 代码没有在真机上跑过。首次使用请先只开「仅 RTCP ping」确认 pong，再开画面。
- **七寸仍需 KCP**：本补丁没动 KCP 通道；24 字节 pong 只做了宽容解析，不代表七寸一定能出画面。
- **byte 15 = 1 / byte 16 = 2 语义未知**，按观察值写入。
- iOS 私有行为：后台保活、本地 5012/5013 端口占用（九号出行在前台时会抢端口）都属于上游原有问题，未改动。

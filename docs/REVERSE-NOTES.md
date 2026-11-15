# 逆向笔记

对象：`NinebotPro.ipa`（xmz28/ninebot_pro，iOS 1.0.0，build 1，`com.hanlin.ninebotpro`）
日期：2026-11-15
方法：静态分析（Mach-O 解析 + ARM64 反汇编），**没有**动态调试（无越狱设备）。

## 1. 为什么这份二进制好读

| 条件 | 情况 |
|---|---|
| 架构 | 单架构 arm64，1,521,480 字节，`__text` 344 KB |
| 符号表 | **未剥离**，13,134 个符号，Swift 修饰名完整 |
| 语言 | Swift（`_$s10NinebotPro…`），少量 C 辅助函数 |
| 依赖 | VideoToolbox / AVFoundation / CoreImage / PhotosUI / AVFAudio / SwiftUI；**没有 Network.framework**（用 BSD socket，符号 `_socket`、类 `ConnectedUDPsocket`） |
| 加密 | App Store FairPlay 加密在这里不适用——这是未签名的个人构建，代码段可直接读 |

结论：不需要 FLIRT 签名、不需要跑起来，按符号名就能直接定位到打包函数。

## 2. 工具

本机没有 IDA / Ghidra，用 Python + capstone 做等价工作：

```bash
unzip NinebotPro.ipa -d ipa
BIN=ipa/Payload/NinebotPro.app/NinebotPro

python tools/re/analyze.py info   "$BIN"
python tools/re/analyze.py syms   "$BIN" Packetizer
python tools/re/analyze.py disasm "$BIN" 0x10002ba18 260
python tools/re/analyze.py scan   "$BIN"
```

## 3. 关键地址

| 地址 | 符号 | 用途 |
|---|---|---|
| `0x10002ba18` | `H264Packetizer.packets(for:timestampMilliseconds:isKeyframe:repeatKeyframe:)` | 20 字节头 + 1380 分片 |
| `0x10002a910` | `JPEGPacketizer.packets(for:timestamp:)` | JPEG 路径（载荷 1400、byte17 恒 1） |
| `0x10002be4c` | `H264Packetizer.heartbeat(counter:)` | 20 字节心跳 |
| `0x10002beec` | `H264Packetizer.heartbeatReplyCounter(_:)` | pong 校验（硬校验 20 字节） |
| `0x10002b184` | `JPEGPacketizer.bye(timestamp:unixMilliseconds:)` | 72 字节断开包 |
| `0x1000225f4` | `MirrorSession.run` | 建 UDP 5012 |
| `0x10002263c` | `MirrorSession.run` | 建 UDP 5013 |
| `0x10002a45c` | `NetworkProbe.run` | 用 5013 做健康探测 |

## 4. 逐条证据

### 4.1 头长 20、byte0 = 0x90、末片置 marker

```
0x10002bbe8  mov  w0, #0x14          ; Data(count: 20)
0x10002bbf8  mov  w8, #0x14
0x10002bbfc  str  x8, [x0, #0x10]     ; 长度 20
0x10002bc0c  mov  w8, #0x90
0x10002bc10  strb w8, [x0, #0x20]     ; 头[0] = 0x90
0x10002bc14  cmp  x28, x21            ; 片尾 == NAL 末尾？
0x10002bc18  mov  w8, #0x20           ; PT 32
0x10002bc1c  mov  w9, #-0x60          ; 0xA0 = marker | PT
0x10002bc20  csel w8, w9, w8, eq
0x10002bc24  strb w8, [x0, #0x21]     ; 头[1]
```

### 4.2 分片 1380

```
0x10002bba8  cmp  x8, #0x564          ; 0x564 = 1380
0x10002bbac  mov  w9, #0x564
0x10002bbb0  csel x8, x8, x9, lt      ; 剩余不足 1380 就取剩余
```

`__cstring` 里另有字符串 `"20 + 1400"`，指「20 字节头 + 1400 整包」。

### 4.3 标志位

```
0x10002bcbc  cmp  x27, #0              ; 片偏移是否为 0
0x10002bcc0  mov  w9, #0x11
0x10002bcc4  csinc w9, w9, wzr, eq     ; 首片 → 0x11，否则 → 0x01（关键帧分支）
...
0x10002bce4  mov  w9, #2
0x10002bce8  mov  w10, #0x12
0x10002bcec  csel w9, w10, w9, eq      ; 非关键帧首片 → 0x12，否则 → 0x02
0x10002bcd0  mov  w10, #8              ; 末片
0x10002bd04  orr  w8, w9, w10
0x10002bd08  strb w8, [x20, #0x31]     ; 头[17]
```

### 4.4 帧标签：LE16，取时间戳低 10 位

```
0x10002baf0  ldr  w8, [sp, #0x2c]      ; 时间戳
0x10002baf4  bfxil w11, w8, #0, #0xa   ; 取低 10 位
0x10002baf8  str  w11, [sp, #0x24]
0x10002bcfc  ...
0x10002bd18  mov  w1, #0x12            ; 偏移 18
0x10002bd1c  bl   writeLE<UInt16>(at:)  ; 小端写 2 字节
```

### 4.5 心跳：常量直接躺在 __const 里

```
__const 0x10005c218 = 85 CC 00 04 00 00 00 00
__const 0x10005c220 = 85 CC 00 03 00 00 00 01   ; 16 字节变体

0x10002be68  mov  w20, #0x14
0x10002be6c  mov  w0, #0x14           ; Data(count: 20)
0x10002be7c  stur xzr, [x0, #0x24]    ; [4..11] = 0
0x10002be84  ldr  d0, [x8, #0x218]    ; 85 CC 00 04 00 00 00 00
0x10002be88  str  s0, [x0, #0x20]     ; 头[0..3] = 85 CC 00 04
0x10002be98  mov  w1, #0xc            ; 偏移 12
0x10002be9c  bl   writeLE<UInt32>     ; 计数器小端写 [12..15]
0x10002bec0  strb w8(=2), [x19, #0x30] ; 头[16] = 2
```

### 4.6 pong 校验硬编码 20 字节

```
0x10002c00c  cmp  x8, #0x14           ; 长度必须 == 20
0x10002c014  ldrb w8, [x0, #0x20]
0x10002c018  cmp  w8, #0x85           ; 头[0]
0x10002c020  cmp  w8, #0xcc           ; 头[1]
0x10002c030  cbnz w8, fail            ; 头[2] 必须 0
0x10002c038  cmp  w8, #4              ; 头[3] 必须 4
```

七寸仪表回 24 字节时，第一条 `cmp x8, #0x14` 就跳走了——这正是上游 README 里「七寸日志显示尚无回应」的根因。

### 4.7 端口 5012 / 5013

```
0x1000225f4  mov  w2, #0x1394         ; 5012，MirrorSession.run
0x10002263c  mov  w2, #0x1395         ; 5013，MirrorSession.run
0x10002a45c  mov  w2, #0x1395         ; 5013，NetworkProbe.run
```

## 5. 未能确认的部分

| 项 | 现状 | 怎么确认 |
|---|---|---|
| byte 15 恒 1 | 两个 packetizer 都写 1 | 抓官方 App 的包对比，或动态调试 |
| byte 16 心跳为 2 | 代码写 2、无分支读 | 改值试车，或看仪表固件 |
| 七寸 24 字节 pong 布局 | 只知道长度 | 七寸实车抓包 |
| 72 字节断开包 | 只读出前 12 字节与 NTP 时间戳 | 完整反汇编 `JPEGPacketizer.bye` |
| SSRC 是否被校验 | H.264 恒 0 也能出画面（上游实测） | 不同车型验证 |

## 6. 复现路径

1. `unzip NinebotPro.ipa -d ipa`
2. `python tools/re/analyze.py syms ipa/Payload/NinebotPro.app/NinebotPro Packetizer`
3. 用上表地址 `disasm`，对照第 4 节的指令模式。
4. 用 `tools/test_protocol.py` 校验本仓库实现与逆向结果是否一致。

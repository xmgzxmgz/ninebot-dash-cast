# SingleCast —— 单机直连仪表的 App 骨架（M1）

目标：**一台 iPhone 自己接收 CarPlay，并把画面直接推给九号仪表**，不经过电脑、不经过录屏。

当前进度：**M1 真机验证通过**（2026-11-15，测试图彩条 + 帧号已在仪表正常显示）。M2 在真机上已能把私有 `CoreAccessories` 加载进进程（`ACCTransportClient` 可见，57 个方法），卡在虚拟配件端点创建，正在区分「参数不对」与「entitlement 被拒」；M3/M4 仍需真机。

> **第一次上手先读 [USAGE.md](USAGE.md)**：车机怎么进接收态、手机怎么连热点、IP 怎么自动探测，以及每种失败现象对应的动作。

## 目录

```
ios-single/
├── USAGE.md                 # 使用说明（三步流程 + 失败分支）
├── project.yml              # xcodegen 工程描述（iOS 16.4+，不签名）
└── Sources/
    ├── NinebotLink.swift    # 20 字节头 + 1380 分片 + 心跳 + BSD socket UDP
    ├── NetworkProbe.swift   # 本机 IP 读取 + 一键探测车机（发心跳收 pong）
    ├── FrameEncoder.swift   # VideoToolbox Baseline 编码，AVCC→Annex-B，关键帧带 SPS/PPS
    ├── CastApp.swift        # 控制层 + 测试图 + 极简 SwiftUI 界面
    └── CarPlayReceiver.swift# CarPlay 接收层接口（stub，未实现）
```

## 为什么先做 M1

M1 跑的是"测试图 → 编码 → 私有协议 → UDP"这一段。它把除 CarPlay 之外的所有变量都固定住：
只要测试图能点亮仪表，就证明协议实现、编码参数、socket 绑定都没问题，后面接 CarPlay 画面时
出问题就只可能是接收层。仓库里的 Python 实现（`tools/`）已在电脑上验证过同一套协议，
这里是把等价逻辑搬到 Swift。

## 构建

本地（需要 macOS + Xcode）：

```bash
brew install xcodegen
cd ios-single
xcodegen generate
xcodebuild -project SingleCast.xcodeproj -scheme SingleCast \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath build/SingleCast.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

没有 Mac 时用 GitHub Actions（macos-14 + xcodegen），流程与上游 NinebotCast 的
`.github/workflows/build.yml` 一致；产物是未签名 IPA，再自签安装。

> 注意：往仓库里加 workflow 需要 token 带 `workflow` 权限，当前 token 没有，所以仓库里没放 CI 文件。

## 里程碑

| 阶段 | 内容 | 状态 |
|---|---|---|
| M1 | 测试图 + 编码 + 仪表协议 + UDP | ✅ **真机验证通过**（2026-11-15，彩条 + 帧号正常显示） |
| M2 | MFi 证书加载 + 虚拟配件 + iAP2 认证 | ⛔ **自签环境已证实受阻**：`ACCTransportClient` 能加载、连接能建，虚拟配件端点 24 种组合全部返回 `nil`（证据见下） |
| M3 | RTSP 协商 + 收 H.264 ES | 🟡 代码完成（`RTSPClient` / `H264Decoder`），消息 ID 与端口待实机校准 |
| M4 | 解码 → 缩放 → 重编码 → 推仪表 | 🟡 代码完成（`FrameScaler` + 既有 `FrameEncoder`），未联调 |
| M5 | 触摸回传、后台保活 | 可选 |

## 已知风险

- `VTCompressionSessionEncodeFrame` 的闭包重载需要 iOS 9+，这里用最新签名，若编译报错按 Xcode 提示换老签名。
- Swift 6 严格并发可能对 `CastController` 的跨队列访问报错，必要时加 `@MainActor` 或 `nonisolated(unsafe)`。
- M2 依赖私有 `CoreAccessories`。真机已验证：`dlopen` 该框架后能取到 `ACCTransportClient`；但虚拟配件端点创建仍失败，自签环境能否拿到对应 entitlement 待确认。
- 证书来源见 `docs/CARWITHIN-RE.md` 第 4 节，自用测试与再分发是两件事。

## M2 为什么停在这里（真机证据，2026-11-15）

自签安装、iOS 26.5 真机，完整探测日志：

```
ACCTransportClient classFound=true  方法 57 个  canCreateEndpoint=true
[ACC] createConnection 编码 @28@0:8i16@20
[ACC] createEndpoint   编码 @52@0:8i16i20@24@?32@40B48
[ACC] createConnection type=0 → C5A70951-AB4B-4F9E-B8AD-B63B600ED046
[ACC] createEndpoint proto=com.apple.carplay transport=0 publish=true → nil
…（3 种协议名 × transportType 0…3 × publish 两态，共 24 次，全部 nil）
[ACC] 已加载的相关镜像：MSUDataAccessor, AccessorySensorManagerServices,
      AccessorySensorManagerDefines_Private, ExternalAccessory, IAP,
      libIOAccessoryManager.dylib, CoreAccessories
```

能排除的：

- **不是类找不到** —— dlopen 之后 `ACCTransportClient` 在，57 个方法可见，`createEndpoint` 选择器响应正常。
- **不是参数 ABI 不对** —— 两个方法的类型编码与实际传参对齐（`i` / `@` / `@?` / `B` 顺序一致）。
- **不是连接没建** —— `type=0` 就返回了合法 UUID，端点用的是这个 UUID。
- **不是协议名/传输类型猜错** —— 三种协议名、四种 transportType、publish 两态全试遍。

剩下唯一解释：accessoryd 对**端点创建**做了客户端校验，需要自签包拿不到的 entitlement（`com.apple.private.accessories.*` 一类）。注意 `ACCTransportIO` 在已加载镜像里并不存在——CarWithin 那条路很可能还依赖一个当前进程里根本没有的 IO 层。

结论：**M3/M4 没有意义再往下做**，除非能拿到 MFi/企业签名或换用带认证芯片的硬件方案（CarPlay dongle → 电脑端 `bridge/stream_bridge.py` 抓窗口，这条路不需要动 iOS）。

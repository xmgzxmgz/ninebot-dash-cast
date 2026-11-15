# SingleCast —— 单机直连仪表的 App 骨架（M1）

目标：**一台 iPhone 自己接收 CarPlay，并把画面直接推给九号仪表**，不经过电脑、不经过录屏。

当前进度：**M1 已通过 GitHub Actions（macos-latest）编译，产物 `SingleCast-unsigned.ipa`（约 33 KB）已可下载**；尚未真机验证。M2/M3（CarPlay 接收）只有接口与注释。

## 目录

```
ios-single/
├── project.yml              # xcodegen 工程描述（iOS 16.4+，不签名）
└── Sources/
    ├── NinebotLink.swift    # 20 字节头 + 1380 分片 + 心跳 + BSD socket UDP
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
| M1 | 测试图 + 编码 + 仪表协议 + UDP | ✅ 已编译通过（CI 59s），待真机验证 |
| M2 | MFi 证书加载 + 虚拟配件 + iAP2 认证 | 🟡 身份/签名/SRP/TLV8 已编译通过（见 docs/AUTH.md），虚拟配件与 iAP2 未完成 |
| M3 | RTSP 协商 + 收 H.264 ES | 未开始 |
| M4 | 解码 → 缩放 → 重编码 → 推仪表 | 未开始（M1 已备好下游） |
| M5 | 触摸回传、后台保活 | 可选 |

## 已知风险

- `VTCompressionSessionEncodeFrame` 的闭包重载需要 iOS 9+，这里用最新签名，若编译报错按 Xcode 提示换老签名。
- Swift 6 严格并发可能对 `CastController` 的跨队列访问报错，必要时加 `@MainActor` 或 `nonisolated(unsafe)`。
- M2 依赖私有 `CoreAccessories`，自签环境能否拿到该 entitlement 需真机实测。
- 证书来源见 `docs/CARWITHIN-RE.md` 第 4 节，自用测试与再分发是两件事。

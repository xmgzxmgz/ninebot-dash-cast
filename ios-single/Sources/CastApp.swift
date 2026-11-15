import SwiftUI
import UIKit
import CoreVideo
import PhotosUI

/// 控制层：两种模式
/// - 测试图：验证"仪表侧输出"（协议 / 编码 / socket）
/// - CarPlay：虚拟配件 → iAP2 认证 → RTSP → 解码 → 重编码 → 仪表
final class CastController: ObservableObject {
    @Published var statusText = "待机"
    @Published var frames = 0
    @Published var packets = 0
    @Published var logs: [String] = []
    @Published var localIP: String?
    @Published var hits: [ProbeHit] = []
    @Published var probing = false
    let identityStatus: String

    private var encoder: FrameEncoder?
    private var receiver: CarPlayReceiver?
    private var video: UDPSender?
    private var control: UDPSender?
    private var packetizer = NinebotPacketizer()
    private var frameTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatCounter: UInt32 = 0
    private var frameIndex: Int64 = 0

    private let width = 848
    private let height = 480
    private let fps = 20

    init() {
        do {
            let identity = try MFiIdentity()
            identityStatus = identity.selfCheck()
                ? "MFi 身份可用：私钥对 Apple 证书验签通过"
                : "身份已加载，但签名自检失败"
        } catch {
            identityStatus = "身份加载失败：\(error)"
        }
        localIP = NetworkProbe.localIPv4()
    }

    private func log(_ text: String) {
        DispatchQueue.main.async {
            self.logs.append(text)
            if self.logs.count > 200 { self.logs.removeFirst(self.logs.count - 200) }
        }
    }

    // MARK: - 网络与探测

    func refreshNetwork() {
        let ip = NetworkProbe.localIPv4()
        localIP = ip
        log(ip.map { "本机 IP：\($0)" } ?? "没读到本机 IP，检查 Wi-Fi 是否已连上")
    }

    func probe() {
        guard !probing else { return }
        probing = true
        hits = []
        log("开始探测车机地址…")
        NetworkProbe.scan(timeout: 2.5, log: { [weak self] line in
            self?.log(line)
        }, completion: { [weak self] hits, local in
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                self.hits = hits
                if let local { self.localIP = local }
                self.statusText = hits.isEmpty
                    ? "没找到车机（看「遇到问题」）"
                    : "找到车机：\(hits.map(\.host).joined(separator: "、"))"
            }
        })
    }

    func copyLogs() {
        UIPasteboard.general.string = logs.joined(separator: "\n")
        statusText = "日志已复制，可直接粘贴发给我"
    }

    // MARK: - 公共装配

    private func prepare(host: String) -> Bool {
        stop()
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { statusText = "仪表 IP 为空"; return false }

        guard let video = UDPSender(host: target, port: 5012, bindLocalPort: 5012) else {
            statusText = "视频 socket 创建失败"; return false
        }
        guard let control = UDPSender(host: target, port: 5013, bindLocalPort: 5013) else {
            statusText = "控制 socket 创建失败"; return false
        }
        self.video = video
        self.control = control
        log("目标 \(target)：视频 5012 / 控制 5013")
        // 绑定结果如实打印：部分车机只认来自 5012 的包，源端口变成随机就白推
        for (name, box) in [("视频", video), ("控制", control)] {
            if let rc = box.bindResult, rc != 0 {
                log("⚠️ \(name)端口绑定失败（errno \(rc)），源端口为系统随机值")
            } else if box.boundPort != 0 {
                log("\(name)本地端口 \(box.boundPort) 绑定成功")
            }
        }

        let encoder = FrameEncoder(configuration: .init(width: width, height: height, fps: fps))
        encoder.onFrame = { [weak self] annexB, keyframe in
            guard let self else { return }
            let ts = UInt32((self.frameIndex * 1000) / Int64(self.fps))
            let packets = self.packetizer.packets(for: annexB, timestampMs: ts, keyframe: keyframe)
            for packet in packets { self.video?.send(packet) }
            DispatchQueue.main.async {
                self.frames += 1
                self.packets += packets.count
            }
        }
        guard encoder.start() else { statusText = "编码器初始化失败"; return false }
        self.encoder = encoder

        frameIndex = 0
        frames = 0
        packets = 0

        let beat = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "singlecast.heartbeat"))
        beat.schedule(deadline: .now() + 0.3, repeating: 1.0)
        beat.setEventHandler { [weak self] in
            guard let self, let control = self.control else { return }
            self.heartbeatCounter &+= 1
            // 两个变体一起发：不同固件认的不是同一个（见 docs/PROTOCOL.md 4.1）
            control.send(NinebotHeartbeat.rtcpApp())
            control.send(NinebotHeartbeat.packet(counter: self.heartbeatCounter))
        }
        beat.resume()
        heartbeatTimer = beat
        return true
    }

    // MARK: - 模式一：测试图

    func startTestPattern(host: String) {
        guard prepare(host: host) else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "singlecast.frames"))
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.frameIndex &+= 1
            guard let buffer = TestPattern.make(index: self.frameIndex, width: self.width, height: self.height) else { return }
            self.encoder?.encode(buffer, frameIndex: self.frameIndex)
        }
        timer.resume()
        frameTimer = timer
        statusText = "测试图发送中 → \(host):5012"
        log("测试图开始：彩条 + 移动方块 + 帧号，车机上应当立刻出现画面")
    }

    // MARK: - 模式三：推一张图（相册 / 截图）

    /// 把一张图推到仪表。仪表收到新帧才重绘，所以每秒重发 2 帧就够，
    /// 静态图没必要按 20fps 烧 Wi-Fi。
    func startImagePush(image: UIImage, host: String) {
        guard prepare(host: host) else { return }
        guard let buffer = ImageFrame.make(image: image, width: width, height: height) else {
            statusText = "图片转换失败（可能是不支持的格式）"
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "singlecast.image"))
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.frameIndex &+= 1
            self.encoder?.encode(buffer, frameIndex: self.frameIndex)
        }
        timer.resume()
        frameTimer = timer
        statusText = "图片推送中 → \(host):5012"
        log("图片推送开始：原图 \(Int(image.size.width))x\(Int(image.size.height))，"
            + "等比缩放补黑边到 \(width)x\(height)，每秒重发 2 帧")
    }

    // MARK: - 模式二：CarPlay

    func startCarPlay(host: String) {
        guard prepare(host: host) else { return }
        do {
            let identity = try MFiIdentity()
            let receiver = CarPlayReceiver(identity: identity)
            receiver.onLog = { [weak self] text in self?.log(text) }
            receiver.onVideoFrame = { [weak self] buffer in
                guard let self else { return }
                self.frameIndex &+= 1
                self.encoder?.encode(buffer, frameIndex: self.frameIndex)
            }
            try receiver.start()
            self.receiver = receiver
            statusText = "CarPlay 会话已发起 → \(host):5012"
        } catch let error as CarPlayReceiver.ReceiverError {
            stop()   // prepare() 已经把心跳跑起来了，失败就别让它空转
            statusText = "CarPlay 起不来，先用「测试图」验证链路"
            log("启动失败：\(error.localizedDescription)")
            log("提示：\(error.hint)")
        } catch {
            stop()
            statusText = "CarPlay 启动失败：\(error.localizedDescription)"
            log("启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        frameTimer?.cancel(); frameTimer = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        receiver?.stop(); receiver = nil
        encoder?.stop(); encoder = nil
        video = nil
        control = nil
        if statusText.contains("发送中") || statusText.contains("会话已发起") {
            statusText = "已停止"
        }
    }
}

/// 测试图：彩条 + 移动方块 + 帧号。
enum TestPattern {
    static func make(index: Int64, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        context.setFillColor(UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                 .systemTeal, .systemBlue, .systemPurple]
        let barWidth = width / colors.count
        for (i, color) in colors.enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: i * barWidth, y: height - height / 3, width: barWidth, height: height / 3))
        }

        let block = width / 16
        let x = Int(index * Int64(max(1, width / 40)) % Int64(max(1, width - block)))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: x, y: height / 2 - block / 2, width: block, height: block))

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        UIGraphicsPushContext(context)
        "FRAME \(String(format: "%06lld", index))  \(width)x\(height)".draw(
            at: CGPoint(x: 16, y: CGFloat(height) / 3 + 16), withAttributes: textAttributes)
        UIGraphicsPopContext()

        return pixelBuffer
    }
}

/// 把 UIImage 画进 CVPixelBuffer：等比缩放 + 居中补黑边，和电脑端 load_image_frame 一个思路。
enum ImageFrame {
    static func make(image: UIImage, width: Int, height: Int) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let scale = min(CGFloat(width) / CGFloat(cgImage.width),
                        CGFloat(height) / CGFloat(cgImage.height))
        let drawWidth = CGFloat(cgImage.width) * scale
        let drawHeight = CGFloat(cgImage.height) * scale
        context.draw(cgImage, in: CGRect(x: (CGFloat(width) - drawWidth) / 2,
                                         y: (CGFloat(height) - drawHeight) / 2,
                                         width: drawWidth, height: drawHeight))
        return pixelBuffer
    }
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var controller = CastController()
    @AppStorage("dashboardHost") private var host = "192.168.1.1"
    @State private var pickedImage: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StepRow(number: 1, title: "车机进入「投屏接收」",
                            detail: "在车机屏幕或九号出行里打开投屏/接收入口。没开这一步，发多少包车机都丢。")
                    StepRow(number: 2, title: "手机连车机热点",
                            detail: "车机会自己开热点，用系统「设置 → Wi-Fi」连上。提示无互联网时选「保持连接」。")
                    StepRow(number: 3, title: "确认地址后推测试图",
                            detail: "点下面「自动探测车机」，找到地址后先推测试图，画面出来再谈 CarPlay。")
                } header: {
                    Text("使用顺序")
                }
                .textCase(nil)

                Section {
                    HStack {
                        Text("本机 IP")
                        Spacer()
                        Text(controller.localIP ?? "未读取")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(controller.localIP == nil ? .secondary : .primary)
                    }
                    Text(networkHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("重新读取网络信息") { controller.refreshNetwork() }
                } header: {
                    Text("第 2 步 · 网络检查")
                }

                Section {
                    HStack {
                        TextField("车机 IP", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(.body, design: .monospaced))
                        Button("探测") { controller.probe() }
                            .buttonStyle(.borderless)
                            .disabled(controller.probing)
                    }
                    if controller.probing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在向 192.168.1.1 / 192.168.169.1 / 本网段网关发心跳…")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(controller.hits) { hit in
                        Button {
                            host = hit.host
                            controller.statusText = "已选用 \(hit.host)"
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(hit.host).font(.system(.body, design: .monospaced))
                                Spacer()
                                Text("\(hit.rttMs) ms · \(hit.bytes) 字节")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("第 3 步 · 车机地址")
                } footer: {
                    Text("「探测」会给候选地址发 20 字节心跳，谁回 85 CC 谁就是车机；点结果可填入。")
                }

                Section {
                    Button {
                        controller.startTestPattern(host: host)
                    } label: {
                        Label("推送测试图（先验证通路）", systemImage: "play.rectangle.fill")
                    }
                    PhotosPicker(selection: $pickedImage, matching: .images) {
                        Label("推送一张图（相册 / 导航截图）", systemImage: "photo.on.rectangle")
                    }
                    .onChange(of: pickedImage) { item in
                        guard let item else { return }
                        Task {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let image = UIImage(data: data) {
                                await MainActor.run {
                                    controller.startImagePush(image: image, host: host)
                                }
                            } else {
                                await MainActor.run { controller.statusText = "读图失败，换一张试试" }
                            }
                            await MainActor.run { pickedImage = nil }
                        }
                    }
                    Button {
                        controller.startCarPlay(host: host)
                    } label: {
                        Label("启动 CarPlay 接收（实验）", systemImage: "car.fill")
                    }
                    Button(role: .destructive) {
                        controller.stop()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                } header: {
                    Text("开始")
                } footer: {
                    Text("测试图是「验路」用的：车机上出现彩条和帧号，说明协议、编码、网络全对。「推送一张图」只用公开 API，导航截图可以直接投上去。CarPlay 模式依赖私有接口，属于实验功能。")
                }

                Section("运行状态") {
                    Text(controller.statusText)
                    Text("帧 \(controller.frames) ／ 包 \(controller.packets)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(controller.identityStatus)
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 160)
                    Button("复制日志") { controller.copyLogs() }
                } header: {
                    Text("日志")
                }

                Section {
                    DisclosureGroup("推了测试图，车机没画面") {
                        Text("① 车机是否真的进了接收态（退回主界面通常就退出了）；② Wi-Fi 是否连的是车机热点；③ IP 是否对（用「探测」）；④ 九号出行 App 可能占着 5012/5013，先杀掉；⑤ 首次运行要允许「本地网络」权限（设置 → SingleCast → 本地网络）。")
                            .font(.footnote)
                    }
                    DisclosureGroup("帧数在涨，但车机没画面") {
                        Text("说明编码在跑、包发出去了，问题在地址或网段。把「本机 IP」和日志复制给我，一般能直接看出是哪个环节。")
                            .font(.footnote)
                    }
                    DisclosureGroup("CarPlay 模式报错") {
                        Text("它会先打印 ACCTransportClient classFound=…。若是 false，说明自签 App 拿不到私有 CarPlay 接口权限，这条路要换方案；把日志复制给我即可判断。")
                            .font(.footnote)
                    }
                    DisclosureGroup("两个按钮有什么区别") {
                        Text("测试图 = 不碰 CarPlay，直接把画的画面推过去，用来排除「协议/网络」；CarPlay = 真的去接管系统 CarPlay 会话。先跑通前者再点后者，出问题才能分清是谁的问题。")
                            .font(.footnote)
                    }
                } header: {
                    Text("遇到问题")
                }
            }
            .navigationTitle("SingleCast")
            .onAppear { controller.refreshNetwork() }
        }
    }

    /// 网段判断：车机热点通常是 192.168.1.x / 192.168.169.x。
    private var networkHint: String {
        guard let ip = controller.localIP else {
            return "没读到 IP —— 先按第 2 步连上车机热点"
        }
        if ip.hasPrefix("192.168.1.") || ip.hasPrefix("192.168.169.") {
            return "网段像车机热点 ✅ 可以直接探测"
        }
        return "当前是 \(ip)，不像车机热点（车机一般是 192.168.1.x 或 192.168.169.x）"
    }
}

struct StepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

@main
struct SingleCastApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

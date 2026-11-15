import SwiftUI
import UIKit
import CoreVideo

/// 控制层：两种模式
/// - 测试图：验证"仪表侧输出"（协议 / 编码 / socket）
/// - CarPlay：虚拟配件 → iAP2 认证 → RTSP → 解码 → 重编码 → 仪表
final class CastController: ObservableObject {
    @Published var statusText = "待机"
    @Published var frames = 0
    @Published var packets = 0
    @Published var logs: [String] = []
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
    }

    private func log(_ text: String) {
        DispatchQueue.main.async {
            self.logs.append(text)
            if self.logs.count > 200 { self.logs.removeFirst(self.logs.count - 200) }
        }
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
        } catch {
            statusText = "CarPlay 启动失败：\(error)"
            log("启动失败：\(error)")
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

struct ContentView: View {
    @StateObject private var controller = CastController()
    @State private var host = "192.168.1.1"

    var body: some View {
        NavigationStack {
            Form {
                Section("仪表") {
                    TextField("仪表 IP", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                    Button("推送测试图") { controller.startTestPattern(host: host) }
                    Button("启动 CarPlay 接收") { controller.startCarPlay(host: host) }
                    Button("停止", role: .destructive) { controller.stop() }
                }
                Section("身份（M2）") {
                    Text(controller.identityStatus).font(.footnote)
                }
                Section("状态") {
                    Text(controller.statusText)
                    Text("帧 \(controller.frames) ／ 包 \(controller.packets)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("日志") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 180)
                }
                Section("说明") {
                    Text("测试图能点亮仪表，说明协议对了；CarPlay 模式依赖私有 CoreAccessories，日志会告诉你卡在哪一步。")
                        .font(.footnote)
                }
            }
            .navigationTitle("SingleCast")
        }
    }
}

@main
struct SingleCastApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

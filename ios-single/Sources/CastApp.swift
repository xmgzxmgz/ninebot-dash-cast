import SwiftUI
import UIKit
import CoreVideo

/// 单机方案的控制层：测试图 → VideoToolbox → 仪表协议 → UDP。
///
/// 当前阶段（M1）只跑测试图，用来在真机上验证"仪表侧输出"这一段；
/// CarPlay 接收（M2/M3）见 CarPlayReceiver.swift 的占位说明。
final class CastController: ObservableObject {
    @Published var statusText = "待机"
    @Published var frames = 0
    @Published var packets = 0
    @Published var pongCount = 0

    private var encoder: FrameEncoder?
    private var video: UDPSender?
    private var control: UDPSender?
    private var packetizer = NinebotPacketizer()
    private var timer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatCounter: UInt32 = 0
    private var frameIndex: Int64 = 0

    private let width = 848
    private let height = 480
    private let fps = 20

    func start(host: String) {
        stop()
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { statusText = "仪表 IP 为空"; return }

        guard let video = UDPSender(host: target, port: 5012, bindLocalPort: 5012) else {
            statusText = "视频 socket 创建失败"; return
        }
        guard let control = UDPSender(host: target, port: 5013, bindLocalPort: 5013) else {
            statusText = "控制 socket 创建失败"; return
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
        guard encoder.start() else { statusText = "编码器初始化失败"; return }
        self.encoder = encoder

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "singlecast.frames"))
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        timer.setEventHandler { [weak self] in self?.produceFrame() }
        timer.resume()
        self.timer = timer

        let beat = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "singlecast.heartbeat"))
        beat.schedule(deadline: .now() + 0.3, repeating: 1.0)
        beat.setEventHandler { [weak self] in
            guard let self, let control = self.control else { return }
            self.heartbeatCounter &+= 1
            control.send(NinebotHeartbeat.packet(counter: self.heartbeatCounter))
        }
        beat.resume()
        heartbeatTimer = beat

        frames = 0
        packets = 0
        frameIndex = 0
        statusText = "发送中 → \(target):5012"
    }

    func stop() {
        timer?.cancel(); timer = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        encoder?.stop(); encoder = nil
        video = nil
        control = nil
        if statusText.hasPrefix("发送中") { statusText = "已停止" }
    }

    private func produceFrame() {
        frameIndex &+= 1
        guard let buffer = TestPattern.make(index: frameIndex, width: width, height: height) else { return }
        encoder?.encode(buffer, frameIndex: frameIndex)
    }
}

/// 测试图：彩条 + 移动方块 + 帧号，用来确认链路，不引入其它变量。
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
        let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context else { return nil }

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

        let text = "FRAME \(String(format: "%06lld", index))  \(width)x\(height)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        UIGraphicsPushContext(context)
        text.draw(at: CGPoint(x: 16, y: CGFloat(height) / 3 + 16), withAttributes: attributes)
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
                    Button("开始推送测试图") { controller.start(host: host) }
                    Button("停止", role: .destructive) { controller.stop() }
                }
                Section("状态") {
                    Text(controller.statusText)
                    Text("帧 \(controller.frames) ／ 包 \(controller.packets)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("说明") {
                    Text("先让仪表进入投屏接收态，手机 Wi-Fi 连上仪表热点，再点开始。")
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

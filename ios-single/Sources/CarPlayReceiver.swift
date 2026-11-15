import Foundation
import CoreVideo

/// CarPlay 接收层：虚拟配件 → iAP2 认证 → RTSP 协商 → 解码 → 出帧。
///
/// 这一段把 CarWithin 的分层（见 docs/CARWITHIN-RE.md）用可验证的方式重写：
/// 链路层、签名、SRP、TLV8 都有测试；真正的未知是"自签 App 能否创建虚拟配件"
/// 与"控制会话的消息 ID"，所以每一步都打日志，真机跑一次就知道卡在哪。
protocol CarPlayReceiving: AnyObject {
    var onVideoFrame: ((CVPixelBuffer) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    var isConnected: Bool { get }
    func start() throws
    func stop()
}

final class CarPlayReceiver: CarPlayReceiving {
    enum ReceiverError: Error, LocalizedError {
        case transportUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .transportUnavailable(let why):
                return "transportUnavailable（私有 CoreAccessories 不可用：\(why)）"
            }
        }

        /// 日志里直接说人话，别让人对着一个枚举名猜
        var hint: String {
            switch self {
            case .transportUnavailable:
                return "CarPlay 这条路要私有框架，自签包大概率拿不到。先用「测试图」验证手机→仪表通不通，别在这卡着。"
            }
        }
    }

    var onVideoFrame: ((CVPixelBuffer) -> Void)?
    var onLog: ((String) -> Void)?
    private(set) var isConnected = false

    private var transport: AccessoryTransport?
    private var session: IAP2Session?
    private var rtsp: RTSPClient?
    private var decoder: H264Decoder?
    private var scaler: FrameScaler?
    private let identity: MFiIdentity

    init(identity: MFiIdentity) {
        self.identity = identity
    }

    func start() throws {
        guard let transport = AccessoryTransport() else {
            throw ReceiverError.transportUnavailable(AccessoryTransport.loadDiagnosis)
        }
        self.transport = transport

        let probe = transport.probe()
        onLog?("ACCTransportClient classFound=\(probe.classFound) 方法 \(probe.methodNames.count) 个 "
               + "canCreateEndpoint=\(probe.canCreateEndpoint)")
        for note in probe.notes { onLog?(note) }
        if !probe.methodNames.isEmpty {
            onLog?("方法：" + probe.methodNames.prefix(20).joined(separator: ", "))
        }

        do {
            try transport.open(identifier: "IPA_24ACBB48646F8077F7463523085B60D2",
                               protocolName: "com.apple.carplay")
        } catch {
            onLog?("虚拟配件创建失败：\(error)")
            throw error
        }

        let decoder = H264Decoder()
        decoder.onLog = { [weak self] in self?.onLog?($0) }
        decoder.onFrame = { [weak self] buffer in
            guard let self, let scaled = self.scaler?.scale(buffer) else { return }
            self.onVideoFrame?(scaled)
        }
        self.decoder = decoder
        scaler = FrameScaler(width: 848, height: 480)

        let session = IAP2Session(identity: identity)
        session.onLog = { [weak self] in self?.onLog?($0) }
        session.bind { [weak self] data in
            self?.transport?.send(data)
        }
        session.onStartCarPlay = { [weak self] port in
            self?.onLog?("iAP2 要求启动 CarPlay，端口 \(port)")
            self?.startRTSP(port: port)
        }
        self.session = session

        transport.onLog = { [weak self] in self?.onLog?($0) }
        transport.onData = { [weak self] data in
            self?.session?.receive(data)
        }

        session.start()
        isConnected = true
        onLog?("已发起虚拟配件会话，等待手机连入")
    }

    private func startRTSP(port: UInt16) {
        let client = RTSPClient(host: "127.0.0.1", port: port)
        client.onLog = { [weak self] in self?.onLog?($0) }
        client.onData = { [weak self] packet in
            guard packet.count > 12 else { return }
            self?.decoder?.feed(packet.subdata(in: 12..<packet.count))
        }
        client.onStateChange = { ready in
            guard ready else { return }
            client.send(request: "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n")
            client.send(request: "SETUP * RTSP/1.0\r\nCSeq: 2\r\n"
                        + "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n")
            client.send(request: "PLAY * RTSP/1.0\r\nCSeq: 3\r\n\r\n")
        }
        client.start()
        rtsp = client
    }

    func stop() {
        rtsp?.stop()
        rtsp = nil
        session = nil
        transport = nil
        decoder = nil
        isConnected = false
    }
}

/// iAP2 会话：链路层握手 + 控制消息。消息 ID 见 IAP2ID 注释。
final class IAP2Session {
    var onLog: ((String) -> Void)?
    var onStartCarPlay: ((UInt16) -> Void)?

    private let identity: MFiIdentity
    private var sequence: UInt8 = 0
    private var buffer = Data()
    private var sendHandler: ((Data) -> Void)?

    init(identity: MFiIdentity) {
        self.identity = identity
    }

    func bind(send: @escaping (Data) -> Void) {
        sendHandler = send
    }

    func start() {
        sequence = 0
        transmit(control: IAP2Link.flagSYN, payload: Data([IAP2Link.version]))
        onLog?("iAP2 SYN 已发送")
    }

    func receive(_ data: Data) {
        buffer.append(data)
        let (frames, rest) = IAP2Link.parse(buffer)
        buffer = rest
        for frame in frames {
            if frame.isSYN && !frame.isACK {
                transmit(control: IAP2Link.flagSYN | IAP2Link.flagACK,
                         sequence: frame.sequence &+ 1, ack: frame.sequence,
                         payload: Data([IAP2Link.version]))
                onLog?("iAP2 收到 SYN，回 SYN+ACK")
                continue
            }
            if frame.payload.count >= 2 { handle(payload: frame.payload) }
        }
    }

    private func handle(payload: Data) {
        guard let message = IAP2Message.decode(payload) else { return }
        onLog?("iAP2 消息 0x\(String(message.identifier, radix: 16)) 参数 \(message.parameters.count) 个")
        switch message.identifier {
        case IAP2ID.identify:
            var reply = IAP2Message(identifier: IAP2ID.deviceInformation, parameters: [])
            reply.parameters.append((IAP2ID.paramName, Data("SingleCast".utf8)))
            transmit(payload: reply.encoded())
        case IAP2ID.authentication:
            guard let challenge = message.parameters.first(where: { $0.id == IAP2ID.paramChallenge })?.value,
                  let signature = try? identity.sign(challenge: challenge) else {
                onLog?("认证：没有挑战或签名失败")
                return
            }
            var reply = IAP2Message(identifier: IAP2ID.authenticationSucceeded, parameters: [])
            reply.parameters.append((IAP2ID.paramCertificate, identity.certificateDER))
            reply.parameters.append((IAP2ID.paramSignature, signature))
            transmit(payload: reply.encoded())
            onLog?("认证：已回证书 + 签名（挑战 \(challenge.count) 字节）")
        default:
            if let portData = message.parameters.first(where: { $0.id == IAP2ID.paramPort })?.value,
               portData.count == 2 {
                let port = UInt16(portData[portData.startIndex]) << 8
                    | UInt16(portData[portData.startIndex + 1])
                onStartCarPlay?(port)
            }
        }
    }

    private func transmit(control: UInt8 = 0, sequence seq: UInt8? = nil,
                          ack: UInt8 = 0xFF, payload: Data = Data()) {
        let next = seq ?? (sequence &+ 1)
        sequence = next
        sendHandler?(IAP2Link.packet(control: control, sequence: next, ack: ack,
                                     sessionID: 0, payload: payload))
    }
}

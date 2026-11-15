import Foundation
import Network

/// 极简 RTSP 客户端：只做 CarPlay 协商要用的那几步（OPTIONS / SETUP / PLAY）。
///
/// CarPlay 的三条通道（control / video / event）都在这条 TCP 上协商，
/// SETUP 的 `Transport` 头会回 `server_port=xxxx`，之后视频数据在另一条连接上过来。
final class RTSPClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "singlecast.rtsp")
    private var buffer = Data()

    var onResponse: ((Int, [String: String]) -> Void)?
    var onData: ((Data) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    /// SETUP 回包里拿到的服务端端口
    private(set) var serverPorts: [String: UInt16] = [:]

    init(host: String, port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? 7000,
                                  using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?(true)
                self?.onLog?("RTSP 已连接")
            case .failed(let error):
                self?.onLog?("RTSP 连接失败：\(error)")
                self?.onStateChange?(false)
            case .cancelled:
                self?.onStateChange?(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func stop() {
        connection.cancel()
    }

    func send(request: String) {
        onLog?("RTSP → \(request.split(separator: "\r\n").first ?? "")")
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.onLog?("RTSP 发送失败：\(error)") }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if let error {
                self.onLog?("RTSP 接收失败：\(error)")
                return
            }
            if !isComplete { self.receive() }
        }
    }

    private func drain() {
        // RTSP 响应以双 CRLF 结束；$ 开头的是 RTP 交织数据，直接交给上层
        while !buffer.isEmpty {
            if buffer.first == 0x24 { // '$'
                guard buffer.count >= 4 else { return }
                let length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
                guard buffer.count >= 4 + length else { return }
                let packet = buffer.prefix(4 + length)
                buffer = buffer.dropFirst(4 + length)
                onData?(Data(packet))
                continue
            }
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = buffer[buffer.startIndex..<range.lowerBound]
            let text = String(data: Data(headerData), encoding: .utf8) ?? ""
            buffer = buffer.dropFirst(buffer.distance(from: buffer.startIndex, to: range.upperBound))
            handle(response: text)
        }
    }

    private func handle(response text: String) {
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return }
        let code = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if let transport = headers["transport"], let range = transport.range(of: "server_port=") {
            let digits = transport[range.upperBound...].prefix { $0.isNumber }
            if let port = UInt16(digits) {
                serverPorts[headers["cseq"] ?? UUID().uuidString] = port
                onLog?("RTSP 协商到 server_port=\(port)")
            }
        }
        onLog?("RTSP ← \(statusLine)")
        onResponse?(code, headers)
    }
}

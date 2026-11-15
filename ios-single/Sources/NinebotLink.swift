import Foundation
import Darwin

/// 仪表侧链路：20 字节私有头 + 1380 分片 + 5013 心跳。
///
/// 与仓库里 Python 实现（tools/protocol.py）逐字节一致，字段含义见 docs/PROTOCOL.md。
struct NinebotPacketizer {
    var chunk = 1380
    private var sequence: UInt16 = 0

    mutating func packets(for frame: Data, timestampMs: UInt32, keyframe: Bool) -> [Data] {
        guard !frame.isEmpty else { return [] }
        var out: [Data] = []
        var offset = 0
        let total = frame.count
        while offset < total {
            let length = min(chunk, total - offset)
            let isFirst = offset == 0
            let isLast = offset + length >= total

            var header = [UInt8](repeating: 0, count: 20)
            header[0] = 0x90                       // V=2, X=1
            header[1] = UInt8(32 | (isLast ? 0x80 : 0))
            header[2] = UInt8((sequence >> 8) & 0xFF)
            header[3] = UInt8(sequence & 0xFF)
            header[4] = UInt8((timestampMs >> 24) & 0xFF)
            header[5] = UInt8((timestampMs >> 16) & 0xFF)
            header[6] = UInt8((timestampMs >> 8) & 0xFF)
            header[7] = UInt8(timestampMs & 0xFF)
            header[15] = 1
            var flags: UInt8 = keyframe ? 0x01 : 0x02
            if isFirst { flags |= 0x10 }
            if isLast { flags |= 0x08 }
            header[17] = flags
            let tag = UInt16(timestampMs & 0x3FF)
            header[18] = UInt8(tag & 0xFF)          // LE16
            header[19] = UInt8((tag >> 8) & 0xFF)

            var packet = Data(header)
            packet.append(frame[frame.startIndex + offset ..< frame.startIndex + offset + length])
            out.append(packet)

            sequence &+= 1
            offset += length
        }
        return out
    }
}

/// 20 字节心跳（85 CC 00 04 … counter LE32 … 02），与逆向结果一致。
enum NinebotHeartbeat {
    static func packet(counter: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x85
        bytes[1] = 0xCC
        bytes[3] = 4
        // 计数器写在 [12..15]（小端），byte16 = 2 —— 见 docs/PROTOCOL.md 4.1
        bytes[12] = UInt8(counter & 0xFF)
        bytes[13] = UInt8((counter >> 8) & 0xFF)
        bytes[14] = UInt8((counter >> 16) & 0xFF)
        bytes[15] = UInt8((counter >> 24) & 0xFF)
        bytes[16] = 2
        return Data(bytes)
    }
}

/// BSD socket 的 UDP 发送端（视频 5012 / 控制 5013）。
final class UDPSender {
    private let fd: Int32
    private let target: sockaddr_in
    private let lock = NSLock()
    private var sent = 0

    init?(host: String, port: UInt16, bindLocalPort: UInt16 = 0) {
        // 全部用局部变量操作，最后再赋给存储属性：
        // 在 init 里让闭包捕获 self 会触发 "captured before all members were initialized"
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }

        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        if bindLocalPort != 0 {
            var local = sockaddr_in()
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = bindLocalPort.bigEndian
            local.sin_addr.s_addr = INADDR_ANY
            _ = withUnsafePointer(to: &local) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else {
            close(sock)
            return nil
        }

        fd = sock
        target = remote
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var addr = target
        let result = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, base, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if result > 0 { sent += 1 }
        return result > 0
    }

    var sentPackets: Int { lock.lock(); defer { lock.unlock() }; return sent }

    deinit { close(fd) }
}

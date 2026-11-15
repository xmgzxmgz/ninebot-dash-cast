import Foundation

/// 与 ninebot_pro iOS 1.0.0 逆向出的仪表协议逐字节一致的 RTP 打包器
/// （本文档已按 docs/PROTOCOL.md 修正，原实现有三处偏差，见 CHANGES 注释）。
///
/// 视频 RTP 包结构（共 20 字节头）：
/// - [0]      0x90（V=2, X=1 扩展头）
/// - [1]      (marker?0x80:0) | 32（payload type 固定 32）
/// - [2..3]   序列号 BE16（全局逐包递增）
/// - [4..7]   时间戳 BE32（单位：毫秒）
/// - [8..14]  0
/// - [15]     1
/// - [16]     0（视频包；心跳包此处为 2）
/// - [17]     标志：0x10 首片 0x08 末片 0x01 关键帧 0x02 非关键帧
/// - [18..19] LE16(时间戳低 10 位)（帧级标识，注意是**小端**）
/// - 负载：Annex-B 原始字节流按 1380 字节切块（不按 NALU 对齐），20+1380=1400
struct RTPPacker {
    /// 分片大小：逆向确认 H.264 载荷 1380（20 字节头 + 1380 = 1400 整包）。
    /// 原实现默认 1400 会让整包变成 1420，部分仪表会直接丢包。
    var chunkSize: Int = 1380
    private(set) var sequence: UInt16 = 0

    init(chunkSize: Int = 1380) {
        self.chunkSize = chunkSize
    }

    mutating func packetizeFrame(_ frame: Data, timestampMs: UInt32, isKeyframe: Bool) -> [Data] {
        let bytes = [UInt8](frame)
        guard !bytes.isEmpty else { return [] }
        var packets: [Data] = []
        var offset = 0
        while offset < bytes.count {
            let chunkLen = min(chunkSize, bytes.count - offset)
            let isFirst = offset == 0
            let isLast = offset + chunkLen >= bytes.count
            sequence &+= 1

            var packet = Data(repeating: 0, count: 20 + chunkLen)
            packet[0] = 0x90
            packet[1] = (isLast ? 0x80 : 0x00) | 32
            packet[2] = UInt8(sequence >> 8)
            packet[3] = UInt8(sequence & 0xFF)
            packet[4] = UInt8((timestampMs >> 24) & 0xFF)
            packet[5] = UInt8((timestampMs >> 16) & 0xFF)
            packet[6] = UInt8((timestampMs >> 8) & 0xFF)
            packet[7] = UInt8(timestampMs & 0xFF)
            // [8..14] 保持 0，[15] = 1，[16] = 0
            packet[15] = 1
            // CHANGES: 非关键帧原来只写 0x10/0x08，官方实现是非关键帧恒带 0x02
            packet[17] = (isFirst ? 0x10 : 0x00)
                | (isKeyframe ? 0x01 : 0x02)
                | (isLast ? 0x08 : 0x00)
            // CHANGES: 原来是 BE16(1024 + ts&1023)，逆向确认是 LE16(ts & 0x3FF)
            let frameTag = UInt16(timestampMs & 0x3FF)
            packet[18] = UInt8(frameTag & 0xFF)
            packet[19] = UInt8(frameTag >> 8)
            packet.replaceSubrange(20..<20 + chunkLen, with: bytes[offset..<offset + chunkLen])
            packets.append(packet)
            offset += chunkSize
        }
        return packets
    }
}

/// 5013 上的 RTCP 风格控制包
enum RTCP {
    /// 5013 心跳（20 字节）：85 CC 00 04 + 8 字节 0 + 计数器 LE32 + 02 00 00 00
    ///
    /// 逆向自 ninebot_pro iOS 1.0.0 的 `H264Packetizer.heartbeat(counter:)`：
    /// 常量 `85 CC 00 04 00 00 00 00` 在 __const 里，byte16 = 2，
    /// 计数器以小端写在 [12..15]。
    static func heartbeat(counter: UInt32) -> Data {
        var d = Data(repeating: 0, count: 20)
        d[0] = 0x85          // V=2 | subtype=5
        d[1] = 0xCC          // PT=204 (APP)
        d[3] = 4             // length = 4 words → 20 字节
        d[12] = UInt8(counter & 0xFF)
        d[13] = UInt8((counter >> 8) & 0xFF)
        d[14] = UInt8((counter >> 16) & 0xFF)
        d[15] = UInt8((counter >> 24) & 0xFF)
        d[16] = 2
        return d
    }

    /// 九号出行官方 App 的 [0,2] 变体（app data 两个 int32 大端），保留做对照实验。
    /// 与上面的 heartbeat 互不影响，仪表对两者都不报错。
    static func appVariant() -> Data {
        var d = Data(repeating: 0, count: 20)
        d[0] = 0x85
        d[1] = 0xCC
        d[3] = 4
        d[19] = 2
        return d
    }

    /// 校验 pong 并取出计数器。
    ///
    /// CHANGES: 原实现要求「长度必须等于 20」，七寸仪表回的是 24 字节，
    /// 于是永远匹配不上、界面一直显示"尚无回应"。现在 20/24 都接受，
    /// 计数器在 [12..15] 取不到时再试 [20..23]。
    static func parsePong(_ data: Data) -> (counter: UInt32?, length: Int)? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0x85, b[1] == 0xCC, b[2] == 0, b[3] == 4 else {
            return nil
        }
        var counter: UInt32?
        if b.count >= 16 {
            let value = UInt32(b[12]) | (UInt32(b[13]) << 8) | (UInt32(b[14]) << 16) | (UInt32(b[15]) << 24)
            if value != 0 { counter = value }
        }
        if counter == nil, b.count >= 24 {
            let value = UInt32(b[20]) | (UInt32(b[21]) << 8) | (UInt32(b[22]) << 16) | (UInt32(b[23]) << 24)
            if value != 0 { counter = value }
        }
        return (counter, b.count)
    }

    /// 仪表主动发来的 RTCP APP 报告（逆向自 NinebotEnhance 文档）：
    /// 子类型 1 = 丢包报告；2 = 请求帧率；3 = 请求码率（数值为小端 32 位，位于 [12..15]）
    struct AppReport {
        let subtype: Int
        let value: UInt32?
    }

    static func parseApp(_ data: Data) -> AppReport? {
        let b = [UInt8](data)
        guard b.count >= 8, (b[0] >> 6) == 2, b[1] == 0xCC else { return nil }
        let subtype = Int(b[0] & 0x1F)
        guard subtype == 1 || subtype == 2 || subtype == 3 else { return nil }
        var value: UInt32?
        if b.count >= 16 {
            value = UInt32(b[12]) | (UInt32(b[13]) << 8) | (UInt32(b[14]) << 16) | (UInt32(b[15]) << 24)
        }
        return AppReport(subtype: subtype, value: value)
    }
}

/// 本机 Wi-Fi IPv4（用于把本地端口绑到 5012/5013，与官方实现一致）
enum LocalAddress {
    static func primaryIPv4(preferInterfaces: Set<String> = ["en0"]) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var preferred: String?
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if preferInterfaces.contains(name) && preferred == nil {
                preferred = ip
            } else if fallback == nil && name.hasPrefix("en") {
                fallback = ip
            }
        }
        return preferred ?? fallback
    }
}

import Foundation

/// iAP2 链路层与控制会话的编解码。
///
/// 链路层是公开研究得比较透的部分（起始符 `0xFF 0x5A` + 长度 + 控制字节 + 序号
/// + 会话号 + 载荷 + 校验），这一层我们按逆向结论实现。**控制会话里的消息 ID
/// 与参数 ID 各家固件不完全一致**，所以这里把它们集中成常量并在日志里打印收到的
/// 每条消息，方便真机抓一轮再校准——不猜着写死。
struct IAP2Link {
    static let startMarker: [UInt8] = [0xFF, 0x5A]
    static let version: UInt8 = 1

    /// 控制字节位定义
    static let flagSYN: UInt8 = 0x80
    static let flagACK: UInt8 = 0x40
    static let flagEAK: UInt8 = 0x20
    static let flagRST: UInt8 = 0x10

    static func packet(control: UInt8, sequence: UInt8, ack: UInt8,
                       sessionID: UInt8, payload: Data = Data()) -> Data {
        var body = Data()
        body.append(control | (sessionID & 0x0F))
        body.append(sequence)
        body.append(ack)
        body.append(payload)

        var frame = Data(startMarker)
        var length = UInt16(body.count + 2)   // 载荷 + 校验
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(body)
        frame.append(checksum(body))
        return frame
    }

    /// iAP2 校验：对控制字节到载荷逐字节求和，取反加一（16 位补码）
    static func checksum(_ body: Data) -> Data {
        var sum: UInt16 = 0
        for byte in body { sum = sum &+ UInt16(byte) }
        let value = (~sum &+ 1)
        return Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    struct Frame {
        let control: UInt8
        let sequence: UInt8
        let ack: UInt8
        let sessionID: UInt8
        let payload: Data
        var isSYN: Bool { control & IAP2Link.flagSYN != 0 }
        var isACK: Bool { control & IAP2Link.flagACK != 0 }
    }

    /// 从字节流里切帧；返回 (帧列表, 剩余未消费字节)
    static func parse(_ buffer: Data) -> (frames: [Frame], rest: Data) {
        var frames: [Frame] = []
        var data = buffer
        while data.count >= 6 {
            guard let start = data.firstIndex(of: 0xFF) else {
                return (frames, Data())
            }
            if start > data.startIndex {
                data = data.suffix(from: start)
            }
            guard data.count >= 3, data[data.startIndex + 1] == 0x5A else {
                data = data.dropFirst()
                continue
            }
            let length = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
            let total = 4 + length
            guard data.count >= total else { break }
            let bodyStart = data.startIndex + 4
            let bodyEnd = bodyStart + length - 2
            guard bodyEnd <= data.endIndex, bodyEnd >= bodyStart + 3 else {
                data = data.dropFirst(total)
                continue
            }
            let body = data[bodyStart..<bodyEnd]
            let control = data[bodyStart]
            let sequence = data[bodyStart + 1]
            let ack = data[bodyStart + 2]
            let payload = Data(body.dropFirst(3))
            frames.append(Frame(control: control, sequence: sequence, ack: ack,
                                sessionID: control & 0x0F, payload: payload))
            data = data.dropFirst(total)
        }
        return (frames, Data(data))
    }
}

/// iAP2 控制会话消息（msgID + 参数表）
struct IAP2Message {
    let identifier: UInt16
    var parameters: [(id: UInt16, value: Data)]

    func encoded() -> Data {
        var data = Data([UInt8((identifier >> 8) & 0xFF), UInt8(identifier & 0xFF)])
        for parameter in parameters {
            data.append(UInt8((parameter.id >> 8) & 0xFF))
            data.append(UInt8(parameter.id & 0xFF))
            data.append(UInt8((parameter.value.count >> 8) & 0xFF))
            data.append(UInt8(parameter.value.count & 0xFF))
            data.append(parameter.value)
        }
        return data
    }

    static func decode(_ data: Data) -> IAP2Message? {
        guard data.count >= 2 else { return nil }
        let identifier = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
        var parameters: [(UInt16, Data)] = []
        var index = data.startIndex + 2
        while index + 4 <= data.endIndex {
            let pid = UInt16(data[index]) << 8 | UInt16(data[index + 1])
            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            let valueStart = index + 4
            guard valueStart + length <= data.endIndex else { break }
            parameters.append((pid, Data(data[valueStart..<valueStart + length])))
            index = valueStart + length
        }
        return IAP2Message(identifier: identifier, parameters: parameters)
    }
}

/// 消息与参数 ID 常量。
///
/// ⚠️ 这些 ID 来自公开研究（wiomoc/iap2、Carplayed、WirelessCarPlay 文档），
/// 不同 iOS 版本会增减。真机收到陌生 ID 时会被原样打进日志，据此再补。
enum IAP2ID {
    static let startIDPS: UInt16 = 0x1D00
    static let identify: UInt16 = 0x1D01
    static let authentication: UInt16 = 0x1D02
    static let authenticationSucceeded: UInt16 = 0x1D03
    static let authenticationFailed: UInt16 = 0x1D04
    static let startCarPlay: UInt16 = 0x1D05
    static let carPlayAvailability: UInt16 = 0x1D06
    static let deviceInformation: UInt16 = 0x1D07

    static let paramName: UInt16 = 0x0000
    static let paramCertificate: UInt16 = 0x0001
    static let paramChallenge: UInt16 = 0x0002
    static let paramSignature: UInt16 = 0x0003
    static let paramStatus: UInt16 = 0x0004
    static let paramPort: UInt16 = 0x0005
}

import Foundation

/// TLV8 编解码：AirPlay/HAP 家族的控制消息格式。
///
/// 每个元素 = 1 字节类型 + 1 字节长度 + 值；值超过 255 字节时按 255 切分，
/// 后续分片沿用同一类型号，接收端按顺序拼回去。
enum TLV8 {
    struct Item {
        let type: UInt8
        let value: Data
    }

    enum Kind: UInt8 {
        case method = 0
        case identifier = 1
        case salt = 2
        case publicKey = 3
        case proof = 4
        case encryptedData = 5
        case state = 6
        case error = 7
        case signature = 10
        case flags = 19
    }

    static func encode(_ items: [Item]) -> Data {
        var out = Data()
        for item in items {
            var value = item.value
            repeat {
                let chunk = value.prefix(255)
                out.append(item.type)
                out.append(UInt8(chunk.count))
                out.append(contentsOf: chunk)
                value = value.dropFirst(chunk.count)
            } while !value.isEmpty
        }
        return out
    }

    static func encode(_ pairs: [(Kind, Data)]) -> Data {
        encode(pairs.map { Item(type: $0.0.rawValue, value: $0.1) })
    }

    static func decode(_ data: Data) -> [Item] {
        var items: [Item] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard data.distance(from: index, to: data.endIndex) >= 2 else { break }
            let type = data[index]
            let length = Int(data[data.index(after: index)])
            let valueStart = data.index(index, offsetBy: 2)
            guard data.distance(from: valueStart, to: data.endIndex) >= length else { break }
            let value = data[valueStart..<data.index(valueStart, offsetBy: length)]

            if let last = items.last, last.type == type, length == 255 {
                items[items.count - 1] = Item(type: type, value: last.value + value)
            } else {
                items.append(Item(type: type, value: Data(value)))
            }
            index = data.index(valueStart, offsetBy: length)
        }
        return items
    }

    static func value(of kind: Kind, in items: [Item]) -> Data? {
        items.first { $0.type == kind.rawValue }?.value
    }

    static func byte(_ kind: Kind, in items: [Item]) -> UInt8? {
        guard let data = value(of: kind, in: items), let first = data.first else { return nil }
        return first
    }
}

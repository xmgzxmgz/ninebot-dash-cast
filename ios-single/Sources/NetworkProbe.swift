import Foundation
import Darwin

/// 一条探测结果：谁回了 pong。
struct ProbeHit: Identifiable, Hashable {
    let host: String
    let rttMs: Int
    let bytes: Int
    var id: String { host }
}

/// 本机网络信息 + 车机地址探测。
///
/// 全部走 BSD socket，不依赖任何系统权限（`NSLocalNetworkUsageDescription` 已在 Info.plist）。
/// 探测原理与正式心跳完全一致：往 5013 发 20 字节心跳，谁回 `85 CC …` 谁就是车机。
enum NetworkProbe {

    // MARK: - 本机地址

    /// 本机 IPv4，优先 en0（Wi-Fi）。
    static func localIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var found: [(name: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let ifa = pointer.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var storage = addr.pointee
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let ok = withUnsafePointer(to: &storage) { raw -> Bool in
                    raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                        getnameinfo(socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size),
                                    &text, socklen_t(INET_ADDRSTRLEN),
                                    nil, 0, NI_NUMERICHOST) == 0
                    }
                }
                if ok {
                    let ip = String(cString: text)
                    if !ip.hasPrefix("127.") { found.append((name, ip)) }
                }
            }
            cursor = ifa.ifa_next
        }
        if let wifi = found.first(where: { $0.name == "en0" }) { return wifi.ip }
        return found.first?.ip
    }

    /// 候选网关：本机网段的 .1，加上已知的两种车机网关。
    static func candidates(local: String?) -> [String] {
        var list: [String] = []
        if let local = local, let dot = local.lastIndex(of: ".") {
            list.append(String(local[local.startIndex...dot]) + "1")
        }
        for host in ["192.168.1.1", "192.168.169.1", "192.168.0.1"] where !list.contains(host) {
            list.append(host)
        }
        return list
    }

    // MARK: - 探测

    /// 并发发心跳并等回包。`log` 会在后台线程被调用，调用方自己切主线程。
    static func scan(timeout: TimeInterval = 2.5,
                     log: @escaping (String) -> Void,
                     completion: @escaping ([ProbeHit], String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let local = localIPv4()
            let targets = candidates(local: local)
            log("本机 IP：\(local ?? "未知")")
            log("尝试地址：\(targets.joined(separator: "、"))")

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else {
                completion([], local)
                log("socket 创建失败")
                return
            }
            defer { close(fd) }

            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            // 优先用 5013：和正式心跳同源端口，部分固件只回这个端口
            if bindLocal(fd, port: 5013) != 0 {
                _ = bindLocal(fd, port: 0)
            }

            var sentAt: [String: Int] = [:]
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            for (index, host) in targets.enumerated() {
                sentAt[host] = stamp
                let beat = NinebotHeartbeat.packet(counter: UInt32(index + 1))
                if !sendOnce(beat, fd: fd, host: host, port: 5013) {
                    log("\(host) 发送失败（地址非法？）")
                }
            }

            var hits: [ProbeHit] = []
            var buffer = [UInt8](repeating: 0, count: 2048)
            let deadline = Date().addingTimeInterval(timeout)

            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(remaining * 1000))
                if ready <= 0 { continue }

                var address = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                        recvfrom(fd, &buffer, buffer.count, 0, socketPointer, &length)
                    }
                }
                if count <= 0 { continue }

                let host = dotted(address)
                let rtt = sentAt[host].map { Int(Date().timeIntervalSince1970 * 1000) - $0 } ?? -1
                if count >= 8, buffer[0] == 0x85, buffer[1] == 0xCC {
                    hits.removeAll { $0.host == host }
                    hits.append(ProbeHit(host: host, rttMs: rtt, bytes: count))
                    log("✅ \(host) 回 pong：\(count) 字节，往返 \(rtt) ms")
                } else {
                    log("\(host) 回了 \(count) 字节但不是 pong：\(hexPrefix(buffer, count))")
                }
            }

            hits.sort { $0.rttMs < $1.rttMs }
            if hits.isEmpty {
                log("没有收到 pong：车机可能没进接收态、IP 不在候选里，或不在同一网段")
            }
            completion(hits, local)
        }
    }

    // MARK: - socket 小工具

    private static func bindLocal(_ fd: Int32, port: UInt16) -> Int32 {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func sendOnce(_ data: Data, fd: Int32, host: String, port: UInt16) -> Bool {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let result = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, base, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result > 0
    }

    private static func dotted(_ address: sockaddr_in) -> String {
        var copy = address.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &copy, &text, socklen_t(INET_ADDRSTRLEN))
        return String(cString: text)
    }

    private static func hexPrefix(_ bytes: [UInt8], _ count: Int) -> String {
        bytes.prefix(min(count, 8)).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

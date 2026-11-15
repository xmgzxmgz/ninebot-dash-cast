import Foundation
import ObjectiveC

/// 私有 CoreAccessories 的运行时桥。
///
/// 这套接口没有任何公开头文件，CarWithin 的做法是：用 `ACCTransportClient` 创建一个
/// "虚拟配件端点"，把 dataOut 回调接上，然后 publish 出去，让 iOS 主动连过来。
/// 从它的二进制里能读到的选择器是：
///
///     createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:
///         forConnectionWithUUID:publishConnection:
///
/// 我们不静态链接这个框架（也链不到），全部走 ObjC 运行时；`probe()` 会把
/// "类在不在、有哪些方法"打印到日志里——**这是这条路线能不能走通的第一手证据**。
final class AccessoryTransport {
    enum TransportError: Error {
        case classMissing(String)
        case selectorMissing(String)
        case creationFailed
        case notConnected
    }

    struct Probe {
        var classFound = false
        var methodNames: [String] = []
        var canCreateEndpoint = false
        var notes: [String] = []
    }

    private let client: NSObject?
    private let clientClass: AnyClass?
    private var endpoint: NSObject?

    var onData: ((Data) -> Void)?
    var onLog: ((String) -> Void)?

    init?() {
        guard let cls = NSClassFromString("ACCTransportClient") else { return nil }
        clientClass = cls
        // 单例一般叫 sharedClient / sharedInstance，两种都试
        if let shared = (cls as AnyObject).perform(NSSelectorFromString("sharedClient"))?.takeUnretainedValue() as? NSObject {
            client = shared
        } else if let shared = (cls as AnyObject).perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject {
            client = shared
        } else if let allocated = (cls as? NSObject.Type)?.init() {
            client = allocated
        } else {
            return nil
        }
    }

    /// 探测：把能看到的类/方法都列出来。真机上跑一次就知道 API 长什么样。
    func probe() -> Probe {
        var result = Probe()
        guard let cls = clientClass else { return result }
        result.classFound = true

        var count: UInt32 = 0
        if let methods = class_copyMethodList(cls, &count) {
            for index in 0..<Int(count) {
                let selector = method_getName(methods[index])
                result.methodNames.append(NSStringFromSelector(selector))
            }
            free(methods)
        }
        if let meta = object_getClass(cls as AnyObject) {
            var classCount: UInt32 = 0
            if let methods = class_copyMethodList(meta, &classCount) {
                for index in 0..<Int(classCount) {
                    result.methodNames.append("+" + NSStringFromSelector(method_getName(methods[index])))
                }
                free(methods)
            }
        }
        result.methodNames.sort()

        let selectorName = "createEndpointWithTransportType:andProtocol:andIdentifier:"
            + "andDataOutHandler:forConnectionWithUUID:publishConnection:"
        result.canCreateEndpoint = client?.responds(to: NSSelectorFromString(selectorName)) ?? false
        if !result.canCreateEndpoint {
            result.notes.append("找不到 createEndpoint… 选择器；方法清单见日志")
        }
        if let ios = NSClassFromString("ACCTransportIO") {
            result.notes.append("ACCTransportIO 存在：\(ios)")
        } else {
            result.notes.append("ACCTransportIO 不存在")
        }
        return result
    }

    /// 建立虚拟配件端点。
    /// - Parameter identifier: 配件标识，通常用证书 CN 里的序列号
    /// - Parameter protocolName: 传输协议名，CarPlay 用 "com.apple.carplay" 之类，待实测确认
    func open(identifier: String, protocolName: String) throws {
        guard let client else { throw TransportError.classMissing("ACCTransportClient") }
        let selector = NSSelectorFromString(
            "createEndpointWithTransportType:andProtocol:andIdentifier:"
            + "andDataOutHandler:forConnectionWithUUID:publishConnection:")
        guard client.responds(to: selector) else { throw TransportError.selectorMissing(NSStringFromSelector(selector)) }

        // 用 objc_msgSend 直接调用：参数类型必须与 C ABI 完全对齐，所以逐个强转。
        typealias CreateFunc = @convention(c) (AnyObject, Selector, UInt32, AnyObject, AnyObject,
                                               @escaping (AnyObject?) -> Void, AnyObject, Bool) -> AnyObject?
        let classObject: AnyObject = client
        guard let method = class_getInstanceMethod(type(of: classObject), selector) else {
            throw TransportError.selectorMissing(NSStringFromSelector(selector))
        }
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: CreateFunc.self)

        let handler: (AnyObject?) -> Void = { [weak self] payload in
            guard let self else { return }
            if let data = payload as? Data {
                self.onData?(data)
            } else if let data = (payload as? NSData) as Data? {
                self.onData?(data)
            } else if let object = payload {
                self.onLog?("dataOut 收到非 Data 类型：\(type(of: object))")
            }
        }

        // transportType：0 = 本机虚拟（CarWithin 的用法），协议名与连接 UUID 按官方换能器的习惯填
        let created = function(classObject, selector, 0,
                               protocolName as NSString, identifier as NSString,
                               handler, NSUUID().uuidString as NSString, true)
        guard let created else { throw TransportError.creationFailed }
        endpoint = created as? NSObject
        onLog?("虚拟配件端点已创建：\(created)")
    }

    /// 往端点塞数据（iAP2 帧）。
    func send(_ data: Data) {
        guard let endpoint else { return }
        for name in ["sendData:error:", "writeData:error:", "sendData:"] {
            let selector = NSSelectorFromString(name)
            if endpoint.responds(to: selector) {
                _ = endpoint.perform(selector, with: data as NSData)
                return
            }
        }
        onLog?("端点没有可用的发送方法（试过 sendData:/writeData:）")
    }
}

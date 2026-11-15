import Foundation
import ObjectiveC
import Darwin

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
    enum TransportError: Error, LocalizedError {
        case classMissing(String)
        case selectorMissing(String)
        case creationFailed(String)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .classMissing(let name):
                return "找不到类 \(name)"
            case .selectorMissing(let name):
                return "找不到方法 \(name)"
            case .creationFailed(let why):
                return "creationFailed（\(why)）"
            case .notConnected:
                return "端点还没连上"
            }
        }
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

    /// 上一次初始化失败的原因。日志里要能说清"是没加载到框架，还是没有这个类"。
    private(set) static var loadDiagnosis = ""

    /// 私有框架默认不会被加载，NSClassFromString 永远找不到类。
    /// 先把 dylib 拽进进程，再查类——这是 CarWithin 那条路能跑起来的前提。
    private static func loadPrivateFramework() -> String {
        let candidates = [
            "/System/Library/PrivateFrameworks/CoreAccessories.framework/CoreAccessories",
            "/System/Library/PrivateFrameworks/CoreAccessories.framework/Support/CoreAccessories",
            "/System/Library/PrivateFrameworks/AccessoryTransport.framework/AccessoryTransport",
            "/System/Library/PrivateFrameworks/IAP.framework/IAP",
            "/usr/lib/libAccessoryLoader.dylib",
        ]
        var tried: [String] = []
        for path in candidates {
            if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
                return "dlopen 成功：\((path as NSString).lastPathComponent)"
            }
            let reason = dlerror().map { String(cString: $0) } ?? "未知"
            tried.append("\((path as NSString).lastPathComponent)=\(reason)")
        }
        return "dlopen 全失败（\(tried.joined(separator: " / "))）"
    }

    /// 进程里已经加载的、名字沾边 Accessory / IAP 的镜像，用来判断 ACCTransportIO 到底在哪个框架。
    private static func loadedAccessoryImages() -> [String] {
        var found: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(index) else { continue }
            let name = String(cString: cName)
            if name.localizedCaseInsensitiveContains("accessor")
                || name.localizedCaseInsensitiveContains("IAP.framework") {
                found.append((name as NSString).lastPathComponent)
            }
        }
        return found
    }

    init?() {
        let loaded = AccessoryTransport.loadPrivateFramework()
        guard let cls = NSClassFromString("ACCTransportClient") else {
            AccessoryTransport.loadDiagnosis = "找不到 ACCTransportClient；\(loaded)"
            return nil
        }
        clientClass = cls
        // 单例一般叫 sharedClient / sharedInstance，两种都试
        if let shared = (cls as AnyObject).perform(NSSelectorFromString("sharedClient"))?.takeUnretainedValue() as? NSObject {
            client = shared
        } else if let shared = (cls as AnyObject).perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject {
            client = shared
        } else if let allocated = (cls as? NSObject.Type)?.init() {
            client = allocated
        } else {
            AccessoryTransport.loadDiagnosis = "ACCTransportClient 在，但拿不到实例（sharedClient/sharedInstance/init 都失败）；\(loaded)"
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
        let cls: AnyClass = type(of: client)
        let createSel = NSSelectorFromString(
            "createEndpointWithTransportType:andProtocol:andIdentifier:"
            + "andDataOutHandler:forConnectionWithUUID:publishConnection:")
        guard client.responds(to: createSel) else {
            throw TransportError.selectorMissing(NSStringFromSelector(createSel))
        }
        let connSel = NSSelectorFromString("createConnectionWithType:andIdentifier:")

        // 把关键方法的类型编码写进日志：再要调参数就不用靠猜了
        for (tag, sel) in [("createConnection", connSel), ("createEndpoint", createSel)] {
            if let method = class_getInstanceMethod(cls, sel),
               let encoding = method_getTypeEncoding(method) {
                onLog?("[ACC] \(tag) 编码 \(String(cString: encoding))")
            }
        }

        // 1) 先按 API 的本意建连接：forConnectionWithUUID: 要的是它返回的 UUID。
        //    之前直接塞了个随机 UUID，多半就是 creationFailed 的来源。
        var connectionUUID: AnyObject?
        if client.responds(to: connSel), let method = class_getInstanceMethod(cls, connSel) {
            typealias ConnFunc = @convention(c) (AnyObject, Selector, UInt, AnyObject) -> AnyObject?
            let fn = unsafeBitCast(method_getImplementation(method), to: ConnFunc.self)
            for type in 0...3 {
                let result = fn(client, connSel, UInt(type), identifier as NSString)
                onLog?("[ACC] createConnection type=\(type) → \(result.map { "\($0)" } ?? "nil")")
                if let result {
                    connectionUUID = result
                    break
                }
            }
        } else {
            onLog?("[ACC] 没有 createConnectionWithType:andIdentifier:，跳过建连接")
        }

        // 2) 建端点。有连接就用连接的 UUID，没有就退回随机 UUID 做对照。
        typealias CreateFunc = @convention(c) (AnyObject, Selector, UInt32, AnyObject, AnyObject,
                                               @escaping (AnyObject?) -> Void, AnyObject, Bool) -> AnyObject?
        guard let method = class_getInstanceMethod(cls, createSel) else {
            throw TransportError.selectorMissing(NSStringFromSelector(createSel))
        }
        let function = unsafeBitCast(method_getImplementation(method), to: CreateFunc.self)

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

        let uuid: AnyObject = connectionUUID ?? (NSUUID().uuidString as NSString)
        if connectionUUID == nil {
            onLog?("[ACC] 连接建不起来，退回随机 UUID 做对照")
        }

        // 协议名也换几种写法试：固件/系统版本不同，认的字符串不一定一样
        let protocolNames = [protocolName, "com.apple.carplay.wireless", "carplay"]
        var created: AnyObject?
        outer: for proto in protocolNames {
            for transportType in 0...3 {
                for publish in [true, false] {
                    let candidate = function(client, createSel, UInt32(transportType),
                                             proto as NSString, identifier as NSString,
                                             handler, uuid, publish)
                    let describe = candidate.map { "\(type(of: $0))" } ?? "nil"
                    onLog?("[ACC] createEndpoint proto=\(proto) transport=\(transportType) "
                           + "publish=\(publish) → \(describe)")
                    if let candidate {
                        created = candidate
                        break outer
                    }
                }
            }
        }

        guard let created else {
            let images = AccessoryTransport.loadedAccessoryImages()
            onLog?("[ACC] 已加载的相关镜像：\(images.isEmpty ? "无" : images.joined(separator: ", "))")
            throw TransportError.creationFailed(connectionUUID == nil
                ? "连接和端点都建不起来，四种 type 全 nil —— 基本可判定为 entitlement 被拒，自签包拿不到访问配件服务的权限"
                : "连接建起来了但端点被拒（transportType 0…3 × publish × 三种协议名全试过了）—— 大概率是端点级 entitlement，不是参数问题")
        }
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

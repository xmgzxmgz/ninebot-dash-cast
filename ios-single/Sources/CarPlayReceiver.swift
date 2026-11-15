import Foundation
import CoreVideo

/// CarPlay 接收层（M2/M3）的接口占位。
///
/// 这一层是单机方案的核心难点，也是目前**没有实现**的部分。它要做的事，
/// 按 CarWithin 的符号表（见 docs/CARWITHIN-RE.md）拆成四步：
///
/// 1. 身份：读取包内 MFi 证书链与私钥（`AccessoryIdentity`）
/// 2. 接入：用私有 `CoreAccessories`（`ACCTransportClient`）创建虚拟配件端点，
///    等 iOS 主动连进来（`NativeReceiver.listen(configuration:identity:port:)`）
/// 3. 认证与协商：iAP2 会话（`IAP2Packet`）+ `/auth-setup` MFiSAP 签名 +
///    SRP 配对验证 + RTSP 协商出视频通道
/// 4. 出帧：从视频通道收 H.264 ES，解出访问单元后交给 `FrameEncoder` 重编码
///
/// 一旦这一层打通，上层只需要把 `onFrame` 里给 `FrameEncoder` 的 CVPixelBuffer
/// 从"测试图"换成"CarPlay 画面"即可，仪表侧代码不需要改。
protocol CarPlayReceiving: AnyObject {
    /// 会话产生的一帧画面（BGRA），尺寸由接收端决定，交给下游缩放。
    var onVideoFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// 会话是否已建立（可用于 UI 状态）。
    var isConnected: Bool { get }
    func start() throws
    func stop()
}

/// 尚未实现：调用会抛错，避免误以为能用。
final class CarPlayReceiverStub: CarPlayReceiving {
    enum StubError: Error {
        case notImplemented
    }

    var onVideoFrame: ((CVPixelBuffer) -> Void)?
    private(set) var isConnected = false

    func start() throws {
        throw StubError.notImplemented
    }

    func stop() {
        isConnected = false
    }
}

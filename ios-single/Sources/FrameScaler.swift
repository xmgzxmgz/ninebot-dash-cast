import Foundation
import CoreImage
import CoreVideo

/// 把任意尺寸的画面缩放到仪表要的分辨率（等比 + 居中补黑边）。
final class FrameScaler {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let width: Int
    private let height: Int
    private var pool: CVPixelBufferPool?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
        pool = created
    }

    func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let input = CIImage(cvPixelBuffer: source)
        let sourceWidth = input.extent.width
        let sourceHeight = input.extent.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(CGFloat(width) / sourceWidth, CGFloat(height) / sourceHeight)
        let scaledWidth = sourceWidth * scale
        let scaledHeight = sourceHeight * scale
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (CGFloat(width) - scaledWidth) / 2
        let dy = (CGFloat(height) - scaledHeight) / 2
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        guard let buffer = makeBuffer() else { return nil }
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.render(placed.composited(over: black), to: buffer)
        return buffer
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if let pool {
            var buffer: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess {
                return buffer
            }
        }
        var fallback: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &fallback)
        return fallback
    }
}

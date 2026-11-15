import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// H.264 编码：VideoToolbox 输出 AVCC，这里转成 Annex-B 访问单元。
///
/// 仪表要的是 Baseline、无 B 帧、每关键帧带 SPS/PPS，和安卓/ninebot_pro 的参数一致。
final class FrameEncoder {
    struct Configuration {
        var width = 848
        var height = 480
        var fps = 20
        var bitrate = 2_000_000
        var gop = 20
    }

    private var session: VTCompressionSession?
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    private let configuration: Configuration

    var onFrame: ((Data, Bool) -> Void)?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func start() -> Bool {
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
        ]
        var handle: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &handle)
        guard status == noErr, let session = handle else { return false }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: configuration.bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: configuration.fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: configuration.gop as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                             value: kCFBooleanTrue)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        return true
    }

    func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    func encode(_ buffer: CVPixelBuffer, frameIndex: Int64) {
        guard let session else { return }
        let pts = CMTime(value: frameIndex, timescale: Int32(configuration.fps))
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: &flags) { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer else { return }
                self?.handle(sampleBuffer: sampleBuffer)
            }
    }

    /// 供 UI 层调用：把编码器产出的 CMSampleBuffer 转成 Annex-B。
    func handle(sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        updateParameterSets(from: format)

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = true
        if let attachments = attachments as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let data = pointer else { return }

        var annexB = Data()
        if isKeyframe {
            for set in [sps, pps] where !set.isEmpty {
                annexB.append(contentsOf: [0, 0, 0, 1])
                annexB.append(contentsOf: set)
            }
        }
        // AVCC：4 字节长度前缀
        var offset = 0
        while offset + 4 <= length {
            let nalLength = Int(UInt32(bigEndian: data.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }))
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(UnsafeBufferPointer(start: UnsafeRawPointer(data.advanced(by: offset))
                                                .assumingMemoryBound(to: UInt8.self),
                                              count: nalLength))
            offset += nalLength
        }
        if !annexB.isEmpty { onFrame?(annexB, isKeyframe) }
    }

    private func updateParameterSets(from format: CMFormatDescription) {
        var count = 0
        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                             parameterSetPointerOut: nil,
                                                             parameterSetSizeOut: nil,
                                                             parameterSetCountOut: &count,
                                                             nalUnitHeaderLengthOut: nil) != noErr {
            return
        }
        guard count >= 2 else { return }
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                          parameterSetPointerOut: &spsPointer,
                                                          parameterSetSizeOut: &spsSize,
                                                          parameterSetCountOut: nil,
                                                          nalUnitHeaderLengthOut: nil)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1,
                                                          parameterSetPointerOut: &ppsPointer,
                                                          parameterSetSizeOut: &ppsSize,
                                                          parameterSetCountOut: nil,
                                                          nalUnitHeaderLengthOut: nil)
        if let spsPointer, spsSize > 0 { sps = Array(UnsafeBufferPointer(start: spsPointer, count: spsSize)) }
        if let ppsPointer, ppsSize > 0 { pps = Array(UnsafeBufferPointer(start: ppsPointer, count: ppsSize)) }
    }
}

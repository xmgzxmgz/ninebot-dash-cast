import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// H.264 解码：接 CarPlay 过来的 Annex-B 字节流，吐出 CVPixelBuffer。
///
/// 参数集（SPS/PPS）变了就重建 format description 与解码会话——CarPlay 在分辨率
/// 或码率切换时会重发参数集，不重建会直接黑屏。
final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onLog: ((String) -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var sps = Data()
    private var pps = Data()
    private var buffer = Data()

    func feed(_ data: Data) {
        buffer.append(data)
        for nal in Self.extractNALs(&buffer) {
            handle(nal: nal)
        }
    }

    private func handle(nal: Data) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7:
            sps = nal
            rebuildFormatIfPossible()
        case 8:
            pps = nal
            rebuildFormatIfPossible()
        case 1, 5:
            decode(nal)
        default:
            break
        }
    }

    private func rebuildFormatIfPossible() {
        guard !sps.isEmpty, !pps.isEmpty else { return }
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        format = description
        rebuildSession(with: description)
    }

    private func rebuildSession(with description: CMFormatDescription) {
        if let session { VTDecompressionSessionInvalidate(session) }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            onLog?("解码会话创建失败：\(status)")
            return
        }
        session = newSession
        onLog?("解码会话就绪（\(CMVideoFormatDescriptionGetDimensions(description).width)x"
               + "\(CMVideoFormatDescriptionGetDimensions(description).height)）")
    }

    private func decode(_ nal: Data) {
        guard let session, let format else { return }
        // AVCC：4 字节大端长度 + NAL
        var avcc = Data()
        var length = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
        avcc.append(nal)

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block) == noErr, let block else { return }
        _ = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!,
                                          blockBuffer: block,
                                          offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sizeDescription = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: block,
                                        formatDescription: format,
                                        sampleCount: 1,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sizeDescription,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { return }

        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: []) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.onFrame?(imageBuffer)
        }
    }

    /// 从缓冲里切出完整 NAL（兼容 3/4 字节起始码），最后一个可能不完整的段落留在 buffer。
    static func extractNALs(_ buffer: inout Data) -> [Data] {
        let bytes = [UInt8](buffer)
        var starts: [Int] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append(index)
                    index += 3
                    continue
                }
                if index + 4 <= bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append(index)
                    index += 4
                    continue
                }
            }
            index += 1
        }
        guard starts.count >= 2 else { return [] }

        var nals: [Data] = []
        for position in 0..<(starts.count - 1) {
            let begin = starts[position]
            let end = starts[position + 1]
            let header = bytes[begin + 2] == 1 ? begin + 3 : begin + 4
            if header < end { nals.append(buffer.subdata(in: header..<end)) }
        }
        let keepFrom = starts[starts.count - 1]
        buffer = buffer.subdata(in: keepFrom..<buffer.count)
        return nals
    }
}

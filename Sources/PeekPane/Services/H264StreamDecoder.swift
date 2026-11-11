import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PeekPaneBridgeWire
import VideoToolbox

final class H264StreamDecoder: @unchecked Sendable {
    private let decodeQueue: DispatchQueue
    private let onDecodedFrame: @Sendable (CVPixelBuffer, IOSurfaceRef, CGSize) -> Void
    private let onKeyframeNeeded: @Sendable () -> Void

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var activeAVCCBytes: Data?
    private var expectedSequenceNumber: UInt32?
    private var awaitingKeyframe: Bool = true
    private var isInvalidated: Bool = false

    init(
        streamLabel: String,
        onDecodedFrame: @escaping @Sendable (CVPixelBuffer, IOSurfaceRef, CGSize) -> Void,
        onKeyframeNeeded: @escaping @Sendable () -> Void
    ) {
        self.decodeQueue = DispatchQueue(
            label: "com.peekpane.h264.\(streamLabel)",
            qos: .userInteractive
        )
        self.onDecodedFrame = onDecodedFrame
        self.onKeyframeNeeded = onKeyframeNeeded
    }

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func enqueuePacket(_ packet: BridgeVideoPacket) {
        decodeQueue.async { [weak self] in
            self?.decodeOnQueue(packet)
        }
    }

    func invalidate() {
        decodeQueue.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            self.isInvalidated = true
            self.tearDownSessionOnQueue()
        }
    }

    private func decodeOnQueue(_ packet: BridgeVideoPacket) {
        guard !isInvalidated else { return }

        if let expected = expectedSequenceNumber, packet.header.sequenceNumber != expected {
            if !packet.header.isKeyframe {
                awaitingKeyframe = true
                expectedSequenceNumber = nil
                onKeyframeNeeded()
                return
            }
        }
        expectedSequenceNumber = packet.header.sequenceNumber &+ 1

        if awaitingKeyframe && !packet.header.isKeyframe {
            onKeyframeNeeded()
            return
        }

        if packet.header.isKeyframe {
            guard let avcC = packet.avcCData, configureSessionIfNeeded(avcC: avcC) else {
                awaitingKeyframe = true
                onKeyframeNeeded()
                return
            }
            awaitingKeyframe = false
        }

        guard let session = decompressionSession,
            let formatDesc = formatDescription,
            let sampleBuffer = Self.makeSampleBuffer(
                naluData: packet.naluData,
                timestampUs: packet.header.timestampUs,
                formatDescription: formatDesc
            )
        else {
            awaitingKeyframe = true
            onKeyframeNeeded()
            return
        }

        let viewportSize = CGSize(
            width: max(64, CGFloat(packet.header.viewportWidth)),
            height: max(64, CGFloat(packet.header.viewportHeight))
        )
        let frameHandler = onDecodedFrame
        let keyframeCallback = onKeyframeNeeded

        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { [weak self] decodeStatus, _, imageBuffer, _, _ in
            guard decodeStatus == noErr,
                let imageBuffer,
                let surfaceUnmanaged = CVPixelBufferGetIOSurface(imageBuffer)
            else {
                self?.markAwaitingKeyframeAsync()
                keyframeCallback()
                return
            }
            let surface = surfaceUnmanaged.takeUnretainedValue()
            frameHandler(imageBuffer, surface, viewportSize)
        }

        if status != noErr {
            awaitingKeyframe = true
            onKeyframeNeeded()
        }
    }

    private func markAwaitingKeyframeAsync() {
        decodeQueue.async { [weak self] in
            self?.awaitingKeyframe = true
        }
    }

    private func configureSessionIfNeeded(avcC: Data) -> Bool {
        if activeAVCCBytes == avcC, decompressionSession != nil, formatDescription != nil {
            return true
        }
        guard let parsed = try? ParsedAVCCConfig.parse(from: avcC),
            let newFormat = Self.createH264FormatDescription(from: parsed)
        else {
            return false
        }

        if let existingSession = decompressionSession,
            VTDecompressionSessionCanAcceptFormatDescription(existingSession, formatDescription: newFormat)
        {
            formatDescription = newFormat
            activeAVCCBytes = avcC
            return true
        }

        tearDownSessionOnQueue()

        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormat,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            return false
        }
        decompressionSession = newSession
        formatDescription = newFormat
        activeAVCCBytes = avcC
        return true
    }

    private func tearDownSessionOnQueue() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        activeAVCCBytes = nil
    }

    private static func createH264FormatDescription(from config: ParsedAVCCConfig) -> CMVideoFormatDescription? {
        let allSets = config.spsList + config.ppsList
        guard !allSets.isEmpty else { return nil }
        var pointers: [UnsafePointer<UInt8>] = []
        pointers.reserveCapacity(allSets.count)
        var sizes: [Int] = []
        sizes.reserveCapacity(allSets.count)

        func withPinnedParameterSets(_ index: Int) -> CMVideoFormatDescription? {
            if index == allSets.count {
                var formatDesc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: allSets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(config.nalUnitLengthByteCount),
                    formatDescriptionOut: &formatDesc
                )
                return status == noErr ? formatDesc : nil
            }
            return allSets[index].withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return nil
                }
                pointers.append(base)
                sizes.append(rawBuffer.count)
                return withPinnedParameterSets(index + 1)
            }
        }
        return withPinnedParameterSets(0)
    }

    private static func makeSampleBuffer(
        naluData: Data,
        timestampUs: UInt64,
        formatDescription: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        let dataLength = naluData.count
        guard dataLength > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let copyStatus = naluData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            return nil
        }

        let safeTimestamp = Int64(bitPattern: timestampUs & 0x7FFF_FFFF_FFFF_FFFF)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: safeTimestamp, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = dataLength
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return sampleStatus == noErr ? sampleBuffer : nil
    }
}

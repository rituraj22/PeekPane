import CoreGraphics
import Foundation

public enum BridgeWireError: Error, Equatable, Sendable {
    case truncatedHeader
    case invalidMagic
    case unsupportedVersion(UInt8)
    case missingKeyframeAVCC
    case truncatedAVCC
    case emptyNALUPayload
    case oversizedFrame
}

/// 28-byte binary frame header preceding AVCC H.264 or JPEG packets from browser extensions.
public struct BridgeWireHeader: Equatable, Sendable {
    public static let byteLength = 28
    public static let magicByte0: UInt8 = 0x50
    public static let magicByte1: UInt8 = 0x50
    public static let currentVersion: UInt8 = 0x01

    public static let flagKeyframe: UInt8 = 1 << 0
    public static let flagHasAVCC: UInt8 = 1 << 1
    public static let flagJPEGPayload: UInt8 = 1 << 2

    public var isKeyframe: Bool
    public var hasAVCC: Bool
    public var isJPEGFrame: Bool
    public var tabID: UInt32
    public var sequenceNumber: UInt32
    public var timestampUs: UInt64
    public var viewportWidth: UInt16
    public var viewportHeight: UInt16
    public var avcCLength: UInt16

    public init(
        isKeyframe: Bool,
        hasAVCC: Bool,
        tabID: UInt32,
        sequenceNumber: UInt32,
        timestampUs: UInt64,
        viewportWidth: UInt16,
        viewportHeight: UInt16,
        avcCLength: UInt16,
        isJPEGFrame: Bool = false
    ) {
        self.isKeyframe = isKeyframe
        self.hasAVCC = hasAVCC
        self.isJPEGFrame = isJPEGFrame
        self.tabID = tabID
        self.sequenceNumber = sequenceNumber
        self.timestampUs = timestampUs
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.avcCLength = avcCLength
    }

    public var flags: UInt8 {
        var result: UInt8 = 0
        if isKeyframe {
            result |= Self.flagKeyframe
        }
        if hasAVCC {
            result |= Self.flagHasAVCC
        }
        if isJPEGFrame {
            result |= Self.flagJPEGPayload
        }
        return result
    }

    public func encode() -> Data {
        var bytes = Data(capacity: Self.byteLength)
        bytes.append(Self.magicByte0)
        bytes.append(Self.magicByte1)
        bytes.append(Self.currentVersion)
        bytes.append(flags)
        Self.appendUInt32BE(tabID, to: &bytes)
        Self.appendUInt32BE(sequenceNumber, to: &bytes)
        Self.appendUInt64BE(timestampUs, to: &bytes)
        Self.appendUInt16BE(viewportWidth, to: &bytes)
        Self.appendUInt16BE(viewportHeight, to: &bytes)
        Self.appendUInt16BE(avcCLength, to: &bytes)
        Self.appendUInt16BE(0, to: &bytes)
        return bytes
    }

    public static func decode(from data: Data) throws -> Self {
        guard data.count >= Self.byteLength else {
            throw BridgeWireError.truncatedHeader
        }
        let base = data.startIndex
        guard data[base] == Self.magicByte0, data[base + 1] == Self.magicByte1 else {
            throw BridgeWireError.invalidMagic
        }
        let version = data[base + 2]
        guard version == Self.currentVersion else {
            throw BridgeWireError.unsupportedVersion(version)
        }
        let rawFlags = data[base + 3]
        let isKeyframe = (rawFlags & Self.flagKeyframe) != 0
        let hasAVCC = (rawFlags & Self.flagHasAVCC) != 0
        let isJPEGFrame = (rawFlags & Self.flagJPEGPayload) != 0

        let tabID = readUInt32BE(data, offset: base + 4)
        let seq = readUInt32BE(data, offset: base + 8)
        let timestampUs = readUInt64BE(data, offset: base + 12)
        let viewportW = readUInt16BE(data, offset: base + 20)
        let viewportH = readUInt16BE(data, offset: base + 22)
        let avcCLen = readUInt16BE(data, offset: base + 24)

        return Self(
            isKeyframe: isKeyframe,
            hasAVCC: hasAVCC,
            tabID: tabID,
            sequenceNumber: seq,
            timestampUs: timestampUs,
            viewportWidth: viewportW,
            viewportHeight: viewportH,
            avcCLength: avcCLen,
            isJPEGFrame: isJPEGFrame
        )
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64BE(_ value: UInt64, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
        let high = UInt64(readUInt32BE(data, offset: offset))
        let low = UInt64(readUInt32BE(data, offset: offset + 4))
        return (high << 32) | low
    }
}

public struct BridgeVideoPacket: Equatable, Sendable {
    public static let defaultMaxFrameBytes = 16 * 1024 * 1024

    public let header: BridgeWireHeader
    public let avcCData: Data?
    public let naluData: Data

    public init(header: BridgeWireHeader, avcCData: Data?, naluData: Data) {
        self.header = header
        self.avcCData = avcCData
        self.naluData = naluData
    }

    public func encode() -> Data {
        let avcCBytes = avcCData ?? Data()
        var normalizedHeader = header
        normalizedHeader.hasAVCC = !avcCBytes.isEmpty
        normalizedHeader.avcCLength = UInt16(clamping: avcCBytes.count)

        var output = Data(capacity: BridgeWireHeader.byteLength + avcCBytes.count + naluData.count)
        output.append(normalizedHeader.encode())
        output.append(avcCBytes)
        output.append(naluData)
        return output
    }

    public static func decode(
        from data: Data,
        maxFrameBytes: Int = Self.defaultMaxFrameBytes
    ) throws -> Self {
        guard data.count <= maxFrameBytes else {
            throw BridgeWireError.oversizedFrame
        }
        let header = try BridgeWireHeader.decode(from: data)
        let avcCLen = Int(header.avcCLength)
        if header.isKeyframe && !header.isJPEGFrame && (!header.hasAVCC || avcCLen == 0) {
            throw BridgeWireError.missingKeyframeAVCC
        }

        let avcCStart = data.startIndex + BridgeWireHeader.byteLength
        let avcCEnd = avcCStart + avcCLen
        guard avcCEnd <= data.endIndex else {
            throw BridgeWireError.truncatedAVCC
        }

        let avcCData: Data? = avcCLen > 0 ? Data(data[avcCStart..<avcCEnd]) : nil
        let naluSlice = data[avcCEnd..<data.endIndex]
        guard !naluSlice.isEmpty else {
            throw BridgeWireError.emptyNALUPayload
        }

        return Self(
            header: header,
            avcCData: avcCData,
            naluData: Data(naluSlice)
        )
    }

    /// Computes the aspect-fit active viewport sub-rectangle in normalized `[0, 1]` surface coordinates,
    /// stripping black letterbox or pillarbox bars if the browser padded a resized tab frame.
    public static func computeActiveContentNormalizedRect(
        surfaceWidth: CGFloat,
        surfaceHeight: CGFloat,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) -> CGRect {
        guard surfaceWidth > 1, surfaceHeight > 1, viewportWidth > 1, viewportHeight > 1 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let surfaceAspect = surfaceWidth / surfaceHeight
        let viewportAspect = viewportWidth / viewportHeight
        let relativeDiff = abs(surfaceAspect - viewportAspect) / max(0.01, viewportAspect)
        if relativeDiff < 0.015 {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if viewportAspect > surfaceAspect {
            let activeH = max(0.01, min(1.0, surfaceAspect / viewportAspect))
            return CGRect(x: 0, y: (1.0 - activeH) * 0.5, width: 1.0, height: activeH)
        }
        let activeW = max(0.01, min(1.0, viewportAspect / surfaceAspect))
        return CGRect(x: (1.0 - activeW) * 0.5, y: 0, width: activeW, height: 1.0)
    }
}

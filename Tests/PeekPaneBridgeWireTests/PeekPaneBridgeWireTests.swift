import Foundation
import PeekPaneBridgeWire
import XCTest

final class PeekPaneBridgeWireTests: XCTestCase {
    func testPinnedExtensionIDMatchesPublicKey() {
        let derived = BridgeConstants.deriveChromeExtensionID(
            publicKeySPKIBase64: BridgeConstants.extensionPublicKeyBase64
        )
        XCTAssertEqual(derived, BridgeConstants.pinnedExtensionID)
        XCTAssertEqual(BridgeConstants.pinnedExtensionID.count, 32)
        XCTAssertTrue(BridgeSecurity.isAllowedExtensionOrigin(BridgeConstants.expectedExtensionOrigin))
        XCTAssertTrue(BridgeSecurity.isAllowedExtensionOrigin("moz-extension://d3b07384-d113-4ec6-a7dc-e2a988123456"))
        XCTAssertFalse(BridgeSecurity.isAllowedExtensionOrigin("moz-extension://not-a-valid-uuid"))
        XCTAssertFalse(BridgeSecurity.isAllowedExtensionOrigin("moz-extension://d3b07384-d113-4ec6-a7dc-e2a988123456/"))
        XCTAssertFalse(BridgeSecurity.isAllowedExtensionOrigin("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertFalse(BridgeSecurity.isAllowedExtensionOrigin("https://evil.example"))
        XCTAssertFalse(BridgeSecurity.isAllowedExtensionOrigin(nil))
    }

    func testJPEGVideoPacketRoundTripWithoutAVCC() throws {
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
        let header = BridgeWireHeader(
            isKeyframe: true,
            hasAVCC: false,
            tabID: 77,
            sequenceNumber: 12,
            timestampUs: 555_000,
            viewportWidth: 1280,
            viewportHeight: 800,
            avcCLength: 0,
            isJPEGFrame: true
        )
        let packet = BridgeVideoPacket(header: header, avcCData: nil, naluData: jpegBytes)
        let encoded = packet.encode()
        XCTAssertEqual(encoded.count, BridgeWireHeader.byteLength + jpegBytes.count)

        let decoded = try BridgeVideoPacket.decode(from: encoded)
        XCTAssertEqual(decoded, packet)
        XCTAssertTrue(decoded.header.isJPEGFrame)
        XCTAssertTrue(decoded.header.isKeyframe)
        XCTAssertNil(decoded.avcCData)
    }

    func testKeyframeVideoPacketRoundTrip() throws {
        let avcC = Self.makeValidAVCC()
        let nalu = Data([0x00, 0x00, 0x00, 0x05, 0x65, 0x88, 0x84, 0x21, 0xA0])
        let header = BridgeWireHeader(
            isKeyframe: true,
            hasAVCC: true,
            tabID: 42,
            sequenceNumber: 1,
            timestampUs: 1_234_567_890,
            viewportWidth: 1440,
            viewportHeight: 900,
            avcCLength: UInt16(avcC.count)
        )
        let packet = BridgeVideoPacket(header: header, avcCData: avcC, naluData: nalu)
        let encoded = packet.encode()
        XCTAssertEqual(encoded.count, BridgeWireHeader.byteLength + avcC.count + nalu.count)

        let decoded = try BridgeVideoPacket.decode(from: encoded)
        XCTAssertEqual(decoded, packet)
    }

    func testDeltaVideoPacketRoundTripWithoutAVCC() throws {
        let nalu = Data([0x00, 0x00, 0x00, 0x04, 0x41, 0x9A, 0x24, 0x6C])
        let header = BridgeWireHeader(
            isKeyframe: false,
            hasAVCC: false,
            tabID: 99,
            sequenceNumber: 108,
            timestampUs: 9_876_543_210,
            viewportWidth: 1280,
            viewportHeight: 720,
            avcCLength: 0
        )
        let packet = BridgeVideoPacket(header: header, avcCData: nil, naluData: nalu)
        let decoded = try BridgeVideoPacket.decode(from: packet.encode())
        XCTAssertEqual(decoded, packet)
        XCTAssertNil(decoded.avcCData)
    }

    func testVideoPacketRejectsInvalidInputs() {
        XCTAssertThrowsError(try BridgeVideoPacket.decode(from: Data([0x50, 0x50]))) { error in
            XCTAssertEqual(error as? BridgeWireError, .truncatedHeader)
        }

        var badMagic = Data(repeating: 0, count: BridgeWireHeader.byteLength + 4)
        badMagic[0] = 0x42
        badMagic[1] = 0x42
        XCTAssertThrowsError(try BridgeVideoPacket.decode(from: badMagic)) { error in
            XCTAssertEqual(error as? BridgeWireError, .invalidMagic)
        }

        var badVersion = Data(repeating: 0, count: BridgeWireHeader.byteLength + 4)
        badVersion[0] = 0x50
        badVersion[1] = 0x50
        badVersion[2] = 0x02
        XCTAssertThrowsError(try BridgeVideoPacket.decode(from: badVersion)) { error in
            XCTAssertEqual(error as? BridgeWireError, .unsupportedVersion(2))
        }

        let keyframeMissingAVCC = BridgeWireHeader(
            isKeyframe: true,
            hasAVCC: false,
            tabID: 1,
            sequenceNumber: 0,
            timestampUs: 100,
            viewportWidth: 800,
            viewportHeight: 600,
            avcCLength: 0
        )
        var rawMissing = keyframeMissingAVCC.encode()
        rawMissing.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x65])
        XCTAssertThrowsError(try BridgeVideoPacket.decode(from: rawMissing)) { error in
            XCTAssertEqual(error as? BridgeWireError, .missingKeyframeAVCC)
        }

        XCTAssertThrowsError(try BridgeVideoPacket.decode(from: rawMissing, maxFrameBytes: 10)) { error in
            XCTAssertEqual(error as? BridgeWireError, .oversizedFrame)
        }
    }

    func testAVCCParserExtractsSPSAndPPS() throws {
        let avcC = Self.makeValidAVCC()
        let parsed = try ParsedAVCCConfig.parse(from: avcC)
        XCTAssertEqual(parsed.profileIndication, 0x64)
        XCTAssertEqual(parsed.profileCompatibility, 0x00)
        XCTAssertEqual(parsed.levelIndication, 0x33)
        XCTAssertEqual(parsed.nalUnitLengthByteCount, 4)
        XCTAssertEqual(parsed.spsList, [Data([0x67, 0x64, 0x00, 0x33, 0xAC])])
        XCTAssertEqual(parsed.ppsList, [Data([0x68, 0xEE, 0x3C, 0x80])])
    }

    func testAVCCParserRejectsMalformedRecords() {
        XCTAssertThrowsError(try ParsedAVCCConfig.parse(from: Data([0x01, 0x64, 0x00]))) { error in
            XCTAssertEqual(error as? AVCCParseError, .truncatedRecord)
        }

        // Unsupported version 2
        let badVersion = Data([0x02, 0x64, 0x00, 0x33, 0xFF, 0xE1, 0x00, 0x01, 0x67])
        XCTAssertThrowsError(try ParsedAVCCConfig.parse(from: badVersion)) { error in
            XCTAssertEqual(error as? AVCCParseError, .unsupportedConfigurationVersion(2))
        }

        // nalUnitLengthByteCount == 3 (0xFE & 0x03 + 1 == 3) is invalid per ISO 14496-15
        let badLengthSize = Data([0x01, 0x64, 0x00, 0x33, 0xFE, 0xE1, 0x00, 0x01, 0x67])
        XCTAssertThrowsError(try ParsedAVCCConfig.parse(from: badLengthSize)) { error in
            XCTAssertEqual(error as? AVCCParseError, .unsupportedNALUnitLength(3))
        }

        // Truncated SPS bytes
        let truncatedSPS = Data([0x01, 0x64, 0x00, 0x33, 0xFF, 0xE1, 0x00, 0x10, 0x67, 0x64])
        XCTAssertThrowsError(try ParsedAVCCConfig.parse(from: truncatedSPS)) { error in
            XCTAssertEqual(error as? AVCCParseError, .truncatedSPS)
        }
    }

    func testNativeMessagingFramingRoundTripAndEOF() throws {
        let response = NativeHostResponse(
            ok: true,
            running: true,
            wsPort: 51_234,
            token: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            protocolVersion: 1,
            stagedExtensionVersion: "1.0.0"
        )
        let framed = try NativeMessagingFraming.encodeMessage(response)
        let decoded = try NativeMessagingFraming.decodeMessage(NativeHostResponse.self, from: framed)
        XCTAssertEqual(decoded, response)

        var cursor = 0
        let readPayload = try NativeMessagingFraming.readFramedPayload { count in
            guard cursor < framed.count else { return nil }
            let end = min(framed.count, cursor + count)
            defer { cursor = end }
            return Data(framed[cursor..<end])
        }
        XCTAssertNotNil(readPayload)

        let eofPayload = try NativeMessagingFraming.readFramedPayload { _ in nil }
        XCTAssertNil(eofPayload)
    }

    func testConstantTimeTokenComparison() {
        let tokenA = "a9f401bc88310de74b6c1928374655a9f401bc88310de74b6c19283746550011"
        let tokenB = "a9f401bc88310de74b6c1928374655a9f401bc88310de74b6c19283746550011"
        let tokenC = "a9f401bc88310de74b6c1928374655a9f401bc88310de74b6c19283746550012"
        XCTAssertTrue(BridgeSecurity.constantTimeEquals(tokenA, tokenB))
        XCTAssertFalse(BridgeSecurity.constantTimeEquals(tokenA, tokenC))
        XCTAssertFalse(BridgeSecurity.constantTimeEquals(tokenA, "short"))
        XCTAssertFalse(BridgeSecurity.constantTimeEquals("", tokenA))
        XCTAssertTrue(BridgeSecurity.constantTimeEquals("", ""))
    }

    func testActiveContentNormalizedRectStripsLetterboxing() {
        let exact = BridgeVideoPacket.computeActiveContentNormalizedRect(
            surfaceWidth: 1920,
            surfaceHeight: 1080,
            viewportWidth: 960,
            viewportHeight: 540
        )
        XCTAssertEqual(exact, CGRect(x: 0, y: 0, width: 1, height: 1))

        // 16:9 surface (1920x1080) holding ultra-wide 2:1 viewport (1000x500) -> horizontal letterbox bars top/bottom
        let letterboxed = BridgeVideoPacket.computeActiveContentNormalizedRect(
            surfaceWidth: 1920,
            surfaceHeight: 1080,
            viewportWidth: 1000,
            viewportHeight: 500
        )
        XCTAssertEqual(letterboxed.minX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(letterboxed.width, 1.0, accuracy: 0.0001)
        XCTAssertEqual(letterboxed.height, (1920.0 / 1080.0) / 2.0, accuracy: 0.0001)
        XCTAssertEqual(letterboxed.minY, (1.0 - letterboxed.height) * 0.5, accuracy: 0.0001)

        // 16:9 surface (1600x900) holding square 1:1 viewport (800x800) -> vertical pillarbox bars left/right
        let pillarboxed = BridgeVideoPacket.computeActiveContentNormalizedRect(
            surfaceWidth: 1600,
            surfaceHeight: 900,
            viewportWidth: 800,
            viewportHeight: 800
        )
        XCTAssertEqual(pillarboxed.minY, 0.0, accuracy: 0.0001)
        XCTAssertEqual(pillarboxed.height, 1.0, accuracy: 0.0001)
        XCTAssertEqual(pillarboxed.width, 900.0 / 1600.0, accuracy: 0.0001)
        XCTAssertEqual(pillarboxed.minX, (1.0 - pillarboxed.width) * 0.5, accuracy: 0.0001)
    }

    private static func makeValidAVCC() -> Data {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC]
        let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
        var bytes: [UInt8] = [
            0x01,  // configurationVersion = 1
            0x64,  // High profile
            0x00,  // compatibility
            0x33,  // Level 5.1
            0xFF,  // 4-byte NALU length
            0xE1,  // 1 SPS
            0x00, UInt8(sps.count)
        ]
        bytes.append(contentsOf: sps)
        bytes.append(0x01)  // 1 PPS
        bytes.append(contentsOf: [0x00, UInt8(pps.count)])
        bytes.append(contentsOf: pps)
        return Data(bytes)
    }
}

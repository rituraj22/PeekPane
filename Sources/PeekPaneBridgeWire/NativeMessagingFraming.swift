import Foundation

public enum NativeMessagingError: Error, Equatable, Sendable {
    case truncatedLengthPrefix
    case emptyMessage
    case messageTooLarge(Int)
    case truncatedPayload
    case invalidJSON
}

public struct BridgeEndpointInfo: Codable, Equatable, Sendable {
    public let wsPort: UInt16
    public let token: String
    public let pid: Int32
    public let protocolVersion: Int
    public let stagedExtensionVersion: String

    public init(
        wsPort: UInt16,
        token: String,
        pid: Int32,
        protocolVersion: Int,
        stagedExtensionVersion: String
    ) {
        self.wsPort = wsPort
        self.token = token
        self.pid = pid
        self.protocolVersion = protocolVersion
        self.stagedExtensionVersion = stagedExtensionVersion
    }
}

public struct NativeHostRequest: Codable, Equatable, Sendable {
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

public struct NativeHostResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let running: Bool
    public let wsPort: UInt16?
    public let token: String?
    public let protocolVersion: Int?
    public let stagedExtensionVersion: String?
    public let callerBundleIdentifier: String?
    public let error: String?

    public init(
        ok: Bool,
        running: Bool,
        wsPort: UInt16? = nil,
        token: String? = nil,
        protocolVersion: Int? = nil,
        stagedExtensionVersion: String? = nil,
        callerBundleIdentifier: String? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.running = running
        self.wsPort = wsPort
        self.token = token
        self.protocolVersion = protocolVersion
        self.stagedExtensionVersion = stagedExtensionVersion
        self.callerBundleIdentifier = callerBundleIdentifier
        self.error = error
    }
}

public enum NativeMessagingFraming {
    public static let maxMessageBytes = 1_048_576

    public static func encodeMessage<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard !payload.isEmpty else {
            throw NativeMessagingError.emptyMessage
        }
        guard payload.count <= Self.maxMessageBytes else {
            throw NativeMessagingError.messageTooLarge(payload.count)
        }
        var lengthLE = UInt32(payload.count).littleEndian
        var framed = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: &lengthLE) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    public static func decodeMessage<T: Decodable>(_ type: T.Type, from framedData: Data) throws -> T {
        guard framedData.count >= 4 else {
            throw NativeMessagingError.truncatedLengthPrefix
        }
        let base = framedData.startIndex
        let length =
            Int(framedData[base])
            | (Int(framedData[base + 1]) << 8)
            | (Int(framedData[base + 2]) << 16)
            | (Int(framedData[base + 3]) << 24)
        guard length > 0 else {
            throw NativeMessagingError.emptyMessage
        }
        guard length <= Self.maxMessageBytes else {
            throw NativeMessagingError.messageTooLarge(length)
        }
        let payloadEnd = base + 4 + length
        guard payloadEnd <= framedData.endIndex else {
            throw NativeMessagingError.truncatedPayload
        }
        let payload = Data(framedData[(base + 4)..<payloadEnd])
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw NativeMessagingError.invalidJSON
        }
    }

    /// Reads a single 4-byte little-endian length-prefixed Native Messaging payload.
    /// Returns `nil` on clean EOF before the first byte of the length header.
    public static func readFramedPayload(
        readExactBytes: (Int) throws -> Data?
    ) throws -> Data? {
        guard let lengthHeader = try readExactBytes(4) else {
            return nil
        }
        guard lengthHeader.count == 4 else {
            throw NativeMessagingError.truncatedLengthPrefix
        }
        let base = lengthHeader.startIndex
        let length =
            Int(lengthHeader[base])
            | (Int(lengthHeader[base + 1]) << 8)
            | (Int(lengthHeader[base + 2]) << 16)
            | (Int(lengthHeader[base + 3]) << 24)
        guard length > 0 else {
            throw NativeMessagingError.emptyMessage
        }
        guard length <= Self.maxMessageBytes else {
            throw NativeMessagingError.messageTooLarge(length)
        }
        guard let payload = try readExactBytes(length), payload.count == length else {
            throw NativeMessagingError.truncatedPayload
        }
        return payload
    }
}

public enum BridgeSecurity {
    /// Constant-time UTF-8 string comparison for 32-byte hex authentication tokens.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard !rhsBytes.isEmpty else {
            return lhsBytes.isEmpty
        }
        var diff: UInt8 = lhsBytes.count == rhsBytes.count ? 0 : 1
        let rhsCount = rhsBytes.count
        let iterations = max(lhsBytes.count, rhsCount)
        for index in 0..<iterations {
            let leftByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rightByte = rhsBytes[index % rhsCount]
            diff |= (leftByte ^ rightByte)
        }
        return diff == 0
    }

    public static func isAllowedExtensionOrigin(_ origin: String?) -> Bool {
        guard let origin else { return false }
        return origin == BridgeConstants.expectedExtensionOrigin
    }
}

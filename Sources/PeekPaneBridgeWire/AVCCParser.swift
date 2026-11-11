import Foundation

public enum AVCCParseError: Error, Equatable, Sendable {
    case truncatedRecord
    case unsupportedConfigurationVersion(UInt8)
    case unsupportedNALUnitLength(Int)
    case emptySPSList
    case truncatedSPS
    case emptySPSNALU
    case missingPPSCount
    case emptyPPSList
    case truncatedPPS
    case emptyPPSNALU
}

/// Parsed ISO/IEC 14496-15 `AVCDecoderConfigurationRecord` (`avcC` payload).
public struct ParsedAVCCConfig: Equatable, Sendable {
    public let profileIndication: UInt8
    public let profileCompatibility: UInt8
    public let levelIndication: UInt8
    public let nalUnitLengthByteCount: Int
    public let spsList: [Data]
    public let ppsList: [Data]

    public static func parse(from data: Data) throws -> Self {
        guard data.count >= 7 else {
            throw AVCCParseError.truncatedRecord
        }
        let bytes = [UInt8](data)
        let configVersion = bytes[0]
        guard configVersion == 1 else {
            throw AVCCParseError.unsupportedConfigurationVersion(configVersion)
        }

        let profileIndication = bytes[1]
        let profileCompatibility = bytes[2]
        let levelIndication = bytes[3]
        let nalUnitLengthByteCount = Int(bytes[4] & 0x03) + 1
        guard nalUnitLengthByteCount == 1 || nalUnitLengthByteCount == 2 || nalUnitLengthByteCount == 4 else {
            throw AVCCParseError.unsupportedNALUnitLength(nalUnitLengthByteCount)
        }

        let spsCount = Int(bytes[5] & 0x1F)
        guard spsCount > 0 else {
            throw AVCCParseError.emptySPSList
        }

        var cursor = 6
        let spsList = try readParameterSetArray(
            from: bytes,
            cursor: &cursor,
            count: spsCount,
            truncatedError: .truncatedSPS,
            emptyItemError: .emptySPSNALU
        )

        guard cursor < bytes.count else {
            throw AVCCParseError.missingPPSCount
        }
        let ppsCount = Int(bytes[cursor])
        cursor += 1
        guard ppsCount > 0 else {
            throw AVCCParseError.emptyPPSList
        }

        let ppsList = try readParameterSetArray(
            from: bytes,
            cursor: &cursor,
            count: ppsCount,
            truncatedError: .truncatedPPS,
            emptyItemError: .emptyPPSNALU
        )

        return Self(
            profileIndication: profileIndication,
            profileCompatibility: profileCompatibility,
            levelIndication: levelIndication,
            nalUnitLengthByteCount: nalUnitLengthByteCount,
            spsList: spsList,
            ppsList: ppsList
        )
    }

    private static func readParameterSetArray(
        from bytes: [UInt8],
        cursor: inout Int,
        count: Int,
        truncatedError: AVCCParseError,
        emptyItemError: AVCCParseError
    ) throws -> [Data] {
        var sets: [Data] = []
        sets.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 2 <= bytes.count else {
                throw truncatedError
            }
            let itemLength = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
            cursor += 2
            guard itemLength > 0 else {
                throw emptyItemError
            }
            guard cursor + itemLength <= bytes.count else {
                throw truncatedError
            }
            sets.append(Data(bytes[cursor..<(cursor + itemLength)]))
            cursor += itemLength
        }
        return sets
    }
}

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

final class JPEGFrameDecoder {
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func decode(jpegData: Data) -> (CVPixelBuffer, IOSurfaceRef)? {
        guard !jpegData.isEmpty,
            let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(
                imageSource,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width >= 16, height >= 16, width <= 8192, height <= 8192,
            let pool = ensurePool(width: width, height: height)
        else {
            return nil
        }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let drewImage: Bool = {
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                return false
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bitmapInfo =
                CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }()

        guard drewImage, let surfaceUnmanaged = CVPixelBufferGetIOSurface(pixelBuffer) else {
            return nil
        }
        return (pixelBuffer, surfaceUnmanaged.takeUnretainedValue())
    }

    func reset() {
        if let pool = pixelBufferPool {
            CVPixelBufferPoolFlush(pool, [])
        }
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let existing = pixelBufferPool, poolWidth == width, poolHeight == height {
            return existing
        }
        reset()

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3
        ]
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &newPool
        )
        guard status == kCVReturnSuccess, let newPool else {
            return nil
        }
        pixelBufferPool = newPool
        poolWidth = width
        poolHeight = height
        return newPool
    }
}

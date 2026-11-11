import CoreGraphics
import CoreVideo

struct CaptureFramePayload: @unchecked Sendable {
    static let fullActiveRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    let pixelBuffer: CVPixelBuffer
    let surface: IOSurfaceRef
    let contentPointSize: CGSize
    let activeContentNormalizedRect: CGRect

    init(
        pixelBuffer: CVPixelBuffer,
        surface: IOSurfaceRef,
        contentPointSize: CGSize,
        activeContentNormalizedRect: CGRect = Self.fullActiveRect
    ) {
        self.pixelBuffer = pixelBuffer
        self.surface = surface
        self.contentPointSize = contentPointSize
        self.activeContentNormalizedRect = activeContentNormalizedRect
    }
}

typealias CaptureStreamStateHandler =
    @MainActor (_ isStreaming: Bool, _ isMinimized: Bool, _ isClosed: Bool, _ errorText: String?) -> Void

protocol CaptureStreamEngine: AnyObject {
    @MainActor var onFrame: (@MainActor (CaptureFramePayload) -> Void)? { get set }
    @MainActor var onInitialImage: (@MainActor (CGImage, CGSize) -> Void)? { get set }
    @MainActor var onStateChange: CaptureStreamStateHandler? { get set }

    @MainActor func start(showsCursor: Bool) async
    @MainActor func updateShowsCursor(_ show: Bool) async
    @MainActor func stop() async
}

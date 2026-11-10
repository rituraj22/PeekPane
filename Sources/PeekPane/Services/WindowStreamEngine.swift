import AppKit
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
@preconcurrency import ScreenCaptureKit
import os

final class WindowStreamEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct FramePayload: @unchecked Sendable {
        let surface: IOSurfaceRef
        let contentPointSize: CGSize
    }

    private struct PendingFrameState: @unchecked Sendable {
        var latestPayload: FramePayload?
        var isDeliveryScheduled: Bool = false
    }

    private let sampleQueue: DispatchQueue
    private let frameLock = OSAllocatedUnfairLock(initialState: PendingFrameState())
    private var stream: SCStream?
    private var currentWindow: SCWindow
    private var lastConfiguredSize: CGSize
    private var showsCursor: Bool = false
    private var monitorTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var isStopped: Bool = false

    var onFrame: (@MainActor (FramePayload) -> Void)?
    var onInitialImage: (@MainActor (CGImage, CGSize) -> Void)?
    var onStateChange:
        (@MainActor (_ isStreaming: Bool, _ isMinimized: Bool, _ isClosed: Bool, _ errorText: String?) -> Void)?

    init(scWindow: SCWindow) {
        self.currentWindow = scWindow
        self.lastConfiguredSize = scWindow.frame.size
        self.sampleQueue = DispatchQueue(
            label: "com.peekpane.stream.\(scWindow.windowID)",
            qos: .userInteractive
        )
        super.init()
    }

    deinit {
        monitorTask?.cancel()
        frameLock.withLock { state in
            state.latestPayload = nil
            state.isDeliveryScheduled = false
        }
        if let activeStream = stream {
            try? activeStream.removeStreamOutput(self, type: .screen)
            Task {
                try? await activeStream.stopCapture()
            }
        }
    }

    @MainActor
    func start(showsCursor: Bool = false) async {
        await stopActiveStreamOnly()
        self.isStopped = false
        self.lifecycleGeneration &+= 1
        let generation = self.lifecycleGeneration
        self.showsCursor = showsCursor

        // Refresh window reference so frame size is current even if window was recently resized
        if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
            let freshWindow = content.windows.first(where: { $0.windowID == currentWindow.windowID })
        {
            self.currentWindow = freshWindow
        }

        guard !isStopped, lifecycleGeneration == generation, !Task.isCancelled else { return }

        let window = self.currentWindow
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = Self.makeStreamConfig(for: window.frame.size, showsCursor: showsCursor)
        self.lastConfiguredSize = window.frame.size

        // Capture an immediate initial frame so the floating window renders right away even if the target window is static
        if let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
            guard !isStopped, lifecycleGeneration == generation, !Task.isCancelled else { return }
            onInitialImage?(cgImage, window.frame.size)
        }

        guard !isStopped, lifecycleGeneration == generation, !Task.isCancelled else { return }

        do {
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()

            guard !isStopped, lifecycleGeneration == generation, !Task.isCancelled else {
                try? newStream.removeStreamOutput(self, type: .screen)
                try? await newStream.stopCapture()
                return
            }

            self.stream = newStream
            onStateChange?(true, !window.isOnScreen, false, nil)
            startWindowMonitor()
        } catch {
            guard !isStopped, lifecycleGeneration == generation else { return }
            onStateChange?(false, !window.isOnScreen, false, error.localizedDescription)
        }
    }

    @MainActor
    func updateShowsCursor(_ show: Bool) async {
        guard showsCursor != show else { return }
        showsCursor = show
        guard !isStopped, let stream else { return }
        let config = Self.makeStreamConfig(for: lastConfiguredSize, showsCursor: show)
        try? await stream.updateConfiguration(config)
    }

    @MainActor
    private func stopActiveStreamOnly() async {
        monitorTask?.cancel()
        monitorTask = nil
        frameLock.withLock { state in
            state.latestPayload = nil
            state.isDeliveryScheduled = false
        }
        if let activeStream = stream {
            stream = nil
            try? activeStream.removeStreamOutput(self, type: .screen)
            try? await activeStream.stopCapture()
        }
    }

    @MainActor
    func stop() async {
        isStopped = true
        lifecycleGeneration &+= 1
        onFrame = nil
        onInitialImage = nil
        onStateChange = nil
        await stopActiveStreamOnly()
    }

    private static func makeStreamConfig(for pointSize: CGSize, showsCursor: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale: CGFloat = 2.0
        let maxDim: CGFloat = 3840
        let rawW = max(64, pointSize.width * scale)
        let rawH = max(64, pointSize.height * scale)
        let clampScale = min(1.0, maxDim / max(rawW, rawH))
        config.width = max(64, Int(round(rawW * clampScale)))
        config.height = max(64, Int(round(rawH * clampScale)))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.captureResolution = .best
        return config
    }

    @MainActor
    private func startWindowMonitor() {
        monitorTask?.cancel()
        let targetWindowID = currentWindow.windowID
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, !self.isStopped else { break }
                await self.checkTargetWindowStatus(windowID: targetWindowID)
            }
        }
    }

    @MainActor
    private func checkTargetWindowStatus(windowID: CGWindowID) async {
        guard !isStopped else { return }

        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let entry = infoList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID })
        else {
            await handleSourceWindowClosed()
            return
        }

        let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
        if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict),
            bounds.width >= 1, bounds.height >= 1
        {
            let newSize = bounds.size
            if abs(newSize.width - lastConfiguredSize.width) > 2 || abs(newSize.height - lastConfiguredSize.height) > 2
            {
                lastConfiguredSize = newSize
                if let stream {
                    let newConfig = Self.makeStreamConfig(for: newSize, showsCursor: showsCursor)
                    try? await stream.updateConfiguration(newConfig)
                }
            }
        }

        onStateChange?(stream != nil, !isOnScreen, false, nil)
    }

    @MainActor
    private func handleSourceWindowClosed() async {
        guard !isStopped else { return }
        await stopActiveStreamOnly()
        onStateChange?(false, false, true, "Source window was closed")
    }

    @MainActor
    private func drainPendingFrame() {
        let payload = frameLock.withLock { state -> FramePayload? in
            let p = state.latestPayload
            state.latestPayload = nil
            state.isDeliveryScheduled = false
            return p
        }
        guard !isStopped, let payload else { return }
        onFrame?(payload)
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first,
            let statusRaw = attachments[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw)
        else {
            return
        }

        if status == .stopped {
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                await self.checkTargetWindowStatus(windowID: self.currentWindow.windowID)
            }
            return
        }

        guard status == .complete || status == .started else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let surfaceUnmanaged = CVPixelBufferGetIOSurface(pixelBuffer)
        else {
            return
        }

        let surface = surfaceUnmanaged.takeUnretainedValue()
        let surfaceWidth = CGFloat(IOSurfaceGetWidth(surface))
        let surfaceHeight = CGFloat(IOSurfaceGetHeight(surface))
        guard surfaceWidth > 0, surfaceHeight > 0 else { return }

        var pointSize = CGSize(width: surfaceWidth * 0.5, height: surfaceHeight * 0.5)
        if let contentRectDict = attachments[.contentRect] as? NSDictionary,
            let contentRect = CGRect(dictionaryRepresentation: contentRectDict),
            contentRect.width > 0, contentRect.height > 0
        {
            pointSize = contentRect.size
        }

        let payload = FramePayload(
            surface: surface,
            contentPointSize: pointSize
        )

        let shouldSchedule = frameLock.withLock { state -> Bool in
            state.latestPayload = payload
            if state.isDeliveryScheduled {
                return false
            }
            state.isDeliveryScheduled = true
            return true
        }

        if shouldSchedule {
            Task { @MainActor [weak self] in
                self?.drainPendingFrame()
            }
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, !self.isStopped else { return }
            let windowID = self.currentWindow.windowID
            let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
            let stillExists =
                infoList?.contains(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) ?? false
            await self.stopActiveStreamOnly()
            if !stillExists {
                self.onStateChange?(false, false, true, "Source window was closed")
            } else {
                self.onStateChange?(false, false, false, message)
            }
        }
    }
}

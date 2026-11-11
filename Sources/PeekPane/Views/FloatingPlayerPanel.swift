import AppKit
import ApplicationServices
import Combine

// MARK: - Floating Player Session

@MainActor
final class FloatingPlayerSession: ObservableObject, Identifiable {
    nonisolated static let minPanelWidth: CGFloat = 168
    nonisolated static let minPanelHeight: CGFloat = 98

    let id = UUID()
    @Published var windowItem: ShareableWindowItem
    var cropRect: NormalizedCropRect
    @Published var opacity: Double = 1.0 {
        didSet {
            guard abs(opacity - oldValue) > 0.0001 else { return }
            panel?.alphaValue = CGFloat(opacity)
            surfaceView?.updateOpacitySlider(opacity)
        }
    }
    @Published var isClickThrough: Bool = false {
        didSet {
            guard isClickThrough != oldValue else { return }
            if isClickThrough {
                setupModifierMonitors()
            } else {
                removeModifierMonitors()
                if isOptionKeyPressed {
                    isOptionKeyPressed = false
                }
            }
            surfaceView?.isClickThrough = isClickThrough
            updatePanelMouseIgnoreState()
        }
    }
    @Published var isOptionKeyPressed: Bool = false {
        didSet {
            guard isOptionKeyPressed != oldValue else { return }
            surfaceView?.isOptionKeyPressed = isOptionKeyPressed
            updatePanelMouseIgnoreState()
        }
    }
    @Published var isAdjustingCrop: Bool = false {
        didSet {
            guard isAdjustingCrop != oldValue else { return }
            surfaceView?.isAdjustingCrop = isAdjustingCrop
            guard let panel else { return }
            if isAdjustingCrop {
                panel.resizeIncrements = NSSize(width: 1, height: 1)
                panel.minSize = NSSize(width: Self.minPanelWidth, height: Self.minPanelHeight)
                updateCropModeMaxSize()
            } else {
                panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                let currentSize = panel.frame.size
                if currentSize.width > 10 && currentSize.height > 10 {
                    let aspect = max(0.15, currentSize.width / max(1, currentSize.height))
                    let minW = max(Self.minPanelWidth, Self.minPanelHeight * aspect)
                    let minH = max(Self.minPanelHeight, minW / aspect)
                    panel.minSize = NSSize(width: minW, height: minH)
                    panel.contentAspectRatio = currentSize
                }
            }
        }
    }

    fileprivate var resizeInitialFrame: NSRect = .zero
    fileprivate var resizeInitialCrop: NormalizedCropRect = .full

    @Published var showsCursor: Bool = false {
        didSet {
            guard showsCursor != oldValue else { return }
            Task { await streamEngine.updateShowsCursor(showsCursor) }
        }
    }
    @Published var isHovered: Bool = false
    @Published var isShowingWindowPicker: Bool = false {
        didSet {
            guard isShowingWindowPicker != oldValue else { return }
            surfaceView?.isShowingWindowPicker = isShowingWindowPicker
        }
    }
    @Published var isStreaming: Bool = false
    @Published var isSourceMinimized: Bool = false
    @Published var isSourceClosed: Bool = false {
        didSet {
            guard isSourceClosed != oldValue else { return }
            surfaceView?.isSourceClosed = isSourceClosed
        }
    }
    @Published var streamError: String?

    private var streamEngine: WindowStreamEngine
    private weak var surfaceView: VideoSurfaceNSView?
    private(set) var panel: FloatingPlayerPanel?
    private var latestSourcePointSize: CGSize
    nonisolated(unsafe) private var globalFlagsMonitor: Any?
    nonisolated(unsafe) private var localFlagsMonitor: Any?
    private var isClosed: Bool = false

    var onClose: ((UUID) -> Void)?
    var onRequestRechooseWindow: ((FloatingPlayerSession) -> Void)?

    init(windowItem: ShareableWindowItem, cropRect: NormalizedCropRect) {
        self.windowItem = windowItem
        self.cropRect = cropRect.clamped()
        self.latestSourcePointSize = windowItem.frame.size
        self.streamEngine = WindowStreamEngine(scWindow: windowItem.scWindow)

        setupStreamCallbacks()
    }

    deinit {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
        }
    }

    private func setupModifierMonitors() {
        guard globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }
        let currentOpt = NSEvent.modifierFlags.contains(.option)
        if isOptionKeyPressed != currentOpt {
            isOptionKeyPressed = currentOpt
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let opt = event.modifierFlags.contains(.option)
            Task { @MainActor [weak self] in
                guard let self, self.isOptionKeyPressed != opt else { return }
                self.isOptionKeyPressed = opt
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let opt = event.modifierFlags.contains(.option)
            Task { @MainActor [weak self] in
                guard let self, self.isOptionKeyPressed != opt else { return }
                self.isOptionKeyPressed = opt
            }
            return event
        }
    }

    private func removeModifierMonitors() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
    }

    private func updatePanelMouseIgnoreState() {
        panel?.ignoresMouseEvents = isClickThrough && !isOptionKeyPressed
    }

    private func setupStreamCallbacks() {
        streamEngine.onInitialImage = { [weak self] cgImage, pointSize in
            guard let self, !self.isClosed else { return }
            self.latestSourcePointSize = pointSize
            self.surfaceView?.updateInitialImage(cgImage, crop: self.cropRect)
        }

        streamEngine.onFrame = { [weak self] payload in
            guard let self, !self.isClosed else { return }
            self.latestSourcePointSize = payload.contentPointSize
            self.surfaceView?.updateFrame(payload, crop: self.cropRect)
        }

        streamEngine.onStateChange = { [weak self] isStreaming, isMinimized, isClosed, errorText in
            guard let self, !self.isClosed else { return }
            if self.isStreaming != isStreaming {
                self.isStreaming = isStreaming
            }
            if self.isSourceMinimized != isMinimized {
                self.isSourceMinimized = isMinimized
            }
            if self.isSourceClosed != isClosed {
                self.isSourceClosed = isClosed
            }
            if self.streamError != errorText {
                self.streamError = errorText
            }
        }
    }

    func attachSurfaceView(_ view: VideoSurfaceNSView) {
        self.surfaceView = view
        view.isAdjustingCrop = isAdjustingCrop
        view.isClickThrough = isClickThrough
        view.isOptionKeyPressed = isOptionKeyPressed
        view.isShowingWindowPicker = isShowingWindowPicker
        view.isSourceClosed = isSourceClosed
        view.configureHUDActions(session: self)
        view.onPanCrop = { [weak self] dx, dy in
            guard let self else { return }
            self.updateCropRect(self.cropRect.panned(dx: dx, dy: dy), resizeWindow: false)
        }
        view.onZoomCrop = { [weak self] scaleFactor in
            guard let self else { return }
            self.updateCropRect(self.cropRect.zoomed(by: scaleFactor), resizeWindow: false)
        }
        view.onBeginResize = { [weak self] in
            self?.beginInteractiveResize()
        }
        view.onUpdateResize = { [weak self] edge, dx, dy in
            self?.updateInteractiveResize(edge: edge, dx: dx, dy: dy)
        }
        view.onHoverChange = { [weak self] hovering in
            guard let self, self.isHovered != hovering else { return }
            self.isHovered = hovering
        }
        view.updateCrop(cropRect)
        Task { [weak self] in
            guard let self, !self.isClosed else { return }
            await self.streamEngine.start(showsCursor: self.showsCursor)
        }
    }

    func switchTargetWindow(_ newWindowItem: ShareableWindowItem, newCrop: NormalizedCropRect) {
        guard !isClosed else { return }
        let oldEngine = self.streamEngine
        oldEngine.onInitialImage = nil
        oldEngine.onFrame = nil
        oldEngine.onStateChange = nil

        if isAdjustingCrop {
            isAdjustingCrop = false
        }
        self.windowItem = newWindowItem
        self.latestSourcePointSize = newWindowItem.frame.size
        surfaceView?.updateGoButtonTargetAppName(newWindowItem.appName)
        if self.isSourceClosed {
            self.isSourceClosed = false
        }
        let newEngine = WindowStreamEngine(scWindow: newWindowItem.scWindow)
        self.streamEngine = newEngine
        setupStreamCallbacks()
        updateCropRect(newCrop, resizeWindow: true)

        Task { [weak self] in
            await oldEngine.stop()
            guard let self, !self.isClosed, self.streamEngine === newEngine else {
                await newEngine.stop()
                return
            }
            await newEngine.start(showsCursor: self.showsCursor)
        }
    }

    func activateSourceApp() {
        let pid = windowItem.processID
        let targetWindowID = windowItem.windowID
        let bundleID = windowItem.bundleIdentifier
        let runningApp =
            (pid != 0 ? NSRunningApplication(processIdentifier: pid) : nil)
            ?? (bundleID.isEmpty
                ? nil
                : NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first)

        let snapshot = WindowFocusHelper.inspectTargetWindow(
            pid: pid,
            windowID: targetWindowID,
            fallbackTitle: windowItem.title,
            fallbackFrame: windowItem.frame
        )

        if !AXIsProcessTrusted() && snapshot.totalAppWindows > 1 {
            WindowFocusHelper.resetStaleAccessibilityTCCEntry()
            let promptOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(promptOptions)
        }

        if let runningApp {
            if runningApp.isHidden {
                runningApp.unhide()
            }

            let raisedAX = WindowFocusHelper.raiseSpecificAXWindow(
                pid: pid,
                snapshot: snapshot
            )

            // rawValue 3 = [.activateAllWindows, .activateIgnoringOtherApps], bringing windows on all displays forward
            // When AX already raised the exact window, rawValue 2 (.activateIgnoringOtherApps) focuses only that window
            let activationBits: UInt = raisedAX ? 2 : 3
            _ = runningApp.activate(options: NSApplication.ActivationOptions(rawValue: activationBits))

            _ = WindowFocusHelper.raiseSpecificAXWindow(pid: pid, snapshot: snapshot)

            if isSourceMinimized && !raisedAX, let bundleURL = runningApp.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: config, completionHandler: nil)
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                _ = WindowFocusHelper.raiseSpecificAXWindow(pid: pid, snapshot: snapshot)
            }
        } else if !bundleID.isEmpty,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }

    func showFloatingPanel(initialScreenRect: CGRect? = nil) {
        let nativeCropSize = cropRect.pixelOrPointSize(for: latestSourcePointSize)

        let startFrame: NSRect
        if let rect = initialScreenRect {
            let targetSize = Self.reasonableInitialPanelSize(
                for: rect.size, maxW: 960, maxH: 760, minW: Self.minPanelWidth)
            startFrame = NSRect(
                x: rect.midX - targetSize.width * 0.5,
                y: rect.midY - targetSize.height * 0.5,
                width: targetSize.width,
                height: targetSize.height
            )
        } else {
            let clampedSize = Self.reasonableInitialPanelSize(for: nativeCropSize)
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1440, height: 900)
            startFrame = NSRect(
                x: screenFrame.maxX - clampedSize.width - 36,
                y: screenFrame.minY + 48,
                width: clampedSize.width,
                height: clampedSize.height
            )
        }

        let floatingPanel = FloatingPlayerPanel(
            contentRect: startFrame,
            session: self
        )
        let aspect = max(0.15, nativeCropSize.width / max(1, nativeCropSize.height))
        let minW = max(Self.minPanelWidth, Self.minPanelHeight * aspect)
        let minH = max(Self.minPanelHeight, minW / aspect)
        floatingPanel.contentAspectRatio = nativeCropSize
        floatingPanel.minSize = NSSize(width: minW, height: minH)
        self.panel = floatingPanel
        floatingPanel.orderFrontRegardless()
    }

    func updateCropRect(_ newCrop: NormalizedCropRect, resizeWindow: Bool = true) {
        let clamped = newCrop.clamped()
        self.cropRect = clamped
        surfaceView?.updateCrop(clamped)

        guard let panel else { return }
        if isAdjustingCrop {
            updateCropModeMaxSize()
        } else {
            let newAspectSize = clamped.pixelOrPointSize(for: latestSourcePointSize)
            let aspect = max(0.15, newAspectSize.width / max(1, newAspectSize.height))
            let minW = max(Self.minPanelWidth, Self.minPanelHeight * aspect)
            let minH = max(Self.minPanelHeight, minW / aspect)
            panel.minSize = NSSize(width: minW, height: minH)
            panel.contentAspectRatio = newAspectSize

            if resizeWindow {
                var frame = panel.frame
                let currentWidth = max(minW, frame.width)
                let newHeight = max(minH, currentWidth / aspect)
                frame.origin.y += (frame.height - newHeight)
                frame.size = NSSize(width: currentWidth, height: newHeight)
                panel.setProgrammaticFrame(frame, animate: false)
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        removeModifierMonitors()

        let engine = streamEngine
        engine.onInitialImage = nil
        engine.onFrame = nil
        engine.onStateChange = nil
        Task {
            await engine.stop()
        }

        surfaceView?.tearDown()
        surfaceView = nil

        if let activePanel = panel {
            panel = nil
            activePanel.orderOut(nil)
            activePanel.close()
        }

        let closeHandler = onClose
        onClose = nil
        onRequestRechooseWindow = nil
        closeHandler?(id)
    }

    private func updateCropModeMaxSize() {
        guard isAdjustingCrop, let panel else { return }
        let c = cropRect.clamped()
        let maxW = max(Self.minPanelWidth, panel.frame.width / max(0.01, c.width))
        let maxH = max(Self.minPanelHeight, panel.frame.height / max(0.01, c.height))
        panel.maxSize = NSSize(width: maxW, height: maxH)
    }

    private static func reasonableInitialPanelSize(
        for nativeSize: CGSize,
        maxW: CGFloat = 680,
        maxH: CGFloat = 520,
        minW: CGFloat = FloatingPlayerSession.minPanelWidth
    ) -> CGSize {
        let aspect = max(0.15, min(6.0, nativeSize.width / max(1, nativeSize.height)))
        var w = nativeSize.width
        var h = nativeSize.height

        if w > maxW {
            w = maxW
            h = w / aspect
        }
        if h > maxH {
            h = maxH
            w = h * aspect
        }
        let effectiveMinW = max(minW, Self.minPanelHeight * aspect)
        if w < effectiveMinW {
            w = effectiveMinW
            h = w / aspect
        }
        if h < Self.minPanelHeight {
            h = Self.minPanelHeight
            w = h * aspect
        }
        return CGSize(width: round(w), height: round(h))
    }
}

// MARK: - FloatingPlayerSession + Interactive Resize

extension FloatingPlayerSession {
    func beginInteractiveResize() {
        guard let panel else { return }
        resizeInitialFrame = panel.frame
        resizeInitialCrop = cropRect.clamped()
    }

    func updateInteractiveResize(edge: FloatingResizeEdge, dx: CGFloat, dy: CGFloat) {
        guard let panel, resizeInitialFrame.width > 10, resizeInitialFrame.height > 10 else { return }
        let initialFrame = resizeInitialFrame

        if isAdjustingCrop {
            updateCropInteractiveResize(edge: edge, dx: dx, dy: dy, initialFrame: initialFrame, panel: panel)
        } else {
            updateAspectInteractiveResize(edge: edge, dx: dx, dy: dy, initialFrame: initialFrame, panel: panel)
        }
    }

    fileprivate func updateCropInteractiveResize(
        edge: FloatingResizeEdge,
        dx: CGFloat,
        dy: CGFloat,
        initialFrame: NSRect,
        panel: FloatingPlayerPanel
    ) {
        let initialCrop = resizeInitialCrop
        let virtualFullWidth = max(1, initialFrame.width / initialCrop.width)
        let virtualFullHeight = max(1, initialFrame.height / initialCrop.height)
        let virtualMinX = initialFrame.minX - initialCrop.x * virtualFullWidth
        let virtualMaxX = virtualMinX + virtualFullWidth
        let virtualMaxY = initialFrame.maxY + initialCrop.y * virtualFullHeight
        let virtualMinY = virtualMaxY - virtualFullHeight

        let minW: CGFloat = Self.minPanelWidth
        let minH: CGFloat = Self.minPanelHeight

        var newMinX = initialFrame.minX
        var newMaxX = initialFrame.maxX
        var newMinY = initialFrame.minY
        var newMaxY = initialFrame.maxY

        switch edge {
        case .left, .topLeft, .bottomLeft:
            newMinX = max(virtualMinX, min(initialFrame.maxX - minW, initialFrame.minX + dx))
        case .right, .topRight, .bottomRight:
            newMaxX = min(virtualMaxX, max(initialFrame.minX + minW, initialFrame.maxX + dx))
        case .top, .bottom:
            break
        }

        switch edge {
        case .top, .topLeft, .topRight:
            newMaxY = min(virtualMaxY, max(initialFrame.minY + minH, initialFrame.maxY + dy))
        case .bottom, .bottomLeft, .bottomRight:
            newMinY = max(virtualMinY, min(initialFrame.maxY - minH, initialFrame.minY + dy))
        case .left, .right:
            break
        }

        let newFrame = NSRect(
            x: newMinX,
            y: newMinY,
            width: max(minW, newMaxX - newMinX),
            height: max(minH, newMaxY - newMinY)
        )
        let newCrop = NormalizedCropRect(
            x: (newFrame.minX - virtualMinX) / virtualFullWidth,
            y: (virtualMaxY - newFrame.maxY) / virtualFullHeight,
            width: newFrame.width / virtualFullWidth,
            height: newFrame.height / virtualFullHeight
        ).clamped()

        self.cropRect = newCrop
        surfaceView?.updateCrop(newCrop)
        panel.setProgrammaticFrame(newFrame, animate: false)
    }

    fileprivate func updateAspectInteractiveResize(
        edge: FloatingResizeEdge,
        dx: CGFloat,
        dy: CGFloat,
        initialFrame: NSRect,
        panel: FloatingPlayerPanel
    ) {
        let aspect = max(0.15, initialFrame.width / max(1, initialFrame.height))
        let minW: CGFloat = max(Self.minPanelWidth, Self.minPanelHeight * aspect)
        let minH: CGFloat = max(Self.minPanelHeight, minW / aspect)
        let newFrame: NSRect

        switch edge {
        case .right:
            let w = max(minW, initialFrame.width + dx)
            let h = max(minH, w / aspect)
            newFrame = NSRect(x: initialFrame.minX, y: initialFrame.midY - h * 0.5, width: w, height: h)
        case .left:
            let w = max(minW, initialFrame.width - dx)
            let h = max(minH, w / aspect)
            newFrame = NSRect(x: initialFrame.maxX - w, y: initialFrame.midY - h * 0.5, width: w, height: h)
        case .top:
            let h = max(minH, initialFrame.height + dy)
            let w = max(minW, h * aspect)
            newFrame = NSRect(x: initialFrame.midX - w * 0.5, y: initialFrame.minY, width: w, height: h)
        case .bottom:
            let h = max(minH, initialFrame.height - dy)
            let w = max(minW, h * aspect)
            newFrame = NSRect(x: initialFrame.midX - w * 0.5, y: initialFrame.maxY - h, width: w, height: h)
        case .topRight:
            let wFromX = initialFrame.width + dx
            let wFromY = (initialFrame.height + dy) * aspect
            let w = max(minW, abs(dx) >= abs(dy) ? wFromX : wFromY)
            let h = max(minH, w / aspect)
            newFrame = NSRect(x: initialFrame.minX, y: initialFrame.minY, width: w, height: h)
        case .bottomRight:
            let wFromX = initialFrame.width + dx
            let wFromY = (initialFrame.height - dy) * aspect
            let w = max(minW, abs(dx) >= abs(dy) ? wFromX : wFromY)
            let h = max(minH, w / aspect)
            newFrame = NSRect(x: initialFrame.minX, y: initialFrame.maxY - h, width: w, height: h)
        case .topLeft:
            let wFromX = initialFrame.width - dx
            let wFromY = (initialFrame.height + dy) * aspect
            let w = max(minW, abs(dx) >= abs(dy) ? wFromX : wFromY)
            let h = max(minH, w / aspect)
            newFrame = NSRect(x: initialFrame.maxX - w, y: initialFrame.minY, width: w, height: h)
        case .bottomLeft:
            let wFromX = initialFrame.width - dx
            let wFromY = (initialFrame.height - dy) * aspect
            let w = max(minW, abs(dx) >= abs(dy) ? wFromX : wFromY)
            let h = max(minH, w / aspect)
            newFrame = NSRect(x: initialFrame.maxX - w, y: initialFrame.maxY - h, width: w, height: h)
        }

        panel.setProgrammaticFrame(newFrame, animate: false)
    }
}

// MARK: - Floating NSPanel Subclass (Pure AppKit ContentView)

final class FloatingPlayerPanel: NSPanel {
    private weak var session: FloatingPlayerSession?

    init(contentRect: NSRect, session: FloatingPlayerSession) {
        self.session = session
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.isExcludedFromWindowsMenu = true
        self.isMovableByWindowBackground = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.setAccessibilitySubrole(.floatingWindow)

        let surfaceView = VideoSurfaceNSView(frame: NSRect(origin: .zero, size: contentRect.size))
        surfaceView.autoresizingMask = [.width, .height]
        self.contentView = surfaceView
        session.attachSurfaceView(surfaceView)
    }

    func setProgrammaticFrame(_ frame: NSRect, animate: Bool = false) {
        setFrame(frame, display: true, animate: animate)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

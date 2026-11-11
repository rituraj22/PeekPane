import AppKit
import CoreVideo
import QuartzCore

// MARK: - GPU Video Surface & Root Container NSView (Zero NSHostingView / Zero Auto Layout)

final class VideoSurfaceNSView: NSView {
    private let videoLayer = CALayer()
    private let borderLayer = CALayer()
    private let topHUDBar = FloatingHUDTopBarView(frame: .zero)
    private let bottomCropPill = PassthroughVisualEffectPill(frame: .zero)
    private let goToAppButton = HUDGoToAppButton(frame: .zero)
    private let closedBanner = ClosedSourceBannerView(frame: .zero)

    private var currentCropRect: NormalizedCropRect = .full
    private var currentPixelBuffer: CVPixelBuffer?
    private var currentActiveContentRect = CaptureFramePayload.fullActiveRect

    var onPanCrop: ((CGFloat, CGFloat) -> Void)?
    var onZoomCrop: ((CGFloat) -> Void)?
    var onBeginResize: (() -> Void)?
    var onUpdateResize: ((FloatingResizeEdge, CGFloat, CGFloat) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    var isAdjustingCrop: Bool = false {
        didSet {
            if isAdjustingCrop != oldValue {
                syncHUDState()
                scheduleCropPillFadeIfNeeded()
            }
        }
    }
    var isHovered: Bool = false {
        didSet {
            if isHovered != oldValue {
                syncHUDState()
            }
        }
    }
    var isShowingWindowPicker: Bool = false {
        didSet {
            if isShowingWindowPicker != oldValue {
                syncHUDState()
            }
        }
    }
    var isClickThrough: Bool = false {
        didSet {
            if isClickThrough != oldValue {
                refreshHoverFromCurrentMousePosition()
                syncHUDState()
            }
        }
    }
    var isOptionKeyPressed: Bool = false {
        didSet {
            if isOptionKeyPressed != oldValue {
                refreshHoverFromCurrentMousePosition()
                syncHUDState()
            }
        }
    }
    var isSourceClosed: Bool = false {
        didSet {
            if isSourceClosed != oldValue {
                syncHUDState()
            }
        }
    }

    private func refreshHoverFromCurrentMousePosition() {
        guard let win = window, activeResizeEdge == nil, !isDraggingWindow else { return }
        let pt = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        let inside = bounds.contains(pt)
        if inside != isHovered {
            isHovered = inside
            onHoverChange?(inside)
        }
    }

    fileprivate enum SurfaceCursorKind: Equatable {
        case arrow
        case openHand
        case closedHand
        case resize(FloatingResizeEdge)
    }

    fileprivate var lastDragLocation: NSPoint?
    fileprivate var isDraggingWindow: Bool = false
    fileprivate var windowDragStartMouseScreen: NSPoint = .zero
    fileprivate var windowDragStartOrigin: NSPoint = .zero
    fileprivate var activeResizeEdge: FloatingResizeEdge?
    fileprivate var resizeStartMouseScreen: NSPoint = .zero
    private var trackingArea: NSTrackingArea?
    fileprivate var currentCursorKind: SurfaceCursorKind = .arrow
    private var cropPillFadeTask: Task<Void, Never>?

    fileprivate let edgeHitThickness: CGFloat = 14
    fileprivate let cornerHitSize: CGFloat = 22

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        videoLayer.contentsGravity = .resize
        videoLayer.magnificationFilter = .trilinear
        videoLayer.minificationFilter = .trilinear
        layer?.addSublayer(videoLayer)

        borderLayer.cornerRadius = 10
        borderLayer.cornerCurve = .continuous
        borderLayer.borderWidth = 1.0
        borderLayer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        borderLayer.zPosition = 100
        layer?.addSublayer(borderLayer)

        addSubview(topHUDBar)
        addSubview(bottomCropPill)
        addSubview(goToAppButton)
        addSubview(closedBanner)

        performManualLayout()
        syncHUDState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateOpacitySlider(_ val: Double) {
        topHUDBar.opacitySlider.doubleValue = val
    }

    func updateGoButtonTargetAppName(_ appName: String) {
        goToAppButton.toolTip = appName.isEmpty ? "Go to source app" : "Go to \(appName)"
    }

    func configureHUDActions(session: FloatingPlayerSession) {
        topHUDBar.opacitySlider.doubleValue = session.opacity
        updateGoButtonTargetAppName(session.source.sourceAppName)
        topHUDBar.refreshButton.actionHandler = { [weak session] in
            guard let session else { return }
            session.onRequestRechooseWindow?(session)
        }
        topHUDBar.cropButton.actionHandler = { [weak session] in
            session?.isAdjustingCrop.toggle()
        }
        topHUDBar.onOpacityChanged = { [weak session] val in
            session?.opacity = val
        }
        topHUDBar.ghostButton.actionHandler = { [weak session] in
            session?.isClickThrough.toggle()
        }
        topHUDBar.closeButton.actionHandler = { [weak session] in
            session?.close()
        }
        goToAppButton.actionHandler = { [weak session] in
            session?.activateSourceApp()
        }
        closedBanner.onRechoose = { [weak session] in
            guard let session else { return }
            session.onRequestRechooseWindow?(session)
        }
        closedBanner.onClose = { [weak session] in
            session?.close()
        }
    }

    deinit {
        cropPillFadeTask?.cancel()
    }

    func tearDown() {
        cropPillFadeTask?.cancel()
        cropPillFadeTask = nil
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = nil
        CATransaction.commit()
        currentPixelBuffer = nil

        onPanCrop = nil
        onZoomCrop = nil
        onBeginResize = nil
        onUpdateResize = nil
        onHoverChange = nil

        topHUDBar.refreshButton.actionHandler = nil
        topHUDBar.cropButton.actionHandler = nil
        topHUDBar.onOpacityChanged = nil
        topHUDBar.ghostButton.actionHandler = nil
        topHUDBar.closeButton.actionHandler = nil
        goToAppButton.actionHandler = nil
        closedBanner.onRechoose = nil
        closedBanner.onClose = nil
    }

    private func scheduleCropPillFadeIfNeeded() {
        cropPillFadeTask?.cancel()
        cropPillFadeTask = nil
        bottomCropPill.alphaValue = 1.0
        guard isAdjustingCrop else { return }

        cropPillFadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.isAdjustingCrop else { return }
            NSAnimationContext.runAnimationGroup(
                { ctx in
                    ctx.duration = 0.35
                    self.bottomCropPill.animator().alphaValue = 0.35
                }, completionHandler: nil)
        }
    }

    func syncHUDState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let showHUD = (isHovered || isShowingWindowPicker) && (!isClickThrough || isOptionKeyPressed)
        topHUDBar.isHidden = !showHUD
        topHUDBar.refreshButton.isActive = isShowingWindowPicker
        topHUDBar.cropButton.isActive = isAdjustingCrop
        topHUDBar.ghostButton.isActive = isClickThrough
        topHUDBar.ghostButton.symbolName = "custom.ghost"

        bottomCropPill.isHidden = !isAdjustingCrop
        goToAppButton.isHidden = !(showHUD && !isAdjustingCrop && !isSourceClosed)
        closedBanner.isHidden = !isSourceClosed

        if isAdjustingCrop {
            borderLayer.borderWidth = 2.5
            borderLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        } else {
            borderLayer.borderWidth = 1.0
            borderLayer.borderColor = NSColor.white.withAlphaComponent(isHovered ? 0.35 : 0.14).cgColor
        }

        CATransaction.commit()

        if isClickThrough && !isOptionKeyPressed {
            applyCursor(.arrow, force: true)
        } else if activeResizeEdge == nil && !isDraggingWindow && lastDragLocation == nil,
            let win = window
        {
            let pt = convert(win.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(pt) {
                applyCursor(resolvedCursor(at: pt), force: true)
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        performManualLayout()
    }

    private func performManualLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCropLayout()
        borderLayer.frame = bounds

        let hudHeight: CGFloat = 36
        let hudMarginX: CGFloat = bounds.width < 200 ? 8 : 14
        let hudMaxW: CGFloat = 290
        let availW = max(120, bounds.width - hudMarginX * 2)
        let hudW = min(hudMaxW, availW)
        topHUDBar.frame = NSRect(
            x: (bounds.width - hudW) * 0.5,
            y: 12,
            width: hudW,
            height: hudHeight
        )

        let pillMaxW = max(140, bounds.width - 20)
        let pillSize = bottomCropPill.sizeToFitContent(maxWidth: pillMaxW)
        bottomCropPill.frame = NSRect(
            x: (bounds.width - pillSize.width) * 0.5,
            y: max(12, bounds.height - pillSize.height - 12),
            width: pillSize.width,
            height: pillSize.height
        )

        let isCompact = bounds.width < 200
        let goBtnW: CGFloat = isCompact ? 50 : 56
        let goBtnH: CGFloat = isCompact ? 25 : 28
        let goMargin: CGFloat = isCompact ? 10 : 12
        goToAppButton.frame = NSRect(
            x: max(goMargin, bounds.width - goBtnW - goMargin),
            y: max(goMargin, bounds.height - goBtnH - goMargin),
            width: goBtnW,
            height: goBtnH
        )

        let bannerW: CGFloat = 190
        let bannerH: CGFloat = 68
        closedBanner.frame = NSRect(
            x: (bounds.width - bannerW) * 0.5,
            y: (bounds.height - bannerH) * 0.5,
            width: bannerW,
            height: bannerH
        )

        CATransaction.commit()
    }

    private func applyCropLayout() {
        let effective = Self.effectiveNormalizedCrop(
            crop: currentCropRect.clamped(),
            activeContent: currentActiveContentRect
        )
        let viewW = max(1, bounds.width)
        let viewH = max(1, bounds.height)
        let fullW = viewW / effective.width
        let fullH = viewH / effective.height
        let targetFrame = CGRect(
            x: -effective.minX * fullW,
            y: -effective.minY * fullH,
            width: fullW,
            height: fullH
        )
        if videoLayer.frame != targetFrame {
            videoLayer.frame = targetFrame
        }
    }

    func updateInitialImage(_ cgImage: CGImage, crop: NormalizedCropRect) {
        currentCropRect = crop
        currentPixelBuffer = nil
        currentActiveContentRect = CaptureFramePayload.fullActiveRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = cgImage
        applyCropLayout()
        CATransaction.commit()
    }

    func updateFrame(_ payload: CaptureFramePayload, crop: NormalizedCropRect) {
        currentCropRect = crop
        currentPixelBuffer = payload.pixelBuffer
        currentActiveContentRect = payload.activeContentNormalizedRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = payload.surface
        applyCropLayout()
        CATransaction.commit()
    }

    func updateCrop(_ crop: NormalizedCropRect) {
        currentCropRect = crop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCropLayout()
        CATransaction.commit()
    }
}

// MARK: - VideoSurfaceNSView + Resize Hit Testing & Events

extension VideoSurfaceNSView {
    static func effectiveNormalizedCrop(crop: NormalizedCropRect, activeContent: CGRect) -> CGRect {
        let activeW = max(0.001, min(1.0, activeContent.width))
        let activeH = max(0.001, min(1.0, activeContent.height))
        let activeX = max(0.0, min(1.0 - activeW, activeContent.minX))
        let activeY = max(0.0, min(1.0 - activeH, activeContent.minY))
        return CGRect(
            x: activeX + crop.x * activeW,
            y: activeY + crop.y * activeH,
            width: max(0.001, crop.width * activeW),
            height: max(0.001, crop.height * activeH)
        )
    }

    // MARK: - Resize Hit Testing & Cursors

    fileprivate func resizeEdge(at pt: NSPoint) -> FloatingResizeEdge? {
        guard bounds.contains(pt) else { return nil }
        let w = bounds.width
        let h = bounds.height

        let inLeftCorner = pt.x <= cornerHitSize
        let inRightCorner = pt.x >= w - cornerHitSize
        let inTopCorner = pt.y <= cornerHitSize
        let inBottomCorner = pt.y >= h - cornerHitSize

        if inLeftCorner && inTopCorner { return .topLeft }
        if inRightCorner && inTopCorner { return .topRight }
        if inLeftCorner && inBottomCorner { return .bottomLeft }
        if inRightCorner && inBottomCorner { return .bottomRight }

        if pt.x <= edgeHitThickness { return .left }
        if pt.x >= w - edgeHitThickness { return .right }
        if pt.y <= edgeHitThickness { return .top }
        if pt.y >= h - edgeHitThickness { return .bottom }
        return nil
    }

    fileprivate func isOverInteractiveOverlay(at pt: NSPoint) -> Bool {
        (!topHUDBar.isHidden && topHUDBar.frame.contains(pt))
            || (!goToAppButton.isHidden && goToAppButton.frame.contains(pt))
            || (!closedBanner.isHidden && closedBanner.frame.contains(pt))
    }

    fileprivate func resolvedCursor(at pt: NSPoint) -> SurfaceCursorKind {
        if (isClickThrough && !isOptionKeyPressed) || !bounds.contains(pt) || isOverInteractiveOverlay(at: pt) {
            return .arrow
        }
        if let edge = resizeEdge(at: pt) {
            return .resize(edge)
        }
        return .openHand
    }

    fileprivate func applyCursor(_ kind: SurfaceCursorKind, force: Bool = false) {
        if !force && currentCursorKind == kind {
            return
        }
        currentCursorKind = kind

        switch kind {
        case .arrow:
            NSCursor.arrow.set()
        case .openHand:
            NSCursor.openHand.set()
        case .closedHand:
            NSCursor.closedHand.set()
        case .resize(let edge):
            switch edge {
            case .left, .right:
                NSCursor.resizeLeftRight.set()
            case .top, .bottom:
                NSCursor.resizeUpDown.set()
            case .topLeft, .bottomRight:
                Self.diagonalNWSECursor.set()
            case .topRight, .bottomLeft:
                Self.diagonalNESWCursor.set()
            }
        }
    }

    static let diagonalNWSECursor: NSCursor = makeDiagonalCursor(nwse: true)
    static let diagonalNESWCursor: NSCursor = makeDiagonalCursor(nwse: false)

    private static func makeDiagonalCursor(nwse: Bool) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 9, y: 9)
            ctx.rotate(by: nwse ? -.pi / 4 : .pi / 4)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: -6, y: 0))
            path.addLine(to: CGPoint(x: 6, y: 0))
            path.move(to: CGPoint(x: -3.5, y: 2.8))
            path.addLine(to: CGPoint(x: -6.5, y: 0))
            path.addLine(to: CGPoint(x: -3.5, y: -2.8))
            path.move(to: CGPoint(x: 3.5, y: 2.8))
            path.addLine(to: CGPoint(x: 6.5, y: 0))
            path.addLine(to: CGPoint(x: 3.5, y: -2.8))

            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(3.2)
            ctx.addPath(path)
            ctx.strokePath()

            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.6)
            ctx.addPath(path)
            ctx.strokePath()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 9, y: 9))
    }

    // MARK: - Mouse & Gesture Events

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(true)
        let pt = convert(event.locationInWindow, from: nil)
        applyCursor(resolvedCursor(at: pt), force: true)
    }

    override func mouseExited(with event: NSEvent) {
        if activeResizeEdge == nil && !isDraggingWindow && lastDragLocation == nil {
            isHovered = false
            onHoverChange?(false)
            applyCursor(.arrow, force: true)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if !isHovered {
            isHovered = true
            onHoverChange?(true)
        }
        guard activeResizeEdge == nil, !isDraggingWindow, lastDragLocation == nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        applyCursor(resolvedCursor(at: pt))
    }

    override func cursorUpdate(with event: NSEvent) {
        guard activeResizeEdge == nil, !isDraggingWindow, lastDragLocation == nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        applyCursor(resolvedCursor(at: pt), force: true)
    }

    override func scrollWheel(with event: NSEvent) {
        if isAdjustingCrop {
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.001 else { return }
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.04
            let zoomFactor = max(0.85, min(1.18, 1.0 - delta * sensitivity))
            onZoomCrop?(zoomFactor)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if !isOverInteractiveOverlay(at: pt), let edge = resizeEdge(at: pt) {
            activeResizeEdge = edge
            isDraggingWindow = false
            lastDragLocation = nil
            resizeStartMouseScreen = NSEvent.mouseLocation
            applyCursor(.resize(edge), force: true)
            onBeginResize?()
            return
        }

        activeResizeEdge = nil
        applyCursor(.closedHand, force: true)
        if isAdjustingCrop {
            isDraggingWindow = false
            lastDragLocation = pt
        } else {
            lastDragLocation = nil
            isDraggingWindow = true
            windowDragStartMouseScreen = NSEvent.mouseLocation
            windowDragStartOrigin = window?.frame.origin ?? .zero
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let edge = activeResizeEdge {
            let curMouse = NSEvent.mouseLocation
            let dx = curMouse.x - resizeStartMouseScreen.x
            let dy = curMouse.y - resizeStartMouseScreen.y
            applyCursor(.resize(edge))
            onUpdateResize?(edge, dx, dy)
            return
        }

        if isDraggingWindow {
            applyCursor(.closedHand)
            let curMouse = NSEvent.mouseLocation
            let newOrigin = NSPoint(
                x: windowDragStartOrigin.x + (curMouse.x - windowDragStartMouseScreen.x),
                y: windowDragStartOrigin.y + (curMouse.y - windowDragStartMouseScreen.y)
            )
            window?.setFrameOrigin(newOrigin)
            return
        }

        if let last = lastDragLocation, isAdjustingCrop {
            applyCursor(.closedHand)
            let cur = convert(event.locationInWindow, from: nil)
            let dxPixels = cur.x - last.x
            let dyPixels = cur.y - last.y
            lastDragLocation = cur

            let viewW = max(1, bounds.width)
            let viewH = max(1, bounds.height)
            let normDX = -(dxPixels / viewW) * currentCropRect.width
            let normDY = -(dyPixels / viewH) * currentCropRect.height
            onPanCrop?(normDX, normDY)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingWindow = false
        activeResizeEdge = nil
        lastDragLocation = nil
        let pt = convert(event.locationInWindow, from: nil)
        isHovered = bounds.contains(pt)
        applyCursor(resolvedCursor(at: pt), force: true)
        super.mouseUp(with: event)
    }
}

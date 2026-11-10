import AppKit
import SwiftUI

struct InteractiveCropCanvas: View {
    let previewImage: NSImage?
    let windowPointSize: CGSize
    @Binding var cropRect: NormalizedCropRect?

    @State private var dragStartCrop: NormalizedCropRect?
    @State private var activeDragMode: DragMode?

    enum DragMode: Equatable {
        case moveAll
        case drawNew(startNormalized: CGPoint)
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }

    private enum CornerHandle: Int, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func position(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private enum EdgeHandle: Int, CaseIterable {
        case top, bottom, left, right

        func position(in rect: CGRect) -> CGPoint {
            switch self {
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            }
        }

        var size: CGSize {
            switch self {
            case .top, .bottom: return CGSize(width: 24, height: 8)
            case .left, .right: return CGSize(width: 8, height: 24)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let effectiveContentSize = previewImage?.size ?? windowPointSize
            let fittedRect = Self.aspectFitRect(contentSize: effectiveContentSize, in: geo.size)
            let selectionPixelRect: CGRect? = cropRect.map { crop in
                CGRect(
                    x: fittedRect.minX + crop.x * fittedRect.width,
                    y: fittedRect.minY + crop.y * fittedRect.height,
                    width: crop.width * fittedRect.width,
                    height: crop.height * fittedRect.height
                )
            }

            ZStack(alignment: .topLeading) {
                // Checkerboard / dark backdrop
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.32))

                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fittedRect.width, height: fittedRect.height)
                        .position(x: fittedRect.midX, y: fittedRect.midY)

                    if let selectionPixelRect {
                        Path { path in
                            path.addRect(fittedRect)
                            path.addRect(selectionPixelRect)
                        }
                        .fill(Color.black.opacity(0.52), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading window preview…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let crop = cropRect, let selectionPixelRect {
                    // Crop Rectangle Border + Rule of Thirds Grid
                    ZStack {
                        Rectangle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)

                        // Subtle rule-of-thirds guides
                        Path { path in
                            let w = selectionPixelRect.width
                            let h = selectionPixelRect.height
                            path.move(to: CGPoint(x: w / 3, y: 0))
                            path.addLine(to: CGPoint(x: w / 3, y: h))
                            path.move(to: CGPoint(x: 2 * w / 3, y: 0))
                            path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                            path.move(to: CGPoint(x: 0, y: h / 3))
                            path.addLine(to: CGPoint(x: w, y: h / 3))
                            path.move(to: CGPoint(x: 0, y: 2 * h / 3))
                            path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
                        }
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                    }
                    .frame(width: selectionPixelRect.width, height: selectionPixelRect.height)
                    .position(x: selectionPixelRect.midX, y: selectionPixelRect.midY)

                    // Edge Handlebars (Top, Bottom, Left, Right)
                    ForEach(EdgeHandle.allCases, id: \.rawValue) { handle in
                        let sz = handle.size
                        Capsule()
                            .fill(Color.white)
                            .frame(width: sz.width, height: sz.height)
                            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2))
                            .shadow(radius: 2)
                            .position(handle.position(in: selectionPixelRect))
                    }

                    // Corner Handlebars
                    ForEach(CornerHandle.allCases, id: \.rawValue) { handle in
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2.5))
                            .shadow(radius: 2)
                            .position(handle.position(in: selectionPixelRect))
                    }

                    // Dimension Readout Pill
                    let croppedPoints = crop.pixelOrPointSize(for: windowPointSize)
                    Text("\(Int(round(croppedPoints.width))) × \(Int(round(croppedPoints.height))) pt")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.76), in: Capsule())
                        .position(
                            x: min(max(fittedRect.minX + 52, selectionPixelRect.midX), fittedRect.maxX - 52),
                            y: selectionPixelRect.minY > fittedRect.minY + 26
                                ? selectionPixelRect.minY - 14
                                : min(fittedRect.maxY - 14, selectionPixelRect.maxY + 14)
                        )
                }

                // Bottom helper text
                Text(
                    cropRect == nil
                        ? "Click and drag on the preview to select a region"
                        : "Drag handles to resize • Drag inside to move • Scroll to zoom"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.62), in: Capsule())
                .position(x: geo.size.width * 0.5, y: max(18, geo.size.height - 16))
                .allowsHitTesting(false)
            }
            .background(
                CropScrollReader(
                    fittedRect: fittedRect,
                    selectionRect: selectionPixelRect,
                    activeDragMode: activeDragMode,
                    onZoom: { zoomFactor in
                        if let current = cropRect {
                            cropRect = current.zoomed(by: zoomFactor)
                        }
                    }
                )
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard fittedRect.width > 10, fittedRect.height > 10 else { return }
                        if activeDragMode == nil {
                            dragStartCrop = cropRect
                            activeDragMode = Self.resolveDragMode(
                                startPoint: value.startLocation,
                                selectionRect: selectionPixelRect,
                                fittedRect: fittedRect
                            )
                        }
                        guard let mode = activeDragMode else { return }
                        let dxNorm = value.translation.width / fittedRect.width
                        let dyNorm = value.translation.height / fittedRect.height
                        applyDrag(
                            mode: mode,
                            initial: dragStartCrop,
                            currentPoint: value.location,
                            fittedRect: fittedRect,
                            dxNorm: dxNorm,
                            dyNorm: dyNorm
                        )
                    }
                    .onEnded { _ in
                        activeDragMode = nil
                        dragStartCrop = nil
                    }
            )
        }
    }

    static func resolveDragMode(startPoint: CGPoint, selectionRect: CGRect?, fittedRect: CGRect) -> DragMode {
        guard let selectionRect else {
            let normStartX = max(0, min(1, (startPoint.x - fittedRect.minX) / fittedRect.width))
            let normStartY = max(0, min(1, (startPoint.y - fittedRect.minY) / fittedRect.height))
            return .drawNew(startNormalized: CGPoint(x: normStartX, y: normStartY))
        }

        // Balanced hit zones:
        // - Keep a small inner margin (<= 11pt or 16% of width/height) so the interior of the crop box
        //   has a spacious, easy-to-grab Move zone.
        // - Provide a generous outer hit margin (24pt on edges, 28pt on corners/handlebars) outside the border.
        let innerBandX: CGFloat = min(11, selectionRect.width * 0.16)
        let innerBandY: CGFloat = min(11, selectionRect.height * 0.16)
        let innerCornerRadius: CGFloat = min(16, min(selectionRect.width, selectionRect.height) * 0.22)
        let outerCornerRadius: CGFloat = 28
        let outerEdgeHandleRadius: CGFloat = 24
        let outerEdgeBand: CGFloat = 20

        let corners: [(DragMode, CGPoint)] = [
            (.topLeft, CGPoint(x: selectionRect.minX, y: selectionRect.minY)),
            (.topRight, CGPoint(x: selectionRect.maxX, y: selectionRect.minY)),
            (.bottomLeft, CGPoint(x: selectionRect.minX, y: selectionRect.maxY)),
            (.bottomRight, CGPoint(x: selectionRect.maxX, y: selectionRect.maxY))
        ]

        // 1. Protect the central interior Move region first so resizing never starves Move
        let innerMoveRect = selectionRect.insetBy(dx: innerBandX, dy: innerBandY)
        if innerMoveRect.contains(startPoint) {
            let nearCornerInside = corners.contains { _, pt in
                hypot(startPoint.x - pt.x, startPoint.y - pt.y) <= innerCornerRadius
            }
            if !nearCornerInside {
                return .moveAll
            }
        }

        // 2. Corner handlebars (generous outer radius, bounded inner radius)
        let cornerDistances = corners.map { ($0.0, hypot(startPoint.x - $0.1.x, startPoint.y - $0.1.y)) }
        if let closestCorner = cornerDistances.min(by: { $0.1 < $1.1 }), closestCorner.1 <= outerCornerRadius {
            return closestCorner.0
        }

        // 3. Edge midpoint handlebars (outside or on the border rim)
        let edgeMidpoints: [(DragMode, CGPoint)] = [
            (.top, CGPoint(x: selectionRect.midX, y: selectionRect.minY)),
            (.bottom, CGPoint(x: selectionRect.midX, y: selectionRect.maxY)),
            (.left, CGPoint(x: selectionRect.minX, y: selectionRect.midY)),
            (.right, CGPoint(x: selectionRect.maxX, y: selectionRect.midY))
        ]
        let edgeMidDistances = edgeMidpoints.map { ($0.0, hypot(startPoint.x - $0.1.x, startPoint.y - $0.1.y)) }
        if let closestMid = edgeMidDistances.min(by: { $0.1 < $1.1 }), closestMid.1 <= outerEdgeHandleRadius {
            return closestMid.0
        }

        // 4. Full edge bands (20pt outside, <= 11pt inside)
        if startPoint.y >= selectionRect.minY - outerEdgeBand && startPoint.y <= selectionRect.maxY + outerEdgeBand {
            if startPoint.x >= selectionRect.minX - outerEdgeBand && startPoint.x <= selectionRect.minX + innerBandX {
                return .left
            }
            if startPoint.x >= selectionRect.maxX - innerBandX && startPoint.x <= selectionRect.maxX + outerEdgeBand {
                return .right
            }
        }

        if startPoint.x >= selectionRect.minX - outerEdgeBand && startPoint.x <= selectionRect.maxX + outerEdgeBand {
            if startPoint.y >= selectionRect.minY - outerEdgeBand && startPoint.y <= selectionRect.minY + innerBandY {
                return .top
            }
            if startPoint.y >= selectionRect.maxY - innerBandY && startPoint.y <= selectionRect.maxY + outerEdgeBand {
                return .bottom
            }
        }

        if selectionRect.contains(startPoint) {
            return .moveAll
        }

        let normStartX = max(0, min(1, (startPoint.x - fittedRect.minX) / fittedRect.width))
        let normStartY = max(0, min(1, (startPoint.y - fittedRect.minY) / fittedRect.height))
        return .drawNew(startNormalized: CGPoint(x: normStartX, y: normStartY))
    }

    private func applyDrag(
        mode: DragMode,
        initial: NormalizedCropRect?,
        currentPoint: CGPoint,
        fittedRect: CGRect,
        dxNorm: CGFloat,
        dyNorm: CGFloat
    ) {
        let minFrac: CGFloat = 0.056
        if case .drawNew(let startNorm) = mode {
            let curNormX = max(0, min(1, (currentPoint.x - fittedRect.minX) / fittedRect.width))
            let curNormY = max(0, min(1, (currentPoint.y - fittedRect.minY) / fittedRect.height))
            let x = min(startNorm.x, curNormX)
            let y = min(startNorm.y, curNormY)
            let w = max(minFrac, abs(curNormX - startNorm.x))
            let h = max(minFrac, abs(curNormY - startNorm.y))
            cropRect = NormalizedCropRect(x: x, y: y, width: w, height: h).clamped()
            return
        }

        guard let initial else { return }
        switch mode {
        case .drawNew:
            break

        case .moveAll:
            cropRect = initial.panned(dx: dxNorm, dy: dyNorm)

        case .topLeft:
            let newX = max(0, min(initial.x + initial.width - minFrac, initial.x + dxNorm))
            let newY = max(0, min(initial.y + initial.height - minFrac, initial.y + dyNorm))
            let newW = (initial.x + initial.width) - newX
            let newH = (initial.y + initial.height) - newY
            cropRect = NormalizedCropRect(x: newX, y: newY, width: newW, height: newH).clamped()

        case .topRight:
            let newY = max(0, min(initial.y + initial.height - minFrac, initial.y + dyNorm))
            let newW = max(minFrac, min(1.0 - initial.x, initial.width + dxNorm))
            let newH = (initial.y + initial.height) - newY
            cropRect = NormalizedCropRect(x: initial.x, y: newY, width: newW, height: newH).clamped()

        case .bottomLeft:
            let newX = max(0, min(initial.x + initial.width - minFrac, initial.x + dxNorm))
            let newW = (initial.x + initial.width) - newX
            let newH = max(minFrac, min(1.0 - initial.y, initial.height + dyNorm))
            cropRect = NormalizedCropRect(x: newX, y: initial.y, width: newW, height: newH).clamped()

        case .bottomRight:
            let newW = max(minFrac, min(1.0 - initial.x, initial.width + dxNorm))
            let newH = max(minFrac, min(1.0 - initial.y, initial.height + dyNorm))
            cropRect = NormalizedCropRect(x: initial.x, y: initial.y, width: newW, height: newH).clamped()

        case .left:
            let newX = max(0, min(initial.x + initial.width - minFrac, initial.x + dxNorm))
            let newW = (initial.x + initial.width) - newX
            cropRect = NormalizedCropRect(x: newX, y: initial.y, width: newW, height: initial.height).clamped()

        case .right:
            let newW = max(minFrac, min(1.0 - initial.x, initial.width + dxNorm))
            cropRect = NormalizedCropRect(x: initial.x, y: initial.y, width: newW, height: initial.height).clamped()

        case .top:
            let newY = max(0, min(initial.y + initial.height - minFrac, initial.y + dyNorm))
            let newH = (initial.y + initial.height) - newY
            cropRect = NormalizedCropRect(x: initial.x, y: newY, width: initial.width, height: newH).clamped()

        case .bottom:
            let newH = max(minFrac, min(1.0 - initial.y, initial.height + dyNorm))
            cropRect = NormalizedCropRect(x: initial.x, y: initial.y, width: initial.width, height: newH).clamped()
        }
    }

    static func aspectFitRect(contentSize: CGSize, in containerSize: CGSize) -> CGRect {
        let pad: CGFloat = 18
        let availW = max(1, containerSize.width - pad * 2)
        let availH = max(1, containerSize.height - pad * 2)
        let contentW = max(1, contentSize.width)
        let contentH = max(1, contentSize.height)
        let scale = min(availW / contentW, availH / contentH)
        let fittedW = contentW * scale
        let fittedH = contentH * scale
        return CGRect(
            x: (containerSize.width - fittedW) * 0.5,
            y: (containerSize.height - fittedH) * 0.5,
            width: fittedW,
            height: fittedH
        )
    }
}

private struct CropScrollReader: NSViewRepresentable {
    var fittedRect: CGRect
    var selectionRect: CGRect?
    var activeDragMode: InteractiveCropCanvas.DragMode?
    var onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> CropScrollNSView {
        let v = CropScrollNSView()
        v.fittedRect = fittedRect
        v.selectionRect = selectionRect
        v.activeDragMode = activeDragMode
        v.onZoom = onZoom
        return v
    }

    func updateNSView(_ nsView: CropScrollNSView, context: Context) {
        let dragChanged = (nsView.activeDragMode != activeDragMode)
        let selectionChanged = (nsView.selectionRect != selectionRect)
        nsView.fittedRect = fittedRect
        nsView.selectionRect = selectionRect
        nsView.activeDragMode = activeDragMode
        nsView.onZoom = onZoom
        if dragChanged || selectionChanged {
            nsView.refreshCursorForCurrentMouse(force: dragChanged)
        }
    }

    static func dismantleNSView(_ nsView: CropScrollNSView, coordinator: ()) {
        nsView.tearDown()
    }
}

private final class CropScrollNSView: NSView {
    var fittedRect: CGRect = .zero
    var selectionRect: CGRect?
    var activeDragMode: InteractiveCropCanvas.DragMode?
    var onZoom: ((CGFloat) -> Void)?

    nonisolated(unsafe) private var monitor: Any?
    private var trackingArea: NSTrackingArea?

    private enum CursorKind: Equatable {
        case arrow
        case crosshair
        case openHand
        case closedHand
        case leftRight
        case upDown
        case diagNWSE
        case diagNESW
    }

    private var currentCursor: CursorKind = .arrow

    override var isFlipped: Bool { true }

    func tearDown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        onZoom = nil
        if currentCursor != .arrow {
            currentCursor = .arrow
            NSCursor.arrow.set()
        }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self,
                !self.isHiddenOrHasHiddenAncestor,
                let win = self.window,
                event.window === win
            else {
                return event
            }
            let pt = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(pt) else { return event }

            let delta = event.scrollingDeltaY
            if abs(delta) > 0.001 {
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.04
                let factor = max(0.85, min(1.18, 1.0 - delta * sensitivity))
                self.onZoom?(factor)
            }
            return nil
        }
    }

    override func mouseEntered(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursor(at: pt, force: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard activeDragMode == nil else { return }
        applyCursor(.arrow, force: true)
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursor(at: pt, force: false)
    }

    override func cursorUpdate(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursor(at: pt, force: true)
    }

    func refreshCursorForCurrentMouse(force: Bool = false) {
        guard let win = window else { return }
        let winPt = win.mouseLocationOutsideOfEventStream
        let localPt = convert(winPt, from: nil)
        updateCursor(at: localPt, force: force)
    }

    private func updateCursor(at pt: CGPoint, force: Bool) {
        if let activeMode = activeDragMode {
            applyCursor(cursorKind(for: activeMode, isDragging: true, at: pt), force: force)
            return
        }
        guard bounds.contains(pt) else {
            applyCursor(.arrow, force: force)
            return
        }
        let hoverMode = InteractiveCropCanvas.resolveDragMode(
            startPoint: pt,
            selectionRect: selectionRect,
            fittedRect: fittedRect
        )
        applyCursor(cursorKind(for: hoverMode, isDragging: false, at: pt), force: force)
    }

    private func cursorKind(for mode: InteractiveCropCanvas.DragMode, isDragging: Bool, at pt: CGPoint) -> CursorKind {
        switch mode {
        case .moveAll:
            return isDragging ? .closedHand : .openHand
        case .left, .right:
            return .leftRight
        case .top, .bottom:
            return .upDown
        case .topLeft, .bottomRight:
            return .diagNWSE
        case .topRight, .bottomLeft:
            return .diagNESW
        case .drawNew:
            if isDragging || fittedRect.contains(pt) {
                return .crosshair
            }
            return .arrow
        }
    }

    private func applyCursor(_ kind: CursorKind, force: Bool) {
        guard force || currentCursor != kind else { return }
        currentCursor = kind
        switch kind {
        case .arrow:
            NSCursor.arrow.set()
        case .crosshair:
            NSCursor.crosshair.set()
        case .openHand:
            NSCursor.openHand.set()
        case .closedHand:
            NSCursor.closedHand.set()
        case .leftRight:
            NSCursor.resizeLeftRight.set()
        case .upDown:
            NSCursor.resizeUpDown.set()
        case .diagNWSE:
            VideoSurfaceNSView.diagonalNWSECursor.set()
        case .diagNESW:
            VideoSurfaceNSView.diagonalNESWCursor.set()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

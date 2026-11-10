import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI

private enum WindowFocusHelper {
    struct TargetWindowSnapshot {
        let frame: CGRect
        let title: String
        let zRankInApp: Int
        let totalAppWindows: Int
    }

    static func inspectTargetWindow(
        pid: pid_t,
        windowID: CGWindowID,
        fallbackTitle: String,
        fallbackFrame: CGRect
    ) -> TargetWindowSnapshot {
        guard pid != 0,
            let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return TargetWindowSnapshot(
                frame: fallbackFrame,
                title: fallbackTitle,
                zRankInApp: 0,
                totalAppWindows: 1
            )
        }

        var rank = 0
        var matchedRank = 0
        var matchedFrame = fallbackFrame
        var matchedTitle = fallbackTitle

        for entry in list {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (entry[kCGWindowLayer as String] as? Int) == 0
            else { continue }

            let entryWID = (entry[kCGWindowNumber as String] as? UInt32) ?? 0
            if entryWID == windowID {
                matchedRank = rank
                if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                    let rect = CGRect(dictionaryRepresentation: boundsDict)
                {
                    matchedFrame = rect
                }
                if let name = entry[kCGWindowName as String] as? String, !name.isEmpty {
                    matchedTitle = name
                }
            }
            rank += 1
        }

        return TargetWindowSnapshot(
            frame: matchedFrame,
            title: matchedTitle,
            zRankInApp: matchedRank,
            totalAppWindows: max(1, rank)
        )
    }

    private static func axWindowFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let posVal = posRef,
            let sizeVal = sizeRef,
            CFGetTypeID(posVal) == AXValueGetTypeID(),
            CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        // Safe cast after verifying CFGetTypeID == AXValueGetTypeID()
        let axPos = unsafeDowncast(posVal, to: AXValue.self)
        let axSize = unsafeDowncast(sizeVal, to: AXValue.self)
        guard AXValueGetValue(axPos, .cgPoint, &point),
            AXValueGetValue(axSize, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    static func raiseSpecificAXWindow(
        pid: pid_t,
        snapshot: TargetWindowSnapshot
    ) -> Bool {
        guard pid != 0, AXIsProcessTrusted() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let axWindows = windowsRef as? [AXUIElement],
            !axWindows.isEmpty
        else { return false }

        var bestWindow: AXUIElement?
        var bestScore = Int.min

        for (index, axWin) in axWindows.enumerated() {
            var score = 0

            if let rect = axWindowFrame(axWin) {
                let dx = abs(rect.origin.x - snapshot.frame.origin.x)
                let dy = abs(rect.origin.y - snapshot.frame.origin.y)
                let dw = abs(rect.width - snapshot.frame.width)
                let dh = abs(rect.height - snapshot.frame.height)
                if dx <= 8 && dy <= 8 && dw <= 8 && dh <= 8 {
                    score += 100
                } else if dw <= 8 && dh <= 8 {
                    score += 30
                }
            }

            if !snapshot.title.isEmpty {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
                    let axTitle = titleRef as? String,
                    !axTitle.isEmpty
                {
                    if axTitle == snapshot.title {
                        score += 60
                    } else if axTitle.localizedCaseInsensitiveContains(snapshot.title)
                        || snapshot.title.localizedCaseInsensitiveContains(axTitle)
                    {
                        score += 25
                    }
                }
            }

            if index == snapshot.zRankInApp {
                score += 20
            }

            if score > bestScore {
                bestScore = score
                bestWindow = axWin
            }
        }

        guard let targetWin = bestWindow else { return false }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(targetWin, kAXMinimizedAttribute as CFString, &minRef) == .success,
            let isMin = minRef as? Bool,
            isMin
        {
            AXUIElementSetAttributeValue(targetWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        AXUIElementPerformAction(targetWin, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(targetWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(targetWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return true
    }

    static func resetStaleAccessibilityTCCEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Ignore if tccutil is unavailable
        }
    }
}

// MARK: - Resize Edge Definition

enum FloatingResizeEdge {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
}

// MARK: - Ghost Outline Icon Renderer

enum GhostIconRenderer {
    /// Draws a crisp vector ghost outline centered in `rect` (standard unflipped CoreGraphics coordinates).
    static func drawGhostOutline(in ctx: CGContext, rect: CGRect, color: NSColor, lineWidth: CGFloat = 1.45) {
        ctx.saveGState()
        let size = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - size) * 0.5
        let originY = rect.minY + (rect.height - size) * 0.5
        let scale = size / 14.0

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        let body = CGMutablePath()
        // Start on left side below dome, arc over dome to right side
        body.move(to: pt(2.6, 3.0))
        body.addLine(to: pt(2.6, 7.6))
        body.addArc(
            center: pt(7.0, 7.6),
            radius: 4.4 * scale,
            startAngle: .pi,
            endAngle: 0,
            clockwise: true
        )
        // Right side down to wavy bottom hem
        body.addLine(to: pt(11.4, 3.0))

        // Three rounded bottom scallops (right -> middle -> left)
        body.addQuadCurve(to: pt(9.9, 2.0), control: pt(11.4, 1.8))
        body.addQuadCurve(to: pt(8.5, 3.1), control: pt(9.1, 2.1))
        body.addQuadCurve(to: pt(7.0, 1.9), control: pt(7.8, 1.9))
        body.addQuadCurve(to: pt(5.5, 3.1), control: pt(6.2, 1.9))
        body.addQuadCurve(to: pt(4.1, 2.0), control: pt(4.9, 2.1))
        body.addQuadCurve(to: pt(2.6, 3.0), control: pt(2.6, 1.8))
        body.closeSubpath()

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(body)
        ctx.strokePath()

        // Two oval eyes
        let eyeW = 1.45 * scale
        let eyeH = 1.85 * scale
        let eyeY = originY + 7.1 * scale
        let leftEye = CGRect(x: originX + 5.35 * scale - eyeW * 0.5, y: eyeY, width: eyeW, height: eyeH)
        let rightEye = CGRect(x: originX + 8.65 * scale - eyeW * 0.5, y: eyeY, width: eyeW, height: eyeH)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: leftEye)
        ctx.fillEllipse(in: rightEye)

        ctx.restoreGState()
    }

    private static let cachedTemplate14: NSImage = makeTemplateImage(size: 14)

    static func templateImage(size: CGFloat = 14) -> NSImage {
        if abs(size - 14) < 0.001 {
            return cachedTemplate14
        }
        return makeTemplateImage(size: size)
    }

    private static func makeTemplateImage(size: CGFloat) -> NSImage {
        let nsSize = NSSize(width: size, height: size)
        let img = NSImage(size: nsSize, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawGhostOutline(in: ctx, rect: rect, color: .black, lineWidth: 1.4)
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Pure AppKit HUD Icon Button

private final class HUDCircleButton: NSView {
    var symbolName: String {
        didSet {
            if symbolName != oldValue {
                cachedSymbolImage = nil
                needsDisplay = true
            }
        }
    }
    var isActive: Bool = false {
        didSet {
            if isActive != oldValue {
                cachedSymbolImage = nil
                needsDisplay = true
            }
        }
    }
    var isDestructive: Bool = false {
        didSet {
            if isDestructive != oldValue {
                cachedSymbolImage = nil
                needsDisplay = true
            }
        }
    }
    var actionHandler: (() -> Void)?

    private var cachedSymbolImage: NSImage?

    private var isPressed: Bool = false {
        didSet {
            if isPressed != oldValue {
                needsDisplay = true
            }
        }
    }

    init(symbolName: String, toolTip: String, isDestructive: Bool = false) {
        self.symbolName = symbolName
        self.isDestructive = isDestructive
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        self.toolTip = toolTip
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        let circleRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bgColor: NSColor
        if isActive {
            bgColor = NSColor.controlAccentColor
        } else if isPressed {
            bgColor = NSColor.labelColor.withAlphaComponent(0.22)
        } else {
            bgColor = NSColor.labelColor.withAlphaComponent(0.10)
        }
        ctx.setFillColor(bgColor.cgColor)
        ctx.fillEllipse(in: circleRect)

        let fgColor: NSColor = isDestructive ? .systemRed : (isActive ? .white : .labelColor)
        if symbolName == "custom.ghost" {
            let iconSize: CGFloat = 13.5
            let iconRect = CGRect(
                x: (bounds.width - iconSize) * 0.5,
                y: (bounds.height - iconSize) * 0.5,
                width: iconSize,
                height: iconSize
            )
            GhostIconRenderer.drawGhostOutline(in: ctx, rect: iconRect, color: fgColor, lineWidth: 1.45)
        } else {
            let symbolImg: NSImage?
            if let cached = cachedSymbolImage {
                symbolImg = cached
            } else if let baseImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
                let colorConfig = config.applying(.init(hierarchicalColor: fgColor))
                let configured = baseImg.withSymbolConfiguration(colorConfig)
                cachedSymbolImage = configured
                symbolImg = configured
            } else {
                symbolImg = nil
            }
            if let symbolImg {
                let imgSize = symbolImg.size
                let drawRect = NSRect(
                    x: (bounds.width - imgSize.width) * 0.5,
                    y: (bounds.height - imgSize.height) * 0.5,
                    width: imgSize.width,
                    height: imgSize.height
                )
                symbolImg.draw(in: drawRect)
            }
        }

        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        isPressed = bounds.contains(pt)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        let pt = convert(event.locationInWindow, from: nil)
        if wasPressed && bounds.contains(pt) {
            actionHandler?()
        }
    }
}

// MARK: - Pure AppKit Continuous Opacity Slider (Zero NSControl / Zero Auto Layout)

private final class HUDOpacitySlider: NSView {
    var minValue: Double = 0.2
    var maxValue: Double = 1.0
    var doubleValue: Double = 1.0 {
        didSet {
            let clamped = max(minValue, min(maxValue, doubleValue))
            if clamped != doubleValue {
                doubleValue = clamped
            }
            if abs(doubleValue - oldValue) > 0.0001 {
                needsDisplay = true
            }
        }
    }

    var onValueChanged: ((Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.toolTip = "Transparency"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        let thumbDiameter: CGFloat = 12
        let trackInsetX: CGFloat = thumbDiameter * 0.5 + 1
        let trackWidth = max(1, bounds.width - trackInsetX * 2)
        let trackHeight: CGFloat = 4
        let trackY = (bounds.height - trackHeight) * 0.5

        let trackRect = CGRect(x: trackInsetX, y: trackY, width: trackWidth, height: trackHeight)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(trackPath)
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.22).cgColor)
        ctx.fillPath()

        let norm = CGFloat((doubleValue - minValue) / max(0.0001, maxValue - minValue))
        let clampedNorm = max(0, min(1, norm))
        let thumbCenterX = trackInsetX + clampedNorm * trackWidth

        let activeWidth = max(trackHeight, thumbCenterX - trackInsetX)
        let activeRect = CGRect(x: trackInsetX, y: trackY, width: activeWidth, height: trackHeight)
        let activePath = CGPath(roundedRect: activeRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(activePath)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fillPath()

        let thumbRect = CGRect(
            x: thumbCenterX - thumbDiameter * 0.5,
            y: (bounds.height - thumbDiameter) * 0.5,
            width: thumbDiameter,
            height: thumbDiameter
        )
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: thumbRect)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(0.75)
        ctx.strokeEllipse(in: thumbRect)

        ctx.restoreGState()
    }

    private func updateValue(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let thumbDiameter: CGFloat = 12
        let trackInsetX: CGFloat = thumbDiameter * 0.5 + 1
        let trackWidth = max(1, bounds.width - trackInsetX * 2)
        let t = Double(max(0, min(1, (pt.x - trackInsetX) / trackWidth)))
        let newValue = minValue + t * (maxValue - minValue)
        doubleValue = newValue
        onValueChanged?(newValue)
    }

    override func mouseDown(with event: NSEvent) {
        updateValue(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateValue(with: event)
    }
}

// MARK: - Pure AppKit Label Subview (Renders Above NSVisualEffectView Material Layers)

private final class HUDPassthroughLabelView: NSView {
    let text: NSString
    let attributes: [NSAttributedString.Key: Any]

    private static let centeredParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 1.5
        return style
    }()

    override var isFlipped: Bool { true }

    init(text: String, fontSize: CGFloat, weight: NSFont.Weight = .medium, color: NSColor = .labelColor) {
        self.text = text as NSString
        self.attributes = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: Self.centeredParagraphStyle
        ]
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func measure(maxWidth: CGFloat) -> NSSize {
        let rect = text.boundingRect(
            with: NSSize(width: max(60, maxWidth), height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let measured = measure(maxWidth: bounds.width)
        let drawRect = NSRect(
            x: 0,
            y: floor((bounds.height - measured.height) * 0.5),
            width: bounds.width,
            height: measured.height
        )
        text.draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
    }
}

// MARK: - Non-Hit-Testing Visual Effect Pill (for Crop Mode Helper Text)

private final class PassthroughVisualEffectPill: NSVisualEffectView {
    private let labelView = HUDPassthroughLabelView(
        text: "Drag to pan • Scroll to zoom • Resize window to change crop area",
        fontSize: 10.5,
        weight: .medium,
        color: NSColor.white.withAlphaComponent(0.95)
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        addSubview(labelView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func sizeToFitContent(maxWidth: CGFloat) -> NSSize {
        let padX: CGFloat = 20
        let padY: CGFloat = 10
        let availTextW = max(100, maxWidth - padX)
        let measured = labelView.measure(maxWidth: availTextW)
        return NSSize(
            width: min(maxWidth, measured.width + padX),
            height: max(24, measured.height + padY)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = min(14, newSize.height * 0.5)
        let padX: CGFloat = 10
        labelView.frame = NSRect(
            x: padX,
            y: 0,
            width: max(1, newSize.width - padX * 2),
            height: newSize.height
        )
    }
}

// MARK: - Pure AppKit Top HUD Bar (4 Icons + Transparency Slider)

private final class FloatingHUDTopBarView: NSVisualEffectView {
    let refreshButton = HUDCircleButton(
        symbolName: "arrow.triangle.2.circlepath", toolTip: "Choose open window or region")
    let cropButton = HUDCircleButton(
        symbolName: "crop", toolTip: "Adjust crop (drag to pan, scroll to zoom, resize window to change crop area)")
    let opacitySlider = HUDOpacitySlider(frame: .zero)
    let ghostButton = HUDCircleButton(
        symbolName: "custom.ghost", toolTip: "Ghost mode (click-through). Hold ⌥ Option to interact while active.")
    let closeButton = HUDCircleButton(symbolName: "xmark", toolTip: "Close floating player", isDestructive: true)

    var onOpacityChanged: ((Double) -> Void)? {
        didSet {
            opacitySlider.onValueChanged = onOpacityChanged
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        addSubview(refreshButton)
        addSubview(cropButton)
        addSubview(opacitySlider)
        addSubview(ghostButton)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        performManualLayout()
    }

    private func performManualLayout() {
        layer?.cornerRadius = bounds.height * 0.5

        let isCompact = bounds.width < 190
        let padX: CGFloat = isCompact ? 6 : 10
        let btnSize: CGFloat = isCompact ? 22 : 24
        let spacing: CGFloat = isCompact ? 5 : 8
        let midY = (bounds.height - btnSize) * 0.5

        refreshButton.frame = NSRect(x: padX, y: midY, width: btnSize, height: btnSize)
        cropButton.frame = NSRect(x: refreshButton.frame.maxX + spacing, y: midY, width: btnSize, height: btnSize)

        closeButton.frame = NSRect(x: bounds.width - padX - btnSize, y: midY, width: btnSize, height: btnSize)
        ghostButton.frame = NSRect(
            x: closeButton.frame.minX - spacing - btnSize, y: midY, width: btnSize, height: btnSize)

        let sliderMinX = cropButton.frame.maxX + spacing
        let sliderMaxW = min(110, max(24, ghostButton.frame.minX - spacing - sliderMinX))
        let sliderH: CGFloat = 18
        opacitySlider.frame = NSRect(
            x: sliderMinX,
            y: (bounds.height - sliderH) * 0.5,
            width: sliderMaxW,
            height: sliderH
        )
    }
}

// MARK: - Pure AppKit Pill Text Button (for Closed Source Banner)

private final class HUDTextPillButton: NSView {
    let title: NSString
    var isPrimary: Bool
    var actionHandler: (() -> Void)?

    private var isPressed = false {
        didSet {
            if isPressed != oldValue {
                needsDisplay = true
            }
        }
    }

    init(title: String, isPrimary: Bool = false) {
        self.title = title as NSString
        self.isPrimary = isPrimary
        super.init(frame: NSRect(x: 0, y: 0, width: 72, height: 22))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        let path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        let bg: NSColor
        if isPrimary {
            bg = isPressed ? NSColor.controlAccentColor.withAlphaComponent(0.75) : NSColor.controlAccentColor
        } else {
            bg = isPressed ? NSColor.labelColor.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.14)
        }
        ctx.setFillColor(bg.cgColor)
        ctx.fillPath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: isPrimary ? NSColor.white : NSColor.labelColor
        ]
        let sz = title.size(withAttributes: attrs)
        let r = NSRect(
            x: (bounds.width - sz.width) * 0.5,
            y: (bounds.height - sz.height) * 0.5,
            width: sz.width,
            height: sz.height
        )
        title.draw(in: r, withAttributes: attrs)
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        isPressed = bounds.contains(pt)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        let pt = convert(event.locationInWindow, from: nil)
        if wasPressed && bounds.contains(pt) {
            actionHandler?()
        }
    }
}

// MARK: - Pure AppKit Floating "Go" Button (Bottom-Right Hover Action)

private final class HUDGoToAppButton: NSVisualEffectView {
    private final class ContentView: NSView {
        private let label: NSString = "Go"
        private var cachedIconNormal: NSImage?
        private var cachedIconHighlighted: NSImage?

        var isHovered: Bool = false {
            didSet {
                if isHovered != oldValue {
                    needsDisplay = true
                }
            }
        }

        var isPressed: Bool = false {
            didSet {
                if isPressed != oldValue {
                    needsDisplay = true
                }
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            if let base = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Go to app")
                ?? NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Go to app")
            {
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
                let normalColor = symbolConfig.applying(
                    .init(hierarchicalColor: NSColor.white.withAlphaComponent(0.92)))
                let activeColor = symbolConfig.applying(.init(hierarchicalColor: NSColor.white))
                cachedIconNormal = base.withSymbolConfiguration(normalColor)
                cachedIconHighlighted = base.withSymbolConfiguration(activeColor)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()

            let pillRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let radius = pillRect.height * 0.5
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(pillPath)

            let bgColor: NSColor
            if isPressed {
                bgColor = NSColor.controlAccentColor.withAlphaComponent(0.88)
            } else if isHovered {
                bgColor = NSColor.white.withAlphaComponent(0.18)
            } else {
                bgColor = NSColor.white.withAlphaComponent(0.08)
            }
            ctx.setFillColor(bgColor.cgColor)
            ctx.fillPath()

            let fgColor =
                (isHovered || isPressed)
                ? NSColor.white
                : NSColor.white.withAlphaComponent(0.92)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: fgColor
            ]
            let textSize = label.size(withAttributes: attrs)
            let iconImg = (isHovered || isPressed) ? cachedIconHighlighted : cachedIconNormal
            let iconSize = iconImg?.size ?? NSSize(width: 12, height: 12)
            let spacing: CGFloat = 4.5
            let totalWidth = iconSize.width + spacing + textSize.width

            // Slight -0.5pt optical nudge balances the leading square icon with the trailing rounded 'o'
            let startX = round((bounds.width - totalWidth) * 0.5 - 0.5)

            if let iconImg {
                let iconRect = NSRect(
                    x: startX,
                    y: round((bounds.height - iconSize.height) * 0.5),
                    width: iconSize.width,
                    height: iconSize.height
                )
                iconImg.draw(in: iconRect)
            }

            let textRect = NSRect(
                x: startX + iconSize.width + spacing,
                y: round((bounds.height - textSize.height) * 0.5),
                width: ceil(textSize.width),
                height: ceil(textSize.height)
            )
            label.draw(in: textRect, withAttributes: attrs)

            ctx.restoreGState()
        }
    }

    private let contentOverlay = ContentView(frame: .zero)
    private var trackingArea: NSTrackingArea?
    var actionHandler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        toolTip = "Go to source app"

        addSubview(contentOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = newSize.height * 0.5
        contentOverlay.frame = bounds
        contentOverlay.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentOverlay.isHovered = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.38).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        contentOverlay.isHovered = false
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        contentOverlay.isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        contentOverlay.isPressed = bounds.contains(pt)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = contentOverlay.isPressed
        contentOverlay.isPressed = false
        let pt = convert(event.locationInWindow, from: nil)
        contentOverlay.isHovered = bounds.contains(pt)
        if wasPressed && bounds.contains(pt) {
            actionHandler?()
        }
    }
}

// MARK: - Closed Window Status Banner

private final class ClosedSourceBannerView: NSVisualEffectView {
    private let titleLabel = HUDPassthroughLabelView(
        text: "Source window closed",
        fontSize: 12,
        weight: .medium,
        color: NSColor.white.withAlphaComponent(0.95)
    )
    private let rechooseButton = HUDTextPillButton(title: "Re-choose", isPrimary: true)
    private let closeButton = HUDTextPillButton(title: "Close", isPrimary: false)

    var onRechoose: (() -> Void)? {
        didSet { rechooseButton.actionHandler = onRechoose }
    }
    var onClose: (() -> Void)? {
        didSet { closeButton.actionHandler = onClose }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        addSubview(titleLabel)
        addSubview(rechooseButton)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        performManualLayout()
    }

    private func performManualLayout() {
        let labelH: CGFloat = 20
        titleLabel.frame = NSRect(
            x: 8,
            y: bounds.height - labelH - 10,
            width: max(1, bounds.width - 16),
            height: labelH
        )

        let btnW: CGFloat = 74
        let btnH: CGFloat = 22
        let spacing: CGFloat = 8
        let totalBtnW = btnW * 2 + spacing
        let startX = (bounds.width - totalBtnW) * 0.5
        let btnY: CGFloat = 10
        rechooseButton.frame = NSRect(x: startX, y: btnY, width: btnW, height: btnH)
        closeButton.frame = NSRect(x: rechooseButton.frame.maxX + spacing, y: btnY, width: btnW, height: btnH)
    }
}

// MARK: - GPU Video Surface & Root Container NSView (Zero NSHostingView / Zero Auto Layout)

final class VideoSurfaceNSView: NSView {
    private let videoLayer = CALayer()
    private let borderLayer = CALayer()
    private let topHUDBar = FloatingHUDTopBarView(frame: .zero)
    private let bottomCropPill = PassthroughVisualEffectPill(frame: .zero)
    private let goToAppButton = HUDGoToAppButton(frame: .zero)
    private let closedBanner = ClosedSourceBannerView(frame: .zero)

    private var currentCropRect: NormalizedCropRect = .full

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

    private enum SurfaceCursorKind: Equatable {
        case arrow
        case openHand
        case closedHand
        case resize(FloatingResizeEdge)
    }

    private var lastDragLocation: NSPoint?
    private var isDraggingWindow: Bool = false
    private var windowDragStartMouseScreen: NSPoint = .zero
    private var windowDragStartOrigin: NSPoint = .zero
    private var activeResizeEdge: FloatingResizeEdge?
    private var resizeStartMouseScreen: NSPoint = .zero
    private var trackingArea: NSTrackingArea?
    private var currentCursorKind: SurfaceCursorKind = .arrow
    private var cropPillFadeTask: Task<Void, Never>?

    private let edgeHitThickness: CGFloat = 14
    private let cornerHitSize: CGFloat = 22

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
        updateGoButtonTargetAppName(session.windowItem.appName)
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
        let c = currentCropRect.clamped()
        let viewW = max(1, bounds.width)
        let viewH = max(1, bounds.height)
        let fullW = viewW / c.width
        let fullH = viewH / c.height
        let targetFrame = CGRect(
            x: -c.x * fullW,
            y: -c.y * fullH,
            width: fullW,
            height: fullH
        )
        if videoLayer.frame != targetFrame {
            videoLayer.frame = targetFrame
        }
    }

    func updateInitialImage(_ cgImage: CGImage, crop: NormalizedCropRect) {
        currentCropRect = crop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = cgImage
        applyCropLayout()
        CATransaction.commit()
    }

    func updateFrame(_ payload: WindowStreamEngine.FramePayload, crop: NormalizedCropRect) {
        currentCropRect = crop
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

    // MARK: - Resize Hit Testing & Cursors

    private func resizeEdge(at pt: NSPoint) -> FloatingResizeEdge? {
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

    private func isOverInteractiveOverlay(at pt: NSPoint) -> Bool {
        (!topHUDBar.isHidden && topHUDBar.frame.contains(pt))
            || (!goToAppButton.isHidden && goToAppButton.frame.contains(pt))
            || (!closedBanner.isHidden && closedBanner.frame.contains(pt))
    }

    private func resolvedCursor(at pt: NSPoint) -> SurfaceCursorKind {
        if (isClickThrough && !isOptionKeyPressed) || !bounds.contains(pt) || isOverInteractiveOverlay(at: pt) {
            return .arrow
        }
        if let edge = resizeEdge(at: pt) {
            return .resize(edge)
        }
        return .openHand
    }

    private func applyCursor(_ kind: SurfaceCursorKind, force: Bool = false) {
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
        if let edge = resizeEdge(at: pt) {
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

    private var resizeInitialFrame: NSRect = .zero
    private var resizeInitialCrop: NormalizedCropRect = .full

    func beginInteractiveResize() {
        guard let panel else { return }
        resizeInitialFrame = panel.frame
        resizeInitialCrop = cropRect.clamped()
    }

    func updateInteractiveResize(edge: FloatingResizeEdge, dx: CGFloat, dy: CGFloat) {
        guard let panel, resizeInitialFrame.width > 10, resizeInitialFrame.height > 10 else { return }
        let initialFrame = resizeInitialFrame

        if isAdjustingCrop {
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
        } else {
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

    private func updateCropModeMaxSize() {
        guard isAdjustingCrop, let panel else { return }
        let c = cropRect.clamped()
        let maxW = max(Self.minPanelWidth, panel.frame.width / max(0.01, c.width))
        let maxH = max(Self.minPanelHeight, panel.frame.height / max(0.01, c.height))
        panel.maxSize = NSSize(width: maxW, height: maxH)
    }

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
        floatingPanel.makeKeyAndOrderFront(nil)
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
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true

        let surfaceView = VideoSurfaceNSView(frame: NSRect(origin: .zero, size: contentRect.size))
        surfaceView.autoresizingMask = [.width, .height]
        self.contentView = surfaceView
        session.attachSurfaceView(surfaceView)
    }

    func setProgrammaticFrame(_ frame: NSRect, animate: Bool = false) {
        setFrame(frame, display: true, animate: animate)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

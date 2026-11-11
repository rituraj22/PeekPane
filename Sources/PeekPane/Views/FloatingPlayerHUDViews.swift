import AppKit
import QuartzCore

// MARK: - Resize Edge Definition

enum FloatingResizeEdge {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
}

// MARK: - Ghost Outline Icon Renderer

enum GhostIconRenderer {
    /// Draws a crisp vector ghost outline centered in `rect` (standard unflipped CoreGraphics coordinates).
    fileprivate static func drawGhostOutline(
        in ctx: CGContext, rect: CGRect, color: NSColor, lineWidth: CGFloat = 1.45
    ) {
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

final class HUDCircleButton: NSView {
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

final class HUDOpacitySlider: NSView {
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

final class PassthroughVisualEffectPill: NSVisualEffectView {
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

final class FloatingHUDTopBarView: NSVisualEffectView {
    let refreshButton = HUDCircleButton(
        symbolName: "arrow.triangle.2.circlepath", toolTip: "Choose open window or region")
    let cropButton = HUDCircleButton(
        symbolName: "crop", toolTip: "Adjust crop (drag to pan, scroll to zoom, resize window to change crop area)")
    let opacitySlider = HUDOpacitySlider(frame: .zero)
    let ghostButton = HUDCircleButton(
        symbolName: "custom.ghost", toolTip: "Ghost mode (click-through). Hold ⌥ Option to interact while active.")
    let closeButton = HUDCircleButton(symbolName: "xmark", toolTip: "Close floating pane", isDestructive: true)

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

final class HUDGoToAppButton: NSVisualEffectView {
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

final class ClosedSourceBannerView: NSVisualEffectView {
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

import AppKit
import QuartzCore

@MainActor
final class BrowserHandoffBannerPanel: NSPanel {
    private let pillView: HandoffClickablePillView
    private var dismissTask: Task<Void, Never>?
    var onDismissed: (() -> Void)?

    init(browserIcon: NSImage?, browserName: String, shortcut: String?) {
        let message = Self.buildInstructionText(browserName: browserName, shortcut: shortcut)
        self.pillView = HandoffClickablePillView(icon: browserIcon, message: message)
        let fittedSize = pillView.preferredSize(maxWidth: 620)

        super.init(
            contentRect: NSRect(origin: .zero, size: fittedSize),
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
        self.setAccessibilitySubrole(.floatingWindow)

        pillView.autoresizingMask = [.width, .height]
        pillView.onClicked = { [weak self] in
            self?.dismiss()
        }
        self.contentView = pillView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(overCGWindowBounds cgBounds: CGRect?) {
        let size = pillView.preferredSize(maxWidth: 620)
        let origin = Self.anchorOrigin(for: size, overCGWindowBounds: cgBounds)
        setFrame(NSRect(origin: origin, size: size), display: true)
        alphaValue = 0.0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 1.0
        }

        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard isVisible else { return }
        orderOut(nil)
        close()
        let callback = onDismissed
        onDismissed = nil
        callback?()
    }

    private static func buildInstructionText(browserName: String, shortcut: String?) -> String {
        if let shortcut, !shortcut.isEmpty {
            return "In \(browserName), switch to your tab and press \(shortcut) (or click the PeekPane toolbar icon)"
        }
        return "In \(browserName), switch to your tab and click the PeekPane toolbar icon to select an area"
    }

    private static func anchorOrigin(for bannerSize: NSSize, overCGWindowBounds cgBounds: CGRect?) -> NSPoint {
        let fallbackScreen = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1440, height: 900)
        guard let cgBounds, cgBounds.width >= 200, cgBounds.height >= 120 else {
            return NSPoint(
                x: round(fallbackScreen.midX - bannerSize.width * 0.5),
                y: round(fallbackScreen.maxY - bannerSize.height - 64)
            )
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? fallbackScreen.maxY
        let appKitWindowRect = NSRect(
            x: cgBounds.origin.x,
            y: primaryHeight - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )
        let hostScreen =
            NSScreen.screens.first { $0.frame.intersects(appKitWindowRect) }?.visibleFrame
            ?? fallbackScreen

        let rawX = appKitWindowRect.midX - bannerSize.width * 0.5
        let rawY = appKitWindowRect.maxY - bannerSize.height - 86
        let clampedX = max(hostScreen.minX + 12, min(hostScreen.maxX - bannerSize.width - 12, rawX))
        let clampedY = max(hostScreen.minY + 24, min(hostScreen.maxY - bannerSize.height - 12, rawY))
        return NSPoint(x: round(clampedX), y: round(clampedY))
    }
}

private final class HandoffClickablePillView: NSVisualEffectView {
    private let iconImageView = NSImageView(frame: .zero)
    private let messageField: NSTextField
    private let closeField: NSTextField
    var onClicked: (() -> Void)?

    init(icon: NSImage?, message: String) {
        self.messageField = NSTextField(labelWithString: message)
        self.closeField = NSTextField(labelWithString: "×")
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        if let iconCopy = icon?.copy() as? NSImage {
            iconCopy.size = NSSize(width: 20, height: 20)
            iconImageView.image = iconCopy
        }
        iconImageView.imageScaling = .scaleProportionallyUpOrDown

        messageField.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        messageField.textColor = NSColor.white.withAlphaComponent(0.96)
        messageField.lineBreakMode = .byTruncatingTail
        messageField.maximumNumberOfLines = 1

        closeField.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        closeField.textColor = NSColor.white.withAlphaComponent(0.65)
        closeField.alignment = .center

        addSubview(iconImageView)
        addSubview(messageField)
        addSubview(closeField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let textWidth = ceil(messageField.attributedStringValue.size().width)
        let totalWidth = min(maxWidth, max(280, 14 + 20 + 10 + textWidth + 10 + 18 + 14))
        return NSSize(width: totalWidth, height: 42)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = newSize.height * 0.5

        let midY = newSize.height * 0.5
        iconImageView.frame = NSRect(x: 14, y: round(midY - 10), width: 20, height: 20)
        closeField.frame = NSRect(x: newSize.width - 30, y: round(midY - 10), width: 18, height: 20)

        let textX: CGFloat = 44
        let textW = max(60, closeField.frame.minX - textX - 8)
        let textH = ceil(messageField.attributedStringValue.size().height)
        messageField.frame = NSRect(x: textX, y: round(midY - textH * 0.5), width: textW, height: textH)
    }

    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }
}

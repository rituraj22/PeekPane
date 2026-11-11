import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

/// Represents a normalized crop rectangle within a target window.
/// Origin (0, 0) is the TOP-LEFT of the window; values are in 0.0...1.0.
struct NormalizedCropRect: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    static let full = Self(x: 0.0, y: 0.0, width: 1.0, height: 1.0)

    /// Clamps the crop rect to valid [0, 1] bounds with a minimum size.
    func clamped(minSize: CGFloat = 0.042) -> Self {
        let w = max(minSize, min(1.0, width))
        let h = max(minSize, min(1.0, height))
        let clampedX = max(0.0, min(1.0 - w, x))
        let clampedY = max(0.0, min(1.0 - h, y))
        return Self(x: clampedX, y: clampedY, width: w, height: h)
    }

    /// Computes the size in points for a given window point size.
    func pixelOrPointSize(for windowSize: CGSize) -> CGSize {
        let c = clamped()
        return CGSize(
            width: max(28, windowSize.width * c.width),
            height: max(28, windowSize.height * c.height)
        )
    }

    /// Pans the normalized rect by delta fractions.
    func panned(dx: CGFloat, dy: CGFloat) -> Self {
        Self(x: x + dx, y: y + dy, width: width, height: height).clamped()
    }

    /// Zooms the normalized rect around its center while strictly preserving its aspect ratio.
    /// `scaleFactor < 1.0` zooms in; `> 1.0` zooms out. Stops cleanly when either dimension hits 1.0.
    func zoomed(by scaleFactor: CGFloat, minSize: CGFloat = 0.042) -> Self {
        let c = clamped(minSize: minSize)
        let centerX = c.x + c.width * 0.5
        let centerY = c.y + c.height * 0.5

        let maxScale = min(1.0 / max(0.0001, c.width), 1.0 / max(0.0001, c.height))
        let minScale = max(minSize / max(0.0001, c.width), minSize / max(0.0001, c.height))
        let effectiveScale = max(minScale, min(maxScale, scaleFactor))

        let newW = c.width * effectiveScale
        let newH = c.height * effectiveScale
        let newX = max(0.0, min(1.0 - newW, centerX - newW * 0.5))
        let newY = max(0.0, min(1.0 - newH, centerY - newH * 0.5))
        return Self(x: newX, y: newY, width: newW, height: newH)
    }
}

/// Metadata and handle for a shareable macOS window.
struct ShareableWindowItem: Identifiable, Hashable {
    let scWindow: SCWindow
    let windowID: CGWindowID
    let title: String
    let appName: String
    let bundleIdentifier: String
    let processID: pid_t
    let frame: CGRect
    let isOnScreen: Bool
    let appIcon: NSImage?

    var id: CGWindowID { windowID }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return appName
        }
        if trimmed.lowercased() == appName.lowercased() {
            return appName
        }
        return "\(appName) — \(trimmed)"
    }

    var shortTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appName : trimmed
    }

    init(scWindow: SCWindow, appIcon: NSImage? = nil) {
        self.scWindow = scWindow
        self.windowID = scWindow.windowID
        self.title = scWindow.title ?? ""
        self.appName = scWindow.owningApplication?.applicationName ?? "Window"
        self.bundleIdentifier = scWindow.owningApplication?.bundleIdentifier ?? ""
        self.processID = scWindow.owningApplication?.processID ?? 0
        self.frame = scWindow.frame
        self.isOnScreen = scWindow.isOnScreen
        if let appIcon {
            self.appIcon = appIcon
        } else if let pid = scWindow.owningApplication?.processID,
            let runningApp = NSRunningApplication(processIdentifier: pid)
        {
            self.appIcon = runningApp.icon
        } else {
            self.appIcon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID && lhs.title == rhs.title && lhs.appName == rhs.appName && lhs.frame == rhs.frame
            && lhs.isOnScreen == rhs.isOnScreen
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(title)
        hasher.combine(appName)
        hasher.combine(frame.origin.x)
        hasher.combine(frame.origin.y)
        hasher.combine(frame.size.width)
        hasher.combine(frame.size.height)
        hasher.combine(isOnScreen)
    }
}

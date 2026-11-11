import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

/// Represents a normalized crop rectangle within a target window or tab viewport.
/// Origin (0, 0) is the TOP-LEFT; values are in 0.0...1.0.
struct NormalizedCropRect: Codable, Equatable, Sendable {
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

    /// Computes the size in points for a given window or viewport point size.
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

enum AppBuildIdentity {
    static let isDevBuild: Bool = {
        if (Bundle.main.object(forInfoDictionaryKey: "PPIsDevBuild") as? Bool) == true {
            return true
        }
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true {
            return true
        }
        return Bundle.main.bundleURL.pathExtension != "app"
    }()

    static var appName: String {
        isDevBuild ? "PeekPaneDev" : "PeekPane"
    }
}

enum BrowserEngineFamily: Sendable {
    case chromium
    case gecko
}

/// Supported Chromium and Gecko-based macOS desktop browsers for direct tab extraction.
enum SupportedBrowser: String, CaseIterable, Identifiable, Sendable {
    // Chromium family
    case googleChrome = "com.google.Chrome"
    case arc = "company.thebrowser.Browser"
    case brave = "com.brave.Browser"
    case edge = "com.microsoft.edgemac"
    case vivaldi = "com.vivaldi.Vivaldi"
    case chromium = "org.chromium.Chromium"

    // Gecko (Firefox & forks) family
    case firefox = "org.mozilla.firefox"
    case firefoxDeveloperEdition = "org.mozilla.firefoxdeveloperedition"
    case zen = "app.zen-browser.zen"
    case libreWolf = "io.gitlab.librewolf-community.librewolf"
    case floorp = "one.ablaze.floorp"
    case waterfox = "net.waterfox.waterfox"

    var id: String { rawValue }

    var engineFamily: BrowserEngineFamily {
        switch self {
        case .googleChrome, .arc, .brave, .edge, .vivaldi, .chromium:
            .chromium
        case .firefox, .firefoxDeveloperEdition, .zen, .libreWolf, .floorp, .waterfox:
            .gecko
        }
    }

    var candidateBundleIdentifiers: [String] {
        switch self {
        case .libreWolf:
            [rawValue, "net.librewolf.librewolf", "org.mozilla.librewolf"]
        default:
            [rawValue]
        }
    }

    static func from(bundleIdentifier: String) -> Self? {
        if let direct = Self(rawValue: bundleIdentifier) {
            return direct
        }
        return Self.allCases.first { $0.candidateBundleIdentifiers.contains(bundleIdentifier) }
    }

    var displayName: String {
        switch self {
        case .googleChrome: "Google Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .firefoxDeveloperEdition: "Firefox Developer Edition"
        case .zen: "Zen Browser"
        case .libreWolf: "LibreWolf"
        case .floorp: "Floorp"
        case .waterfox: "Waterfox"
        }
    }

    var shortLabel: String {
        switch self {
        case .googleChrome: "Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .firefoxDeveloperEdition: "Firefox Dev"
        case .zen: "Zen"
        case .libreWolf: "LibreWolf"
        case .floorp: "Floorp"
        case .waterfox: "Waterfox"
        }
    }

    var extensionsURLString: String {
        switch self {
        case .googleChrome, .arc, .chromium: "chrome://extensions"
        case .brave: "brave://extensions"
        case .edge: "edge://extensions"
        case .vivaldi: "vivaldi://extensions"
        case .firefox, .firefoxDeveloperEdition, .zen, .libreWolf, .floorp, .waterfox:
            "about:debugging#/runtime/this-firefox"
        }
    }

    var appSupportRelativeParentPath: String {
        switch self {
        case .googleChrome: "Google/Chrome"
        case .arc: "Arc/User Data"
        case .brave: "BraveSoftware/Brave-Browser"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        case .firefox, .firefoxDeveloperEdition: "Mozilla"
        case .zen: "zen"
        case .libreWolf: "LibreWolf"
        case .floorp: "Floorp"
        case .waterfox: "Waterfox"
        }
    }

    @MainActor
    var installedAppURL: URL? {
        for candidateID in candidateBundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidateID) {
                return url
            }
        }
        return nil
    }

    @MainActor
    var appIcon: NSImage {
        if let url = installedAppURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

/// Uniquely identifies an active browser tab stream across multiple Chromium or Gecko profiles.
struct TabStreamKey: Hashable, Codable, Sendable {
    let extensionInstanceID: String
    let tabID: UInt32
}

/// Metadata for a live Chromium or Gecko browser tab source.
struct BrowserTabSourceItem: Identifiable, Hashable {
    let streamKey: TabStreamKey
    let browserBundleIdentifier: String
    var title: String
    var host: String
    var viewportSize: CGSize
    let appIcon: NSImage?

    var id: TabStreamKey { streamKey }

    var browserDisplayName: String {
        SupportedBrowser.from(bundleIdentifier: browserBundleIdentifier)?.displayName ?? "Browser"
    }

    var shortTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return host.isEmpty ? browserDisplayName : host
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.streamKey == rhs.streamKey
            && lhs.browserBundleIdentifier == rhs.browserBundleIdentifier
            && lhs.title == rhs.title
            && lhs.host == rhs.host
            && lhs.viewportSize == rhs.viewportSize
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(streamKey)
        hasher.combine(browserBundleIdentifier)
        hasher.combine(title)
        hasher.combine(host)
        hasher.combine(viewportSize.width)
        hasher.combine(viewportSize.height)
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

/// Unified source descriptor backing a `FloatingPlayerSession`.
enum CaptureSource: Equatable {
    case window(ShareableWindowItem)
    case browserTab(BrowserTabSourceItem)

    var shortTitle: String {
        switch self {
        case .window(let item): item.shortTitle
        case .browserTab(let tab): tab.shortTitle
        }
    }

    var sourceAppName: String {
        switch self {
        case .window(let item): item.appName
        case .browserTab(let tab): tab.browserDisplayName
        }
    }

    var appIcon: NSImage? {
        switch self {
        case .window(let item): item.appIcon
        case .browserTab(let tab): tab.appIcon
        }
    }

    var initialPointSize: CGSize {
        switch self {
        case .window(let item): item.frame.size
        case .browserTab(let tab): tab.viewportSize
        }
    }

    var windowItem: ShareableWindowItem? {
        guard case .window(let item) = self else { return nil }
        return item
    }

    var browserTabItem: BrowserTabSourceItem? {
        guard case .browserTab(let tab) = self else { return nil }
        return tab
    }
}

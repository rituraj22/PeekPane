import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowDiscoveryService: ObservableObject {
    @Published var windows: [ShareableWindowItem] = []
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var hasScreenRecordingPermission: Bool = CGPreflightScreenCaptureAccess()
    @Published var isRefreshing: Bool = false
    @Published var lastError: String?

    private let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.wallpaper.agent",
        "com.apple.loginwindow"
    ]

    private let excludedAppNames: Set<String> = [
        "Dock",
        "Window Server",
        "Control Center",
        "Notification Center",
        "SystemUIServer",
        "Spotlight",
        "Wallpaper"
    ]

    private var thumbnailTask: Task<Void, Never>?

    deinit {
        thumbnailTask?.cancel()
    }

    func checkPermissionStatus() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if hasScreenRecordingPermission != granted {
            hasScreenRecordingPermission = granted
        }
        return granted
    }

    func checkAndRequestPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            if !hasScreenRecordingPermission {
                hasScreenRecordingPermission = true
            }
            return true
        }
        Self.resetStaleScreenCaptureTCCEntry()
        let granted = CGRequestScreenCaptureAccess()
        if hasScreenRecordingPermission != granted {
            hasScreenRecordingPermission = granted
        }
        return granted
    }

    private static func resetStaleScreenCaptureTCCEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Ignore if tccutil is unavailable
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Refreshes the list of shareable windows ordered front-to-back.
    func refreshWindows(loadThumbnails: Bool = true) async {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            if !hasScreenRecordingPermission {
                hasScreenRecordingPermission = true
            }
            if lastError != nil {
                lastError = nil
            }

            let currentPID = ProcessInfo.processInfo.processIdentifier
            let zOrderMap = Self.buildWindowZOrderMap(onScreenOnly: true)
            let filtered = filterWindows(content.windows, currentPID: currentPID, zOrderMap: zOrderMap)
            let sorted = Self.sortWindows(filtered, zOrderMap: zOrderMap)

            if self.windows != sorted {
                self.windows = sorted
            }

            // Prune thumbnails for windows that have been closed so the cache stays bounded
            let validIDs = Set(sorted.map(\.windowID))
            if thumbnails.keys.contains(where: { !validIDs.contains($0) }) {
                thumbnails = thumbnails.filter { validIDs.contains($0.key) }
            }

            if loadThumbnails {
                let task = Task<Void, Never> { @MainActor [weak self] in
                    guard let self else { return }
                    await self.captureThumbnails(for: sorted)
                }
                thumbnailTask = task
                await task.value
            }
        } catch {
            self.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
            self.lastError = error.localizedDescription
        }
    }

    /// Captures a snapshot of a single window without shadows.
    func captureWindowSnapshot(
        for item: ShareableWindowItem,
        maxDimension: CGFloat = 1400,
        storeAsThumbnail: Bool = false
    ) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: item.scWindow)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.showsCursor = false

        let aspect = max(0.1, item.frame.width / max(1, item.frame.height))
        if item.frame.width >= item.frame.height {
            let w = min(maxDimension, max(320, item.frame.width * 2.0))
            config.width = Int(w)
            config.height = max(1, Int(w / aspect))
        } else {
            let h = min(maxDimension, max(320, item.frame.height * 2.0))
            config.height = Int(h)
            config.width = max(1, Int(h * aspect))
        }

        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
            let image = NSImage(cgImage: cgImage, size: imageSize)
            if storeAsThumbnail {
                thumbnails[item.windowID] = image
            }
            return image
        } catch {
            return thumbnails[item.windowID]
        }
    }

    private func captureThumbnails(for items: [ShareableWindowItem]) async {
        for item in items.prefix(16) {
            guard !Task.isCancelled else { break }
            _ = await captureWindowSnapshot(for: item, maxDimension: 520, storeAsThumbnail: true)
        }
    }

    private static func buildWindowZOrderMap(onScreenOnly: Bool = true) -> [CGWindowID: Int] {
        let options: CGWindowListOption =
            onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var map: [CGWindowID: Int] = [:]
        for (index, entry) in infoList.enumerated() {
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 {
                continue
            }
            if let num = entry[kCGWindowNumber as String] as? UInt32 {
                if map[num] == nil {
                    map[num] = index
                }
            }
        }
        return map
    }

    private struct CachedAppInfo {
        let isRegular: Bool
        let icon: NSImage?
    }

    private static func resolveAppInfo(
        for app: SCRunningApplication,
        cache: inout [pid_t: CachedAppInfo],
        fallbackIcon: NSImage
    ) -> CachedAppInfo {
        let pid = app.processID
        if let cached = cache[pid] {
            return cached
        }
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let isRegular = runningApp.map { $0.activationPolicy == .regular } ?? true
        let icon = runningApp?.icon ?? fallbackIcon
        let created = CachedAppInfo(isRegular: isRegular, icon: icon)
        cache[pid] = created
        return created
    }

    /// Exclude macOS off-screen 500x500 dummy windows and untitled off-screen windows
    private static func isOffScreenDummy(_ scWindow: SCWindow, title: String) -> Bool {
        title.isEmpty || (Int(scWindow.frame.width) == 500 && Int(scWindow.frame.height) == 500)
    }

    private func filterWindows(
        _ windows: [SCWindow],
        currentPID: pid_t,
        zOrderMap: [CGWindowID: Int]
    ) -> [ShareableWindowItem] {
        // Collect which apps have at least one titled window so we can ignore untitled helper/dummy windows
        var appsWithTitledWindow = Set<pid_t>()
        for w in windows where w.windowLayer == 0 && w.frame.width >= 80 && w.frame.height >= 60 {
            let t = (w.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, let pid = w.owningApplication?.processID {
                appsWithTitledWindow.insert(pid)
            }
        }

        var appInfoCache: [pid_t: CachedAppInfo] = [:]
        let fallbackIcon = NSWorkspace.shared.icon(for: .applicationBundle)

        return windows.compactMap { scWindow in
            guard scWindow.windowLayer == 0, scWindow.frame.width >= 80, scWindow.frame.height >= 60 else { return nil }
            guard let app = scWindow.owningApplication, app.processID != currentPID else { return nil }
            if excludedBundleIDs.contains(app.bundleIdentifier) || excludedAppNames.contains(app.applicationName) {
                return nil
            }

            let appInfo = Self.resolveAppInfo(for: app, cache: &appInfoCache, fallbackIcon: fallbackIcon)
            guard appInfo.isRegular else { return nil }

            let title = (scWindow.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let appName = app.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty && appName.isEmpty { return nil }

            let isTrulyOnScreen = zOrderMap[scWindow.windowID] != nil
            if !isTrulyOnScreen {
                if Self.isOffScreenDummy(scWindow, title: title) { return nil }
            } else if title.isEmpty && appsWithTitledWindow.contains(app.processID) {
                // Exclude untitled auxiliary layer-0 windows when the app already has real titled windows
                return nil
            }

            return ShareableWindowItem(scWindow: scWindow, appIcon: appInfo.icon)
        }
    }

    private static func sortWindows(
        _ windows: [ShareableWindowItem],
        zOrderMap: [CGWindowID: Int]
    ) -> [ShareableWindowItem] {
        windows.sorted { a, b in
            let rankA = zOrderMap[a.windowID] ?? Int.max
            let rankB = zOrderMap[b.windowID] ?? Int.max
            if rankA != rankB {
                return rankA < rankB
            }
            if a.isOnScreen != b.isOnScreen {
                return a.isOnScreen && !b.isOnScreen
            }
            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }
    }
}

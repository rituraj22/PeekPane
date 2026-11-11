import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var mainWindow: NSWindow?
    nonisolated(unsafe) private var windowWillCloseObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var windowDidBecomeKeyObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var windowDidDeminiaturizeObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installWindowLifecycleObservers()
        coordinator.startBrowserBridgeServices()

        let launchInBackground = CommandLine.arguments.contains("--background")
        if launchInBackground {
            _ = NSApp.setActivationPolicy(.accessory)
        } else {
            _ = NSApp.setActivationPolicy(.regular)
            showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stopBrowserBridgeServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasVisibleMain = NSApp.windows.contains {
            Self.isStandardAppWindow($0) && $0.isVisible && !$0.isMiniaturized
        }
        if !hasVisibleMain {
            showMainWindow()
        } else {
            if NSApp.activationPolicy() != .regular {
                _ = NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    deinit {
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
        }
        if let windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
        }
        if let windowDidDeminiaturizeObserver {
            NotificationCenter.default.removeObserver(windowDidDeminiaturizeObserver)
        }
    }

    static func isStandardAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
    }

    private func installWindowLifecycleObservers() {
        observeWindowWillClose()
        observeWindowDidBecomeKey()
        observeWindowDidDeminiaturize()
    }

    private func observeWindowWillClose() {
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            let closingObjectID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let closingObjectID,
                    let closingWindow = NSApp.windows.first(where: { ObjectIdentifier($0) == closingObjectID }),
                    Self.isStandardAppWindow(closingWindow)
                else {
                    return
                }

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.syncActivationPolicyAfterWindowClose()
                    }
                }
            }
        }
    }

    private func observeWindowDidBecomeKey() {
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            let keyObjectID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let keyObjectID,
                    let keyWindow = NSApp.windows.first(where: { ObjectIdentifier($0) == keyObjectID }),
                    Self.isStandardAppWindow(keyWindow)
                else {
                    return
                }
                if NSApp.activationPolicy() != .regular {
                    _ = NSApp.setActivationPolicy(.regular)
                }
            }
        }
    }

    private func observeWindowDidDeminiaturize() {
        windowDidDeminiaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: nil,
            queue: .main
        ) { notification in
            let deminObjectID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let deminObjectID,
                    let deminWindow = NSApp.windows.first(where: { ObjectIdentifier($0) == deminObjectID }),
                    Self.isStandardAppWindow(deminWindow)
                else {
                    return
                }
                if NSApp.activationPolicy() != .regular {
                    _ = NSApp.setActivationPolicy(.regular)
                }
            }
        }
    }

    private static func syncActivationPolicyAfterWindowClose() {
        guard !NSApp.isHidden else { return }
        let hasOpenMainWindow = NSApp.windows.contains {
            isStandardAppWindow($0) && ($0.isVisible || $0.isMiniaturized)
        }
        if !hasOpenMainWindow {
            switchToAccessoryKeepingFloatingPanesVisible()
        }
    }

    private static func switchToAccessoryKeepingFloatingPanesVisible() {
        let visiblePanels = NSApp.windows.compactMap { $0 as? FloatingPlayerPanel }.filter(\.isVisible)
        if NSApp.activationPolicy() != .accessory {
            _ = NSApp.setActivationPolicy(.accessory)
        }
        if NSApp.isActive {
            NSApp.deactivate()
        }
        for panel in visiblePanels {
            panel.orderFrontRegardless()
        }
    }

    func showMainWindow() {
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        let window = ensureMainWindow()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSApp.activationPolicy() != .regular {
                    _ = NSApp.setActivationPolicy(.regular)
                }
                self.bringStandardWindowsToFront()
            }
        }
    }

    private func ensureMainWindow() -> NSWindow {
        if let mainWindow {
            return mainWindow
        }
        let rootView = MainControlView(coordinator: coordinator)
            .frame(minWidth: 820, minHeight: 540)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(AppBuildIdentity.appName) — Window Region Floating Pane"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 640))
        window.minSize = NSSize(width: 820, height: 540)
        window.isReleasedWhenClosed = false
        window.center()
        let autosaveName = AppBuildIdentity.isDevBuild ? "PeekPaneDevMainWindow" : "PeekPaneMainWindow"
        window.setFrameAutosaveName(autosaveName)
        self.mainWindow = window
        return window
    }

    private func bringStandardWindowsToFront() {
        for window in NSApp.windows where Self.isStandardAppWindow(window) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct PeekPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarExtraContentView(appDelegate: appDelegate, coordinator: appDelegate.coordinator)
        } label: {
            Image(nsImage: MenuBarIconRenderer.templateImage(isDevBuild: AppBuildIdentity.isDevBuild))
        }
    }
}

private struct MenuBarExtraContentView: View {
    let appDelegate: AppDelegate
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        if AppBuildIdentity.isDevBuild {
            Text("DEV BUILD • \(AppBuildIdentity.appName)")
                .font(.caption.weight(.semibold))
            Divider()
        }

        Button {
            for s in coordinator.activeSessions {
                s.isClickThrough = false
            }
        } label: {
            Label {
                Text("Disable Ghost Mode")
            } icon: {
                Image(nsImage: GhostIconRenderer.templateImage(size: 14))
            }
        }

        if !coordinator.activeSessions.isEmpty {
            Button(role: .destructive) {
                coordinator.closeAllSessions()
            } label: {
                Label("Close All Floating Panes", systemImage: "xmark")
            }
        }

        Divider()

        Button("Open \(AppBuildIdentity.appName) Window") {
            appDelegate.showMainWindow()
        }

        Button("Quit \(AppBuildIdentity.appName)") {
            coordinator.closeAllSessions()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

enum MenuBarIconRenderer {
    static func templateImage(size: CGFloat = 18, isDevBuild: Bool = false) -> NSImage {
        let scale = size / 18.0
        let imgSize = NSSize(width: size, height: size)
        let image = NSImage(size: imgSize, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            drawPaneGlyph(scale: scale)
            if isDevBuild {
                drawDevIndicatorDot(scale: scale)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawPaneGlyph(scale: CGFloat) {
        // 1. Floating hero rounded-rect pane (matches AppIcon.svg hero glass slab)
        let paneRect = NSRect(
            x: 1.8 * scale,
            y: 2.0 * scale,
            width: 14.4 * scale,
            height: 9.6 * scale
        )
        let panePath = NSBezierPath(
            roundedRect: paneRect,
            xRadius: 2.8 * scale,
            yRadius: 2.8 * scale
        )
        panePath.lineWidth = 1.55 * scale
        panePath.stroke()

        // 2. Interior widget shapes: left orb + two right horizontal pills
        let orbDiameter = 3.4 * scale
        let orbRect = NSRect(
            x: 4.1 * scale,
            y: 5.1 * scale,
            width: orbDiameter,
            height: orbDiameter
        )
        NSBezierPath(ovalIn: orbRect).fill()

        let topPill = NSRect(
            x: 8.8 * scale,
            y: 5.0 * scale,
            width: 5.0 * scale,
            height: 1.5 * scale
        )
        NSBezierPath(roundedRect: topPill, xRadius: 0.75 * scale, yRadius: 0.75 * scale).fill()

        let bottomPill = NSRect(
            x: 8.8 * scale,
            y: 7.3 * scale,
            width: 3.6 * scale,
            height: 1.5 * scale
        )
        NSBezierPath(roundedRect: bottomPill, xRadius: 0.75 * scale, yRadius: 0.75 * scale).fill()

        // 3. Perspective base deck / glowing origin bar below the floating pane
        let deckPath = NSBezierPath()
        deckPath.move(to: NSPoint(x: 4.4 * scale, y: 13.8 * scale))
        deckPath.line(to: NSPoint(x: 13.6 * scale, y: 13.8 * scale))
        deckPath.line(to: NSPoint(x: 15.6 * scale, y: 16.2 * scale))
        deckPath.line(to: NSPoint(x: 2.4 * scale, y: 16.2 * scale))
        deckPath.close()
        deckPath.lineWidth = 1.35 * scale
        deckPath.lineJoinStyle = .round
        deckPath.stroke()
    }

    private static func drawDevIndicatorDot(scale: CGFloat) {
        let center = NSPoint(x: 15.5 * scale, y: 2.5 * scale)
        let haloRadius = 2.65 * scale
        let dotRadius = 1.65 * scale

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        let haloRect = NSRect(
            x: center.x - haloRadius,
            y: center.y - haloRadius,
            width: haloRadius * 2.0,
            height: haloRadius * 2.0
        )
        NSBezierPath(ovalIn: haloRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.setFill()
        let dotRect = NSRect(
            x: center.x - dotRadius,
            y: center.y - dotRadius,
            width: dotRadius * 2.0,
            height: dotRadius * 2.0
        )
        NSBezierPath(ovalIn: dotRect).fill()
    }
}

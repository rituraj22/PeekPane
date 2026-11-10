import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PeekPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("PeekPane — Window Region Floating Player", id: "main") {
            MainControlView(coordinator: coordinator)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 960, height: 640)

        MenuBarExtra {
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
                    Label("Close All Floating Players", systemImage: "xmark")
                }
            }

            Divider()

            Button("Open PeekPane Window") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Button("Quit PeekPane") {
                coordinator.closeAllSessions()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(nsImage: MenuBarIconRenderer.templateImage())
        }
    }
}

enum MenuBarIconRenderer {
    static func templateImage(size: CGFloat = 18) -> NSImage {
        let imgSize = NSSize(width: size, height: size)
        let image = NSImage(size: imgSize, flipped: true) { rect in
            let s = min(rect.width, rect.height)
            let scale = s / 18.0
            NSColor.black.setStroke()
            NSColor.black.setFill()

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

            return true
        }
        image.isTemplate = true
        return image
    }
}

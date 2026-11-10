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

        MenuBarExtra("PeekPane", systemImage: "pip") {
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
            .disabled(!coordinator.activeSessions.contains(where: \.isClickThrough))

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
        }
    }
}

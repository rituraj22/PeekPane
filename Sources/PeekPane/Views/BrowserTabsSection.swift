import SwiftUI

struct BrowserTabsSection: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var extensionManager: ExtensionBundleManager
    @ObservedObject var bridgeServer: BrowserBridgeServer

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.extensionManager = coordinator.extensionManager
        self.bridgeServer = coordinator.bridgeServer
    }

    var body: some View {
        if !extensionManager.installedBrowsers.isEmpty {
            Section("Browser Tabs (No Toolbars)") {
                ForEach(extensionManager.installedBrowsers) { browser in
                    BrowserTabTriggerRow(
                        browser: browser,
                        isLiveConnected: bridgeServer.isCurrentlyConnected(for: browser),
                        isConfigured: coordinator.isExtensionConfigured(for: browser)
                    ) {
                        coordinator.handleSidebarBrowserButtonTap(browser)
                    } onOpenSetup: {
                        coordinator.setupSheetBrowser = browser
                    }
                }
            }
        }
    }
}

private struct BrowserTabTriggerRow: View {
    let browser: SupportedBrowser
    let isLiveConnected: Bool
    let isConfigured: Bool
    let onPrimaryAction: () -> Void
    let onOpenSetup: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPrimaryAction) {
                HStack(spacing: 8) {
                    Image(nsImage: browser.appIcon)
                        .resizable()
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pick \(browser.shortLabel) Tab…")
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text(statusLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isConfigured {
                Button(action: onOpenSetup) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Browser extension setup instructions")
            } else {
                Button("Set Up", action: onOpenSetup)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        if isLiveConnected {
            return .green
        }
        return isConfigured ? .blue : .secondary.opacity(0.5)
    }

    private var statusLabel: String {
        if isLiveConnected {
            return browser.engineFamily == .gecko ? "Connected (~12–15 FPS)" : "Extension connected"
        }
        if isConfigured {
            return browser.engineFamily == .gecko ? "Ready (~12–15 FPS)" : "Ready via shortcut / icon"
        }
        return browser.engineFamily == .gecko ? "Setup (~12–15 FPS)" : "One-time extension setup"
    }
}

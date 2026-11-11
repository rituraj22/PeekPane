import SwiftUI

struct ChromiumWindowBanner: View {
    let browser: SupportedBrowser
    let windowItem: ShareableWindowItem
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var bridgeServer: BrowserBridgeServer
    @ObservedObject var extensionManager: ExtensionBundleManager

    init(browser: SupportedBrowser, windowItem: ShareableWindowItem, coordinator: AppCoordinator) {
        self.browser = browser
        self.windowItem = windowItem
        self.coordinator = coordinator
        self.bridgeServer = coordinator.bridgeServer
        self.extensionManager = coordinator.extensionManager
    }

    var body: some View {
        let isConfigured =
            bridgeServer.isCurrentlyConnected(for: browser)
            || extensionManager.browsersWithInstalledExtension.contains(browser)
        let bannerMessage = Self.makeBannerText(for: browser, isConfigured: isConfigured)
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(bannerMessage)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(2)

            Spacer(minLength: 8)

            if isConfigured {
                Button {
                    coordinator.beginBrowserTabHandoff(for: browser, specificWindow: windowItem)
                } label: {
                    Text("Pick a Tab Instead →")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    coordinator.setupSheetBrowser = browser
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("View \(browser.displayName) extension setup")
            } else {
                Button {
                    coordinator.setupSheetBrowser = browser
                } label: {
                    Text("Set Up Browser Extension…")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.09))
    }

    private static func makeBannerText(for browser: SupportedBrowser, isConfigured: Bool) -> String {
        if browser.engineFamily == .gecko {
            if isConfigured {
                return
                    "Full \(browser.shortLabel) window changes when switching tabs. "
                    + "Tab extraction streams at ~12–15 FPS (best for dashboards & trackers)."
            }
            return
                "Float a single \(browser.shortLabel) tab (~12–15 FPS for dashboards & trackers; "
                + "use window capture or built-in PiP for 60 FPS video)."
        }
        if isConfigured {
            return "Capturing a full \(browser.shortLabel) window includes toolbars and changes when you switch tabs."
        }
        return "Float a single \(browser.shortLabel) tab — no toolbars, keeps streaming when you switch tabs."
    }
}

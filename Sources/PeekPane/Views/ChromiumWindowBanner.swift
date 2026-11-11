import SwiftUI

struct ChromiumWindowBanner: View {
    let browser: SupportedChromiumBrowser
    let windowItem: ShareableWindowItem
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var bridgeServer: BrowserBridgeServer

    init(browser: SupportedChromiumBrowser, windowItem: ShareableWindowItem, coordinator: AppCoordinator) {
        self.browser = browser
        self.windowItem = windowItem
        self.coordinator = coordinator
        self.bridgeServer = coordinator.bridgeServer
    }

    var body: some View {
        let isConfigured = bridgeServer.hasEverConnected(bundleIdentifier: browser.bundleIdentifier)
        let bannerMessage =
            isConfigured
            ? "Capturing a full \(browser.shortLabel) window includes toolbars and changes when you switch tabs."
            : "Float a single \(browser.shortLabel) tab — no toolbars, keeps streaming when you switch tabs."
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
}

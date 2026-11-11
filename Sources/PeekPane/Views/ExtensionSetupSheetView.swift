import AppKit
import SwiftUI

struct ExtensionSetupSheetView: View {
    let browser: SupportedChromiumBrowser
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var extensionManager: ExtensionBundleManager
    @ObservedObject var bridgeServer: BrowserBridgeServer
    @State private var copiedAddress: Bool = false

    init(browser: SupportedChromiumBrowser, coordinator: AppCoordinator) {
        self.browser = browser
        self.coordinator = coordinator
        self.extensionManager = coordinator.extensionManager
        self.bridgeServer = coordinator.bridgeServer
    }

    var body: some View {
        let isLiveConnected = bridgeServer.isCurrentlyConnected(bundleIdentifier: browser.bundleIdentifier)
        let isOutdated = bridgeServer.outdatedVersionBundleIDs.contains(browser.bundleIdentifier)
        let shortcut = bridgeServer.actionShortcut(for: browser.bundleIdentifier) ?? "⌥⇧P"

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: browser.appIcon)
                    .resizable()
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Float Individual \(browser.displayName) Tabs")
                        .font(.title3.weight(.semibold))
                    Text("Streams a tab region without browser chrome, even when you switch tabs or minimize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if extensionManager.isAppTranslocated {
                WarningCalloutView(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "Move PeekPane.app to /Applications and relaunch before setting up the browser bridge."
                )
            }

            if isOutdated {
                WarningCalloutView(
                    icon: "arrow.triangle.2.circlepath.circle.fill",
                    tint: .blue,
                    text:
                        "A newer PeekPane extension is staged. "
                        + "Click Reload on \(browser.extensionsURLString) if needed."
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                SetupStepRow(
                    number: "1",
                    title: "Open \(browser.extensionsURLString) and enable Developer mode",
                    subtitle:
                        "Paste the address into \(browser.shortLabel)'s URL bar "
                        + "and toggle Developer mode on (top right)."
                ) {
                    Button(copiedAddress ? "Copied!" : "Copy \(browser.extensionsURLString)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(browser.extensionsURLString, forType: .string)
                        copiedAddress = true
                    }
                    .controlSize(.small)
                }

                SetupStepRow(
                    number: "2",
                    title: "Click “Load unpacked” and choose PeekPane's Extension folder",
                    subtitle: extensionManager.stagedExtensionURL.path
                ) {
                    Button("Reveal Folder in Finder") {
                        extensionManager.revealStagedExtensionInFinder()
                    }
                    .controlSize(.small)
                }

                SetupStepRow(
                    number: "3",
                    title: "Pin PeekPane from the puzzle-piece menu",
                    subtitle: "Click the toolbar icon (or press \(shortcut)) on any tab to snap or drag a region."
                ) {
                    EmptyView()
                }
            }

            Divider()

            HStack(spacing: 10) {
                Circle()
                    .fill(isLiveConnected ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 8, height: 8)
                Text(
                    isLiveConnected
                        ? "Connected to \(browser.displayName)! Ready to float tabs."
                        : "Waiting for extension in \(browser.displayName)…"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(isLiveConnected ? .primary : .secondary)

                Spacer()

                Button("Switch to \(browser.shortLabel) →") {
                    let target = browser
                    coordinator.setupSheetBrowser = nil
                    coordinator.beginBrowserTabHandoff(for: target, specificWindow: nil)
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    coordinator.setupSheetBrowser = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct WarningCalloutView: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SetupStepRow<ActionContent: View>: View {
    let number: String
    let title: String
    let subtitle: String
    @ViewBuilder let actionContent: () -> ActionContent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                actionContent()
            }
            Spacer(minLength: 0)
        }
    }
}

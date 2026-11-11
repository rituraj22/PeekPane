import AppKit
import PeekPaneBridgeWire
import SwiftUI

struct ExtensionSetupSheetView: View {
    let browser: SupportedBrowser
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var extensionManager: ExtensionBundleManager
    @ObservedObject var bridgeServer: BrowserBridgeServer
    @State private var copiedAddress: Bool = false

    init(browser: SupportedBrowser, coordinator: AppCoordinator) {
        self.browser = browser
        self.coordinator = coordinator
        self.extensionManager = coordinator.extensionManager
        self.bridgeServer = coordinator.bridgeServer
    }

    var body: some View {
        let isLiveConnected = bridgeServer.isCurrentlyConnected(for: browser)
        let isOutdated = bridgeServer.isOutdated(for: browser)
        let shortcut = bridgeServer.actionShortcut(for: browser) ?? "⌥⇧P"

        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if extensionManager.isAppTranslocated {
                WarningCalloutView(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text:
                        "Move \(AppBuildIdentity.appName).app to /Applications and relaunch "
                        + "before setting up the browser bridge."
                )
            }

            if browser.engineFamily == .gecko {
                WarningCalloutView(
                    icon: "info.circle.fill",
                    tint: .blue,
                    text:
                        "\(browser.shortLabel) streams via Gecko tab snapshots (~12–15 FPS) — ideal for "
                        + "dashboards, tickers, trackers, and logs. For 60 FPS video, use full-window capture "
                        + "or \(browser.shortLabel)'s built-in Picture-in-Picture."
                )
            }

            if isOutdated {
                WarningCalloutView(
                    icon: "arrow.triangle.2.circlepath.circle.fill",
                    tint: .blue,
                    text:
                        "A newer PeekPane extension is staged. "
                        + "Reload it from \(browser.extensionsURLString) if needed."
                )
            }

            Divider()

            if browser.engineFamily == .gecko {
                GeckoSetupStepsView(
                    browser: browser,
                    shortcut: shortcut,
                    hasSignedXPI: extensionManager.hasSignedFirefoxXPI,
                    copiedAddress: $copiedAddress,
                    onOpenAddonsStore: {
                        extensionManager.openFirefoxAddonsPage(in: browser)
                    },
                    onInstallSignedXPI: {
                        extensionManager.openSignedFirefoxXPI(in: browser)
                    },
                    onRevealItem: {
                        extensionManager.revealStagedFirefoxItemInFinder()
                    }
                )
            } else {
                ChromiumSetupStepsView(
                    browser: browser,
                    shortcut: shortcut,
                    stagedFolderPath: extensionManager.stagedExtensionURL.path,
                    copiedAddress: $copiedAddress
                ) {
                    extensionManager.revealStagedExtensionInFinder()
                }
            }

            Divider()

            footerSection(isLiveConnected: isLiveConnected)
        }
        .padding(22)
        .frame(width: 540)
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(nsImage: browser.appIcon)
                .resizable()
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Float Individual \(browser.displayName) Tabs")
                    .font(.title3.weight(.semibold))
                Text(
                    browser.engineFamily == .gecko
                        ? "Streams a background tab region (~12–15 FPS) without browser toolbars."
                        : "Streams a tab region without browser chrome, even when you switch tabs or minimize."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func footerSection(isLiveConnected: Bool) -> some View {
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
}

private struct ChromiumSetupStepsView: View {
    let browser: SupportedBrowser
    let shortcut: String
    let stagedFolderPath: String
    @Binding var copiedAddress: Bool
    let onRevealFolder: () -> Void

    var body: some View {
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
                subtitle: stagedFolderPath
            ) {
                Button("Reveal Folder in Finder", action: onRevealFolder)
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
    }
}

private struct GeckoSetupStepsView: View {
    let browser: SupportedBrowser
    let shortcut: String
    let hasSignedXPI: Bool
    @Binding var copiedAddress: Bool
    let onOpenAddonsStore: () -> Void
    let onInstallSignedXPI: () -> Void
    let onRevealItem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStepRow(
                number: "1",
                title: "Install PeekPane Tab Extractor from Mozilla Add-ons",
                subtitle:
                    "Opens the official Firefox Add-ons listing in \(browser.shortLabel) "
                    + "(\(BridgeConstants.firefoxAddonsURLString)) — click “Add to Firefox” to install permanently."
            ) {
                HStack(spacing: 8) {
                    Button("Open in \(browser.shortLabel) →", action: onOpenAddonsStore)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    Button(copiedAddress ? "Copied!" : "Copy Add-on Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(BridgeConstants.firefoxAddonsURLString, forType: .string)
                        copiedAddress = true
                    }
                    .controlSize(.small)

                    if hasSignedXPI {
                        Button("Install Offline .xpi", action: onInstallSignedXPI)
                            .controlSize(.small)
                    }
                }
            }

            SetupStepRow(
                number: "2",
                title: "Switch to any webpage tab and click PeekPane (or press \(shortcut))",
                subtitle: "Snap an element, drag a custom box, or float the full tab."
            ) {
                EmptyView()
            }

            HStack(spacing: 6) {
                Text("Testing a local build?")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Button("Reveal unpacked manifest.json for about:debugging…", action: onRevealItem)
                    .buttonStyle(.link)
                    .controlSize(.mini)
                    .font(.system(size: 11))
            }
            .padding(.leading, 30)
        }
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

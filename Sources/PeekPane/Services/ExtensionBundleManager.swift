import AppKit
import Foundation
import PeekPaneBridgeWire

private struct NativeMessagingManifest: Codable {
    let name: String
    let description: String
    let path: String
    let type: String
    let allowedOrigins: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case path
        case type
        case allowedOrigins = "allowed_origins"
    }
}

@MainActor
final class ExtensionBundleManager: ObservableObject {
    @Published private(set) var isAppTranslocated: Bool = false
    @Published private(set) var stagedExtensionURL: URL = BridgeConstants.stagedExtensionDirectoryURL()
    @Published private(set) var installedBrowsers: [SupportedChromiumBrowser] = []

    func setupOnLaunch() {
        refreshInstalledBrowsers()
        let bundlePath = Bundle.main.bundlePath
        isAppTranslocated = bundlePath.contains("/AppTranslocation/")

        stageBundledExtensionAtomically()
        if !isAppTranslocated {
            writeNativeMessagingManifests()
        }
    }

    func refreshInstalledBrowsers() {
        installedBrowsers = SupportedChromiumBrowser.allCases.filter { $0.installedAppURL != nil }
    }

    func revealStagedExtensionInFinder() {
        stageBundledExtensionAtomically()
        NSWorkspace.shared.activateFileViewerSelecting([stagedExtensionURL])
    }

    private func stageBundledExtensionAtomically() {
        guard let sourceURL = locateBundledExtensionURL() else {
            return
        }
        let fm = FileManager.default
        let supportDir = BridgeConstants.appSupportDirectoryURL()
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let stagingTempURL = supportDir.appendingPathComponent(
                "Extension.staging-\(UUID().uuidString)",
                isDirectory: true
            )
            defer {
                try? fm.removeItem(at: stagingTempURL)
            }
            try fm.copyItem(at: sourceURL, to: stagingTempURL)

            if fm.fileExists(atPath: stagedExtensionURL.path) {
                _ = try fm.replaceItemAt(stagedExtensionURL, withItemAt: stagingTempURL)
            } else {
                try fm.moveItem(at: stagingTempURL, to: stagedExtensionURL)
            }
        } catch {
            return
        }
    }

    private func locateBundledExtensionURL() -> URL? {
        let fm = FileManager.default
        if let resourceExtension = Bundle.main.resourceURL?.appendingPathComponent("Extension", isDirectory: true),
            fm.fileExists(atPath: resourceExtension.appendingPathComponent("manifest.json").path)
        {
            return resourceExtension
        }
        let repoFallback = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Extension", isDirectory: true)
        if fm.fileExists(atPath: repoFallback.appendingPathComponent("manifest.json").path) {
            return repoFallback
        }
        return nil
    }

    private func writeNativeMessagingManifests() {
        guard let helperPath = locateNativeHostExecutablePath() else {
            return
        }
        let fm = FileManager.default
        let appSupportRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        let manifest = NativeMessagingManifest(
            name: BridgeConstants.nativeHostName,
            description: "PeekPane Browser Tab Bridge",
            path: helperPath,
            type: "stdio",
            allowedOrigins: ["\(BridgeConstants.expectedExtensionOrigin)/"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let manifestData = try? encoder.encode(manifest) else {
            return
        }

        for browser in SupportedChromiumBrowser.allCases {
            let browserParentDir = appSupportRoot.appendingPathComponent(
                browser.appSupportRelativeParentPath,
                isDirectory: true
            )
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: browserParentDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let hostsDir = browserParentDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            do {
                try fm.createDirectory(at: hostsDir, withIntermediateDirectories: true)
                let manifestFile = hostsDir.appendingPathComponent("\(BridgeConstants.nativeHostName).json")
                try manifestData.write(to: manifestFile, options: .atomic)
            } catch {
                continue
            }
        }
    }

    private func locateNativeHostExecutablePath() -> String? {
        let fm = FileManager.default
        let bundledHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("PeekPaneNativeHost", isDirectory: false)
        if fm.isExecutableFile(atPath: bundledHelper.path) {
            return bundledHelper.path
        }
        if let siblingHelper = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("PeekPaneNativeHost", isDirectory: false),
            fm.isExecutableFile(atPath: siblingHelper.path)
        {
            return siblingHelper.path
        }
        return nil
    }
}

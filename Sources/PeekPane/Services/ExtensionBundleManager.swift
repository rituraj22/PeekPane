import AppKit
import Foundation
import PeekPaneBridgeWire

private struct ChromiumNativeMessagingManifest: Codable {
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

private struct GeckoNativeMessagingManifest: Codable {
    let name: String
    let description: String
    let path: String
    let type: String
    let allowedExtensions: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case path
        case type
        case allowedExtensions = "allowed_extensions"
    }
}

@MainActor
final class ExtensionBundleManager: ObservableObject {
    @Published private(set) var isAppTranslocated: Bool = false
    @Published private(set) var stagedExtensionURL: URL = BridgeConstants.stagedExtensionDirectoryURL()
    @Published private(set) var stagedFirefoxExtensionURL: URL = BridgeConstants.stagedFirefoxExtensionDirectoryURL()
    @Published private(set) var stagedFirefoxSignedXPIURL: URL = BridgeConstants.stagedFirefoxSignedXPIURL()
    @Published private(set) var hasSignedFirefoxXPI: Bool = false
    @Published private(set) var installedBrowsers: [SupportedBrowser] = []
    @Published private(set) var browsersWithInstalledExtension: Set<SupportedBrowser> = []

    var stagedFirefoxManifestURL: URL {
        stagedFirefoxExtensionURL.appendingPathComponent("manifest.json", isDirectory: false)
    }

    func setupOnLaunch() {
        refreshInstalledBrowsers()
        let bundlePath = Bundle.main.bundlePath
        isAppTranslocated = bundlePath.contains("/AppTranslocation/")

        stageBundledExtensionDirectory(named: "Extension", destinationURL: stagedExtensionURL)
        stageBundledExtensionDirectory(named: "FirefoxExtension", destinationURL: stagedFirefoxExtensionURL)
        stageOptionalSignedFirefoxXPI()
        if !isAppTranslocated {
            writeNativeMessagingManifests()
        }
    }

    func refreshInstalledBrowsers() {
        let detectedBrowsers = SupportedBrowser.allCases.filter { $0.installedAppURL != nil }
        if installedBrowsers != detectedBrowsers {
            installedBrowsers = detectedBrowsers
        }
        let configuredOnDisk = Set(
            detectedBrowsers.filter { BrowserProfileExtensionDetector.isExtensionInstalledOnDisk(for: $0) }
        )
        if browsersWithInstalledExtension != configuredOnDisk {
            browsersWithInstalledExtension = configuredOnDisk
        }
    }

    func revealStagedExtensionInFinder() {
        stageBundledExtensionDirectory(named: "Extension", destinationURL: stagedExtensionURL)
        NSWorkspace.shared.activateFileViewerSelecting([stagedExtensionURL])
    }

    func revealStagedFirefoxItemInFinder() {
        stageBundledExtensionDirectory(named: "FirefoxExtension", destinationURL: stagedFirefoxExtensionURL)
        stageOptionalSignedFirefoxXPI()
        if hasSignedFirefoxXPI {
            NSWorkspace.shared.activateFileViewerSelecting([stagedFirefoxSignedXPIURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([stagedFirefoxManifestURL])
        }
    }

    func openSignedFirefoxXPI(in browser: SupportedBrowser) {
        stageOptionalSignedFirefoxXPI()
        guard hasSignedFirefoxXPI else { return }
        if let appURL = browser.installedAppURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(
                [stagedFirefoxSignedXPIURL],
                withApplicationAt: appURL,
                configuration: config,
                completionHandler: nil
            )
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([stagedFirefoxSignedXPIURL])
        }
    }

    private func stageBundledExtensionDirectory(named folderName: String, destinationURL: URL) {
        guard let sourceURL = locateBundledDirectoryURL(named: folderName) else {
            return
        }
        let fm = FileManager.default
        let supportDir = BridgeConstants.appSupportDirectoryURL()
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let stagingTempURL = supportDir.appendingPathComponent(
                "\(folderName).staging-\(UUID().uuidString)",
                isDirectory: true
            )
            defer {
                try? fm.removeItem(at: stagingTempURL)
            }
            try fm.copyItem(at: sourceURL, to: stagingTempURL)

            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: stagingTempURL)
            } else {
                try fm.moveItem(at: stagingTempURL, to: destinationURL)
            }
        } catch {
            return
        }
    }

    private func stageOptionalSignedFirefoxXPI() {
        let fm = FileManager.default
        let bundledXPI = Bundle.main.resourceURL?.appendingPathComponent("peekpane-firefox.xpi", isDirectory: false)
        let repoXPI = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("peekpane-firefox.xpi", isDirectory: false)
        let sourceXPI = [bundledXPI, repoXPI].compactMap { $0 }.first { fm.fileExists(atPath: $0.path) }

        if let sourceXPI {
            try? fm.createDirectory(at: BridgeConstants.appSupportDirectoryURL(), withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: sourceXPI) {
                try? data.write(to: stagedFirefoxSignedXPIURL, options: .atomic)
            }
        }
        hasSignedFirefoxXPI = fm.fileExists(atPath: stagedFirefoxSignedXPIURL.path)
    }

    private func locateBundledDirectoryURL(named folderName: String) -> URL? {
        let fm = FileManager.default
        if let resourceExtension = Bundle.main.resourceURL?.appendingPathComponent(folderName, isDirectory: true),
            fm.fileExists(atPath: resourceExtension.appendingPathComponent("manifest.json").path)
        {
            return resourceExtension
        }
        let repoFallback = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent(folderName, isDirectory: true)
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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        writeChromiumManifests(helperPath: helperPath, appSupportRoot: appSupportRoot, encoder: encoder, fm: fm)
        writeGeckoManifests(helperPath: helperPath, appSupportRoot: appSupportRoot, encoder: encoder, fm: fm)
    }

    private func writeChromiumManifests(
        helperPath: String,
        appSupportRoot: URL,
        encoder: JSONEncoder,
        fm: FileManager
    ) {
        let manifest = ChromiumNativeMessagingManifest(
            name: BridgeConstants.nativeHostName,
            description: "PeekPane Browser Tab Bridge",
            path: helperPath,
            type: "stdio",
            allowedOrigins: ["\(BridgeConstants.expectedExtensionOrigin)/"]
        )
        guard let manifestData = try? encoder.encode(manifest) else { return }

        for browser in SupportedBrowser.allCases where browser.engineFamily == .chromium {
            let parentDir = appSupportRoot.appendingPathComponent(
                browser.appSupportRelativeParentPath,
                isDirectory: true
            )
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: parentDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            writeManifestFile(manifestData, insideParentDir: parentDir, fm: fm)
        }
    }

    private func writeGeckoManifests(
        helperPath: String,
        appSupportRoot: URL,
        encoder: JSONEncoder,
        fm: FileManager
    ) {
        let manifest = GeckoNativeMessagingManifest(
            name: BridgeConstants.nativeHostName,
            description: "PeekPane Browser Tab Bridge",
            path: helperPath,
            type: "stdio",
            allowedExtensions: [BridgeConstants.firefoxExtensionID]
        )
        guard let manifestData = try? encoder.encode(manifest) else { return }

        let geckoBrowsers = SupportedBrowser.allCases.filter { $0.engineFamily == .gecko }
        let anyGeckoInstalled = geckoBrowsers.contains { $0.installedAppURL != nil }
        var targetParentPaths = Set<String>()

        if anyGeckoInstalled {
            targetParentPaths.insert("Mozilla")
        }
        for browser in geckoBrowsers {
            let relPath = browser.appSupportRelativeParentPath
            let parentDir = appSupportRoot.appendingPathComponent(relPath, isDirectory: true)
            var isDir: ObjCBool = false
            let dirExists = fm.fileExists(atPath: parentDir.path, isDirectory: &isDir) && isDir.boolValue
            if dirExists || browser.installedAppURL != nil {
                targetParentPaths.insert(relPath)
            }
        }

        for relPath in targetParentPaths {
            let parentDir = appSupportRoot.appendingPathComponent(relPath, isDirectory: true)
            writeManifestFile(manifestData, insideParentDir: parentDir, fm: fm)
        }
    }

    private func writeManifestFile(_ data: Data, insideParentDir parentDir: URL, fm: FileManager) {
        let hostsDir = parentDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        do {
            try fm.createDirectory(at: hostsDir, withIntermediateDirectories: true)
            let manifestFile = hostsDir.appendingPathComponent("\(BridgeConstants.nativeHostName).json")
            try data.write(to: manifestFile, options: .atomic)
        } catch {
            return
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

private enum BrowserProfileExtensionDetector {
    private static let chromiumIDBytes = Data(BridgeConstants.pinnedExtensionID.utf8)
    private static let geckoIDBytes = Data(BridgeConstants.firefoxExtensionID.utf8)
    private static let skippedChromiumDirs: Set<String> = ["Guest Profile", "System Profile"]

    static func isExtensionInstalledOnDisk(for browser: SupportedBrowser) -> Bool {
        let fm = FileManager.default
        let appSupportRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        switch browser.engineFamily {
        case .chromium:
            let userDataDir = appSupportRoot.appendingPathComponent(
                browser.appSupportRelativeParentPath,
                isDirectory: true
            )
            return hasActiveChromiumExtension(in: userDataDir, fm: fm)
        case .gecko:
            return hasActiveGeckoExtension(for: browser, appSupportRoot: appSupportRoot, fm: fm)
        }
    }

    private static func hasActiveChromiumExtension(in userDataDir: URL, fm: FileManager) -> Bool {
        guard
            let children = try? fm.contentsOfDirectory(
                at: userDataDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }

        for dir in children where !skippedChromiumDirs.contains(dir.lastPathComponent) {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            for filename in ["Secure Preferences", "Preferences"] {
                let prefsURL = dir.appendingPathComponent(filename, isDirectory: false)
                if isActiveInChromiumPrefsFile(prefsURL, fm: fm) {
                    return true
                }
            }
        }
        return false
    }

    private static func isActiveInChromiumPrefsFile(_ prefsURL: URL, fm: FileManager) -> Bool {
        guard let data = try? Data(contentsOf: prefsURL),
            data.contains(chromiumIDBytes),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let extensions = root["extensions"] as? [String: Any],
            let settings = extensions["settings"] as? [String: Any],
            let entry = settings[BridgeConstants.pinnedExtensionID] as? [String: Any]
        else {
            return false
        }

        if let state = entry["state"] as? Int, state == 0 {
            return false
        }
        if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty {
            return false
        }
        if let reasonMask = entry["disable_reasons"] as? Int, reasonMask != 0 {
            return false
        }
        if let unpackedPath = entry["path"] as? String,
            unpackedPath.hasPrefix("/"),
            !fm.fileExists(atPath: unpackedPath)
        {
            return false
        }
        return true
    }

    private static func hasActiveGeckoExtension(
        for browser: SupportedBrowser,
        appSupportRoot: URL,
        fm: FileManager
    ) -> Bool {
        let profilesRelPath: String =
            switch browser {
            case .firefox, .firefoxDeveloperEdition: "Firefox/Profiles"
            case .zen: "zen/Profiles"
            case .libreWolf: "LibreWolf/Profiles"
            case .floorp: "Floorp/Profiles"
            case .waterfox: "Waterfox/Profiles"
            default: ""
            }
        guard !profilesRelPath.isEmpty else { return false }

        let profilesDir = appSupportRoot.appendingPathComponent(profilesRelPath, isDirectory: true)
        guard
            let profileDirs = try? fm.contentsOfDirectory(
                at: profilesDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }

        for dir in profileDirs {
            let folderName = dir.lastPathComponent.lowercased()
            if browser == .firefoxDeveloperEdition && !folderName.contains("dev-edition") {
                continue
            }
            if browser == .firefox && folderName.contains("dev-edition") {
                continue
            }
            let extFile = dir.appendingPathComponent("extensions.json", isDirectory: false)
            if isActiveInGeckoExtensionsFile(extFile) {
                return true
            }
        }
        return false
    }

    private static func isActiveInGeckoExtensionsFile(_ fileURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
            data.contains(geckoIDBytes),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let addons = root["addons"] as? [[String: Any]]
        else {
            return false
        }

        for addon in addons where (addon["id"] as? String) == BridgeConstants.firefoxExtensionID {
            let isActive = (addon["active"] as? Bool) ?? true
            let isUserDisabled = (addon["userDisabled"] as? Bool) ?? false
            if isActive && !isUserDisabled {
                return true
            }
        }
        return false
    }
}

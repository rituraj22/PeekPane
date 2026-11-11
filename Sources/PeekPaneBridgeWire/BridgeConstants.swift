import CryptoKit
import Foundation

public enum BridgeConstants {
    public static let appBundleIdentifier = "com.peekpane.app"
    public static let devAppBundleIdentifier = "com.peekpane.app.dev"
    public static let nativeHostBundleIdentifier = "com.peekpane.app.native-host"
    public static let nativeHostName = "com.peekpane.bridge"
    public static let protocolVersion = 1
    public static let stagedExtensionVersion = "1.1"

    public static let extensionPublicKeyBase64 = [
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAu8PNgnhO6+KUVnhBmX/q",
        "GvPquvALdJcGKuajVfV75id/tf+5IaNFlCLZcPQS+ktQYZfKd0V5aqJJ8Fu7RcxQ",
        "ee+XLf06rMiEZ+Z5yHkWnJfRreOTROfG05h68JdVNbCXCNqmI7wkAlmPt8BogoSH",
        "ktVs++K7LKvbaSWhNGSLRnMXX3UJJoGMBlrMEdZLd8OmgUvQDhif/fxLCdLsHZ7b",
        "Ipnnldi2EzhKLgo/0NE8mXCIG+V3inBARKM9++tLrohZprMUQdaCacrsv7yvzBre",
        "+zuet9siKhOT8dZsULsyhDHy3qRFZ6zndjF6aTGyAWV2ry6luYELaALfkMZ7LR4d",
        "1wIDAQAB"
    ].joined()
    public static let pinnedExtensionID = "noibghleoblgaecnekfpbfngfgjolhab"
    public static let expectedExtensionOrigin = "chrome-extension://\(pinnedExtensionID)"
    public static let firefoxExtensionID = "bridge@peekpane.app"
    public static let firefoxOriginSchemePrefix = "moz-extension://"
    public static let firefoxAddonsURLString =
        "https://addons.mozilla.org/en-US/firefox/addon/peekpane-tab-extractor/"

    public static func appSupportDirectoryURL(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PeekPane", isDirectory: true)
    }

    public static func stagedExtensionDirectoryURL(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        appSupportDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent("Extension", isDirectory: true)
    }

    public static func stagedFirefoxExtensionDirectoryURL(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        appSupportDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent("FirefoxExtension", isDirectory: true)
    }

    public static func stagedFirefoxSignedXPIURL(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        appSupportDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent("peekpane-firefox.xpi", isDirectory: false)
    }

    public static func endpointFileURL(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        appSupportDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent("bridge-endpoint.json", isDirectory: false)
    }

    /// Derives the 32-character Chromium extension ID (`a`...`p`) from a Base64-encoded SPKI DER public key.
    public static func deriveChromeExtensionID(publicKeySPKIBase64: String) -> String? {
        guard let derData = Data(base64Encoded: publicKeySPKIBase64), !derData.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: derData)
        var chars: [Character] = []
        chars.reserveCapacity(32)
        let asciiA: UInt8 = 0x61
        for byte in digest.prefix(16) {
            let highNibble = (byte >> 4) & 0x0F
            let lowNibble = byte & 0x0F
            chars.append(Character(UnicodeScalar(asciiA + highNibble)))
            chars.append(Character(UnicodeScalar(asciiA + lowNibble)))
        }
        return String(chars)
    }
}

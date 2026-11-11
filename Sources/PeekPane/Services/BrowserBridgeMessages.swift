import CoreFoundation

enum BridgeConnectionRole: String, Codable, Sendable {
    case control
    case stream
}

struct BridgeInboundEnvelope: Decodable, Sendable {
    let type: String
    let protocolVersion: Int?
    let role: BridgeConnectionRole?
    let extensionInstanceId: String?
    let browserBundleId: String?
    let extensionVersion: String?
    let actionShortcut: String?
    let token: String?

    // Tab lifecycle & start_tab_pane fields
    let tabId: UInt32?
    let title: String?
    let urlHost: String?
    let cropRect: NormalizedCropRect?
    let viewportWidth: CGFloat?
    let viewportHeight: CGFloat?
    let reason: String?
}

struct BridgeOutboundMessage: Encodable, Sendable {
    let type: String
    var protocolVersion: Int?
    var stagedExtensionVersion: String?
    var tabId: UInt32?
}

struct ConnectedBrowserInfo: Equatable, Identifiable, Sendable {
    let extensionInstanceID: String
    let browserBundleIdentifier: String
    var extensionVersion: String
    var actionShortcut: String

    var id: String { extensionInstanceID }
}

struct StartTabPaneEvent: Sendable {
    let streamKey: TabStreamKey
    let browserBundleIdentifier: String
    let title: String
    let host: String
    let cropRect: NormalizedCropRect
    let viewportSize: CGSize
}

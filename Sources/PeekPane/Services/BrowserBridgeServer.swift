import Darwin
import Foundation
import Network
import PeekPaneBridgeWire
import os

@MainActor
final class BrowserBridgeServer: ObservableObject {
    struct TabStreamSubscriber {
        let onFrame: @MainActor (CaptureFramePayload) -> Void
        let onStateChange:
            @MainActor (_ isStreaming: Bool, _ isMinimized: Bool, _ isClosed: Bool, _ errorText: String?) -> Void
    }

    final class SharedTabStream {
        let decoder: H264StreamDecoder
        var subscribers: [UUID: TabStreamSubscriber] = [:]
        var latestPayload: CaptureFramePayload?

        init(decoder: H264StreamDecoder) {
            self.decoder = decoder
        }
    }

    final class ManagedSocket {
        let id: UUID
        let connection: NWConnection
        var isAuthenticated: Bool = false
        var role: BridgeConnectionRole?
        var extensionInstanceID: String?
        var browserBundleIdentifier: String?
        var authTimeoutTask: Task<Void, Never>?

        init(id: UUID, connection: NWConnection) {
            self.id = id
            self.connection = connection
        }
    }

    private static let legacyEverConnectedDefaultsKey = "com.peekpane.everConnectedBrowsers"
    private static let shortcutsDefaultsKey = "com.peekpane.browserShortcuts"

    @Published private(set) var connectedBrowsers: [String: ConnectedBrowserInfo] = [:]
    @Published private(set) var cachedShortcutsByBundleID: [String: String]
    @Published private(set) var outdatedVersionBundleIDs: Set<String> = []

    var onCropStarted: ((String) -> Void)?
    var onStartTabPane: ((StartTabPaneEvent) -> Void)?
    var onTabMetadataUpdated: ((TabStreamKey, String, String, CGSize) -> Void)?

    let networkQueue = DispatchQueue(label: "com.peekpane.bridge.network", qos: .userInteractive)
    let authToken: String
    let decoderLookup = OSAllocatedUnfairLock(initialState: [TabStreamKey: H264StreamDecoder]())

    var listener: NWListener?
    var sockets: [UUID: ManagedSocket] = [:]
    var controlSocketByInstanceID: [String: UUID] = [:]
    var sharedStreams: [TabStreamKey: SharedTabStream] = [:]
    private var heartbeatTask: Task<Void, Never>?
    private var isRunning: Bool = false

    init() {
        self.authToken = Self.generateRandomHexToken()
        UserDefaults.standard.removeObject(forKey: Self.legacyEverConnectedDefaultsKey)
        self.cachedShortcutsByBundleID =
            (UserDefaults.standard.dictionary(forKey: Self.shortcutsDefaultsKey) as? [String: String]) ?? [:]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = BridgeVideoPacket.defaultMaxFrameBytes + 4096
        wsOptions.setClientRequestHandler(networkQueue) { _, headers in
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value
            if BridgeSecurity.isAllowedExtensionOrigin(origin) {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let newListener = try? NWListener(using: parameters) else {
            isRunning = false
            return
        }
        self.listener = newListener

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard case .ready = state, let port = newListener?.port?.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.writeEndpointFile(port: port)
            }
        }

        newListener.newConnectionHandler = { [weak self] nwConnection in
            Task { @MainActor [weak self] in
                self?.acceptSocketConnection(nwConnection)
            }
        }

        newListener.start(queue: networkQueue)
        startHeartbeatLoop()
    }

    func stop() {
        isRunning = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        removeEndpointFile()

        listener?.cancel()
        listener = nil

        for (_, managed) in sockets {
            managed.authTimeoutTask?.cancel()
            managed.connection.cancel()
        }
        sockets.removeAll()
        controlSocketByInstanceID.removeAll()
        connectedBrowsers.removeAll()

        let activeStreams = Array(sharedStreams.values)
        sharedStreams.removeAll()
        decoderLookup.withLock { $0.removeAll() }
        for stream in activeStreams {
            stream.decoder.invalidate()
        }
    }

    func isCurrentlyConnected(for browser: SupportedBrowser) -> Bool {
        let candidates = Set(browser.candidateBundleIdentifiers)
        return connectedBrowsers.values.contains { candidates.contains($0.browserBundleIdentifier) }
    }

    func isOutdated(for browser: SupportedBrowser) -> Bool {
        !outdatedVersionBundleIDs.isDisjoint(with: browser.candidateBundleIdentifiers)
    }

    func actionShortcut(for browser: SupportedBrowser) -> String? {
        let candidates = Set(browser.candidateBundleIdentifiers)
        if let live = connectedBrowsers.values.first(where: { candidates.contains($0.browserBundleIdentifier) }) {
            return live.actionShortcut.isEmpty ? nil : live.actionShortcut
        }
        for candidate in browser.candidateBundleIdentifiers {
            if let cached = cachedShortcutsByBundleID[candidate] {
                return cached.isEmpty ? nil : cached
            }
        }
        return "⌥⇧P"
    }

    func recordConnectedBrowser(info: ConnectedBrowserInfo) {
        connectedBrowsers[info.extensionInstanceID] = info
        if !info.browserBundleIdentifier.isEmpty {
            cachedShortcutsByBundleID[info.browserBundleIdentifier] = info.actionShortcut
            UserDefaults.standard.set(cachedShortcutsByBundleID, forKey: Self.shortcutsDefaultsKey)

            if info.extensionVersion != BridgeConstants.stagedExtensionVersion {
                outdatedVersionBundleIDs.insert(info.browserBundleIdentifier)
            } else {
                outdatedVersionBundleIDs.remove(info.browserBundleIdentifier)
            }
        }
    }

    func removeConnectedBrowser(instanceID: String) {
        connectedBrowsers.removeValue(forKey: instanceID)
    }

    func highlightActionBadge(for browser: SupportedBrowser) {
        let candidates = Set(browser.candidateBundleIdentifiers)
        let matchingIDs =
            connectedBrowsers
            .filter { candidates.contains($0.value.browserBundleIdentifier) }
            .map(\.key)
        for instanceID in matchingIDs {
            sendControlMessage(BridgeOutboundMessage(type: "highlight_action_badge"), toInstanceID: instanceID)
        }
    }

    func requestActivateTab(_ key: TabStreamKey) {
        sendControlMessage(
            BridgeOutboundMessage(type: "activate_tab", tabId: key.tabID),
            toInstanceID: key.extensionInstanceID
        )
    }

    func requestKeyframe(_ key: TabStreamKey) {
        sendControlMessage(
            BridgeOutboundMessage(type: "request_keyframe", tabId: key.tabID),
            toInstanceID: key.extensionInstanceID
        )
    }

    func subscribe(
        to key: TabStreamKey,
        subscriber: TabStreamSubscriber
    ) -> UUID {
        let subscriberID = UUID()
        let stream = ensureSharedTabStream(for: key)
        stream.subscribers[subscriberID] = subscriber
        if let latest = stream.latestPayload {
            subscriber.onFrame(latest)
            subscriber.onStateChange(true, false, false, nil)
        }
        requestKeyframe(key)
        return subscriberID
    }

    func unsubscribe(from key: TabStreamKey, subscriberID: UUID) {
        guard let stream = sharedStreams[key] else { return }
        stream.subscribers.removeValue(forKey: subscriberID)
        guard stream.subscribers.isEmpty else { return }

        sharedStreams.removeValue(forKey: key)
        _ = decoderLookup.withLock { $0.removeValue(forKey: key) }
        stream.decoder.invalidate()
        sendControlMessage(
            BridgeOutboundMessage(type: "stop_tab_capture", tabId: key.tabID),
            toInstanceID: key.extensionInstanceID
        )
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self else { break }
                for instanceID in self.controlSocketByInstanceID.keys {
                    self.sendControlMessage(BridgeOutboundMessage(type: "ping"), toInstanceID: instanceID)
                }
            }
        }
    }

    private func writeEndpointFile(port: UInt16) {
        let fm = FileManager.default
        let dirURL = BridgeConstants.appSupportDirectoryURL()
        let endpointURL = BridgeConstants.endpointFileURL()
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let info = BridgeEndpointInfo(
            wsPort: port,
            token: authToken,
            pid: getpid(),
            protocolVersion: BridgeConstants.protocolVersion,
            stagedExtensionVersion: BridgeConstants.stagedExtensionVersion
        )
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: endpointURL, options: .atomic)
        chmod(endpointURL.path, S_IRUSR | S_IWUSR)
    }

    private func removeEndpointFile() {
        let endpointURL = BridgeConstants.endpointFileURL()
        try? FileManager.default.removeItem(at: endpointURL)
    }

    private static func generateRandomHexToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var hex = ""
        hex.reserveCapacity(64)
        for _ in 0..<4 {
            let word = generator.next()
            let chunk = String(word, radix: 16, uppercase: false)
            if chunk.count < 16 {
                hex.append(String(repeating: "0", count: 16 - chunk.count))
            }
            hex.append(chunk)
        }
        return hex
    }
}

import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import Network
import PeekPaneBridgeWire
import os

extension BrowserBridgeServer {
    func acceptSocketConnection(_ nwConnection: NWConnection) {
        let socketID = UUID()
        let managed = ManagedSocket(id: socketID, connection: nwConnection)
        sockets[socketID] = managed

        managed.authTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self,
                let current = self.sockets[socketID],
                !current.isAuthenticated
            else { return }
            self.disconnectSocket(id: socketID)
        }

        nwConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.disconnectSocket(id: socketID)
                }
            default:
                break
            }
        }

        nwConnection.start(queue: networkQueue)
        scheduleNextReceive(socketID: socketID, connection: nwConnection, authenticatedInstanceBox: nil)
    }

    func sendControlMessage(_ message: BridgeOutboundMessage, toInstanceID instanceID: String) {
        guard let socketID = controlSocketByInstanceID[instanceID],
            let managed = sockets[socketID],
            let data = try? JSONEncoder().encode(message)
        else {
            return
        }
        sendWebSocketTextFrame(data, over: managed.connection)
    }

    func ensureSharedTabStream(for key: TabStreamKey) -> SharedTabStream {
        if let existing = sharedStreams[key] {
            return existing
        }
        let decoder = H264StreamDecoder(
            streamLabel: "\(key.extensionInstanceID.prefix(8)).\(key.tabID)",
            onDecodedFrame: { [weak self] pixelBuffer, surface, viewportSize in
                self?.deliverDecodedSurface(
                    for: key,
                    pixelBuffer: pixelBuffer,
                    surface: surface,
                    viewportSize: viewportSize
                )
            },
            onKeyframeNeeded: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.requestKeyframe(key)
                }
            }
        )
        let created = SharedTabStream(decoder: decoder)
        sharedStreams[key] = created
        decoderLookup.withLock { $0[key] = decoder }
        return created
    }

    nonisolated private func deliverDecodedSurface(
        for key: TabStreamKey,
        pixelBuffer: CVPixelBuffer,
        surface: IOSurfaceRef,
        viewportSize: CGSize
    ) {
        let surfaceW = CGFloat(IOSurfaceGetWidth(surface))
        let surfaceH = CGFloat(IOSurfaceGetHeight(surface))
        guard surfaceW > 0, surfaceH > 0 else { return }

        let activeRect = BridgeVideoPacket.computeActiveContentNormalizedRect(
            surfaceWidth: surfaceW,
            surfaceHeight: surfaceH,
            viewportWidth: viewportSize.width,
            viewportHeight: viewportSize.height
        )
        let payload = CaptureFramePayload(
            pixelBuffer: pixelBuffer,
            surface: surface,
            contentPointSize: viewportSize,
            activeContentNormalizedRect: activeRect
        )

        Task { @MainActor [weak self] in
            guard let self, let stream = self.sharedStreams[key] else { return }
            stream.latestPayload = payload
            for subscriber in stream.subscribers.values {
                subscriber.onFrame(payload)
                subscriber.onStateChange(true, false, false, nil)
            }
        }
    }

    private func scheduleNextReceive(
        socketID: UUID,
        connection: NWConnection,
        authenticatedInstanceBox: String?
    ) {
        let decoderLock = self.decoderLookup
        connection.receiveMessage { [weak self] content, context, _, error in
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.disconnectSocket(id: socketID)
                }
                return
            }

            let wsMeta =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            let opcode = wsMeta?.opcode ?? .text

            if opcode == .close {
                Task { @MainActor [weak self] in
                    self?.disconnectSocket(id: socketID)
                }
                return
            }

            if opcode == .binary, let content, let instanceID = authenticatedInstanceBox {
                if let packet = try? BridgeVideoPacket.decode(from: content) {
                    let key = TabStreamKey(extensionInstanceID: instanceID, tabID: packet.header.tabID)
                    let directDecoder = decoderLock.withLock { $0[key] }
                    if let directDecoder {
                        directDecoder.enqueuePacket(packet)
                    } else {
                        Task { @MainActor [weak self] in
                            let stream = self?.ensureSharedTabStream(for: key)
                            stream?.decoder.enqueuePacket(packet)
                        }
                    }
                }
                Task { @MainActor [weak self] in
                    guard let self, self.sockets[socketID] != nil else { return }
                    self.scheduleNextReceive(
                        socketID: socketID,
                        connection: connection,
                        authenticatedInstanceBox: instanceID
                    )
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self, let managed = self.sockets[socketID] else { return }
                if let content, opcode == .text {
                    self.handleTextMessage(content, from: managed)
                }
                guard self.sockets[socketID] != nil else { return }
                let resolvedInstance = managed.isAuthenticated ? managed.extensionInstanceID : nil
                self.scheduleNextReceive(
                    socketID: socketID,
                    connection: connection,
                    authenticatedInstanceBox: resolvedInstance
                )
            }
        }
    }

    private func handleTextMessage(_ data: Data, from managed: ManagedSocket) {
        guard let envelope = try? JSONDecoder().decode(BridgeInboundEnvelope.self, from: data) else {
            if !managed.isAuthenticated {
                disconnectSocket(id: managed.id)
            }
            return
        }

        if !managed.isAuthenticated {
            authenticateSocket(managed, with: envelope)
            return
        }

        guard let instanceID = managed.extensionInstanceID else { return }
        handleAuthenticatedControlEnvelope(
            envelope,
            instanceID: instanceID,
            browserBundleID: managed.browserBundleIdentifier ?? ""
        )
    }

    private func authenticateSocket(_ managed: ManagedSocket, with envelope: BridgeInboundEnvelope) {
        guard envelope.type == "hello",
            envelope.protocolVersion == BridgeConstants.protocolVersion,
            let role = envelope.role,
            let instanceID = envelope.extensionInstanceId,
            !instanceID.isEmpty,
            let providedToken = envelope.token,
            BridgeSecurity.constantTimeEquals(providedToken, authToken)
        else {
            disconnectSocket(id: managed.id)
            return
        }

        managed.isAuthenticated = true
        managed.role = role
        managed.extensionInstanceID = instanceID
        managed.browserBundleIdentifier = envelope.browserBundleId ?? ""
        managed.authTimeoutTask?.cancel()
        managed.authTimeoutTask = nil

        if role == .control {
            if let oldControlID = controlSocketByInstanceID[instanceID], oldControlID != managed.id {
                disconnectSocket(id: oldControlID)
            }
            controlSocketByInstanceID[instanceID] = managed.id
            let browserInfo = ConnectedBrowserInfo(
                extensionInstanceID: instanceID,
                browserBundleIdentifier: envelope.browserBundleId ?? "",
                extensionVersion: envelope.extensionVersion ?? "0.0.0",
                actionShortcut: envelope.actionShortcut ?? ""
            )
            recordConnectedBrowser(info: browserInfo)
        }

        let ack = BridgeOutboundMessage(
            type: "hello_ack",
            protocolVersion: BridgeConstants.protocolVersion,
            stagedExtensionVersion: BridgeConstants.stagedExtensionVersion
        )
        if let ackData = try? JSONEncoder().encode(ack) {
            sendWebSocketTextFrame(ackData, over: managed.connection)
        }
    }

    private func handleAuthenticatedControlEnvelope(
        _ envelope: BridgeInboundEnvelope,
        instanceID: String,
        browserBundleID: String
    ) {
        switch envelope.type {
        case "crop_started":
            onCropStarted?(envelope.browserBundleId ?? browserBundleID)

        case "start_tab_pane":
            guard let tabID = envelope.tabId else { return }
            let viewportW = max(120, envelope.viewportWidth ?? 1280)
            let viewportH = max(120, envelope.viewportHeight ?? 800)
            let event = StartTabPaneEvent(
                streamKey: TabStreamKey(extensionInstanceID: instanceID, tabID: tabID),
                browserBundleIdentifier: envelope.browserBundleId ?? browserBundleID,
                title: envelope.title ?? "",
                host: envelope.urlHost ?? "",
                cropRect: (envelope.cropRect ?? .full).clamped(),
                viewportSize: CGSize(width: viewportW, height: viewportH)
            )
            onStartTabPane?(event)

        case "tab_updated":
            guard let tabID = envelope.tabId else { return }
            let key = TabStreamKey(extensionInstanceID: instanceID, tabID: tabID)
            let viewport = CGSize(
                width: envelope.viewportWidth ?? 0,
                height: envelope.viewportHeight ?? 0
            )
            onTabMetadataUpdated?(key, envelope.title ?? "", envelope.urlHost ?? "", viewport)

        case "tab_closed":
            guard let tabID = envelope.tabId else { return }
            closeStreamFromRemote(
                key: TabStreamKey(extensionInstanceID: instanceID, tabID: tabID),
                message: "Browser tab was closed"
            )

        case "capture_stopped":
            guard let tabID = envelope.tabId else { return }
            closeStreamFromRemote(
                key: TabStreamKey(extensionInstanceID: instanceID, tabID: tabID),
                message: envelope.reason ?? "Tab capture stopped in browser"
            )

        default:
            break
        }
    }

    private func closeStreamFromRemote(key: TabStreamKey, message: String) {
        guard let stream = sharedStreams.removeValue(forKey: key) else { return }
        _ = decoderLookup.withLock { $0.removeValue(forKey: key) }
        stream.decoder.invalidate()
        for subscriber in stream.subscribers.values {
            subscriber.onStateChange(false, false, true, message)
        }
    }

    private func disconnectSocket(id: UUID) {
        guard let managed = sockets.removeValue(forKey: id) else { return }
        managed.authTimeoutTask?.cancel()
        managed.connection.cancel()

        guard let instanceID = managed.extensionInstanceID else { return }
        if managed.role == .control, controlSocketByInstanceID[instanceID] == id {
            controlSocketByInstanceID.removeValue(forKey: instanceID)
            removeConnectedBrowser(instanceID: instanceID)
        } else if managed.role == .stream {
            for (key, stream) in sharedStreams where key.extensionInstanceID == instanceID {
                for subscriber in stream.subscribers.values {
                    subscriber.onStateChange(false, false, false, "Reconnecting to browser stream…")
                }
            }
        }
    }

    private func sendWebSocketTextFrame(_ data: Data, over connection: NWConnection) {
        let wsMeta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "bridge-json",
            metadata: [wsMeta]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
}

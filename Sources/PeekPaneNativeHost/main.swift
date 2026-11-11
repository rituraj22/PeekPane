import AppKit
import Darwin
import Foundation
import PeekPaneBridgeWire

private enum PeekPaneNativeHostRunner {
    static func run() {
        do {
            while let payload = try NativeMessagingFraming.readFramedPayload(readExactBytes: readExactFromStdin) {
                let response = handlePayload(payload)
                try writeResponse(response)
            }
        } catch {
            let errorResponse = NativeHostResponse(
                ok: false,
                running: false,
                protocolVersion: BridgeConstants.protocolVersion,
                stagedExtensionVersion: BridgeConstants.stagedExtensionVersion,
                error: "Native host framing error"
            )
            try? writeResponse(errorResponse)
        }
    }

    private static func readExactFromStdin(count: Int) throws -> Data? {
        var accumulated = Data()
        accumulated.reserveCapacity(count)
        while accumulated.count < count {
            let remaining = count - accumulated.count
            guard let chunk = try FileHandle.standardInput.read(upToCount: remaining), !chunk.isEmpty else {
                return accumulated.isEmpty ? nil : accumulated
            }
            accumulated.append(chunk)
        }
        return accumulated
    }

    private static func writeResponse(_ response: NativeHostResponse) throws {
        let framed = try NativeMessagingFraming.encodeMessage(response)
        try FileHandle.standardOutput.write(contentsOf: framed)
    }

    private static func handlePayload(_ payload: Data) -> NativeHostResponse {
        guard let request = try? JSONDecoder().decode(NativeHostRequest.self, from: payload) else {
            return NativeHostResponse(
                ok: false,
                running: false,
                protocolVersion: BridgeConstants.protocolVersion,
                stagedExtensionVersion: BridgeConstants.stagedExtensionVersion,
                error: "Invalid JSON request"
            )
        }

        switch request.type {
        case "probe":
            return handleProbe()
        case "bootstrap":
            return handleBootstrap()
        default:
            return NativeHostResponse(
                ok: false,
                running: false,
                protocolVersion: BridgeConstants.protocolVersion,
                stagedExtensionVersion: BridgeConstants.stagedExtensionVersion,
                error: "Unsupported request type: \(request.type)"
            )
        }
    }

    private static func handleProbe() -> NativeHostResponse {
        let callerBundleID = detectParentBrowserBundleIdentifier()
        guard let live = readLiveEndpoint() else {
            return NativeHostResponse(
                ok: true,
                running: false,
                protocolVersion: BridgeConstants.protocolVersion,
                stagedExtensionVersion: BridgeConstants.stagedExtensionVersion,
                callerBundleIdentifier: callerBundleID
            )
        }
        return makeRunningResponse(from: live, callerBundleID: callerBundleID)
    }

    private static func handleBootstrap() -> NativeHostResponse {
        let callerBundleID = detectParentBrowserBundleIdentifier()
        if let live = readLiveEndpoint() {
            return makeRunningResponse(from: live, callerBundleID: callerBundleID)
        }

        guard let appBundleURL = resolveAppBundleURL() else {
            return NativeHostResponse(
                ok: false,
                running: false,
                protocolVersion: BridgeConstants.protocolVersion,
                stagedExtensionVersion: BridgeConstants.stagedExtensionVersion,
                callerBundleIdentifier: callerBundleID,
                error: "Could not locate PeekPane.app"
            )
        }

        launchBackgroundApp(at: appBundleURL)

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if let live = readLiveEndpoint() {
                return makeRunningResponse(from: live, callerBundleID: callerBundleID)
            }
        }

        return NativeHostResponse(
            ok: false,
            running: false,
            protocolVersion: BridgeConstants.protocolVersion,
            stagedExtensionVersion: BridgeConstants.stagedExtensionVersion,
            callerBundleIdentifier: callerBundleID,
            error: "Timed out waiting for PeekPane bridge server"
        )
    }

    private static func makeRunningResponse(
        from endpoint: BridgeEndpointInfo,
        callerBundleID: String?
    ) -> NativeHostResponse {
        NativeHostResponse(
            ok: true,
            running: true,
            wsPort: endpoint.wsPort,
            token: endpoint.token,
            protocolVersion: endpoint.protocolVersion,
            stagedExtensionVersion: endpoint.stagedExtensionVersion,
            callerBundleIdentifier: callerBundleID
        )
    }

    private static func detectParentBrowserBundleIdentifier() -> String? {
        let parentPID = getppid()
        guard parentPID > 1 else { return nil }
        if let directBundleID = NSRunningApplication(processIdentifier: parentPID)?.bundleIdentifier,
            !directBundleID.isEmpty
        {
            return directBundleID
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(parentPID, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        let processPath = String(cString: pathBuffer)
        let components = URL(fileURLWithPath: processPath).pathComponents
        guard let outerAppIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        let appURL = NSURL.fileURL(withPathComponents: Array(components.prefix(outerAppIndex + 1)))
        guard let appURL else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    private static func readLiveEndpoint() -> BridgeEndpointInfo? {
        let url = BridgeConstants.endpointFileURL()
        guard let data = try? Data(contentsOf: url),
            let info = try? JSONDecoder().decode(BridgeEndpointInfo.self, from: data),
            info.pid > 0,
            info.wsPort > 0,
            !info.token.isEmpty
        else {
            return nil
        }

        guard kill(info.pid, 0) == 0 else {
            return nil
        }
        guard isLoopbackPortReachable(info.wsPort) else {
            return nil
        }
        return info
    }

    private static func isLoopbackPortReachable(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let currentFlags = fcntl(sock, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(sock, F_SETFL, currentFlags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectStatus = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                connect(sock, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectStatus == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 200) > 0, (pfd.revents & Int16(POLLOUT)) != 0 else {
            return false
        }

        var socketError: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) == 0 else {
            return false
        }
        return socketError == 0
    }

    private static func resolveAppBundleURL() -> URL? {
        if let executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            // Expected layout: PeekPane.app/Contents/Helpers/PeekPaneNativeHost
            let candidate =
                executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if candidate.pathExtension == "app",
                FileManager.default.fileExists(atPath: candidate.path)
            {
                return candidate
            }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: BridgeConstants.appBundleIdentifier)
    }

    private static func launchBackgroundApp(at appBundleURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        config.arguments = ["--background"]
        NSWorkspace.shared.openApplication(at: appBundleURL, configuration: config, completionHandler: nil)
    }
}

PeekPaneNativeHostRunner.run()

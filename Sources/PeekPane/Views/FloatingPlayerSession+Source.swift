import AppKit
import ApplicationServices

extension FloatingPlayerSession {
    convenience init(windowItem: ShareableWindowItem, cropRect: NormalizedCropRect) {
        self.init(
            source: .window(windowItem),
            cropRect: cropRect,
            streamEngine: WindowStreamEngine(scWindow: windowItem.scWindow)
        )
    }

    convenience init(
        browserTabItem: BrowserTabSourceItem,
        cropRect: NormalizedCropRect,
        engine: any CaptureStreamEngine
    ) {
        self.init(
            source: .browserTab(browserTabItem),
            cropRect: cropRect,
            streamEngine: engine
        )
    }

    func switchTargetWindow(_ newWindowItem: ShareableWindowItem, newCrop: NormalizedCropRect) {
        guard !isClosed else { return }
        let oldEngine = self.streamEngine
        oldEngine.onInitialImage = nil
        oldEngine.onFrame = nil
        oldEngine.onStateChange = nil

        if isAdjustingCrop {
            isAdjustingCrop = false
        }
        self.source = .window(newWindowItem)
        self.latestSourcePointSize = newWindowItem.frame.size
        surfaceView?.updateGoButtonTargetAppName(newWindowItem.appName)
        if self.isSourceClosed {
            self.isSourceClosed = false
        }
        let newEngine = WindowStreamEngine(scWindow: newWindowItem.scWindow)
        self.streamEngine = newEngine
        setupStreamCallbacks()
        updateCropRect(newCrop, resizeWindow: true)

        Task { [weak self] in
            await oldEngine.stop()
            guard let self, !self.isClosed, self.streamEngine === newEngine else {
                await newEngine.stop()
                return
            }
            await newEngine.start(showsCursor: self.showsCursor)
        }
    }

    func updateBrowserTabMetadata(title: String, host: String, viewportSize: CGSize) {
        guard case .browserTab(var tab) = source else { return }
        if !title.isEmpty {
            tab.title = title
        }
        if !host.isEmpty {
            tab.host = host
        }
        if viewportSize.width >= 1 && viewportSize.height >= 1 {
            tab.viewportSize = viewportSize
            latestSourcePointSize = viewportSize
        }
        source = .browserTab(tab)
    }

    func activateSourceApp() {
        switch source {
        case .window(let windowItem):
            activateWindowSource(windowItem)
        case .browserTab(let tabItem):
            activateBrowserTabSource(tabItem)
        }
    }

    private func activateBrowserTabSource(_ tabItem: BrowserTabSourceItem) {
        onActivateBrowserTab?(tabItem)
        let bundleID = tabItem.browserBundleIdentifier
        guard !bundleID.isEmpty else { return }
        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if runningApp.isHidden {
                runningApp.unhide()
            }
            _ = runningApp.activate(options: NSApplication.ActivationOptions(rawValue: 3))
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }

    private func activateWindowSource(_ windowItem: ShareableWindowItem) {
        let pid = windowItem.processID
        let targetWindowID = windowItem.windowID
        let bundleID = windowItem.bundleIdentifier
        let runningApp =
            (pid != 0 ? NSRunningApplication(processIdentifier: pid) : nil)
            ?? (bundleID.isEmpty
                ? nil
                : NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first)

        let snapshot = WindowFocusHelper.inspectTargetWindow(
            pid: pid,
            windowID: targetWindowID,
            fallbackTitle: windowItem.title,
            fallbackFrame: windowItem.frame
        )

        if !AXIsProcessTrusted() && snapshot.totalAppWindows > 1 {
            WindowFocusHelper.resetStaleAccessibilityTCCEntry()
            let promptOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(promptOptions)
        }

        if let runningApp {
            if runningApp.isHidden {
                runningApp.unhide()
            }

            let raisedAX = WindowFocusHelper.raiseSpecificAXWindow(
                pid: pid,
                snapshot: snapshot
            )

            // rawValue 3 = [.activateAllWindows, .activateIgnoringOtherApps], bringing windows on all displays forward
            // When AX already raised the exact window, rawValue 2 (.activateIgnoringOtherApps) focuses only that window
            let activationBits: UInt = raisedAX ? 2 : 3
            _ = runningApp.activate(options: NSApplication.ActivationOptions(rawValue: activationBits))

            _ = WindowFocusHelper.raiseSpecificAXWindow(pid: pid, snapshot: snapshot)

            if isSourceMinimized && !raisedAX, let bundleURL = runningApp.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: config, completionHandler: nil)
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                _ = WindowFocusHelper.raiseSpecificAXWindow(pid: pid, snapshot: snapshot)
            }
        } else if !bundleID.isEmpty,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }
}

import AppKit
import CoreGraphics
import Foundation

extension AppCoordinator {
    var selectedChromiumBrowser: SupportedChromiumBrowser? {
        guard let bundleID = selectedWindow?.bundleIdentifier else { return nil }
        return SupportedChromiumBrowser(rawValue: bundleID)
    }

    func startBrowserBridgeServices() {
        extensionManager.setupOnLaunch()

        bridgeServer.onCropStarted = { [weak self] _ in
            self?.dismissHandoffBanner()
        }
        bridgeServer.onStartTabPane = { [weak self] event in
            self?.handleStartTabPane(event)
        }
        bridgeServer.onTabMetadataUpdated = { [weak self] streamKey, title, host, viewportSize in
            guard let self else { return }
            for session in self.activeSessions where session.source.browserTabItem?.streamKey == streamKey {
                session.updateBrowserTabMetadata(title: title, host: host, viewportSize: viewportSize)
            }
        }
        bridgeServer.start()
    }

    func stopBrowserBridgeServices() {
        dismissHandoffBanner()
        bridgeServer.stop()
    }

    func handleSidebarBrowserButtonTap(_ browser: SupportedChromiumBrowser) {
        if bridgeServer.hasEverConnected(bundleIdentifier: browser.bundleIdentifier) {
            beginBrowserTabHandoff(for: browser, specificWindow: nil)
        } else {
            setupSheetBrowser = browser
        }
    }

    func beginBrowserTabHandoff(for browser: SupportedChromiumBrowser, specificWindow: ShareableWindowItem?) {
        let bundleID = browser.bundleIdentifier
        let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        var anchorBounds: CGRect? = specificWindow?.frame

        if let runningApp {
            if runningApp.isHidden {
                runningApp.unhide()
            }
            if let specificWindow {
                let snapshot = WindowFocusHelper.inspectTargetWindow(
                    pid: runningApp.processIdentifier,
                    windowID: specificWindow.windowID,
                    fallbackTitle: specificWindow.title,
                    fallbackFrame: specificWindow.frame
                )
                anchorBounds = snapshot.frame
                let raised = WindowFocusHelper.raiseSpecificAXWindow(
                    pid: runningApp.processIdentifier,
                    snapshot: snapshot
                )
                let bits: UInt = raised ? 2 : 3
                _ = runningApp.activate(options: NSApplication.ActivationOptions(rawValue: bits))
            } else {
                _ = runningApp.activate(options: NSApplication.ActivationOptions(rawValue: 3))
                anchorBounds = Self.frontmostBrowserCGWindowBounds(pid: runningApp.processIdentifier)
            }
        } else if let appURL = browser.installedAppURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }

        bridgeServer.highlightActionBadge(for: bundleID)
        showHandoffBanner(for: browser, anchorCGWindowBounds: anchorBounds)
    }

    func populateBrowserTabItems(into menu: NSMenu) {
        let configured = extensionManager.installedBrowsers.filter {
            bridgeServer.hasEverConnected(bundleIdentifier: $0.bundleIdentifier)
        }
        guard !configured.isEmpty else { return }

        menu.addItem(NSMenuItem.sectionHeader(title: "Extract Browser Tab"))
        for browser in configured {
            let item = NSMenuItem(
                title: "Pick a Tab in \(browser.displayName)…",
                action: #selector(MenuActionTarget.invoke(_:)),
                keyEquivalent: ""
            )
            let target = MenuActionTarget { [weak self] in
                self?.beginBrowserTabHandoff(for: browser, specificWindow: nil)
            }
            item.target = target
            item.representedObject = target
            let icon = browser.appIcon
            if let iconCopy = icon.copy() as? NSImage {
                iconCopy.size = NSSize(width: 18, height: 18)
                item.image = iconCopy
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    private func handleStartTabPane(_ event: StartTabPaneEvent) {
        dismissHandoffBanner()

        let icon =
            SupportedChromiumBrowser(rawValue: event.browserBundleIdentifier)?.appIcon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        let tabItem = BrowserTabSourceItem(
            streamKey: event.streamKey,
            browserBundleIdentifier: event.browserBundleIdentifier,
            title: event.title,
            host: event.host,
            viewportSize: event.viewportSize,
            appIcon: icon
        )
        let engine = TabStreamEngine(streamKey: event.streamKey, bridgeServer: bridgeServer)
        let session = FloatingPlayerSession(
            browserTabItem: tabItem,
            cropRect: event.cropRect,
            engine: engine
        )
        session.onClose = { [weak self] closedID in
            self?.activeSessions.removeAll { $0.id == closedID }
        }
        session.onRequestRechooseWindow = { [weak self] targetSession in
            Task { @MainActor in
                await self?.presentWindowPickerMenu(for: targetSession)
            }
        }
        session.onActivateBrowserTab = { [weak self] tab in
            self?.bridgeServer.requestActivateTab(tab.streamKey)
        }

        activeSessions.append(session)
        session.showFloatingPanel(initialScreenRect: nil)
    }

    private func showHandoffBanner(for browser: SupportedChromiumBrowser, anchorCGWindowBounds: CGRect?) {
        dismissHandoffBanner()
        let shortcut = bridgeServer.actionShortcut(for: browser.bundleIdentifier)
        let banner = BrowserHandoffBannerPanel(
            browserIcon: browser.appIcon,
            browserName: browser.shortLabel,
            shortcut: shortcut
        )
        banner.onDismissed = { [weak self, weak banner] in
            if self?.handoffBannerPanel === banner {
                self?.handoffBannerPanel = nil
            }
        }
        handoffBannerPanel = banner
        banner.present(overCGWindowBounds: anchorCGWindowBounds)
    }

    private func dismissHandoffBanner() {
        let active = handoffBannerPanel
        handoffBannerPanel = nil
        active?.dismiss()
    }

    private static func frontmostBrowserCGWindowBounds(pid: pid_t) -> CGRect? {
        guard pid > 0,
            let infoList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }
        for entry in infoList {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (entry[kCGWindowLayer as String] as? Int) == 0,
                let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: boundsDict),
                rect.width >= 200,
                rect.height >= 120
            else {
                continue
            }
            return rect
        }
        return nil
    }
}

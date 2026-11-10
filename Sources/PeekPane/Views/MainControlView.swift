import AppKit
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    let discovery = WindowDiscoveryService()

    @Published var activeSessions: [FloatingPlayerSession] = []
    @Published var selectedWindow: ShareableWindowItem?
    @Published var selectedPreviewImage: NSImage?
    @Published var draftCropRect: NormalizedCropRect? = nil
    @Published var searchQuery: String = ""

    private var previewTask: Task<Void, Never>?
    nonisolated(unsafe) private var terminationObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var activationObserver: (any NSObjectProtocol)?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.previewTask?.cancel()
                self?.closeAllSessions()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                    !self.discovery.hasScreenRecordingPermission || self.discovery.windows.isEmpty
                else { return }
                Task { @MainActor [weak self] in
                    await self?.initialLoad()
                }
            }
        }
    }

    deinit {
        previewTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    var filteredWindows: [ShareableWindowItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return discovery.windows }
        return discovery.windows.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q) || $0.appName.localizedCaseInsensitiveContains(q)
        }
    }

    func initialLoad() async {
        guard discovery.checkPermissionStatus() else {
            return
        }
        await discovery.refreshWindows(loadThumbnails: true)
        if selectedWindow == nil, let first = discovery.windows.first {
            await selectWindow(first)
        }
    }

    func requestPermissionAndLoad() async {
        let alreadyGranted = discovery.checkAndRequestPermission()
        await discovery.refreshWindows(loadThumbnails: true)
        if discovery.hasScreenRecordingPermission {
            if selectedWindow == nil, let first = discovery.windows.first {
                await selectWindow(first)
            }
        } else if !alreadyGranted {
            discovery.openScreenRecordingSettings()
        }
    }

    func selectWindow(_ item: ShareableWindowItem) async {
        previewTask?.cancel()
        if selectedWindow?.windowID != item.windowID {
            draftCropRect = nil
        }
        selectedWindow = item
        if let cached = discovery.thumbnails[item.windowID] {
            selectedPreviewImage = cached
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let storeThumb = (self.discovery.thumbnails[item.windowID] == nil)
            if let hiRes = await self.discovery.captureWindowSnapshot(
                for: item,
                maxDimension: 1600,
                storeAsThumbnail: storeThumb
            ) {
                guard !Task.isCancelled, self.selectedWindow?.windowID == item.windowID else { return }
                self.selectedPreviewImage = hiRes
            }
        }
        previewTask = task
        await task.value
    }

    func refreshSelectedPreview() async {
        if let currentID = selectedWindow?.windowID,
            let freshItem = discovery.windows.first(where: { $0.windowID == currentID })
        {
            selectedWindow = freshItem
        } else if let first = discovery.windows.first {
            selectedWindow = first
        } else {
            selectedWindow = nil
            selectedPreviewImage = nil
        }
        guard let item = selectedWindow else { return }
        previewTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let hiRes = await self.discovery.captureWindowSnapshot(for: item, maxDimension: 1600) {
                guard !Task.isCancelled, self.selectedWindow?.windowID == item.windowID else { return }
                self.selectedPreviewImage = hiRes
            }
        }
        previewTask = task
        await task.value
    }

    func createFloatingPlayer(
        for windowItem: ShareableWindowItem,
        cropRect: NormalizedCropRect,
        initialScreenRect: CGRect? = nil
    ) {
        let session = FloatingPlayerSession(windowItem: windowItem, cropRect: cropRect)
        session.onClose = { [weak self] closedID in
            self?.activeSessions.removeAll { $0.id == closedID }
        }
        session.onRequestRechooseWindow = { [weak self] targetSession in
            Task { @MainActor in
                await self?.presentWindowPickerMenu(for: targetSession)
            }
        }

        activeSessions.append(session)
        session.showFloatingPanel(initialScreenRect: initialScreenRect)
    }

    func presentWindowPickerMenu(for session: FloatingPlayerSession) async {
        guard discovery.checkAndRequestPermission() else {
            return
        }
        session.isShowingWindowPicker = true
        defer { session.isShowingWindowPicker = false }

        await discovery.refreshWindows(loadThumbnails: false)
        guard let panel = session.panel, let contentView = panel.contentView else {
            return
        }

        let menu = NSMenu(title: "Choose Window")
        menu.autoenablesItems = false

        let header = NSMenuItem.sectionHeader(title: "Switch to Open Window")
        menu.addItem(header)

        if discovery.windows.isEmpty {
            let emptyItem = NSMenuItem(title: "No Open Windows Found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for item in discovery.windows {
                let suffix = item.isOnScreen ? "" : " (Minimized / Off-Screen)"
                let menuItem = NSMenuItem(
                    title: item.displayTitle + suffix,
                    action: #selector(MenuActionTarget.invoke(_:)),
                    keyEquivalent: ""
                )
                let target = MenuActionTarget { [weak self, weak session] in
                    guard let session else { return }
                    let nextCrop: NormalizedCropRect =
                        (item.windowID == session.windowItem.windowID) ? session.cropRect : .full
                    session.switchTargetWindow(item, newCrop: nextCrop)
                    self?.selectedWindow = item
                }
                menuItem.target = target
                menuItem.representedObject = target
                menuItem.state = (item.windowID == session.windowItem.windowID) ? .on : .off

                if let appIcon = item.appIcon?.copy() as? NSImage {
                    appIcon.size = NSSize(width: 18, height: 18)
                    menuItem.image = appIcon
                }
                menu.addItem(menuItem)
            }
        }

        let anchorY = contentView.isFlipped ? 40.0 : max(8.0, contentView.bounds.height - 40.0)
        let anchorPoint = NSPoint(x: 14.0, y: anchorY)
        menu.popUp(positioning: nil, at: anchorPoint, in: contentView)
        menu.removeAllItems()
    }

    func createFloatingPlayerFromDraft() {
        guard let item = selectedWindow else { return }
        createFloatingPlayer(for: item, cropRect: draftCropRect ?? .full)
    }

    func closeAllSessions() {
        let current = activeSessions
        activeSessions.removeAll()
        for session in current {
            session.close()
        }
    }
}

// MARK: - Main Window View

struct MainControlView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var discovery: WindowDiscoveryService

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.discovery = coordinator.discovery
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 270, ideal: 300, max: 360)
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await discovery.refreshWindows(loadThumbnails: true)
                        await coordinator.refreshSelectedPreview()
                    }
                } label: {
                    Label("Refresh Windows", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh open windows list (⌘R)")
            }
        }
        .task {
            await coordinator.initialLoad()
        }
    }

    // MARK: - Sidebar (Open Windows + Active Floating Players)

    private var sidebarView: some View {
        let filteredWindows = coordinator.filteredWindows
        return VStack(spacing: 0) {
            // Search filter
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter windows…", text: $coordinator.searchQuery)
                    .textFieldStyle(.plain)
                if !coordinator.searchQuery.isEmpty {
                    Button {
                        coordinator.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            List(
                selection: Binding(
                    get: { coordinator.selectedWindow?.windowID },
                    set: { newID in
                        guard let newID, newID != coordinator.selectedWindow?.windowID else { return }
                        if let item = discovery.windows.first(where: { $0.windowID == newID }) {
                            Task { await coordinator.selectWindow(item) }
                        }
                    }
                )
            ) {
                if !coordinator.activeSessions.isEmpty {
                    Section("Active Floating Players (\(coordinator.activeSessions.count))") {
                        ForEach(coordinator.activeSessions) { session in
                            ActiveSessionRowView(session: session)
                        }
                    }
                }

                Section("Open Windows (\(filteredWindows.count))") {
                    ForEach(filteredWindows) { item in
                        WindowRowView(
                            item: item,
                            thumbnail: discovery.thumbnails[item.windowID],
                            isSelected: coordinator.selectedWindow?.windowID == item.windowID
                        )
                        .tag(item.windowID)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Detail (Interactive Crop Editor & Controls)

    @ViewBuilder
    private var detailView: some View {
        if !discovery.hasScreenRecordingPermission {
            permissionRequiredView
        } else if let windowItem = coordinator.selectedWindow {
            VStack(spacing: 0) {
                // Header Bar
                HStack(spacing: 12) {
                    if let icon = windowItem.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(windowItem.shortTitle)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(windowItem.appName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("•")
                                .foregroundStyle(.quaternary)
                            Text("\(Int(windowItem.frame.width)) × \(Int(windowItem.frame.height)) pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if !windowItem.isOnScreen {
                                Text("Minimized / Off-Screen")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Spacer(minLength: 12)

                    // Compact 2×3 schematic preset grid + Clear button
                    HStack(alignment: .center, spacing: 8) {
                        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                            GridRow {
                                RegionPresetIconButton(
                                    title: "Top Half",
                                    highlightRect: CGRect(x: 0, y: 0, width: 1, height: 0.5),
                                    isActive: coordinator.draftCropRect
                                        == NormalizedCropRect(x: 0, y: 0, width: 1, height: 0.5)
                                ) {
                                    coordinator.draftCropRect = NormalizedCropRect(x: 0, y: 0, width: 1, height: 0.5)
                                }

                                RegionPresetIconButton(
                                    title: "Left Half",
                                    highlightRect: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                                    isActive: coordinator.draftCropRect
                                        == NormalizedCropRect(x: 0, y: 0, width: 0.5, height: 1)
                                ) {
                                    coordinator.draftCropRect = NormalizedCropRect(x: 0, y: 0, width: 0.5, height: 1)
                                }

                                RegionPresetIconButton(
                                    title: "Full Window",
                                    highlightRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    isActive: coordinator.draftCropRect == .full
                                ) {
                                    coordinator.draftCropRect = .full
                                }
                            }
                            GridRow {
                                RegionPresetIconButton(
                                    title: "Bottom Half",
                                    highlightRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
                                    isActive: coordinator.draftCropRect
                                        == NormalizedCropRect(x: 0, y: 0.5, width: 1, height: 0.5)
                                ) {
                                    coordinator.draftCropRect = NormalizedCropRect(x: 0, y: 0.5, width: 1, height: 0.5)
                                }

                                RegionPresetIconButton(
                                    title: "Right Half",
                                    highlightRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                                    isActive: coordinator.draftCropRect
                                        == NormalizedCropRect(x: 0.5, y: 0, width: 0.5, height: 1)
                                ) {
                                    coordinator.draftCropRect = NormalizedCropRect(x: 0.5, y: 0, width: 0.5, height: 1)
                                }

                                RegionPresetIconButton(
                                    title: "Center",
                                    highlightRect: CGRect(x: 0.27, y: 0.27, width: 0.46, height: 0.46),
                                    isActive: coordinator.draftCropRect
                                        == NormalizedCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                                ) {
                                    coordinator.draftCropRect = NormalizedCropRect(
                                        x: 0.25,
                                        y: 0.25,
                                        width: 0.5,
                                        height: 0.5
                                    )
                                }
                            }
                        }

                        Button {
                            coordinator.draftCropRect = nil
                        } label: {
                            Text("Clear")
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 6)
                                .frame(height: 28)
                        }
                        .buttonStyle(.bordered)
                        .disabled(coordinator.draftCropRect == nil)
                        .help("Clear crop selection")
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)

                Divider()

                // Interactive Crop Canvas
                InteractiveCropCanvas(
                    previewImage: coordinator.selectedPreviewImage,
                    windowPointSize: windowItem.frame.size,
                    cropRect: $coordinator.draftCropRect
                )
                .padding(16)

                Divider()

                // Bottom Action Bar
                HStack(spacing: 14) {
                    Spacer()

                    Button {
                        coordinator.createFloatingPlayerFromDraft()
                    } label: {
                        Label("Create Floating Player", systemImage: "pip.enter")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "pip")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text("Select a Window")
                    .font(.title3.weight(.semibold))
                Text("Choose any open window from the sidebar to crop a region and create a floating player.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(32)
        }
    }

    private var permissionRequiredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Screen Recording Permission Required")
                .font(.title2.weight(.semibold))
            Text(
                "PeekPane uses macOS ScreenCaptureKit to stream the selected region of any window into an always-on-top floating player. Please allow Screen Recording access in System Settings."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            Button("Request Permission") {
                Task { await coordinator.requestPermissionAndLoad() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
    }
}

// MARK: - Sidebar Row Views

private struct RegionPresetIconButton: View {
    let title: String
    let highlightRect: CGRect
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Canvas { context, size in
                let outer = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                let framePath = Path(roundedRect: outer, cornerRadius: 2.5)
                context.stroke(
                    framePath,
                    with: .color(isActive ? .accentColor : .primary.opacity(0.75)),
                    lineWidth: 1.2
                )

                let inner = outer.insetBy(dx: 2.0, dy: 2.0)
                let fillRect = CGRect(
                    x: inner.minX + highlightRect.minX * inner.width,
                    y: inner.minY + highlightRect.minY * inner.height,
                    width: highlightRect.width * inner.width,
                    height: highlightRect.height * inner.height
                )
                let fillPath = Path(roundedRect: fillRect, cornerRadius: 1.2)
                context.fill(
                    fillPath,
                    with: .color(isActive ? .accentColor : .primary.opacity(0.85))
                )
            }
            .frame(width: 16, height: 12)
        }
        .controlSize(.mini)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct WindowRowView: View {
    let item: ShareableWindowItem
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 54, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 54, height: 36)
                }

                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.shortTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(item.appName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

private struct ActiveSessionRowView: View {
    @ObservedObject var session: FloatingPlayerSession

    var body: some View {
        HStack(spacing: 8) {
            if let icon = session.windowItem.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.windowItem.shortTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(
                            session.isSourceClosed
                                ? Color.red : (session.isSourceMinimized ? Color.orange : Color.green)
                        )
                        .frame(width: 6, height: 6)
                    Text(session.isSourceClosed ? "Closed" : (session.isClickThrough ? "Click-Through" : "Live PiP"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if session.isClickThrough {
                Button {
                    session.isClickThrough = false
                } label: {
                    Image(nsImage: GhostIconRenderer.templateImage(size: 14))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Disable Ghost Mode")
            }

            Button {
                session.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close floating player")
        }
        .padding(.vertical, 2)
    }
}

@MainActor
private final class MenuActionTarget: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler()
    }
}

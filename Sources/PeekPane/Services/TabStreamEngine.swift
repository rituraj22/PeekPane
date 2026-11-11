import CoreGraphics
import Foundation
import os

final class TabStreamEngine: CaptureStreamEngine, @unchecked Sendable {
    private struct PendingFrameState: @unchecked Sendable {
        var latestPayload: CaptureFramePayload?
        var isDeliveryScheduled: Bool = false
    }

    private let streamKey: TabStreamKey
    private weak var bridgeServer: BrowserBridgeServer?
    private let frameLock = OSAllocatedUnfairLock(initialState: PendingFrameState())
    private var subscriberID: UUID?
    private var isStopped: Bool = false

    @MainActor var onFrame: (@MainActor (CaptureFramePayload) -> Void)?
    @MainActor var onInitialImage: (@MainActor (CGImage, CGSize) -> Void)?
    @MainActor var onStateChange:
        (@MainActor (_ isStreaming: Bool, _ isMinimized: Bool, _ isClosed: Bool, _ errorText: String?) -> Void)?

    @MainActor
    init(streamKey: TabStreamKey, bridgeServer: BrowserBridgeServer) {
        self.streamKey = streamKey
        self.bridgeServer = bridgeServer
    }

    @MainActor
    func start(showsCursor: Bool) async {
        _ = showsCursor
        guard !isStopped else { return }
        if let existingID = subscriberID {
            bridgeServer?.unsubscribe(from: streamKey, subscriberID: existingID)
            subscriberID = nil
        }

        let subscriber = BrowserBridgeServer.TabStreamSubscriber(
            onFrame: { [weak self] payload in
                self?.enqueueCoalescedFrame(payload)
            },
            onStateChange: { [weak self] isStreaming, isMinimized, isClosed, errorText in
                guard let self, !self.isStopped else { return }
                self.onStateChange?(isStreaming, isMinimized, isClosed, errorText)
            }
        )
        subscriberID = bridgeServer?.subscribe(to: streamKey, subscriber: subscriber)
    }

    @MainActor
    func updateShowsCursor(_ show: Bool) async {
        _ = show
    }

    @MainActor
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        frameLock.withLock { state in
            state.latestPayload = nil
            state.isDeliveryScheduled = false
        }
        onFrame = nil
        onInitialImage = nil
        onStateChange = nil
        if let activeID = subscriberID {
            subscriberID = nil
            bridgeServer?.unsubscribe(from: streamKey, subscriberID: activeID)
        }
    }

    private func enqueueCoalescedFrame(_ payload: CaptureFramePayload) {
        let shouldSchedule = frameLock.withLock { state -> Bool in
            state.latestPayload = payload
            if state.isDeliveryScheduled {
                return false
            }
            state.isDeliveryScheduled = true
            return true
        }
        if shouldSchedule {
            Task { @MainActor [weak self] in
                self?.drainPendingFrame()
            }
        }
    }

    @MainActor
    private func drainPendingFrame() {
        let payload = frameLock.withLock { state -> CaptureFramePayload? in
            let next = state.latestPayload
            state.latestPayload = nil
            state.isDeliveryScheduled = false
            return next
        }
        guard !isStopped, let payload else { return }
        onFrame?(payload)
    }
}

import ApplicationServices
import Foundation

enum WindowFocusHelper {
    struct TargetWindowSnapshot {
        let frame: CGRect
        let title: String
        let zRankInApp: Int
        let totalAppWindows: Int
    }

    static func inspectTargetWindow(
        pid: pid_t,
        windowID: CGWindowID,
        fallbackTitle: String,
        fallbackFrame: CGRect
    ) -> TargetWindowSnapshot {
        guard pid != 0,
            let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return TargetWindowSnapshot(
                frame: fallbackFrame,
                title: fallbackTitle,
                zRankInApp: 0,
                totalAppWindows: 1
            )
        }

        var rank = 0
        var matchedRank = 0
        var matchedFrame = fallbackFrame
        var matchedTitle = fallbackTitle

        for entry in list {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (entry[kCGWindowLayer as String] as? Int) == 0
            else { continue }

            let entryWID = (entry[kCGWindowNumber as String] as? UInt32) ?? 0
            if entryWID == windowID {
                matchedRank = rank
                if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                    let rect = CGRect(dictionaryRepresentation: boundsDict)
                {
                    matchedFrame = rect
                }
                if let name = entry[kCGWindowName as String] as? String, !name.isEmpty {
                    matchedTitle = name
                }
            }
            rank += 1
        }

        return TargetWindowSnapshot(
            frame: matchedFrame,
            title: matchedTitle,
            zRankInApp: matchedRank,
            totalAppWindows: max(1, rank)
        )
    }

    private static func axWindowFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let posVal = posRef,
            let sizeVal = sizeRef,
            CFGetTypeID(posVal) == AXValueGetTypeID(),
            CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        // Safe cast after verifying CFGetTypeID == AXValueGetTypeID()
        let axPos = unsafeDowncast(posVal, to: AXValue.self)
        let axSize = unsafeDowncast(sizeVal, to: AXValue.self)
        guard AXValueGetValue(axPos, .cgPoint, &point),
            AXValueGetValue(axSize, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    static func raiseSpecificAXWindow(
        pid: pid_t,
        snapshot: TargetWindowSnapshot
    ) -> Bool {
        guard pid != 0, AXIsProcessTrusted() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let axWindows = windowsRef as? [AXUIElement],
            !axWindows.isEmpty
        else { return false }

        var bestWindow: AXUIElement?
        var bestScore = Int.min

        for (index, axWin) in axWindows.enumerated() {
            var score = 0

            if let rect = axWindowFrame(axWin) {
                let dx = abs(rect.origin.x - snapshot.frame.origin.x)
                let dy = abs(rect.origin.y - snapshot.frame.origin.y)
                let dw = abs(rect.width - snapshot.frame.width)
                let dh = abs(rect.height - snapshot.frame.height)
                if dx <= 8 && dy <= 8 && dw <= 8 && dh <= 8 {
                    score += 100
                } else if dw <= 8 && dh <= 8 {
                    score += 30
                }
            }

            if !snapshot.title.isEmpty {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
                    let axTitle = titleRef as? String,
                    !axTitle.isEmpty
                {
                    if axTitle == snapshot.title {
                        score += 60
                    } else if axTitle.localizedCaseInsensitiveContains(snapshot.title)
                        || snapshot.title.localizedCaseInsensitiveContains(axTitle)
                    {
                        score += 25
                    }
                }
            }

            if index == snapshot.zRankInApp {
                score += 20
            }

            if score > bestScore {
                bestScore = score
                bestWindow = axWin
            }
        }

        guard let targetWin = bestWindow else { return false }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(targetWin, kAXMinimizedAttribute as CFString, &minRef) == .success,
            let isMin = minRef as? Bool,
            isMin
        {
            AXUIElementSetAttributeValue(targetWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        AXUIElementPerformAction(targetWin, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(targetWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(targetWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return true
    }

    static func resetStaleAccessibilityTCCEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Ignore if tccutil is unavailable
        }
    }
}

import AppKit
import ApplicationServices

@MainActor
final class InteractionProxy {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private var latestTrace: [String] = []

    func latestInteractionTrace() -> [String] {
        latestTrace
    }

    func perform(_ interaction: StatusItemInteraction, on item: StatusItemModel) -> Bool {
        let allowAXAction = shouldAttemptAXAction(for: item)
        latestTrace = []
        let fallbackPoint = preferredClickPoint(for: item)
        let resolvedTarget = resolveTarget(for: item, interaction: interaction)
        let resolvedPoint = safeResolvedPoint(
            resolvedTarget?.clickPoint,
            expectedFrame: item.frameInScreen,
            fallbackPoint: fallbackPoint
        )

        record(
            "Interaction start type=\(describe(interaction)) source=\(item.source.rawValue) item=\(item.displayName) frame=(x:\(Int(item.frameInScreen.minX)) y:\(Int(item.frameInScreen.minY)) w:\(Int(item.frameInScreen.width)) h:\(Int(item.frameInScreen.height))) fallback=\(pointDescription(fallbackPoint)) resolved=\(pointDescription(resolvedPoint)) hasAXTarget=\(resolvedTarget != nil) allowAXAction=\(allowAXAction)"
        )

        if performSyntheticMouseInteraction(interaction, at: resolvedPoint) {
            record("Interaction success via synthetic mouse at resolved point")
            return true
        }

        if interaction == .rightClick, performSyntheticControlLeftClick(at: resolvedPoint) {
            record("Interaction success via control+left at resolved point")
            return true
        }

        if allowAXAction, let resolvedTarget, performAXInteraction(interaction, on: resolvedTarget.element) {
            record("Interaction success via AX target")
            return true
        }

        guard resolvedPoint != fallbackPoint else {
            record("Interaction failed: resolved point equals fallback and all attempts exhausted", isError: true)
            return false
        }

        if performSyntheticMouseInteraction(interaction, at: fallbackPoint) {
            record("Interaction success via synthetic mouse at fallback point")
            return true
        }

        if interaction == .rightClick, performSyntheticControlLeftClick(at: fallbackPoint) {
            record("Interaction success via control+left at fallback point")
            return true
        }

        if allowAXAction, let resolvedTarget, performAXInteraction(interaction, on: resolvedTarget.element) {
            record("Interaction success via AX target after fallback attempts")
            return true
        }

        record("Interaction failed after all fallback paths", isError: true)
        return false
    }

    private func shouldAttemptAXAction(for item: StatusItemModel) -> Bool {
        if item.source == .screenshot, item.ownerBundleID == nil {
            return false
        }

        if item.role == "Screenshot" {
            return false
        }

        return true
    }

    private func resolveTarget(
        for item: StatusItemModel,
        interaction: StatusItemInteraction
    ) -> ResolvedAXTarget? {
        let primaryAction = primaryAXAction(for: interaction).rawValue
        let secondaryAction = secondaryAXAction(for: interaction).rawValue
        let expectedBundleID = item.ownerBundleID
        let expectedRole = item.role

        var best: ResolvedAXTarget?

        for probePoint in interactionProbePoints(for: item) {
            for point in axProbePoints(for: probePoint) {
                guard let baseElement = element(at: point) else {
                    continue
                }

                let chain = ancestorChain(startingAt: baseElement, depthLimit: 6)
                for (depth, candidateElement) in chain.enumerated() {
                    let actions = actionNames(for: candidateElement)
                    let supportsPrimary = actions.contains(primaryAction)
                    let supportsSecondary = actions.contains(secondaryAction)

                    if !supportsPrimary, !supportsSecondary {
                        continue
                    }

                    let candidateFrame = frameAttribute(from: candidateElement)
                    if let candidateFrame,
                       !isPlausibleMenuItemFrame(candidateFrame, expectedFrame: item.frameInScreen) {
                        continue
                    }

                    let candidatePoint = candidateFrame.map { clampPointToFrameCenter($0) } ?? point
                    let candidateRole = stringAttribute(kAXRoleAttribute as String, from: candidateElement)
                    let candidateBundleID = bundleIdentifier(for: candidateElement)
                    let score = scoreTarget(
                        supportsPrimary: supportsPrimary,
                        supportsSecondary: supportsSecondary,
                        depth: depth,
                        probePoint: probePoint,
                        candidatePoint: candidatePoint,
                        candidateFrame: candidateFrame,
                        expectedFrame: item.frameInScreen,
                        candidateBundleID: candidateBundleID,
                        expectedBundleID: expectedBundleID,
                        candidateRole: candidateRole,
                        expectedRole: expectedRole
                    )

                    if score > (best?.score ?? .min) {
                        best = ResolvedAXTarget(
                            element: candidateElement,
                            clickPoint: candidatePoint,
                            score: score
                        )
                    }
                }
            }
        }

        return best
    }

    private func safeResolvedPoint(
        _ resolvedPoint: CGPoint?,
        expectedFrame: CGRect,
        fallbackPoint: CGPoint
    ) -> CGPoint {
        guard let resolvedPoint else {
            return fallbackPoint
        }

        let expandedExpected = expectedFrame.insetBy(dx: -24, dy: -10)
        if expandedExpected.contains(resolvedPoint) {
            return resolvedPoint
        }

        if hypot(resolvedPoint.x - fallbackPoint.x, resolvedPoint.y - fallbackPoint.y) <= 80 {
            return resolvedPoint
        }

        return fallbackPoint
    }

    private func isPlausibleMenuItemFrame(_ candidate: CGRect, expectedFrame: CGRect) -> Bool {
        if candidate.width < 8 || candidate.width > 120 {
            return false
        }
        if candidate.height < 8 || candidate.height > 44 {
            return false
        }

        let expandedExpected = expectedFrame.insetBy(dx: -90, dy: -24)
        return expandedExpected.intersects(candidate)
    }

    private func scoreTarget(
        supportsPrimary: Bool,
        supportsSecondary: Bool,
        depth: Int,
        probePoint: CGPoint,
        candidatePoint: CGPoint,
        candidateFrame: CGRect?,
        expectedFrame: CGRect,
        candidateBundleID: String?,
        expectedBundleID: String?,
        candidateRole: String?,
        expectedRole: String?
    ) -> Int {
        var score = 0

        if supportsPrimary {
            score += 18
        }
        if supportsSecondary {
            score += 8
        }
        if let expectedBundleID, let candidateBundleID, candidateBundleID == expectedBundleID {
            score += 10
        }
        if let expectedRole, let candidateRole, candidateRole == expectedRole {
            score += 3
        }
        if candidateRole == "AXMenuBarItem" {
            score += 2
        }
        if let candidateFrame {
            let expandedExpected = expectedFrame.insetBy(dx: -18, dy: -8)
            if candidateFrame.intersects(expandedExpected) {
                score += 8
            }
        }

        let distancePenalty = Int((hypot(candidatePoint.x - probePoint.x, candidatePoint.y - probePoint.y) / 12).rounded())
        score -= distancePenalty
        score -= depth
        return score
    }

    private func performAXInteraction(_ interaction: StatusItemInteraction, on element: AXUIElement) -> Bool {
        let primary = primaryAXAction(for: interaction)
        let secondary = secondaryAXAction(for: interaction)
        let chain = ancestorChain(startingAt: element, depthLimit: 6)

        for candidate in chain where performAXAction(primary, on: candidate) {
            return true
        }
        for candidate in chain where performAXAction(secondary, on: candidate) {
            return true
        }

        return false
    }

    private func primaryAXAction(for interaction: StatusItemInteraction) -> AXAction {
        switch interaction {
        case .leftClick:
            return .press
        case .rightClick:
            return .showMenu
        }
    }

    private func secondaryAXAction(for interaction: StatusItemInteraction) -> AXAction {
        switch interaction {
        case .leftClick:
            return .showMenu
        case .rightClick:
            return .press
        }
    }

    private func performAXAction(_ action: AXAction, on element: AXUIElement) -> Bool {
        let supportedActions = actionNames(for: element)
        guard supportedActions.contains(action.rawValue) else {
            return false
        }

        let result = AXUIElementPerformAction(element, action.rawValue as CFString)
        return result == .success
    }

    private func performSyntheticMouseInteraction(_ interaction: StatusItemInteraction, at point: CGPoint) -> Bool {
        let tap: CGEventTapLocation = .cghidEventTap
        let eventPoint = syntheticMouseEventPoint(for: point)
        let succeeded: Bool
        switch interaction {
        case .leftClick:
            succeeded = synthesizeMouseClick(
                at: eventPoint,
                button: .left,
                flags: [],
                tap: tap
            )
        case .rightClick:
            succeeded = synthesizeMouseClick(
                at: eventPoint,
                button: .right,
                flags: [],
                tap: tap
            )
        }

        if succeeded {
            record(
                "Synthetic click posted target=\(pointDescription(point)) event=\(pointDescription(eventPoint)) tap=\(tapDescription(tap))"
            )
        }
        return succeeded
    }

    private func performSyntheticControlLeftClick(at point: CGPoint) -> Bool {
        let tap: CGEventTapLocation = .cghidEventTap
        let eventPoint = syntheticMouseEventPoint(for: point)
        let succeeded = synthesizeMouseClick(
            at: eventPoint,
            button: .left,
            flags: .maskControl,
            tap: tap
        )
        if succeeded {
            record(
                "Synthetic control-left posted target=\(pointDescription(point)) event=\(pointDescription(eventPoint)) tap=\(tapDescription(tap))"
            )
        }
        return succeeded
    }

    private func syntheticMouseEventPoint(for point: CGPoint) -> CGPoint {
        let resolvedScreen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) ??
            NSScreen.screens.first(where: { point.x >= $0.frame.minX - 1 && point.x <= $0.frame.maxX + 1 })
        guard let screen = resolvedScreen else {
            return point
        }

        let localY = point.y - screen.frame.minY
        let quartzY = screen.frame.maxY - localY
        return CGPoint(x: point.x, y: quartzY)
    }

    private func synthesizeMouseClick(_ interaction: StatusItemInteraction, at point: CGPoint) -> Bool {
        switch interaction {
        case .leftClick:
            return synthesizeMouseClick(at: point, button: .left, flags: [], tap: .cghidEventTap)
        case .rightClick:
            return synthesizeMouseClick(at: point, button: .right, flags: [], tap: .cghidEventTap)
        }
    }

    private func synthesizeControlLeftClick(at point: CGPoint) -> Bool {
        synthesizeMouseClick(at: point, button: .left, flags: .maskControl, tap: .cghidEventTap)
    }

    private func synthesizeMouseClick(
        at point: CGPoint,
        button: CGMouseButton,
        flags: CGEventFlags,
        tap: CGEventTapLocation
    ) -> Bool {
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: point,
                mouseButton: button
            ),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: upType,
                mouseCursorPosition: point,
                mouseButton: button
            )
        else {
            return false
        }

        down.flags = flags
        up.flags = flags
        down.post(tap: tap)
        up.post(tap: tap)
        return true
    }

    private func interactionProbePoints(for item: StatusItemModel) -> [CGPoint] {
        let frame = item.frameInScreen
        let insetFrame = frame.insetBy(
            dx: min(6, max(1, frame.width * 0.18)),
            dy: min(4, max(1, frame.height * 0.2))
        )

        let preferred = preferredClickPoint(for: item)
        let topY = min(max(insetFrame.minY + 1, frame.minY + 1), frame.maxY - 1)
        let middleY = min(max(frame.midY, frame.minY + 1), frame.maxY - 1)
        let lowY = max(frame.minY + 1, min(frame.maxY - 1, frame.midY - 4))
        let leftX = max(frame.minX + 1, min(frame.maxX - 1, insetFrame.minX + 2))
        let midX = min(max(frame.midX, frame.minX + 1), frame.maxX - 1)
        let rightX = min(frame.maxX - 1, max(frame.minX + 1, insetFrame.maxX - 2))

        return deduplicatedPoints([
            preferred,
            item.interactionPoint,
            CGPoint(x: midX, y: middleY),
            CGPoint(x: midX, y: topY),
            CGPoint(x: midX, y: lowY),
            CGPoint(x: leftX, y: middleY),
            CGPoint(x: rightX, y: middleY),
        ])
    }

    private func axProbePoints(for point: CGPoint) -> [CGPoint] {
        var probes = [point]

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let flippedY = screen.frame.maxY - (point.y - screen.frame.minY)
            let flippedPoint = CGPoint(x: point.x, y: flippedY)
            probes.append(flippedPoint)
        }

        return deduplicatedPoints(probes)
    }

    private func preferredClickPoint(for item: StatusItemModel) -> CGPoint {
        let frame = item.frameInScreen
        let x = min(max(item.interactionPoint.x, frame.minX + 1), frame.maxX - 1)
        let y = min(max(item.interactionPoint.y, frame.minY + 1), frame.maxY - 1)
        return CGPoint(x: x, y: y)
    }

    private func deduplicatedPoints(_ points: [CGPoint]) -> [CGPoint] {
        var seen: Set<String> = []
        var result: [CGPoint] = []

        for point in points {
            let key = "\(Int(point.x.rounded()))-\(Int(point.y.rounded()))"
            if seen.insert(key).inserted {
                result.append(point)
            }
        }

        return result
    }

    private func clampPointToFrameCenter(_ frame: CGRect) -> CGPoint {
        let x = min(max(frame.midX, frame.minX + 1), frame.maxX - 1)
        let y = min(max(frame.midY, frame.minY + 1), frame.maxY - 1)
        return CGPoint(x: x, y: y)
    }

    private func ancestorChain(startingAt element: AXUIElement, depthLimit: Int) -> [AXUIElement] {
        var chain: [AXUIElement] = [element]
        var current: AXUIElement? = element
        var depth = 0

        while depth < depthLimit,
              let currentElement = current,
              let parent = copyElementAttribute(kAXParentAttribute as String, from: currentElement) {
            chain.append(parent)
            current = parent
            depth += 1
        }

        return chain
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        var target: AXUIElement?
        let lookupResult = AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &target)
        guard lookupResult == .success, let target else {
            return nil
        }
        return target
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success, let actions = actions as? [String] else {
            return []
        }
        return actions
    }

    private func bundleIdentifier(for element: AXUIElement) -> String? {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success, pid > 0 else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private func frameAttribute(from element: AXUIElement) -> CGRect? {
        guard
            let positionReference = copyAttributeValue(kAXPositionAttribute as String, from: element),
            let sizeReference = copyAttributeValue(kAXSizeAttribute as String, from: element),
            CFGetTypeID(positionReference) == AXValueGetTypeID(),
            CFGetTypeID(sizeReference) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionValue = unsafeBitCast(positionReference, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeReference, to: AXValue.self)

        var position = CGPoint.zero
        var size = CGSize.zero

        guard
            AXValueGetType(positionValue) == .cgPoint,
            AXValueGetValue(positionValue, .cgPoint, &position),
            AXValueGetType(sizeValue) == .cgSize,
            AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        if let value = copyAttributeValue(attribute, from: element) as? String {
            return value
        }

        if let attributed = copyAttributeValue(attribute, from: element) as? NSAttributedString {
            return attributed.string
        }

        return nil
    }

    private func copyAttributeValue(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }
        return value
    }

    private func describe(_ interaction: StatusItemInteraction) -> String {
        switch interaction {
        case .leftClick:
            return "left"
        case .rightClick:
            return "right"
        }
    }

    private func pointDescription(_ point: CGPoint) -> String {
        "(\(Int(point.x.rounded())),\(Int(point.y.rounded())))"
    }

    private func tapDescription(_ tap: CGEventTapLocation) -> String {
        switch tap {
        case .cghidEventTap:
            return "hid"
        case .cgSessionEventTap:
            return "session"
        case .cgAnnotatedSessionEventTap:
            return "annotated"
        @unknown default:
            return "unknown"
        }
    }

    private func record(_ message: String, isError: Bool = false) {
        latestTrace.append(message)
        if isError {
            Logger.error(message)
        } else {
            Logger.info(message)
        }
    }
}

private struct ResolvedAXTarget {
    let element: AXUIElement
    let clickPoint: CGPoint
    let score: Int
}

private enum AXAction: String {
    case press = "AXPress"
    case showMenu = "AXShowMenu"
}

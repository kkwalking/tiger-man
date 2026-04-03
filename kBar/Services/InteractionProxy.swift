import AppKit
import ApplicationServices

@MainActor
final class InteractionProxy {
    private let systemWideElement = AXUIElementCreateSystemWide()
    private var latestTrace: [String] = []
    private var latestResult = InteractionExecutionResult()
    private let hiddenAXActionTimeouts: [Float] = [0.6, 1.4, 2.5]
    private let defaultAXActionTimeouts: [Float] = [0.4]

    func latestInteractionTrace() -> [String] {
        latestTrace
    }

    func latestInteractionResult() -> InteractionExecutionResult {
        latestResult
    }

    func perform(_ interaction: StatusItemInteraction, on item: StatusItemModel) -> Bool {
        let allowAXAction = shouldAttemptAXAction(for: item)
        latestTrace = []
        let isHiddenItem = !item.isVisibleInMenuBar
        let storedDirectAXElement = item.directAXElement
        latestResult = InteractionExecutionResult(isHiddenItem: isHiddenItem)

        if isHiddenItem {
            record(
                "Interaction start type=\(describe(interaction)) source=\(item.source.rawValue) item=\(item.displayName) hidden=true directAX=\(storedDirectAXElement != nil)"
            )
            if let storedDirectAXElement,
               performAXInteraction(interaction, on: storedDirectAXElement, context: "hidden-direct") {
                latestResult.succeeded = true
                latestResult.usedAXAction = true
                latestResult.usedStoredDirectAXTarget = true
                record("Interaction success via direct AX target for hidden item")
                return true
            }
            if storedDirectAXElement != nil {
                record("Interaction direct AX attempt failed for hidden item; continuing with fallback paths")
            }
        }

        let fallbackPoint = preferredClickPoint(for: item)
        let resolvedTarget = shouldResolveDynamicTarget(for: item) ? resolveTarget(for: item, interaction: interaction) : nil
        let resolvedPoint = safeResolvedPoint(
            resolvedTarget?.clickPoint,
            expectedFrame: item.frameInScreen,
            fallbackPoint: fallbackPoint
        )

        record(
            "Interaction start type=\(describe(interaction)) source=\(item.source.rawValue) item=\(item.displayName) frame=(x:\(Int(item.frameInScreen.minX)) y:\(Int(item.frameInScreen.minY)) w:\(Int(item.frameInScreen.width)) h:\(Int(item.frameInScreen.height))) fallback=\(pointDescription(fallbackPoint)) resolved=\(pointDescription(resolvedPoint)) hasAXTarget=\(resolvedTarget != nil) allowAXAction=\(allowAXAction)"
        )

        if isHiddenItem,
           allowAXAction,
           let resolvedTarget,
           performAXInteraction(interaction, on: resolvedTarget.element, context: "hidden-resolved") {
            latestResult.succeeded = true
            latestResult.usedAXAction = true
            latestResult.usedResolvedAXTarget = true
            record("Interaction success via AX target for hidden item")
            return true
        }

        if performSyntheticMouseInteraction(
            interaction,
            at: resolvedPoint,
            preferredTaps: syntheticMouseTaps(forHiddenItem: isHiddenItem)
        ) {
            latestResult.succeeded = true
            latestResult.usedSyntheticMouseFallback = true
            record("Interaction success via synthetic mouse at resolved point")
            return true
        }

        if interaction == .rightClick,
           performSyntheticControlLeftClick(
            at: resolvedPoint,
            preferredTaps: syntheticMouseTaps(forHiddenItem: isHiddenItem)
           ) {
            latestResult.succeeded = true
            latestResult.usedControlLeftFallback = true
            record("Interaction success via control+left at resolved point")
            return true
        }

        if allowAXAction, let resolvedTarget, performAXInteraction(interaction, on: resolvedTarget.element, context: "resolved") {
            latestResult.succeeded = true
            latestResult.usedAXAction = true
            latestResult.usedResolvedAXTarget = true
            record("Interaction success via AX target")
            return true
        }

        if allowAXAction, let directAXElement = storedDirectAXElement, performAXInteraction(interaction, on: directAXElement, context: "stored-direct") {
            latestResult.succeeded = true
            latestResult.usedAXAction = true
            latestResult.usedStoredDirectAXTarget = true
            record("Interaction success via stored direct AX target")
            return true
        }

        guard resolvedPoint != fallbackPoint else {
            record("Interaction failed: resolved point equals fallback and all attempts exhausted", isError: true)
            return false
        }

        if performSyntheticMouseInteraction(
            interaction,
            at: fallbackPoint,
            preferredTaps: syntheticMouseTaps(forHiddenItem: isHiddenItem)
        ) {
            latestResult.succeeded = true
            latestResult.usedSyntheticMouseFallback = true
            record("Interaction success via synthetic mouse at fallback point")
            return true
        }

        if interaction == .rightClick,
           performSyntheticControlLeftClick(
            at: fallbackPoint,
            preferredTaps: syntheticMouseTaps(forHiddenItem: isHiddenItem)
           ) {
            latestResult.succeeded = true
            latestResult.usedControlLeftFallback = true
            record("Interaction success via control+left at fallback point")
            return true
        }

        if allowAXAction, let resolvedTarget, performAXInteraction(interaction, on: resolvedTarget.element, context: "resolved-after-fallback") {
            latestResult.succeeded = true
            latestResult.usedAXAction = true
            latestResult.usedResolvedAXTarget = true
            record("Interaction success via AX target after fallback attempts")
            return true
        }

        if allowAXAction, let directAXElement = storedDirectAXElement, performAXInteraction(interaction, on: directAXElement, context: "stored-direct-after-fallback") {
            latestResult.succeeded = true
            latestResult.usedAXAction = true
            latestResult.usedStoredDirectAXTarget = true
            record("Interaction success via stored direct AX target after fallback attempts")
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

    private func shouldResolveDynamicTarget(for item: StatusItemModel) -> Bool {
        if item.source == .screenshot, item.ownerBundleID == nil {
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

    private func performAXInteraction(
        _ interaction: StatusItemInteraction,
        on element: AXUIElement,
        context: String
    ) -> Bool {
        let primary = primaryAXAction(for: interaction)
        let secondary = secondaryAXAction(for: interaction)
        let chain = ancestorChain(startingAt: element, depthLimit: 6)

        record(
            "AX chain context=\(context) interaction=\(describe(interaction)) candidateCount=\(chain.count) origin=\(elementSummary(element))"
        )

        let timeouts = axActionTimeouts(for: context)

        for candidate in chain where performAXAction(primary, on: candidate, context: context, timeouts: timeouts) {
            return true
        }
        for candidate in chain where performAXAction(secondary, on: candidate, context: context, timeouts: timeouts) {
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

    private func performAXAction(
        _ action: AXAction,
        on element: AXUIElement,
        context: String,
        timeouts: [Float]
    ) -> Bool {
        let supportedActions = actionNames(for: element)
        guard supportedActions.contains(action.rawValue) else {
            record(
                "AX action skipped context=\(context) action=\(action.rawValue) reason=unsupported element=\(elementSummary(element)) supported=\(supportedActions.joined(separator: ","))"
            )
            return false
        }

        let attemptTimeouts = timeouts.isEmpty ? defaultAXActionTimeouts : timeouts
        for (index, timeout) in attemptTimeouts.enumerated() {
            applyAXMessagingTimeout(timeout, to: element)
            let result = AXUIElementPerformAction(element, action.rawValue as CFString)
            if result == .success {
                record(
                    "AX action success context=\(context) action=\(action.rawValue) attempt=\(index + 1) timeout=\(timeout) element=\(elementSummary(element))"
                )
                return true
            }

            record(
                "AX action failed context=\(context) action=\(action.rawValue) attempt=\(index + 1) timeout=\(timeout) error=\(describe(result)) element=\(elementSummary(element)) supported=\(supportedActions.joined(separator: ","))",
                isError: true
            )

            if result != .cannotComplete {
                break
            }
        }

        return false
    }

    private func performSyntheticMouseInteraction(
        _ interaction: StatusItemInteraction,
        at point: CGPoint,
        preferredTaps: [CGEventTapLocation]
    ) -> Bool {
        let eventPoint = syntheticMouseEventPoint(for: point)
        for tap in preferredTaps {
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
                return true
            }
        }
        return false
    }

    private func performSyntheticControlLeftClick(
        at point: CGPoint,
        preferredTaps: [CGEventTapLocation]
    ) -> Bool {
        let eventPoint = syntheticMouseEventPoint(for: point)
        for tap in preferredTaps {
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
                return true
            }
        }
        return false
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
        usleep(40_000)
        up.post(tap: tap)
        return true
    }

    private func syntheticMouseTaps(forHiddenItem isHiddenItem: Bool) -> [CGEventTapLocation] {
        if isHiddenItem {
            return [.cgSessionEventTap, .cgAnnotatedSessionEventTap, .cghidEventTap]
        }

        return [.cghidEventTap]
    }

    private func axActionTimeouts(for context: String) -> [Float] {
        if context.hasPrefix("hidden-") || context.contains("stored-direct") {
            return hiddenAXActionTimeouts
        }

        return defaultAXActionTimeouts
    }

    private func applyAXMessagingTimeout(_ timeout: Float, to element: AXUIElement) {
        let result = AXUIElementSetMessagingTimeout(element, timeout)
        if result != .success {
            record(
                "AX timeout set failed timeout=\(timeout) error=\(describe(result)) element=\(elementSummary(element))",
                isError: true
            )
        }
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

        return normalizeAccessibilityFrame(CGRect(origin: position, size: size))
    }

    private func normalizeAccessibilityFrame(_ frame: CGRect) -> CGRect {
        guard !NSScreen.screens.isEmpty else {
            return frame
        }

        let matchingScreens = NSScreen.screens.filter { screen in
            frame.midX >= screen.frame.minX - 1 && frame.midX <= screen.frame.maxX + 1
        }
        let screen = matchingScreens.first ?? NSScreen.screens.first!

        let flippedY = screen.frame.maxY - (frame.minY - screen.frame.minY) - frame.height
        return CGRect(x: frame.minX, y: flippedY, width: frame.width, height: frame.height)
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

    private func elementSummary(_ element: AXUIElement) -> String {
        let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? "nil"
        let subrole = stringAttribute(kAXSubroleAttribute as String, from: element) ?? "nil"
        let title = stringAttribute(kAXTitleAttribute as String, from: element) ?? "nil"
        let bundleID = bundleIdentifier(for: element) ?? "nil"
        let frame = frameAttribute(from: element).map(rectDescription) ?? "nil"
        return "role=\(role) subrole=\(subrole) title=\(title) bundle=\(bundleID) frame=\(frame)"
    }

    private func rectDescription(_ rect: CGRect) -> String {
        "(x:\(Int(rect.minX.rounded())) y:\(Int(rect.minY.rounded())) w:\(Int(rect.width.rounded())) h:\(Int(rect.height.rounded())))"
    }

    private func describe(_ error: AXError) -> String {
        switch error {
        case .success:
            return "success"
        case .failure:
            return "failure"
        case .illegalArgument:
            return "illegalArgument"
        case .invalidUIElement:
            return "invalidUIElement"
        case .invalidUIElementObserver:
            return "invalidUIElementObserver"
        case .cannotComplete:
            return "cannotComplete"
        case .attributeUnsupported:
            return "attributeUnsupported"
        case .actionUnsupported:
            return "actionUnsupported"
        case .notificationUnsupported:
            return "notificationUnsupported"
        case .notImplemented:
            return "notImplemented"
        case .notificationAlreadyRegistered:
            return "notificationAlreadyRegistered"
        case .notificationNotRegistered:
            return "notificationNotRegistered"
        case .apiDisabled:
            return "apiDisabled"
        case .noValue:
            return "noValue"
        case .parameterizedAttributeUnsupported:
            return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision:
            return "notEnoughPrecision"
        @unknown default:
            return "unknown(\(error.rawValue))"
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

struct InteractionExecutionResult {
    var succeeded = false
    var isHiddenItem = false
    var usedSyntheticMouseFallback = false
    var usedControlLeftFallback = false
    var usedAXAction = false
    var usedResolvedAXTarget = false
    var usedStoredDirectAXTarget = false

    init(isHiddenItem: Bool = false) {
        self.isHiddenItem = isHiddenItem
    }

    var shouldSuppressAutomaticRefresh: Bool {
        succeeded && isHiddenItem && (usedSyntheticMouseFallback || usedControlLeftFallback)
    }
}

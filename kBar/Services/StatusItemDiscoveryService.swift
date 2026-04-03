import AppKit
import ApplicationServices
import Foundation

struct DiscoveryResult {
    let items: [StatusItemModel]
    let menuBarFrame: CGRect
    let diagnostics: [String]
    let hiddenDiagnostics: [String]
}

private struct ScreenshotFallbackResult {
    let candidates: [DiscoveredCandidate]
    let diagnostics: [String]
}

private struct CandidateFilterSnapshot {
    let name: String
    let items: [DiscoveredCandidate]
}

private struct CandidateScanRegion {
    let minX: CGFloat
    let maxX: CGFloat
    let mode: String
}

private struct HiddenProbeNode {
    let element: AXUIElement
    let probeSource: String
    let title: String
    let role: String
    let subrole: String?
    let frame: CGRect?
    let ownerName: String?
    let bundleID: String?
    let path: String
    let parentRoles: [String]
    let actions: [String]
    let classification: String

    var isAppleOwned: Bool {
        guard let bundleID else {
            return false
        }
        return bundleID.hasPrefix("com.apple.")
    }

    var hasKnownOwner: Bool {
        bundleID != nil
    }

    func debugLine(index: Int) -> String {
        let owner = ownerName ?? "nil"
        let bundle = bundleID ?? "nil"
        let subrole = subrole ?? "nil"
        let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
        let frameDescription: String
        if let frame {
            frameDescription = "(x:\(Int(frame.minX.rounded())) y:\(Int(frame.minY.rounded())) w:\(Int(frame.width.rounded())) h:\(Int(frame.height.rounded())))"
        } else {
            frameDescription = "nil"
        }
        let actionText = actions.isEmpty ? "nil" : actions.joined(separator: ",")
        let parentText = parentRoles.isEmpty ? "nil" : parentRoles.prefix(4).joined(separator: ">")
        return "#\(index) src=\(probeSource) state=\(classification) role=\(role) subrole=\(subrole) owner=\(owner) bundle=\(bundle) title=\(safeTitle) frame=\(frameDescription) actions=\(actionText) parents=\(parentText) path=\(path)"
    }
}

private struct HiddenProbeCollectionResult {
    let systemUIServerStatus: String
    let visitedNodeCount: Int
    let nodes: [HiddenProbeNode]
    let runningApplicationTargetCount: Int
    let runningApplicationNodeCount: Int
    let runningApplicationTargetLabels: [String]
    let systemUIServerRootDiagnostics: [String]
    let runningApplicationRootDiagnostics: [String]
}

private struct RunningApplicationHiddenProbeResult {
    let targetCount: Int
    let visitedNodeCount: Int
    let nodes: [HiddenProbeNode]
    let targetLabels: [String]
    let rootDiagnostics: [String]
}

@MainActor
final class StatusItemDiscoveryService {
    private let diagnosticsVersion = "2026-04-02-hidden-extras-v2"
    private let screenCaptureService: ScreenCaptureService
    private let diagnosticImageExportEnabled = DiagnosticsFileLogger.isScanImageExportEnabled

    init(screenCaptureService: ScreenCaptureService) {
        self.screenCaptureService = screenCaptureService
    }

    func discoverItems(on screen: NSScreen, kBarFrame: CGRect?) -> DiscoveryResult {
        let menuBarFrame = LayoutCoordinator.menuBarFrame(for: screen)
        let scanRegion = preferredScanRegion(in: menuBarFrame, kBarFrame: kBarFrame)
        let accessibilityCandidates = collectCandidates(on: screen, scanRegion: scanRegion)
        let fallbackVisibleCandidates = accessibilityCandidates.filter { candidate in
            candidate.frame.intersects(menuBarBand(for: screen))
        }
        guard let capture = screenCaptureService.captureMenuBar(for: screen) else {
            let hiddenProbeCollection = hiddenProbeCollection(
                on: screen,
                menuBarFrame: menuBarFrame,
                scanRegion: scanRegion,
                visibleCandidates: fallbackVisibleCandidates
            )
            let hiddenDiagnostics = hiddenProbeDiagnostics(
                from: hiddenProbeCollection,
                menuBarFrame: menuBarFrame,
                scanRegion: scanRegion,
                visibleCandidateCount: fallbackVisibleCandidates.count
            )
            let hiddenItems = buildHiddenItems(
                from: hiddenProbeCollection.nodes,
                capture: nil,
                screen: screen
            )
            return DiscoveryResult(
                items: hiddenItems,
                menuBarFrame: menuBarFrame,
                diagnostics: ["无法截取菜单栏图像。", "hiddenItemsBuilt=\(hiddenItems.count)"],
                hiddenDiagnostics: hiddenDiagnostics
            )
        }

        let screenshotResult = screenshotFallbackCandidates(in: capture, kBarFrame: kBarFrame)
        let screenshotCandidates = screenshotResult.candidates
        let rawCandidates = deduplicate(accessibilityCandidates + screenshotCandidates)
        var diagnostics: [String] = []
        diagnostics.append("diagnosticsVersion=\(diagnosticsVersion)")
        diagnostics.append("captureImage=\(capture.image.width)x\(capture.image.height) scale=\(String(format: "%.2f", capture.scale))")
        if diagnosticImageExportEnabled,
           let exportPath = exportCaptureImage(capture) {
            diagnostics.append("captureExport=\(exportPath)")
        }
        diagnostics.append("axCandidates=\(accessibilityCandidates.count)")
        diagnostics.append("screenshotCandidates=\(screenshotCandidates.count)")
        diagnostics.append("rawCandidates=\(rawCandidates.count)")
        diagnostics.append("menuBarFrame=x:\(Int(menuBarFrame.minX)) y:\(Int(menuBarFrame.minY)) w:\(Int(menuBarFrame.width)) h:\(Int(menuBarFrame.height))")
        diagnostics.append("scanRegion=min:\(Int(scanRegion.minX)) max:\(Int(scanRegion.maxX)) mode:\(scanRegion.mode)")
        if let kBarFrame {
            diagnostics.append("kBarFrame=x:\(Int(kBarFrame.minX)) y:\(Int(kBarFrame.minY)) w:\(Int(kBarFrame.width)) h:\(Int(kBarFrame.height))")
        } else {
            diagnostics.append("kBarFrame=nil")
        }
        diagnostics.append(contentsOf: screenshotResult.diagnostics)
        let filterSnapshots = buildFilterSnapshots(
            from: rawCandidates,
            screen: screen,
            menuBarFrame: menuBarFrame,
            scanRegion: scanRegion,
            kBarFrame: kBarFrame
        )
        let filteredCandidates = filterSnapshots.last?.items ?? []
        let hiddenProbeCollection = hiddenProbeCollection(
            on: screen,
            menuBarFrame: menuBarFrame,
            scanRegion: scanRegion,
            visibleCandidates: filteredCandidates
        )
        let hiddenDiagnostics = hiddenProbeDiagnostics(
            from: hiddenProbeCollection,
            menuBarFrame: menuBarFrame,
            scanRegion: scanRegion,
            visibleCandidateCount: filteredCandidates.count
        )
        let hiddenProbeEnrichedCandidates = enrichVisibleCandidates(
            filteredCandidates,
            usingHiddenProbeNodes: hiddenProbeCollection.nodes
        )
        let interactionEnrichedCandidates = collapseSpatialDuplicates(
            enrichInteractionTargets(
                for: hiddenProbeEnrichedCandidates,
                using: accessibilityCandidates
            )
        )

        diagnostics.append(contentsOf: filterSnapshots.map { "\($0.name)=\($0.items.count)" })
        diagnostics.append(contentsOf: diagnosticLines(for: rawCandidates, title: "rawCandidateDetails", limit: 40))
        diagnostics.append(contentsOf: diagnosticLines(for: filteredCandidates, title: "filteredCandidateDetails", limit: 40))
        diagnostics.append(contentsOf: diagnosticLines(for: hiddenProbeEnrichedCandidates, title: "hiddenProbeEnrichedCandidateDetails", limit: 40))
        diagnostics.append(contentsOf: diagnosticLines(for: interactionEnrichedCandidates, title: "interactionCandidateDetails", limit: 40))

        if diagnosticImageExportEnabled,
           let annotatedPath = exportAnnotatedCaptureImage(
               capture,
               rawCandidates: rawCandidates,
               filteredCandidates: filteredCandidates
           ) {
            diagnostics.append("captureAnnotated=\(annotatedPath)")
        }

        let visibleItems = interactionEnrichedCandidates.compactMap { candidate -> StatusItemModel? in
            guard let snapshot = screenCaptureService.cropSnapshot(
                from: capture,
                screenRect: candidate.frame,
                source: candidate.source
            ) else {
                return nil
            }

            return StatusItemModel(
                id: UUID(),
                ownerBundleID: candidate.bundleID,
                ownerName: candidate.ownerName,
                title: candidate.title,
                frameInScreen: candidate.frame,
                interactionPoint: candidate.interactionPoint ?? CGPoint(x: candidate.frame.midX, y: candidate.frame.midY),
                source: candidate.source,
                snapshot: snapshot,
                isVisibleInMenuBar: true,
                role: candidate.role,
                directAXElement: candidate.directAXElement
            )
        }
        let hiddenItems = buildHiddenItems(
            from: hiddenProbeCollection.nodes,
            capture: capture,
            screen: screen
        )
        let items = visibleItems + hiddenItems

        Logger.info("Discovered \(items.count) menu bar items")
        diagnostics.append("snapshotsBuilt=\(items.count)")
        diagnostics.append("hiddenItemsBuilt=\(hiddenItems.count)")
        diagnostics.append(contentsOf: itemDiagnosticLines(for: items, title: "finalItemDetails", limit: 40))
        return DiscoveryResult(
            items: items,
            menuBarFrame: menuBarFrame,
            diagnostics: diagnostics,
            hiddenDiagnostics: hiddenDiagnostics
        )
    }

    private func buildFilterSnapshots(
        from rawCandidates: [DiscoveredCandidate],
        screen: NSScreen,
        menuBarFrame: CGRect,
        scanRegion: CandidateScanRegion,
        kBarFrame: CGRect?
    ) -> [CandidateFilterSnapshot] {
        let protectedSystemRegionMinX = menuBarFrame.maxX - reservedSystemTrailingWidth(in: menuBarFrame)
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let menuBarCandidates = rawCandidates.filter { candidate in
            candidate.frame.intersects(menuBarBand(for: screen))
        }
        let withoutKBarCandidates = menuBarCandidates.filter { candidate in
            guard let kBarFrame else { return true }
            return !candidate.frame.intersects(kBarFrame.insetBy(dx: -6, dy: -4))
        }
        let inferredFrontmostMenuFrames = frontmostMenuCandidateFrames(
            from: withoutKBarCandidates,
            frontmostBundleID: frontmostBundleID
        )
        let directFrontmostMenuFrames = frontmostApplicationMenuFrames(on: screen)
        let frontmostMenuFrames = directFrontmostMenuFrames + inferredFrontmostMenuFrames
        let frontmostMenuMaxX = frontmostMenuFrames
            .map { $0.maxX }
            .max()
        let minimumUsableScanWidth = min(220, max(140, (scanRegion.maxX - scanRegion.minX) * 0.42))
        let effectiveScanMinX: CGFloat
        if let frontmostMenuMaxX, frontmostMenuMaxX < scanRegion.maxX - 40 {
            let proposedMinX = max(scanRegion.minX, frontmostMenuMaxX + 10)
            let cappedMinX = max(scanRegion.minX, scanRegion.maxX - minimumUsableScanWidth)
            effectiveScanMinX = min(proposedMinX, cappedMinX)
        } else {
            effectiveScanMinX = scanRegion.minX
        }
        let scanRegionCandidates = withoutKBarCandidates.filter { candidate in
            candidate.frame.minX >= effectiveScanMinX && candidate.frame.maxX <= scanRegion.maxX
        }
        let sizeQualifiedCandidates = scanRegionCandidates.filter { candidate in
            candidate.frame.width >= 8 && candidate.frame.width <= 72 &&
            candidate.frame.height >= 8 && candidate.frame.height <= 32
        }
        let menuScopedCandidates = sizeQualifiedCandidates.filter { candidate in
            candidate.source == .screenshot || candidate.isMenuBarScoped
        }
        let frontmostFilteredCandidates = menuScopedCandidates.filter { candidate in
            if let frontmostBundleID,
               candidate.bundleID == frontmostBundleID {
                return false
            }
            return !isLikelyFrontmostMenuScreenshot(
                candidate,
                frontmostMenuFrames: frontmostMenuFrames
            )
        }
        let textFilteredCandidates = frontmostFilteredCandidates.filter { candidate in
            !shouldFilterTextLikeScreenshot(candidate, frontmostMenuMaxX: frontmostMenuMaxX)
        }
        let bundleFilteredCandidates = textFilteredCandidates.filter { candidate in
            candidate.bundleID != Bundle.main.bundleIdentifier
        }
        let appRegionCandidates = bundleFilteredCandidates.filter { candidate in
            !shouldPreserveInMenuBar(candidate, protectedSystemRegionMinX: protectedSystemRegionMinX)
        }
        let sortedCandidates = appRegionCandidates.sorted { $0.frame.minX < $1.frame.minX }

        return [
            CandidateFilterSnapshot(name: "menuBarBandCandidates", items: menuBarCandidates),
            CandidateFilterSnapshot(name: "excludingKBarCandidates", items: withoutKBarCandidates),
            CandidateFilterSnapshot(
                name: "scanRegionCandidates[\(scanRegion.mode) min:\(Int(effectiveScanMinX)) max:\(Int(scanRegion.maxX)) reserve:\(Int(minimumUsableScanWidth))]",
                items: scanRegionCandidates
            ),
            CandidateFilterSnapshot(name: "sizeQualifiedCandidates", items: sizeQualifiedCandidates),
            CandidateFilterSnapshot(name: "menuScopedCandidates", items: menuScopedCandidates),
            CandidateFilterSnapshot(name: "frontmostFilteredCandidates", items: frontmostFilteredCandidates),
            CandidateFilterSnapshot(name: "textFilteredCandidates", items: textFilteredCandidates),
            CandidateFilterSnapshot(name: "bundleFilteredCandidates", items: bundleFilteredCandidates),
            CandidateFilterSnapshot(name: "appRegionCandidates", items: appRegionCandidates),
            CandidateFilterSnapshot(name: "filteredCandidates", items: sortedCandidates),
        ]
    }

    private func reservedSystemTrailingWidth(in menuBarFrame: CGRect) -> CGFloat {
        min(320, max(220, menuBarFrame.width * 0.22))
    }

    private func shouldPreserveInMenuBar(
        _ candidate: DiscoveredCandidate,
        protectedSystemRegionMinX: CGFloat
    ) -> Bool {
        if let bundleID = candidate.bundleID, bundleID.hasPrefix("com.apple.") {
            return true
        }

        if candidate.frame.midX >= protectedSystemRegionMinX {
            return true
        }

        return false
    }

    private func frontmostMenuCandidateFrames(
        from candidates: [DiscoveredCandidate],
        frontmostBundleID: String?
    ) -> [CGRect] {
        guard let frontmostBundleID else {
            return []
        }

        return candidates.compactMap { candidate in
            guard candidate.source != .screenshot else {
                return nil
            }
            guard candidate.bundleID == frontmostBundleID else {
                return nil
            }
            guard candidate.isMenuBarScoped else {
                return nil
            }
            guard candidate.frame.width >= 14,
                  candidate.frame.width <= 180,
                  candidate.frame.height >= 10,
                  candidate.frame.height <= 36
            else {
                return nil
            }

            switch candidate.role {
            case "AXMenuBarItem", "AXMenuButton", "AXButton":
                return candidate.frame
            default:
                return nil
            }
        }
    }

    private func frontmostApplicationMenuFrames(on screen: NSScreen) -> [CGRect] {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier > 0
        else {
            return []
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        guard let root = resolvedMenuBarElement(from: appElement) else {
            return []
        }

        let band = menuBarBand(for: screen)
        return collectCandidatesRecursively(from: root, path: "FrontmostAppMenu", depth: 0, source: .accessibility)
            .compactMap { candidate in
                guard candidate.isMenuBarScoped else {
                    return nil
                }
                guard candidate.frame.intersects(band) else {
                    return nil
                }
                guard candidate.frame.width >= 14,
                      candidate.frame.width <= 180,
                      candidate.frame.height >= 10,
                      candidate.frame.height <= 36
                else {
                    return nil
                }

                switch candidate.role {
                case "AXMenuBarItem", "AXMenuButton", "AXButton":
                    return candidate.frame
                default:
                    return nil
                }
            }
    }

    private func isLikelyFrontmostMenuScreenshot(
        _ candidate: DiscoveredCandidate,
        frontmostMenuFrames: [CGRect]
    ) -> Bool {
        guard candidate.source == .screenshot else {
            return false
        }

        return frontmostMenuFrames.contains { frame in
            let expanded = frame.insetBy(dx: -12, dy: -6)
            return expanded.intersects(candidate.frame) ||
                abs(candidate.frame.midX - frame.midX) <= 18
        }
    }

    private func shouldFilterTextLikeScreenshot(
        _ candidate: DiscoveredCandidate,
        frontmostMenuMaxX: CGFloat?
    ) -> Bool {
        guard candidate.source == .screenshot, candidate.looksTextLike else {
            return false
        }

        if let frontmostMenuMaxX {
            return candidate.frame.midX <= frontmostMenuMaxX + 24
        }

        return candidate.frame.width >= max(18, candidate.frame.height * 1.2)
    }

    private func enrichInteractionTargets(
        for candidates: [DiscoveredCandidate],
        using accessibilityCandidates: [DiscoveredCandidate]
    ) -> [DiscoveredCandidate] {
        let actionableAccessibilityCandidates = accessibilityCandidates.filter { candidate in
            guard candidate.source != .screenshot else {
                return false
            }
            guard candidate.isMenuBarScoped else {
                return false
            }

            if let bundleID = candidate.bundleID, bundleID == Bundle.main.bundleIdentifier {
                return false
            }

            if let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               candidate.bundleID == frontmostBundleID {
                return false
            }

            return candidate.frame.width >= 6 && candidate.frame.width <= 120 &&
                candidate.frame.height >= 6 && candidate.frame.height <= 44
        }

        return candidates.map { candidate in
            guard candidate.source == .screenshot else {
                let interactionPoint = candidate.interactionPoint ?? CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
                return candidate.withInteractionPoint(interactionPoint)
            }

            let centerPoint = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
            guard let matched = bestAccessibilityMatch(for: candidate, in: actionableAccessibilityCandidates) else {
                return candidate.withInteractionPoint(centerPoint)
            }

            return candidate.enrichingInteraction(from: matched)
        }
    }

    private func enrichVisibleCandidates(
        _ candidates: [DiscoveredCandidate],
        usingHiddenProbeNodes nodes: [HiddenProbeNode]
    ) -> [DiscoveredCandidate] {
        let actionableNodes = nodes.filter { node in
            guard node.probeSource == "runningAppExtras" else {
                return false
            }
            guard node.classification == "visibleMatched" || node.classification == "withinScanRegion" else {
                return false
            }
            guard let frame = node.frame,
                  frame.width >= 6,
                  frame.height >= 6
            else {
                return false
            }
            guard ["AXMenuBarItem", "AXMenuButton", "AXPopUpButton", "AXButton"].contains(node.role) else {
                return false
            }
            guard hiddenNodeBundleIdentifier(node) != Bundle.main.bundleIdentifier else {
                return false
            }
            return true
        }

        return candidates.map { candidate in
            guard candidate.source == .screenshot else {
                return candidate
            }
            guard let matched = bestHiddenProbeMatch(for: candidate, in: actionableNodes),
                  let accessibilityCandidate = discoveredCandidate(from: matched)
            else {
                return candidate
            }
            return candidate.enrichingInteraction(from: accessibilityCandidate)
        }
    }

    private func bestHiddenProbeMatch(
        for screenshotCandidate: DiscoveredCandidate,
        in nodes: [HiddenProbeNode]
    ) -> HiddenProbeNode? {
        guard !nodes.isEmpty else {
            return nil
        }

        let center = CGPoint(x: screenshotCandidate.frame.midX, y: screenshotCandidate.frame.midY)
        let filtered = nodes.filter { node in
            guard let frame = node.frame else {
                return false
            }
            let yDistance = abs(frame.midY - center.y)
            guard yDistance <= 16 else {
                return false
            }

            if frame.intersects(screenshotCandidate.frame) {
                return true
            }

            return abs(frame.midX - center.x) <= 8
        }

        guard !filtered.isEmpty else {
            return nil
        }

        return filtered.max { lhs, rhs in
            hiddenProbeMatchScore(lhs, around: screenshotCandidate) < hiddenProbeMatchScore(rhs, around: screenshotCandidate)
        }
    }

    private func hiddenProbeMatchScore(
        _ node: HiddenProbeNode,
        around screenshotCandidate: DiscoveredCandidate
    ) -> Int {
        guard let frame = node.frame else {
            return Int.min
        }

        let center = CGPoint(x: screenshotCandidate.frame.midX, y: screenshotCandidate.frame.midY)
        var score = hiddenNodeScore(node) * 10

        if frame.intersects(screenshotCandidate.frame) {
            score += 120
        }

        let distance = hypot(frame.midX - center.x, frame.midY - center.y)
        score -= Int((distance * 3.0).rounded())

        if node.classification == "visibleMatched" {
            score += 60
        }

        if let bundleID = hiddenNodeBundleIdentifier(node),
           !bundleID.hasPrefix("com.apple.") {
            score += 20
        }

        if node.role == "AXMenuBarItem" {
            score += 16
        }

        return score
    }

    private func bestAccessibilityMatch(
        for screenshotCandidate: DiscoveredCandidate,
        in accessibilityCandidates: [DiscoveredCandidate]
    ) -> DiscoveredCandidate? {
        guard !accessibilityCandidates.isEmpty else {
            return nil
        }

        let center = CGPoint(x: screenshotCandidate.frame.midX, y: screenshotCandidate.frame.midY)
        let expandedFrame = screenshotCandidate.frame.insetBy(dx: -40, dy: -12)

        let filtered = accessibilityCandidates.filter { candidate in
            let yDistance = abs(candidate.frame.midY - center.y)
            guard yDistance <= 18 else {
                return false
            }

            if expandedFrame.intersects(candidate.frame) {
                return true
            }

            return horizontalDistance(from: center.x, to: candidate.frame) <= 48
        }

        guard !filtered.isEmpty else {
            return nil
        }

        return filtered.max { lhs, rhs in
            accessibilityMatchScore(lhs, around: screenshotCandidate) < accessibilityMatchScore(rhs, around: screenshotCandidate)
        }
    }

    private func accessibilityMatchScore(
        _ candidate: DiscoveredCandidate,
        around screenshotCandidate: DiscoveredCandidate
    ) -> Int {
        let center = CGPoint(x: screenshotCandidate.frame.midX, y: screenshotCandidate.frame.midY)
        let expandedFrame = screenshotCandidate.frame.insetBy(dx: -40, dy: -12)
        var score = 0

        if expandedFrame.intersects(candidate.frame) {
            score += 60
        }

        let distance = hypot(candidate.frame.midX - center.x, candidate.frame.midY - center.y)
        score -= Int((distance * 1.8).rounded())
        score += candidate.score

        if candidate.source == .accessibility {
            score += 8
        } else if candidate.source == .hybrid {
            score += 4
        }

        if let bundleID = candidate.bundleID, !bundleID.hasPrefix("com.apple.") {
            score += 18
        }

        if candidate.role == "AXMenuBarItem" {
            score += 6
        }

        return score
    }

    private func horizontalDistance(from x: CGFloat, to frame: CGRect) -> CGFloat {
        if frame.minX <= x, frame.maxX >= x {
            return 0
        }
        return min(abs(frame.minX - x), abs(frame.maxX - x))
    }

    private func collapseSpatialDuplicates(_ candidates: [DiscoveredCandidate]) -> [DiscoveredCandidate] {
        let sorted = candidates.sorted { lhs, rhs in
            interactionPriority(lhs) > interactionPriority(rhs)
        }

        var kept: [DiscoveredCandidate] = []
        for candidate in sorted {
            let overlapsExisting = kept.contains { existing in
                candidate.frame.intersects(existing.frame.insetBy(dx: -6, dy: -4)) ||
                    abs(candidate.frame.midX - existing.frame.midX) < 8
            }
            if !overlapsExisting {
                kept.append(candidate)
            }
        }

        return kept.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func interactionPriority(_ candidate: DiscoveredCandidate) -> Int {
        var score = candidate.score * 10
        if candidate.source == .accessibility || candidate.source == .hybrid {
            score += 40
        }
        if candidate.bundleID != nil {
            score += 24
        }
        if candidate.role == "AXMenuBarItem" {
            score += 12
        }
        if candidate.role == "Screenshot" {
            score -= 20
        }
        return score
    }

    private func diagnosticLines(
        for candidates: [DiscoveredCandidate],
        title: String,
        limit: Int
    ) -> [String] {
        guard !candidates.isEmpty else {
            return ["\(title)=none"]
        }

        var lines = ["\(title)=begin"]
        for (index, candidate) in candidates.prefix(limit).enumerated() {
            lines.append(candidate.debugLine(index: index + 1))
        }
        if candidates.count > limit {
            lines.append("\(title)=truncated \(candidates.count - limit) more")
        }
        lines.append("\(title)=end")
        return lines
    }

    private func itemDiagnosticLines(
        for items: [StatusItemModel],
        title: String,
        limit: Int
    ) -> [String] {
        guard !items.isEmpty else {
            return ["\(title)=none"]
        }

        var lines = ["\(title)=begin"]
        for (index, item) in items.prefix(limit).enumerated() {
            let bundleID = item.ownerBundleID ?? "nil"
            let ownerName = item.ownerName ?? "nil"
            let safeTitle = (item.title ?? "nil").replacingOccurrences(of: "\n", with: " ")
            let source = item.source.rawValue
            let visible = item.isVisibleInMenuBar ? "visible" : "hidden"
            lines.append(
                "#\(index + 1) state=\(visible) source=\(source) display=\(item.displayName) owner=\(ownerName) bundle=\(bundleID) title=\(safeTitle) frame=(x:\(Int(item.frameInScreen.minX.rounded())) y:\(Int(item.frameInScreen.minY.rounded())) w:\(Int(item.frameInScreen.width.rounded())) h:\(Int(item.frameInScreen.height.rounded())))"
            )
        }
        if items.count > limit {
            lines.append("\(title)=truncated \(items.count - limit) more")
        }
        lines.append("\(title)=end")
        return lines
    }

    private func collectCandidates(on screen: NSScreen, scanRegion: CandidateScanRegion) -> [DiscoveredCandidate] {
        let systemUIServerCandidates = candidatesFromSystemUIServer()
        let fallbackCandidates = candidatesFromSystemWide(on: screen, scanRegion: scanRegion)

        let merged = deduplicate(systemUIServerCandidates + fallbackCandidates)
        return merged
    }

    private func candidatesFromSystemUIServer() -> [DiscoveredCandidate] {
        guard let systemUIServer = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systemuiserver"
        }) else {
            return []
        }

        let appElement = AXUIElementCreateApplication(systemUIServer.processIdentifier)
        let root = resolvedRootElement(from: appElement)
        guard let root else {
            return []
        }

        return collectCandidatesRecursively(from: root, path: "SystemUIServer", depth: 0, source: .accessibility)
    }

    private func candidatesFromSystemWide(on screen: NSScreen, scanRegion: CandidateScanRegion) -> [DiscoveredCandidate] {
        let systemWideElement = AXUIElementCreateSystemWide()
        let band = menuBarBand(for: screen)
        let sampleYPositions: [CGFloat] = [
            band.minY + 3,
            band.midY,
            band.maxY - 3,
        ]
        let startX = min(screen.frame.maxX - 8, scanRegion.maxX)
        let endX = max(screen.frame.minX, scanRegion.minX)
        let step: CGFloat = 12

        guard startX > endX else {
            return []
        }

        var results: [DiscoveredCandidate] = []

        for sampleY in sampleYPositions {
            var x = startX
            while x >= endX {
                if let element = elementAtPosition(systemWideElement, x: x, y: sampleY),
                   let candidate = bestCandidateFromAncestors(of: element, source: .hybrid) {
                    results.append(candidate)
                }
                x -= step
            }
        }

        return results
    }

    private func screenshotFallbackCandidates(in capture: MenuBarCapture, kBarFrame: CGRect?) -> ScreenshotFallbackResult {
        guard let providerData = capture.image.dataProvider?.data,
              let rawPointer = CFDataGetBytePtr(providerData)
        else {
            return ScreenshotFallbackResult(candidates: [], diagnostics: ["screenshotFallback=dataProvider=nil"])
        }

        let width = capture.image.width
        let height = capture.image.height
        let bytesPerRow = capture.image.bytesPerRow
        let bytesPerPixel = max(capture.image.bitsPerPixel / 8, 4)
        let expectedPixelHeight = max(12, Int((capture.menuBarFrame.height * capture.scale).rounded()))
        let analysisHeight = min(height, expectedPixelHeight)

        let scanRegion = preferredScanRegion(in: capture.menuBarFrame, kBarFrame: kBarFrame)
        let startScreenX = scanRegion.minX
        let endScreenX = scanRegion.maxX

        let startX = max(0, Int(((startScreenX - capture.menuBarFrame.minX) * capture.scale).rounded(.down)))
        let endX = min(width - 1, Int(((endScreenX - capture.menuBarFrame.minX) * capture.scale).rounded(.down)))

        guard endX - startX > 20 else {
            return ScreenshotFallbackResult(
                candidates: [],
                diagnostics: ["screenshotFallback=rangeTooSmall startX=\(startX) endX=\(endX) mode:\(scanRegion.mode)"]
            )
        }

        let backgroundLuminance = estimatedBackgroundLuminance(
            pointer: rawPointer,
            width: width,
            height: analysisHeight,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            sampleStartX: startX,
            sampleEndX: endX
        )

        var activeColumns = Array(repeating: false, count: endX - startX + 1)
        var edgeColumns = Array(repeating: false, count: endX - startX + 1)
        var contrastScores = Array(repeating: 0, count: endX - startX + 1)
        for x in startX...endX {
            var localContrastPixelCount = 0
            var edgeScore = 0
            for y in 0..<analysisHeight {
                let lum = luminance(pointer: rawPointer, x: x, y: y, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
                let localContrast = localContrastScore(
                    pointer: rawPointer,
                    x: x,
                    y: y,
                    width: width,
                    height: analysisHeight,
                    bytesPerRow: bytesPerRow,
                    bytesPerPixel: bytesPerPixel
                )
                if localContrast >= 26 {
                    localContrastPixelCount += 1
                }

                if x > 0, x < (width - 1), y > 0, y < (analysisHeight - 1) {
                    let left = luminance(pointer: rawPointer, x: x - 1, y: y, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
                    let right = luminance(pointer: rawPointer, x: x + 1, y: y, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
                    let up = luminance(pointer: rawPointer, x: x, y: y - 1, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
                    let down = luminance(pointer: rawPointer, x: x, y: y + 1, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
                    edgeScore += abs(lum - left) + abs(lum - right) + abs(lum - up) + abs(lum - down)
                }
            }

            let localIndex = x - startX
            contrastScores[localIndex] = localContrastPixelCount
            activeColumns[localIndex] = localContrastPixelCount >= max(3, analysisHeight / 8)
            edgeColumns[localIndex] = edgeScore >= (analysisHeight * 48)
        }

        let contrastRanges = ScreenGeometry.mergeColumnActivity(activeColumns, gapTolerance: 8, minimumWidth: 4)
        let edgeRanges = ScreenGeometry.mergeColumnActivity(edgeColumns, gapTolerance: 5, minimumWidth: 4)
        let mergedRanges = deduplicateRanges(contrastRanges + edgeRanges)
        let ranges = splitWideRanges(mergedRanges, contrastScores: contrastScores)
        var textLikeCandidateCount = 0
        let candidates: [DiscoveredCandidate] = ranges.compactMap { range -> DiscoveredCandidate? in
            let globalRange = (range.lowerBound + startX)...(range.upperBound + startX)
            guard let verticalRange = detectVerticalRangeByLocalContrast(
                for: globalRange,
                pointer: rawPointer,
                width: width,
                height: analysisHeight,
                bytesPerRow: bytesPerRow,
                bytesPerPixel: bytesPerPixel
            ) else {
                return nil
            }

            let imageRect = CGRect(
                x: CGFloat(max(0, globalRange.lowerBound - 3)),
                y: CGFloat(max(0, verticalRange.lowerBound - 2)),
                width: CGFloat(globalRange.upperBound - globalRange.lowerBound + 7),
                height: CGFloat(verticalRange.upperBound - verticalRange.lowerBound + 5)
            )
            let screenRect = screenRect(from: imageRect, capture: capture)
            let looksTextLike = looksLikeMenuTextFragment(
                in: imageRect,
                pointer: rawPointer,
                imageWidth: width,
                imageHeight: analysisHeight,
                bytesPerRow: bytesPerRow,
                bytesPerPixel: bytesPerPixel,
                backgroundLuminance: backgroundLuminance
            )
            if looksTextLike {
                textLikeCandidateCount += 1
            }

            return DiscoveredCandidate(
                title: "Screenshot Item",
                role: "Screenshot",
                frame: screenRect,
                ownerName: nil,
                bundleID: nil,
                source: .screenshot,
                score: 2,
                debugPath: "ScreenshotFallback",
                interactionPoint: nil,
                looksTextLike: looksTextLike,
                isMenuBarScoped: true,
                directAXElement: nil
            )
        }

        let activeColumnCount = activeColumns.filter { $0 }.count
        let edgeColumnCount = edgeColumns.filter { $0 }.count
        return ScreenshotFallbackResult(
            candidates: candidates,
            diagnostics: [
                "screenshotRange=start:\(startX) end:\(endX) mode:\(scanRegion.mode)",
                "backgroundLuminance=\(backgroundLuminance)",
                "analysisHeight=\(analysisHeight)/\(height)",
                "activeColumns=\(activeColumnCount)/\(activeColumns.count)",
                "edgeColumns=\(edgeColumnCount)/\(edgeColumns.count)",
                "contrastRanges=\(contrastRanges.count)",
                "edgeRanges=\(edgeRanges.count)",
                "mergedRanges=\(mergedRanges.count)",
                "splitRanges=\(ranges.count)",
                "textLikeScreenshotCandidates=\(textLikeCandidateCount)",
            ]
        )
    }

    private func preferredScanRegion(in menuBarFrame: CGRect, kBarFrame: CGRect?) -> CandidateScanRegion {
        let baseScanWidth = min(460, max(200, menuBarFrame.width * 0.36))
        let scanWidth = max(160, baseScanWidth - 76)
        let trailingMaxX = menuBarFrame.maxX - 6
        let trailingMinX = max(menuBarFrame.minX, trailingMaxX - scanWidth)

        guard let kBarFrame else {
            return CandidateScanRegion(minX: trailingMinX, maxX: trailingMaxX, mode: "trailingFallback")
        }

        let anchoredMaxX = min(trailingMaxX, max(menuBarFrame.minX, kBarFrame.minX - 4))
        guard anchoredMaxX - menuBarFrame.minX > 20 else {
            return CandidateScanRegion(minX: menuBarFrame.minX, maxX: anchoredMaxX, mode: "leftOfKBar[narrow]")
        }

        let anchoredMinX = max(menuBarFrame.minX, anchoredMaxX - scanWidth)
        return CandidateScanRegion(minX: anchoredMinX, maxX: anchoredMaxX, mode: "leftOfKBar")
    }

    private func hiddenProbeCollection(
        on screen: NSScreen,
        menuBarFrame: CGRect,
        scanRegion: CandidateScanRegion,
        visibleCandidates: [DiscoveredCandidate]
    ) -> HiddenProbeCollectionResult {
        var systemUIServerStatus = "unavailable"
        var nodes: [HiddenProbeNode] = []
        var visitedNodeCount = 0
        var systemUIServerRootDiagnostics: [String] = []

        guard let systemUIServer = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systemuiserver"
        }) else {
            let runningApplicationResult = collectHiddenProbeNodesFromRunningApplications(
                on: screen,
                menuBarFrame: menuBarFrame,
                scanRegion: scanRegion,
                visibleCandidates: visibleCandidates
            )
            return HiddenProbeCollectionResult(
                systemUIServerStatus: systemUIServerStatus,
                visitedNodeCount: runningApplicationResult.visitedNodeCount,
                nodes: runningApplicationResult.nodes,
                runningApplicationTargetCount: runningApplicationResult.targetCount,
                runningApplicationNodeCount: runningApplicationResult.nodes.count,
                runningApplicationTargetLabels: runningApplicationResult.targetLabels,
                systemUIServerRootDiagnostics: ["hiddenProbe.systemUIServer.appMissing=true"],
                runningApplicationRootDiagnostics: runningApplicationResult.rootDiagnostics
            )
        }

        let appElement = AXUIElementCreateApplication(systemUIServer.processIdentifier)
        if let root = resolvedMenuBarElement(from: appElement) ?? resolvedRootElement(from: appElement) {
            systemUIServerStatus = "ok"
            let protectedSystemRegionMinX = menuBarFrame.maxX - reservedSystemTrailingWidth(in: menuBarFrame)
            nodes.append(
                contentsOf: collectHiddenProbeNodesRecursively(
                    from: root,
                    probeSource: "systemUIServer",
                    path: "SystemUIServerHiddenProbe",
                    depth: 0,
                    screen: screen,
                    menuBarFrame: menuBarFrame,
                    scanRegion: scanRegion,
                    protectedSystemRegionMinX: protectedSystemRegionMinX,
                    visibleCandidates: visibleCandidates,
                    visitedNodeCount: &visitedNodeCount
                )
            )
        } else {
            systemUIServerStatus = "missingRoot"
            systemUIServerRootDiagnostics = hiddenProbeRootDiagnostics(
                for: appElement,
                label: "hiddenProbe.systemUIServerRoot"
            )
        }

        let runningApplicationResult = collectHiddenProbeNodesFromRunningApplications(
            on: screen,
            menuBarFrame: menuBarFrame,
            scanRegion: scanRegion,
            visibleCandidates: visibleCandidates
        )
        nodes.append(contentsOf: runningApplicationResult.nodes)
        visitedNodeCount += runningApplicationResult.visitedNodeCount

        return HiddenProbeCollectionResult(
            systemUIServerStatus: systemUIServerStatus,
            visitedNodeCount: visitedNodeCount,
            nodes: nodes,
            runningApplicationTargetCount: runningApplicationResult.targetCount,
            runningApplicationNodeCount: runningApplicationResult.nodes.count,
            runningApplicationTargetLabels: runningApplicationResult.targetLabels,
            systemUIServerRootDiagnostics: systemUIServerRootDiagnostics,
            runningApplicationRootDiagnostics: runningApplicationResult.rootDiagnostics
        )
    }

    private func hiddenProbeDiagnostics(
        from collection: HiddenProbeCollectionResult,
        menuBarFrame: CGRect,
        scanRegion: CandidateScanRegion,
        visibleCandidateCount: Int
    ) -> [String] {
        let runningAppTargetLabels = collection.runningApplicationTargetLabels.joined(separator: ",")

        guard collection.systemUIServerStatus == "ok" || collection.runningApplicationNodeCount > 0 else {
            return [
                "hiddenProbe=begin",
                "hiddenProbe.systemUIServer=\(collection.systemUIServerStatus)",
                "hiddenProbe.runningAppTargets=\(collection.runningApplicationTargetCount)",
                "hiddenProbe.runningAppNodes=\(collection.runningApplicationNodeCount)",
                "hiddenProbe.runningAppTargetLabels=\(runningAppTargetLabels)",
                "hiddenProbe=end",
            ]
        }

        let nodes = collection.nodes
        let appleOwnedCount = nodes.filter(\.isAppleOwned).count
        let nonAppleOwnedCount = nodes.filter { node in
            node.hasKnownOwner && !node.isAppleOwned
        }.count
        let unknownOwnerCount = nodes.filter { !$0.hasKnownOwner }.count
        let visibleMatchedCount = nodes.filter { $0.classification == "visibleMatched" }.count
        let withinScanCount = nodes.filter { $0.classification == "withinScanRegion" }.count
        let outsideScanCount = nodes.filter { $0.classification.hasPrefix("outsideScanRegion") }.count
        let protectedTrailingCount = nodes.filter { $0.classification == "protectedTrailingRegion" }.count
        let offMenuBarCount = nodes.filter { $0.classification == "offMenuBarBand" }.count
        let zeroSizeCount = nodes.filter { $0.classification == "zeroSize" }.count
        let missingFrameCount = nodes.filter { $0.classification == "missingFrame" }.count

        let potentialHiddenNodes = nodes
            .filter { node in
                hiddenProbePriority(node.classification) >= 3
            }
            .sorted(by: hiddenProbeSort)
        let outsideScanNodes = nodes
            .filter { $0.classification.hasPrefix("outsideScanRegion") || $0.classification == "protectedTrailingRegion" }
            .sorted(by: hiddenProbeSort)

        var diagnostics: [String] = [
            "hiddenProbe=begin",
            "hiddenProbe.diagnosticsVersion=\(diagnosticsVersion)",
            "hiddenProbe.systemUIServer=\(collection.systemUIServerStatus)",
            "hiddenProbe.runningAppTargets=\(collection.runningApplicationTargetCount)",
            "hiddenProbe.runningAppNodes=\(collection.runningApplicationNodeCount)",
            "hiddenProbe.runningAppTargetLabels=\(runningAppTargetLabels)",
            "hiddenProbe.scanRegion=min:\(Int(scanRegion.minX)) max:\(Int(scanRegion.maxX)) mode:\(scanRegion.mode)",
            "hiddenProbe.menuBarFrame=x:\(Int(menuBarFrame.minX)) y:\(Int(menuBarFrame.minY)) w:\(Int(menuBarFrame.width)) h:\(Int(menuBarFrame.height))",
            "hiddenProbe.visibleCandidates=\(visibleCandidateCount)",
            "hiddenProbe.visitedNodes=\(collection.visitedNodeCount)",
            "hiddenProbe.interestingNodes=\(nodes.count)",
            "hiddenProbe.appleOwnedNodes=\(appleOwnedCount)",
            "hiddenProbe.nonAppleOwnedNodes=\(nonAppleOwnedCount)",
            "hiddenProbe.unknownOwnerNodes=\(unknownOwnerCount)",
            "hiddenProbe.visibleMatched=\(visibleMatchedCount)",
            "hiddenProbe.withinScanRegion=\(withinScanCount)",
            "hiddenProbe.outsideScanRegion=\(outsideScanCount)",
            "hiddenProbe.protectedTrailingRegion=\(protectedTrailingCount)",
            "hiddenProbe.offMenuBarBand=\(offMenuBarCount)",
            "hiddenProbe.zeroSize=\(zeroSizeCount)",
            "hiddenProbe.missingFrame=\(missingFrameCount)",
        ]
        diagnostics.append(contentsOf: collection.systemUIServerRootDiagnostics)
        diagnostics.append(contentsOf: collection.runningApplicationRootDiagnostics)
        diagnostics.append(
            contentsOf: hiddenProbeLines(
                for: nodes.filter { $0.probeSource == "runningAppExtras" }.sorted(by: hiddenProbeSort),
                title: "hiddenProbeRunningAppExtraDetails",
                limit: 40
            )
        )
        diagnostics.append(
            contentsOf: hiddenProbeLines(
                for: deduplicateHiddenNodes(nodes.filter(shouldPromoteHiddenNode)).sorted(by: hiddenProbeSort),
                title: "hiddenProbePromotedDetails",
                limit: 20
            )
        )
        diagnostics.append(contentsOf: hiddenProbeLines(for: potentialHiddenNodes, title: "hiddenProbePotentialDetails", limit: 40))
        diagnostics.append(contentsOf: hiddenProbeLines(for: outsideScanNodes, title: "hiddenProbeOutsideScanDetails", limit: 20))
        diagnostics.append("hiddenProbe=end")
        return diagnostics
    }

    private func buildHiddenItems(
        from nodes: [HiddenProbeNode],
        capture: MenuBarCapture?,
        screen: NSScreen
    ) -> [StatusItemModel] {
        let promotedNodes = deduplicateHiddenNodes(nodes.filter(shouldPromoteHiddenNode))

        return promotedNodes.compactMap { node in
            let snapshot = hiddenSnapshot(for: node, capture: capture, screen: screen) ?? genericHiddenSnapshot()
            let frame = node.frame ?? .zero
            let interactionPoint = node.frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero

            return StatusItemModel(
                id: UUID(),
                ownerBundleID: hiddenNodeBundleIdentifier(node),
                ownerName: hiddenNodeOwnerName(node),
                title: node.title,
                frameInScreen: frame,
                interactionPoint: interactionPoint,
                source: .accessibility,
                snapshot: snapshot,
                isVisibleInMenuBar: false,
                role: node.role,
                directAXElement: node.element
            )
        }
    }

    private func shouldPromoteHiddenNode(_ node: HiddenProbeNode) -> Bool {
        if hiddenNodeBundleIdentifier(node) == Bundle.main.bundleIdentifier {
            return false
        }

        switch node.classification {
        case "outsideScanRegion[left]", "missingFrame", "zeroSize":
            break
        case "withinScanRegion":
            guard node.probeSource == "runningAppExtras" else {
                return false
            }
        default:
            return false
        }

        let trimmedTitle = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if node.probeSource == "runningApp" || node.probeSource == "runningAppExtras" {
            guard ["AXMenuBarItem", "AXMenuButton", "AXPopUpButton", "AXButton"].contains(node.role) else {
                return false
            }
            guard !node.parentRoles.contains("AXMenu") else {
                return false
            }
            if node.probeSource == "runningApp",
               node.parentRoles.contains("AXMenuBar"),
               node.subrole != "AXMenuExtra" {
                return false
            }
            if trimmedTitle.caseInsensitiveCompare("Apple") == .orderedSame {
                return false
            }
            if node.probeSource == "runningApp",
               let ownerName = hiddenNodeOwnerName(node),
               trimmedTitle.caseInsensitiveCompare(ownerName) == .orderedSame {
                return false
            }
            if looksLikeApplicationMainMenuTitle(trimmedTitle) {
                return false
            }
        } else if trimmedTitle.isEmpty {
            return false
        }

        if node.role == "AXUnknown", node.actions.isEmpty {
            return false
        }

        if node.role == "AXMenuBar" || node.role == "AXGroup" || node.role == "AXMenu" || node.role == "AXMenuItem" {
            return false
        }

        return true
    }

    private func deduplicateHiddenNodes(_ nodes: [HiddenProbeNode]) -> [HiddenProbeNode] {
        var buckets: [String: HiddenProbeNode] = [:]

        for node in nodes {
            let key = hiddenNodeKey(node)
            if let existing = buckets[key] {
                if hiddenNodeScore(node) > hiddenNodeScore(existing) {
                    buckets[key] = node
                }
            } else {
                buckets[key] = node
            }
        }

        return Array(buckets.values)
    }

    private func hiddenNodeKey(_ node: HiddenProbeNode) -> String {
        let bundleKey = hiddenNodeBundleIdentifier(node) ?? hiddenNodeOwnerName(node) ?? "nil"
        let titleKey = node.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let frameKey = node.frame.map {
            "\(Int($0.minX.rounded()))-\(Int($0.width.rounded()))"
        } ?? node.classification
        return "\(bundleKey)|\(titleKey)|\(frameKey)"
    }

    private func hiddenNodeScore(_ node: HiddenProbeNode) -> Int {
        var score = 0

        switch node.role {
        case "AXMenuBarItem":
            score += 12
        case "AXMenuButton", "AXPopUpButton":
            score += 10
        case "AXButton":
            score += 8
        default:
            score += 2
        }

        if node.actions.contains("AXPress") {
            score += 6
        }
        if node.actions.contains("AXShowMenu") {
            score += 4
        }
        if node.parentRoles.contains("AXMenuBar") {
            score += 5
        }
        if node.parentRoles.contains("AXMenuBarItem") {
            score += 2
        }
        if node.frame == nil {
            score += 3
        }
        if node.classification == "outsideScanRegion[left]" {
            score += 3
        }
        if node.classification == "missingFrame" || node.classification == "zeroSize" {
            score += 2
        }
        score -= node.path.components(separatedBy: "/").count
        return score
    }

    private func hiddenSnapshot(
        for node: HiddenProbeNode,
        capture: MenuBarCapture?,
        screen: NSScreen
    ) -> NSImage? {
        if let bundleID = hiddenNodeBundleIdentifier(node),
           let appIcon = appIconSnapshot(bundleID: bundleID) {
            return appIcon
        }

        if let capture,
           let frame = node.frame,
           frame.width > 0,
           frame.height > 0,
           frame.intersects(menuBarBand(for: screen)),
           let snapshot = screenCaptureService.cropSnapshot(
                from: capture,
                screenRect: frame,
                source: .accessibility
           ) {
            return snapshot
        }

        return nil
    }

    private func hiddenNodeBundleIdentifier(_ node: HiddenProbeNode) -> String? {
        guard let bundleID = node.bundleID,
              bundleID != "com.apple.systemuiserver"
        else {
            return nil
        }
        return bundleID
    }

    private func hiddenNodeOwnerName(_ node: HiddenProbeNode) -> String? {
        if let ownerName = node.ownerName,
           ownerName != "SystemUIServer" {
            return ownerName
        }
        return nil
    }

    private func appIconSnapshot(bundleID: String) -> NSImage? {
        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = runningApp.icon {
            return icon
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return nil
    }

    private func genericHiddenSnapshot() -> NSImage {
        if let image = NSImage(
            systemSymbolName: "questionmark.square.dashed",
            accessibilityDescription: "Hidden Menu Bar Item"
        ) {
            return image
        }

        return NSImage(size: NSSize(width: 18, height: 18))
    }

    private func collectHiddenProbeNodesFromRunningApplications(
        on screen: NSScreen,
        menuBarFrame: CGRect,
        scanRegion: CandidateScanRegion,
        visibleCandidates: [DiscoveredCandidate]
    ) -> RunningApplicationHiddenProbeResult {
        let protectedSystemRegionMinX = menuBarFrame.maxX - reservedSystemTrailingWidth(in: menuBarFrame)
        let targets = hiddenProbeRunningApplicationTargets()
        var visitedNodeCount = 0
        var nodes: [HiddenProbeNode] = []
        var targetLabels: [String] = []
        var rootDiagnostics: [String] = []

        for app in targets {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let appLabel = hiddenProbeApplicationLabel(app)
            targetLabels.append(appLabel)
            rootDiagnostics.append(
                contentsOf: hiddenProbeRootDiagnostics(
                    for: appElement,
                    label: "hiddenProbe.runningAppRoot[\(appLabel)]"
                )
            )
            let extraRoots = runningApplicationExtraMenuBarRoots(from: appElement)
            rootDiagnostics.append("hiddenProbe.runningAppRoot[\(appLabel)].extraRootCount=\(extraRoots.count)")
            nodes.append(
                contentsOf: extraRoots.enumerated().flatMap { index, extraRoot in
                    collectHiddenProbeNodesRecursively(
                        from: extraRoot,
                        probeSource: "runningAppExtras",
                        path: "RunningAppExtra[\(appLabel)]/\(index)",
                        depth: 0,
                        screen: screen,
                        menuBarFrame: menuBarFrame,
                        scanRegion: scanRegion,
                        protectedSystemRegionMinX: protectedSystemRegionMinX,
                        visibleCandidates: visibleCandidates,
                        visitedNodeCount: &visitedNodeCount
                    )
                }
            )
        }

        return RunningApplicationHiddenProbeResult(
            targetCount: targets.count,
            visitedNodeCount: visitedNodeCount,
            nodes: nodes,
            targetLabels: targetLabels,
            rootDiagnostics: rootDiagnostics
        )
    }

    private func runningApplicationExtraMenuBarRoots(from appElement: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = []

        func appendUnique(_ candidate: AXUIElement) {
            if roots.contains(where: { CFEqual($0, candidate) }) {
                return
            }
            roots.append(candidate)
        }

        if let extrasMenuBar = copyElementAttribute("AXExtrasMenuBar", from: appElement) {
            appendUnique(extrasMenuBar)
        }

        for child in arrayAttribute(kAXChildrenAttribute as String, from: appElement) {
            if isLikelyExtraMenuBarRoot(child) {
                appendUnique(child)
            }
        }

        return roots
    }

    private func isLikelyExtraMenuBarRoot(_ element: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute as String, from: element) == "AXMenuBar" else {
            return false
        }

        let childCount = arrayAttribute(kAXChildrenAttribute as String, from: element).count
        guard childCount > 0, childCount <= 4 else {
            return false
        }

        guard let frame = frameAttribute(from: element) else {
            return true
        }

        return frame.width > 0 && frame.width <= 220 && frame.height > 0 && frame.height <= 40
    }

    private func hiddenProbeRunningApplicationTargets() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier > 0 else {
                return false
            }
            guard !app.isTerminated else {
                return false
            }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else {
                return false
            }
            guard app.bundleIdentifier != "com.apple.systemuiserver" else {
                return false
            }
            guard let bundleID = app.bundleIdentifier else {
                return false
            }
            if bundleID.hasPrefix("com.apple.") {
                return false
            }

            switch app.activationPolicy {
            case .accessory, .prohibited, .regular:
                return true
            @unknown default:
                return false
            }
        }
        .sorted { lhs, rhs in
            hiddenProbeApplicationLabel(lhs).localizedCaseInsensitiveCompare(hiddenProbeApplicationLabel(rhs)) == .orderedAscending
        }
    }

    private func hiddenProbeApplicationLabel(_ app: NSRunningApplication) -> String {
        let base = app.bundleIdentifier ?? app.localizedName ?? "pid\(app.processIdentifier)"
        return base.replacingOccurrences(of: "/", with: "_")
    }

    private func collectHiddenProbeNodesRecursively(
        from element: AXUIElement,
        probeSource: String,
        path: String,
        depth: Int,
        screen: NSScreen,
        menuBarFrame: CGRect,
        scanRegion: CandidateScanRegion,
        protectedSystemRegionMinX: CGFloat,
        visibleCandidates: [DiscoveredCandidate],
        visitedNodeCount: inout Int
    ) -> [HiddenProbeNode] {
        guard depth <= 8 else {
            return []
        }

        visitedNodeCount += 1

        let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? "AXUnknown"
        let subrole = stringAttribute(kAXSubroleAttribute as String, from: element)
        let actions = actionNames(for: element)
        let parentRoles = ancestorRoles(for: element, limit: 8)
        let frame = frameAttribute(from: element)
        let owner = ownerProcessInfo(for: element)
        let title = preferredTitle(for: element) ?? owner.processName ?? role

        var collected: [HiddenProbeNode] = []
        if shouldIncludeInHiddenProbe(
            role: role,
            subrole: subrole,
            actions: actions,
            parentRoles: parentRoles,
            probeSource: probeSource
        ) {
            let classification = classifyHiddenProbeNode(
                frame: frame,
                screen: screen,
                menuBarFrame: menuBarFrame,
                scanRegion: scanRegion,
                protectedSystemRegionMinX: protectedSystemRegionMinX,
                visibleCandidates: visibleCandidates
            )
            collected.append(
                HiddenProbeNode(
                    element: element,
                    probeSource: probeSource,
                    title: title,
                    role: role,
                    subrole: subrole,
                    frame: frame,
                    ownerName: owner.processName,
                    bundleID: owner.bundleIdentifier,
                    path: path,
                    parentRoles: parentRoles,
                    actions: actions,
                    classification: classification
                )
            )
        }

        guard shouldDescendIntoHiddenProbeChildren(
            role: role,
            probeSource: probeSource,
            depth: depth
        ) else {
            return collected
        }

        for (index, child) in arrayAttribute(kAXChildrenAttribute as String, from: element).enumerated() {
            collected.append(
                contentsOf: collectHiddenProbeNodesRecursively(
                    from: child,
                    probeSource: probeSource,
                    path: "\(path)/\(index)",
                    depth: depth + 1,
                    screen: screen,
                    menuBarFrame: menuBarFrame,
                    scanRegion: scanRegion,
                    protectedSystemRegionMinX: protectedSystemRegionMinX,
                    visibleCandidates: visibleCandidates,
                    visitedNodeCount: &visitedNodeCount
                )
            )
        }

        return collected
    }

    private func shouldIncludeInHiddenProbe(
        role: String,
        subrole: String?,
        actions: [String],
        parentRoles: [String],
        probeSource: String
    ) -> Bool {
        if probeSource == "runningApp" || probeSource == "runningAppExtras" {
            if role == "AXMenu" || role == "AXMenuItem" {
                return false
            }
            if role == "AXApplication" || role == "AXMenuBar" {
                return false
            }
        }

        if supportedRoles.contains(role) {
            return true
        }

        if subrole == "AXMenuExtra" {
            return true
        }

        if parentRoles.contains("AXMenuBar") || parentRoles.contains("AXMenuBarItem") {
            return true
        }

        if actions.contains("AXPress") || actions.contains("AXShowMenu") {
            return true
        }

        return false
    }

    private func shouldDescendIntoHiddenProbeChildren(
        role: String,
        probeSource: String,
        depth: Int
    ) -> Bool {
        if probeSource == "runningApp" || probeSource == "runningAppExtras" {
            if role == "AXMenu" || role == "AXMenuItem" || role == "AXMenuBarItem" {
                return false
            }
            if depth >= 4 {
                return false
            }
        }

        return true
    }

    private func classifyHiddenProbeNode(
        frame: CGRect?,
        screen: NSScreen,
        menuBarFrame: CGRect,
        scanRegion: CandidateScanRegion,
        protectedSystemRegionMinX: CGFloat,
        visibleCandidates: [DiscoveredCandidate]
    ) -> String {
        guard let frame else {
            return "missingFrame"
        }

        if frame.width <= 0 || frame.height <= 0 {
            return "zeroSize"
        }

        if !frame.intersects(menuBarBand(for: screen)) {
            return "offMenuBarBand"
        }

        if matchesVisibleCandidate(frame: frame, in: visibleCandidates) {
            return "visibleMatched"
        }

        if frame.midX >= protectedSystemRegionMinX || frame.midX >= menuBarFrame.maxX - 4 {
            return "protectedTrailingRegion"
        }

        if frame.maxX < scanRegion.minX {
            return "outsideScanRegion[left]"
        }

        if frame.minX > scanRegion.maxX {
            return "outsideScanRegion[right]"
        }

        return "withinScanRegion"
    }

    private func matchesVisibleCandidate(
        frame: CGRect,
        in visibleCandidates: [DiscoveredCandidate]
    ) -> Bool {
        visibleCandidates.contains { candidate in
            candidate.frame.insetBy(dx: -8, dy: -6).intersects(frame)
        }
    }

    private func hiddenProbeLines(
        for nodes: [HiddenProbeNode],
        title: String,
        limit: Int
    ) -> [String] {
        var lines = ["\(title)=begin"]
        for (index, node) in nodes.prefix(limit).enumerated() {
            lines.append(node.debugLine(index: index + 1))
        }
        if nodes.count > limit {
            lines.append("\(title)=truncated \(nodes.count - limit) more")
        }
        lines.append("\(title)=end")
        return lines
    }

    private func hiddenProbePriority(_ classification: String) -> Int {
        switch classification {
        case "missingFrame":
            return 5
        case "zeroSize":
            return 4
        case "offMenuBarBand":
            return 3
        case "protectedTrailingRegion":
            return 2
        case "outsideScanRegion[left]", "outsideScanRegion[right]":
            return 1
        default:
            return 0
        }
    }

    private func hiddenProbeSort(lhs: HiddenProbeNode, rhs: HiddenProbeNode) -> Bool {
        let lhsPriority = hiddenProbePriority(lhs.classification)
        let rhsPriority = hiddenProbePriority(rhs.classification)
        if lhsPriority == rhsPriority {
            let lhsBundle = lhs.bundleID ?? lhs.title
            let rhsBundle = rhs.bundleID ?? rhs.title
            return lhsBundle < rhsBundle
        }
        return lhsPriority > rhsPriority
    }

    private func collectCandidatesRecursively(
        from element: AXUIElement,
        path: String,
        depth: Int,
        source: StatusItemSource
    ) -> [DiscoveredCandidate] {
        guard depth <= 6 else {
            return []
        }

        var collected: [DiscoveredCandidate] = []
        if let candidate = buildCandidate(from: element, source: source, debugPath: path) {
            collected.append(candidate)
        }

        for (index, child) in arrayAttribute(kAXChildrenAttribute as String, from: element).enumerated() {
            collected.append(
                contentsOf: collectCandidatesRecursively(
                    from: child,
                    path: "\(path)/\(index)",
                    depth: depth + 1,
                    source: source
                )
            )
        }

        return collected
    }

    private func bestCandidateFromAncestors(of element: AXUIElement, source: StatusItemSource) -> DiscoveredCandidate? {
        var current: AXUIElement? = element
        var depth = 0
        var best: DiscoveredCandidate?

        while let currentElement = current, depth <= 6 {
            if let candidate = buildCandidate(from: currentElement, source: source, debugPath: "SystemWide/\(depth)"),
               candidate.score > (best?.score ?? .min) {
                best = candidate
            }

            current = copyElementAttribute(kAXParentAttribute as String, from: currentElement)
            depth += 1
        }

        return best
    }

    private func buildCandidate(
        from element: AXUIElement,
        source: StatusItemSource,
        debugPath: String
    ) -> DiscoveredCandidate? {
        guard let frame = frameAttribute(from: element),
              frame.width > 0,
              frame.height > 0,
              frame.width <= 220,
              frame.height <= 80
        else {
            return nil
        }

        let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? "AXUnknown"
        let actions = actionNames(for: element)

        let owner = ownerProcessInfo(for: element)
        let parentRoles = ancestorRoles(for: element)

        let score = candidateScore(
            role: role,
            frame: frame,
            actions: actions,
            bundleID: owner.bundleIdentifier,
            parentRoles: parentRoles
        )

        guard score >= 1 else {
            return nil
        }

        return DiscoveredCandidate(
            title: preferredTitle(for: element) ?? owner.processName ?? role,
            role: role,
            frame: frame,
            ownerName: owner.processName,
            bundleID: owner.bundleIdentifier,
            source: source,
            score: score,
            debugPath: debugPath,
            interactionPoint: CGPoint(x: frame.midX, y: frame.midY),
            looksTextLike: false,
            isMenuBarScoped: isMenuBarScoped(role: role, parentRoles: parentRoles),
            directAXElement: element
        )
    }

    private func discoveredCandidate(from node: HiddenProbeNode) -> DiscoveredCandidate? {
        guard let frame = node.frame else {
            return nil
        }

        return DiscoveredCandidate(
            title: node.title,
            role: node.role,
            frame: frame,
            ownerName: hiddenNodeOwnerName(node),
            bundleID: hiddenNodeBundleIdentifier(node),
            source: .accessibility,
            score: hiddenNodeScore(node),
            debugPath: "\(node.path)|hiddenProbe",
            interactionPoint: CGPoint(x: frame.midX, y: frame.midY),
            looksTextLike: false,
            isMenuBarScoped: true,
            directAXElement: node.element
        )
    }

    private func candidateScore(
        role: String,
        frame: CGRect,
        actions: [String],
        bundleID: String?,
        parentRoles: [String]
    ) -> Int {
        var score = 0

        switch role {
        case "AXMenuBarItem":
            score += 4
        case "AXMenuButton", "AXPopUpButton":
            score += 3
        case "AXButton":
            score += 2
        default:
            break
        }

        if parentRoles.contains("AXMenuBar") {
            score += 3
        }

        if parentRoles.contains("AXMenuBarItem") {
            score += 1
        }

        if actions.contains("AXPress") {
            score += 1
        }

        if actions.contains("AXShowMenu") {
            score += 1
        }

        if frame.width >= 10, frame.width <= 72 {
            score += 1
        }

        if frame.height >= 10, frame.height <= 32 {
            score += 1
        }

        if frame.width > 120 || frame.height > 44 {
            score -= 3
        }

        if frame.width > 180 || frame.height > 60 {
            score -= 6
        }

        if role == "AXUnknown" {
            score -= 1
        }

        if let bundleID, !bundleID.hasPrefix("com.apple.") {
            score += 2
        }

        return score
    }

    private func resolvedRootElement(from appElement: AXUIElement) -> AXUIElement? {
        if let extrasMenuBar = copyElementAttribute("AXExtrasMenuBar", from: appElement) {
            return extrasMenuBar
        }

        if let menuBar = copyElementAttribute(kAXMenuBarAttribute as String, from: appElement) {
            return menuBar
        }

        let children = arrayAttribute(kAXChildrenAttribute as String, from: appElement)

        if let menuBarChild = children.first(where: {
            stringAttribute(kAXRoleAttribute as String, from: $0) == "AXMenuBar"
        }) {
            return menuBarChild
        }

        return firstCandidateContainer(in: children, depth: 0)
    }

    private func resolvedMenuBarElement(from appElement: AXUIElement) -> AXUIElement? {
        if let extrasMenuBar = copyElementAttribute("AXExtrasMenuBar", from: appElement) {
            return extrasMenuBar
        }

        if let menuBar = copyElementAttribute(kAXMenuBarAttribute as String, from: appElement) {
            return menuBar
        }

        let children = arrayAttribute(kAXChildrenAttribute as String, from: appElement)
        return firstElement(withRole: "AXMenuBar", in: children, depth: 0)
    }

    private func hiddenProbeRootDiagnostics(
        for element: AXUIElement,
        label: String
    ) -> [String] {
        let attributes = attributeNames(for: element)
        let children = arrayAttribute(kAXChildrenAttribute as String, from: element)
        let menuBar = copyElementAttribute(kAXMenuBarAttribute as String, from: element)
        let extrasMenuBar = copyElementAttribute("AXExtrasMenuBar", from: element)
        let attributeList = attributes.prefix(16).joined(separator: ",")
        let menuBarDescription = menuBar.map { stringAttribute(kAXRoleAttribute as String, from: $0) ?? "present" } ?? "nil"
        let extrasMenuBarDescription = extrasMenuBar.map { stringAttribute(kAXRoleAttribute as String, from: $0) ?? "present" } ?? "nil"

        var lines: [String] = [
            "\(label).attributes=\(attributeList)",
            "\(label).childCount=\(children.count)",
            "\(label).menuBarAttr=\(menuBarDescription)",
            "\(label).extrasMenuBarAttr=\(extrasMenuBarDescription)",
        ]

        for (index, child) in children.prefix(4).enumerated() {
            let role = stringAttribute(kAXRoleAttribute as String, from: child) ?? "AXUnknown"
            let subrole = stringAttribute(kAXSubroleAttribute as String, from: child) ?? "nil"
            let title = preferredTitle(for: child) ?? "nil"
            let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
            let childCount = arrayAttribute(kAXChildrenAttribute as String, from: child).count
            let frameDescription: String
            if let frame = frameAttribute(from: child) {
                frameDescription = "x:\(Int(frame.minX.rounded())) y:\(Int(frame.minY.rounded())) w:\(Int(frame.width.rounded())) h:\(Int(frame.height.rounded()))"
            } else {
                frameDescription = "nil"
            }
            lines.append(
                "\(label).child#\(index)=role=\(role) subrole=\(subrole) title=\(safeTitle) childCount=\(childCount) frame=\(frameDescription)"
            )
        }

        return lines
    }

    private func looksLikeApplicationMainMenuTitle(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let commonMenuTitles: Set<String> = [
            "file", "edit", "view", "window", "help", "format", "action", "services",
            "文件", "编辑", "查看", "窗口", "帮助", "格式", "显示", "快捷键",
        ]

        return commonMenuTitles.contains(normalized)
    }

    private func firstCandidateContainer(in elements: [AXUIElement], depth: Int) -> AXUIElement? {
        guard depth <= 4 else {
            return nil
        }

        for element in elements {
            let role = stringAttribute(kAXRoleAttribute as String, from: element)
            let children = arrayAttribute(kAXChildrenAttribute as String, from: element)

            if role == "AXGroup" || role == "AXToolbar" || role == "AXUnknown" || role == nil {
                if children.contains(where: {
                    guard let childRole = stringAttribute(kAXRoleAttribute as String, from: $0) else {
                        return false
                    }
                    return supportedRoles.contains(childRole)
                }) {
                    return element
                }
            }

            if let nested = firstCandidateContainer(in: children, depth: depth + 1) {
                return nested
            }
        }

        return nil
    }

    private func firstElement(withRole targetRole: String, in elements: [AXUIElement], depth: Int) -> AXUIElement? {
        guard depth <= 4 else {
            return nil
        }

        for element in elements {
            let role = stringAttribute(kAXRoleAttribute as String, from: element)
            if role == targetRole {
                return element
            }

            let children = arrayAttribute(kAXChildrenAttribute as String, from: element)
            if let nested = firstElement(withRole: targetRole, in: children, depth: depth + 1) {
                return nested
            }
        }

        return nil
    }

    private func deduplicate(_ items: [DiscoveredCandidate]) -> [DiscoveredCandidate] {
        var buckets: [String: DiscoveredCandidate] = [:]

        for item in items {
            let frameKey = "\(Int(item.frame.minX.rounded()))-\(Int(item.frame.width.rounded()))"
            let bundleKey = item.bundleID ?? item.title
            let key = "\(bundleKey)|\(frameKey)"

            if let existing = buckets[key] {
                if item.score > existing.score {
                    buckets[key] = item
                }
            } else {
                buckets[key] = item
            }
        }

        return Array(buckets.values)
    }

    private func estimatedBackgroundLuminance(
        pointer: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        sampleStartX: Int,
        sampleEndX: Int
    ) -> Int {
        guard width > 0, height > 0 else {
            return 220
        }

        var samples: [Int] = []
        let step = max(8, (sampleEndX - sampleStartX) / 24)
        let sampleY = min(max(0, height / 2), height - 1)

        var x = sampleStartX
        while x <= sampleEndX {
            samples.append(
                luminance(pointer: pointer, x: x, y: sampleY, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
            )
            x += step
        }

        guard !samples.isEmpty else {
            return 220
        }

        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func menuBarBand(for screen: NSScreen) -> CGRect {
        let thickness = max(NSStatusBar.system.thickness, 24)
        return CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - thickness - 6,
            width: screen.frame.width,
            height: thickness + 12
        )
    }

    private func detectVerticalRangeByLocalContrast(
        for columnRange: ClosedRange<Int>,
        pointer: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int
    ) -> ClosedRange<Int>? {
        var minY: Int?
        var maxY: Int?

        for y in 0..<height {
            var changedCount = 0
            for x in columnRange {
                let contrast = localContrastScore(
                    pointer: pointer,
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    bytesPerPixel: bytesPerPixel
                )
                if contrast >= 24 {
                    changedCount += 1
                }
            }

            if changedCount >= max(2, (columnRange.upperBound - columnRange.lowerBound + 1) / 8) {
                minY = minY ?? y
                maxY = y
            }
        }

        guard let minY, let maxY else {
            return nil
        }

        return minY...maxY
    }

    private func looksLikeMenuTextFragment(
        in imageRect: CGRect,
        pointer: UnsafePointer<UInt8>,
        imageWidth: Int,
        imageHeight: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        backgroundLuminance: Int
    ) -> Bool {
        let minX = max(0, Int(imageRect.minX.rounded(.down)))
        let maxX = min(imageWidth - 1, Int(imageRect.maxX.rounded(.up)) - 1)
        let minY = max(0, Int(imageRect.minY.rounded(.down)))
        let maxY = min(imageHeight - 1, Int(imageRect.maxY.rounded(.up)) - 1)

        guard maxX > minX, maxY > minY else {
            return false
        }

        let width = maxX - minX + 1
        let height = maxY - minY + 1
        guard width >= 10, height >= 10 else {
            return false
        }

        var activeColumns = Array(repeating: false, count: width)
        var activeRows = Array(repeating: false, count: height)
        var columnInk = Array(repeating: 0, count: width)
        var foregroundPixelCount = 0

        for y in minY...maxY {
            var rowInk = 0
            for x in minX...maxX {
                let lum = luminance(
                    pointer: pointer,
                    x: x,
                    y: y,
                    bytesPerRow: bytesPerRow,
                    bytesPerPixel: bytesPerPixel
                )
                let contrast = localContrastScore(
                    pointer: pointer,
                    x: x,
                    y: y,
                    width: imageWidth,
                    height: imageHeight,
                    bytesPerRow: bytesPerRow,
                    bytesPerPixel: bytesPerPixel
                )
                let isForeground = abs(lum - backgroundLuminance) >= 22 || contrast >= 28
                if isForeground {
                    foregroundPixelCount += 1
                    rowInk += 1
                    columnInk[x - minX] += 1
                }
            }
            activeRows[y - minY] = rowInk >= max(2, width / 9)
        }

        for (index, ink) in columnInk.enumerated() {
            activeColumns[index] = ink >= max(2, height / 8)
        }

        let area = width * height
        guard area > 0 else {
            return false
        }

        let coverageRatio = CGFloat(foregroundPixelCount) / CGFloat(area)
        let activeRowRatio = CGFloat(activeRows.filter { $0 }.count) / CGFloat(height)
        let aspectRatio = CGFloat(width) / CGFloat(height)
        let columnGroups = ScreenGeometry.mergeColumnActivity(activeColumns, gapTolerance: 1, minimumWidth: 1)
        let averageGroupWidth: CGFloat
        if columnGroups.isEmpty {
            averageGroupWidth = 0
        } else {
            let totalGroupWidth = columnGroups.reduce(0) { partialResult, range in
                partialResult + (range.upperBound - range.lowerBound + 1)
            }
            averageGroupWidth = CGFloat(totalGroupWidth) / CGFloat(columnGroups.count)
        }

        var transitions = 0
        for index in 1..<activeColumns.count where activeColumns[index] != activeColumns[index - 1] {
            transitions += 1
        }

        let wideWordLike =
            aspectRatio >= 1.45 &&
            columnGroups.count >= 2 &&
            coverageRatio <= 0.34 &&
            activeRowRatio <= 0.78
        let fragmentedLetterLike =
            aspectRatio >= 0.85 &&
            width >= 14 &&
            columnGroups.count >= 3 &&
            averageGroupWidth <= 5 &&
            coverageRatio <= 0.28 &&
            activeRowRatio <= 0.72
        let oscillatingTextLike =
            width >= 16 &&
            transitions >= 6 &&
            coverageRatio <= 0.30 &&
            activeRowRatio <= 0.74

        return wideWordLike || fragmentedLetterLike || oscillatingTextLike
    }

    private func screenRect(from imageRect: CGRect, capture: MenuBarCapture) -> CGRect {
        CGRect(
            x: capture.menuBarFrame.minX + (imageRect.minX / capture.scale),
            y: capture.menuBarFrame.minY + (imageRect.minY / capture.scale),
            width: imageRect.width / capture.scale,
            height: imageRect.height / capture.scale
        )
    }

    private func exportCaptureImage(_ capture: MenuBarCapture) -> String? {
        exportPNGImage(capture.image, prefix: "kbar-menubar-capture")
    }

    private func exportAnnotatedCaptureImage(
        _ capture: MenuBarCapture,
        rawCandidates: [DiscoveredCandidate],
        filteredCandidates: [DiscoveredCandidate]
    ) -> String? {
        let size = NSSize(width: capture.image.width, height: capture.image.height)
        let image = NSImage(size: size)
        image.lockFocus()

        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: capture.image, size: size).draw(in: NSRect(origin: .zero, size: size))

        let filteredKeys = Set(filteredCandidates.map(\.deduplicationKey))
        let rawByX = rawCandidates.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.frame.width < rhs.frame.width
            }
            return lhs.frame.minX < rhs.frame.minX
        }

        for (index, candidate) in rawByX.enumerated() {
            let imageRect = imageRect(from: candidate.frame, capture: capture)
            let isFiltered = filteredKeys.contains(candidate.deduplicationKey)
            let strokeColor = color(for: candidate.source, highlighted: isFiltered)
            strokeColor.setStroke()

            let path = NSBezierPath(rect: imageRect)
            path.lineWidth = isFiltered ? 3 : 1.5
            path.stroke()

            let labelRect = NSRect(
                x: imageRect.minX,
                y: min(CGFloat(capture.image.height - 18), imageRect.maxY + 2),
                width: min(160, CGFloat(capture.image.width) - imageRect.minX),
                height: 16
            )
            let labelText = "\(index + 1) \(candidate.source.shortLabel) s\(candidate.score)"
            let backgroundPath = NSBezierPath(
                roundedRect: labelRect,
                xRadius: 4,
                yRadius: 4
            )
            strokeColor.withAlphaComponent(0.88).setFill()
            backgroundPath.fill()

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle,
            ]
            NSString(string: labelText).draw(
                in: labelRect.insetBy(dx: 4, dy: 1),
                withAttributes: attributes
            )
        }

        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let imageRep = NSBitmapImageRep(data: tiffData),
              let cgImage = imageRep.cgImage
        else {
            return nil
        }

        return exportPNGImage(cgImage, prefix: "kbar-menubar-annotated")
    }

    private func exportPNGImage(_ image: CGImage, prefix: String) -> String? {
        let imageRep = NSBitmapImageRep(cgImage: image)
        guard let data = imageRep.representation(using: .png, properties: [:]) else {
            return nil
        }

        let url = temporaryPNGURL(prefix: prefix)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    private func temporaryPNGURL(prefix: String) -> URL {
        let tmpDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let fileName = "\(prefix)-\(formatter.string(from: Date())).png"
        return tmpDirectory.appendingPathComponent(fileName)
    }

    private func imageRect(from screenRect: CGRect, capture: MenuBarCapture) -> CGRect {
        CGRect(
            x: (screenRect.minX - capture.menuBarFrame.minX) * capture.scale,
            y: (screenRect.minY - capture.menuBarFrame.minY) * capture.scale,
            width: screenRect.width * capture.scale,
            height: screenRect.height * capture.scale
        )
    }

    private func color(for source: StatusItemSource, highlighted: Bool) -> NSColor {
        let baseColor: NSColor
        switch source {
        case .accessibility:
            baseColor = .systemBlue
        case .screenshot:
            baseColor = .systemOrange
        case .hybrid:
            baseColor = .systemPurple
        }

        return highlighted ? baseColor : baseColor.withAlphaComponent(0.7)
    }

    private func localContrastScore(
        pointer: UnsafePointer<UInt8>,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int
    ) -> Int {
        let lum = luminance(pointer: pointer, x: x, y: y, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)

        let leftX = max(0, x - 1)
        let rightX = min(width - 1, x + 1)
        let upY = max(0, y - 1)
        let downY = min(height - 1, y + 1)

        let left = luminance(pointer: pointer, x: leftX, y: y, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
        let right = luminance(pointer: pointer, x: rightX, y: y, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
        let up = luminance(pointer: pointer, x: x, y: upY, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
        let down = luminance(pointer: pointer, x: x, y: downY, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)

        return max(abs(lum - left), abs(lum - right), abs(lum - up), abs(lum - down))
    }

    private func splitWideRanges(
        _ ranges: [ClosedRange<Int>],
        contrastScores: [Int]
    ) -> [ClosedRange<Int>] {
        ranges.flatMap { range in
            splitWideRange(range, contrastScores: contrastScores)
        }
    }

    private func splitWideRange(
        _ range: ClosedRange<Int>,
        contrastScores: [Int]
    ) -> [ClosedRange<Int>] {
        let width = range.upperBound - range.lowerBound + 1
        guard width >= 72 else {
            return [range]
        }

        let candidateIndices = Array((range.lowerBound + 10)..<(range.upperBound - 10))
        guard !candidateIndices.isEmpty else {
            return [range]
        }

        let valleyIndex = candidateIndices.min { lhs, rhs in
            contrastScores[lhs] < contrastScores[rhs]
        }

        guard
            let valleyIndex,
            contrastScores[valleyIndex] <= 1,
            valleyIndex - range.lowerBound >= 10,
            range.upperBound - valleyIndex >= 10
        else {
            return [range]
        }

        let left = range.lowerBound...(valleyIndex - 1)
        let right = (valleyIndex + 1)...range.upperBound
        return splitWideRange(left, contrastScores: contrastScores) + splitWideRange(right, contrastScores: contrastScores)
    }

    private func luminance(
        pointer: UnsafePointer<UInt8>,
        x: Int,
        y: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int
    ) -> Int {
        let offset = (y * bytesPerRow) + (x * bytesPerPixel)
        let red = Int(pointer[offset])
        let green = Int(pointer[offset + 1])
        let blue = Int(pointer[offset + 2])
        return (red * 299 + green * 587 + blue * 114) / 1000
    }

    private func deduplicateRanges(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = ranges.sorted { lhs, rhs in
            if lhs.lowerBound == rhs.lowerBound {
                return lhs.upperBound < rhs.upperBound
            }
            return lhs.lowerBound < rhs.lowerBound
        }

        var merged: [ClosedRange<Int>] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            if range.lowerBound <= last.upperBound + 3 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private func ancestorRoles(for element: AXUIElement, limit: Int = 6) -> [String] {
        var roles: [String] = []
        var current = copyElementAttribute(kAXParentAttribute as String, from: element)
        var depth = 0

        while let currentElement = current, depth < limit {
            if let role = stringAttribute(kAXRoleAttribute as String, from: currentElement) {
                roles.append(role)
            }
            current = copyElementAttribute(kAXParentAttribute as String, from: currentElement)
            depth += 1
        }

        return roles
    }

    private func isMenuBarScoped(role: String, parentRoles: [String]) -> Bool {
        if role == "AXMenuBarItem" {
            return true
        }

        if parentRoles.contains("AXMenuBar") || parentRoles.contains("AXMenuBarItem") {
            return true
        }

        return false
    }

    private func ownerProcessInfo(for element: AXUIElement) -> ProcessInfoSnapshot {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(element, &pid)

        guard error == .success, pid > 0 else {
            return ProcessInfoSnapshot(pid: 0, processName: nil, bundleIdentifier: nil)
        }

        let app = NSRunningApplication(processIdentifier: pid)
        return ProcessInfoSnapshot(
            pid: pid,
            processName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier
        )
    }

    private func preferredTitle(for element: AXUIElement) -> String? {
        let attributes = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXValueAttribute as String,
            kAXHelpAttribute as String,
        ]

        for attribute in attributes {
            if let value = stringAttribute(attribute, from: element),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }

        return nil
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success, let actions = actions as? [String] else {
            return []
        }
        return actions
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

    private func elementAtPosition(_ element: AXUIElement, x: CGFloat, y: CGFloat) -> AXUIElement? {
        var result: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(element, Float(x), Float(y), &result)
        guard error == .success else {
            return nil
        }
        return result
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

    private func arrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttributeValue(attribute, from: element) as? NSArray else {
            return []
        }

        return value.compactMap { rawValue in
            guard let object = rawValue as AnyObject?,
                  CFGetTypeID(object) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(object, to: AXUIElement.self)
        }
    }

    private func copyAttributeValue(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }
        return value
    }

    private func attributeNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(element, &names)
        guard error == .success, let names = names as? [String] else {
            return []
        }
        return names
    }

    private let supportedRoles: Set<String> = [
        "AXMenuBarItem",
        "AXButton",
        "AXMenuButton",
        "AXPopUpButton",
    ]
}

private struct DiscoveredCandidate {
    let title: String
    let role: String
    let frame: CGRect
    let ownerName: String?
    let bundleID: String?
    let source: StatusItemSource
    let score: Int
    let debugPath: String
    let interactionPoint: CGPoint?
    let looksTextLike: Bool
    let isMenuBarScoped: Bool
    let directAXElement: AXUIElement?

    var deduplicationKey: String {
        let frameKey = "\(Int(frame.minX.rounded()))-\(Int(frame.width.rounded()))"
        let bundleKey = bundleID ?? title
        return "\(bundleKey)|\(frameKey)"
    }

    func debugLine(index: Int) -> String {
        let owner = ownerName ?? "nil"
        let bundle = bundleID ?? "nil"
        let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
        let interaction = interactionPoint.map { "(x:\(Int($0.x)) y:\(Int($0.y)))" } ?? "nil"
        let textLike = looksTextLike ? " textLike=true" : ""
        let scoped = source == .screenshot ? "" : " menuScoped=\(isMenuBarScoped)"
        return "#\(index) src=\(source.rawValue) score=\(score) role=\(role) owner=\(owner) bundle=\(bundle) title=\(safeTitle) frame=(x:\(Int(frame.minX)) y:\(Int(frame.minY)) w:\(Int(frame.width)) h:\(Int(frame.height))) interaction=\(interaction)\(textLike)\(scoped) path=\(debugPath)"
    }

    func withInteractionPoint(_ point: CGPoint) -> DiscoveredCandidate {
        DiscoveredCandidate(
            title: title,
            role: role,
            frame: frame,
            ownerName: ownerName,
            bundleID: bundleID,
            source: source,
            score: score,
            debugPath: debugPath,
            interactionPoint: point,
            looksTextLike: looksTextLike,
            isMenuBarScoped: isMenuBarScoped,
            directAXElement: directAXElement
        )
    }

    func enrichingInteraction(from candidate: DiscoveredCandidate) -> DiscoveredCandidate {
        let mergedTitle = (title == "Screenshot Item") ? candidate.title : title
        let mergedRole = (role == "Screenshot") ? candidate.role : role
        let mergedSource: StatusItemSource = source == .screenshot ? .hybrid : source

        return DiscoveredCandidate(
            title: mergedTitle,
            role: mergedRole,
            frame: frame,
            ownerName: ownerName ?? candidate.ownerName,
            bundleID: bundleID ?? candidate.bundleID,
            source: mergedSource,
            score: max(score, candidate.score),
            debugPath: "\(debugPath)|matched:\(candidate.source.rawValue)",
            interactionPoint: candidate.interactionPoint ?? CGPoint(x: candidate.frame.midX, y: candidate.frame.midY),
            looksTextLike: looksTextLike,
            isMenuBarScoped: isMenuBarScoped || candidate.isMenuBarScoped,
            directAXElement: directAXElement ?? candidate.directAXElement
        )
    }
}

private struct ProcessInfoSnapshot {
    let pid: pid_t
    let processName: String?
    let bundleIdentifier: String?
}

private extension StatusItemSource {
    var shortLabel: String {
        switch self {
        case .accessibility:
            return "AX"
        case .screenshot:
            return "SS"
        case .hybrid:
            return "HY"
        }
    }
}

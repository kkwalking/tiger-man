import AppKit
import ApplicationServices
import Foundation

struct DiscoveryResult {
    let items: [StatusItemModel]
    let menuBarFrame: CGRect
    let diagnostics: [String]
}

private struct ScreenshotFallbackResult {
    let candidates: [DiscoveredCandidate]
    let diagnostics: [String]
}

private struct CandidateFilterSnapshot {
    let name: String
    let items: [DiscoveredCandidate]
}

@MainActor
final class StatusItemDiscoveryService {
    private let screenCaptureService: ScreenCaptureService

    init(screenCaptureService: ScreenCaptureService) {
        self.screenCaptureService = screenCaptureService
    }

    func discoverItems(on screen: NSScreen, kBarFrame: CGRect?) -> DiscoveryResult {
        let menuBarFrame = LayoutCoordinator.menuBarFrame(for: screen)
        guard let capture = screenCaptureService.captureMenuBar(for: screen) else {
            return DiscoveryResult(items: [], menuBarFrame: menuBarFrame, diagnostics: ["无法截取菜单栏图像。"])
        }

        let accessibilityCandidates = collectCandidates(on: screen)
        let screenshotResult = screenshotFallbackCandidates(in: capture, kBarFrame: kBarFrame)
        let screenshotCandidates = screenshotResult.candidates
        let rawCandidates = deduplicate(accessibilityCandidates + screenshotCandidates)
        var diagnostics: [String] = []
        diagnostics.append("captureImage=\(capture.image.width)x\(capture.image.height) scale=\(String(format: "%.2f", capture.scale))")
        if let exportPath = exportCaptureImage(capture) {
            diagnostics.append("captureExport=\(exportPath)")
        }
        diagnostics.append("axCandidates=\(accessibilityCandidates.count)")
        diagnostics.append("screenshotCandidates=\(screenshotCandidates.count)")
        diagnostics.append("rawCandidates=\(rawCandidates.count)")
        diagnostics.append("menuBarFrame=x:\(Int(menuBarFrame.minX)) y:\(Int(menuBarFrame.minY)) w:\(Int(menuBarFrame.width)) h:\(Int(menuBarFrame.height))")
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
            kBarFrame: kBarFrame
        )
        let filteredCandidates = filterSnapshots.last?.items ?? []

        diagnostics.append(contentsOf: filterSnapshots.map { "\($0.name)=\($0.items.count)" })
        diagnostics.append(contentsOf: diagnosticLines(for: rawCandidates, title: "rawCandidateDetails", limit: 40))
        diagnostics.append(contentsOf: diagnosticLines(for: filteredCandidates, title: "filteredCandidateDetails", limit: 40))

        if let annotatedPath = exportAnnotatedCaptureImage(
            capture,
            rawCandidates: rawCandidates,
            filteredCandidates: filteredCandidates
        ) {
            diagnostics.append("captureAnnotated=\(annotatedPath)")
        }

        let items = filteredCandidates.compactMap { candidate -> StatusItemModel? in
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
                interactionPoint: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY),
                source: candidate.source,
                snapshot: snapshot,
                isVisibleInMenuBar: true,
                role: candidate.role
            )
        }

        Logger.info("Discovered \(items.count) menu bar items")
        diagnostics.append("snapshotsBuilt=\(items.count)")
        return DiscoveryResult(items: items, menuBarFrame: menuBarFrame, diagnostics: diagnostics)
    }

    private func buildFilterSnapshots(
        from rawCandidates: [DiscoveredCandidate],
        screen: NSScreen,
        menuBarFrame: CGRect,
        kBarFrame: CGRect?
    ) -> [CandidateFilterSnapshot] {
        let protectedSystemRegionMinX = menuBarFrame.maxX - reservedSystemTrailingWidth(in: menuBarFrame)
        let menuBarCandidates = rawCandidates.filter { candidate in
            candidate.frame.intersects(menuBarBand(for: screen))
        }
        let withoutKBarCandidates = menuBarCandidates.filter { candidate in
            guard let kBarFrame else { return true }
            return !candidate.frame.intersects(kBarFrame.insetBy(dx: -6, dy: -4))
        }
        let rightSideCandidates = withoutKBarCandidates.filter { candidate in
            candidate.frame.minX >= (menuBarFrame.maxX - min(760, menuBarFrame.width * 0.7))
        }
        let sizeQualifiedCandidates = rightSideCandidates.filter { candidate in
            candidate.frame.width >= 8 && candidate.frame.width <= 72 &&
            candidate.frame.height >= 8 && candidate.frame.height <= 32
        }
        let bundleFilteredCandidates = sizeQualifiedCandidates.filter { candidate in
            candidate.bundleID != Bundle.main.bundleIdentifier
        }
        let appRegionCandidates = bundleFilteredCandidates.filter { candidate in
            !shouldPreserveInMenuBar(candidate, protectedSystemRegionMinX: protectedSystemRegionMinX)
        }
        let sortedCandidates = appRegionCandidates.sorted { $0.frame.minX < $1.frame.minX }

        return [
            CandidateFilterSnapshot(name: "menuBarBandCandidates", items: menuBarCandidates),
            CandidateFilterSnapshot(name: "excludingKBarCandidates", items: withoutKBarCandidates),
            CandidateFilterSnapshot(name: "rightRegionCandidates", items: rightSideCandidates),
            CandidateFilterSnapshot(name: "sizeQualifiedCandidates", items: sizeQualifiedCandidates),
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

    private func collectCandidates(on screen: NSScreen) -> [DiscoveredCandidate] {
        let systemUIServerCandidates = candidatesFromSystemUIServer()
        let fallbackCandidates = candidatesFromSystemWide(on: screen)

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

    private func candidatesFromSystemWide(on screen: NSScreen) -> [DiscoveredCandidate] {
        let systemWideElement = AXUIElementCreateSystemWide()
        let band = menuBarBand(for: screen)
        let sampleY = band.midY
        let startX = screen.frame.maxX - 8
        let endX = max(screen.frame.minX, screen.frame.maxX - 720)
        let step: CGFloat = 20

        var results: [DiscoveredCandidate] = []
        var x = startX

        while x >= endX {
            if let element = elementAtPosition(systemWideElement, x: x, y: sampleY),
               let candidate = bestCandidateFromAncestors(of: element, source: .hybrid) {
                results.append(candidate)
            }
            x -= step
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

        let defaultStartScreenX = max(capture.menuBarFrame.minX, capture.menuBarFrame.maxX - 760)
        let startScreenX: CGFloat
        let startMode: String
        if let kBarFrame {
            let anchored = min(max(defaultStartScreenX, kBarFrame.maxX + 4), capture.menuBarFrame.maxX - 120)
            startScreenX = anchored
            startMode = "kBarAnchored"
        } else {
            startScreenX = defaultStartScreenX
            startMode = "default"
        }
        let endScreenX = capture.menuBarFrame.maxX - 6

        let startX = max(0, Int(((startScreenX - capture.menuBarFrame.minX) * capture.scale).rounded(.down)))
        let endX = min(width - 1, Int(((endScreenX - capture.menuBarFrame.minX) * capture.scale).rounded(.down)))

        guard endX - startX > 20 else {
            return ScreenshotFallbackResult(
                candidates: [],
                diagnostics: ["screenshotFallback=rangeTooSmall startX=\(startX) endX=\(endX)"]
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

            return DiscoveredCandidate(
                title: "Screenshot Item",
                role: "Screenshot",
                frame: screenRect,
                ownerName: nil,
                bundleID: nil,
                source: .screenshot,
                score: 2,
                debugPath: "ScreenshotFallback"
            )
        }

        let activeColumnCount = activeColumns.filter { $0 }.count
        let edgeColumnCount = edgeColumns.filter { $0 }.count
        return ScreenshotFallbackResult(
            candidates: candidates,
            diagnostics: [
                "screenshotRange=start:\(startX) end:\(endX) mode:\(startMode)",
                "backgroundLuminance=\(backgroundLuminance)",
                "analysisHeight=\(analysisHeight)/\(height)",
                "activeColumns=\(activeColumnCount)/\(activeColumns.count)",
                "edgeColumns=\(edgeColumnCount)/\(edgeColumns.count)",
                "contrastRanges=\(contrastRanges.count)",
                "edgeRanges=\(edgeRanges.count)",
                "mergedRanges=\(mergedRanges.count)",
                "splitRanges=\(ranges.count)",
            ]
        )
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
        guard let role = stringAttribute(kAXRoleAttribute as String, from: element),
              supportedRoles.contains(role),
              let frame = frameAttribute(from: element),
              frame.width > 0,
              frame.height > 0
        else {
            return nil
        }

        let owner = ownerProcessInfo(for: element)
        let parentRoles = ancestorRoles(for: element)
        let score = candidateScore(
            role: role,
            frame: frame,
            actions: actionNames(for: element),
            bundleID: owner.bundleIdentifier,
            parentRoles: parentRoles
        )

        guard score >= 3 else {
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
            debugPath: debugPath
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

        if frame.width >= 10, frame.width <= 72 {
            score += 1
        }

        if frame.height >= 10, frame.height <= 32 {
            score += 1
        }

        if let bundleID, !bundleID.hasPrefix("com.apple.") {
            score += 2
        }

        return score
    }

    private func resolvedRootElement(from appElement: AXUIElement) -> AXUIElement? {
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

        return CGRect(origin: position, size: size)
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

    var deduplicationKey: String {
        let frameKey = "\(Int(frame.minX.rounded()))-\(Int(frame.width.rounded()))"
        let bundleKey = bundleID ?? title
        return "\(bundleKey)|\(frameKey)"
    }

    func debugLine(index: Int) -> String {
        let owner = ownerName ?? "nil"
        let bundle = bundleID ?? "nil"
        let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
        return "#\(index) src=\(source.rawValue) score=\(score) role=\(role) owner=\(owner) bundle=\(bundle) title=\(safeTitle) frame=(x:\(Int(frame.minX)) y:\(Int(frame.minY)) w:\(Int(frame.width)) h:\(Int(frame.height))) path=\(debugPath)"
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

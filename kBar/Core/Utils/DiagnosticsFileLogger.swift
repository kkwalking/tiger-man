import AppKit
import Foundation

enum DiagnosticsFileLogger {
    private static let baseURL = URL(fileURLWithPath: "/Users/zhouzekun/code/kbar", isDirectory: true)
    private static let eventsURL = baseURL.appendingPathComponent("kbar-events.log")
    private static let latestScanURL = baseURL.appendingPathComponent("kbar-scan-latest.log")
    private static let latestInteractionURL = baseURL.appendingPathComponent("kbar-interaction-latest.log")
    private static let latestHiddenDiscoveryURL = baseURL.appendingPathComponent("kbar-hidden-discovery-latest.log")
    private static let queue = DispatchQueue(label: "com.zhouzekun.kbar.diagnostics-file")

    static func appendRuntimeLog(level: String, message: String) {
        appendEventBlock(
            title: "runtime",
            lines: [
                "level=\(level)",
                "message=\(message)",
            ]
        )
    }

    static func recordScanSnapshot(
        reason: String,
        permissions: PermissionStatus,
        itemCount: Int,
        menuBarFrame: CGRect,
        kBarFrame: CGRect?,
        diagnostics: [String],
        lastError: String?
    ) {
        var lines: [String] = [
            "timestamp=\(timestamp())",
            "reason=\(reason)",
            "permissions=ax:\(permissions.accessibilityGranted) screen:\(permissions.screenCaptureGranted)",
            "itemCount=\(itemCount)",
            "menuBarFrame=\(rectDescription(menuBarFrame))",
            "kBarFrame=\(kBarFrame.map(rectDescription) ?? "nil")",
            "lastError=\(lastError ?? "nil")",
            "diagnostics=begin",
        ]
        lines.append(contentsOf: diagnostics)
        lines.append("diagnostics=end")

        writeLatest(lines.joined(separator: "\n") + "\n", to: latestScanURL)
        appendEventBlock(
            title: "scan",
            lines: [
                "reason=\(reason)",
                "itemCount=\(itemCount)",
                "lastError=\(lastError ?? "nil")",
            ] + diagnostics
        )
    }

    static func recordInteractionSnapshot(
        item: StatusItemModel,
        interaction: StatusItemInteraction,
        succeeded: Bool,
        diagnostics: [String],
        lastError: String?
    ) {
        var lines: [String] = [
            "timestamp=\(timestamp())",
            "item=\(item.displayName)",
            "interaction=\(describe(interaction))",
            "succeeded=\(succeeded)",
            "source=\(item.source.rawValue)",
            "visibleInMenuBar=\(item.isVisibleInMenuBar)",
            "frame=\(rectDescription(item.frameInScreen))",
            "interactionPoint=\(pointDescription(item.interactionPoint))",
            "bundleID=\(item.ownerBundleID ?? "nil")",
            "lastError=\(lastError ?? "nil")",
            "diagnostics=begin",
        ]
        lines.append(contentsOf: diagnostics)
        lines.append("diagnostics=end")

        writeLatest(lines.joined(separator: "\n") + "\n", to: latestInteractionURL)
        appendEventBlock(
            title: "interaction",
            lines: [
                "item=\(item.displayName)",
                "interaction=\(describe(interaction))",
                "succeeded=\(succeeded)",
                "lastError=\(lastError ?? "nil")",
            ] + diagnostics
        )
    }

    static func recordHiddenDiscoverySnapshot(
        reason: String,
        permissions: PermissionStatus,
        diagnostics: [String],
        lastError: String?
    ) {
        var lines: [String] = [
            "timestamp=\(timestamp())",
            "reason=\(reason)",
            "permissions=ax:\(permissions.accessibilityGranted) screen:\(permissions.screenCaptureGranted)",
            "lastError=\(lastError ?? "nil")",
            "diagnostics=begin",
        ]
        lines.append(contentsOf: diagnostics)
        lines.append("diagnostics=end")

        writeLatest(lines.joined(separator: "\n") + "\n", to: latestHiddenDiscoveryURL)
        appendEventBlock(
            title: "hidden-discovery",
            lines: [
                "reason=\(reason)",
                "lastError=\(lastError ?? "nil")",
            ] + diagnostics
        )
    }

    private static func appendEventBlock(title: String, lines: [String]) {
        let block = ([
            "===== \(title) \(timestamp()) =====",
        ] + lines + [""]).joined(separator: "\n")
        append(block, to: eventsURL)
    }

    private static func writeLatest(_ content: String, to url: URL) {
        queue.sync {
            do {
                try ensureBaseDirectory()
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("[kBar][Diagnostics][Error] Failed to write %@: %@", url.path, String(describing: error))
            }
        }
    }

    private static func append(_ content: String, to url: URL) {
        queue.sync {
            do {
                try ensureBaseDirectory()
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
                }

                let data = Data(content.utf8)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                NSLog("[kBar][Diagnostics][Error] Failed to append %@: %@", url.path, String(describing: error))
            }
        }
    }

    private static func ensureBaseDirectory() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private static nonisolated func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static nonisolated func describe(_ interaction: StatusItemInteraction) -> String {
        switch interaction {
        case .leftClick:
            return "left"
        case .rightClick:
            return "right"
        }
    }

    private static nonisolated func rectDescription(_ rect: CGRect) -> String {
        "(x:\(Int(rect.minX.rounded())) y:\(Int(rect.minY.rounded())) w:\(Int(rect.width.rounded())) h:\(Int(rect.height.rounded())))"
    }

    private static nonisolated func pointDescription(_ point: CGPoint) -> String {
        "(x:\(Int(point.x.rounded())) y:\(Int(point.y.rounded())))"
    }
}

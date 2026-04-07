import AppKit
import ApplicationServices

struct StatusItemModel: Identifiable {
    let id: UUID
    let ownerBundleID: String?
    let ownerName: String?
    let title: String?
    let frameInScreen: CGRect
    let interactionPoint: CGPoint
    let source: StatusItemSource
    let snapshot: NSImage
    let isVisibleInMenuBar: Bool
    let role: String?
    let directAXElement: AXUIElement?

    var displayName: String {
        ownerName ?? title ?? ownerBundleID ?? "Unknown Item"
    }
}

enum StatusItemSource: String {
    case screenshot
    case accessibility
    case hybrid
}

enum StatusItemInteraction {
    case leftClick
    case rightClick
}

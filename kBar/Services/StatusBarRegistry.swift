import AppKit

struct StatusBarRefreshResult {
    let items: [StatusItemModel]
    let menuBarFrame: CGRect
    let diagnostics: [String]
    let hiddenDiagnostics: [String]
}

@MainActor
final class StatusBarRegistry {
    private let discoveryService: StatusItemDiscoveryService
    private(set) var items: [StatusItemModel] = []

    init(discoveryService: StatusItemDiscoveryService) {
        self.discoveryService = discoveryService
    }

    func refresh(on screen: NSScreen, kBarFrame: CGRect?) -> StatusBarRefreshResult {
        let result = discoveryService.discoverItems(on: screen, kBarFrame: kBarFrame)
        items = result.items.sorted(by: sortItems)
        return StatusBarRefreshResult(
            items: items,
            menuBarFrame: result.menuBarFrame,
            diagnostics: result.diagnostics,
            hiddenDiagnostics: result.hiddenDiagnostics
        )
    }

    private func sortItems(lhs: StatusItemModel, rhs: StatusItemModel) -> Bool {
        if lhs.isVisibleInMenuBar != rhs.isVisibleInMenuBar {
            return !lhs.isVisibleInMenuBar && rhs.isVisibleInMenuBar
        }

        if lhs.isVisibleInMenuBar {
            return lhs.frameInScreen.minX < rhs.frameInScreen.minX
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

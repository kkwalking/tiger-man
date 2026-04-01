import AppKit

struct StatusBarRefreshResult {
    let items: [StatusItemModel]
    let menuBarFrame: CGRect
    let diagnostics: [String]
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
        items = result.items.sorted { $0.frameInScreen.minX < $1.frameInScreen.minX }
        return StatusBarRefreshResult(items: items, menuBarFrame: result.menuBarFrame, diagnostics: result.diagnostics)
    }
}

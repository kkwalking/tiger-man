import AppKit
import SwiftUI

@MainActor
final class MirrorPanelController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private let activateHandler: (StatusItemModel, StatusItemInteraction) -> Void
    private let refreshHandler: () -> Void
    private let settingsHandler: () -> Void

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 320, height: 84)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: rootView())
        return panel
    }()

    var isVisible: Bool {
        panel.isVisible
    }

    init(
        appState: AppState,
        activateHandler: @escaping (StatusItemModel, StatusItemInteraction) -> Void,
        refreshHandler: @escaping () -> Void,
        settingsHandler: @escaping () -> Void
    ) {
        self.appState = appState
        self.activateHandler = activateHandler
        self.refreshHandler = refreshHandler
        self.settingsHandler = settingsHandler
    }

    func update(items: [StatusItemModel]) {
        let panelSize = preferredPanelSize(for: items.count)
        panel.setContentSize(panelSize)
        panel.contentView = NSHostingView(rootView: rootView())
    }

    func show(relativeTo anchorFrame: CGRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) }) ?? NSScreen.main
        guard let screen else {
            return
        }

        let panelFrame = LayoutCoordinator.panelFrame(
            panelSize: preferredPanelSize(for: appState.items.count),
            anchorFrame: anchorFrame,
            screen: screen
        )
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !appState.keepPanelOpenAfterInteraction {
            close()
            appState.isPanelVisible = false
        }
    }

    private func preferredPanelSize(for itemCount: Int) -> CGSize {
        let width = min(640, max(220, CGFloat(itemCount) * 56 + 88))
        return CGSize(width: width, height: 84)
    }

    private func rootView() -> some View {
        MirrorPanelView(
            appState: appState,
            activateHandler: activateHandler,
            refreshHandler: refreshHandler,
            settingsHandler: settingsHandler
        )
    }
}

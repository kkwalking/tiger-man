import AppKit
import SwiftUI

@MainActor
final class MirrorPanelController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private let activateHandler: (StatusItemModel, StatusItemInteraction) -> Void
    private let refreshHandler: () -> Void
    private let settingsHandler: () -> Void
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 320, height: 84)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
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
        installEventMonitors()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        removeEventMonitors()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Non-activating panels can transiently lose key status when the host app
        // is not active. Explicit outside-click monitoring is more reliable.
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

    private func installEventMonitors() {
        guard globalEventMonitor == nil, localEventMonitor == nil else {
            return
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.dismissIfNeededForExternalClick()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            self?.handleLocalEvent(event) ?? event
        }
    }

    private func removeEventMonitors() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else {
            return event
        }

        if event.type == .keyDown, event.keyCode == 53 {
            dismissPanel()
            return nil
        }

        let eventLocation = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.contains(eventLocation) else {
            return event
        }

        dismissPanel()
        return event
    }

    private func dismissIfNeededForExternalClick() {
        guard panel.isVisible else {
            return
        }

        if !panel.frame.contains(NSEvent.mouseLocation) {
            dismissPanel()
        }
    }

    private func dismissPanel() {
        close()
        appState.isPanelVisible = false
    }
}

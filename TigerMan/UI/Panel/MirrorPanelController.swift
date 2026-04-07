import AppKit
import SwiftUI

@MainActor
final class MirrorPanelController: NSObject, NSWindowDelegate {
    enum PanelPlacement {
        case anchorFrame(CGRect)
        case trailingMenuBar(screen: NSScreen, trailingInset: CGFloat)
    }

    private let appState: AppState
    private let activateHandler: (StatusItemModel, StatusItemInteraction) -> Void
    private let settingsHandler: () -> Void
    private let dismissalExemptionFrameProvider: () -> CGRect?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 320, height: 44)),
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
        settingsHandler: @escaping () -> Void,
        dismissalExemptionFrameProvider: @escaping () -> CGRect?
    ) {
        self.appState = appState
        self.activateHandler = activateHandler
        self.settingsHandler = settingsHandler
        self.dismissalExemptionFrameProvider = dismissalExemptionFrameProvider
    }

    func update(items: [StatusItemModel]) {
        _ = applyPreferredContentSize()
    }

    func show(using placement: PanelPlacement) {
        let panelSize = applyPreferredContentSize()
        let panelFrame: CGRect

        switch placement {
        case let .anchorFrame(anchorFrame):
            let screen = LayoutCoordinator.screen(containing: anchorFrame) ?? NSScreen.main
            guard let screen else {
                return
            }
            panelFrame = LayoutCoordinator.panelFrame(
                panelSize: panelSize,
                anchorFrame: anchorFrame,
                screen: screen
            )
        case let .trailingMenuBar(screen, trailingInset):
            panelFrame = LayoutCoordinator.trailingMenuBarPanelFrame(
                panelSize: panelSize,
                screen: screen,
                trailingInset: trailingInset
            )
        }

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

    private func applyPreferredContentSize() -> CGSize {
        let hostingView = NSHostingView(rootView: rootView())
        hostingView.layoutSubtreeIfNeeded()

        let fittingSize = hostingView.fittingSize
        let panelSize = CGSize(
            width: min(640, max(180, ceil(fittingSize.width))),
            height: max(1, ceil(fittingSize.height))
        )

        panel.setContentSize(panelSize)
        panel.contentView = hostingView
        return panelSize
    }

    private func rootView() -> MirrorPanelView {
        MirrorPanelView(
            appState: appState,
            activateHandler: activateHandler,
            settingsHandler: settingsHandler
        )
    }

    private func installEventMonitors() {
        guard globalEventMonitor == nil, localEventMonitor == nil else {
            return
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.dismissIfNeededForExternalClick(event)
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
        guard shouldDismiss(for: event, at: eventLocation) else {
            return event
        }

        dismissPanel()
        return event
    }

    private func dismissIfNeededForExternalClick(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        let eventLocation = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if shouldDismiss(for: event, at: eventLocation) {
            dismissPanel()
        }
    }

    private func shouldDismiss(for event: NSEvent, at location: CGPoint) -> Bool {
        if panel.frame.contains(location) {
            return false
        }

        if event.type == .leftMouseDown,
           let exemptFrame = dismissalExemptionFrameProvider(),
           exemptFrame.contains(location) {
            return false
        }

        return true
    }

    private func dismissPanel() {
        close()
        appState.isPanelVisible = false
    }
}

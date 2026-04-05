import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        appState: AppState,
        permissionCenter: PermissionCenter,
        refreshHandler: @escaping () -> Void
    ) {
        let rootView = SettingsView(
            appState: appState,
            permissionCenter: permissionCenter,
            refreshHandler: refreshHandler
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "kBar Settings"
        window.contentView = hostingView
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

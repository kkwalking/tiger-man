import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        appState: AppState,
        permissionCenter: PermissionCenter,
        refreshHandler: @escaping () -> Void
    ) {
        let contentView = SettingsView(
            appState: appState,
            permissionCenter: permissionCenter,
            refreshHandler: refreshHandler
        )

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "kBar Settings"
        window.contentView = NSHostingView(rootView: contentView)
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

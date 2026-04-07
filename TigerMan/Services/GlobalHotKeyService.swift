import AppKit

final class GlobalHotKeyService {
    var isEnabled = true

    private var shortcut: GlobalHotKeyShortcut
    private let handler: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(shortcut: GlobalHotKeyShortcut, handler: @escaping () -> Void) {
        self.shortcut = shortcut
        self.handler = handler
    }

    deinit {
        unregister()
    }

    func register() -> Bool {
        guard globalMonitor == nil, localMonitor == nil else {
            return true
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            guard self.matchesShortcut(event) else {
                return event
            }

            self.handler()
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesShortcut(event) else {
                return
            }

            Task { @MainActor [handler = self.handler] in
                handler()
            }
        }

        guard localMonitor != nil, globalMonitor != nil else {
            unregister()
            Logger.error("Failed to register global hot key shortcut=\(shortcut.displayName)")
            return false
        }

        Logger.info("Registered global hot key shortcut=\(shortcut.displayName)")
        return true
    }

    @discardableResult
    func updateShortcut(_ shortcut: GlobalHotKeyShortcut) -> Bool {
        self.shortcut = shortcut
        Logger.info("Updated global hot key shortcut=\(shortcut.displayName)")
        return register()
    }

    func unregister() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func matchesShortcut(_ event: NSEvent) -> Bool {
        guard isEnabled else {
            return false
        }

        return shortcut.matches(event)
    }
}

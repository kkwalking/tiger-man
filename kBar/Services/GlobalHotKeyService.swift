import AppKit
import Carbon

final class GlobalHotKeyService {
    static let shortcutDisplayName = "⌃⌥⌘K"

    private let handler: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(handler: @escaping () -> Void) {
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
            Logger.error("Failed to register global hot key shortcut=\(Self.shortcutDisplayName)")
            return false
        }

        Logger.info("Registered global hot key shortcut=\(Self.shortcutDisplayName)")
        return true
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
        guard !event.isARepeat, event.keyCode == UInt16(kVK_ANSI_K) else {
            return false
        }

        let requiredFlags: NSEvent.ModifierFlags = [.control, .option, .command]
        let effectiveFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return effectiveFlags == requiredFlags
    }
}

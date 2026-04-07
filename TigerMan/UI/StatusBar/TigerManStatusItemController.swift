import AppKit

@MainActor
final class TigerManStatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var contextMenu = makeContextMenu()

    var primaryActionHandler: (() -> Void)?
    var preferencesActionHandler: (() -> Void)?
    var quitActionHandler: (() -> Void)?

    override init() {
        super.init()
        configure()
    }

    func screenFrame() -> CGRect? {
        guard let button = statusItem.button else {
            return nil
        }
        return LayoutCoordinator.screenFrame(for: button)
    }

    private func configure() {
        guard let button = statusItem.button else {
            return
        }

        let image = NSImage(named: "StatusIcon")
            ?? NSImage(systemSymbolName: "switch.2", accessibilityDescription: "TigerMan")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.action = #selector(handleButtonAction(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "TigerMan"
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let preferencesItem = NSMenuItem(
            title: "偏好设置",
            action: #selector(handlePreferencesAction),
            keyEquivalent: ""
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(handleQuitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        return menu
    }

    @objc
    private func handleButtonAction(_ sender: Any?) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
        default:
            primaryActionHandler?()
        }
    }

    @objc
    private func handlePreferencesAction(_ sender: Any?) {
        preferencesActionHandler?()
    }

    @objc
    private func handleQuitAction(_ sender: Any?) {
        if let quitActionHandler {
            quitActionHandler()
        } else {
            NSApp.terminate(nil)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if statusItem.menu === menu {
            statusItem.menu = nil
        }
    }
}

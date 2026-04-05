import AppKit

@MainActor
final class KBarStatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var primaryActionHandler: (() -> Void)?
    var secondaryActionHandler: (() -> Void)?

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
            ?? NSImage(systemSymbolName: "switch.2", accessibilityDescription: "kBar")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.action = #selector(handleButtonAction(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "kBar"
    }

    @objc
    private func handleButtonAction(_ sender: Any?) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            secondaryActionHandler?()
        default:
            primaryActionHandler?()
        }
    }
}

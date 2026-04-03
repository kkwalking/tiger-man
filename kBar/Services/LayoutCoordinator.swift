import AppKit

@MainActor
enum LayoutCoordinator {
    static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func menuBarFrame(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = max(frame.maxY - visibleFrame.maxY, 28)
        return CGRect(x: frame.minX, y: frame.maxY - menuBarHeight, width: frame.width, height: menuBarHeight)
    }

    static func screenFrame(for button: NSStatusBarButton) -> CGRect? {
        guard let window = button.window else {
            return nil
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    static func panelFrame(
        panelSize: CGSize,
        anchorFrame: CGRect,
        screen: NSScreen
    ) -> CGRect {
        let screenFrame = screen.visibleFrame
        let originX = min(
            max(anchorFrame.midX - (panelSize.width / 2), screenFrame.minX + 12),
            screenFrame.maxX - panelSize.width - 12
        )
        let originY = max(screenFrame.minY + 12, anchorFrame.minY - panelSize.height - 1)
        return CGRect(origin: CGPoint(x: originX, y: originY), size: panelSize)
    }
}

import AppKit

@MainActor
enum LayoutCoordinator {
    static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        let nonEmptyRect = rect.isEmpty ? CGRect(origin: rect.origin, size: CGSize(width: 1, height: 1)) : rect
        if let exactMatch = NSScreen.screens.first(where: { $0.frame.contains(nonEmptyRect.center) }) {
            return exactMatch
        }

        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(nonEmptyRect).area < rhs.frame.intersection(nonEmptyRect).area
        }
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

    static func trailingMenuBarPanelFrame(
        panelSize: CGSize,
        screen: NSScreen,
        trailingInset: CGFloat
    ) -> CGRect {
        let screenFrame = screen.visibleFrame
        let menuBarFrame = menuBarFrame(for: screen)
        let resolvedTrailingInset = max(12, trailingInset)
        let originX = min(
            max(screenFrame.maxX - panelSize.width - resolvedTrailingInset, screenFrame.minX + 12),
            screenFrame.maxX - panelSize.width - 12
        )
        let originY = max(screenFrame.minY + 12, menuBarFrame.minY - panelSize.height - 1)
        return CGRect(origin: CGPoint(x: originX, y: originY), size: panelSize)
    }
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

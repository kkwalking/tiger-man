import AppKit
import ApplicationServices

@MainActor
final class InteractionProxy {
    func perform(_ interaction: StatusItemInteraction, on item: StatusItemModel) -> Bool {
        switch interaction {
        case .leftClick:
            if performAXAction(.press, at: item.interactionPoint) {
                return true
            }
            return synthesizeMouseClick(at: item.interactionPoint, button: .left)
        case .rightClick:
            if performAXAction(.showMenu, at: item.interactionPoint) {
                return true
            }
            return synthesizeMouseClick(at: item.interactionPoint, button: .right)
        }
    }

    private func performAXAction(_ action: AXAction, at point: CGPoint) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var target: AXUIElement?
        let lookupResult = AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &target)
        guard lookupResult == .success, let target else {
            return false
        }

        let result = AXUIElementPerformAction(target, action.rawValue as CFString)
        return result == .success
    }

    private func synthesizeMouseClick(at point: CGPoint, button: CGMouseButton) -> Bool {
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
        else {
            return false
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

private enum AXAction: String {
    case press = "AXPress"
    case showMenu = "AXShowMenu"
}

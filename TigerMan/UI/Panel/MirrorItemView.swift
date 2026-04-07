import AppKit
import SwiftUI

struct MirrorItemView: View {
    let item: StatusItemModel
    let activateHandler: (StatusItemInteraction) -> Void

    @State
    private var isHovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(isHovered ? Color.white.opacity(0.14) : Color.clear)

            Image(nsImage: item.snapshot)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: iconDisplaySize.width, height: iconDisplaySize.height)

            MirrorItemInteractionBridge(
                leftAction: { activateHandler(.leftClick) },
                rightAction: { activateHandler(.rightClick) }
            )
        }
        .frame(width: cellWidth, height: 33)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovered in
            isHovered = hovered
        }
        .help(item.isVisibleInMenuBar ? item.displayName : "\(item.displayName)（隐藏）")
    }

    private var iconDisplaySize: CGSize {
        let originalSize = item.snapshot.size
        guard originalSize.width > 0, originalSize.height > 0 else {
            return CGSize(width: 22, height: 18)
        }

        let maxWidth: CGFloat = 36
        let maxHeight: CGFloat = 17
        let scale = min(maxWidth / originalSize.width, maxHeight / originalSize.height, 1)
        return CGSize(
            width: max(14, originalSize.width * scale),
            height: max(12, originalSize.height * scale)
        )
    }

    private var cellWidth: CGFloat {
        max(36, iconDisplaySize.width + 10)
    }
}

private struct MirrorItemInteractionBridge: NSViewRepresentable {
    let leftAction: () -> Void
    let rightAction: () -> Void

    func makeNSView(context: Context) -> MirrorItemInteractionView {
        let view = MirrorItemInteractionView()
        view.leftAction = leftAction
        view.rightAction = rightAction
        return view
    }

    func updateNSView(_ nsView: MirrorItemInteractionView, context: Context) {
        nsView.leftAction = leftAction
        nsView.rightAction = rightAction
    }
}

private final class MirrorItemInteractionView: NSView {
    var leftAction: (() -> Void)?
    var rightAction: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        leftAction?()
    }

    override func rightMouseDown(with event: NSEvent) {
        rightAction?()
    }
}

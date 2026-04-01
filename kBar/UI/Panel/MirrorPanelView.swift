import SwiftUI

struct MirrorPanelView: View {
    @ObservedObject var appState: AppState
    let activateHandler: (StatusItemModel, StatusItemInteraction) -> Void
    let refreshHandler: () -> Void
    let settingsHandler: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if appState.items.isEmpty {
                emptyState
            } else {
                ForEach(appState.items) { item in
                    MirrorItemView(item: item) { interaction in
                        activateHandler(item, interaction)
                    }
                }
            }

            Divider()
                .overlay(.white.opacity(0.08))
                .frame(height: 40)

            VStack(spacing: 10) {
                ActionBadge(symbol: "arrow.clockwise", action: refreshHandler)
                ActionBadge(symbol: "gearshape", action: settingsHandler)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        )
        .padding(6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("未发现可收起图标")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("确认已授予权限，或点击刷新重新扫描。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(width: 220, alignment: .leading)
    }
}

private struct ActionBadge: View {
    let symbol: String
    let action: () -> Void

    @State
    private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hovered ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

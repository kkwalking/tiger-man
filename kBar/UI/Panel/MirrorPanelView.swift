import SwiftUI

struct MirrorPanelView: View {
    @ObservedObject var appState: AppState
    let activateHandler: (StatusItemModel, StatusItemInteraction) -> Void
    let settingsHandler: () -> Void

    private var panelItems: [StatusItemModel] {
        appState.panelItems
    }

    var body: some View {
        HStack(spacing: 10) {
            if appState.isPanelRefreshing {
                loadingState
            } else if panelItems.isEmpty {
                emptyState
            } else {
                ForEach(panelItems) { item in
                    MirrorItemView(item: item) { interaction in
                        activateHandler(item, interaction)
                    }
                }
            }

            Divider()
                .overlay(.white.opacity(0.08))
                .frame(height: 22)

            ActionBadge(symbol: "gearshape", action: settingsHandler)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 5, y: 1)
        )
        .padding(1)
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("正在刷新...")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 220, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.showOnlyHiddenItems ? "未发现被隐藏图标" : "未发现可收起图标")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(emptyStateDescription)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(width: 220, alignment: .leading)
    }

    private var emptyStateDescription: String {
        if appState.showOnlyHiddenItems {
            return "可关闭该开关恢复展示可见图标，或到设置页重新扫描。"
        }

        return "确认已授予权限，或到设置页重新扫描。"
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovered ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

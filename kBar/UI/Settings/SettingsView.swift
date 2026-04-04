import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    let permissionCenter: PermissionCenter
    let refreshHandler: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.system(size: 20, weight: .bold))

            VStack(alignment: .leading, spacing: 10) {
                Toggle("自动刷新菜单栏映射", isOn: $appState.autoRefreshEnabled)
                Toggle("交互后保持面板打开", isOn: $appState.keepPanelOpenAfterInteraction)
            }

            Divider()

            permissionSection

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    LabeledContent("全局快捷键", value: GlobalHotKeyService.shortcutDisplayName)
                    Spacer()
                }
                Text("当菜单栏中的 kBar 被系统隐藏时，仍可用该快捷键打开或收起虚拟菜单栏。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack {
                    LabeledContent("已识别图标数量", value: "\(appState.items.count)")
                    Spacer()
                    Button("立即刷新", action: refreshHandler)
                }
                if let lastError = appState.lastError {
                    Text(lastError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

        }
        .padding(20)
        .frame(width: 620)
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                permissionBadge(title: "辅助功能", granted: appState.permissions.accessibilityGranted)
                Spacer()
                Button("打开设置") {
                    permissionCenter.openAccessibilitySettings()
                }
            }

            HStack {
                permissionBadge(title: "录屏权限", granted: appState.permissions.screenCaptureGranted)
                Spacer()
                Button("打开设置") {
                    permissionCenter.openScreenCaptureSettings()
                }
            }
        }
    }

    private func permissionBadge(title: String, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? .green : .orange)
                .frame(width: 10, height: 10)
            Text("\(title): \(granted ? "已授权" : "未授权")")
                .font(.system(size: 13, weight: .medium))
        }
    }
}

import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    let permissionCenter: PermissionCenter
    let refreshHandler: () -> Void

    @State
    private var showScanDiagnostics = false
    @State
    private var showHiddenDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("kBar 设置")
                .font(.system(size: 20, weight: .bold))

            VStack(alignment: .leading, spacing: 10) {
                Toggle("自动刷新菜单栏映射", isOn: $appState.autoRefreshEnabled)
                Toggle("交互后保持面板打开", isOn: $appState.keepPanelOpenAfterInteraction)
            }

            Divider()

            permissionSection

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("已识别图标数量", value: "\(appState.items.count)")
                if let lastError = appState.lastError {
                    Text(lastError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            if !appState.interactionDiagnostics.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("交互诊断")
                        .font(.system(size: 14, weight: .semibold))

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(appState.interactionDiagnostics.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(height: 120)
                    .padding(10)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            if !appState.scanDiagnostics.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("扫描诊断")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button(showScanDiagnostics ? "收起" : "展开") {
                            showScanDiagnostics.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    }

                    if showScanDiagnostics {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(appState.scanDiagnostics.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(height: 180)
                        .padding(10)
                        .background(Color.black.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Text("默认收起，排查识别问题时再展开。")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !appState.hiddenDiscoveryDiagnostics.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("隐藏图标诊断")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button(showHiddenDiagnostics ? "收起" : "展开") {
                            showHiddenDiagnostics.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    }

                    if showHiddenDiagnostics {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(appState.hiddenDiscoveryDiagnostics.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(height: 180)
                        .padding(10)
                        .background(Color.black.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Text("默认收起，排查隐藏图标发现问题时再展开。")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("立即刷新", action: refreshHandler)
                Button("重新请求辅助功能权限") {
                    _ = permissionCenter.requestAccessibilityAccess()
                }
                Button("重新请求录屏权限") {
                    _ = permissionCenter.requestScreenCaptureAccess()
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
                Button("打开设置") {
                    permissionCenter.openAccessibilitySettings()
                }
            }

            HStack {
                permissionBadge(title: "录屏权限", granted: appState.permissions.screenCaptureGranted)
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

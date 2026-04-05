import AppKit
import Carbon
import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    let permissionCenter: PermissionCenter
    let refreshHandler: () -> Void

    @StateObject
    private var hotKeyRecorder = GlobalHotKeyRecorderController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.system(size: 20, weight: .bold))

            VStack(alignment: .leading, spacing: 10) {
                Toggle("自动刷新菜单栏映射", isOn: $appState.autoRefreshEnabled)
                Toggle("交互后保持面板打开", isOn: $appState.keepPanelOpenAfterInteraction)
                Toggle("仅展示被隐藏图标", isOn: $appState.showOnlyHiddenItems)
            }

            Divider()

            permissionSection

            Divider()

            shortcutSection

            Divider()

            statusSection

        }
        .padding(20)
        .frame(width: 620)
        .onDisappear {
            stopHotKeyRecording()
        }
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

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("全局快捷键")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button(action: toggleHotKeyRecording) {
                    Text(hotKeyRecorder.isRecording ? "请按下快捷键" : appState.globalHotKeyShortcut.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .frame(minWidth: 140)
                }
                .buttonStyle(.bordered)

                Button("恢复默认") {
                    stopHotKeyRecording()
                    appState.globalHotKeyShortcut = .defaultValue
                }
                .buttonStyle(.bordered)
                .disabled(appState.globalHotKeyShortcut == .defaultValue && !hotKeyRecorder.isRecording)
            }

            if let errorMessage = hotKeyRecorder.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            Text(hotKeyRecorder.isRecording
                 ? "按下新的快捷键，按 Esc 取消。"
                 : "当菜单栏中的 kBar 被系统隐藏时，仍可用该快捷键打开或收起虚拟菜单栏。点击上方快捷键可重新录制，快捷键至少包含一个修饰键。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LabeledContent("已识别图标数量", value: "\(appState.items.count)")
                Spacer()
                Button("立即刷新", action: refreshHandler)
            }
            if appState.showOnlyHiddenItems {
                Text("当前虚拟菜单栏只展示被 macOS 隐藏的图标。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let lastError = appState.lastError {
                Text(lastError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
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

    private func toggleHotKeyRecording() {
        if hotKeyRecorder.isRecording {
            stopHotKeyRecording()
            return
        }

        hotKeyRecorder.startRecording(
            onShortcutRecorded: { shortcut in
                appState.globalHotKeyShortcut = shortcut
            },
            onRecordingChange: { isRecording in
                appState.isRecordingGlobalHotKey = isRecording
            }
        )
    }

    private func stopHotKeyRecording() {
        hotKeyRecorder.stopRecording { isRecording in
            appState.isRecordingGlobalHotKey = isRecording
        }
    }
}

@MainActor
private final class GlobalHotKeyRecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?

    private var localMonitor: Any?

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    func startRecording(
        onShortcutRecorded: @escaping (GlobalHotKeyShortcut) -> Void,
        onRecordingChange: @escaping (Bool) -> Void
    ) {
        guard !isRecording else {
            return
        }

        errorMessage = nil
        isRecording = true
        onRecordingChange(true)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else {
                return event
            }

            return self.handleRecordingEvent(
                event,
                onShortcutRecorded: onShortcutRecorded,
                onRecordingChange: onRecordingChange
            )
        }
    }

    func stopRecording(onRecordingChange: ((Bool) -> Void)? = nil) {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if isRecording {
            isRecording = false
            onRecordingChange?(false)
        }
    }

    private func handleRecordingEvent(
        _ event: NSEvent,
        onShortcutRecorded: @escaping (GlobalHotKeyShortcut) -> Void,
        onRecordingChange: @escaping (Bool) -> Void
    ) -> NSEvent? {
        let modifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(GlobalHotKeyShortcut.supportedModifierFlags)

        if event.keyCode == UInt16(kVK_Escape), modifierFlags.isEmpty {
            stopRecording(onRecordingChange: onRecordingChange)
            return nil
        }

        guard let shortcut = GlobalHotKeyShortcut.fromRecordingEvent(event) else {
            errorMessage = "快捷键至少包含一个修饰键。"
            NSSound.beep()
            return nil
        }

        errorMessage = nil
        onShortcutRecorded(shortcut)
        stopRecording(onRecordingChange: onRecordingChange)
        return nil
    }
}

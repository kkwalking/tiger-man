import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var items: [StatusItemModel] = []
    @Published var scanDiagnostics: [String] = []
    @Published var interactionDiagnostics: [String] = []
    @Published var hiddenDiscoveryDiagnostics: [String] = []
    @Published var globalHotKeyShortcut: GlobalHotKeyShortcut
    @Published var isRecordingGlobalHotKey = false
    @Published var isPanelRefreshing = false
    @Published var permissions = PermissionStatus()
    @Published var autoRefreshEnabled = true
    @Published var keepPanelOpenAfterInteraction = false
    @Published var showOnlyHiddenItems = false
    @Published var isPanelVisible = false
    @Published var lastRefreshDate: Date?
    @Published var lastRefreshReason = "idle"
    @Published var lastRefreshFrontmostBundleID: String?
    @Published var observedFrontmostBundleID: String?
    @Published var frontmostAppCacheDirty = false
    @Published var lastError: String?
    @Published var menuBarFrame = CGRect.zero

    init() {
        globalHotKeyShortcut = GlobalHotKeyShortcutStore.load()
    }

    var panelItems: [StatusItemModel] {
        guard showOnlyHiddenItems else {
            return items
        }

        return items.filter { !$0.isVisibleInMenuBar }
    }
}

struct PermissionStatus {
    var accessibilityGranted = false
    var screenCaptureGranted = false

    var isReady: Bool {
        accessibilityGranted && screenCaptureGranted
    }
}

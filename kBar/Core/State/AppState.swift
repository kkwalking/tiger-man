import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var items: [StatusItemModel] = []
    @Published var scanDiagnostics: [String] = []
    @Published var interactionDiagnostics: [String] = []
    @Published var permissions = PermissionStatus()
    @Published var autoRefreshEnabled = true
    @Published var keepPanelOpenAfterInteraction = false
    @Published var isPanelVisible = false
    @Published var lastRefreshDate: Date?
    @Published var lastRefreshReason = "idle"
    @Published var lastError: String?
    @Published var menuBarFrame = CGRect.zero
}

struct PermissionStatus {
    var accessibilityGranted = false
    var screenCaptureGranted = false

    var isReady: Bool {
        accessibilityGranted && screenCaptureGranted
    }
}

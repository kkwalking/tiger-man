import AppKit
import Combine
import Foundation

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let permissionCenter = PermissionCenter()
    private let screenCaptureService = ScreenCaptureService()
    private lazy var discoveryService = StatusItemDiscoveryService(screenCaptureService: screenCaptureService)
    private lazy var statusBarRegistry = StatusBarRegistry(discoveryService: discoveryService)
    private let interactionProxy = InteractionProxy()
    private lazy var statusItemController = KBarStatusItemController()
    private lazy var mirrorPanelController = MirrorPanelController(
        appState: appState,
        activateHandler: { [weak self] item, interaction in
            self?.handleInteraction(for: item, interaction: interaction)
        },
        settingsHandler: { [weak self] in
            self?.showSettings()
        }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        appState: appState,
        permissionCenter: permissionCenter,
        refreshHandler: { [weak self] in
            self?.refreshNow(reason: "settings")
        }
    )

    private var refreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var automaticRefreshSuppressedUntil: Date?
    private let automaticRefreshSuppressionDuration: TimeInterval = 5.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("Application launched")

        statusItemController.primaryActionHandler = { [weak self] in
            self?.toggleMirrorPanel()
        }
        statusItemController.secondaryActionHandler = { [weak self] in
            self?.showSettings()
        }

        bindState()
        observeSystemChanges()
        syncPermissions(promptIfNeeded: true)
        refreshNow(reason: "launch")
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func bindState() {
        appState.$autoRefreshEnabled
            .sink { [weak self] _ in
                self?.configureRefreshTimer()
            }
            .store(in: &cancellables)
    }

    private func observeSystemChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceChange),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        configureRefreshTimer()
    }

    private func configureRefreshTimer() {
        refreshTimer?.invalidate()
        guard appState.autoRefreshEnabled else {
            return
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow(reason: "timer")
            }
        }
        refreshTimer?.tolerance = 1.0
    }

    @objc
    private func handleScreenParametersChange() {
        refreshNow(reason: "screen-change")
    }

    @objc
    private func handleWorkspaceChange() {
        refreshNow(reason: "workspace-change")
    }

    private func toggleMirrorPanel() {
        syncPermissions(promptIfNeeded: false)
        if mirrorPanelController.isVisible {
            mirrorPanelController.close()
            appState.isPanelVisible = false
            return
        }

        refreshNow(reason: "panel-open")

        let anchorFrame: CGRect
        if let statusItemFrame = statusItemController.screenFrame() {
            anchorFrame = statusItemFrame
        } else if let screen = LayoutCoordinator.primaryScreen() {
            let menuBarFrame = LayoutCoordinator.menuBarFrame(for: screen)
            let clampedX = min(max(NSEvent.mouseLocation.x, screen.frame.minX + 8), screen.frame.maxX - 8)
            anchorFrame = CGRect(
                x: clampedX - 9,
                y: menuBarFrame.minY,
                width: 18,
                height: menuBarFrame.height
            )
            Logger.info("Fallback anchor frame used for mirror panel")
        } else {
            appState.lastError = "无法获取 kBar 菜单栏位置。"
            return
        }

        mirrorPanelController.show(relativeTo: anchorFrame)
        appState.isPanelVisible = true
    }

    private func showSettings(activateApp: Bool = true) {
        syncPermissions(promptIfNeeded: false)
        settingsWindowController.showWindow(nil)
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleInteraction(for item: StatusItemModel, interaction: StatusItemInteraction) {
        let keepPanelOpen = appState.keepPanelOpenAfterInteraction
        if !keepPanelOpen {
            mirrorPanelController.close()
            appState.isPanelVisible = false
        }

        let performForwarding = { [weak self] in
            guard let self else {
                return
            }

            let succeeded = self.interactionProxy.perform(interaction, on: item)
            let interactionResult = self.interactionProxy.latestInteractionResult()
            self.appState.interactionDiagnostics = self.interactionProxy.latestInteractionTrace()
            if !succeeded {
                self.appState.lastError = "未能触发 \(item.displayName) 的原始操作。"
            }
            DiagnosticsFileLogger.recordInteractionSnapshot(
                item: item,
                interaction: interaction,
                succeeded: succeeded,
                diagnostics: self.appState.interactionDiagnostics,
                lastError: self.appState.lastError
            )

            if interactionResult.shouldSuppressAutomaticRefresh {
                let until = Date().addingTimeInterval(self.automaticRefreshSuppressionDuration)
                self.automaticRefreshSuppressedUntil = until
                Logger.info(
                    "Suppress automatic refresh after interaction item=\(item.displayName) until=\(until)"
                )
            }

            if self.shouldDeferPostInteractionRefresh(for: interactionResult) {
                Logger.info("Skip immediate post-interaction refresh for item=\(item.displayName)")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.refreshNow(reason: "post-interaction")
                }
            }
        }

        if keepPanelOpen {
            performForwarding()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                performForwarding()
            }
        }
    }

    private func syncPermissions(promptIfNeeded: Bool) {
        appState.permissions = permissionCenter.currentStatus()

        guard promptIfNeeded else {
            return
        }

        if !appState.permissions.accessibilityGranted {
            _ = permissionCenter.requestAccessibilityAccess()
        }

        if !appState.permissions.screenCaptureGranted {
            _ = permissionCenter.requestScreenCaptureAccess()
        }

        appState.permissions = permissionCenter.currentStatus()
    }

    private func refreshNow(reason: String) {
        if shouldSkipAutomaticRefresh(reason: reason) {
            return
        }

        syncPermissions(promptIfNeeded: false)

        guard appState.permissions.isReady else {
            Logger.info("Skip refresh, permissions are not ready")
            appState.items = []
            appState.scanDiagnostics = ["权限未就绪，跳过扫描。"]
            appState.hiddenDiscoveryDiagnostics = ["权限未就绪，跳过隐藏图标探测。"]
            appState.lastError = "请先授权辅助功能和录屏权限。"
            mirrorPanelController.update(items: [])
            DiagnosticsFileLogger.recordScanSnapshot(
                reason: reason,
                permissions: appState.permissions,
                itemCount: 0,
                menuBarFrame: appState.menuBarFrame,
                kBarFrame: statusItemController.screenFrame(),
                diagnostics: appState.scanDiagnostics,
                lastError: appState.lastError
            )
            DiagnosticsFileLogger.recordHiddenDiscoverySnapshot(
                reason: reason,
                permissions: appState.permissions,
                diagnostics: appState.hiddenDiscoveryDiagnostics,
                lastError: appState.lastError
            )
            return
        }

        guard let screen = LayoutCoordinator.primaryScreen() else {
            appState.lastError = "未找到主屏幕。"
            appState.hiddenDiscoveryDiagnostics = ["未找到主屏幕，跳过隐藏图标探测。"]
            DiagnosticsFileLogger.recordScanSnapshot(
                reason: reason,
                permissions: appState.permissions,
                itemCount: 0,
                menuBarFrame: appState.menuBarFrame,
                kBarFrame: statusItemController.screenFrame(),
                diagnostics: ["未找到主屏幕。"],
                lastError: appState.lastError
            )
            DiagnosticsFileLogger.recordHiddenDiscoverySnapshot(
                reason: reason,
                permissions: appState.permissions,
                diagnostics: appState.hiddenDiscoveryDiagnostics,
                lastError: appState.lastError
            )
            return
        }

        let kBarFrame = statusItemController.screenFrame()
        let result = statusBarRegistry.refresh(on: screen, kBarFrame: kBarFrame)

        appState.items = result.items
        appState.scanDiagnostics = result.diagnostics
        appState.hiddenDiscoveryDiagnostics = result.hiddenDiagnostics
        appState.lastRefreshDate = Date()
        appState.lastError = nil
        appState.menuBarFrame = result.menuBarFrame
        appState.lastRefreshReason = reason

        mirrorPanelController.update(items: result.items)
        DiagnosticsFileLogger.recordScanSnapshot(
            reason: reason,
            permissions: appState.permissions,
            itemCount: result.items.count,
            menuBarFrame: result.menuBarFrame,
            kBarFrame: kBarFrame,
            diagnostics: result.diagnostics,
            lastError: appState.lastError
        )
        DiagnosticsFileLogger.recordHiddenDiscoverySnapshot(
            reason: reason,
            permissions: appState.permissions,
            diagnostics: result.hiddenDiagnostics,
            lastError: appState.lastError
        )
    }

    private func shouldDeferPostInteractionRefresh(for result: InteractionExecutionResult) -> Bool {
        result.shouldSuppressAutomaticRefresh
    }

    private func shouldSkipAutomaticRefresh(reason: String) -> Bool {
        guard let automaticRefreshSuppressedUntil else {
            return false
        }

        if Date() >= automaticRefreshSuppressedUntil {
            self.automaticRefreshSuppressedUntil = nil
            return false
        }

        guard automaticRefreshReasons.contains(reason) else {
            return false
        }

        Logger.info(
            "Skip refresh reason=\(reason) suppressedUntil=\(automaticRefreshSuppressedUntil)"
        )
        return true
    }

    private var automaticRefreshReasons: Set<String> {
        ["post-interaction", "timer", "screen-change", "workspace-change"]
    }
}

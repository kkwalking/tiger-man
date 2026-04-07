import AppKit
import Combine
import Foundation

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private enum MirrorPanelTrigger {
        case statusItem
        case hotKey
    }

    private let appState = AppState()
    private let permissionCenter = PermissionCenter()
    private let screenCaptureService = ScreenCaptureService()
    private lazy var discoveryService = StatusItemDiscoveryService(screenCaptureService: screenCaptureService)
    private lazy var statusBarRegistry = StatusBarRegistry(discoveryService: discoveryService)
    private let interactionProxy = InteractionProxy()
    private lazy var statusItemController = TigerManStatusItemController()
    private lazy var globalHotKeyService = GlobalHotKeyService(shortcut: appState.globalHotKeyShortcut) { [weak self] in
        self?.toggleMirrorPanel(trigger: .hotKey)
    }
    private lazy var mirrorPanelController = MirrorPanelController(
        appState: appState,
        activateHandler: { [weak self] item, interaction in
            self?.handleInteraction(for: item, interaction: interaction)
        },
        settingsHandler: { [weak self] in
            self?.showSettings()
        },
        dismissalExemptionFrameProvider: { [weak self] in
            self?.statusItemController.screenFrame()
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
    private var pendingFrontmostRefreshWorkItem: DispatchWorkItem?
    private var appWasFrontmostSinceLastExternalActivation = false
    private let automaticRefreshSuppressionDuration: TimeInterval = 5.0
    private let panelOpenRefreshDelay: TimeInterval = 0.05
    private let panelOpenRefreshStalenessThreshold: TimeInterval = 1.5
    private let frontmostRefreshDebounce: TimeInterval = 0.12
    private let launchSettlingRefreshDelay: TimeInterval = 0.35
    private let mirrorPanelFallbackTrailingInset: CGFloat = 12
    private var lastKnownStatusItemFrame: CGRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("Application launched")

        statusItemController.primaryActionHandler = { [weak self] in
            self?.toggleMirrorPanel(trigger: .statusItem)
        }
        statusItemController.secondaryActionHandler = { [weak self] in
            self?.showSettings()
        }

        bindState()
        observeSystemChanges()
        registerGlobalHotKey()
        _ = updateVisibleStatusItemFrame()
        appState.observedFrontmostBundleID = monitoredFrontmostApplicationBundleID()
        syncPermissions(promptIfNeeded: true)
        refreshNow(reason: "launch")
        scheduleLaunchSettlingRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        pendingFrontmostRefreshWorkItem?.cancel()
        globalHotKeyService.unregister()
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

        appState.$globalHotKeyShortcut
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.applyGlobalHotKeyShortcut(shortcut)
            }
            .store(in: &cancellables)

        appState.$isRecordingGlobalHotKey
            .sink { [weak self] isRecording in
                self?.globalHotKeyService.isEnabled = !isRecording
            }
            .store(in: &cancellables)

        appState.$showOnlyHiddenItems
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else {
                    return
                }

                self.mirrorPanelController.update(items: self.appState.panelItems)
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

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleFrontmostApplicationChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
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

    private func registerGlobalHotKey() {
        _ = applyGlobalHotKeyShortcut(appState.globalHotKeyShortcut)
    }

    @discardableResult
    private func applyGlobalHotKeyShortcut(_ shortcut: GlobalHotKeyShortcut) -> Bool {
        GlobalHotKeyShortcutStore.save(shortcut)
        let succeeded = globalHotKeyService.updateShortcut(shortcut)
        guard !succeeded else {
            return true
        }

        Logger.error("Global hot key registration failed shortcut=\(shortcut.displayName)")
        return false
    }

    private func scheduleLaunchSettlingRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + launchSettlingRefreshDelay) { [weak self] in
            self?.refreshNow(reason: "launch-settling")
        }
    }

    @objc
    private func handleScreenParametersChange() {
        refreshNow(reason: "screen-change")
    }

    @objc
    private func handleWorkspaceChange() {
        refreshNow(reason: "workspace-change")
    }

    @objc
    private func handleFrontmostApplicationChange(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        noteFrontmostApplicationDidChange(to: application.bundleIdentifier)
    }

    private func toggleMirrorPanel(trigger: MirrorPanelTrigger) {
        syncPermissions(promptIfNeeded: false)
        if mirrorPanelController.isVisible {
            mirrorPanelController.close()
            appState.isPanelVisible = false
            return
        }

        guard let placement = mirrorPanelPlacement(for: trigger) else {
            appState.lastError = "无法获取 TigerMan 菜单栏位置。"
            return
        }

        let shouldHideCachedContents = shouldHideCachedMirrorPanelContentsOnOpen
        appState.isPanelRefreshing = shouldHideCachedContents
        mirrorPanelController.show(using: placement)
        appState.isPanelVisible = true
        refreshAfterPresentingMirrorPanelIfNeeded(force: shouldHideCachedContents)
    }

    private func showSettings(activateApp: Bool = true) {
        syncPermissions(promptIfNeeded: false)
        settingsWindowController.showWindow(nil)
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleInteraction(for item: StatusItemModel, interaction: StatusItemInteraction) {
        mirrorPanelController.close()
        appState.isPanelVisible = false

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            performForwarding()
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

        if shouldSkipRefreshWhileSelfIsActive(reason: reason) {
            return
        }

        syncPermissions(promptIfNeeded: false)

        guard appState.permissions.isReady else {
            Logger.info("Skip refresh, permissions are not ready")
            appState.items = []
            appState.scanDiagnostics = ["权限未就绪，跳过扫描。"]
            appState.hiddenDiscoveryDiagnostics = ["权限未就绪，跳过隐藏图标探测。"]
            appState.lastError = "请先授权辅助功能和录屏权限。"
            appState.isPanelRefreshing = false
            mirrorPanelController.update(items: [])
            DiagnosticsFileLogger.recordScanSnapshot(
                reason: reason,
                permissions: appState.permissions,
                itemCount: 0,
                menuBarFrame: appState.menuBarFrame,
                tigerManFrame: statusItemController.screenFrame(),
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
            appState.isPanelRefreshing = false
            DiagnosticsFileLogger.recordScanSnapshot(
                reason: reason,
                permissions: appState.permissions,
                itemCount: 0,
                menuBarFrame: appState.menuBarFrame,
                tigerManFrame: statusItemController.screenFrame(),
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

        let tigerManFrame = updateVisibleStatusItemFrame()
        let result = statusBarRegistry.refresh(on: screen, tigerManFrame: tigerManFrame)

        appState.items = result.items
        appState.scanDiagnostics = result.diagnostics
        appState.hiddenDiscoveryDiagnostics = result.hiddenDiagnostics
        appState.lastRefreshDate = Date()
        appState.lastError = nil
        appState.isPanelRefreshing = false
        appState.menuBarFrame = result.menuBarFrame
        appState.lastRefreshReason = reason
        appState.lastRefreshFrontmostBundleID = monitoredFrontmostApplicationBundleID()
        appState.observedFrontmostBundleID = appState.lastRefreshFrontmostBundleID
        appState.frontmostAppCacheDirty = false

        mirrorPanelController.update(items: result.items)
        DiagnosticsFileLogger.recordScanSnapshot(
            reason: reason,
            permissions: appState.permissions,
            itemCount: result.items.count,
            menuBarFrame: result.menuBarFrame,
            tigerManFrame: tigerManFrame,
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

    private func shouldSkipRefreshWhileSelfIsActive(reason: String) -> Bool {
        guard selfActiveRefreshSkipReasons.contains(reason) else {
            return false
        }

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return false
        }

        Logger.info("Skip refresh reason=\(reason) while TigerMan is active")
        return true
    }

    private func noteFrontmostApplicationDidChange(to bundleID: String?) {
        let appBundleID = Bundle.main.bundleIdentifier
        if bundleID == appBundleID {
            appWasFrontmostSinceLastExternalActivation = true
            Logger.info("TigerMan became active; defer external menu bar refresh until next external activation")
            return
        }

        let returningFromSelfActivation = appWasFrontmostSinceLastExternalActivation
        appWasFrontmostSinceLastExternalActivation = false
        let observedBundleChanged = appState.observedFrontmostBundleID != bundleID

        guard observedBundleChanged || returningFromSelfActivation else {
            return
        }

        appState.observedFrontmostBundleID = bundleID
        let needsRefresh = returningFromSelfActivation || appState.lastRefreshFrontmostBundleID != bundleID
        appState.frontmostAppCacheDirty = needsRefresh

        guard needsRefresh else {
            return
        }

        if appState.isPanelVisible {
            appState.isPanelRefreshing = true
        }

        scheduleFrontmostApplicationRefresh()
    }

    private func scheduleFrontmostApplicationRefresh() {
        pendingFrontmostRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshNow(reason: "frontmost-app-change")
        }
        pendingFrontmostRefreshWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + frontmostRefreshDebounce, execute: workItem)
    }

    private func mirrorPanelPlacement(for trigger: MirrorPanelTrigger) -> MirrorPanelController.PanelPlacement? {
        if let statusItemFrame = updateVisibleStatusItemFrame() {
            if trigger == .hotKey {
                Logger.info("Mirror panel hot key anchored to visible TigerMan status item")
            }
            return .anchorFrame(statusItemFrame)
        }

        return fallbackMirrorPanelPlacement(trigger: trigger)
    }

    private func fallbackMirrorPanelPlacement(trigger: MirrorPanelTrigger) -> MirrorPanelController.PanelPlacement? {
        guard let screen = fallbackMirrorPanelScreen() else {
            return nil
        }

        Logger.info(
            "Mirror panel fallback placement used trigger=\(String(describing: trigger)) screen=\(screen.localizedName)"
        )
        return .trailingMenuBar(screen: screen, trailingInset: mirrorPanelFallbackTrailingInset)
    }

    @discardableResult
    private func updateVisibleStatusItemFrame() -> CGRect? {
        guard let statusItemFrame = statusItemController.screenFrame() else {
            return nil
        }

        lastKnownStatusItemFrame = statusItemFrame
        return statusItemFrame
    }

    private func fallbackMirrorPanelScreen() -> NSScreen? {
        if let cachedStatusItemFrame = lastKnownStatusItemFrame,
           let cachedStatusItemScreen = LayoutCoordinator.screen(containing: cachedStatusItemFrame) {
            return cachedStatusItemScreen
        }

        if !appState.menuBarFrame.isEmpty,
           let lastRefreshScreen = LayoutCoordinator.screen(containing: appState.menuBarFrame) {
            return lastRefreshScreen
        }

        return LayoutCoordinator.primaryScreen()
    }

    private func refreshAfterPresentingMirrorPanelIfNeeded(force: Bool = false) {
        guard force || shouldRefreshMirrorPanelContentsOnOpen else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + panelOpenRefreshDelay) { [weak self] in
            guard let self, self.mirrorPanelController.isVisible else {
                return
            }
            self.refreshNow(reason: "panel-open")
        }
    }

    private var shouldRefreshMirrorPanelContentsOnOpen: Bool {
        if appState.frontmostAppCacheDirty {
            return true
        }

        if launchBootstrapRefreshReasons.contains(appState.lastRefreshReason) {
            return true
        }

        guard let lastRefreshDate = appState.lastRefreshDate else {
            return true
        }

        return Date().timeIntervalSince(lastRefreshDate) >= panelOpenRefreshStalenessThreshold
    }

    private var automaticRefreshReasons: Set<String> {
        ["post-interaction", "timer", "screen-change", "workspace-change"]
    }

    private var launchBootstrapRefreshReasons: Set<String> {
        ["launch", "launch-settling"]
    }

    private var selfActiveRefreshSkipReasons: Set<String> {
        automaticRefreshReasons.union(["panel-open", "settings", "frontmost-app-change"])
    }

    private var shouldHideCachedMirrorPanelContentsOnOpen: Bool {
        appState.frontmostAppCacheDirty || launchBootstrapRefreshReasons.contains(appState.lastRefreshReason)
    }

    private func monitoredFrontmostApplicationBundleID() -> String? {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if bundleID == Bundle.main.bundleIdentifier {
            return appState.observedFrontmostBundleID
        }
        return bundleID
    }
}

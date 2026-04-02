# kBar 可执行开发方案（V2，更新于 2026-04-02）

## 1. 文档目标

基于 [`spec.md`](spec.md) 的最新口径，记录当前已落地的技术路线、核心实现方式和剩余未完成项。  
本版只聚焦“虚拟菜单栏展示 + 原始交互转发”，不再包含遮挡原始菜单栏能力。

## 2. 需求基线（与 sepc 对齐）

1. `kBar` 常驻菜单栏，作为虚拟菜单栏入口。
2. 点击 `kBar` 后弹出悬浮面板，展示识别到的第三方菜单栏图标。
3. 面板图标支持左键 / 右键，并尽量还原原始菜单栏交互体验。
4. 原始菜单栏保持可见且可用，不做遮挡、隐藏、宽度改写。
5. 当前阶段不解决“被 macOS 彻底隐藏、截图中不可见的图标”发现问题。

## 3. 技术路线结论

### 3.1 总结

采用“左侧扫描 + 镜像展示 + 事件转发”路线：

1. 以 `kBar` 为锚点，扫描其左侧菜单栏区域。
2. 用 AX + 截图双通道建立统一镜像模型。
3. 在 `NSPanel` 中渲染虚拟菜单栏。
4. 用户点击镜像图标时，把交互转发回真实菜单栏目标。

### 3.2 当前交互策略

1. 对带稳定语义信息的项，允许解析 AX 目标并尝试 `AXPress` / `AXShowMenu`。
2. 对纯截图项，直接使用发现阶段确定的交互点做 `CGEvent` 点击。
3. 纯截图项不再在点击时重新解析临时 AX 目标，避免误跳到相邻图标。

### 3.3 明确不做

1. 不调用私有 API 去修改其他 App 的 `NSStatusItem`。
2. 不实现“遮挡原始菜单栏”。
3. 不以 App Store 审核通过为第一阶段目标。

## 4. 工程模块与职责

### 4.1 App 与状态

- [`kBar/kBarApp.swift`](kBar/kBarApp.swift)
- [`kBar/App/AppCoordinator.swift`](kBar/App/AppCoordinator.swift)
- [`kBar/Core/State/AppState.swift`](kBar/Core/State/AppState.swift)

职责：应用生命周期、全局状态、刷新调度、面板开关、诊断落盘调度。  
当前状态：已落地，左键弹面板、手动刷新、交互后刷新都已稳定。

### 4.2 菜单栏入口与面板

- [`kBar/UI/StatusBar/KBarStatusItemController.swift`](kBar/UI/StatusBar/KBarStatusItemController.swift)
- [`kBar/UI/Panel/MirrorPanelController.swift`](kBar/UI/Panel/MirrorPanelController.swift)
- [`kBar/UI/Panel/MirrorPanelView.swift`](kBar/UI/Panel/MirrorPanelView.swift)
- [`kBar/UI/Panel/MirrorItemView.swift`](kBar/UI/Panel/MirrorItemView.swift)

职责：`kBar` 入口、虚拟菜单栏容器、镜像图标渲染与交互。  
当前状态：已实现纯图标展示、外部点击关闭、跨 Space 使用。

### 4.3 发现、截图、映射

- [`kBar/Services/StatusItemDiscoveryService.swift`](kBar/Services/StatusItemDiscoveryService.swift)
- [`kBar/Services/ScreenCaptureService.swift`](kBar/Services/ScreenCaptureService.swift)
- [`kBar/Services/StatusBarRegistry.swift`](kBar/Services/StatusBarRegistry.swift)
- [`kBar/Services/LayoutCoordinator.swift`](kBar/Services/LayoutCoordinator.swift)

职责：候选图标发现、图像切分、AX 融合、镜像模型更新。  
当前状态：主链路可用，当前瓶颈只剩“系统彻底隐藏图标”的发现能力。

### 4.4 权限与交互

- [`kBar/Services/PermissionCenter.swift`](kBar/Services/PermissionCenter.swift)
- [`kBar/Services/InteractionProxy.swift`](kBar/Services/InteractionProxy.swift)

职责：权限检查与重试、AX/CGEvent 转发链路。  
当前状态：已可用，纯截图项与语义项的点击策略已经拆分。

### 4.5 设置与诊断

- [`kBar/UI/Settings/SettingsView.swift`](kBar/UI/Settings/SettingsView.swift)
- [`kBar/UI/Settings/SettingsWindowController.swift`](kBar/UI/Settings/SettingsWindowController.swift)
- [`kBar/Core/Utils/DiagnosticsFileLogger.swift`](kBar/Core/Utils/DiagnosticsFileLogger.swift)
- [`kBar/Core/Utils/Logger.swift`](kBar/Core/Utils/Logger.swift)

职责：权限状态、手动刷新、诊断展示、文件日志持久化。  
当前状态：已支持设置页诊断 + 项目根目录落盘日志双通道排查。

## 5. 核心流程（当前实现）

### 5.1 启动流程

1. 启动 `kBar`，注册菜单栏入口。
2. 检查辅助功能与录屏权限。
3. 权限齐全后进行扫描并构建镜像模型。
4. 左键点击 `kBar` 直接弹出虚拟菜单栏，并在需要时同步刷新。

### 5.2 扫描与建模流程

1. 以 `kBar` 左侧区域为扫描窗口。
2. AX 通道先取候选：
   - `SystemUIServer`
   - system-wide probe
3. 截图通道切分候选：
   - 局部对比度
   - 边缘强度
   - 宽块切分
4. 对候选做分层过滤：
   - 菜单栏 band 过滤
   - `kBar` 自身区域过滤
   - 尺寸过滤
   - 菜单栏语义树过滤
   - 前台菜单区过滤
   - 文本型 screenshot 过滤
   - 系统右侧保留区过滤
5. 生成统一镜像模型，供面板展示与交互使用。

### 5.3 面板交互流程

1. 用户点击 `kBar` 打开面板。
2. 面板渲染当前镜像图标列表。
3. 点击镜像图标后：
   - 语义项先尝试 AX 动作
   - 纯截图项按发现阶段交互点发 `CGEvent`
4. 交互完成后写入交互诊断，并触发必要刷新。

## 6. 图标发现与过滤策略（当前版本）

### 6.1 已落地策略

1. 扫描区域锚定在 `kBar` 左侧，而不是右侧固定区。
2. 对前台应用菜单项做 AX frame 过滤。
3. 仅保留真正属于菜单栏语义树的 AX 候选。
4. 过滤文本型 screenshot 候选，减少把前台应用菜单文字误收为图标。
5. VS Code 等前台应用的顶部状态控件不会再参与交互匹配。

### 6.2 当前效果与限制

1. 当前真实菜单栏可见区域中的第三方图标，识别与点击链路已经基本闭环。
2. 部分候选仍然只能以 screenshot 形式存在，缺少稳定的 owner / bundle 语义。
3. 被 macOS 完全隐藏、截图中不可见的图标仍无法发现。

## 7. 交互转发策略（当前版本）

### 7.1 已落地

1. 左键 / 右键均可转发。
2. 事件投递坐标已按 macOS 事件坐标系做转换。
3. 纯 screenshot 项不再在交互瞬间重新解析相邻 AX 目标。
4. 交互链路有完整诊断：
   - 设置页“交互诊断”
   - `kbar-interaction-latest.log`

### 7.2 当前限制

1. 某些完全没有可用 AX 语义的应用，仍主要依赖 screenshot 点击点。
2. 该方案可以满足当前 MVP，但不保证覆盖所有异常实现。

## 8. 诊断与排障策略

1. 设置页保留扫描诊断和交互诊断。
2. 项目根目录自动写入：
   - `kbar-events.log`
   - `kbar-scan-latest.log`
   - `kbar-interaction-latest.log`
3. 诊断已包含候选分层统计，例如：
   - `scanRegionCandidates`
   - `menuScopedCandidates`
   - `frontmostFilteredCandidates`
   - `interactionCandidateDetails`

## 9. 当前开发进度（截至 2026-04-02）

### 9.1 已完成

1. 项目已切换为标准 Xcode macOS 工程并可构建运行。
2. 权限申请链路（辅助功能、录屏）已打通并可重试。
3. 虚拟菜单栏面板、图标点击与右键转发已打通。
4. 左侧扫描、前台应用过滤、VS Code 场景修正已完成。
5. 设置页诊断与落盘日志体系已完成。
6. “遮挡原始菜单栏”相关运行逻辑与文件已移除。

### 9.2 当前未完成

1. 发现被系统彻底隐藏的菜单栏图标。

### 9.3 暂缓

1. 拖拽排序
2. 分组与搜索
3. 快捷键唤起
4. 高级主题能力

## 10. MVP 验收状态（当前）

1. 启动后不影响原始菜单栏显示与行为：已满足。
2. 点击 `kBar` 可稳定弹出虚拟菜单栏：已满足。
3. 多个常见第三方菜单栏 App 可通过面板稳定触发交互：已基本满足。
4. 右键行为在支持的 App 上可用：已满足。
5. 权限缺失时提示明确、可重试：已满足。
6. 剩余未满足项：系统彻底隐藏图标的发现能力。

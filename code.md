# TigerMan 可执行开发方案（V2，更新于 2026-04-07）

## 1. 文档目标

基于 [`spec.md`](spec.md) 的最新口径，记录当前已落地的技术路线、核心实现方式和剩余未完成项。  
本版只聚焦“虚拟菜单栏展示 + 原始交互转发”，不再包含遮挡原始菜单栏能力。

## 2. 需求基线（与 spec 对齐）

1. `TigerMan` 常驻菜单栏，作为虚拟菜单栏入口。
2. 点击 `TigerMan` 后弹出悬浮面板，展示识别到的第三方菜单栏图标。
3. 面板图标支持左键 / 右键，并尽量还原原始菜单栏交互体验。
4. 原始菜单栏保持可见且可用，不做遮挡、隐藏、宽度改写。
5. 当前阶段重点解决“被 macOS 彻底隐藏、截图中不可见的图标”发现问题。
6. 在隐藏图标能力开发前，先补齐可开关的可观测性日志能力；默认关闭，需要排查时再显式开启。
7. 需要补充“菜单栏入口失效时的备用入口”；当前已选定为全局快捷键唤起，而不是尝试控制 `NSStatusItem` 排序。
8. 当前阶段不以上架 Mac App Store 为目标，但需要能生成一个可供其他 Mac 手动安装测试的 `DMG`。

## 3. 技术路线结论

### 3.1 总结

采用“左侧扫描 + 镜像展示 + 事件转发”路线：

1. 以 `TigerMan` 为锚点，将可见扫描窗口固定在“屏幕中线到 `TigerMan` 左侧”。
2. 用 AX + 截图双通道建立统一镜像模型。
3. 在 `NSPanel` 中渲染虚拟菜单栏。
4. 用户点击镜像图标时，把交互转发回真实菜单栏目标。
5. 当前已补上“隐藏图标探测 + 专用诊断日志”支线能力，并进入兼容性扩展阶段。

### 3.2 入口兜底策略（已实现）

1. 不尝试依赖公开 API 把 `TigerMan` 固定到系统菜单栏最右侧，因为这条路线不可靠。
2. 已增加全局快捷键兜底入口，默认是 `⌃⌥⌘K`，并允许用户在设置页通过键盘录制修改。
3. 当用户直接点击 `TigerMan` 时，面板仍优先锚定到状态栏图标位置。
4. 当用户通过快捷键唤起时，若 `TigerMan` 仍可见，则面板与左键点击保持一致，继续锚定真实 `TigerMan` 图标。
5. 当 `TigerMan` 已被系统隐藏、拿不到稳定 frame 时，面板会回退到目标屏幕右上角下方的固定位置，而不是再跟随鼠标 `x` 漂移。

### 3.3 当前交互策略

1. 对带稳定语义信息的项，允许解析 AX 目标并尝试 `AXPress` / `AXShowMenu`。
2. 对纯截图项，直接使用发现阶段确定的交互点做 `CGEvent` 点击。
3. 纯截图项不再在点击时重新解析临时 AX 目标，避免误跳到相邻图标。
4. 对隐藏图标，优先使用发现阶段保存的 `directAXElement`；若直接 AX 不可用，再退回动态 AX 解析与 synthetic click。
5. 隐藏图标交互失败时会记录 AX 失败码、目标节点摘要，并在命中鼠标回退后暂时压住自动刷新，避免菜单被后续刷新打断。

### 3.4 前台应用切换后的缓存策略（已实现）

1. 当前会监听 `NSWorkspace.didActivateApplicationNotification`，感知前台应用变化。
2. `AppState` 会记录“上次刷新对应的前台 bundle id”和“当前观察到的前台 bundle id”。
3. 当前台应用已变化且缓存失效时，面板不会先展示旧 `items`，而是优先刷新最新结果。
4. 若刷新尚未完成，面板会短暂展示“正在刷新...”加载态，而不是先闪出上一前台应用的虚拟菜单栏。

### 3.5 `TigerMan` 自激活时的缓存保护（已实现）

1. `TigerMan` 是 `LSUIElement` 应用；打开设置页或录制快捷键时，它自己会临时成为前台应用。
2. 在这段时间里，系统菜单栏视觉上仍可能保留外部 App 的文本菜单，因此不能把“前台 bundle id 命中当前应用”直接当成有效扫描上下文。
3. 当前会跳过 `TigerMan` 自己活跃期间的自动刷新，避免把外部 App 的文本菜单误收进虚拟菜单栏缓存。
4. 当用户从设置页回到外部 App 时，会额外把缓存标记为 dirty 并补一次刷新，保证新快捷键首次唤起时拿到的是正确的菜单栏镜像。

### 3.6 明确不做

1. 不调用私有 API 去修改其他 App 的 `NSStatusItem`。
2. 不实现“遮挡原始菜单栏”。
3. 不以 App Store 审核通过为第一阶段目标。

### 3.7 本地测试分发策略（已实现）

1. 当前采用“`Release` 构建 + 本地 `DMG` 打包”路线，目标是支持无开发者账号场景下的跨机器测试。
2. 打包脚本位于 [`scripts/package-dmg.sh`](scripts/package-dmg.sh)，输出到 `dist/`，文件名格式为 `TigerMan-<version>-unsigned.dmg`。
3. `DMG` 内容固定为 `TigerMan.app + /Applications` 快捷方式，遵循 macOS 常见的“拖到 Applications”安装方式。
4. 当前产物未做 `Developer ID` 签名和 notarization；目标机器首次打开时，需要用户在“系统设置 > 隐私与安全性”里手动点“仍要打开”。

## 4. 工程模块与职责

### 4.1 App 与状态

- [`TigerMan/TigerManApp.swift`](TigerMan/TigerManApp.swift)
- [`TigerMan/App/AppCoordinator.swift`](TigerMan/App/AppCoordinator.swift)
- [`TigerMan/Core/State/AppState.swift`](TigerMan/Core/State/AppState.swift)

职责：应用生命周期、全局状态、刷新调度、面板开关、可选诊断落盘调度。  
当前状态：已落地，左键点击 `TigerMan` 已支持面板开关；面板打开已改为优先显示、再按需补刷新；当前已补齐前台应用切换时的 dirty cache 处理，避免先闪出旧菜单；`TigerMan` 自己变成前台应用时会跳过污染性刷新，并在回到外部 App 后补刷新；隐藏图标命中回退交互时，会临时抑制自动刷新。

### 4.2 菜单栏入口与面板

- [`TigerMan/UI/StatusBar/TigerManStatusItemController.swift`](TigerMan/UI/StatusBar/TigerManStatusItemController.swift)
- [`TigerMan/UI/Panel/MirrorPanelController.swift`](TigerMan/UI/Panel/MirrorPanelController.swift)
- [`TigerMan/UI/Panel/MirrorPanelView.swift`](TigerMan/UI/Panel/MirrorPanelView.swift)
- [`TigerMan/UI/Panel/MirrorItemView.swift`](TigerMan/UI/Panel/MirrorItemView.swift)

职责：`TigerMan` 入口、虚拟菜单栏容器、镜像图标渲染与交互。  
当前状态：已实现纯图标展示、外部点击关闭、跨 Space 使用；并已修复“面板打开时再次点击 `TigerMan` 会被外部点击监听抢先关闭后又重新打开”的事件竞争问题；当前入口已扩展为“菜单栏点击 + 全局快捷键”双通道；状态栏图标已改为优先读取 `Assets.xcassets/StatusIcon.imageset`；应用图标已补齐 `Assets.xcassets/AppIcon.appiconset`，系统权限列表会显示自定义 App Icon；快捷键唤起时会优先贴真实 `TigerMan`，否则固定回退到目标屏幕右上角；当前台应用切换导致缓存失效时，面板会改为展示“正在刷新...”加载态而不是旧结果。

### 4.3 发现、截图、映射

- [`TigerMan/Services/StatusItemDiscoveryService.swift`](TigerMan/Services/StatusItemDiscoveryService.swift)
- [`TigerMan/Services/ScreenCaptureService.swift`](TigerMan/Services/ScreenCaptureService.swift)
- [`TigerMan/Services/StatusBarRegistry.swift`](TigerMan/Services/StatusBarRegistry.swift)
- [`TigerMan/Services/LayoutCoordinator.swift`](TigerMan/Services/LayoutCoordinator.swift)

职责：候选图标发现、图像切分、AX 融合、镜像模型更新。  
当前状态：主链路可用；隐藏图标发现已接入 `AXExtrasMenuBar` / `runningAppExtras` 探测，并可构建隐藏项镜像模型与专用诊断输出。当前可见扫描窗口固定为“屏幕中线到 `TigerMan` 左侧”；前台菜单过滤已改为只读取前台 App 的主菜单 `AXMenuBar`，不再把右侧 `AXExtrasMenuBar` 误当成文本菜单区。

### 4.4 权限与交互

- [`TigerMan/Services/PermissionCenter.swift`](TigerMan/Services/PermissionCenter.swift)
- [`TigerMan/Services/InteractionProxy.swift`](TigerMan/Services/InteractionProxy.swift)

职责：权限检查与重试、AX/CGEvent 转发链路。  
当前状态：已可用，纯截图项与语义项的点击策略已经拆分；隐藏项支持更长 AX timeout、多次重试与多级 synthetic tap 回退。

### 4.5 设置与诊断

- [`TigerMan/UI/Settings/SettingsView.swift`](TigerMan/UI/Settings/SettingsView.swift)
- [`TigerMan/UI/Settings/SettingsWindowController.swift`](TigerMan/UI/Settings/SettingsWindowController.swift)
- [`TigerMan/Core/Utils/DiagnosticsFileLogger.swift`](TigerMan/Core/Utils/DiagnosticsFileLogger.swift)
- [`TigerMan/Core/Utils/Logger.swift`](TigerMan/Core/Utils/Logger.swift)

职责：权限状态、手动刷新、文件日志持久化与诊断开关解析。  
当前状态：设置页已精简为权限状态、手动刷新、全局快捷键录制与“仅展示被隐藏图标”开关；“交互后保持面板打开”已移除，图标交互统一按“先收起面板，再转发原始操作”执行。文件诊断落盘默认关闭，需要时通过代码常量开启。设置窗口当前显式关闭了 `NSHostingView` 的自动 sizing，避免 SwiftUI 在窗口布局时反复改尺寸导致崩溃。

### 4.6 打包与分发

- [`scripts/package-dmg.sh`](scripts/package-dmg.sh)

职责：执行 `Release` 构建、组装 `DMG` 根目录、生成无开发者账号场景下的测试版 `DMG`。  
当前状态：已可用；脚本会在 `dist/` 生成 `TigerMan-<version>-unsigned.dmg`，供其他 Mac 手动拖入 `Applications` 安装测试。

## 5. 核心流程（当前实现）

### 5.1 启动流程

1. 启动 `TigerMan`，注册菜单栏入口。
2. 注册持久化保存的全局快捷键，默认值为 `⌃⌥⌘K`，作为备用唤起入口。
3. 监听前台应用激活变化，维护当前前台应用缓存状态。
4. 检查辅助功能与录屏权限。
5. 权限齐全后进行扫描并构建镜像模型。
6. 左键点击 `TigerMan` 以开关方式控制虚拟菜单栏：未显示时优先立即打开，并仅在数据过旧或缓存失效时补一次刷新；已显示时直接收起。

### 5.2 扫描与建模流程

1. 以“屏幕中线到 `TigerMan` 左侧”作为扫描窗口。
2. AX 通道先取候选：
   - `SystemUIServer`
   - system-wide probe
3. 截图通道切分候选：
   - 局部对比度
   - 边缘强度
   - 宽块切分
4. 对候选做分层过滤：
   - 菜单栏 band 过滤
   - `TigerMan` 自身区域过滤
   - 尺寸过滤
   - 菜单栏语义树过滤
   - 前台菜单区过滤（仅基于前台 App 主菜单 `AXMenuBar`，不把 `AXExtrasMenuBar` 当成前台文本菜单）
   - 文本型 screenshot 过滤
   - 系统右侧保留区过滤
5. 生成统一镜像模型，供面板展示与交互使用。
6. 隐藏图标研究阶段额外执行宿主进程 `AXExtrasMenuBar` 探测，记录可见候选匹配、隐藏候选判定和失败原因。
7. 隐藏项会以 `StatusItemModel` 进入面板模型，并保留 `isVisibleInMenuBar=false` 与 `directAXElement`。
8. 隐藏项快照优先使用宿主 App 图标，必要时回退到菜单栏裁图或占位图。

### 5.3 面板交互流程

1. 用户点击 `TigerMan` 或按下当前配置的全局快捷键打开面板；若面板已显示，则再次触发相同入口可直接收起。
2. 若当前前台应用已变化且缓存失效，面板不会先渲染旧结果，而是先进入“正在刷新...”加载态。
3. 刷新完成后，面板渲染当前镜像图标列表。
4. 点击镜像图标后，面板会先关闭，再进入交互转发：
   - 语义项先尝试 AX 动作
   - 纯截图项按发现阶段交互点发 `CGEvent`
   - 隐藏项优先走 `directAXElement`，失败后再进入动态解析 / 事件回退
5. 如果已开启诊断，交互完成后会写入交互诊断；如果隐藏项命中了鼠标回退，会暂时跳过自动刷新，避免菜单自动关闭。
6. 面板显示期间，命中 `TigerMan` 状态栏按钮区域的左键点击不会再被当成“外部点击关闭”，而是交由入口按钮自身的 toggle 逻辑处理。
7. 快捷键唤起时若 `TigerMan` 已被系统隐藏，面板会固定回退到目标屏幕右上角下方，而不是依赖鼠标位置或失效的状态栏图标位置。
8. 若用户在设置页开启“仅展示被隐藏图标”，面板展示层会直接过滤掉 `isVisibleInMenuBar == true` 的项；底层扫描与隐藏图标探测链路不受影响。

## 6. 图标发现与过滤策略（当前版本）

### 6.1 已落地策略

1. 扫描区域已固定为“屏幕中线到 `TigerMan` 左侧”，不再根据前台文本菜单长度二次收窄左边界。
2. 对前台应用菜单项做仅主菜单 `AXMenuBar` 的 AX frame 过滤，不把前台 App 的右侧状态图标区当成文本菜单。
3. 仅保留真正属于菜单栏语义树的 AX 候选。
4. 过滤文本型 screenshot 候选，减少把前台应用菜单文字误收为图标。
5. VS Code 等前台应用的顶部状态控件不会再参与交互匹配。

### 6.2 当前效果与限制

1. 当前真实菜单栏可见区域中的第三方图标，识别与点击链路已经基本闭环。
2. 部分候选仍然只能以 screenshot 形式存在，缺少稳定的 owner / bundle 语义。
3. 被 macOS 完全隐藏、截图中不可见的图标已经可以通过宿主进程 `runningAppExtras` 路径被发现，并已在 `Bob`、`OrbStack` 上验证成功。
4. 当前机器上 `SystemUIServer` 仍拿不到根节点，因此隐藏图标发现暂时主要依赖宿主进程级探测。
5. 兼容性仍未彻底完成；并不是所有隐藏图标都保证能直接通过 AX 动作触发。

## 7. 交互转发策略（当前版本）

### 7.1 已落地

1. 左键 / 右键均可转发。
2. 事件投递坐标已按 macOS 事件坐标系做转换。
3. 纯 screenshot 项不再在交互瞬间重新解析相邻 AX 目标。
4. 交互链路有完整文件诊断能力；将 `DiagnosticsConfiguration.isEnabled` 改为 `true` 并重新构建后，会写入 `tigerman-interaction-latest.log`。
5. 隐藏项已支持：
   - `directAXElement`
   - AX failure code 记录
   - 更长的 AX messaging timeout 与重试
   - `session / annotated / hid` 多级 synthetic tap 回退
   - 自动刷新抑制，避免菜单短暂弹出后被关闭

### 7.2 当前限制

1. 某些隐藏图标的 `AXPress` 仍会返回 `cannotComplete`，当前只能通过回退事件链路触发。
2. 该方案已经满足首轮隐藏图标样本验证，但不保证覆盖所有异常实现。
3. 某些全屏场景下，`TigerMan` 本身可能被系统隐藏；当前已由可配置全局快捷键兜底，但快捷键冲突或注册失败时还没有显式 UI 提示。

## 8. 诊断与排障策略

1. 设置页不再展示诊断区域；诊断能力以可选文件落盘为主。
2. 将 `TigerMan/Core/Utils/DiagnosticsFileLogger.swift` 中的 `DiagnosticsConfiguration.isEnabled` 改为 `true` 并重新构建后，项目根目录会写入：
   - `tigerman-events.log`
   - `tigerman-scan-latest.log`
   - `tigerman-interaction-latest.log`
   - `tigerman-hidden-discovery-latest.log`
3. 将同一处的 `DiagnosticsConfiguration.isScanImageExportEnabled` 改为 `true`，且保持 `isEnabled = true` 时，会额外把菜单栏原始截图与候选标注图导出到系统临时目录，便于排查识别、过滤和裁图问题。
4. 用法：需要排查时，直接修改上述代码常量并重新构建；排查结束后恢复为默认的 `false`，避免长期写盘。
5. 诊断已包含候选分层统计，例如：
   - `scanRegionCandidates`
   - `menuScopedCandidates`
   - `frontmostFilteredCandidates`
   - `interactionCandidateDetails`
6. 下一阶段新增隐藏图标探测专用诊断，至少覆盖：
   - `SystemUIServer` AX 树探测结果
   - 隐藏候选分类与过滤原因
   - 可见候选 / 隐藏候选对照关系
   - 无法继续推进时的失败上下文
7. 当前已补充更多隐藏图标专用字段，包括：
   - `hiddenItemsBuilt`
   - `finalItemDetails`
   - `hiddenProbeRunningAppExtraDetails`
   - `hiddenProbePromotedDetails`
   - 隐藏项交互时的 `AX action success / failed`
   - 自动刷新抑制与跳过刷新日志

## 9. 当前开发进度（截至 2026-04-07）

### 9.1 已完成

1. 项目已切换为标准 Xcode macOS 工程并可构建运行。
2. 权限申请链路（辅助功能、录屏）已打通并可重试。
3. 虚拟菜单栏面板、图标点击与右键转发已打通。
4. 左侧扫描、前台应用过滤、VS Code 场景修正已完成。
5. 设置页已精简；可选文件诊断与落盘日志体系已完成。
6. “遮挡原始菜单栏”相关运行逻辑与文件已移除。
7. 当前已经明确：隐藏图标发现不是后续优化项，而是下一阶段核心目标。
8. 隐藏图标探测专用诊断已接入可选落盘日志；启用后会写入 `tigerman-hidden-discovery-latest.log`。
9. 隐藏图标发现主链路已打通，`Bob`、`OrbStack` 已能进入面板模型并展示正确 logo。
10. 已修复隐藏项菜单“弹出约 1 秒后自动关闭”的问题。
11. 当前对隐藏项的交互结果、AX 失败码、自动刷新抑制状态都已有可观测日志。
12. 已修复 `TigerMan` 自身入口的二次点击行为，当前虚拟菜单栏支持“点一次打开、再点一次收起”的稳定切换。
13. 已优化面板打开热路径，点击 `TigerMan` 时不再先被同步全量扫描阻塞；诊断文件写盘默认关闭，并新增代码常量控制扫描图片导出。
14. 已新增全局快捷键兜底入口；默认值是 `⌃⌥⌘K`，并已支持在设置页中通过键盘录制修改与持久化保存。
15. 已修复快捷键唤起时面板跟随鼠标位置漂移的问题；当前会优先锚定真实 `TigerMan` 图标，隐藏时稳定回退到目标屏幕右上角。
16. 已补齐前台应用切换后的缓存失效处理；当前切换前台应用后再次打开面板，不会先闪出旧结果，必要时只会短暂显示“正在刷新...”。
17. 已修复“在设置页修改全局快捷键后，面板被外部 App 文本菜单污染”的问题；当前会跳过 `TigerMan` 自激活期间的刷新，并在回到外部 App 后强制补一次正确刷新。
18. 已把 `TigerMan` 菜单栏图标切换为资产目录中的 `StatusIcon`，支持仓库内直接替换图标资源。
19. 已新增“仅展示被隐藏图标”设置开关；开启后面板只保留隐藏项，关闭后恢复展示全部图标。
20. 已修复新增设置项后打开设置页触发的 `NSHostingView` 约束更新死循环；当前设置窗口尺寸固定，不再由 SwiftUI 自动回写。
21. 已移除“交互后保持面板打开”配置；当前镜像图标交互统一先关闭面板，再转发原始事件。
22. 已将可见扫描窗口固定为“屏幕中线到 `TigerMan` 左侧”，避免再因前台菜单区推断过窄而漏掉左侧仍然可见的菜单栏图标。
23. 已修复“仅展示被隐藏图标”模式下把仍然可见图标误收进隐藏列表的问题；根因是前台菜单过滤曾错误读取 `AXExtrasMenuBar`，当前已改为只读取前台 App 主菜单 `AXMenuBar`。
24. 已更新 `AppIcon.appiconset` 与 `StatusIcon.imageset` 的当前图标资源；Finder、系统设置权限列表、菜单栏入口等位置现在都会显示仓库中的自定义图标资产。
25. 已新增无开发者账号场景下的测试打包脚本 `scripts/package-dmg.sh`；当前可生成 `Release` 构建对应的 `dist/TigerMan-<version>-unsigned.dmg`，用于跨机器测试安装。

### 9.2 当前未完成

1. 扩大隐藏图标交互兼容性，减少对回退事件链路的依赖。
2. 补齐更多隐藏图标样本验证，而不只停留在已验证的少量 App。
3. 补齐全局快捷键冲突、注册失败与非法组合的显式 UI 提示。
4. 继续验证前台应用高频切换时的刷新体验，确保不会长期停留在加载态或错过刷新。
5. 当前打包链路仍停留在“unsigned DMG 测试分发”；若后续要面向更广泛用户分发，还需要补 `Developer ID` 签名与 notarization。

### 9.3 暂缓

1. 拖拽排序
2. 分组与搜索
3. 高级主题能力

## 10. MVP 验收状态（当前）

1. 启动后不影响原始菜单栏显示与行为：已满足。
2. 点击 `TigerMan` 可稳定弹出虚拟菜单栏：已满足。
3. 多个常见第三方菜单栏 App 可通过面板稳定触发交互：已基本满足。
4. 右键行为在支持的 App 上可用：已满足。
5. 权限缺失时提示明确、可重试：已满足。
6. 隐藏图标发现能力：已满足首轮目标，真实隐藏样本已能发现并展示。
7. 隐藏图标交互稳定性：已满足首轮目标，`Bob` / `OrbStack` 已可弹出原始菜单且不再自动关闭。
8. 当 `TigerMan` 被系统隐藏时的全局快捷键兜底入口：已满足，当前默认快捷键为 `⌃⌥⌘K`，并支持用户在设置页自定义。
9. 前台应用切换后不再先闪出旧面板结果：已满足，当前必要时仅短暂展示“正在刷新...”。
10. 当前剩余未完全满足项：并非所有隐藏图标都保证可直接通过 AX 成功触发。

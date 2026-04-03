# kBar 开发进展记录（更新于 2026-04-03）

## 1. 当前需求共识（已确认）

需求基线以 [`spec.md`](spec.md) 为准，当前已明确：

1. 核心目标是“虚拟菜单栏展示 + 原始交互转发”。
2. 原始菜单栏保持可见且可用，不再做遮挡、隐藏或收起。
3. 面板优先展示 `kBar` 左侧的菜单栏图标，避免 `kBar` 被系统挤进刘海后难以点击。
4. 面板图标需要尽量贴近原始菜单栏观感，但当前阶段以“识别正确、点击正确”为先。
5. 当前阶段重点仍是隐藏图标能力，但“能否发现”这一步已经打通，重点转为兼容性扩展。
6. 隐藏图标能力必须持续依赖可开关的自动化诊断日志推进；默认关闭，需要排查时再显式开启。

## 2. 已完成里程碑

### 2.1 工程与基础框架

1. 已迁移为标准 Xcode macOS App 工程。
2. 主流程已稳定运行于当前本机开发环境。
3. 菜单栏入口、设置窗口、虚拟面板框架已具备。

### 2.2 权限、窗口与交互链路

1. 辅助功能权限检查与重试已实现。
2. 录屏权限检查与重试已实现。
3. 左键点击 `kBar` 可开关虚拟菜单栏，不再依赖先打开设置页。
4. 虚拟面板支持外部点击关闭，并可跟随当前 Space。
5. 已修复 `kBar` 二次点击与面板外部点击监听的冲突；当前面板弹出后，再点一次 `kBar` 会直接收起，而不是立刻又重新打开。
6. 已优化面板打开速度；当前点击 `kBar` 会优先显示面板，再按需补刷新，不再被同步扫描卡住约 1 秒。
7. 镜像图标交互转发已实现：
   - 语义项优先走 `AXPress` / `AXShowMenu`
   - 失败回退 `CGEvent`
   - 纯截图项直接使用发现阶段的交互点，不再在点击时临时重算到相邻图标

### 2.3 图标发现、过滤与诊断

1. 已实现 AX + 截图双通道发现。
2. 扫描区域已切换为“以 `kBar` 为锚点，优先扫描左侧”。
3. 已实现：
   - `kBar` 自身区域过滤
   - 系统右侧保留区过滤
   - 前台应用菜单区过滤
   - 文本型 screenshot 候选过滤
   - 仅保留菜单栏语义树 AX 候选
4. VS Code 等前台应用的顶部状态控件不再被当成真实菜单栏图标参与交互映射。
5. 设置页当前只保留权限状态与手动刷新，不再内置诊断区域。
6. 已新增可开关的落盘诊断文件；默认关闭，便于需要时复现后直接分析：
   - `kbar-events.log`
   - `kbar-scan-latest.log`
   - `kbar-interaction-latest.log`
   - `kbar-hidden-discovery-latest.log`
7. 诊断开关已改为代码常量，位置在 `kBar/Core/Utils/DiagnosticsFileLogger.swift` 的 `DiagnosticsConfiguration`。
8. 将 `DiagnosticsConfiguration.isEnabled` 改为 `true` 并重新构建，可开启上述日志落盘；将 `DiagnosticsConfiguration.isScanImageExportEnabled` 改为 `true`，且保持 `isEnabled = true` 时，可在此基础上额外导出菜单栏原始截图与候选标注图到系统临时目录。
9. 用法：需要排查时，直接修改这两个代码常量并重新构建；排查结束后恢复为默认的 `false`。
10. 已补充隐藏图标探测专用诊断日志，避免排查继续依赖人工反馈。
11. 已补充隐藏图标交互专用日志，能够看到 AX failure code、synthetic tap 类型和刷新抑制状态。

### 2.4 图标快照与视觉

1. 面板图标已改为纯图标展示，去掉文本标签。
2. 已实现多轮图标快照清理：
   - 边缘背景采样
   - alpha 清理
   - 透明边裁剪
   - 主体连通域保留
3. 当前观感已明显好于早期版本，用户已确认“图标视觉微调先做到这里”，本阶段冻结进一步精修。
4. 隐藏图标已支持单独 logo 展示，优先取宿主 App 图标。

### 2.5 隐藏图标能力首轮落地

1. 已接入宿主进程级 `AXExtrasMenuBar` / `runningAppExtras` 探测。
2. `Bob`、`OrbStack` 这类被 macOS 隐藏的菜单栏图标，已经可以被识别并进入面板。
3. 隐藏图标已支持点击打开原始菜单。
4. 先前存在的“菜单弹出后自动关闭并跳到刘海附近”问题已经修复。

## 3. 当前可用能力快照

1. 点击 `kBar` 可稳定开关虚拟菜单栏，已显示时再次点击会收起；打开速度已明显快于早期同步刷新方案。
2. 面板可展示当前真实菜单栏可见区域中识别到的第三方图标。
3. 左键/右键交互转发主链路可运行。
4. VS Code 这类前台 App 场景下，误把顶部状态控件当成候选的问题已被压住。
5. 纯截图项的点击定位已稳定，不再二次偏移到相邻图标。
6. 需要排查扫描或交互问题时，可通过代码常量显式开启落盘日志与扫描图片导出。
7. 被 macOS 隐藏的图标已经能进入面板并展示 logo。
8. 当前下一步不是继续做 UI 微调，而是扩大隐藏图标兼容性并继续压缩交互回退的不确定性。

## 4. 当前主要问题

1. 隐藏图标“能否发现”已经不再是首要阻塞，当前问题转为“能否覆盖更多隐藏图标实现，并减少交互回退依赖”。
2. 当前机器上 `SystemUIServer` 根节点仍不可用，隐藏图标发现主要依赖宿主进程 `AXExtrasMenuBar`。
3. 部分隐藏图标的直接 `AXPress` 仍会返回 `cannotComplete`，当前依然需要 synthetic event 回退兜底。
4. 图标视觉虽然已可接受，但还不是逐像素 1:1 复刻。

## 5. 下一阶段优先级

1. 继续扩大隐藏图标样本验证范围，确认更多第三方菜单栏 App 的发现与交互表现。
2. 继续优化隐藏图标交互，尽量减少 `AXPress cannotComplete` 时对回退事件链路的依赖。
3. 在不破坏当前可用性的前提下，再决定是否继续做图标视觉精修。

## 6. 建议接手顺序

1. 先读文档：
   - [`spec.md`](spec.md)
   - [`code.md`](code.md)
   - [`process.md`](process.md)
2. 再看核心代码：
   - [`kBar/Services/StatusItemDiscoveryService.swift`](kBar/Services/StatusItemDiscoveryService.swift)
   - [`kBar/Services/InteractionProxy.swift`](kBar/Services/InteractionProxy.swift)
   - [`kBar/Services/ScreenCaptureService.swift`](kBar/Services/ScreenCaptureService.swift)
   - [`kBar/App/AppCoordinator.swift`](kBar/App/AppCoordinator.swift)
3. 如果要排查问题，先把 `kBar/Core/Utils/DiagnosticsFileLogger.swift` 中的 `DiagnosticsConfiguration` 调到目标值并重新构建，再优先读取：
   - `kbar-events.log`
   - `kbar-scan-latest.log`
   - `kbar-interaction-latest.log`
   - `kbar-hidden-discovery-latest.log`

## 7. 一句话状态结论

项目已经从“主链路打通”进入“隐藏图标首轮落地完成、开始做兼容性扩展”阶段。  
当前核心功能已经闭环，基础入口交互也补齐了“点击开关”行为；接下来的核心任务是：把已打通的隐藏图标能力扩展到更多 App，并继续提高交互稳定性。

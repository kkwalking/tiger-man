# kBar 可执行开发方案（V2，更新于 2026-04-01）

## 1. 文档目标

基于 [`sepc.md`](sepc.md) 的最新口径，明确当前可落地的研发路线、阶段目标和验收标准。  
本版只聚焦“虚拟菜单栏展示 + 原始交互转发”，不再包含遮挡原始菜单栏能力。

## 2. 需求基线（与 sepc 对齐）

1. `kBar` 常驻菜单栏，点击后弹出虚拟菜单栏面板。
2. 面板展示第三方菜单栏图标，并尽量还原原始图标观感。
3. 面板中的图标支持左键/右键，并转发到原始图标。
4. 原始菜单栏保持可见且可用，不做遮挡、隐藏、宽度改写。
5. 需要辅助功能权限和录屏权限。

## 3. 技术路线结论

### 3.1 总结

采用“镜像 + 交互转发”路线：

1. 扫描右上角菜单栏图标（AX + 截图双通道）。
2. 维护统一镜像模型（位置、快照、语义、交互点）。
3. 在 `NSPanel` 中渲染虚拟菜单栏。
4. 用户点击镜像图标时优先走 AX 动作，失败回退到 `CGEvent`。

### 3.2 明确不做

1. 不调用私有 API 去修改其他 App 的 `NSStatusItem`。
2. 不实现“遮挡原始菜单栏”。
3. 不以 App Store 审核通过为第一阶段目标。

## 4. 工程模块与职责

### 4.1 App 与状态

- [`kBar/kBarApp.swift`](kBar/kBarApp.swift)
- [`kBar/App/AppCoordinator.swift`](kBar/App/AppCoordinator.swift)
- [`kBar/Core/State/AppState.swift`](kBar/Core/State/AppState.swift)

职责：应用生命周期、全局状态、刷新调度、面板开关。  
当前状态：已落地，遮挡相关状态已移除。

### 4.2 菜单栏入口与面板

- [`kBar/UI/StatusBar/KBarStatusItemController.swift`](kBar/UI/StatusBar/KBarStatusItemController.swift)
- [`kBar/UI/Panel/MirrorPanelController.swift`](kBar/UI/Panel/MirrorPanelController.swift)
- [`kBar/UI/Panel/MirrorPanelView.swift`](kBar/UI/Panel/MirrorPanelView.swift)
- [`kBar/UI/Panel/MirrorItemView.swift`](kBar/UI/Panel/MirrorItemView.swift)

职责：`kBar` 入口、虚拟菜单栏容器、镜像图标渲染与交互。  
当前状态：已实现纯图标展示，样式仍可继续精修。

### 4.3 发现、截图、映射

- [`kBar/Services/StatusItemDiscoveryService.swift`](kBar/Services/StatusItemDiscoveryService.swift)
- [`kBar/Services/ScreenCaptureService.swift`](kBar/Services/ScreenCaptureService.swift)
- [`kBar/Services/StatusBarRegistry.swift`](kBar/Services/StatusBarRegistry.swift)
- [`kBar/Services/LayoutCoordinator.swift`](kBar/Services/LayoutCoordinator.swift)

职责：候选图标发现、图像切分、AX 融合、镜像模型更新。  
当前状态：双通道可跑通，识别准确率和图标干净度仍是主攻点。

### 4.4 权限与交互

- [`kBar/Services/PermissionCenter.swift`](kBar/Services/PermissionCenter.swift)
- [`kBar/Services/InteractionProxy.swift`](kBar/Services/InteractionProxy.swift)

职责：权限检查与重试、AX/CGEvent 转发链路。  
当前状态：已可用。

### 4.5 设置与诊断

- [`kBar/UI/Settings/SettingsView.swift`](kBar/UI/Settings/SettingsView.swift)
- [`kBar/UI/Settings/SettingsWindowController.swift`](kBar/UI/Settings/SettingsWindowController.swift)

职责：开关、权限状态、扫描日志、手动刷新。  
当前状态：已支持诊断输出和权限重试入口。

## 5. 核心流程（当前实现）

### 5.1 启动流程

1. 启动 `kBar`，注册菜单栏入口。
2. 检查辅助功能与录屏权限。
3. 权限齐全后进行扫描并构建镜像模型。

### 5.2 扫描与建模流程

1. AX 通道先取候选（结构化信息、动作能力、粗 frame）。
2. 截图通道切分候选（视觉边界、图标位图、补齐不可 AX 项）。
3. 对候选进行过滤：
   - 右侧系统保留区排除
   - kBar 自身区域排除
   - 宽块二次切分与噪点清理
4. 生成用于面板展示和交互的统一模型。

### 5.3 面板交互流程

1. 用户点击 `kBar` 打开面板。
2. 面板渲染当前镜像图标列表。
3. 点击镜像图标后：
   - 先执行 AX 动作（`AXPress` / `AXShowMenu`）
   - 失败时回退 `CGEvent` 到原始坐标

## 6. 图标发现与图像策略（当前版本）

### 6.1 已落地策略

1. 菜单栏扫描区域锚定在 `kBar` 右侧有效区。
2. 使用局部对比度 + 边缘强度识别候选列区间。
3. 对过宽候选做二次切分，避免多个图标合并。
4. 增加诊断输出：
   - `rawCandidateDetails`
   - `filteredCandidateDetails`
   - `contrastRanges` / `splitRanges`
   - `captureAnnotated`
5. 图标快照加入 aggressive 清理流程（边缘采样、透明抠图、主体连通域保留、透明边裁剪）。

### 6.2 当前效果与限制

1. 已能在多数情况下切出多个独立图标并展示在面板中。
2. 仍可能出现少量底色残留或锯齿，视觉与原图标未完全一致。
3. 截图候选仍有 `owner=nil/bundle=nil` 的语义缺口，影响精准过滤。

## 7. 体验策略（V2）

1. 保持原始菜单栏完整可见，不抢占其交互。
2. 虚拟菜单栏只做“补充入口”，不做系统菜单栏替代。
3. 默认点击后弹出，支持“交互后保持面板打开”选项。
4. 优先确保可用性（识别与点击正确），再做视觉精修。

## 8. 性能与刷新策略

1. 常驻态低频刷新，避免持续高频截图。
2. 面板打开前强制快速同步一次候选。
3. 触发快速重扫的事件：
   - 手动刷新
   - 分辨率/缩放变化
   - 活动屏幕变化
4. 面板关闭后回落到轻量刷新。

## 9. 当前开发进度（截至 2026-04-01）

### 9.1 已完成

1. 项目已切换为标准 Xcode macOS 工程并可构建运行。
2. 权限申请链路（辅助功能、录屏）已打通并可重试。
3. 虚拟菜单栏面板、图标点击与右键转发已打通。
4. 双通道扫描与诊断体系已建立。
5. “遮挡原始菜单栏”相关运行逻辑与文件已移除。

### 9.2 当前进行中

1. 提升“第三方图标精准筛选”的稳定性。
2. 继续缩小“面板图标观感”和“原始菜单栏图标”之间的差距。

### 9.3 暂缓

1. 拖拽排序
2. 分组与搜索
3. 快捷键唤起
4. 高级主题能力

## 10. 下一阶段优先级

1. 完成 AX 与截图候选的更稳融合，降低误收与漏收。
2. 把语义信息（owner/bundle/title）回填到更多截图候选。
3. 针对高频应用样本做定向回归（如代理/截图/输入法类状态栏图标）。
4. 在不牺牲识别率的前提下继续优化图标干净度。

## 11. MVP 验收标准（更新后）

1. 启动后不影响原始菜单栏显示与行为。
2. 点击 `kBar` 可稳定弹出虚拟菜单栏。
3. 至少 5 个常见第三方菜单栏 App 可通过面板稳定触发交互。
4. 右键行为在支持的 App 上可用。
5. 权限缺失时提示明确、可重试。
6. 休眠唤醒或布局变化后可恢复扫描与交互。

## 12. 风险与应对

1. 风险：不同 App 的 AX 支持差异大。  
应对：保持 AX 与截图双通道并行，交互层做回退。

2. 风险：菜单栏状态频繁变化导致映射过期。  
应对：打开面板前强制同步，运行时轻量增量刷新。

3. 风险：图标抠图过于激进导致细节损失。  
应对：把图像清理参数做成可调策略，按样本迭代阈值。

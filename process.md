# kBar 开发进展记录（更新于 2026-04-01）

## 1. 当前需求共识（已确认）

需求基线以 [`sepc.md`](sepc.md) 为准，当前已明确：

1. 核心目标是“虚拟菜单栏展示 + 原始交互转发”。
2. 原始菜单栏保持可见且可用，不再做遮挡、隐藏或收起。
3. 虚拟面板显示第三方图标，支持左键/右键触发原行为。
4. 图标视觉尽量贴近原始菜单栏，但以可用性优先。

## 2. 已完成里程碑

### 2.1 工程与基础框架

1. 已迁移为标准 Xcode macOS App 工程。
2. 主流程已稳定运行于当前本机开发环境。
3. 菜单栏入口、设置窗口、面板窗口框架已具备。

### 2.2 权限与交互链路

1. 辅助功能权限检查与重试已实现。
2. 录屏权限检查与重试已实现。
3. 镜像图标交互转发已实现：
   - 优先 `AXPress` / `AXShowMenu`
   - 失败回退 `CGEvent`

### 2.3 图标发现与诊断

1. 已实现 AX + 截图双通道发现。
2. 已实现截图 fallback 的范围控制与宽块切分。
3. 已实现系统右侧保留区过滤与 `kBar` 自身过滤。
4. 设置页已提供扫描诊断与手动刷新。
5. 已支持导出带标注截图，便于定位候选错误。

### 2.4 需求方向调整落地

1. 已从状态和主流程中移除“遮挡原始菜单栏”逻辑。
2. 相关旧模块文件已删除：
   - `kBar/UI/Overlay/OcclusionWindowController.swift`
   - `kBar/UI/Overlay/OcclusionOverlayView.swift`
3. 设置页已改为只强调虚拟菜单栏方案。

## 3. 本轮（截至当前）新增进展

1. 面板图标已改为纯图标展示，去掉文本标签。
2. 已对图标快照做多轮清理优化：
   - 边缘背景采样与抠图
   - 透明边裁剪
   - 主体连通域保留
   - 更激进的 alpha 阈值清理
3. 当前状态：图标识别链路可用，图标观感比早期明显提升，但仍存在个别底色残留。
4. 用户已确认“图标微调先到这里”，当前阶段先冻结视觉精修，继续以功能闭环为主。

## 4. 当前可用能力快照

1. `kBar` 点击后可弹出虚拟菜单栏。
2. 虚拟面板能展示已识别候选图标。
3. 左键/右键转发主链路可运行。
4. 诊断区可查看候选与切分细节（如 `filteredCandidateDetails`、`splitRanges`）。

## 5. 当前主要问题

1. 识别准确率仍需提升：个别目标图标会漏收，或与无关候选混入。
2. 语义信息不完整：部分截图候选仍缺少可靠的 owner/bundle。
3. 图标视觉仍非 1:1 原样：极少数场景存在彩色底块或边缘瑕疵。

## 6. 下一阶段优先级

1. 先做“识别正确率”：
   - 提升第三方图标过滤稳定性
   - 降低系统区域误收
2. 再做“语义融合”：
   - 增强 AX 与截图候选配对
   - 回填 owner/bundle/title 提高可解释性
3. 最后继续“视觉精修”：
   - 在不影响识别率前提下迭代抠图参数
   - 针对高频图标样本做专项回归

## 7. 建议接手顺序

1. 先读文档：
   - [`sepc.md`](sepc.md)
   - [`code.md`](code.md)
   - [`process.md`](process.md)
2. 再看核心代码：
   - [`kBar/Services/StatusItemDiscoveryService.swift`](kBar/Services/StatusItemDiscoveryService.swift)
   - [`kBar/Services/ScreenCaptureService.swift`](kBar/Services/ScreenCaptureService.swift)
   - [`kBar/Services/InteractionProxy.swift`](kBar/Services/InteractionProxy.swift)
   - [`kBar/UI/Panel/MirrorItemView.swift`](kBar/UI/Panel/MirrorItemView.swift)
3. 接手后先验证两件事：
   - `filteredCandidateDetails` 是否主要为真实目标图标
   - 面板点击/右键是否能稳定触发原始 App 行为

## 8. 一句话状态结论

项目已从“可跑通骨架”进入“可用性打磨阶段”：  
主链路已经成立，当前主战场是提高第三方图标筛选准确率，并在此基础上持续优化图标观感。

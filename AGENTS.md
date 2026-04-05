# Repository Guidelines

## 项目结构与模块划分

`kBar/` 是主代码目录。`App/` 放应用生命周期与刷新调度，`Services/` 放扫描、截图、快捷键、权限与交互转发，`UI/` 放状态栏、面板和设置页，`Core/` 放状态、模型与日志工具。资源位于 `kBar/Assets.xcassets/`。仓库根目录的 `spec.md`、`code.md`、`process.md` 分别记录需求、实现方案和开发进展；功能变更后应同步更新。

## 构建、测试与开发命令

本项目是 Xcode macOS App 工程，主要使用：

- `open kBar.xcodeproj`：在 Xcode 中运行和调试。
- `HOME=/tmp/kbar-home xcodebuild -project kBar.xcodeproj -target kBar -configuration Debug OBJROOT=/tmp/kbar-obj SYMROOT=/tmp/kbar-sym SHARED_PRECOMPS_DIR=/tmp/kbar-precomp CLANG_MODULE_CACHE_PATH=/tmp/kbar-clang-module-cache MODULE_CACHE_DIR=/tmp/kbar-module-cache SDK_STAT_CACHE_DIR=/tmp/kbar-sdk-stat-cache build`
  ：无界面构建，适合本地验证和 agent 执行。

当前仓库没有独立测试 target；提交前至少应完成一次 Debug 构建，并对相关交互做手动验证。

## 代码风格与命名

使用 Swift，保持 4 空格缩进。类型名使用 `UpperCamelCase`，属性、方法和变量使用 `lowerCamelCase`。文件名应与主类型一致，例如 `GlobalHotKeyService.swift`。优先保持现有结构和命名风格，不引入无关抽象；只在复杂逻辑前添加简短注释。菜单栏资源名称应清晰稳定，例如 `StatusIcon.imageset`。

## 测试与验证要求

由于当前以手动验证为主，修改后请记录你验证的场景，例如“左键开关面板”“全局快捷键唤起”“设置页录制快捷键”“全屏场景 fallback 定位”。涉及 UI 或扫描逻辑时，优先验证前台应用切换、权限缺失和 `kBar` 被隐藏等边界情况。

## 提交与 PR 规范

提交信息遵循当前历史风格：简短、英文、祈使句，例如 `Add configurable global hot key fallback`、`Protect refresh when kBar is active`。Pull Request 应说明用户可见变化、验证方式、是否更新 `spec.md`/`code.md`/`process.md`；若改动影响面板、设置页或菜单栏图标，请附截图。

每次准备 `git commit` 和 `git push` 前，必须先同步更新根目录的 `spec.md`、`code.md`、`process.md`，写入最新开发进展，并清理其中已经过时、相互冲突或与当前实现不符的描述；不要把过期口径留到后续提交再处理。

## 配置与排障

诊断开关在 `kBar/Core/Utils/DiagnosticsFileLogger.swift` 的 `DiagnosticsConfiguration`。默认保持关闭；仅在排障时临时改为 `true` 并重新构建。不要提交本地诊断日志文件。

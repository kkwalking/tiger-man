<div align="center">
<a href="https://github.com/kkwalking/tiger-man"><img src="app_icon_origin.png" width="120"/></a>
</div>
<h1 align="center">Tiger Man</h1>

<h4 align="center"><a href="README.md">English</a> | 简体中文 </h4>


<strong>TigerMan 是一个 macOS 菜单栏工具，目标是提供一个可操作的“虚拟菜单栏”入口，使得被macOS 隐藏的app图标也可点击。</strong>


## 截图

虚拟菜单栏
<div align="center"><img src="screenshots/virtual_menu.png" width="500"/></div>


设置页
<div align="center"><img src="screenshots/settings.png" width="500"/></div>


## 开发背景

在 MacBook Air、小屏幕设备和刘海屏机器上，右上角菜单栏图标很容易拥挤。随着常驻菜单栏的应用越来越多，一部分图标会变得难以点击，甚至直接被系统挤出可见区域。

TigerMan 的设计目标不是接管或重排系统菜单栏，而是新增一个独立入口：

- 保持原始菜单栏继续可见、可用
- 在悬浮面板里镜像展示菜单栏图标
- 尽量把用户在面板中的点击转发回原始菜单栏交互
- 在 TigerMan 自己也被系统隐藏时，仍然提供备用唤起方式

## Feature

- 菜单栏常驻入口：左键点击开关虚拟菜单栏，右键点击打开“偏好设置 / 退出”菜单
- 虚拟菜单栏面板：在独立悬浮面板中展示已识别的菜单栏图标
- 左键 / 右键交互转发：尽量还原原始菜单栏图标的点击行为
- 隐藏图标发现：支持探测被 macOS 因空间不足而隐藏的第三方菜单栏图标
- 全局快捷键：当 TigerMan 自己被系统隐藏时，仍可通过快捷键唤起面板，默认是 `Ctrl + Option + Command + K`
- 仅展示隐藏图标：设置页支持切换为只显示被隐藏的图标

## 用法

### 运行与调试

在 Xcode 中打开工程：

```bash
open TigerMan.xcodeproj
```

也可以使用命令行构建 Debug 版本：

```bash
HOME=/tmp/tigerman-home xcodebuild -project TigerMan.xcodeproj -scheme TigerMan -configuration Debug -derivedDataPath /tmp/tigerman-derived-data OBJROOT=/tmp/tigerman-obj SYMROOT=/tmp/tigerman-sym SHARED_PRECOMPS_DIR=/tmp/tigerman-precomp CLANG_MODULE_CACHE_PATH=/tmp/tigerman-clang-module-cache MODULE_CACHE_DIR=/tmp/tigerman-module-cache SDK_STAT_CACHE_DIR=/tmp/tigerman-sdk-stat-cache build
```

### 首次使用

1. 启动 TigerMan。
2. 按系统提示授予“辅助功能”和“录屏”权限。
3. 左键点击菜单栏中的 TigerMan 图标，打开虚拟菜单栏。
4. 直接点击面板中的镜像图标，触发原始菜单栏行为。
5. 如果 TigerMan 自己被系统挤出可见区域，可使用全局快捷键 `Ctrl + Option + Command + K` 唤起面板。

### 设置页

设置页目前支持：

- 手动刷新菜单栏映射
- 录制并修改全局快捷键
- 切换“仅展示被隐藏图标”
- 查看权限状态

### 本地打包测试版 DMG

项目提供了本地测试分发脚本：

```bash
./scripts/package-dmg.sh
```

生成产物位于 `dist/`，文件名格式为 `TigerMan-<version>-unsigned.dmg`。这是未签名测试包，首次在目标机器打开时，通常需要到“系统设置 > 隐私与安全性”里手动放行。

## 项目结构

- `TigerMan/App/`：应用生命周期、刷新调度、面板开关
- `TigerMan/Services/`：菜单栏扫描、截图、权限、快捷键、交互转发
- `TigerMan/UI/`：状态栏入口、虚拟面板、设置页
- `TigerMan/Core/`：状态、模型、日志工具
- `TigerMan/Assets.xcassets/`：图标与资源
- `.codex/`：需求、实现方案和开发进展文档

## 已知说明

- 当前仓库没有独立测试 target，主要依赖 Debug 构建和手动验证
- 项目不承诺兼容所有第三方菜单栏应用
- 当前分发目标主要是本地测试，不是已签名、已 notarize 的正式发行包

## Vibe Coding 声明

该项目是纯 vibe coding 的产物，开发人员不对代码质量保证。

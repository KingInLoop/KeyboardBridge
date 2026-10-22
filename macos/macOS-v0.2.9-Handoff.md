# KeyboardBridge macOS 开发交接文档

版本：v0.2.9  
目标系统：macOS 13+，Apple Silicon 与 Intel universal binary  
技术栈：Swift、AppKit、CoreGraphics、ApplicationServices、Apple Installer

## 本版重点

v0.2.9 在 v0.2.8 的手动粘贴、复制监听、紧凑置顶窗口、真实物理键码和脱敏日志基础上，加入标准 `.pkg` 安装与更明确的双权限引导。

## 安装模型

- 安装目标固定为 `/Applications/KeyboardBridge.app`。
- `installer-scripts/preinstall` 在删除旧版前读取 `CFBundleIdentifier`，只允许替换 `local.keyboardbridge.app`。
- 正常系统安装时会停止运行中的旧进程，并删除经相同 bundle id 校验的 `~/Applications/KeyboardBridge.app` 旧副本。
- 若目标路径存在无法确认身份的应用，安装会失败并保留该应用。
- `installer-scripts/postinstall` 通过 LaunchServices 注册应用，并在当前图形登录用户会话中启动它。

## 权限模型

- “授权键盘输入（辅助功能）”：调用辅助功能申请接口，打开 `Privacy_Accessibility`，用于发送键盘事件。
- “授权复制监听（输入监控）”：调用输入监听申请接口，打开 `Privacy_ListenEvent`，用于监听 `Command+C` 与 `Option+Esc`。
- 两个按钮会在 0.8、2、5 秒后刷新权限状态，但不能替用户批准系统权限。
- 固定安装路径与单一副本可降低用户在权限列表中找不到正确应用的概率。

## 构建

在项目根目录执行：

```bash
./macos/build-macos-installer.sh
```

脚本依次执行：

1. 编译 arm64 与 x86_64 并合并为 universal binary。
2. 运行内置 `--self-test` 与严格 codesign 校验。
3. 将应用暂存为 `/Applications/KeyboardBridge.app` 负载。
4. 使用 `pkgbuild` 和 `productbuild` 生成 `macos/dist/KeyboardBridge-macOS-v0.2.9.pkg`。
5. 如有签名证书与公证 profile，则自动签名、公证并 stapler 校验。

正式发布示例：

```bash
KEYBOARD_BRIDGE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
KEYBOARD_BRIDGE_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
KEYBOARD_BRIDGE_NOTARY_PROFILE="keyboardbridge-notary" \
./macos/build-macos-installer.sh
```

当前机器若没有 Developer ID 证书，脚本仍会生成本机测试包，但应用仅为 ad-hoc 签名、安装器没有分发签名。此包不应直接作为面向公众的最终发行版。

## 验证要点

- `pkgutil --payload-files` 中包含 `/Applications/KeyboardBridge.app`。
- 包内 `CFBundleShortVersionString` 为 `0.2.9`、构建号为 `29`。
- `lipo -archs` 同时报告 `arm64 x86_64`。
- 用临时目标卷验证从 v0.2.8 到 v0.2.9 的替换，并验证无关 bundle id 的同名应用会被拒绝且保留。
- 启动后确认两个授权按钮名称、说明和目标设置页分别正确。

## 保留能力

- 无论复制监听开关是否启用，待输入区始终支持 `Command+V` 和标题栏“粘贴”按钮。
- 多行默认转换为空格，只有勾选“允许回车”后才模拟 Enter。
- 窗口置顶、紧凑布局、Dock 与菜单栏恢复、复制监听开关、停止快捷键、演练模式和脱敏日志保持不变。

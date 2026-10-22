# KeyboardBridge macOS 开发交接文档

版本：v0.2.10  
目标系统：macOS 13+，Apple Silicon 与 Intel universal binary  
技术栈：Swift、AppKit、CoreGraphics、ApplicationServices、Apple Installer

## 问题根因

v0.2.9 安装后，系统设置可能显示 KeyboardBridge 开关已开启，但 `AXIsProcessTrusted()`、`CGPreflightPostEventAccess()` 与 `CGPreflightListenEventAccess()` 仍返回 false。

现场检查确认 v0.2.8 与 v0.2.9 都是 ad-hoc 签名，二者 designated requirement 由不同 CDHash 构成。TCC 列表里的开启记录仍可能属于旧 CDHash，因此这不是单纯的 UI 刷新延迟。

## 修复策略

### 安装器

`installer-scripts/postinstall` 读取新应用的 `TeamIdentifier`：

- `TeamIdentifier=not set`：判定为临时签名，以当前图形登录用户身份执行：
  - `tccutil reset Accessibility local.keyboardbridge.app`
  - `tccutil reset ListenEvent local.keyboardbridge.app`
- 存在 TeamIdentifier：判定为稳定签名，不重置已有授权。

重置发生在 LaunchServices 注册之后、自动启动新版之前。

### 应用内

- 每 0.5 秒执行一次权限检测。
- 权限状态旁的“刷新状态”强制立即刷新，并给出成功或旧签名排查反馈。
- “清理旧授权记录并重新授权”初始隐藏，仅在用户刷新后仍未授权时展开；经二次确认后异步运行两条 `tccutil reset`，成功后打开辅助功能设置，全部授权成功后自动收起。
- 输入监控由 false 变为 true 时调用 `updateCopyMonitors()`，重建可能在未授权期间创建失败的全局事件监听器。
- 授权按钮后的复查节点为 0.2、0.5、1、2、5、10 秒。

## 构建

```bash
./macos/build-macos-installer.sh
```

输出：`macos/dist/KeyboardBridge-macOS-v0.2.10.pkg`

正式发布建议：

```bash
KEYBOARD_BRIDGE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
KEYBOARD_BRIDGE_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
KEYBOARD_BRIDGE_NOTARY_PROFILE="keyboardbridge-notary" \
./macos/build-macos-installer.sh
```

使用稳定的 Developer ID Application 签名是避免每次升级重新授权的最终方案；测试包只能通过安装时自动清理，把操作成本降到一次重新开启两项开关。

## 验证

- universal binary：`arm64 x86_64`。
- 内置 `--self-test` 通过。
- 紧凑刷新按钮可在未授权状态显示明确修复提示并按需展开修复按钮。
- 修复按钮默认隐藏、存在二次确认，且不会重置其他应用。
- 临时目标卷升级测试必须确认旧应用被替换、无关 bundle id 应用被保留。

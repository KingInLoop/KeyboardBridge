# KeyboardBridge v0.2.10

本次发布包含 macOS v0.2.10 与 Windows v0.2.5 成品。

## 下载选择

- **macOS**：下载 `KeyboardBridge-macOS-v0.2.10.pkg`，双击安装。支持 Apple Silicon 与 Intel。
- **Windows 推荐**：下载 `KeyboardBridge-Windows-WinForms-x64-v0.2.5.zip`，解压后直接运行 `KeyboardBridge-WinForms.exe`。
- **Windows Tauri 版**：下载 `KeyboardBridge-Windows-Tauri-x64-v0.2.5.zip`，解压后保持 EXE 与 `WebView2Loader.dll` 在同一目录。

## macOS v0.2.10

- 标准 `.pkg` 安装到 `/Applications/KeyboardBridge.app`，自动识别并覆盖旧版本。
- 临时签名升级时自动清理旧的辅助功能与输入监控记录，修复系统开关已开启但应用仍显示未授权的问题。
- 权限状态每 0.5 秒刷新，提供紧凑的手动刷新入口。
- 旧授权清理入口仅在刷新后仍未授权时出现，授权成功后自动收起。
- 保留紧凑置顶窗口、菜单栏入口、手动粘贴、复制监听、多行 Enter、安全默认值和脱敏日志。

## Windows v0.2.5

- 提供 WinForms 单文件版本与 Tauri 2 版本。
- 支持 Ctrl+C 自动唤起、可调输入倒计时、三档界面缩放、模拟 Enter 和 `Ctrl+Alt+Esc` 停止。
- WinForms 与 Tauri 的状态文案、响应式布局和安全默认值保持一致。
- 默认不发送换行，不保存待输入正文。

## 首次运行提示

当前附件未使用商业代码签名证书：

- macOS 可能提示无法验证开发者，可在 Finder 中右键安装包并选择“打开”，不要全局关闭 Gatekeeper。
- Windows 可能显示 SmartScreen 提示，请核对本页附件与 `KeyboardBridge-v0.2.10-SHA256SUMS.txt` 后再决定是否运行。

本工具不会注入目标进程或绕过系统策略。请仅在获得允许的环境中使用，不要用于输入密码、令牌或私钥。

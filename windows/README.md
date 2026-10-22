# KeyboardBridge Windows Handoff v0.2.5

此源码包包含功能一致的两个 Windows 客户端：

- `windows-winforms/`：.NET 8 WinForms，自包含单文件发布。
- `tauri/`：Tauri 2 + Rust + 原生 HTML/CSS/JavaScript。
- `assets/`：应用图标源文件及 ICO。

## v0.2.5 重点

- 界面档位：小 80%、中 100%、大 125%；中档保持 v0.2.1 之前的标准大小。
- 两版的窗体、字体和间距同步缩放。
- 各档最小尺寸随比例调整，内容不足时使用纵向滚动条。
- 安全提示每次启动显示，5 秒后出现 ×，关闭后释放布局空间。
- 修复 Tauri 版点击 × 后提示仍占用空间，以及 WinForms 某些窗口状态下 × 未出现的问题。
- 固定 Tauri 底部操作区的最小高度；窗口高度不足时改为页面滚动，按钮不再被 Grid 压扁，并可随窗口恢复正常显示。
- WinForms 预览标题区减少顶部留白，并增强缩放重绘。
- 两版在倒计时期间统一提示“请点击要输入的位置”，不再把使用场景限定为云桌面。
- 工具可用于远程桌面、浏览器、桌面应用、终端以及禁用普通粘贴但允许键盘输入的位置；仍应遵守目标系统的使用和安全策略。

完整开发交接见 `WINDOWS-HANDOFF.md`，产品与技术设计见 `DESIGN.md`。

## 构建

WinForms：在 `windows-winforms` 中运行 `build-windows.ps1`。

Tauri：在 `tauri/src-tauri` 中运行 `cargo build --release`。GNU 工具链产物需将 `WebView2Loader.dll` 与 EXE 放在同一目录。

## 验证参数

- `--self-test`：WinForms 应用自检。
- `--input-self-test`：WinForms 原生 SendInput 冒烟测试。
- `--layout-test-min`：按当前档位以最小窗体尺寸启动，供布局检查。
- `--layout-test-narrow`：以窄窗体启动，供响应式布局检查。

注册表设置位于 `HKCU\Software\KeyboardBridge`，包括 `MonitorCopyShortcut` 与 `UiScale`。

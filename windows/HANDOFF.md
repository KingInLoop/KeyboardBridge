# KeyboardBridge Windows 开发交接文档

版本：v0.2.5  
实现：WinForms 与 Tauri 2  
目标系统：Windows 10/11 x64

## 产品定位

KeyboardBridge 是一个本地、可见、由用户主动确认的文本转键盘输入工具。用户检查文本并点击“几秒后输入”后，应用等待倒计时，由用户点击任意目标输入位置，再通过 Windows `SendInput` 逐字符发送键盘事件。

它不只面向云桌面，也适用于远程桌面、浏览器表单、Web 终端、桌面应用、虚拟机控制台，以及禁止普通剪贴板粘贴但仍允许键盘输入的区域。工具不注入目标进程、不修改安全策略，也不保证绕过目标应用对模拟输入的主动拦截。

## 当前用户流程

1. 用户输入文本，或开启 Ctrl+C 监听后从剪贴板载入文本。
2. 用户确认字符间隔、倒计时、回车策略和演练模式。
3. 点击“几秒后输入”。
4. 两版统一显示：`请点击要输入的位置（N 秒后输入）`。
5. 用户点击任意允许键盘输入的位置。
6. 倒计时结束后发送按键；`Ctrl+Alt+Esc` 可随时停止。

提示文案故意不再出现“云桌面”或“切换到目标窗口”，以覆盖同一窗口内控件、浏览器、桌面程序和远程环境等使用场景。

## 源码结构

- `windows-winforms/`：.NET 8 WinForms，自包含单文件发布。
- `tauri/ui/`：Tauri 前端 HTML、CSS、JavaScript。
- `tauri/src-tauri/`：Rust 后端、系统托盘、全局热键、复制监听与 `SendInput`。
- `assets/`：图标源文件。
- `DESIGN.md`：产品、交互和技术设计。

## 构建与测试

WinForms：在 `windows-winforms` 目录运行 `build-windows.ps1`。脚本会执行核心测试、发布自包含 EXE、运行应用自检和原生输入冒烟测试。

Tauri：在 `tauri/src-tauri` 目录运行：

```powershell
cargo test
cargo build --release
```

GNU 工具链产物需要把 `WebView2Loader.dll` 与 EXE 放在同一目录。

布局验证参数：

- `--layout-test-min`：以当前缩放档位的最小尺寸启动。
- `--layout-test-narrow`：以窄窗体启动。

## 设置与运行状态

注册表位置：`HKCU\Software\KeyboardBridge`

- `MonitorCopyShortcut`：是否监听 Ctrl+C。
- `UiScale`：`small`、`medium` 或 `large`。

输入内容本身不写入日志。日志只记录事件、计数、耗时、错误码和截断后的内容哈希。

## 已知限制

- 目标程序以更高完整性级别运行时，普通权限应用的模拟输入可能被 Windows 阻止。
- 部分安全软件、游戏、密码控件或受保护窗口会拒绝合成键盘事件。
- 标点物理键位按常见美式键盘位置映射；不同键盘布局可能产生差异。
- 开启“允许回车”可能直接提交表单或执行命令，默认保持关闭。

## 后续修改要求

- WinForms 与 Tauri 的功能、提示语、设置项和缩放体验应同步修改。
- 倒计时提示的核心含义应保持“点击要输入的位置”，避免限定具体应用类型。
- 每次发布同时更新版本号、交接文档、设计文档、使用说明、发布说明和 SHA-256。

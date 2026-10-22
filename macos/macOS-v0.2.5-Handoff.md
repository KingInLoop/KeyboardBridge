# KeyboardBridge macOS 开发交接文档

版本：v0.2.5  
目标系统：macOS 13+，Apple Silicon 与 Intel universal binary  
技术栈：Swift、AppKit、CoreGraphics、ApplicationServices

## 产品定位

KeyboardBridge 是一个本地、可见、由用户主动确认的文本转键盘输入工具。它适用于远程桌面、浏览器、终端、桌面应用、虚拟机控制台，以及限制普通粘贴但允许键盘输入的位置。

工具不注入目标进程、不修改系统或目标程序策略。用户在可编辑预览中确认文本，点击倒计时输入按钮，再将焦点放到目标位置，应用随后逐字符发送键盘事件。

## 与 Windows v0.2.5 对齐的功能

- 可编辑预览以及独立字符/行数统计。
- 字符间隔 1–500 ms。
- 输入倒计时 1–30 秒，按钮和状态栏同步显示剩余时间。
- 小 80%、中 100%、大 125% 三档界面缩放。
- 默认把换行替换为空格；“允许回车”开启后发送 Return。
- 演练模式、输入期间控件锁定和全局停止。
- 复制快捷键监听总开关及持久化。
- 每次启动显示安全提示，5 秒后允许关闭。
- 窄窗口使用纵向滚动，操作按钮保持最小高度。
- 倒计时提示使用“请点击要输入的位置”，不限定具体目标应用。

## macOS 平台实现

- `NSEvent` 全局与本地监听捕获 `Command+C` 和 `Option+Esc`。
- `CGEvent` 向 HID 事件层发送键盘事件。
- 常见 ASCII 优先使用物理 macOS key code；大写和符号显式发送 Shift。
- 非 ASCII 使用 `keyboardSetUnicodeString` 回退。
- 窗口使用 `.screenSaver` 层级并每 800 ms 恢复置顶，但最小化时不会被拉回。
- 应用同时保留 Dock 和菜单栏入口；关闭窗口只隐藏，菜单栏“退出”才终止进程。

## 设置持久化

使用 `UserDefaults`：

- `monitorCopyShortcut`：是否监听 `Command+C`。
- `uiScale`：`small`、`medium` 或 `large`。

输入正文、字符间隔和倒计时不会持久保存。

## 权限

- 辅助功能：发送键盘事件。
- 输入监控：监听其他应用中的 `Command+C` 和输入过程中的停止快捷键。

界面分别显示权限状态并提供对应系统设置入口。开发构建采用临时签名，重新编译后 macOS 可能要求移除旧授权并重新加入当前应用副本。

## 构建与验证

在项目根目录执行：

```bash
./macos/build-macos.sh
```

构建脚本会：

1. 分别编译 arm64 和 x86_64。
2. 使用 `lipo` 合并 universal binary。
3. 创建 `macos/dist/KeyboardBridge.app`。
4. 进行 ad-hoc codesign。
5. 执行 `--self-test`。

额外检查：

```bash
codesign --verify --deep --strict --verbose=2 macos/dist/KeyboardBridge.app
lipo -archs macos/dist/KeyboardBridge.app/Contents/MacOS/KeyboardBridge
```

## 日志

```text
~/Library/Logs/KeyboardBridge/bridge-YYYYMMDD.log
```

日志仅包含事件、平台、字符数、耗时、换行替换数和 12 位内容哈希，不记录输入正文。

## 已知限制

- 物理键位按常见美式键盘布局映射，非美式布局的标点可能不同。
- 非 ASCII 依赖 Unicode CGEvent，具体远程客户端可能不支持。
- 独占全屏应用可能覆盖系统级置顶窗口，此时建议使用窗口化或 macOS 全屏辅助空间。
- `Option+Esc` 依赖输入监听权限。
- 当前构建是临时签名，正式公开发布前应使用 Developer ID 签名并公证。

## 修改要求

- 面向用户的设置名称、倒计时语义、安全默认值和状态反馈应继续与 Windows 主版本同步。
- 保留 macOS 特有的权限诊断、运行副本路径、Dock 与菜单栏恢复入口。
- 每次发布递增版本号，不覆盖已有交付包，并运行自检、签名、双架构和压缩包完整性检查。


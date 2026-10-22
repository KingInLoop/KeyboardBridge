# 键盘输入桥 macOS v0.2.9

## 标准安装包

- 交付物改为 `.pkg`，应用固定安装到 `/Applications/KeyboardBridge.app`。
- 安装前会读取现有应用的 bundle id 和版本；只有确认是 KeyboardBridge 后才覆盖。
- 自动清理经校验的 `~/Applications/KeyboardBridge.app` 历史副本，减少系统权限列表里的重复条目。
- 安装后自动注册并启动新版本。

## 权限引导

- “授权键盘输入（辅助功能）”用于发送模拟按键，并直接打开辅助功能设置。
- “授权复制监听（输入监控）”用于监听 `Command+C` 与停止快捷键，并直接打开输入监控设置。
- 两项权限互相独立，按钮不再使用可能令人误解的“一键申请”文案。
- 每次申请后自动复查状态；macOS 最终授权仍需用户在系统设置中亲自确认。

## 构建与分发

- `build-macos-installer.sh` 会先构建 universal app，再生成安装包。
- 可分别指定 `KEYBOARD_BRIDGE_SIGN_IDENTITY` 与 `KEYBOARD_BRIDGE_INSTALLER_IDENTITY`。
- 配置 `KEYBOARD_BRIDGE_NOTARY_PROFILE` 后自动提交公证并装订票据。
- 没有开发者证书时生成 ad-hoc 应用和未签名安装包，仅适合本机测试。

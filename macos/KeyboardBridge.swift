import AppKit
import ApplicationServices
import CryptoKit

private let appVersion = "0.2.10"
private let monitorCopyPreferenceKey = "monitorCopyShortcut"
private let uiScalePreferenceKey = "uiScale"

private enum UiScale: String {
    case small, medium, large

    var factor: CGFloat {
        switch self {
        case .small: return 0.80
        case .medium: return 1.00
        case .large: return 1.25
        }
    }

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

struct TextPlan {
    let units: [String]
    let replacedNewlines: Int

    static func make(_ text: String, allowReturn: Bool) -> TextPlan {
        var result: [String] = []
        var replaced = 0
        for character in text {
            let value = String(character)
            if value == "\n" || value == "\r\n" || value == "\r" {
                if allowReturn {
                    result.append("\n")
                } else {
                    result.append(" ")
                    replaced += 1
                }
            } else if value == "\t" {
                result.append("    ")
            } else {
                result.append(value)
            }
        }
        return TextPlan(units: result, replacedNewlines: replaced)
    }
}

struct PhysicalKey {
    let keyCode: CGKeyCode
    let shift: Bool
}

enum PhysicalKeyMapper {
    private static let plain: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, " ": 49, "`": 50
    ]

    private static let shifted: [Character: CGKeyCode] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26,
        "*": 28, "(": 25, ")": 29, "+": 24, "_": 27, "{": 33, "}": 30,
        "|": 42, ":": 41, "\"": 39, "<": 43, ">": 47, "?": 44, "~": 50
    ]

    static func key(for character: Character) -> PhysicalKey? {
        if let code = plain[character] { return PhysicalKey(keyCode: code, shift: false) }
        if let code = shifted[character] { return PhysicalKey(keyCode: code, shift: true) }
        let value = String(character)
        let lower = value.lowercased()
        if value != lower, lower.count == 1, let lowerCharacter = lower.first,
           let code = plain[lowerCharacter] {
            return PhysicalKey(keyCode: code, shift: true)
        }
        return nil
    }
}

final class SafeLogger {
    static let shared = SafeLogger()
    private let queue = DispatchQueue(label: "KeyboardBridge.Logger")
    private let fileURL: URL

    private init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KeyboardBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        fileURL = base.appendingPathComponent("bridge-\(formatter.string(from: Date())).log")
    }

    func contentID(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    func write(_ event: String, fields: [String: String] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeFields = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: "_"))" }
            .joined(separator: " ")
        let line = "\(timestamp) version=\(appVersion) event=\(event) \(safeFields)\n"
        queue.async { [fileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

final class CancellationFlag {
    private let lock = NSLock()
    private var stopped = false

    func reset() { lock.withLock { stopped = false } }
    func cancel() { lock.withLock { stopped = true } }
    func isCancelled() -> Bool { lock.withLock { stopped } }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private let textView = NSTextView()
    private let previewInfoLabel = NSTextField(labelWithString: "0 字符 · 1 行")
    private let statusLabel = NSTextField(labelWithString: "●  等待输入内容")
    private let delayField = NSTextField(string: "10")
    private let countdownField = NSTextField(string: "3")
    private let uiScalePopup = NSPopUpButton()
    private let allowReturnButton = NSButton(checkboxWithTitle: "允许回车（可能直接执行命令）", target: nil, action: nil)
    private let dryRunButton = NSButton(checkboxWithTitle: "演练模式（不发送按键）", target: nil, action: nil)
    private let monitorCopyButton = NSButton(checkboxWithTitle: "监听 ⌘C 并自动唤起窗口", target: nil, action: nil)
    private let permissionLabel = NSTextField(labelWithString: "权限状态：检查中…")
    private let pathLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "授权键盘输入（辅助功能）", target: nil, action: nil)
    private let listenPermissionButton = NSButton(title: "授权复制监听（输入监控）", target: nil, action: nil)
    private let recheckPermissionButton = NSButton(title: "刷新状态", target: nil, action: nil)
    private let repairPermissionButton = NSButton(title: "清理旧授权记录并重新授权", target: nil, action: nil)
    private let installButton = NSButton(title: "安装到应用程序文件夹", target: nil, action: nil)
    private let pasteButton = NSButton(title: "粘贴", target: nil, action: nil)
    private let startButton = NSButton(title: "3 秒后输入", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止  ⌥Esc", target: nil, action: nil)
    private weak var rootStack: NSStackView?
    private weak var safetyNotice: NSBox?
    private weak var numberSettingsStack: NSStackView?
    private weak var permissionButtonsStack: NSStackView?
    private var permissionTimer: Timer?
    private var frontTimer: Timer?
    private var countdownTimer: Timer?
    private var globalStopMonitor: Any?
    private var localStopMonitor: Any?
    private var globalCopyMonitor: Any?
    private var localCopyMonitor: Any?
    private var lastCopyTrigger = Date.distantPast
    private var countdown = 0
    private let cancellation = CancellationFlag()
    private var isTyping = false
    private var isCountingDown = false
    private var currentUiScale: CGFloat = 1.0
    private var lastPostPermission: Bool?
    private var lastListenPermission: Bool?

    convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        configureWindow()
        buildUI()
        beginMonitoring()
    }

    private func configureWindow() {
        guard let window else { return }
        window.title = "键盘输入桥"
        window.minSize = NSSize(width: 320, height: 400)
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.miniwindowTitle = "键盘输入桥"
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        let restored = window.setFrameUsingName("KeyboardBridgeCompactWindowV1")
        window.setFrameAutosaveName("KeyboardBridgeCompactWindowV1")
        if !restored, let visible = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: visible.maxX - window.frame.width - 16,
                y: visible.maxY - window.frame.height - 16
            )
            window.setFrameOrigin(origin)
        }
        window.delegate = self
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func card(containing child: NSView, fill: NSColor = .controlBackgroundColor, border: NSColor = .separatorColor) -> NSBox {
            let box = NSBox()
            box.boxType = .custom
            box.titlePosition = .noTitle
            box.fillColor = fill
            box.borderColor = border
            box.borderWidth = 1
            box.cornerRadius = 10
            box.contentViewMargins = NSSize(width: 14, height: 12)
            guard let cardContent = box.contentView else { return box }
            child.translatesAutoresizingMaskIntoConstraints = false
            cardContent.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
                child.topAnchor.constraint(equalTo: cardContent.topAnchor),
                child.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor)
            ])
            return box
        }

        func label(_ value: String, weight: NSFont.Weight = .regular, size: CGFloat = 13) -> NSTextField {
            let result = NSTextField(labelWithString: value)
            result.font = .systemFont(ofSize: size, weight: weight)
            return result
        }

        func settingPair(_ title: String, field: NSView) -> NSStackView {
            let pair = NSStackView(views: [label(title, weight: .medium, size: 12), field])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 8
            return pair
        }

        let warningText = NSTextField(wrappingLabelWithString: "请检查内容后再输入。不要粘贴密码、令牌或私钥；换行默认会替换为空格。")
        warningText.textColor = .systemOrange
        warningText.font = .systemFont(ofSize: 13)
        warningText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let warningClose = NSButton(title: "×", target: self, action: #selector(dismissSafetyNotice))
        warningClose.bezelStyle = .inline
        warningClose.isBordered = false
        warningClose.font = .systemFont(ofSize: 16, weight: .semibold)
        warningClose.contentTintColor = .systemOrange
        warningClose.toolTip = "隐藏安全提示"
        warningClose.setAccessibilityLabel("隐藏安全提示")
        warningClose.widthAnchor.constraint(equalToConstant: 28).isActive = true
        warningClose.heightAnchor.constraint(equalToConstant: 28).isActive = true
        warningClose.isHidden = true
        let warningRow = NSStackView(views: [warningText, warningClose])
        warningRow.orientation = .horizontal
        warningRow.alignment = .centerY
        warningRow.spacing = 8
        let warningCard = card(
            containing: warningRow,
            fill: NSColor.systemOrange.withAlphaComponent(0.10),
            border: NSColor.systemOrange.withAlphaComponent(0.32)
        )
        safetyNotice = warningCard

        let previewTitle = label("待输入内容", weight: .semibold, size: 13)
        previewInfoLabel.textColor = .secondaryLabelColor
        previewInfoLabel.font = .systemFont(ofSize: 12)
        previewInfoLabel.alignment = .right
        pasteButton.bezelStyle = .rounded
        pasteButton.controlSize = .small
        pasteButton.target = self
        pasteButton.action = #selector(pasteIntoPreview)
        pasteButton.toolTip = "将剪贴板内容插入待输入区（⌘V）"
        pasteButton.setAccessibilityLabel("将剪贴板内容粘贴到待输入区")
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let previewHeader = NSStackView(views: [previewTitle, headerSpacer, previewInfoLabel, pasteButton])
        previewHeader.orientation = .horizontal
        previewHeader.alignment = .centerY
        previewHeader.spacing = 8

        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.borderType = .noBorder
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.delegate = self
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editorScroll.documentView = textView
        editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let previewStack = NSStackView(views: [previewHeader, editorScroll])
        previewStack.orientation = .vertical
        previewStack.alignment = .width
        previewStack.spacing = 8
        let previewCard = card(containing: previewStack)

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .none
        numberFormatter.allowsFloats = false
        delayField.formatter = numberFormatter
        delayField.alignment = .center
        delayField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        delayField.widthAnchor.constraint(equalToConstant: 62).isActive = true
        countdownField.formatter = numberFormatter
        countdownField.alignment = .center
        countdownField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countdownField.delegate = self
        countdownField.target = self
        countdownField.action = #selector(countdownValueChanged)
        countdownField.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let savedScale = UiScale(rawValue: UserDefaults.standard.string(forKey: uiScalePreferenceKey) ?? "") ?? .medium
        uiScalePopup.addItems(withTitles: [UiScale.small.title, UiScale.medium.title, UiScale.large.title])
        uiScalePopup.selectItem(at: savedScale == .small ? 0 : (savedScale == .large ? 2 : 1))
        uiScalePopup.target = self
        uiScalePopup.action = #selector(uiScaleChanged)

        let numberRow = NSStackView(views: [
            settingPair("字符间隔（毫秒）", field: delayField),
            settingPair("输入倒计时（秒）", field: countdownField),
            settingPair("界面大小", field: uiScalePopup)
        ])
        numberRow.orientation = .vertical
        numberRow.alignment = .leading
        numberRow.distribution = .fill
        numberRow.spacing = 7
        numberSettingsStack = numberRow

        let savedMonitorSetting = UserDefaults.standard.object(forKey: monitorCopyPreferenceKey) as? Bool ?? true
        monitorCopyButton.state = savedMonitorSetting ? .on : .off
        monitorCopyButton.target = self
        monitorCopyButton.action = #selector(copyMonitoringChanged)
        let options = NSStackView(views: [allowReturnButton, dryRunButton, monitorCopyButton])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 7

        let settingsStack = NSStackView(views: [numberRow, options])
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 12
        numberRow.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true
        let settingsCard = card(containing: settingsStack)

        permissionButton.target = self
        permissionButton.action = #selector(requestAccessibilityPermission)
        permissionButton.toolTip = "允许应用向当前聚焦位置发送模拟键盘输入"
        listenPermissionButton.target = self
        listenPermissionButton.action = #selector(requestInputMonitoringPermission)
        listenPermissionButton.toolTip = "允许应用监听其他程序中的 Command+C 和停止快捷键"
        recheckPermissionButton.target = self
        recheckPermissionButton.action = #selector(recheckPermissions)
        recheckPermissionButton.toolTip = "立即重新读取 macOS 返回的辅助功能与输入监控状态"
        recheckPermissionButton.controlSize = .small
        repairPermissionButton.target = self
        repairPermissionButton.action = #selector(repairPermissionRecords)
        repairPermissionButton.toolTip = "清除仅属于 KeyboardBridge 的旧授权记录；版本升级后开关已开但仍显示未授权时使用"
        repairPermissionButton.isHidden = true
        installButton.target = self
        installButton.action = #selector(installToApplications)
        installButton.isHidden = isRunningFromApplicationsFolder()
        permissionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        permissionLabel.lineBreakMode = .byWordWrapping
        permissionLabel.maximumNumberOfLines = 0
        permissionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let permissionHeader = NSStackView(views: [permissionLabel, recheckPermissionButton])
        permissionHeader.orientation = .horizontal
        permissionHeader.alignment = .centerY
        permissionHeader.distribution = .fill
        permissionHeader.spacing = 8
        recheckPermissionButton.setContentHuggingPriority(.required, for: .horizontal)
        let permissionButtons = NSStackView(views: [
            permissionButton,
            listenPermissionButton,
            repairPermissionButton,
            installButton
        ])
        permissionButtons.orientation = .vertical
        permissionButtons.alignment = .width
        permissionButtons.distribution = .fill
        permissionButtons.spacing = 6
        permissionButtons.detachesHiddenViews = true
        permissionButtonsStack = permissionButtons
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.toolTip = Bundle.main.bundlePath
        pathLabel.stringValue = "运行副本：\(Bundle.main.bundlePath)"
        let permissionStack = NSStackView(views: [permissionHeader, permissionButtons, pathLabel])
        permissionStack.orientation = .vertical
        permissionStack.alignment = .width
        permissionStack.spacing = 8
        let permissionCard = card(containing: permissionStack)

        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startCountdown)
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopTyping)
        let buttons = NSStackView(views: [startButton, stopButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillProportionally
        buttons.spacing = 10
        startButton.widthAnchor.constraint(equalTo: stopButton.widthAnchor, multiplier: 1.6).isActive = true
        startButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        stopButton.heightAnchor.constraint(equalTo: startButton.heightAnchor).isActive = true

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [warningCard, previewCard, settingsCard, permissionCard])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        rootStack = stack

        let rootScroll = NSScrollView()
        rootScroll.hasVerticalScroller = true
        rootScroll.autohidesScrollers = true
        rootScroll.drawsBackground = true
        rootScroll.backgroundColor = .windowBackgroundColor
        rootScroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        rootScroll.documentView = document
        content.addSubview(rootScroll)

        let footer = NSStackView(views: [buttons, statusLabel])
        footer.orientation = .vertical
        footer.alignment = .width
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            rootScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootScroll.topAnchor.constraint(equalTo: content.topAnchor),
            rootScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: rootScroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: rootScroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -12),
            warningCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            buttons.widthAnchor.constraint(equalTo: footer.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak warningClose, weak warningCard] in
            guard warningCard?.isHidden == false else { return }
            warningClose?.isHidden = false
        }
        updatePreviewStatus("")
        applyUiScale(savedScale, persist: false)
        updateResponsiveLayout()
    }

    @objc private func dismissSafetyNotice() {
        safetyNotice?.isHidden = true
    }

    @objc private func pasteIntoPreview() {
        guard !isTyping else { return }
        guard NSPasteboard.general.string(forType: .string) != nil else {
            statusLabel.stringValue = "剪贴板中没有可粘贴的文本"
            NSSound.beep()
            return
        }
        window?.makeFirstResponder(textView)
        textView.paste(nil)
        updatePreviewStatus(textView.string)
        statusLabel.stringValue = "已从剪贴板粘贴，可继续编辑后再输入"
        SafeLogger.shared.write("manual_paste", fields: [
            "chars": "\(textView.string.count)",
            "content_id": SafeLogger.shared.contentID(textView.string)
        ])
    }

    private func updateResponsiveLayout() {
        guard let width = window?.contentView?.bounds.width else { return }
        let compact = width < 540

        if let numberSettingsStack {
            numberSettingsStack.orientation = compact ? .vertical : .horizontal
            numberSettingsStack.alignment = compact ? .leading : .centerY
            numberSettingsStack.distribution = compact ? .fill : .gravityAreas
            numberSettingsStack.spacing = compact ? 7 : 18
        }

        if let permissionButtonsStack {
            permissionButtonsStack.orientation = compact ? .vertical : .horizontal
            permissionButtonsStack.alignment = compact ? .width : .centerY
            permissionButtonsStack.distribution = compact ? .fill : .fillEqually
            permissionButtonsStack.spacing = 6
        }

        pathLabel.isHidden = width < 460
    }

    private func selectedUiScale() -> UiScale {
        switch uiScalePopup.indexOfSelectedItem {
        case 0: return .small
        case 2: return .large
        default: return .medium
        }
    }

    private func scaleFonts(in view: NSView, ratio: CGFloat) {
        if let control = view as? NSControl, let font = control.font {
            control.font = NSFont(descriptor: font.fontDescriptor, size: max(8, font.pointSize * ratio))
        }
        if let text = view as? NSTextView, let font = text.font {
            text.font = NSFont(descriptor: font.fontDescriptor, size: max(8, font.pointSize * ratio))
        }
        view.subviews.forEach { scaleFonts(in: $0, ratio: ratio) }
    }

    private func applyUiScale(_ scale: UiScale, persist: Bool) {
        let target = scale.factor
        let ratio = target / currentUiScale
        if abs(ratio - 1) > 0.001, let window, let content = window.contentView {
            scaleFonts(in: content, ratio: ratio)
            let frame = window.frame
            let center = NSPoint(x: frame.midX, y: frame.midY)
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
            var size = NSSize(width: frame.width * ratio, height: frame.height * ratio)
            size.width = min(size.width, screenFrame.width - 24)
            size.height = min(size.height, screenFrame.height - 24)
            let origin = NSPoint(
                x: min(max(screenFrame.minX, center.x - size.width / 2), screenFrame.maxX - size.width),
                y: min(max(screenFrame.minY, center.y - size.height / 2), screenFrame.maxY - size.height)
            )
            window.minSize = NSSize(
                width: max(300, 320 * target),
                height: max(360, 400 * target)
            )
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
            currentUiScale = target
        } else {
            window?.minSize = NSSize(
                width: max(300, 320 * target),
                height: max(360, 400 * target)
            )
            currentUiScale = target
        }
        if persist { UserDefaults.standard.set(scale.rawValue, forKey: uiScalePreferenceKey) }
        updateResponsiveLayout()
    }

    @objc private func uiScaleChanged() {
        let scale = selectedUiScale()
        applyUiScale(scale, persist: true)
        statusLabel.stringValue = "界面大小已切换为\(scale.title)"
    }

    private func boundedInteger(from field: NSTextField, fallback: Int, range: ClosedRange<Int>) -> Int {
        let value = Int(field.stringValue) ?? fallback
        let bounded = min(range.upperBound, max(range.lowerBound, value))
        field.stringValue = String(bounded)
        return bounded
    }

    @objc private func countdownValueChanged() {
        let seconds = boundedInteger(from: countdownField, fallback: 3, range: 1...30)
        if !isTyping { startButton.title = "\(seconds) 秒后输入" }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === countdownField else { return }
        if let seconds = Int(field.stringValue), (1...30).contains(seconds), !isTyping {
            startButton.title = "\(seconds) 秒后输入"
        }
    }

    private func beginMonitoring() {
        globalStopMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleStopKey(event)
        }
        localStopMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleStopKey(event)
            return event
        }
        updateCopyMonitors()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
        frontTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.pinWindowToFront()
        }
        refreshPermissionStatus()
        pinWindowToFront()
        SafeLogger.shared.write("app_started", fields: ["platform": "macos"])

        if !canPostEvents() || (monitorCopyButton.state == .on && !CGPreflightListenEventAccess()) {
            statusLabel.stringValue = "首次使用请依次完成“辅助功能”和“输入监控”授权"
        }
    }

    private func handleStopKey(_ event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.contains(.option) {
            DispatchQueue.main.async { [weak self] in self?.stopTyping() }
        }
    }

    private func handleCopyKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.keyCode == 8, flags.contains(.command), !event.isARepeat else { return }
        DispatchQueue.main.async { [weak self] in self?.scheduleCopyCapture() }
    }

    private func updateCopyMonitors() {
        if let globalCopyMonitor { NSEvent.removeMonitor(globalCopyMonitor); self.globalCopyMonitor = nil }
        if let localCopyMonitor { NSEvent.removeMonitor(localCopyMonitor); self.localCopyMonitor = nil }
        guard monitorCopyButton.state == .on else { return }
        globalCopyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCopyKey(event)
        }
        localCopyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCopyKey(event)
            return event
        }
    }

    @objc private func copyMonitoringChanged() {
        let enabled = monitorCopyButton.state == .on
        UserDefaults.standard.set(enabled, forKey: monitorCopyPreferenceKey)
        updateCopyMonitors()
        refreshPermissionStatus()
        statusLabel.stringValue = enabled ? "已开启 ⌘C 监听；复制后会自动唤起" : "已关闭 ⌘C 监听；复制操作不会唤起工具"
        SafeLogger.shared.write("copy_monitor_changed", fields: ["enabled": enabled ? "true" : "false"])
    }

    private func scheduleCopyCapture() {
        guard monitorCopyButton.state == .on, !isTyping else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCopyTrigger) > 0.15 else { return }
        lastCopyTrigger = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.captureClipboardAfterCopy()
        }
    }

    private func captureClipboardAfterCopy() {
        guard monitorCopyButton.state == .on, !isTyping else { return }
        let pasteboard = NSPasteboard.general
        guard !isTyping, let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        textView.string = text
        updatePreviewStatus(text)
        NSSound.beep()
        window?.deminiaturize(nil)
        pinWindowToFront()
        SafeLogger.shared.write("command_c_captured", fields: [
            "chars": "\(text.count)", "content_id": SafeLogger.shared.contentID(text)
        ])
    }

    private func canPostEvents() -> Bool {
        CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }

    func refreshPermissionStatus(showFeedback: Bool = false) {
        let post = canPostEvents()
        let listen = CGPreflightListenEventAccess()
        let monitoring = monitorCopyButton.state == .on
        let listenStatus = monitoring ? (listen ? "已授权 ✓" : "未授权 ✗") : "已关闭"
        permissionLabel.stringValue = "输入：\(post ? "已授权 ✓" : "未授权 ✗")　⌘C：\(listenStatus)"
        permissionLabel.textColor = (post && (!monitoring || listen)) ? .systemGreen : .systemOrange
        if post && (!monitoring || listen) {
            repairPermissionButton.isHidden = true
        }

        let newlyAuthorized = (lastPostPermission == false && post)
            || (lastListenPermission == false && listen)
        if lastListenPermission == false && listen && monitoring {
            // A global monitor created before permission was granted may remain
            // inactive. Recreate it as soon as macOS reports the change.
            updateCopyMonitors()
        }
        lastPostPermission = post
        lastListenPermission = listen

        guard !isTyping && !isCountingDown else { return }
        if post && (!monitoring || listen) {
            if showFeedback || newlyAuthorized {
                statusLabel.stringValue = "授权状态已更新，可以开始使用"
            }
        } else if showFeedback {
            statusLabel.stringValue = "系统仍返回未授权；若设置开关已打开，请使用“清理旧授权记录并重新授权”"
        }
    }

    @objc private func recheckPermissions() {
        refreshPermissionStatus(showFeedback: true)
        let post = canPostEvents()
        let listenReady = monitorCopyButton.state == .off || CGPreflightListenEventAccess()
        repairPermissionButton.isHidden = post && listenReady
        SafeLogger.shared.write("permissions_rechecked")
    }

    @objc private func repairPermissionRecords() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清理 KeyboardBridge 的旧授权记录？"
        alert.informativeText = "版本升级后，macOS 可能仍显示旧签名副本的开关。此操作只重置 KeyboardBridge 的辅助功能和输入监控记录；完成后需要重新打开这两个权限。"
        alert.addButton(withTitle: "清理并重新授权")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        recheckPermissionButton.isEnabled = false
        repairPermissionButton.isEnabled = false
        statusLabel.stringValue = "正在清理旧授权记录…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let accessibilityReset = Self.resetPermissionRecord(service: "Accessibility")
            let listenReset = Self.resetPermissionRecord(service: "ListenEvent")
            DispatchQueue.main.async {
                guard let self else { return }
                self.recheckPermissionButton.isEnabled = true
                self.repairPermissionButton.isEnabled = true
                self.lastPostPermission = nil
                self.lastListenPermission = nil
                self.refreshPermissionStatus()
                if accessibilityReset && listenReset {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    self.openPrivacySettings(anchor: "Privacy_Accessibility", name: "辅助功能")
                    self.statusLabel.stringValue = "旧授权已清理：请先授权“辅助功能”，再授权“输入监控”"
                    SafeLogger.shared.write("permission_records_reset", fields: ["result": "success"])
                    self.schedulePermissionRechecks()
                } else {
                    self.statusLabel.stringValue = "旧授权记录清理失败，请完全退出应用后重新安装最新版"
                    SafeLogger.shared.write("permission_records_reset", fields: ["result": "failed"])
                }
            }
        }
    }

    private static func resetPermissionRecord(service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "local.keyboardbridge.app"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @objc private func requestAccessibilityPermission() {
        if canPostEvents() {
            statusLabel.stringValue = "键盘输入权限已授权，无需重复设置"
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = CGRequestPostEventAccess()
            openPrivacySettings(anchor: "Privacy_Accessibility", name: "辅助功能")
            statusLabel.stringValue = "请在“辅助功能”中允许 KeyboardBridge，然后返回此窗口"
        }
        refreshPermissionStatus()
        SafeLogger.shared.write("accessibility_permission_requested")
        schedulePermissionRechecks()
    }

    @objc private func requestInputMonitoringPermission() {
        if CGPreflightListenEventAccess() {
            statusLabel.stringValue = "复制监听权限已授权，无需重复设置"
        } else {
            _ = CGRequestListenEventAccess()
            openPrivacySettings(anchor: "Privacy_ListenEvent", name: "输入监控")
            statusLabel.stringValue = "请在“输入监控”中允许 KeyboardBridge，然后返回此窗口"
        }
        refreshPermissionStatus()
        SafeLogger.shared.write("input_monitoring_permission_requested")
        schedulePermissionRechecks()
    }

    private func schedulePermissionRechecks() {
        for delay in [0.2, 0.5, 1.0, 2.0, 5.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshPermissionStatus()
            }
        }
    }

    private func openPrivacySettings(anchor: String, name: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
        statusLabel.stringValue = "已打开“\(name)”设置；允许当前路径的应用后，请完全退出并重新打开"
        SafeLogger.shared.write("privacy_settings_opened", fields: ["pane": anchor])
    }

    private func isRunningFromApplicationsFolder() -> Bool {
        let appPath = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path
        return appPath.hasPrefix("/Applications/") || appPath.hasPrefix(userApplications + "/")
    }

    @objc private func installToApplications() {
        if isRunningFromApplicationsFolder() {
            installButton.isHidden = true
            statusLabel.stringValue = "当前副本已位于应用程序文件夹"
            return
        }

        let manager = FileManager.default
        let applications = manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let target = applications.appendingPathComponent("KeyboardBridge.app", isDirectory: true)
        let staging = applications.appendingPathComponent(".KeyboardBridge.installing.app", isDirectory: true)

        do {
            try manager.createDirectory(at: applications, withIntermediateDirectories: true)
            if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
            try manager.copyItem(at: Bundle.main.bundleURL, to: staging)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.moveItem(at: staging, to: target)

            statusLabel.stringValue = "安装完成，正在从固定位置重新启动…"
            SafeLogger.shared.write("self_install_completed", fields: ["destination": "user_applications"])
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.statusLabel.stringValue = "安装完成，但自动启动失败：\(error.localizedDescription)"
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            statusLabel.stringValue = "安装失败：\(error.localizedDescription)"
            SafeLogger.shared.write("self_install_failed", fields: ["error": String(describing: type(of: error))])
            NSSound.beep()
        }
    }

    func pinWindowToFront() {
        guard let window else { return }
        guard !window.isMiniaturized else { return }
        window.level = .screenSaver
        window.orderFrontRegardless()
    }

    private func updatePreviewStatus(_ text: String) {
        let lines = text.reduce(into: 1) { count, c in if c == "\n" { count += 1 } }
        previewInfoLabel.stringValue = "\(text.count) 字符 · \(lines) 行"
        if !isTyping {
            statusLabel.stringValue = text.isEmpty ? "●  等待输入内容" : "●  内容已更新，等待确认"
        }
    }

    @objc private func startCountdown() {
        guard !isTyping else { return }
        let text = textView.string
        guard !text.isEmpty else {
            statusLabel.stringValue = "没有可输入的内容"
            NSSound.beep()
            return
        }
        guard text.count <= 100_000 else {
            statusLabel.stringValue = "内容超过 100,000 字符，已拒绝输入"
            NSSound.beep()
            return
        }
        let delay = boundedInteger(from: delayField, fallback: 10, range: 1...500)
        let countdownSeconds = boundedInteger(from: countdownField, fallback: 3, range: 1...30)
        if dryRunButton.state == .off && !canPostEvents() {
            refreshPermissionStatus()
            statusLabel.stringValue = "尚未获得输入权限；请点击“打开辅助功能设置”，授权后重启应用"
            NSSound.beep()
            return
        }

        cancellation.reset()
        isTyping = true
        isCountingDown = true
        setControlsEnabled(false)
        countdown = countdownSeconds
        startButton.title = "\(countdown) 秒后输入"
        statusLabel.stringValue = "请点击要输入的位置（\(countdown) 秒后输入）"
        pinWindowToFront()
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.cancellation.isCancelled() {
                timer.invalidate()
                self.finish(status: "已停止", event: "cancelled")
                return
            }
            self.countdown -= 1
            if self.countdown > 0 {
                self.startButton.title = "\(self.countdown) 秒后输入"
                self.statusLabel.stringValue = "请点击要输入的位置（\(self.countdown) 秒后输入）"
            } else {
                timer.invalidate()
                self.isCountingDown = false
                self.startButton.title = "正在输入…"
                self.performTyping(text: text, delayMilliseconds: delay)
            }
        }
    }

    private func performTyping(text: String, delayMilliseconds: Int) {
        let allowReturn = allowReturnButton.state == .on
        let dryRun = dryRunButton.state == .on
        let plan = TextPlan.make(text, allowReturn: allowReturn)
        let contentID = SafeLogger.shared.contentID(text)
        statusLabel.stringValue = dryRun ? "演练中…" : "输入中…（物理键码模式，⌥Esc 停止）"
        let started = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var sent = 0
            for unit in plan.units {
                if self.cancellation.isCancelled() { break }
                if !dryRun { self.emit(unit) }
                sent += unit.count
                let unitDelay = unit == "\n" ? max(delayMilliseconds, 150) : delayMilliseconds
                Thread.sleep(forTimeInterval: Double(unitDelay) / 1000.0)
            }
            let cancelled = self.cancellation.isCancelled()
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                self.finish(
                    status: cancelled ? "已停止（已处理 \(sent) 个字符）" : "完成（已处理 \(sent) 个字符）",
                    event: cancelled ? "typing_cancelled" : (dryRun ? "dry_run_completed" : "typing_completed"),
                    fields: [
                        "chars": "\(sent)", "content_id": contentID, "elapsed_ms": "\(elapsed)",
                        "newlines_replaced": "\(plan.replacedNewlines)", "input_mode": "physical_ascii"
                    ]
                )
            }
        }
    }

    private func emit(_ unit: String) {
        for character in unit {
            if character == "\n" {
                postPhysicalKey(PhysicalKey(keyCode: 36, shift: false))
            } else if let key = PhysicalKeyMapper.key(for: character) {
                postPhysicalKey(key)
            } else {
                emitUnicode(String(character))
            }
        }
    }

    private func emitUnicode(_ value: String) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        let utf16 = Array(value.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let address = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postPhysicalKey(_ key: PhysicalKey) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if key.shift,
           let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true) {
            shiftDown.flags = .maskShift
            shiftDown.post(tap: .cghidEventTap)
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: false) else { return }
        if key.shift {
            down.flags = .maskShift
            up.flags = .maskShift
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        if key.shift,
           let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) {
            shiftUp.post(tap: .cghidEventTap)
        }
    }

    @objc private func stopTyping() {
        guard isTyping else {
            statusLabel.stringValue = "当前没有正在进行的输入"
            return
        }
        cancellation.cancel()
        if isCountingDown {
            finish(status: "已停止", event: "typing_cancelled")
            return
        }
        statusLabel.stringValue = "正在停止…"
    }

    private func finish(status: String, event: String, fields: [String: String] = [:]) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isTyping = false
        isCountingDown = false
        setControlsEnabled(true)
        startButton.title = "\(boundedInteger(from: countdownField, fallback: 3, range: 1...30)) 秒后输入"
        statusLabel.stringValue = status
        SafeLogger.shared.write(event, fields: fields)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        startButton.isEnabled = enabled
        textView.isEditable = enabled
        delayField.isEnabled = enabled
        countdownField.isEnabled = enabled
        uiScalePopup.isEnabled = enabled
        allowReturnButton.isEnabled = enabled
        dryRunButton.isEnabled = enabled
        monitorCopyButton.isEnabled = enabled
        pasteButton.isEnabled = enabled
    }

    func textDidChange(_ notification: Notification) {
        if !isTyping { updatePreviewStatus(textView.string) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        updateResponsiveLayout()
    }

    deinit {
        if let globalStopMonitor { NSEvent.removeMonitor(globalStopMonitor) }
        if let localStopMonitor { NSEvent.removeMonitor(localStopMonitor) }
        if let globalCopyMonitor { NSEvent.removeMonitor(globalCopyMonitor) }
        if let localCopyMonitor { NSEvent.removeMonitor(localCopyMonitor) }
        permissionTimer?.invalidate()
        frontTimer?.invalidate()
    }
}

enum StatusBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let keyboard = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 2.1, width: 11.2, height: 7.2), xRadius: 1.6, yRadius: 1.6)
            keyboard.lineWidth = 1.35
            keyboard.stroke()

            for x in [3.0, 5.5, 8.0, 10.5] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 6.4, width: 1.25, height: 1.15), xRadius: 0.25, yRadius: 0.25).fill()
            }
            let space = NSBezierPath()
            space.move(to: NSPoint(x: 4.0, y: 4.2))
            space.line(to: NSPoint(x: 9.7, y: 4.2))
            space.lineWidth = 1.15
            space.lineCapStyle = .round
            space.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 6.0, y: 14.2))
            arrow.curve(
                to: NSPoint(x: 15.5, y: 10.0),
                controlPoint1: NSPoint(x: 10.0, y: 16.2),
                controlPoint2: NSPoint(x: 15.5, y: 15.0)
            )
            arrow.move(to: NSPoint(x: 12.7, y: 11.8))
            arrow.line(to: NSPoint(x: 15.5, y: 10.0))
            arrow.line(to: NSPoint(x: 15.7, y: 13.3))
            arrow.lineWidth = 1.55
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "键盘输入桥"
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMainMenu()
        controller = MainWindowController()
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        createStatusItem()
    }

    private func createMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "键盘输入桥", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "键盘输入桥")
        appMenu.addItem(NSMenuItem(
            title: "关于键盘输入桥",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "退出键盘输入桥",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.refreshPermissionStatus()
        controller?.pinWindowToFront()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusBarIcon.make()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "键盘输入桥"
        item.button?.setAccessibilityLabel("键盘输入桥")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示键盘输入桥", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showWindow() {
        controller?.window?.deminiaturize(nil)
        controller?.pinWindowToFront()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

func runSelfTests() -> Int32 {
    var failed = 0
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() { print("PASS \(name)") }
        else { print("FAIL \(name)"); failed += 1 }
    }
    let safe = TextPlan.make("echo a\nb\tc", allowReturn: false)
    expect(safe.units.joined() == "echo a b    c", "newline and tab safe normalization")
    expect(safe.replacedNewlines == 1, "newline count")
    let allowed = TextPlan.make("a\nb", allowReturn: true)
    expect(allowed.units.joined() == "a\nb", "allowed return preserved")
    expect(PhysicalKeyMapper.key(for: "a")?.keyCode == 0, "physical key mapping for a")
    expect(PhysicalKeyMapper.key(for: "p")?.keyCode == 35, "physical key mapping for p")
    expect(PhysicalKeyMapper.key(for: "A")?.shift == true, "uppercase uses shift")
    expect(PhysicalKeyMapper.key(for: ".")?.keyCode == 47, "physical key mapping for period")
    expect(PhysicalKeyMapper.key(for: "$")?.shift == true, "shell symbol uses shift")
    expect(UiScale.small.factor == 0.80, "small UI scale")
    expect(UiScale.medium.factor == 1.00, "medium UI scale")
    expect(UiScale.large.factor == 1.25, "large UI scale")
    expect(SafeLogger.shared.contentID("secret").count == 12, "redacted content id")
    print(failed == 0 ? "SELF-TEST OK" : "SELF-TEST FAILED: \(failed)")
    return failed == 0 ? 0 : 1
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTests())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Use the normal app policy so the app and its minimized window remain visible
// in the Dock. The menu-bar item is kept as a second recovery entry point.
application.setActivationPolicy(.regular)
application.run()


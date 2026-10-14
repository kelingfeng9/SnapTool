import AppKit
import ServiceManagement

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let preferences: Preferences
    private let hotKeyManager: HotKeyManager
    var onChanged: (() -> Void)?
    private let shortcutField = NSTextField()
    private let recordButton = NSButton(title: "录制", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let recognizePinned = NSButton(checkboxWithTitle: "截图时自动识别本工具的贴图窗口", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "登录 Mac 时启动", target: nil, action: nil)
    private let colorWell: SettingsColorWell
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "3 pt")
    private var recordingMonitor: Any?
    private var originalShortcutText = ""
    private var languageChoices: [(String, [String])] = [("自动识别", [])]

    init(preferences: Preferences, hotKeyManager: HotKeyManager) {
        self.preferences = preferences
        self.hotKeyManager = hotKeyManager
        colorWell = SettingsColorWell()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SnapTool 设置"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 460)
        let content = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        buildInterface(in: content)
        loadValues()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        // Bringing an existing window forward should preserve edits and active recording.
        if !window.isVisible && !window.isMiniaturized { loadValues() }
        if window.isMiniaturized { window.deminiaturize(sender) }
        if window.collectionBehavior.contains(.canJoinAllSpaces) {
            window.collectionBehavior.remove(.moveToActiveSpace)
        } else { window.collectionBehavior.insert(.moveToActiveSpace) }
        positionOnCurrentDisplay(window)
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(sender)
        window.contentView?.layoutSubtreeIfNeeded()
        synchronizeColorPanelLevel()
    }

    private func positionOnCurrentDisplay(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        if !screen.frame.intersects(frame) {
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        }
        frame.origin.x = frame.width <= visible.width ? min(max(frame.minX, visible.minX), visible.maxX - frame.width) : visible.minX
        frame.origin.y = frame.height <= visible.height ? min(max(frame.minY, visible.minY), visible.maxY - frame.height) : visible.maxY - frame.height
        window.setFrameOrigin(frame.origin)
    }

    private func buildInterface(in content: NSView) {
        // This is a fixed-size native utility window. Manual frames avoid building
        // constraints between controls before they share a view hierarchy.
        let heading = NSTextField(labelWithString: "快捷键与截图偏好")
        heading.font = .boldSystemFont(ofSize: 17)
        heading.frame = NSRect(x: 24, y: 424, width: 492, height: 24)
        content.addSubview(heading)
        addLabel("截图快捷键", frame: NSRect(x: 24, y: 382, width: 80, height: 24), to: content)
        shortcutField.placeholderString = "Ctrl+Option+A"
        shortcutField.identifier = NSUserInterfaceItemIdentifier("settings.shortcut")
        shortcutField.setAccessibilityLabel("全局截图快捷键")
        shortcutField.frame = NSRect(x: 110, y: 380, width: 240, height: 28)
        content.addSubview(shortcutField)
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.identifier = NSUserInterfaceItemIdentifier("settings.record")
        recordButton.frame = NSRect(x: 366, y: 380, width: 80, height: 28)
        content.addSubview(recordButton)
        let hint = NSTextField(wrappingLabelWithString: "可直接输入组合键，或点击录制。保存成功后新键立即生效；发生冲突时保留原键。至少包含 ⌃ / ⌥ / ⌘ 之一。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        hint.maximumNumberOfLines = 3
        hint.frame = NSRect(x: 24, y: 326, width: 492, height: 44)
        content.addSubview(hint)

        let supported = (try? OCRService.supportedLanguages()) ?? ["zh-Hans", "zh-Hant", "en-US"]
        let locale = Locale(identifier: "zh-Hans")
        languageChoices = [("自动识别", [])] + supported.map { (locale.localizedString(forIdentifier: $0) ?? $0, [$0]) }
        languagePopup.removeAllItems()
        languageChoices.forEach { languagePopup.addItem(withTitle: $0.0) }
        addLabel("识别语言", frame: NSRect(x: 24, y: 283, width: 80, height: 24), to: content)
        languagePopup.frame = NSRect(x: 110, y: 282, width: 292, height: 28)
        languagePopup.target = self
        languagePopup.action = #selector(markPendingChanges)
        content.addSubview(languagePopup)
        recognizePinned.target = self
        recognizePinned.action = #selector(markPendingChanges)
        recognizePinned.frame = NSRect(x: 24, y: 246, width: 492, height: 24)
        content.addSubview(recognizePinned)

        addLabel("默认颜色", frame: NSRect(x: 24, y: 208, width: 75, height: 24), to: content)
        colorWell.frame = NSRect(x: 105, y: 204, width: 48, height: 28)
        colorWell.target = self
        colorWell.action = #selector(markPendingChanges)
        content.addSubview(colorWell)
        addLabel("默认线宽", frame: NSRect(x: 170, y: 208, width: 75, height: 24), to: content)
        widthSlider.frame = NSRect(x: 245, y: 204, width: 200, height: 28)
        widthSlider.numberOfTickMarks = 24
        widthSlider.allowsTickMarkValuesOnly = true
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        content.addSubview(widthSlider)
        widthLabel.frame = NSRect(x: 454, y: 208, width: 55, height: 24)
        content.addSubview(widthLabel)

        loginToggle.target = self
        loginToggle.action = #selector(loginChanged)
        loginToggle.frame = NSRect(x: 24, y: 164, width: 240, height: 24)
        content.addSubview(loginToggle)
        let loginSettings = NSButton(title: "系统登录项…", target: self, action: #selector(openLoginSettings))
        loginSettings.frame = NSRect(x: 290, y: 160, width: 170, height: 28)
        content.addSubview(loginSettings)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("settings.status")
        statusLabel.maximumNumberOfLines = 3
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 24, y: 82, width: 492, height: 64)
        content.addSubview(statusLabel)
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.identifier = NSUserInterfaceItemIdentifier("settings.save")
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 360, y: 30, width: 156, height: 32)
        content.addSubview(save)
    }

    private func addLabel(_ title: String, frame: NSRect, to content: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.frame = frame
        content.addSubview(label)
    }

    private func loadValues() {
        stopRecording(restore: false)
        shortcutField.stringValue = preferences.hotkey.displayName
        if let selected = languageChoices.firstIndex(where: { $0.1 == preferences.ocrLanguages }) { languagePopup.selectItem(at: selected) }
        else { languagePopup.selectItem(at: 0) }
        recognizePinned.state = preferences.recognizePinnedWindows ? .on : .off
        colorWell.color = preferences.defaultColor
        widthSlider.doubleValue = Double(preferences.defaultLineWidth)
        widthChanged()
        refreshLoginState()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "当前生效：\(hotKeyManager.shortcut?.displayName ?? "尚未注册")。截图只在调取时读取屏幕。"
    }

    @objc private func toggleRecording() {
        if recordingMonitor != nil { stopRecording(restore: true); return }
        originalShortcutText = shortcutField.stringValue
        hotKeyManager.isSuspended = true
        // Carbon consumes the currently registered combination before a local keyDown monitor.
        hotKeyManager.onSuspendedTrigger = { [weak self] value in self?.acceptRecordedShortcut(value) }
        shortcutField.isEditable = false
        shortcutField.stringValue = "请按组合键（Esc 取消）"
        recordButton.title = "取消录制"
        window?.makeFirstResponder(nil)
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            if event.keyCode == 53 { self.stopRecording(restore: true); return nil }
            do {
                let value = try HotKeyShortcut(event: event)
                self.acceptRecordedShortcut(value)
            } catch {
                self.showStatus(error.localizedDescription, isError: true)
            }
            return nil
        }
    }

    private func stopRecording(restore: Bool) {
        if let monitor = recordingMonitor { NSEvent.removeMonitor(monitor) }
        if restore, recordingMonitor != nil { shortcutField.stringValue = originalShortcutText }
        recordingMonitor = nil
        hotKeyManager.onSuspendedTrigger = nil
        hotKeyManager.isSuspended = false
        shortcutField.isEditable = true
        recordButton.title = "录制"
    }

    private func acceptRecordedShortcut(_ value: HotKeyShortcut) {
        stopRecording(restore: false)
        shortcutField.stringValue = value.displayName
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "已录制 \(value.displayName)，点击保存后生效。"
    }

    @objc private func saveSettings() {
        guard recordingMonitor == nil else { showStatus("请先完成快捷键录制，或按 Esc 取消。", isError: true); return }
        do {
            let value = try HotKeyShortcut.parse(shortcutField.stringValue)
            try hotKeyManager.register(value)
            preferences.hotkey = value
            let index = languagePopup.indexOfSelectedItem
            preferences.ocrLanguages = languageChoices[max(0, min(index, languageChoices.count - 1))].1
            preferences.recognizePinnedWindows = recognizePinned.state == .on
            preferences.defaultColor = colorWell.color
            preferences.defaultLineWidth = CGFloat(widthSlider.doubleValue)
            shortcutField.stringValue = value.displayName
            showStatus("设置已保存，\(value.displayName) 立即生效。", isError: false)
            onChanged?()
        } catch { showStatus(error.localizedDescription, isError: true) }
    }

    @objc private func widthChanged() { widthLabel.stringValue = "\(Int(widthSlider.doubleValue)) pt" }
    @objc private func markPendingChanges() { showStatus("更改尚未保存，请点击“保存设置”应用。", isError: false) }

    @objc private func loginChanged() {
        do {
            if loginToggle.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginState()
            if SMAppService.mainApp.status == .requiresApproval {
                showStatus("登录启动需要在“系统设置 → 通用 → 登录项”中允许 SnapTool。", isError: false)
            } else { showStatus("登录启动设置已更新。", isError: false) }
        } catch {
            refreshLoginState()
            showStatus("无法更改登录启动：\(error.localizedDescription) 请将 SnapTool 放入“应用程序”后再试。", isError: true)
        }
    }

    private func refreshLoginState() {
        let status = SMAppService.mainApp.status
        loginToggle.state = (status == .enabled || status == .requiresApproval) ? .on : .off
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func showStatus(_ text: String, isError: Bool) { statusLabel.stringValue = text; statusLabel.toolTip = text; statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor }
    func synchronizeColorPanelLevel() { colorWell.synchronizePanelLevel() }
    func windowDidBecomeKey(_ notification: Notification) { refreshLoginState(); synchronizeColorPanelLevel() }
    func windowWillClose(_ notification: Notification) {
        stopRecording(restore: true)
        if colorWell.isActive {
            colorWell.deactivate()
            NSColorPanel.shared.orderOut(nil)
        }
    }
    deinit { if let monitor = recordingMonitor { NSEvent.removeMonitor(monitor) } }
}

/// Keeps the system color picker above an elevated settings window during capture.
private final class SettingsColorWell: NSColorWell {
    private var originalPanelLevel: NSWindow.Level?
    private var originalPanelBehavior: NSWindow.CollectionBehavior?

    override func activate(_ exclusive: Bool) {
        super.activate(exclusive)
        let panel = NSColorPanel.shared
        if originalPanelLevel == nil {
            originalPanelLevel = panel.level
            originalPanelBehavior = panel.collectionBehavior
        }
        synchronizePanelLevel()
    }

    func synchronizePanelLevel() {
        guard isActive, let window else { return }
        let panel = NSColorPanel.shared
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, window.level.rawValue + 1))
        panel.collectionBehavior = window.collectionBehavior.union(.fullScreenAuxiliary)
    }

    override func deactivate() {
        super.deactivate()
        // An inactive well has no panel state to restore; avoid creating a shared
        // native color panel as a side effect during initialization/cleanup.
        guard originalPanelLevel != nil || originalPanelBehavior != nil else { return }
        let panel = NSColorPanel.shared
        if let originalPanelLevel { panel.level = originalPanelLevel }
        if let originalPanelBehavior { panel.collectionBehavior = originalPanelBehavior }
        originalPanelLevel = nil
        originalPanelBehavior = nil
    }
}

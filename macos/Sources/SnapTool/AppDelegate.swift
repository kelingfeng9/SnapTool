import AppKit
import SnapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let hotKeys = HotKeyManager()
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController?
    private var captureWindow: CaptureSession?
    private var capturing = false
    private var delayTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var pins: [ObjectIdentifier: PinWindow] = [:]
    private var textWindows: [NSWindow] = []
    private var textWindowObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var lastFrontApplication: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--documentation-snapshots"), CommandLine.arguments.count > index + 1 {
            Task {
                do {
                    try await DocumentationSnapshots.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
                    NSApp.terminate(nil)
                } catch {
                    FileHandle.standardError.write(Data("Native documentation rendering failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return
        }
        configureApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SnapTool")
        statusItem.button?.image?.isTemplate = true
        hotKeys.onTrigger = { [weak self] in self?.beginCapture() }
        do { try hotKeys.register(preferences.hotkey) }
        catch {
            if CommandLine.arguments.contains("--smoke-test") {
                FileHandle.standardError.write(Data("Global hot key registration failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            showError("快捷键注册失败，可从菜单栏开始截图或修改快捷键。", error)
        }
        rebuildMenu()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveCaptureRequest(_:)),
            name: Notification.Name("com.kelingfeng9.SnapTool.capture"), object: nil)
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        } else if CommandLine.arguments.contains("--capture") {
            beginCapture()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        beginCapture()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        delayTask?.cancel()
        ocrTask?.cancel()
        captureTask?.cancel()
        captureWindow?.close()
        DistributedNotificationCenter.default().removeObserver(self)
        hotKeys.unregister()
    }

    private func configureApplicationMenu() {
        let root = NSMenu()
        let appEntry = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 SnapTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appEntry.submenu = appMenu
        root.addItem(appEntry)
        let editEntry = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.insertItem(redo, at: 1)
        editEntry.submenu = edit
        root.addItem(editEntry)
        NSApp.mainMenu = root
    }

    private func menuItem(_ title: String, action: Selector?, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem("开始截图  \(preferences.hotkey.displayName)", action: #selector(captureNow)))
        let delay = menuItem("延迟截图", action: nil)
        let delays = NSMenu()
        for seconds in [3, 5, 10] { delays.addItem(menuItem("\(seconds) 秒", action: #selector(captureDelayed(_:)), tag: seconds)) }
        delay.submenu = delays
        menu.addItem(delay)
        menu.addItem(.separator())
        menu.addItem(menuItem("快捷键与设置…", action: #selector(openSettings)))
        let pinRecognition = menuItem("截图时识别贴图窗口", action: #selector(togglePinRecognition))
        pinRecognition.state = preferences.recognizePinnedWindows ? .on : .off
        menu.addItem(pinRecognition)
        let language = menuItem("OCR 语言", action: nil)
        let languages = NSMenu()
        let auto = menuItem("自动（中文 / 英文）", action: #selector(selectOCRLanguage(_:)))
        auto.representedObject = ""
        auto.state = preferences.ocrLanguages.isEmpty ? .on : .off
        languages.addItem(auto)
        let supported = (try? OCRService.supportedLanguages()) ?? ["zh-Hans", "en-US"]
        for code in supported {
            let name = Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
            let item = menuItem(name, action: #selector(selectOCRLanguage(_:)))
            item.representedObject = code
            item.state = preferences.ocrLanguages == [code] ? .on : .off
            languages.addItem(item)
        }
        language.submenu = languages
        menu.addItem(language)
        if !textWindows.isEmpty {
            let results = menuItem("OCR 识别结果（\(textWindows.count)）", action: nil)
            let resultMenu = NSMenu()
            for (index, window) in textWindows.enumerated().reversed() {
                let item = menuItem("识别结果 \(index + 1)\(window.isMiniaturized ? "（已最小化）" : "")", action: #selector(reopenOCRResult(_:)))
                item.representedObject = window
                resultMenu.addItem(item)
            }
            results.submenu = resultMenu
            menu.addItem(results)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("关于 SnapTool", action: #selector(showAbout)))
        menu.addItem(menuItem("退出", action: #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.toolTip = "SnapTool · \(preferences.hotkey.displayName)"
    }

    @objc private func captureNow() { beginCapture() }
    @objc private func receiveCaptureRequest(_ notification: Notification) { beginCapture() }
    @objc private func captureDelayed(_ sender: NSMenuItem) { beginCapture(delay: sender.tag) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "SnapTool for Mac \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1")"
        alert.informativeText = "轻量菜单栏截图工具\n原生截图、标注、贴图与本地 OCR\n支持 Apple 芯片 · macOS 14 及更新版本"
        presentAlert(alert)
    }
    @objc private func togglePinRecognition() {
        preferences.recognizePinnedWindows.toggle()
        rebuildMenu()
    }
    @objc private func selectOCRLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String ?? ""
        preferences.ocrLanguages = code.isEmpty ? [] : [code]
        rebuildMenu()
    }
    @objc private func openSettings() {
        if settings == nil {
            let controller = SettingsWindowController(preferences: preferences, hotKeyManager: hotKeys)
            controller.onChanged = { [weak self] in self?.rebuildMenu() }
            settings = controller
        }
        if let window = settings?.window { configureAuxiliaryWindow(window) }
        settings?.synchronizeColorPanelLevel()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func beginCapture(delay: Int = 0) {
        delayTask?.cancel()
        delayTask = nil
        if let window = captureWindow { window.makeKeyAndOrderFront(nil); return }
        guard !capturing else { return }
        lastFrontApplication = NSWorkspace.shared.frontmostApplication
        if delay > 0 {
            delayTask = Task { [weak self] in
                guard let self else { return }
                for remaining in stride(from: delay, through: 1, by: -1) {
                    if Task.isCancelled { self.restoreStatusIcon(); return }
                    self.statusItem.button?.image = nil
                    self.statusItem.button?.title = "\(remaining)"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                self.restoreStatusIcon()
                if !Task.isCancelled { self.beginCapture() }
            }
            return
        }
        capturing = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.capturing = false; self.captureTask = nil }
            do {
                let captured = try await CaptureService.capture()
                let pinIDs = PinWindow.activeWindowIDs
                let windows = self.preferences.recognizePinnedWindows ? captured.windows
                    : captured.windows.filter { !pinIDs.contains($0.id) }
                let capture = DesktopCapture(image: captured.image, frame: captured.frame, scale: captured.scale, windows: windows)
                self.presentCapture(capture)
            } catch is CancellationError { return }
            catch { self.showError("无法开始截图", error) }
        }
    }

    func presentCapture(_ capture: DesktopCapture) {
        let window = CaptureSession(capture: capture, preferences: preferences)
        window.onDisplaysChanged = { [weak self] in
            self?.finishCapture()
            self?.showError("显示器配置发生变化，请重新截图", CaptureServiceError.unavailableDisplay)
        }
        window.canvas.onClose = { [weak self] in self?.finishCapture() }
        window.canvas.onSettings = { [weak self] in self?.openSettings() }
        window.canvas.onPin = { [weak self] image in self?.openPin(image) }
        window.canvas.onOCR = { [weak self] image in self?.recognize(image) }
        captureWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(window.canvas)
    }

    private func restoreStatusIcon() {
        statusItem.button?.title = ""
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SnapTool")
        statusItem.button?.image?.isTemplate = true
    }

    private func finishCapture() {
        captureWindow?.orderOut(nil)
        captureWindow?.close()
        captureWindow = nil
        if let window = settings?.window { configureAuxiliaryWindow(window) }
        settings?.synchronizeColorPanelLevel()
        textWindows.forEach(configureAuxiliaryWindow)
        lastFrontApplication?.activate(options: [])
    }

    private func openPin(_ image: CGImage) {
        let pin = PinWindow(image: image)
        let id = ObjectIdentifier(pin)
        pins[id] = pin
        pin.onClose = { [weak self] in self?.pins.removeValue(forKey: id) }
        pin.showWindow(nil)
        finishCapture()
    }

    private func recognize(_ image: CGImage) {
        guard ocrTask == nil else { captureWindow?.canvas.showToast("正在识别，请稍候"); return }
        captureWindow?.canvas.showToast("正在本地识别文字…")
        let languages = preferences.ocrLanguages
        ocrTask = Task { [weak self] in
            guard let self else { return }
            defer { self.ocrTask = nil }
            do {
                let text = try await OCRService.recognize(image: image, languages: languages)
                self.showRecognizedText(text)
            } catch is CancellationError {
                return
            } catch { self.showError("文字识别失败", error) }
        }
    }

    private func showRecognizedText(_ text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SnapTool · 识别结果"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 54, width: 536, height: 294))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.font = .systemFont(ofSize: 16)
        editor.string = text.isEmpty ? "未识别到文字，请尝试更清晰的选区。" : text
        scroll.documentView = editor
        let copy = OCRCopyButton(title: "复制全部", target: self, action: #selector(copyOCRText(_:)))
        copy.frame = NSRect(x: 436, y: 12, width: 110, height: 30)
        copy.autoresizingMask = [.minXMargin]
        copy.textView = editor
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(copy)
        textWindows.append(window)
        let windowID = ObjectIdentifier(window)
        textWindowObservers[windowID] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
            // NotificationCenter's explicit main queue provides the executor guarantee here.
            MainActor.assumeIsolated {
                guard let window, let self else { return }
                self.textWindows.removeAll { $0 === window }
                if let token = self.textWindowObservers.removeValue(forKey: windowID) { NotificationCenter.default.removeObserver(token) }
                self.rebuildMenu()
            }
        }
        configureAuxiliaryWindow(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        rebuildMenu()
    }

    @objc private func reopenOCRResult(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow,
              textWindows.contains(where: { $0 === window }) else { return }
        configureAuxiliaryWindow(window)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        rebuildMenu()
    }

    private func configureAuxiliaryWindow(_ window: NSWindow) {
        if let parent = captureWindow?.activeWindow {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .above)
            window.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let area = parent.frame
            window.setFrameOrigin(CGPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        } else {
            window.parent?.removeChildWindow(window)
            window.level = .normal
            window.collectionBehavior = []
        }
    }

    @objc private func copyOCRText(_ sender: OCRCopyButton) {
        guard let editor = sender.textView else { return }
        OutputService.copyText(editor.string)
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        presentAlert(alert)
    }

    private func presentAlert(_ alert: NSAlert) {
        if let parent = captureWindow?.activeWindow {
            alert.beginSheetModal(for: parent)
        } else {
            alert.runModal()
        }
    }
}

private final class OCRCopyButton: NSButton {
    weak var textView: NSTextView?
}

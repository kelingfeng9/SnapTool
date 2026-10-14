import AppKit
import CoreGraphics

@MainActor
final class PinWindow: NSWindowController, NSWindowDelegate {
    private final class WeakPin {
        weak var value: PinWindow?
        init(_ value: PinWindow) { self.value = value }
    }
    private static var registry: [CGWindowID: WeakPin] = [:]
    static var activeWindowIDs: Set<CGWindowID> {
        Set(registry.compactMap { $0.value.value?.window?.isVisible == true ? $0.key : nil })
    }
    static var activeFrames: [CGWindowID: NSRect] {
        registry.reduce(into: [:]) { result, entry in
            if let window = entry.value.value?.window, window.isVisible { result[entry.key] = window.frame }
        }
    }

    let image: CGImage
    var onClose: (() -> Void)?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var saveTask: Task<Void, Never>?
    private var dragging = false
    private var topmost = true
    private var baseSize: NSSize

    init(image: CGImage, initialFrame: NSRect? = nil) {
        self.image = image
        let screen = NSScreen.main ?? NSScreen.screens.first
        let imageSize = NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let backing = screen?.backingScaleFactor ?? 2
        let natural = NSSize(width: imageSize.width / backing, height: imageSize.height / backing)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let factor = min(1, min(visible.width * 0.75 / natural.width, visible.height * 0.75 / natural.height))
        let size = NSSize(width: max(1, natural.width * factor), height: max(1, natural.height * factor))
        let frame = initialFrame ?? NSRect(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2,
                                          width: size.width, height: size.height)
        baseSize = frame.size
        let panel = PinPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.title = "SnapTool 贴图"
        panel.acceptsMouseMovedEvents = true
        super.init(window: panel)
        panel.delegate = self
        let view = PinImageView(image: image)
        view.owner = self
        panel.contentView = view
        panel.setFrame(frame, display: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        window.makeKeyAndOrderFront(sender)
        if let view = window.contentView { window.makeFirstResponder(view) }
        Self.registry[CGWindowID(window.windowNumber)] = WeakPin(self)
        installMouseMonitors()
        updateClickThrough()
    }

    func windowWillClose(_ notification: Notification) {
        saveTask?.cancel()
        if let window { Self.registry.removeValue(forKey: CGWindowID(window.windowNumber)) }
        removeMouseMonitors()
        onClose?()
    }

    private func installMouseMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateClickThrough()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateClickThrough()
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    private func updateClickThrough() {
        guard !dragging, let window, let view = window.contentView as? PinImageView else { return }
        let global = NSEvent.mouseLocation
        guard window.frame.contains(global) else {
            window.ignoresMouseEvents = false
            return
        }
        let local = view.convert(window.convertPoint(fromScreen: global), from: nil)
        window.ignoresMouseEvents = !view.hasOpaquePixel(at: local)
    }

    fileprivate func beginDrag() {
        dragging = true
        window?.ignoresMouseEvents = false
    }

    fileprivate func endDrag() {
        dragging = false
        updateClickThrough()
    }

    fileprivate func scroll(_ event: NSEvent) {
        guard let window else { return }
        if event.modifierFlags.contains(.shift) {
            window.alphaValue = max(0.15, min(1, window.alphaValue + event.scrollingDeltaY * 0.015))
            return
        }
        let old = window.frame
        let factor = exp(max(-10, min(10, event.scrollingDeltaY)) * 0.035)
        let width = old.width * factor
        let minimumScale = max(24 / baseSize.width, 24 / baseSize.height)
        let scale = max(minimumScale, min(8, width / baseSize.width))
        let size = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
        let mouse = NSEvent.mouseLocation
        let anchorX = max(0, min(1, (mouse.x - old.minX) / old.width))
        let anchorY = max(0, min(1, (mouse.y - old.minY) / old.height))
        window.setFrame(NSRect(x: mouse.x - anchorX * size.width,
                               y: mouse.y - anchorY * size.height,
                               width: size.width, height: size.height), display: true)
        updateClickThrough()
    }

    @objc fileprivate func copyImage(_ sender: Any?) {
        do { try OutputService.copy(image) } catch { showError(error) }
    }

    @objc fileprivate func saveImage(_ sender: Any?) {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.saveTask = nil }
            do { _ = try await OutputService.save(self.image, parent: self.window) }
            catch is CancellationError { return }
            catch { self.showError(error) }
        }
    }

    @objc fileprivate func toggleTopmost(_ sender: Any?) {
        topmost.toggle()
        window?.level = topmost ? .floating : .normal
    }

    @objc fileprivate func resetSize(_ sender: Any?) {
        guard let window else { return }
        let frame = window.frame
        window.setFrame(NSRect(x: frame.midX - baseSize.width / 2,
                               y: frame.midY - baseSize.height / 2,
                               width: baseSize.width, height: baseSize.height), display: true)
        window.alphaValue = 1
        updateClickThrough()
    }

    @objc fileprivate func closePin(_ sender: Any?) { close() }

    fileprivate func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items: [(String, Selector, String)] = [
            ("复制图片", #selector(copyImage(_:)), "c"),
            ("另存为…", #selector(saveImage(_:)), "s"),
            ("置顶", #selector(toggleTopmost(_:)), "t"),
            ("恢复大小与透明度", #selector(resetSize(_:)), "0")
        ]
        for (title, action, key) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            if action == #selector(saveImage(_:)) { item.isEnabled = saveTask == nil }
            if action == #selector(toggleTopmost(_:)) {
                item.state = topmost ? .on : .off
                item.keyEquivalentModifierMask = []
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭贴图", action: #selector(closePin(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window, window.isVisible { alert.beginSheetModal(for: window) }
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class PinImageView: NSView {
    weak var owner: PinWindow?
    private let image: NSImage
    private let mask: [UInt8]
    private let maskWidth: Int
    private let maskHeight: Int
    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image source: CGImage) {
        image = NSImage(cgImage: source, size: NSSize(width: CGFloat(source.width), height: CGFloat(source.height)))
        let factor = min(1, 512 / CGFloat(max(source.width, source.height)))
        maskWidth = max(1, Int(CGFloat(source.width) * factor))
        maskHeight = max(1, Int(CGFloat(source.height) * factor))
        let count = maskWidth * maskHeight
        if let context = CGContext(data: nil, width: maskWidth, height: maskHeight,
                                   bitsPerComponent: 8, bytesPerRow: maskWidth * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) {
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(maskWidth), height: CGFloat(maskHeight)))
            if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
                mask = (0..<count).map { pixels[$0 * 4 + 3] }
            } else { mask = Array(repeating: 255, count: count) }
        } else { mask = Array(repeating: 255, count: count) }
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }

    func hasOpaquePixel(at point: NSPoint) -> Bool {
        guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return false }
        let x = min(maskWidth - 1, max(0, Int(point.x / bounds.width * CGFloat(maskWidth))))
        let y = min(maskHeight - 1, max(0, Int(point.y / bounds.height * CGFloat(maskHeight))))
        return mask[y * maskWidth + x] > 12
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.close(); return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin
        owner?.beginDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let windowOrigin else { return }
        let point = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: windowOrigin.x + point.x - dragOrigin.x,
                                       y: windowOrigin.y + point.y - dragOrigin.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        windowOrigin = nil
        owner?.endDrag()
    }

    override func scrollWheel(with event: NSEvent) { owner?.scroll(event) }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.contextMenu() }
    @objc func copy(_ sender: Any?) { owner?.copyImage(sender) }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { owner?.close(); return }
        if characters == "c", event.modifierFlags.contains(.command) { owner?.copyImage(nil); return }
        if characters == "s", event.modifierFlags.contains(.command) { owner?.saveImage(nil); return }
        if characters == "t", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            owner?.toggleTopmost(nil); return
        }
        if characters == "0", event.modifierFlags.contains(.command) { owner?.resetSize(nil); return }
        super.keyDown(with: event)
    }
}

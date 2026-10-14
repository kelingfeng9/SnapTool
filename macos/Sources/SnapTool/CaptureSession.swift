import AppKit
import SnapCore

/// One native window per display, sharing one bitmap, renderer, undo history
/// and editor. Only the active display hosts the editor's controls; other
/// viewports draw the same desktop coordinates and forward pointer events.
@MainActor
final class CaptureSession {
    let canvas: CaptureCanvas
    let geometry: DesktopGeometry
    private(set) var windows: [CaptureWindow] = []
    private(set) var activeWindow: CaptureWindow?
    private var screenObserver: NSObjectProtocol?
    private let originalDisplayFrames: [CGRect]
    var onDisplaysChanged: (() -> Void)?
    var level: NSWindow.Level { activeWindow?.level ?? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) }

    init(capture: DesktopCapture, preferences: Preferences, displayFrames: [CGRect]? = nil) {
        geometry = DesktopGeometry(frame: capture.frame)
        canvas = CaptureCanvas(capture: capture, preferences: preferences)
        let frames = displayFrames ?? NSScreen.screens.map(\.frame)
        originalDisplayFrames = frames
        for frame in frames where frame.intersects(capture.frame) {
            let viewport = geometry.viewport(for: frame).intersection(geometry.bounds)
            let window = CaptureWindow(frame: geometry.appKitRect(fromDesktop: viewport),
                                       viewport: viewport, canvas: canvas)
            window.viewport.session = self
            windows.append(window)
        }
        canvas.onInvalidate = { [weak self] rect in
            guard let self else { return }
            for window in self.windows where self.canvas.superview !== window.viewport {
                window.viewport.invalidate(desktopRect: rect)
            }
        }
        canvas.onActivateAtPoint = { [weak self] point in self?.activate(at: point) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, NSScreen.screens.map(\.frame) != self.originalDisplayFrames else { return }
                    self.onDisplaysChanged?()
                }
            }
    }

    func makeKeyAndOrderFront(_ sender: Any?) {
        windows.forEach { $0.orderFrontRegardless() }
        let point = geometry.desktopPoint(fromAppKit: NSEvent.mouseLocation)
        activate(at: point, commitEditing: true)
        activeWindow?.makeKeyAndOrderFront(sender)
    }

    func activate(at point: CGPoint, commitEditing: Bool = false) {
        guard let next = windows.first(where: { $0.viewport.desktopViewport.contains(point) }) ?? activeWindow ?? windows.first else { return }
        guard next !== activeWindow || canvas.superview !== next.viewport else { return }
        if canvas.isEditingText && !commitEditing { return }
        canvas.prepareToSwitchDisplay()
        canvas.removeFromSuperview()
        activeWindow = next
        canvas.frame = CGRect(x: -next.viewport.desktopViewport.minX, y: -next.viewport.desktopViewport.minY,
                              width: geometry.bounds.width, height: geometry.bounds.height)
        next.viewport.addSubview(canvas)
        canvas.activeViewport = next.viewport.desktopViewport
        next.makeKeyAndOrderFront(nil)
        next.makeFirstResponder(canvas)
        windows.forEach { $0.viewport.needsDisplay = true }
    }

    @discardableResult
    func makeFirstResponder(_ responder: NSResponder?) -> Bool { activeWindow?.makeFirstResponder(responder) ?? false }
    func orderOut(_ sender: Any?) { windows.forEach { $0.orderOut(sender) } }

    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        canvas.endSession()
        for window in windows {
            for child in window.childWindows ?? [] { window.removeChildWindow(child) }
            window.orderOut(nil)
            window.close()
        }
        activeWindow = nil
        canvas.removeFromSuperview()
        windows.removeAll()
    }
}

final class CaptureWindow: NSWindow {
    let viewport: CaptureViewport
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(frame: CGRect, viewport: CGRect, canvas: CaptureCanvas) {
        self.viewport = CaptureViewport(viewport: viewport, canvas: canvas)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        title = "SnapTool 截图"
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = self.viewport
        setFrame(frame, display: false)
    }
}

final class CaptureViewport: NSView {
    let desktopViewport: CGRect
    let canvas: CaptureCanvas
    weak var session: CaptureSession?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(viewport: CGRect, canvas: CaptureCanvas) {
        desktopViewport = viewport
        self.canvas = canvas
        super.init(frame: CGRect(origin: .zero, size: viewport.size))
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard canvas.superview !== self, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: -desktopViewport.minX, y: -desktopViewport.minY)
        canvas.draw(dirtyRect.offsetBy(dx: desktopViewport.minX, dy: desktopViewport.minY))
        context.restoreGState()
    }
    func invalidate(desktopRect: CGRect) {
        let dirty = desktopRect.intersection(desktopViewport)
        if !dirty.isNull { setNeedsDisplay(dirty.offsetBy(dx: -desktopViewport.minX, dy: -desktopViewport.minY)) }
    }
    private func activate(for event: NSEvent) {
        let global = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let point = canvas.geometry.desktopPoint(fromAppKit: global)
        session?.activate(at: point, commitEditing: true)
    }
    override func mouseMoved(with event: NSEvent) { canvas.mouseMoved(with: event) }
    override func mouseDown(with event: NSEvent) { activate(for: event); canvas.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { canvas.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { canvas.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { activate(for: event); canvas.rightMouseDown(with: event) }
    override func scrollWheel(with event: NSEvent) { activate(for: event); canvas.scrollWheel(with: event) }
    override func keyDown(with event: NSEvent) { canvas.keyDown(with: event) }
    @objc func copy(_ sender: Any?) { canvas.copy(sender) }
    @objc func undo(_ sender: Any?) { canvas.undo(sender) }
    @objc func redo(_ sender: Any?) { canvas.redo(sender) }
}

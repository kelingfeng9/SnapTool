import AppKit
import SnapCore

final class CaptureWindow: NSWindow {
    let canvas: CaptureCanvas
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(capture: DesktopCapture, preferences: Preferences) {
        canvas = CaptureCanvas(capture: capture, preferences: preferences)
        super.init(contentRect: capture.frame, styleMask: .borderless, backing: .buffered, defer: false)
        title = "SnapTool 截图"
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = canvas
    }
}

private final class FlowToolbar: NSView {
    var items: [NSView] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    func arrange(width: CGFloat) -> CGFloat {
        let width = max(160, width)
        var x: CGFloat = 8, y: CGFloat = 6
        for item in items {
            let size = item.frame.size
            if x + size.width + 8 > width && x > 8 { x = 8; y += 32 }
            item.frame.origin = NSPoint(x: x, y: y)
            x += size.width + 3
        }
        frame.size = NSSize(width: width, height: y + 34)
        return frame.height
    }
    func append(_ view: NSView) { items.append(view); addSubview(view) }
}

final class CaptureCanvas: NSView, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPin: ((CGImage) -> Void)?
    var onOCR: ((CGImage) -> Void)?
    private let capture: DesktopCapture
    private let preferences: Preferences
    private let background: NSImage
    private let renderer: AnnotationRenderer
    private let store = AnnotationStore()
    private let shapeBar = FlowToolbar()
    private let annotationBar = FlowToolbar()
    private var shapeButtons: [NSButton] = []
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private let fillButton = NSButton(checkboxWithTitle: "实心", target: nil, action: nil)
    private let doubleArrowButton = NSButton(checkboxWithTitle: "双向", target: nil, action: nil)
    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white, .black]
    private var shape: CaptureShape = .rectangle
    private var tool: AnnotationTool = .rectangle
    private var selection: CGRect = .zero
    private var polygon: [CGPoint] = []
    private var polygonClosed = false
    private var annotating = false
    private var hover: WindowTarget?
    private var pointer: CGPoint = .zero
    private var anchor: CGPoint = .zero
    private var selecting = false
    private var movingCrop = false
    private var resizeHandle: SelectionHandle?
    private var originalSelection: CGRect = .zero
    private var originalPolygon: [CGPoint] = []
    private var current: Annotation?
    private var selectedID: UUID?
    private var movingMark: Annotation?
    private var moveDelta: CGPoint = .zero
    private var color: RGBAColor
    private var lineWidth: CGFloat
    private var fontSize: CGFloat = 24
    private var mosaicBlock = 12
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var toast: String?
    private var toastTimer: Timer?
    private var lastStamp: (id: UUID, point: CGPoint, tool: AnnotationTool, time: TimeInterval)?
    private var tracking: NSTrackingArea?
    private var outputBusy = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var polygonDraft: Bool { shape == .polygon && !polygonClosed }
    private var hasSelection: Bool { selection.width > 2 && selection.height > 2 && !polygonDraft }
    private var selected: Annotation? { store.items.first { $0.id == selectedID } }

    init(capture: DesktopCapture, preferences: Preferences) {
        self.capture = capture
        self.preferences = preferences
        background = NSImage(cgImage: capture.image, size: capture.frame.size)
        renderer = AnnotationRenderer(desktop: capture.image, pixelScale: capture.scale)
        let nsColor = preferences.defaultColor.usingColorSpace(.sRGB) ?? .systemRed
        color = RGBAColor(red: nsColor.redComponent, green: nsColor.greenComponent, blue: nsColor.blueComponent)
        lineWidth = preferences.defaultLineWidth
        super.init(frame: NSRect(origin: .zero, size: capture.frame.size))
        let mouse = NSEvent.mouseLocation
        pointer = CGPoint(x: min(bounds.width, max(0, mouse.x - capture.frame.minX)),
                          y: min(bounds.height, max(0, capture.frame.maxY - mouse.y)))
        hover = capture.windows.first { $0.rect.contains(pointer) }
        buildToolbars()
        addSubview(shapeBar)
        addSubview(annotationBar)
        annotationBar.isHidden = true
        layoutToolbars()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { toastTimer?.invalidate() }

    private func button(_ title: String, width: CGFloat = 55, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame.size = NSSize(width: width, height: 28)
        button.font = .systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        return button
    }
    private func label(_ title: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.frame.size = NSSize(width: width, height: 26)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        return label
    }
    private func buildToolbars() {
        shapeBar.append(label("截图形状", width: 60))
        for (index, title) in ["矩形", "圆形", "三角形"].enumerated() {
            let item = button(title, action: #selector(selectShape(_:)))
            item.tag = index
            shapeButtons.append(item)
            shapeBar.append(item)
        }
        let polygons = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 105, height: 28), pullsDown: true)
        polygons.addItems(withTitles: ["多边形", "五边形", "六边形", "自由多边形"])
        for (index, item) in polygons.itemArray.enumerated() { item.tag = index + 2 }
        polygons.target = self
        polygons.action = #selector(selectPolygon(_:))
        shapeBar.append(polygons)
        shapeBar.append(button("调整选区", width: 75, action: #selector(adjustCrop)))
        shapeBar.append(button("快捷键设置", width: 90, action: #selector(settingsClicked)))

        annotationBar.append(label("标注", width: 32))
        for (index, value) in AnnotationTool.allCases.enumerated() {
            let item = button(value.title, width: 50, action: #selector(selectTool(_:)))
            item.tag = index
            item.toolTip = "\(index == 9 ? 0 : index + 1) · \(value.title)；Shift 约束图形比例或线段角度"
            toolButtons.append(item)
            annotationBar.append(item)
        }
        for item in [fillButton, doubleArrowButton] {
            item.frame.size = NSSize(width: 53, height: 28)
            item.target = self
            item.action = #selector(changeStyle)
            annotationBar.append(item)
        }
        for (index, nsColor) in palette.enumerated() {
            let item = button("●", width: 24, action: #selector(selectColor(_:)))
            item.contentTintColor = nsColor
            item.tag = index
            colorButtons.append(item)
            annotationBar.append(item)
        }
        for (title, action) in [("撤销", #selector(undo(_:))), ("重做", #selector(redo(_:))),
                                ("复制", #selector(copy(_:))), ("保存", #selector(saveScreenshot)),
                                ("快存", #selector(quickSave)), ("贴图", #selector(pin)),
                                ("OCR", #selector(ocr)), ("重选", #selector(reselect)), ("取消", #selector(cancel))] {
            annotationBar.append(button(title, action: action))
        }
        updateTools()
    }

    override func layout() { super.layout(); layoutToolbars() }
    private func layoutToolbars() {
        let screenPoint = NSPoint(x: capture.frame.minX + pointer.x, y: capture.frame.maxY - pointer.y)
        let display = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? NSScreen.main
        let global = display?.visibleFrame ?? capture.frame
        let area = CGRect(x: global.minX - capture.frame.minX, y: capture.frame.maxY - global.maxY,
                          width: global.width, height: global.height).intersection(bounds)
        let width = max(160, min(720, area.width - 16))
        _ = shapeBar.arrange(width: width)
        shapeBar.frame.origin = CGPoint(x: max(4, area.midX - width / 2), y: max(4, area.minY + 8))
        let annotationWidth = max(160, min(1250, area.width - 16))
        _ = annotationBar.arrange(width: annotationWidth)
        var y = selection.maxY + 8
        if y + annotationBar.frame.height > area.maxY { y = selection.minY - annotationBar.frame.height - 8 }
        y = max(area.minY + 4, min(y, area.maxY - annotationBar.frame.height - 4))
        let x = max(area.minX + 4, min(selection.minX, area.maxX - annotationWidth - 4))
        if shapeBar.frame.intersects(CGRect(x: x, y: y, width: annotationWidth, height: annotationBar.frame.height)) {
            y = min(area.maxY - annotationBar.frame.height - 4, shapeBar.frame.maxY + 8)
        }
        annotationBar.frame.origin = CGPoint(x: x, y: max(4, y))
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()
        if hasSelection || selecting {
            let crop = ShapeGeometry.path(shape: shape, in: selection, vertices: polygon)
            context.saveGState()
            context.addPath(crop)
            context.clip()
            background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            renderer.drawAnnotations(in: context, annotations: previewItems(),
                                     transientIDs: Set([current?.id, movingMark?.id].compactMap { $0 }))
            context.restoreGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.addPath(crop)
            context.strokePath()
            if !annotating { drawCropHandles(context) }
            if let item = selected {
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineDash(phase: 0, lengths: [4, 3])
                context.stroke(AnnotationGeometry.bounds(of: item).offsetBy(dx: moveDelta.x, dy: moveDelta.y))
                context.setLineDash(phase: 0, lengths: [])
            }
        } else if let hover, !polygonDraft {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2)
            context.stroke(hover.rect)
            drawText(hover.title, at: CGPoint(x: hover.rect.minX + 4, y: max(75, hover.rect.minY - 23)), color: .white)
        }
        if polygonDraft, !polygon.isEmpty {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2)
            context.move(to: polygon[0])
            polygon.dropFirst().forEach { context.addLine(to: $0) }
            context.addLine(to: pointer)
            context.strokePath()
            for point in polygon { context.fillEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)) }
        }
        drawPixelHUD(context)
        if let toast { drawToast(toast) }
        else if !hasSelection { drawToast(polygonDraft ? "逐点单击 · 双击 / Enter 闭合 · 右键 / 退格撤点" : "拖动框选 · 单击选择窗口 · Esc 取消 · C 复制颜色") }
        else if !annotating { drawToast("拖动调整选区 · 下方“标注”画矩形 / 圆形 / 箭头 · Enter 复制") }
    }

    private func drawCropHandles(_ context: CGContext) {
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        for point in cropHandles() {
            let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fill(rect); context.stroke(rect)
        }
    }
    private func cropHandles() -> [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY),
         CGPoint(x: selection.midX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.midY),
         CGPoint(x: selection.midX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.midY)]
    }
    private func cropHandle(at point: CGPoint) -> SelectionHandle? {
        if let index = cropHandles().firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 10 }) {
            return SelectionHandle.allCases[index]
        }
        guard selection.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        if abs(point.y - selection.minY) < 8 { return .top }
        if abs(point.x - selection.maxX) < 8 { return .right }
        if abs(point.y - selection.maxY) < 8 { return .bottom }
        if abs(point.x - selection.minX) < 8 { return .left }
        return nil
    }
    private func drawText(_ text: String, at point: CGPoint, color: NSColor, size: CGFloat = 13) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }
    private func drawToast(_ message: String) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
        let size = (message as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: max(8, shapeBar.frame.midX - size.width / 2), y: max(75, shapeBar.frame.maxY + 8), width: size.width + 22, height: 30)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (message as NSString).draw(at: CGPoint(x: rect.minX + 11, y: rect.minY + 6), withAttributes: attributes)
    }
    func showToast(_ text: String) {
        toast = text
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            self?.toast = nil; self?.needsDisplay = true
        }
        needsDisplay = true
    }

    private func pixel() -> (UInt8, UInt8, UInt8)? {
        let x = min(capture.image.width - 1, max(0, Int(pointer.x * capture.scale)))
        let y = min(capture.image.height - 1, max(0, Int(pointer.y * capture.scale)))
        guard let crop = capture.image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (bytes[0], bytes[1], bytes[2])
    }
    private func hudRect(at point: CGPoint) -> CGRect {
        CGRect(x: min(max(4, point.x + 22), bounds.width - 202),
               y: min(max(4, point.y + 22), bounds.height - 94), width: 198, height: 90)
    }
    private func drawPixelHUD(_ context: CGContext) {
        guard let rgb = pixel() else { return }
        let rect = hudRect(at: pointer)
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        let px = pointer.x * capture.scale, py = pointer.y * capture.scale
        let source = CGRect(x: px - 5, y: py - 5, width: 11, height: 11).intersection(CGRect(x: 0, y: 0, width: CGFloat(capture.image.width), height: CGFloat(capture.image.height)))
        if let zoom = capture.image.cropping(to: source) {
            context.saveGState(); context.interpolationQuality = .none
            NSImage(cgImage: zoom, size: NSSize(width: 60, height: 60)).draw(in: CGRect(x: rect.minX + 7, y: rect.minY + 7, width: 60, height: 60), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            context.restoreGState()
        }
        drawText(String(format: "#%02X%02X%02X", rgb.0, rgb.1, rgb.2), at: CGPoint(x: rect.minX + 74, y: rect.minY + 10), color: .white)
        drawText("\(rgb.0), \(rgb.1), \(rgb.2)", at: CGPoint(x: rect.minX + 74, y: rect.minY + 33), color: .white, size: 11)
        drawText("C 复制 HEX", at: CGPoint(x: rect.minX + 74, y: rect.minY + 58), color: .lightGray, size: 11)
    }

    private func previewItems() -> [Annotation] {
        var items = store.items
        if let movingMark, let index = items.firstIndex(where: { $0.id == movingMark.id }) { items[index] = movingMark.translated(by: moveDelta) }
        if let current { items.append(current) }
        return items
    }
    private func localPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)), y: min(bounds.maxY, max(bounds.minY, point.y)))
    }
    private func invalidatePointer(old: CGPoint) {
        setNeedsDisplay(hudRect(at: old).union(hudRect(at: pointer)).insetBy(dx: -5, dy: -5))
    }
    override func mouseMoved(with event: NSEvent) {
        let old = pointer
        pointer = localPoint(event)
        invalidatePointer(old: old)
        if polygonDraft {
            if let last = polygon.last { setNeedsDisplay(ShapeGeometry.normalized(start: last, end: old).union(ShapeGeometry.normalized(start: last, end: pointer)).insetBy(dx: -5, dy: -5)) }
        } else if !hasSelection {
            let prior = hover?.rect ?? .zero
            hover = capture.windows.first { $0.rect.contains(pointer) }
            if prior != hover?.rect { setNeedsDisplay(prior.union(hover?.rect ?? .zero).insetBy(dx: -30, dy: -30)) }
        }
        if annotating { (tool == .text ? NSCursor.iBeam : (tool == .select ? NSCursor.arrow : NSCursor.crosshair)).set() }
        else { (hasSelection && selection.contains(pointer) ? NSCursor.openHand : NSCursor.crosshair).set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard !outputBusy else { return }
        finishText(commit: true)
        window?.makeFirstResponder(self)
        pointer = localPoint(event)
        if !hasSelection { hover = capture.windows.first { $0.rect.contains(pointer) } }
        if polygonDraft {
            if event.clickCount >= 2 || (polygon.count >= 3 && hypot(pointer.x - polygon[0].x, pointer.y - polygon[0].y) < 10) { completePolygon() }
            else if polygon.last != pointer { polygon.append(pointer); needsDisplay = true }
            return
        }
        if event.clickCount >= 2, hasSelection {
            if let stamp = lastStamp, stamp.tool == tool,
               event.timestamp - stamp.time < NSEvent.doubleClickInterval + 0.1,
               hypot(pointer.x - stamp.point.x, pointer.y - stamp.point.y) < 8 {
                store.remove(id: stamp.id); lastStamp = nil
            }
            copy(nil)
            return
        }
        anchor = pointer
        if !hasSelection { selecting = true; selection = .zero; return }
        if !annotating {
            originalSelection = selection
            originalPolygon = polygon
            if let handle = cropHandle(at: pointer) {
                resizeHandle = handle
            } else if selection.contains(pointer) { movingCrop = true }
            else { reselect(); selecting = true; anchor = pointer }
            return
        }
        if tool == .select {
            selectedID = AnnotationGeometry.hitTest(pointer, annotations: store.items)
            movingMark = selected
            moveDelta = .zero
            updateTools(); needsDisplay = true
            return
        }
        guard ShapeGeometry.path(shape: shape, in: selection, vertices: polygon).contains(pointer) else { return }
        if tool == .text { beginText(at: pointer); return }
        current = Annotation(tool: tool, start: pointer, end: pointer,
                             points: [.pen, .highlight].contains(tool) ? [pointer] : [],
                             color: color, width: lineWidth, fontSize: fontSize, blockSize: mosaicBlock,
                             number: (store.items.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1,
                             filled: fillButton.state == .on, doubleArrow: doubleArrowButton.state == .on)
    }

    override func mouseDragged(with event: NSEvent) {
        let oldPointer = pointer
        pointer = localPoint(event)
        invalidatePointer(old: oldPointer)
        if selecting {
            let old = selection
            let end = ShapeGeometry.constrainedCaptureEnd(start: anchor, end: pointer, shape: shape, enabled: event.modifierFlags.contains(.shift))
            selection = ShapeGeometry.normalized(start: anchor, end: end).intersection(bounds)
            if shape == .circle { selection = ShapeGeometry.circleSquare(in: selection) }
            setNeedsDisplay(old.union(selection).insetBy(dx: -8, dy: -8))
        } else if movingCrop {
            let old = selection
            selection = ShapeGeometry.move(selection: originalSelection, by: CGPoint(x: pointer.x - anchor.x, y: pointer.y - anchor.y), within: bounds)
            let delta = CGPoint(x: selection.minX - originalSelection.minX, y: selection.minY - originalSelection.minY)
            polygon = originalPolygon.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            setNeedsDisplay(old.union(selection).insetBy(dx: -10, dy: -10))
        } else if let resizeHandle {
            let old = selection
            selection = ShapeGeometry.resize(selection: originalSelection, handle: resizeHandle, to: pointer, within: bounds, square: shape == .circle)
            transformPolygon(from: originalSelection, to: selection)
            setNeedsDisplay(old.union(selection).insetBy(dx: -10, dy: -10))
        } else if let movingMark {
            let old = AnnotationGeometry.bounds(of: movingMark).offsetBy(dx: moveDelta.x, dy: moveDelta.y)
            moveDelta = CGPoint(x: pointer.x - anchor.x, y: pointer.y - anchor.y)
            setNeedsDisplay(old.union(AnnotationGeometry.bounds(of: movingMark).offsetBy(dx: moveDelta.x, dy: moveDelta.y)).insetBy(dx: -4, dy: -4))
        } else if current != nil {
            if [.pen, .highlight].contains(tool) {
                let previous = current?.points.last ?? pointer
                current?.end = pointer
                if previous != pointer { current?.points.append(pointer) }
                let margin = lineWidth * (tool == .highlight ? 2 : 0.5) + 4
                setNeedsDisplay(ShapeGeometry.normalized(start: previous, end: pointer).insetBy(dx: -margin, dy: -margin))
            } else {
                let old = AnnotationGeometry.bounds(of: current!)
                current?.end = ShapeGeometry.constrainedEnd(start: current!.start, end: pointer, tool: tool, enabled: event.modifierFlags.contains(.shift))
                setNeedsDisplay(old.union(AnnotationGeometry.bounds(of: current!)).insetBy(dx: -4, dy: -4))
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if selecting {
            selecting = false
            if selection.width < 3 || selection.height < 3 { selection = hover?.rect.intersection(bounds) ?? .zero }
            if shape == .circle { selection = ShapeGeometry.circleSquare(in: selection) }
            annotationBar.isHidden = !hasSelection
            layoutToolbars(); needsDisplay = true
        } else if movingCrop || resizeHandle != nil {
            movingCrop = false; resizeHandle = nil; layoutToolbars(); needsDisplay = true
        } else if let movingMark {
            store.move(id: movingMark.id, delta: moveDelta)
            self.movingMark = nil; moveDelta = .zero
            pruneCaches(); needsDisplay = true
        } else if let current {
            self.current = nil
            let keep: Bool
            switch current.tool {
            case .rectangle, .ellipse, .mosaic: keep = current.rect.width >= 2 && current.rect.height >= 2
            case .arrow, .line: keep = hypot(current.end.x - current.start.x, current.end.y - current.start.y) >= 2
            default: keep = true
            }
            if keep {
                store.add(current)
                if current.tool == .number || ((current.tool == .pen || current.tool == .highlight) && current.points.count <= 1) {
                    lastStamp = (current.id, current.start, current.tool, event.timestamp)
                } else { lastStamp = nil }
            }
            pruneCaches(); needsDisplay = true
        }
    }

    private func transformPolygon(from old: CGRect, to new: CGRect) {
        guard shape == .polygon, old.width > 0, old.height > 0 else { return }
        polygon = originalPolygon.map { CGPoint(x: new.minX + ($0.x - old.minX) * new.width / old.width,
                                                y: new.minY + ($0.y - old.minY) * new.height / old.height) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if polygonDraft { if !polygon.isEmpty { polygon.removeLast(); needsDisplay = true } }
        else { reselect() }
    }
    private func completePolygon() {
        guard polygon.count >= 3 else { showToast("至少需要三个顶点"); return }
        let x = polygon.map(\.x), y = polygon.map(\.y)
        let rect = CGRect(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
        var twiceArea: CGFloat = 0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            twiceArea += polygon[index].x * next.y - next.x * polygon[index].y
        }
        guard rect.width > 3, rect.height > 3, abs(twiceArea) > 8 else { showToast("顶点需要围成有效区域"); return }
        selection = rect.intersection(bounds)
        polygonClosed = true
        annotationBar.isHidden = false
        layoutToolbars(); needsDisplay = true
    }

    @objc private func selectShape(_ sender: NSButton) { applyShape(CaptureShape.allCases[sender.tag]) }
    @objc private func selectPolygon(_ sender: NSPopUpButton) {
        let index = sender.selectedItem?.tag ?? 3
        if index >= 3 && index < CaptureShape.allCases.count { applyShape(CaptureShape.allCases[index]) }
    }
    private func applyShape(_ value: CaptureShape) {
        finishText(commit: true); cancelGesture()
        shape = value; polygon = []; polygonClosed = false; annotating = false
        if value == .polygon { selection = .zero; annotationBar.isHidden = true }
        else if value == .circle { selection = ShapeGeometry.circleSquare(in: selection) }
        updateTools(); layoutToolbars(); needsDisplay = true
    }
    @objc private func adjustCrop() { finishText(commit: true); cancelGesture(); annotating = false; selectedID = nil; updateTools(); needsDisplay = true }
    @objc private func selectTool(_ sender: NSButton) { applyTool(AnnotationTool.allCases[sender.tag]) }
    private func applyTool(_ value: AnnotationTool) {
        guard hasSelection else { return }
        finishText(commit: true); cancelGesture(); selectedID = nil
        tool = value; annotating = true; updateTools(); needsDisplay = true
        window?.makeFirstResponder(self)
    }
    @objc private func settingsClicked() { finishText(commit: true); onSettings?() }
    private func updateTools() {
        for (index, item) in shapeButtons.enumerated() { item.state = CaptureShape.allCases[index] == shape ? .on : .off }
        for (index, item) in toolButtons.enumerated() { item.state = AnnotationTool.allCases[index] == tool && annotating ? .on : .off }
        let activeTool = selected?.tool ?? tool
        fillButton.isEnabled = activeTool == .rectangle || activeTool == .ellipse
        doubleArrowButton.isEnabled = activeTool == .arrow
        if let selected { fillButton.state = selected.filled ? .on : .off; doubleArrowButton.state = selected.doubleArrow ? .on : .off }
    }
    @objc private func selectColor(_ sender: NSButton) {
        finishText(commit: true)
        let nsColor = palette[sender.tag].usingColorSpace(.sRGB)!
        color = RGBAColor(red: nsColor.redComponent, green: nsColor.greenComponent, blue: nsColor.blueComponent)
        preferences.defaultColor = nsColor
        if let id = selectedID { store.updateStyle(id: id, color: color) }
        pruneCaches(); needsDisplay = true; window?.makeFirstResponder(self)
    }
    @objc private func changeStyle() {
        if let id = selectedID { store.updateStyle(id: id, filled: fillButton.state == .on, doubleArrow: doubleArrowButton.state == .on) }
        pruneCaches(); needsDisplay = true; window?.makeFirstResponder(self)
    }
    private func changeSize(_ delta: CGFloat) {
        if var mark = selected {
            if mark.tool == .text { mark.fontSize = min(96, max(8, mark.fontSize + delta * 2)) }
            else if mark.tool == .mosaic { mark.blockSize = min(64, max(2, mark.blockSize + Int(delta))) }
            else { mark.width = min(24, max(1, mark.width + delta)) }
            store.replace(mark)
        } else if tool == .text { fontSize = min(96, max(8, fontSize + delta * 2)) }
        else if tool == .mosaic { mosaicBlock = min(64, max(2, mosaicBlock + Int(delta))) }
        else { lineWidth = min(24, max(1, lineWidth + delta)); preferences.defaultLineWidth = lineWidth }
        pruneCaches(); showToast("\(tool == .text ? "字号" : (tool == .mosaic ? "马赛克粒度" : "线宽"))已调整")
    }
    override func scrollWheel(with event: NSEvent) {
        guard hasSelection, event.scrollingDeltaY != 0 else { return }
        changeSize(event.scrollingDeltaY > 0 ? 1 : -1)
    }

    private func beginText(at point: CGPoint) {
        textOrigin = point
        let field = NSTextField(frame: CGRect(x: min(point.x, bounds.width - 265), y: min(point.y, bounds.height - 42), width: 260, height: max(34, fontSize + 12)))
        field.font = .systemFont(ofSize: fontSize, weight: .bold)
        field.textColor = NSColor(cgColor: color.cgColor) ?? .systemRed
        field.backgroundColor = .white
        field.delegate = self
        field.target = self
        field.action = #selector(commitText)
        textField = field
        addSubview(field)
        window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.allowsUndo = true
    }
    @objc private func commitText() { finishText(commit: true); window?.makeFirstResponder(self) }
    private func finishText(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        if commit && !field.stringValue.isEmpty {
            store.add(Annotation(tool: .text, start: textOrigin, end: textOrigin, text: field.stringValue, color: color, width: lineWidth, fontSize: fontSize))
        }
        field.removeFromSuperview(); pruneCaches(); needsDisplay = true
    }
    func controlTextDidEndEditing(_ notification: Notification) { finishText(commit: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishText(commit: false); window?.makeFirstResponder(self); return true }
        return false
    }

    private func cancelGesture() {
        current = nil; movingMark = nil; moveDelta = .zero
        selecting = false; movingCrop = false; resizeHandle = nil
        pruneCaches()
    }
    private func pruneCaches() { renderer.pruneCache(activeIDs: Set(store.items.map(\.id))) }
    @objc func undo(_ sender: Any?) {
        if let editor = textField?.currentEditor(), editor.isKind(of: NSTextView.self) {
            editor.undoManager?.undo(); return
        }
        finishText(commit: true)
        if current != nil || movingMark != nil { cancelGesture(); needsDisplay = true; return }
        _ = store.undo(); selectedID = nil; lastStamp = nil; pruneCaches(); updateTools(); needsDisplay = true
    }
    @objc func redo(_ sender: Any?) {
        if let editor = textField?.currentEditor(), editor.isKind(of: NSTextView.self) {
            editor.undoManager?.redo(); return
        }
        finishText(commit: true); cancelGesture()
        _ = store.redo(); selectedID = nil; lastStamp = nil; pruneCaches(); updateTools(); needsDisplay = true
    }
    @objc private func reselect() {
        finishText(commit: false); cancelGesture()
        store.clear(); renderer.clearCache(); selectedID = nil; lastStamp = nil
        selection = .zero; polygon = []; polygonClosed = false; hover = nil; annotating = false
        annotationBar.isHidden = true; needsDisplay = true
    }
    @objc private func cancel() { finishText(commit: false); toastTimer?.invalidate(); onClose?() }
    private func rendered() throws -> CGImage {
        finishText(commit: true)
        cancelGesture()
        return try renderer.render(selection: selection, shape: shape, vertices: polygon, annotations: store.items)
    }
    @objc func copy(_ sender: Any?) {
        if let editor = textField?.currentEditor() { editor.copy(sender); return }
        guard !outputBusy else { return }
        guard hasSelection else { copyPixel(hex: false); return }
        do { try OutputService.copy(rendered()); onClose?() }
        catch { showFailure(error) }
    }
    @objc private func saveScreenshot() {
        guard hasSelection, !outputBusy else { return }
        do {
            let image = try rendered()
            outputBusy = true
            Task { [weak self] in
                guard let self else { return }
                defer { self.outputBusy = false }
                do { if try await OutputService.save(image, parent: self.window) != nil { self.onClose?() } }
                catch { self.showFailure(error) }
            }
        } catch { showFailure(error) }
    }
    @objc private func quickSave() {
        guard hasSelection else { return }
        do { _ = try OutputService.quickSave(rendered()); onClose?() }
        catch { showFailure(error) }
    }
    @objc private func pin() {
        guard hasSelection else { return }
        do { onPin?(try rendered()) } catch { showFailure(error) }
    }
    @objc private func ocr() {
        guard hasSelection else { return }
        do { onOCR?(try renderer.render(selection: selection, shape: shape, vertices: polygon, annotations: [])) }
        catch { showFailure(error) }
    }
    private func showFailure(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if command {
            switch key {
            case "c": if hasSelection { copy(nil) } else { copyPixel(hex: false) }
            case "s": if shift { quickSave() } else { saveScreenshot() }
            case "t": pin()
            case "o": if shift { ocr() }
            case "z": if shift { redo(nil) } else { undo(nil) }
            case "y": redo(nil)
            case "r": reselect()
            default: super.keyDown(with: event)
            }
            return
        }
        if event.keyCode == 53 { cancel(); return }
        if event.keyCode == 36 || event.keyCode == 76 { if polygonDraft { completePolygon() } else { copy(nil) }; return }
        if event.keyCode == 51 || event.keyCode == 117 {
            if polygonDraft { if !polygon.isEmpty { polygon.removeLast(); needsDisplay = true } }
            else if let id = selectedID { cancelGesture(); store.remove(id: id); selectedID = nil; pruneCaches(); updateTools(); needsDisplay = true }
            else { undo(nil) }
            return
        }
        if key == "c" { copyPixel(hex: true); return }
        if key == "[" { changeSize(-1); return }
        if key == "]" { changeSize(1); return }
        if let number = Int(key), number >= 0, number <= 9 { applyTool(AnnotationTool.allCases[number == 0 ? 9 : number - 1]); return }
        super.keyDown(with: event)
    }
    private func copyPixel(hex: Bool) {
        if let rgb = pixel() { OutputService.copyColor(red: rgb.0, green: rgb.1, blue: rgb.2, hex: hex); showToast("颜色已复制") }
    }
}

private extension AnnotationTool {
    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse: return "圆形"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .pen: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .number: return "序号"
        case .highlight: return "高亮"
        case .select: return "选择"
        }
    }
}

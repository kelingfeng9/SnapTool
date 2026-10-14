import AppKit
import SnapCore

/// Produces documentation from the actual native views and renderer, using a
/// generated desktop so documentation never contains a user's screen content.
@MainActor
enum DocumentationSnapshots {
    static func write(to directory: URL) async throws {
        FileHandle.standardError.write(Data("Native documentation: start\n".utf8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .aqua)
        let size = CGSize(width: 1280, height: 760)
        let desktop = try image(size: size) {
            NSColor(srgbRed: 0.9, green: 0.94, blue: 0.98, alpha: 1).setFill()
            CGRect(origin: .zero, size: size).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: CGRect(x: 70, y: 100, width: 1140, height: 570), xRadius: 16, yRadius: 16).fill()
            text("SnapTool · 截图与标注演示", at: CGPoint(x: 105, y: 140), size: 30)
            text("直接调取  →  选择区域  →  标注  →  复制 / 保存 / 贴图", at: CGPoint(x: 105, y: 188), size: 18)
            for (index, row) in ["项目说明与任务清单", "需要标记的重要内容", "示例文字：中文识别 / Local OCR", "敏感信息示例  1234 5678"].enumerated() {
                text(row, at: CGPoint(x: 120, y: 268 + CGFloat(index) * 70), size: 23)
            }
            text("演示背景 · 不含真实桌面内容", at: CGPoint(x: 100, y: 700), size: 15)
        }
        FileHandle.standardError.write(Data("Native documentation: generated desktop\n".utf8))
        let origin = NSScreen.main?.frame.origin ?? .zero
        let frame = CGRect(origin: origin, size: size)
        let captured = DesktopCapture(image: desktop, frame: frame, scale: 1, windows: [])
        let preferences = Preferences(defaults: UserDefaults(suiteName: "SnapTool.Documentation")!)
        let session = CaptureSession(capture: captured, preferences: preferences, displayFrames: [frame])
        FileHandle.standardError.write(Data("Native documentation: session initialized\n".utf8))
        session.makeKeyAndOrderFront(nil)
        FileHandle.standardError.write(Data("Native documentation: session shown\n".utf8))
        session.canvas.appearance = NSAppearance(named: .aqua)
        session.canvas.loadDocumentationExample(selection: CGRect(x: 90, y: 125, width: 1100, height: 495), annotations: [
            Annotation(tool: .rectangle, start: CGPoint(x: 106, y: 255), end: CGPoint(x: 490, y: 310), color: .init(red: 1, green: 0, blue: 0), width: 4),
            Annotation(tool: .ellipse, start: CGPoint(x: 530, y: 240), end: CGPoint(x: 900, y: 340), color: .init(red: 0.12, green: 0.56, blue: 1), width: 4),
            Annotation(tool: .arrow, start: CGPoint(x: 945, y: 410), end: CGPoint(x: 540, y: 355), color: .init(red: 1, green: 0.55, blue: 0), width: 5),
            Annotation(tool: .number, start: CGPoint(x: 1040, y: 300), end: CGPoint(x: 1040, y: 300), color: .init(red: 1, green: 0, blue: 0), width: 4, number: 1),
            Annotation(tool: .mosaic, start: CGPoint(x: 345, y: 476), end: CGPoint(x: 560, y: 520), blockSize: 16)
        ])
        try await Task.sleep(nanoseconds: 200_000_000)
        FileHandle.standardError.write(Data("Native documentation: save capture begin\n".utf8))
        try save(view: session.windows[0].viewport, to: directory.appendingPathComponent("mac-capture.png"))
        session.close()

        FileHandle.standardError.write(Data("Native documentation: capture rendered; construct settings\n".utf8))
        let settings = SettingsWindowController(preferences: preferences, hotKeyManager: HotKeyManager())
        FileHandle.standardError.write(Data("Native documentation: settings constructed; show\n".utf8))
        settings.showWindow(nil)
        settings.window?.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(nanoseconds: 150_000_000)
        if let view = settings.window?.contentView {
            try save(view: view, to: directory.appendingPathComponent("mac-settings.png"), background: settings.window?.backgroundColor ?? .windowBackgroundColor)
        }
        settings.close()

        let boardSize = CGSize(width: 1200, height: 750)
        let tools: [AnnotationTool] = [.rectangle, .ellipse, .arrow, .line, .pen, .text, .mosaic, .number, .highlight]
        let titles = ["1 矩形", "2 圆形 / 椭圆", "3 箭头", "4 直线", "5 画笔", "6 文字", "7 马赛克", "8 序号", "9 高亮"]
        let base = try image(size: boardSize) {
            NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
            CGRect(origin: .zero, size: boardSize).fill()
            for index in tools.indices {
                let x = CGFloat(index % 3) * 400 + 18, y = CGFloat(index / 3) * 250 + 18
                NSColor.white.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: y, width: 364, height: 214), xRadius: 12, yRadius: 12).fill()
                text(titles[index], at: CGPoint(x: x + 16, y: y + 14), size: 22)
                if tools[index] == .mosaic {
                    for row in 0..<12 { for column in 0..<30 {
                        ((row + column) % 2 == 0 ? NSColor.systemBlue : NSColor.systemOrange).setFill()
                        CGRect(x: x + 40 + CGFloat(column) * 8, y: y + 74 + CGFloat(row) * 8, width: 8, height: 8).fill()
                    } }
                }
                if tools[index] == .highlight { text("重点内容", at: CGPoint(x: x + 75, y: y + 92), size: 28) }
            }
        }
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        var annotations: [Annotation] = []
        for (index, tool) in tools.enumerated() {
            let x = CGFloat(index % 3) * 400 + 18, y = CGFloat(index / 3) * 250 + 18
            let start = CGPoint(x: x + 55, y: y + 76), end = CGPoint(x: x + 290, y: y + 168)
            var annotation = Annotation(tool: tool, start: start, end: end, color: red, width: 5, fontSize: 30)
            if tool == .pen { annotation.points = [start, CGPoint(x: x + 110, y: y + 155), CGPoint(x: x + 185, y: y + 82), end] }
            if tool == .text { annotation.text = "Snap 标注"; annotation.start.y += 20 }
            if tool == .number { annotation.start = CGPoint(x: x + 178, y: y + 119); annotation.number = 1 }
            if tool == .highlight { annotation.points = [CGPoint(x: x + 66, y: y + 129), CGPoint(x: x + 270, y: y + 129)]; annotation.color = RGBAColor(red: 1, green: 0.84, blue: 0); annotation.width = 10 }
            annotations.append(annotation)
        }
        let annotated = try AnnotationRenderer(desktop: base, pixelScale: 1).render(selection: CGRect(origin: .zero, size: boardSize), shape: .rectangle, annotations: annotations)
        try AnnotationRenderer.PNGData(annotated).write(to: directory.appendingPathComponent("mac-annotations.png"))

        let shapes = try image(size: CGSize(width: 1200, height: 520)) {
            NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 1200, height: 520).fill()
            for (index, shape) in CaptureShape.allCases.enumerated() {
                let x = CGFloat(index % 3) * 400 + 30, y = CGFloat(index / 3) * 260 + 12
                text(["矩形（默认）", "圆形", "三角形", "五边形", "六边形", "自由多边形"][index], at: CGPoint(x: x, y: y), size: 22)
                for row in 0..<18 { for column in 0..<30 {
                    (row + column) % 2 == 0 ? NSColor(white: 0.92, alpha: 1).setFill() : NSColor.white.setFill()
                    CGRect(x: x + CGFloat(column) * 10, y: y + 44 + CGFloat(row) * 10, width: 10, height: 10).fill()
                } }
                let polygon = [CGPoint(x: 95, y: 35), CGPoint(x: 360, y: 80), CGPoint(x: 300, y: 225), CGPoint(x: 115, y: 200)]
                if let crop = try? AnnotationRenderer(desktop: desktop, pixelScale: 1).render(selection: CGRect(x: 90, y: 30, width: 280, height: 200), shape: shape, vertices: polygon) {
                    NSImage(cgImage: crop, size: CGSize(width: 280, height: 200)).draw(in: CGRect(x: x + 24, y: y + 44, width: 252, height: 180), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
        try AnnotationRenderer.PNGData(shapes).write(to: directory.appendingPathComponent("mac-shapes.png"))

        let pin = PinWindow(image: annotated, initialFrame: CGRect(x: origin.x + 30, y: origin.y + 50, width: 720, height: 450))
        pin.showWindow(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        if let view = pin.window?.contentView { try save(view: view, to: directory.appendingPathComponent("mac-pins.png")) }
        pin.close()
    }

    private static func image(size: CGSize, draw: () -> Void) throws -> CGImage {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OutputServiceError.encodingFailed }
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw OutputServiceError.encodingFailed }
        return image
    }
    private static func text(_ value: String, at point: CGPoint, size: CGFloat) {
        (value as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor(srgbRed: 0.16, green: 0.2, blue: 0.26, alpha: 1)])
    }
    private static func save(view: NSView, to url: URL, background: NSColor? = nil) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw OutputServiceError.encodingFailed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data: Data
        if let background, let image = bitmap.cgImage, let rgb = background.usingColorSpace(.sRGB) {
            let opaque = try AnnotationRenderer.opaqueImage(image, background: RGBAColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent))
            data = try AnnotationRenderer.PNGData(opaque)
        } else {
            guard let encoded = bitmap.representation(using: .png, properties: [:]) else { throw OutputServiceError.encodingFailed }
            data = encoded
        }
        try data.write(to: url)
    }
}

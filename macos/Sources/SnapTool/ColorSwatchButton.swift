import AppKit
import CoreGraphics

/// A palette button paints its color directly, independent of bezel tint and appearance.
@MainActor
final class ColorSwatchButton: NSButton {
    let swatchColor: NSColor
    let colorName: String

    init(color: NSColor, name: String, target: AnyObject?, action: Selector) {
        swatchColor = (color.usingColorSpace(.sRGB) ?? .black).withAlphaComponent(1)
        colorName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 28))
        title = ""
        isBordered = false
        setButtonType(.pushOnPushOff)
        self.target = target
        self.action = action
        toolTip = "\(name) · 标注颜色"
        setAccessibilityLabel("标注颜色：\(name)")
        setAccessibilityHelp("选择\(name)作为标注颜色")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override var state: NSControl.StateValue {
        didSet {
            needsDisplay = true
            if state != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if !isEnabled { context.setAlpha(0.45) }
        Self.drawSwatch(in: context, bounds: bounds, color: swatchColor, state: state)
        context.restoreGState()
    }

    override func accessibilityValue() -> Any? { state == .on ? "已选中" : "未选中" }

    /// Shared with pixel tests so tests exercise the same paint routine as the actual button.
    static func drawSwatch(in context: CGContext, bounds: CGRect, color: NSColor,
                           state: NSControl.StateValue) {
        let side = min(bounds.width, bounds.height) - 8
        guard side >= 8 else { return }
        let swatch = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side)
        let rgb = (color.usingColorSpace(.sRGB) ?? .black).withAlphaComponent(1)
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        let path = CGPath(roundedRect: swatch, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.saveGState()
        context.setFillColor(rgb.cgColor)
        context.addPath(path)
        context.fillPath()

        // Light swatches have a dark edge; dark swatches have a light edge.
        context.setStrokeColor(NSColor(srgbRed: luminance > 0.6 ? 0.30 : 0.78,
                                       green: luminance > 0.6 ? 0.30 : 0.78,
                                       blue: luminance > 0.6 ? 0.30 : 0.78, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()

        if state == .on {
            let ring = CGPath(roundedRect: swatch.insetBy(dx: -2, dy: -2),
                              cornerWidth: 5, cornerHeight: 5, transform: nil)
            context.setStrokeColor(NSColor(srgbRed: 0.10, green: 0.43, blue: 0.98, alpha: 1).cgColor)
            context.setLineWidth(2)
            context.addPath(ring)
            context.strokePath()
            context.setStrokeColor((luminance > 0.6 ? NSColor.black : NSColor.white).cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: swatch.midX - 4, y: swatch.midY + 0.3))
            context.addLine(to: CGPoint(x: swatch.midX - 1, y: swatch.midY + 3))
            context.addLine(to: CGPoint(x: swatch.midX + 4, y: swatch.midY - 3))
            context.strokePath()
        }
        context.restoreGState()
    }
}

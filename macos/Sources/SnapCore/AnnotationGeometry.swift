import Foundation
import CoreGraphics
import CoreText

public enum AnnotationGeometry {
    public static func bounds(of annotation: Annotation) -> CGRect {
        let width = safeWidth(annotation.width)
        let padding = max(4, width / 2 + 2)
        switch annotation.tool {
        case .text:
            let size = textSize(annotation.text, fontSize: annotation.fontSize)
            return CGRect(origin: annotation.start, size: size).insetBy(dx: -2, dy: -2)
        case .number:
            let radius = numberRadius(annotation)
            return CGRect(x: annotation.start.x - radius - 2, y: annotation.start.y - radius - 2,
                          width: radius * 2 + 4, height: radius * 2 + 4)
        case .pen, .highlight:
            let points = annotation.points.isEmpty ? [annotation.start, annotation.end] : annotation.points
            var minX = points[0].x, minY = points[0].y
            var maxX = minX, maxY = minY
            for point in points.dropFirst() {
                minX = min(minX, point.x); minY = min(minY, point.y)
                maxX = max(maxX, point.x); maxY = max(maxY, point.y)
            }
            let penPadding = annotation.tool == .highlight ? max(padding, width * 2 + 2) : padding
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -penPadding, dy: -penPadding)
        case .arrow:
            let arrowPadding = max(padding, width * 3 + 4)
            return annotation.rect.insetBy(dx: -arrowPadding, dy: -arrowPadding)
        default: return annotation.rect.insetBy(dx: -padding, dy: -padding)
        }
    }

    public static func hitTest(_ point: CGPoint, annotation: Annotation, tolerance: CGFloat = 5) -> Bool {
        guard bounds(of: annotation).insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        let stroke = safeWidth(annotation.width)
        switch annotation.tool {
        case .rectangle:
            let rect = annotation.rect
            if annotation.filled { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            let outer = rect.insetBy(dx: -(tolerance + stroke / 2), dy: -(tolerance + stroke / 2))
            let inner = rect.insetBy(dx: tolerance + stroke / 2, dy: tolerance + stroke / 2)
            return outer.contains(point) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(point))
        case .ellipse:
            let path = CGPath(ellipseIn: annotation.rect, transform: nil)
            if annotation.filled && path.contains(point) { return true }
            return path.copy(strokingWithWidth: stroke + tolerance * 2,
                             lineCap: .round, lineJoin: .round, miterLimit: 10, transform: .identity).contains(point)
        case .arrow:
            return arrowPath(annotation).copy(strokingWithWidth: stroke + tolerance * 2,
                                              lineCap: .round, lineJoin: .round, miterLimit: 10, transform: .identity).contains(point)
        case .line:
            return segmentDistance(point, from: annotation.start, to: annotation.end) <= tolerance + stroke / 2
        case .pen, .highlight:
            let points = annotation.points.isEmpty ? [annotation.start, annotation.end] : annotation.points
            let padding = tolerance + (annotation.tool == .highlight ? stroke * 2 : stroke / 2)
            if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= padding }
            return zip(points, points.dropFirst()).contains { segmentDistance(point, from: $0.0, to: $0.1) <= padding }
        case .number:
            return hypot(point.x - annotation.start.x, point.y - annotation.start.y) <= numberRadius(annotation) + tolerance
        case .text, .mosaic: return bounds(of: annotation).contains(point)
        case .select: return false
        }
    }

    /// Returns the topmost item matching the pointer.
    public static func hitTest(_ point: CGPoint, annotations: [Annotation], tolerance: CGFloat = 5) -> UUID? {
        annotations.reversed().first { hitTest(point, annotation: $0, tolerance: tolerance) }?.id
    }

    static func safeWidth(_ value: CGFloat) -> CGFloat { value.isFinite ? max(1, min(100, value)) : 3 }
    static func safeFontSize(_ value: CGFloat) -> CGFloat { value.isFinite ? max(8, min(200, value)) : 24 }
    static func numberRadius(_ annotation: Annotation) -> CGFloat {
        max(12, max(safeFontSize(annotation.fontSize) * 0.7,
                    textSize(String(annotation.number), fontSize: annotation.fontSize).width / 2 + 5))
    }

    static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, safeFontSize(fontSize), nil)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font) + max(2, CTFontGetLeading(font))
        let lines = text.components(separatedBy: .newlines)
        let width = lines.map { value -> CGFloat in
            let string = NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string as CFAttributedString), nil, nil, nil))
        }.max() ?? 0
        return CGSize(width: max(1, ceil(width)), height: max(1, ceil(CGFloat(lines.count) * height)))
    }

    static func arrowPath(_ annotation: Annotation) -> CGPath {
        let path = CGMutablePath()
        path.move(to: annotation.start); path.addLine(to: annotation.end)
        let angle = atan2(annotation.end.y - annotation.start.y, annotation.end.x - annotation.start.x)
        let length = min(hypot(annotation.end.x - annotation.start.x, annotation.end.y - annotation.start.y) / 2,
                         max(10, safeWidth(annotation.width) * 3))
        func addHead(at point: CGPoint, angle: CGFloat) {
            path.move(to: CGPoint(x: point.x - cos(angle - .pi / 6) * length,
                                 y: point.y - sin(angle - .pi / 6) * length))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x - cos(angle + .pi / 6) * length,
                                    y: point.y - sin(angle + .pi / 6) * length))
        }
        addHead(at: annotation.end, angle: angle)
        if annotation.doubleArrow { addHead(at: annotation.start, angle: angle + .pi) }
        return path
    }

    private static func segmentDistance(_ point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let fraction = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + fraction * dx), point.y - (a.y + fraction * dy))
    }
}

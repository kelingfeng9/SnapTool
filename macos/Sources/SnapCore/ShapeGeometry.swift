import Foundation
import CoreGraphics

public enum ShapeGeometry {
    public static func normalized(start: CGPoint, end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public static func circleSquare(in rect: CGRect) -> CGRect {
        let rect = rect.standardized
        let side = min(rect.width, rect.height)
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    public static func path(shape: CaptureShape, in rect: CGRect, vertices: [CGPoint] = []) -> CGPath {
        let path = CGMutablePath()
        switch shape {
        case .rectangle: path.addRect(rect.standardized)
        case .circle: path.addEllipse(in: circleSquare(in: rect))
        case .triangle, .pentagon, .hexagon:
            let count = shape == .triangle ? 3 : (shape == .pentagon ? 5 : 6)
            let points = regularPolygon(count: count, in: rect)
            addPolygon(points, to: path)
        case .polygon: addPolygon(vertices, to: path)
        }
        return path
    }

    public static func regularPolygon(count: Int, in rect: CGRect) -> [CGPoint] {
        guard count >= 3 else { return [] }
        let rect = rect.standardized
        let unitPoints = (0..<count).map { index -> CGPoint in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * CGFloat.pi / CGFloat(count)
            return CGPoint(x: cos(angle), y: sin(angle))
        }
        // Fit the actual polygon bounds to the selection, including triangles.
        let minX = unitPoints.map(\.x).min()!, maxX = unitPoints.map(\.x).max()!
        let minY = unitPoints.map(\.y).min()!, maxY = unitPoints.map(\.y).max()!
        return unitPoints.map {
            CGPoint(x: rect.minX + ($0.x - minX) / (maxX - minX) * rect.width,
                    y: rect.minY + ($0.y - minY) / (maxY - minY) * rect.height)
        }
    }

    public static func constrainedEnd(start: CGPoint, end: CGPoint, tool: AnnotationTool,
                                      enabled: Bool) -> CGPoint {
        guard enabled else { return end }
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side),
                           y: start.y + (dy < 0 ? -side : side))
        case .arrow, .line:
            let length = hypot(dx, dy)
            guard length > 0 else { return start }
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        default: return end
        }
    }

    public static func constrainedCaptureEnd(start: CGPoint, end: CGPoint,
                                             shape: CaptureShape, enabled: Bool = false) -> CGPoint {
        constrainedEnd(start: start, end: end, tool: .rectangle,
                       enabled: enabled || shape == .circle)
    }

    /// Creates a selection within the desktop while preserving the drag anchor.
    /// Circle and Shift-constrained captures stay square even near the bounds;
    /// clipping a square and subsequently recentering it would move the anchor.
    /// A zero delta on an axis uses its positive direction, matching
    /// constrainedCaptureEnd rather than producing a zero-width constraint.
    public static func captureSelection(start: CGPoint, end: CGPoint, shape: CaptureShape,
                                         within bounds: CGRect, constrain: Bool = false) -> CGRect {
        let bounds = bounds.standardized
        let anchor = CGPoint(x: clamp(start.x, bounds.minX, bounds.maxX),
                             y: clamp(start.y, bounds.minY, bounds.maxY))
        guard shape == .circle || constrain else {
            return normalized(start: anchor, end: end).intersection(bounds)
        }
        let dx = end.x - anchor.x, dy = end.y - anchor.y
        let sx: CGFloat = dx < 0 ? -1 : 1
        let sy: CGFloat = dy < 0 ? -1 : 1
        let availableX = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let availableY = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        let side = max(0, min(max(abs(dx), abs(dy)), min(availableX, availableY)))
        return normalized(start: anchor, end: CGPoint(x: anchor.x + sx * side, y: anchor.y + sy * side))
    }

    public static func move(selection: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
        let selection = selection.standardized
        let bounds = bounds.standardized
        let width = min(selection.width, bounds.width), height = min(selection.height, bounds.height)
        return CGRect(x: clamp(selection.minX + delta.x, bounds.minX, bounds.maxX - width),
                      y: clamp(selection.minY + delta.y, bounds.minY, bounds.maxY - height),
                      width: width, height: height)
    }

    public static func resizeCircle(selection: CGRect, handle: SelectionHandle, to point: CGPoint,
                                    within bounds: CGRect) -> CGRect {
        let rect = circleSquare(in: selection)
        let bounds = bounds.standardized
        switch handle {
        case .top, .bottom:
            // The midpoint of the opposite edge is the fixed anchor. Moving
            // tangentially along an edge does not change the circle size.
            let anchor = CGPoint(x: rect.midX, y: handle == .top ? rect.maxY : rect.minY)
            let desired = max(0, handle == .top ? anchor.y - point.y : point.y - anchor.y)
            let horizontalLimit = 2 * max(0, min(anchor.x - bounds.minX, bounds.maxX - anchor.x))
            let verticalLimit = max(0, handle == .top ? anchor.y - bounds.minY : bounds.maxY - anchor.y)
            let side = min(desired, min(horizontalLimit, verticalLimit))
            return CGRect(x: anchor.x - side / 2, y: handle == .top ? anchor.y - side : anchor.y,
                          width: side, height: side)
        case .left, .right:
            let anchor = CGPoint(x: handle == .left ? rect.maxX : rect.minX, y: rect.midY)
            let desired = max(0, handle == .left ? anchor.x - point.x : point.x - anchor.x)
            let verticalLimit = 2 * max(0, min(anchor.y - bounds.minY, bounds.maxY - anchor.y))
            let horizontalLimit = max(0, handle == .left ? anchor.x - bounds.minX : bounds.maxX - anchor.x)
            let side = min(desired, min(horizontalLimit, verticalLimit))
            return CGRect(x: handle == .left ? anchor.x - side : anchor.x, y: anchor.y - side / 2,
                          width: side, height: side)
        default: break
        }
        let anchor: CGPoint
        let sx: CGFloat, sy: CGFloat
        switch handle {
        case .topLeft: anchor = CGPoint(x: rect.maxX, y: rect.maxY); sx = -1; sy = -1
        case .topRight: anchor = CGPoint(x: rect.minX, y: rect.maxY); sx = 1; sy = -1
        case .bottomLeft: anchor = CGPoint(x: rect.maxX, y: rect.minY); sx = -1; sy = 1
        case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY); sx = 1; sy = 1
        case .top, .right, .bottom, .left: return rect // Handled above.
        }
        let desired = max(0, max((point.x - anchor.x) * sx, (point.y - anchor.y) * sy))
        let availableX = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let availableY = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        let side = max(0, min(desired, min(availableX, availableY)))
        return normalized(start: anchor, end: CGPoint(x: anchor.x + sx * side, y: anchor.y + sy * side))
    }

    public static func resize(selection: CGRect, handle: SelectionHandle, to point: CGPoint,
                              within bounds: CGRect, square: Bool = false) -> CGRect {
        if square { return resizeCircle(selection: selection, handle: handle, to: point, within: bounds) }
        let rect = selection.standardized
        let bounds = bounds.standardized
        let bounded = CGPoint(x: clamp(point.x, bounds.minX, bounds.maxX),
                              y: clamp(point.y, bounds.minY, bounds.maxY))
        switch handle {
        case .top:
            return normalized(start: CGPoint(x: rect.minX, y: rect.maxY),
                              end: CGPoint(x: rect.maxX, y: bounded.y))
        case .bottom:
            return normalized(start: CGPoint(x: rect.minX, y: rect.minY),
                              end: CGPoint(x: rect.maxX, y: bounded.y))
        case .left:
            return normalized(start: CGPoint(x: rect.maxX, y: rect.minY),
                              end: CGPoint(x: bounded.x, y: rect.maxY))
        case .right:
            return normalized(start: CGPoint(x: rect.minX, y: rect.minY),
                              end: CGPoint(x: bounded.x, y: rect.maxY))
        default: break
        }
        let anchor: CGPoint
        switch handle {
        case .topLeft: anchor = CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: anchor = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: anchor = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY)
        case .top, .right, .bottom, .left: return rect // Handled above.
        }
        return normalized(start: anchor, end: bounded)
    }

    private static func addPolygon(_ points: [CGPoint], to path: CGMutablePath) {
        guard points.count >= 3 else { return }
        path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }
        path.closeSubpath()
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

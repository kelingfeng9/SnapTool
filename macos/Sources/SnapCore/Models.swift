import Foundation
import CoreGraphics

/// All points and rectangles in SnapCore use desktop logical points, with the
/// origin at the top-left of the captured display.
public enum CaptureShape: String, CaseIterable, Codable, Sendable {
    case rectangle, circle, triangle, pentagon, hexagon, polygon
}

public enum AnnotationTool: String, CaseIterable, Codable, Sendable {
    case rectangle, ellipse, arrow, line, pen, text, mosaic, number, highlight, select
}

public struct RGBAColor: Equatable, Codable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [
            Self.unit(red), Self.unit(green), Self.unit(blue), Self.unit(alpha)
        ])!
    }

    public static let orange = RGBAColor(red: 1, green: 0.45, blue: 0.05)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)

    private static func unit(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

public struct Annotation: Identifiable, Equatable, Codable {
    public var id: UUID
    public var tool: AnnotationTool
    public var start: CGPoint
    public var end: CGPoint
    public var points: [CGPoint]
    public var text: String
    public var color: RGBAColor
    public var width: CGFloat
    public var fontSize: CGFloat
    /// Mosaic block size in logical points; rendering converts it to pixels.
    public var blockSize: Int
    public var number: Int
    public var filled: Bool
    public var doubleArrow: Bool

    public init(id: UUID = UUID(), tool: AnnotationTool, start: CGPoint, end: CGPoint,
                points: [CGPoint] = [], text: String = "", color: RGBAColor = .orange,
                width: CGFloat = 3, fontSize: CGFloat = 24, blockSize: Int = 12,
                number: Int = 1, filled: Bool = false, doubleArrow: Bool = false) {
        self.id = id; self.tool = tool; self.start = start; self.end = end
        self.points = points; self.text = text; self.color = color; self.width = width
        self.fontSize = fontSize; self.blockSize = blockSize; self.number = number
        self.filled = filled; self.doubleArrow = doubleArrow
    }

    public var rect: CGRect { ShapeGeometry.normalized(start: start, end: end) }

    public func translated(by delta: CGPoint) -> Annotation {
        var result = self
        result.start.x += delta.x; result.start.y += delta.y
        result.end.x += delta.x; result.end.y += delta.y
        result.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return result
    }
}

public enum SelectionHandle: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, right, bottom, left
}

public enum SnapCoreError: Error, LocalizedError {
    case invalidScale, invalidSelection, invalidPolygon, imageAllocationFailed, pngEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidScale: return "屏幕缩放比例无效。"
        case .invalidSelection: return "截图区域为空或超出屏幕范围。"
        case .invalidPolygon: return "多边形至少需要三个顶点。"
        case .imageAllocationFailed: return "无法创建截图图像。"
        case .pngEncodingFailed: return "无法编码 PNG 图像。"
        }
    }
}

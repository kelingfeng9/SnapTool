import Foundation
import CoreGraphics

/// Coordinate conversions for separate display overlay windows sharing one
/// captured desktop. AppKit globals have a bottom-left origin. Desktop and
/// screen-local points have top-left origins, and remain logical points even
/// when displays have different backing scales.
public struct DesktopGeometry: Equatable {
    /// The union of display frames in global AppKit coordinates.
    public let frame: CGRect
    /// The full captured desktop in top-left logical coordinates.
    public var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }

    public init(frame: CGRect) { self.frame = frame.standardized }

    /// The display's viewport in the shared desktop canvas. This conversion
    /// does not clip: callers may intersect it with bounds when laying out UI.
    public func viewport(for screenFrame: CGRect) -> CGRect {
        desktopRect(fromAppKit: screenFrame)
    }

    public func desktopPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }

    public func appKitPoint(fromDesktop point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + frame.minX, y: frame.maxY - point.y)
    }

    public func desktopRect(fromAppKit rect: CGRect) -> CGRect {
        let rect = rect.standardized
        return CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    public func appKitRect(fromDesktop rect: CGRect) -> CGRect {
        let rect = rect.standardized
        return CGRect(x: rect.minX + frame.minX, y: frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// Input is relative to this display's top-left. It may be outside the
    /// display while AppKit delivers a drag begun on another display.
    public func desktopPoint(fromScreenLocal point: CGPoint, screenFrame: CGRect) -> CGPoint {
        let viewport = viewport(for: screenFrame)
        return CGPoint(x: point.x + viewport.minX, y: point.y + viewport.minY)
    }

    public func screenLocalPoint(fromDesktop point: CGPoint, screenFrame: CGRect) -> CGPoint {
        let viewport = viewport(for: screenFrame)
        return CGPoint(x: point.x - viewport.minX, y: point.y - viewport.minY)
    }

    public func desktopRect(fromScreenLocal rect: CGRect, screenFrame: CGRect) -> CGRect {
        let viewport = viewport(for: screenFrame)
        return rect.standardized.offsetBy(dx: viewport.minX, dy: viewport.minY)
    }

    public func screenLocalRect(fromDesktop rect: CGRect, screenFrame: CGRect) -> CGRect {
        let viewport = viewport(for: screenFrame)
        return rect.standardized.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
    }
}

import XCTest
import CoreGraphics
@testable import SnapCore

final class DesktopGeometryTests: XCTestCase {
    func testHorizontalDisplaysHaveDifferentTopOffsetsAndShareDragCoordinates() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let geometry = DesktopGeometry(frame: primary.union(right))
        XCTAssertEqual(geometry.bounds, CGRect(x: 0, y: 0, width: 3360, height: 1080))
        XCTAssertEqual(geometry.viewport(for: primary), CGRect(x: 0, y: 180, width: 1440, height: 900))
        XCTAssertEqual(geometry.viewport(for: right), CGRect(x: 1440, y: 0, width: 1920, height: 1080))

        let start = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 1320, y: 100), screenFrame: primary)
        let end = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 80, y: 420), screenFrame: right)
        let selection = ShapeGeometry.normalized(start: start, end: end)
        XCTAssertEqual(selection, CGRect(x: 1320, y: 280, width: 200, height: 140))
        XCTAssertEqual(selection.intersection(geometry.viewport(for: primary)).width, 120)
        XCTAssertEqual(selection.intersection(geometry.viewport(for: right)).width, 80)
        // A line at the same global height remains horizontal across both overlays.
        let leftLine = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 1400, y: 20), screenFrame: primary)
        let rightLine = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 100, y: 200), screenFrame: right)
        XCTAssertEqual(leftLine.y, rightLine.y)
    }

    func testNegativeOriginDisplayAndAppKitWindowRectMapToCorrectScreen() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        let geometry = DesktopGeometry(frame: primary.union(left))
        XCTAssertEqual(geometry.viewport(for: left), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(geometry.viewport(for: primary), CGRect(x: 1920, y: 0, width: 1440, height: 900))
        let mainPointer = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 10, y: 10), screenFrame: primary)
        XCTAssertEqual(mainPointer, CGPoint(x: 1930, y: 10))
        XCTAssertEqual(geometry.appKitPoint(fromDesktop: mainPointer), CGPoint(x: 10, y: 890))
        let windowFrame = CGRect(x: -1900, y: 700, width: 200, height: 100)
        let windowRect = geometry.desktopRect(fromAppKit: windowFrame)
        XCTAssertEqual(windowRect, CGRect(x: 20, y: 100, width: 200, height: 100))
        XCTAssertEqual(geometry.screenLocalRect(fromDesktop: windowRect, screenFrame: left), windowRect)
        XCTAssertEqual(geometry.appKitRect(fromDesktop: windowRect), windowFrame)
    }

    func testDisplayAbovePrimaryUsesDesktopTopRatherThanPrimaryTop() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let upper = CGRect(x: 160, y: 900, width: 1280, height: 1024)
        let geometry = DesktopGeometry(frame: primary.union(upper))
        XCTAssertEqual(geometry.viewport(for: upper), CGRect(x: 160, y: 0, width: 1280, height: 1024))
        XCTAssertEqual(geometry.viewport(for: primary), CGRect(x: 0, y: 1024, width: 1440, height: 900))
        let upperBottom = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 40, y: 1024), screenFrame: upper)
        let primaryTop = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 200, y: 0), screenFrame: primary)
        XCTAssertEqual(upperBottom, primaryTop)
        XCTAssertEqual(geometry.desktopPoint(fromAppKit: CGPoint(x: 200, y: 900)), upperBottom)
        XCTAssertEqual(geometry.screenLocalPoint(fromDesktop: primaryTop, screenFrame: upper), CGPoint(x: 40, y: 1024))
    }

    func testDragDeliveredToOriginalScreenContinuesPastItsBounds() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let geometry = DesktopGeometry(frame: primary.union(right))
        // AppKit can continue delivering mouseDragged to the starting window.
        let deliveredToPrimary = CGPoint(x: 1600, y: 50)
        let expectedOnRight = CGPoint(x: 160, y: 230)
        let desktop = geometry.desktopPoint(fromScreenLocal: deliveredToPrimary, screenFrame: primary)
        XCTAssertEqual(geometry.screenLocalPoint(fromDesktop: desktop, screenFrame: right), expectedOnRight)
        XCTAssertEqual(geometry.desktopPoint(fromScreenLocal: expectedOnRight, screenFrame: right), desktop)
        let outside = geometry.screenLocalPoint(fromDesktop: CGPoint(x: 1200, y: 100), screenFrame: right)
        XCTAssertEqual(outside, CGPoint(x: -240, y: 100))
    }

    func testMixedRetinaDisplaysStayInLogicalPointsBeforeUnifiedPixelScaling() {
        let retina = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let external = CGRect(x: 0, y: -100, width: 1920, height: 1080)
        let geometry = DesktopGeometry(frame: retina.union(external))
        let localSelection = CGRect(x: 100, y: 150, width: 300, height: 200)
        let desktopSelection = geometry.desktopRect(fromScreenLocal: localSelection, screenFrame: external)
        XCTAssertEqual(desktopSelection, CGRect(x: 1380, y: 150, width: 300, height: 200))
        // A 1x external screen is resampled into the capture's unified 2x image;
        // its overlay still uses the same 300 by 200 logical-point selection.
        let captureScale: CGFloat = 2
        let pixels = CGRect(x: desktopSelection.minX * captureScale,
                            y: desktopSelection.minY * captureScale,
                            width: desktopSelection.width * captureScale,
                            height: desktopSelection.height * captureScale)
        XCTAssertEqual(pixels, CGRect(x: 2760, y: 300, width: 600, height: 400))
        XCTAssertEqual(geometry.screenLocalRect(fromDesktop: desktopSelection, screenFrame: external), localSelection)
        let retinaPointer = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 200, y: 100), screenFrame: retina)
        XCTAssertEqual(retinaPointer, CGPoint(x: 200, y: 280))
    }

    func testCrossDisplaySelectionExportsPixelsFromBothDisplayTiles() throws {
        let left = CGRect(x: -8, y: 0, width: 8, height: 6)
        let right = CGRect(x: 0, y: -2, width: 10, height: 8)
        let geometry = DesktopGeometry(frame: left.union(right))
        let scale: CGFloat = 2
        let width = 36, height = 16
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                // A Retina left display and 1x right display are both composited
                // into one 2x raster. The uncovered desktop gap remains black.
                if x < 16 && y < 12 { bytes[index] = 255 }
                if x >= 16 { bytes[index + 1] = 255 }
                bytes[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let desktop = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue),
                                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let start = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 6, y: 2), screenFrame: left)
        let end = geometry.desktopPoint(fromScreenLocal: CGPoint(x: 2, y: 4), screenFrame: right)
        let output = try AnnotationRenderer(desktop: desktop, pixelScale: scale).render(
            selection: ShapeGeometry.normalized(start: start, end: end), shape: .rectangle)
        XCTAssertEqual(output.width, 8); XCTAssertEqual(output.height, 4)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
                                             bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(output, in: CGRect(x: 0, y: 0, width: 8, height: 4))
        let result = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let redPixel = (1 * 8 + 1) * 4, greenPixel = (1 * 8 + 6) * 4
        XCTAssertEqual(Array(UnsafeBufferPointer(start: result.advanced(by: redPixel), count: 4)), [255, 0, 0, 255])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: result.advanced(by: greenPixel), count: 4)), [0, 255, 0, 255])
    }

    func testRectRoundTripsPreserveFractionalCoordinatesAndDesktopGaps() {
        let bottom = CGRect(x: -600, y: -900, width: 1200, height: 900)
        let top = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let geometry = DesktopGeometry(frame: bottom.union(top))
        let frame = CGRect(x: -525.5, y: -850.25, width: 300.5, height: 125.25)
        let rect = geometry.desktopRect(fromAppKit: frame)
        XCTAssertEqual(rect, CGRect(x: 74.5, y: 1725, width: 300.5, height: 125.25))
        XCTAssertEqual(geometry.appKitRect(fromDesktop: rect), frame)
        let local = geometry.screenLocalRect(fromDesktop: rect, screenFrame: bottom)
        XCTAssertEqual(local, CGRect(x: 74.5, y: 725, width: 300.5, height: 125.25))
        XCTAssertEqual(geometry.desktopRect(fromScreenLocal: local, screenFrame: bottom), rect)
        // The union includes a region outside actual displays; transforms must
        // not silently snap such a pointer to a different screen.
        let gapPoint = CGPoint(x: 100, y: 500)
        XCTAssertFalse(geometry.viewport(for: bottom).contains(gapPoint))
        XCTAssertFalse(geometry.viewport(for: top).contains(gapPoint))
        XCTAssertEqual(geometry.desktopPoint(fromAppKit: geometry.appKitPoint(fromDesktop: gapPoint)), gapPoint)
    }
}

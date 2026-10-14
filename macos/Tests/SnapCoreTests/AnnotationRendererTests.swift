import XCTest
import CoreGraphics
import ImageIO
@testable import SnapCore

final class AnnotationRendererTests: XCTestCase {
    private func source(width: Int = 64, height: Int = 48) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8((x * 3) % 256)
                bytes[index + 1] = UInt8((y * 3) % 256)
                bytes[index + 2] = UInt8((x + y) % 256)
                bytes[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
    }

    private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let index = (y * width + x) * 4
        return Array(bytes[index..<(index + 4)])
    }

    func testRectangleKeepsRasterOrientationAndRetinaCropCoordinates() throws {
        let desktop = try source()
        let renderer = AnnotationRenderer(desktop: desktop, pixelScale: 1)
        let full = try renderer.render(selection: CGRect(x: 0, y: 0, width: 64, height: 48), shape: .rectangle)
        let bytes = try pixels(full)
        XCTAssertEqual(pixel(bytes, width: 64, x: 5, y: 4), [15, 12, 9, 255])
        XCTAssertEqual(pixel(bytes, width: 64, x: 55, y: 40), [165, 120, 95, 255])
        let retina = AnnotationRenderer(desktop: desktop, pixelScale: 2)
        let crop = try retina.render(selection: CGRect(x: 6, y: 10, width: 10, height: 8), shape: .rectangle)
        XCTAssertEqual(crop.width, 20); XCTAssertEqual(crop.height, 16)
        XCTAssertEqual(pixel(try pixels(crop), width: 20, x: 1, y: 1), [39, 63, 34, 255])
    }

    func testAllNonrectangularMasksProduceTransparencyAndPreserveCenter() throws {
        let renderer = AnnotationRenderer(desktop: try source(), pixelScale: 1)
        let rect = CGRect(x: 0, y: 0, width: 40, height: 40)
        let vertices = [CGPoint(x: 20, y: 0), CGPoint(x: 40, y: 20),
                        CGPoint(x: 20, y: 40), CGPoint(x: 0, y: 20)]
        for shape in CaptureShape.allCases where shape != .rectangle {
            let output = try renderer.render(selection: rect, shape: shape, vertices: vertices)
            let bytes = try pixels(output)
            XCTAssertEqual(pixel(bytes, width: 40, x: 1, y: 1)[3], 0, "\(shape) corner alpha")
            XCTAssertEqual(pixel(bytes, width: 40, x: 20, y: 20)[3], 255, "\(shape) center alpha")
        }
    }

    func testAnnotationsUseTopLeftAndStayInsideShapeMask() throws {
        let renderer = AnnotationRenderer(desktop: try source(), pixelScale: 1)
        let blue = RGBAColor(red: 0, green: 0, blue: 1)
        let fill = Annotation(tool: .rectangle, start: CGPoint(x: 10, y: 5), end: CGPoint(x: 22, y: 15),
                              color: blue, filled: true)
        let image = try renderer.render(selection: CGRect(x: 5, y: 3, width: 40, height: 40),
                                         shape: .rectangle, annotations: [fill])
        let bytes = try pixels(image)
        XCTAssertEqual(pixel(bytes, width: 40, x: 10, y: 5), [0, 0, 255, 255])
        XCTAssertNotEqual(pixel(bytes, width: 40, x: 10, y: 30), [0, 0, 255, 255])
        let cover = Annotation(tool: .rectangle, start: .zero, end: CGPoint(x: 64, y: 48),
                               color: blue, filled: true)
        let circle = try renderer.render(selection: CGRect(x: 0, y: 0, width: 40, height: 40),
                                          shape: .circle, annotations: [cover])
        let circleBytes = try pixels(circle)
        XCTAssertEqual(pixel(circleBytes, width: 40, x: 1, y: 1)[3], 0)
        XCTAssertEqual(pixel(circleBytes, width: 40, x: 20, y: 20), [0, 0, 255, 255])
    }

    func testFilledEllipseLineArrowAndPenChangePixels() throws {
        let renderer = AnnotationRenderer(desktop: try source(width: 160, height: 120), pixelScale: 1)
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        let annotations = [
            Annotation(tool: .ellipse, start: CGPoint(x: 5, y: 5), end: CGPoint(x: 35, y: 35), color: red, filled: true),
            Annotation(tool: .line, start: CGPoint(x: 45, y: 20), end: CGPoint(x: 75, y: 20), color: red, width: 4),
            Annotation(tool: .arrow, start: CGPoint(x: 90, y: 20), end: CGPoint(x: 140, y: 20), color: red, width: 4, doubleArrow: true),
            Annotation(tool: .pen, start: CGPoint(x: 10, y: 70), end: CGPoint(x: 40, y: 70),
                       points: [CGPoint(x: 10, y: 70), CGPoint(x: 25, y: 65), CGPoint(x: 40, y: 70)], color: red, width: 5)
        ]
        let image = try renderer.render(selection: CGRect(x: 0, y: 0, width: 160, height: 120),
                                         shape: .rectangle, annotations: annotations)
        let bytes = try pixels(image)
        for point in [(20, 20), (60, 20), (115, 20), (25, 65)] {
            XCTAssertEqual(pixel(bytes, width: 160, x: point.0, y: point.1), [255, 0, 0, 255])
        }
        XCTAssertEqual(renderer.cachedAnnotationCount, 4)
    }

    func testPNGPreservesAlphaAndOpaqueExportCompositesWhite() throws {
        let renderer = AnnotationRenderer(desktop: try source(), pixelScale: 1)
        let circle = try renderer.render(selection: CGRect(x: 0, y: 0, width: 40, height: 40), shape: .circle)
        let data = try AnnotationRenderer.PNGData(circle)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let roundTrip = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(pixel(try pixels(roundTrip), width: 40, x: 1, y: 1)[3], 0)
        let white = try AnnotationRenderer.opaqueImage(circle)
        XCTAssertEqual(pixel(try pixels(white), width: 40, x: 1, y: 1), [255, 255, 255, 255])
        XCTAssertEqual(pixel(try pixels(white), width: 40, x: 20, y: 20),
                       pixel(try pixels(circle), width: 40, x: 20, y: 20))
    }

    func testMosaicCachesDerivedImageAndInvalidatesChangedStyle() throws {
        let renderer = AnnotationRenderer(desktop: try source(width: 32, height: 32), pixelScale: 1)
        var item = Annotation(tool: .mosaic, start: .zero, end: CGPoint(x: 32, y: 32), blockSize: 8)
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let first = try renderer.render(selection: rect, shape: .rectangle, annotations: [item])
        let bytes = try pixels(first)
        XCTAssertEqual(pixel(bytes, width: 32, x: 1, y: 1), pixel(bytes, width: 32, x: 4, y: 4))
        let again = try renderer.render(selection: rect, shape: .rectangle, annotations: [item])
        XCTAssertEqual(try pixels(again), bytes)
        XCTAssertEqual(renderer.cachedAnnotationCount, 1)
        item.blockSize = 16
        let changed = try renderer.render(selection: rect, shape: .rectangle, annotations: [item])
        XCTAssertNotEqual(try pixels(changed), bytes)
        XCTAssertEqual(renderer.cachedAnnotationCount, 1)
        renderer.pruneCache(activeIDs: []); XCTAssertEqual(renderer.cachedAnnotationCount, 0)
    }

    func testDirtyRegionSkipsCreatingMosaicOutsideClip() throws {
        let renderer = AnnotationRenderer(desktop: try source(width: 32, height: 32), pixelScale: 1)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clip(to: CGRect(x: 0, y: 0, width: 5, height: 5))
        let outside = Annotation(tool: .mosaic, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 30, y: 30))
        renderer.drawAnnotations(in: context, annotations: [outside])
        XCTAssertEqual(renderer.cachedAnnotationCount, 0)
        let visible = Annotation(tool: .mosaic, start: .zero, end: CGPoint(x: 10, y: 10))
        renderer.drawAnnotations(in: context, annotations: [outside, visible])
        XCTAssertEqual(renderer.cachedAnnotationCount, 1)
    }

    func testTransientPenDoesNotRetainPointSnapshotInCompletedCache() throws {
        let renderer = AnnotationRenderer(desktop: try source(width: 32, height: 32), pixelScale: 1)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var pen = Annotation(tool: .pen, start: CGPoint(x: 2, y: 2), end: CGPoint(x: 8, y: 8),
                             points: [CGPoint(x: 2, y: 2), CGPoint(x: 8, y: 8)])
        renderer.drawAnnotations(in: context, annotations: [pen], transientIDs: [pen.id])
        XCTAssertEqual(renderer.cachedAnnotationCount, 0)
        pen.points.append(CGPoint(x: 16, y: 12))
        renderer.drawAnnotations(in: context, annotations: [pen])
        XCTAssertEqual(renderer.cachedAnnotationCount, 1)
        renderer.drawAnnotations(in: context, annotations: [pen], transientIDs: [pen.id])
        XCTAssertEqual(renderer.cachedAnnotationCount, 0)
    }

    func testTextNumbersAndHighlighterRenderWithoutChangingSource() throws {
        let desktop = try source(width: 180, height: 100)
        let original = try pixels(desktop)
        let renderer = AnnotationRenderer(desktop: desktop, pixelScale: 1)
        let annotations = [
            Annotation(tool: .text, start: CGPoint(x: 5, y: 5), end: .zero, text: "测试\nSnap", fontSize: 18),
            Annotation(tool: .number, start: CGPoint(x: 110, y: 25), end: .zero, number: 3),
            Annotation(tool: .highlight, start: CGPoint(x: 10, y: 80), end: CGPoint(x: 140, y: 80),
                       points: [CGPoint(x: 10, y: 80), CGPoint(x: 140, y: 80)], width: 3)
        ]
        let output = try renderer.render(selection: CGRect(x: 0, y: 0, width: 180, height: 100),
                                          shape: .rectangle, annotations: annotations)
        let bytes = try pixels(output)
        XCTAssertNotEqual(bytes, original)
        XCTAssertNotEqual(pixel(bytes, width: 180, x: 60, y: 80), pixel(original, width: 180, x: 60, y: 80))
        XCTAssertNotEqual(pixel(bytes, width: 180, x: 110, y: 14), pixel(original, width: 180, x: 110, y: 14))
        XCTAssertEqual(try pixels(desktop), original)
    }

    func testInvalidInputsFailBeforeAllocatingOutput() throws {
        let desktop = try source()
        XCTAssertThrowsError(try AnnotationRenderer(desktop: desktop, pixelScale: 0).render(
            selection: CGRect(x: 0, y: 0, width: 10, height: 10), shape: .rectangle))
        let renderer = AnnotationRenderer(desktop: desktop, pixelScale: 1)
        XCTAssertThrowsError(try renderer.render(selection: .zero, shape: .rectangle))
        XCTAssertThrowsError(try renderer.render(selection: CGRect(x: -5, y: 0, width: 10, height: 10), shape: .rectangle))
        XCTAssertThrowsError(try renderer.render(selection: CGRect(x: 0, y: 0, width: 10, height: 10), shape: .polygon))
    }
}

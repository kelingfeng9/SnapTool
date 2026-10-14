import AppKit
import CoreGraphics
import CoreText
import ImageIO
import XCTest
@testable import SnapTool

final class ServicesTests: XCTestCase {
    private func quadrantImage(side: Int = 80) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                if x < side / 2, y < side / 2 {
                    bytes[offset] = 255
                    bytes[offset + 3] = 255
                } else if x >= side / 2, y >= side / 2 {
                    bytes[offset + 2] = 255
                    bytes[offset + 3] = 255
                }
            }
        }
        return try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue),
                                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent))
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
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

    @MainActor
    func testPNGAndClipboardTIFFPreserveTransparencyAndOrientation() async throws {
        let source = try quadrantImage()
        let item = try OutputService.clipboardItem(source)
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let image = try decoded(XCTUnwrap(item.data(forType: type)))
            let bytes = try pixels(image)
            XCTAssertEqual(pixel(bytes, width: 80, x: 10, y: 10), [255, 0, 0, 255])
            XCTAssertEqual(pixel(bytes, width: 80, x: 70, y: 70), [0, 0, 255, 255])
            XCTAssertEqual(pixel(bytes, width: 80, x: 70, y: 10)[3], 0)
        }
        let png = try OutputService.encode(source, format: .png)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    @MainActor
    func testJPEGAndBMPHaveWhiteTransparencyAndKeepTopAndBottomColors() async throws {
        let source = try quadrantImage()
        for format in [OutputService.ImageFormat.jpeg, .bmp] {
            let data = try OutputService.encode(source, format: format)
            if format == .jpeg { XCTAssertEqual(Array(data.prefix(2)), [255, 216]) }
            else { XCTAssertEqual(Array(data.prefix(2)), [66, 77]) }
            let bytes = try pixels(decoded(data))
            let white = pixel(bytes, width: 80, x: 70, y: 10)
            XCTAssertTrue(white[0..<3].allSatisfy { $0 >= 245 })
            XCTAssertEqual(white[3], 255)
            let red = pixel(bytes, width: 80, x: 10, y: 10)
            let blue = pixel(bytes, width: 80, x: 70, y: 70)
            XCTAssertGreaterThan(red[0], 240); XCTAssertLessThan(red[2], 15)
            XCTAssertGreaterThan(blue[2], 240); XCTAssertLessThan(blue[0], 15)
        }
    }

    @MainActor
    func testSaveFormatSurvivesNextSessionAndInvalidValueFallsBackToPNG() async throws {
        let suite = "SnapTool.ServicesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(OutputService.rememberedFormat(in: defaults), .png)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapTool-test.jpg")
        OutputService.rememberSaveLocation(for: url, format: .jpeg, in: defaults)
        let next = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(OutputService.rememberedFormat(in: next), .jpeg)
        OutputService.rememberSaveLocation(for: url, format: .bmp, in: defaults)
        XCTAssertEqual(OutputService.rememberedFormat(in: next), .bmp)
        defaults.set(999, forKey: "SnapTool.lastSaveFormat")
        XCTAssertEqual(OutputService.rememberedFormat(in: defaults), .png)
    }

    @MainActor
    func testPinTransparentHitTestAndImageDrawHaveSameTopLeftOrientation() async throws {
        _ = NSApplication.shared
        let image = try quadrantImage(side: 8)
        let view = PinImageView(image: image)
        view.frame = NSRect(x: 0, y: 0, width: 8, height: 8)
        XCTAssertTrue(view.hasOpaquePixel(at: NSPoint(x: 1, y: 1)))
        XCTAssertFalse(view.hasOpaquePixel(at: NSPoint(x: 6, y: 1)))
        XCTAssertFalse(view.hasOpaquePixel(at: NSPoint(x: 1, y: 6)))
        XCTAssertTrue(view.hasOpaquePixel(at: NSPoint(x: 6, y: 6)))
        XCTAssertFalse(view.hasOpaquePixel(at: NSPoint(x: -1, y: 1)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8,
                                             bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue))
        context.translateBy(x: 0, y: 8); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let bytes = Array(UnsafeBufferPointer(start: pointer, count: 8 * 8 * 4))
        XCTAssertEqual(pixel(bytes, width: 8, x: 1, y: 1), [255, 0, 0, 255])
        XCTAssertEqual(pixel(bytes, width: 8, x: 6, y: 6), [0, 0, 255, 255])
        XCTAssertEqual(pixel(bytes, width: 8, x: 6, y: 1)[3], 0)
    }

    @MainActor
    func testWindowCoordinatesIncludeScreensAboveAndLeftOfPrimary() async throws {
        let desktop = NSRect(x: -1440, y: 0, width: 3360, height: 1980)
        let topLeftScreenWindow = CGRect(x: -1300, y: -750, width: 300, height: 200)
        XCTAssertEqual(CaptureService.desktopRect(quartzFrame: topLeftScreenWindow,
                                                  desktop: desktop, primaryTop: 1080),
                       CGRect(x: 140, y: 150, width: 300, height: 200))
        let primaryWindow = CGRect(x: 100, y: 50, width: 640, height: 480)
        XCTAssertEqual(CaptureService.desktopRect(quartzFrame: primaryWindow,
                                                  desktop: desktop, primaryTop: 1080),
                       CGRect(x: 1540, y: 950, width: 640, height: 480))
    }

    @MainActor
    func testCancelledCaptureDoesNotRequestScreenPermissionAndCancelledOCRDoesNotRun() async throws {
        let capture = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CaptureService.capture()
        }
        do { _ = try await capture.value; XCTFail("Expected capture cancellation before permission request") }
        catch is CancellationError {}
        let image = try quadrantImage(side: 8)
        let ocr = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OCRService.recognize(image: image)
        }
        do { _ = try await ocr.value; XCTFail("Expected OCR cancellation before Vision request") }
        catch is CancellationError {}
    }

    func testVisionRecognizesARealLocalTextImage() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 110,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 110))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 42, nil)
        let text = NSAttributedString(string: "HELLO MAC 2026", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 16, y: 35)
        CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
        let result = try await OCRService.recognize(image: XCTUnwrap(context.makeImage()), language: "en-US")
        XCTAssertTrue(result.uppercased().contains("HELLO"), result)
        XCTAssertTrue(result.contains("2026"), result)
    }
}

import AppKit
import CoreGraphics
import XCTest
@testable import SnapTool

final class ColorSwatchButtonTests: XCTestCase {
    private struct Raster {
        let width: Int
        let bytes: [UInt8]
        func pixel(x: Int, y: Int) -> [UInt8] {
            let index = (y * width + x) * 4
            return Array(bytes[index..<(index + 4)])
        }
    }

    @MainActor
    private func render(color: NSColor, state: NSControl.StateValue = .off) throws -> Raster {
        let width = 52, height = 56
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue))
        // Match the top-left coordinate system supplied by the actual flipped NSView.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 2, y: -2)
        ColorSwatchButton.drawSwatch(in: context, bounds: CGRect(x: 0, y: 0, width: 26, height: 28),
                                    color: color, state: state)
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Raster(width: width, bytes: Array(UnsafeBufferPointer(start: pointer, count: width * height * 4)))
    }

    @MainActor
    func testPaletteCentersHaveTheirActualRGBColors() async throws {
        let values: [(NSColor, [UInt8])] = [
            (NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), [255, 0, 0, 255]),
            (NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), [0, 255, 0, 255]),
            (NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), [0, 0, 255, 255]),
            (.white, [255, 255, 255, 255]),
            (.black, [0, 0, 0, 255])
        ]
        for (color, expected) in values {
            XCTAssertEqual(try render(color: color).pixel(x: 26, y: 28), expected)
        }
    }

    @MainActor
    func testWhiteAndBlackSwatchesBothHaveVisibleContrastEdges() async throws {
        let white = try render(color: .white)
        let black = try render(color: .black)
        let whiteEdge = white.pixel(x: 8, y: 28)
        let blackEdge = black.pixel(x: 8, y: 28)
        XCTAssertLessThan(whiteEdge[0], 160)
        XCTAssertGreaterThan(blackEdge[0], 100)
        XCTAssertEqual(whiteEdge[3], 255)
        XCTAssertEqual(blackEdge[3], 255)
    }

    @MainActor
    func testSelectedStateAddsAnOuterRingAndAContrastingCheckmark() async throws {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let off = try render(color: red)
        let on = try render(color: red, state: .on)
        XCTAssertEqual(off.pixel(x: 3, y: 28)[3], 0)
        let ring = on.pixel(x: 3, y: 28)
        XCTAssertEqual(ring[3], 255)
        XCTAssertGreaterThan(ring[2], ring[0])
        // The checkmark's lower vertex lies well inside the unchanged red color block.
        XCTAssertEqual(off.pixel(x: 24, y: 34), [255, 0, 0, 255])
        let checkmark = on.pixel(x: 24, y: 34)
        XCTAssertGreaterThan(checkmark[1], 180)
        XCTAssertGreaterThan(checkmark[2], 180)
    }

    @MainActor
    func testButtonStateInvalidatesDisplayAndExposesColorNameAndSelection() async throws {
        _ = NSApplication.shared
        let button = ColorSwatchButton(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                                      name: "红色", target: nil, action: Selector("selectColor:"))
        XCTAssertEqual(button.frame.size, NSSize(width: 26, height: 28))
        XCTAssertEqual(button.accessibilityLabel(), "标注颜色：红色")
        XCTAssertEqual(button.accessibilityValue() as? String, "未选中")
        button.needsDisplay = false
        button.state = .on
        XCTAssertTrue(button.needsDisplay)
        XCTAssertEqual(button.accessibilityValue() as? String, "已选中")
        button.needsDisplay = false
        button.state = .off
        XCTAssertTrue(button.needsDisplay)
        XCTAssertEqual(button.accessibilityValue() as? String, "未选中")
    }
}

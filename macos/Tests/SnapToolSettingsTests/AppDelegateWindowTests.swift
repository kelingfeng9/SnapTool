import AppKit
import XCTest
@testable import SnapTool

final class AppDelegateWindowTests: XCTestCase {
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testCaptureToolbarOpensSettingsAboveItsWindowAndRecoversItAfterMinimizing() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let display = try XCTUnwrap(NSScreen.screens.first)
            let frame = display.frame
            let context = try XCTUnwrap(CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            let app = AppDelegate()
            try withExtendedLifetime(app) {
                app.presentCapture(DesktopCapture(image: image, frame: frame, scale: 1, windows: []))
                let overlay = try XCTUnwrap(NSApp.windows.compactMap { $0 as? CaptureWindow }.first { $0.isVisible })
                let canvas = overlay.viewport.canvas
                let entry = try XCTUnwrap(descendants(canvas).compactMap { $0 as? NSButton }.first { $0.title == "快捷键设置" })
                entry.performClick(nil)
                let settings = try XCTUnwrap(NSApp.windows.first { $0.title == "SnapTool 设置" && $0.isVisible })
                defer { settings.close() }
                XCTAssertTrue(settings.parent === overlay)
                XCTAssertGreaterThan(settings.level.rawValue, overlay.level.rawValue)
                XCTAssertTrue(settings.isVisible)
                settings.miniaturize(nil)
                entry.performClick(nil)
                XCTAssertFalse(settings.isMiniaturized)
                XCTAssertTrue(settings.isVisible)
                let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                    windowNumber: overlay.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                canvas.keyDown(with: escape)
                XCTAssertFalse(overlay.isVisible)
                XCTAssertNil(settings.parent)
                XCTAssertEqual(settings.level, .normal)
            }
        }
    }
}

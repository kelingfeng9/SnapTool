import AppKit
import CoreGraphics
import XCTest
import SnapCore
@testable import SnapTool

/// Native window/view and event routing tests using virtual display frames.
/// These do not request TCC access or verify physical displays / separate Spaces.
final class CaptureSessionTests: XCTestCase {
    @MainActor
    private func withSession(_ body: (CaptureSession, [CGRect], Preferences) throws -> Void) throws {
        _ = NSApplication.shared
        let frames = [CGRect(x: -640, y: 0, width: 640, height: 480),
                      CGRect(x: 0, y: 0, width: 800, height: 600)]
        let desktopFrame = frames[0].union(frames[1])
        let context = try XCTUnwrap(CGContext(data: nil, width: 1440, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 0.30, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1440, height: 600))
        let image = try XCTUnwrap(context.makeImage())
        let capture = DesktopCapture(image: image, frame: desktopFrame, scale: 1, windows: [])
        let suite = "SnapTool.CaptureSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = Preferences(defaults: defaults)
        let session = CaptureSession(capture: capture, preferences: preferences, displayFrames: frames)
        defer { session.close(); defaults.removePersistentDomain(forName: suite) }
        session.makeKeyAndOrderFront(nil)
        session.activate(at: CGPoint(x: 100, y: 200))
        try body(session, frames, preferences)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, desktopPoint: CGPoint,
                       window: NSWindow, geometry: DesktopGeometry, time: TimeInterval) throws -> NSEvent {
        let global = geometry.appKitPoint(fromDesktop: desktopPoint)
        let local = window.convertPoint(fromScreen: global)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                                                timestamp: time, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func key(_ characters: String, code: UInt16, window: NSWindow,
                     modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testEachDisplayHasAnIndependentWindowSharingTheSameEditorState() async throws {
        try await MainActor.run {
            try withSession { session, frames, _ in
                XCTAssertEqual(session.windows.count, 2)
                XCTAssertEqual(session.windows.map(\.frame), frames)
                XCTAssertFalse(session.windows[0] === session.windows[1])
                XCTAssertFalse(session.windows[0].viewport === session.windows[1].viewport)
                for window in session.windows {
                    XCTAssertTrue(window.viewport.canvas === session.canvas,
                                  "Both viewports must reuse the editor that owns the bitmap and renderer")
                    XCTAssertEqual(window.viewport.desktopViewport, session.geometry.viewport(for: window.frame))
                }
                let item = Annotation(tool: .line, start: CGPoint(x: 550, y: 180), end: CGPoint(x: 750, y: 240))
                let selection = CGRect(x: 500, y: 150, width: 300, height: 200)
                session.canvas.loadDocumentationExample(selection: selection, annotations: [item])
                for window in session.windows {
                    XCTAssertEqual(window.viewport.canvas.selectionRect, selection)
                    XCTAssertEqual(window.viewport.canvas.annotations, [item])
                }
            }
        }
    }

    func testActiveCanvasMovesBetweenViewportsWithDesktopCoordinatesPreserved() async throws {
        try await MainActor.run {
            try withSession { session, _, _ in
                let left = session.windows[0], right = session.windows[1]
                let selection = CGRect(x: 500, y: 150, width: 300, height: 200)
                session.canvas.loadDocumentationExample(selection: selection)
                session.activate(at: CGPoint(x: 100, y: 200))
                XCTAssertTrue(session.activeWindow === left)
                XCTAssertTrue(session.canvas.superview === left.viewport)
                XCTAssertEqual(session.canvas.frame.origin, CGPoint(x: 0, y: -120))
                XCTAssertEqual(session.canvas.activeViewport, left.viewport.desktopViewport)
                session.activate(at: CGPoint(x: 700, y: 200))
                XCTAssertTrue(session.activeWindow === right)
                XCTAssertTrue(session.canvas.superview === right.viewport)
                XCTAssertFalse(left.viewport.subviews.contains { $0 === session.canvas })
                XCTAssertEqual(session.canvas.frame.origin, CGPoint(x: -640, y: 0))
                XCTAssertEqual(session.canvas.bounds, session.geometry.bounds)
                XCTAssertEqual(session.canvas.selectionRect, selection)
                session.activate(at: CGPoint(x: 100, y: 200))
                XCTAssertTrue(session.canvas.superview === left.viewport)
                XCTAssertEqual(session.canvas.selectionRect, selection)
            }
        }
    }

    func testMouseUpFromStartingWindowCompletesCrossDisplaySelectionWithoutFinalDragEvent() async throws {
        try await MainActor.run {
            try withSession { session, _, _ in
                let left = session.windows[0], right = session.windows[1]
                let down = try mouse(.leftMouseDown, desktopPoint: CGPoint(x: 600, y: 220),
                                     window: left, geometry: session.geometry, time: 10)
                let up = try mouse(.leftMouseUp, desktopPoint: CGPoint(x: 760, y: 320),
                                   window: left, geometry: session.geometry, time: 11)
                XCTAssertTrue(down.window === left)
                XCTAssertTrue(up.window === left)
                XCTAssertGreaterThan(up.locationInWindow.x, left.frame.width)
                left.viewport.mouseDown(with: down)
                // Intentionally omit mouseDragged: mouseUp must use its final point.
                left.viewport.mouseUp(with: up)
                XCTAssertEqual(session.canvas.selectionRect, CGRect(x: 600, y: 220, width: 160, height: 100))
                XCTAssertTrue(session.activeWindow === right)
                XCTAssertTrue(session.canvas.superview === right.viewport)
            }
        }
    }

    func testKeyboardUndoAndRedoUseOneHistoryAcrossDisplays() async throws {
        try await MainActor.run {
            try withSession { session, _, _ in
                let left = session.windows[0], right = session.windows[1]
                let first = Annotation(tool: .rectangle, start: CGPoint(x: 540, y: 180), end: CGPoint(x: 580, y: 220))
                let second = Annotation(tool: .arrow, start: CGPoint(x: 700, y: 180), end: CGPoint(x: 760, y: 220))
                session.canvas.loadDocumentationExample(selection: CGRect(x: 500, y: 150, width: 300, height: 200),
                                                        annotations: [first, second])
                left.viewport.keyDown(with: try key("z", code: 6, window: left, modifiers: .command))
                XCTAssertEqual(session.canvas.annotations, [first])
                session.activate(at: CGPoint(x: 700, y: 200))
                right.viewport.keyDown(with: try key("z", code: 6, window: right, modifiers: .command))
                XCTAssertTrue(session.canvas.annotations.isEmpty)
                right.viewport.keyDown(with: try key("z", code: 6, window: right, modifiers: [.command, .shift]))
                XCTAssertEqual(session.canvas.annotations, [first])
                session.activate(at: CGPoint(x: 100, y: 200))
                left.viewport.keyDown(with: try key("y", code: 16, window: left, modifiers: .command))
                XCTAssertEqual(session.canvas.annotations, [first, second])
            }
        }
    }

    func testPalettePaintsDistinctColorsAndSettingsButtonDispatchesItsAction() async throws {
        try await MainActor.run {
            try withSession { session, _, preferences in
                session.canvas.loadDocumentationExample(selection: CGRect(x: 500, y: 150, width: 300, height: 200))
                let views = descendants(of: session.canvas)
                let settings = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "快捷键设置" })
                var settingsCalls = 0
                session.canvas.onSettings = { settingsCalls += 1 }
                settings.performClick(nil)
                XCTAssertEqual(settingsCalls, 1)
                let colors = views.compactMap { $0 as? ColorSwatchButton }.sorted { $0.tag < $1.tag }
                XCTAssertEqual(colors.count, 7)
                var samples: [[UInt8]] = []
                for button in colors {
                    let context = try XCTUnwrap(CGContext(data: nil, width: 26, height: 28, bitsPerComponent: 8,
                                                         bytesPerRow: 104, space: CGColorSpaceCreateDeviceRGB(),
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                            CGBitmapInfo.byteOrder32Big.rawValue))
                    ColorSwatchButton.drawSwatch(in: context, bounds: button.bounds,
                                                 color: button.swatchColor, state: .off)
                    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                    samples.append(Array(UnsafeBufferPointer(start: bytes.advanced(by: (10 * 26 + 7) * 4), count: 4)))
                }
                XCTAssertGreaterThan(samples[0][0], 200); XCTAssertLessThan(samples[0][1], 50)
                XCTAssertGreaterThan(samples[3][1], 150); XCTAssertLessThan(samples[3][0], 100)
                XCTAssertGreaterThan(samples[4][2], 200); XCTAssertLessThan(samples[4][0], 100)
                XCTAssertNotEqual(samples[0], samples[3]); XCTAssertNotEqual(samples[3], samples[4])
                colors[4].performClick(nil)
                XCTAssertEqual(colors[4].state, .on)
                let selected = try XCTUnwrap(preferences.defaultColor.usingColorSpace(.sRGB))
                XCTAssertGreaterThan(selected.blueComponent, selected.redComponent)
            }
        }
    }

    func testNumberSizeShortcutAffectsNewAndSelectedAnnotationsAndUndoRestoresSize() async throws {
        try await MainActor.run {
            try withSession { session, _, _ in
                let right = session.windows[1]
                session.canvas.loadDocumentationExample(selection: CGRect(x: 500, y: 150, width: 300, height: 200))
                session.activate(at: CGPoint(x: 700, y: 200))
                let numberTool = try XCTUnwrap(descendants(of: session.canvas).compactMap { $0 as? NSButton }
                    .first { $0.title == "序号" })
                numberTool.performClick(nil)
                right.viewport.keyDown(with: try key("]", code: 30, window: right))
                let point = CGPoint(x: 700, y: 200)
                right.viewport.mouseDown(with: try mouse(.leftMouseDown, desktopPoint: point,
                                                        window: right, geometry: session.geometry, time: 30))
                right.viewport.mouseUp(with: try mouse(.leftMouseUp, desktopPoint: point,
                                                      window: right, geometry: session.geometry, time: 31))
                let created = try XCTUnwrap(session.canvas.annotations.first)
                XCTAssertEqual(created.tool, .number)
                XCTAssertEqual(created.fontSize, 26, "The number shortcut must change its visible font/radius, not unused stroke width")
                XCTAssertEqual(created.number, 1)
                right.viewport.keyDown(with: try key("z", code: 6, window: right, modifiers: .command))
                XCTAssertTrue(session.canvas.annotations.isEmpty)
                right.viewport.keyDown(with: try key("z", code: 6, window: right, modifiers: [.command, .shift]))
                XCTAssertEqual(session.canvas.annotations, [created])

                right.viewport.keyDown(with: try key("0", code: 29, window: right))
                right.viewport.mouseDown(with: try mouse(.leftMouseDown, desktopPoint: point,
                                                        window: right, geometry: session.geometry, time: 32))
                right.viewport.mouseUp(with: try mouse(.leftMouseUp, desktopPoint: point,
                                                      window: right, geometry: session.geometry, time: 33))
                right.viewport.keyDown(with: try key("]", code: 30, window: right))
                let enlarged = try XCTUnwrap(session.canvas.annotations.first)
                XCTAssertEqual(enlarged.id, created.id)
                XCTAssertEqual(enlarged.fontSize, 28)
                XCTAssertGreaterThan(AnnotationGeometry.bounds(of: enlarged).width,
                                     AnnotationGeometry.bounds(of: created).width)
                right.viewport.keyDown(with: try key("z", code: 6, window: right, modifiers: .command))
                XCTAssertEqual(session.canvas.annotations, [created])
                right.viewport.keyDown(with: try key("y", code: 16, window: right, modifiers: .command))
                XCTAssertEqual(session.canvas.annotations, [enlarged])
            }
        }
    }

    func testDirtyRectAndFullInvalidationNotifyInactiveViewport() async throws {
        try await MainActor.run {
            try withSession { session, _, _ in
                let right = session.windows[1]
                right.viewport.needsDisplay = false
                session.canvas.setNeedsDisplay(CGRect(x: 700, y: 200, width: 30, height: 20))
                XCTAssertTrue(right.viewport.needsDisplay)
                right.viewport.needsDisplay = false
                session.canvas.needsDisplay = true
                XCTAssertTrue(right.viewport.needsDisplay)
            }
        }
    }

    func testEscapeClosesEveryOverlayAndQueuedEscapeDoesNotRepeatCallback() async throws {
        try await MainActor.run {
            try withSession { session, _, _ in
                let left = session.windows[0], right = session.windows[1]
                let leftEscape = try key("\u{1b}", code: 53, window: left)
                let rightEscape = try key("\u{1b}", code: 53, window: right)
                var closeCalls = 0
                session.canvas.onClose = { [weak session] in closeCalls += 1; session?.close() }
                left.viewport.keyDown(with: leftEscape)
                XCTAssertEqual(closeCalls, 1)
                XCTAssertTrue(session.windows.isEmpty)
                XCTAssertNil(session.activeWindow)
                XCTAssertNil(session.canvas.superview)
                XCTAssertFalse(left.isVisible); XCTAssertFalse(right.isVisible)
                // Simulate an already queued event from the second display.
                right.viewport.keyDown(with: rightEscape)
                session.close()
                XCTAssertEqual(closeCalls, 1)
            }
        }
    }
}

import AppKit
import XCTest
@testable import SnapTool

/// Creates only test-owned objects. XCTest owns the application/run-loop lifecycle.
@MainActor
private final class SettingsFixture {
    let suite: String
    let defaults: UserDefaults
    let preferences: Preferences
    let manager: HotKeyManager
    let controller: SettingsWindowController

    init() {
        _ = NSApplication.shared
        suite = "SnapTool.SettingsWindowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        preferences = Preferences(defaults: defaults)
        // Never register a real global hot key or change system login items.
        manager = HotKeyManager()
        controller = SettingsWindowController(preferences: preferences, hotKeyManager: manager)
    }

    func cleanup() {
        controller.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

final class SettingsWindowTests: XCTestCase {
    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private func control<T: NSView>(_ identifier: String, in controller: SettingsWindowController, as type: T.Type) throws -> T {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(of: content).first { $0.identifier?.rawValue == identifier } as? T)
    }

    // Async XCTest entry points retain the correct concurrency ABI. Each complete
    // test runs on MainActor, rather than hopping through nested MainActor.run closures.
    @MainActor
    func testConstructedWindowContainsBoundControlsBeforeFirstShow() async throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        XCTAssertTrue(Thread.isMainThread)
        let controller = fixture.controller
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.isWindowLoaded)
        XCTAssertEqual(window.title, "SnapTool 设置")
        let content = try XCTUnwrap(window.contentView)
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
        // AppKit may add internal buttons; verify all five user-facing actions.
        for title in ["录制", "截图时自动识别本工具的贴图窗口", "登录 Mac 时启动", "系统登录项…", "保存设置"] {
            let button = try XCTUnwrap(buttons.first { $0.title == title }, title)
            XCTAssertNotNil(button.action, button.title)
            XCTAssertTrue((button.target as? SettingsWindowController) === controller, button.title)
        }
        let field = try control("settings.shortcut", in: controller, as: NSTextField.self)
        XCTAssertEqual(field.stringValue, "⌃⌥A")
        XCTAssertTrue(field.isEditable)
        let save = try control("settings.save", in: controller, as: NSButton.self)
        XCTAssertEqual(save.keyEquivalent, "\r")
    }

    @MainActor
    func testShowWindowRecoversVisibilityAndReusesClosedWindow() async throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller
        let original = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        XCTAssertTrue(original.isVisible)
        XCTAssertFalse(original.isMiniaturized)
        XCTAssertTrue(original.collectionBehavior.contains(.moveToActiveSpace))
        controller.close()
        XCTAssertFalse(original.isVisible)
        controller.showWindow(nil)
        XCTAssertTrue(controller.window === original)
        XCTAssertTrue(original.isVisible)
        let save = try control("settings.save", in: controller, as: NSButton.self)
        let content = try XCTUnwrap(original.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(save.isHidden)
        XCTAssertTrue(content.bounds.contains(save.convert(save.bounds, to: content)))
    }

    @MainActor
    func testShowWindowRestoresMiniaturizedWindowAndPreservesDraft() async throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let field = try control("settings.shortcut", in: controller, as: NSTextField.self)
        field.stringValue = "Cmd+Shift+S"
        XCTAssertTrue(window.styleMask.contains(.miniaturizable), "This native test window must support miniaturization.")
        window.miniaturize(nil)
        // AppKit's minimize animation completes after this call returns. Yield the
        // main actor so the native run loop can finish before checking its state.
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertTrue(window.isMiniaturized)
        controller.showWindow(nil)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(field.stringValue, "Cmd+Shift+S")
    }

    @MainActor
    func testRecordingButtonStartsCancelsAndAcceptsRegisteredCombination() async throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller
        let manager = fixture.manager
        controller.showWindow(nil)
        let field = try control("settings.shortcut", in: controller, as: NSTextField.self)
        let record = try control("settings.record", in: controller, as: NSButton.self)
        record.performClick(nil)
        XCTAssertTrue(manager.isSuspended)
        XCTAssertNotNil(manager.onSuspendedTrigger)
        XCTAssertFalse(field.isEditable)
        XCTAssertEqual(record.title, "取消录制")
        record.performClick(nil)
        XCTAssertFalse(manager.isSuspended)
        XCTAssertNil(manager.onSuspendedTrigger)
        XCTAssertTrue(field.isEditable)
        XCTAssertEqual(field.stringValue, "⌃⌥A")
        record.performClick(nil)
        manager.onSuspendedTrigger?(try HotKeyShortcut.parse("Cmd+Shift+S"))
        XCTAssertFalse(manager.isSuspended)
        XCTAssertNil(manager.onSuspendedTrigger)
        XCTAssertTrue(field.isEditable)
        XCTAssertEqual(field.stringValue, "⇧⌘S")
        XCTAssertEqual(record.title, "录制")
    }

    @MainActor
    func testInvalidSaveReportsProblemWithoutChangingStoredShortcut() async throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller
        controller.showWindow(nil)
        let field = try control("settings.shortcut", in: controller, as: NSTextField.self)
        field.stringValue = "Shift+A"
        let save = try control("settings.save", in: controller, as: NSButton.self)
        save.performClick(nil)
        XCTAssertEqual(fixture.preferences.hotkey, .defaultCapture)
        XCTAssertNil(fixture.manager.shortcut)
        let status = try control("settings.status", in: controller, as: NSTextField.self)
        XCTAssertTrue(status.stringValue.contains("至少需要"))
        XCTAssertEqual(status.textColor, NSColor.systemRed)
    }

    @MainActor
    func testClosingDuringRecordingReleasesSuspendedTrigger() async throws {
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller
        let manager = fixture.manager
        controller.showWindow(nil)
        let record = try control("settings.record", in: controller, as: NSButton.self)
        record.performClick(nil)
        XCTAssertTrue(manager.isSuspended)
        controller.close()
        XCTAssertFalse(manager.isSuspended)
        XCTAssertNil(manager.onSuspendedTrigger)
    }
}

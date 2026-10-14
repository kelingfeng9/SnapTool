import AppKit
import XCTest
@testable import SnapTool

final class SettingsWindowTests: XCTestCase {
    @MainActor private static var didInitializeApplication = false

    @MainActor
    private func withSettings(_ body: (SettingsWindowController, HotKeyManager, Preferences) throws -> Void) rethrows {
        let app = NSApplication.shared
        if !Self.didInitializeApplication {
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            Self.didInitializeApplication = true
        }
        let suite = "SnapTool.SettingsWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        // Never register a real global hot key or change system login items in these tests.
        let manager = HotKeyManager()
        let controller = SettingsWindowController(preferences: preferences, hotKeyManager: manager)
        defer {
            controller.close()
            defaults.removePersistentDomain(forName: suite)
        }
        try body(controller, manager, preferences)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private func control<T: NSView>(_ identifier: String, in controller: SettingsWindowController, as type: T.Type) throws -> T {
        let content = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(of: content).first { $0.identifier?.rawValue == identifier } as? T)
    }

    func testConstructedWindowContainsBoundControlsBeforeFirstShow() async throws {
        try await MainActor.run {
            try withSettings { controller, _, _ in
                let window = try XCTUnwrap(controller.window)
                XCTAssertTrue(controller.isWindowLoaded)
                XCTAssertEqual(window.title, "SnapTool 设置")
                let content = try XCTUnwrap(window.contentView)
                let buttons = descendants(of: content).compactMap { $0 as? NSButton }
                // AppKit may add its own internal buttons; verify the five user-facing actions.
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
        }
    }

    func testShowWindowRecoversVisibilityAndReusesClosedWindow() async throws {
        try await MainActor.run {
            try withSettings { controller, _, _ in
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
        }
    }

    func testShowWindowRestoresMiniaturizedWindowAndPreservesDraft() async throws {
        try await MainActor.run {
            try withSettings { controller, _, _ in
                controller.showWindow(nil)
                let window = try XCTUnwrap(controller.window)
                let field = try control("settings.shortcut", in: controller, as: NSTextField.self)
                field.stringValue = "Cmd+Shift+S"
                window.miniaturize(nil)
                XCTAssertTrue(window.isMiniaturized)
                controller.showWindow(nil)
                XCTAssertFalse(window.isMiniaturized)
                XCTAssertTrue(window.isVisible)
                XCTAssertEqual(field.stringValue, "Cmd+Shift+S")
            }
        }
    }

    func testRecordingButtonStartsCancelsAndAcceptsRegisteredCombination() async throws {
        try await MainActor.run {
            try withSettings { controller, manager, _ in
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
        }
    }

    func testInvalidSaveReportsProblemWithoutChangingStoredShortcut() async throws {
        try await MainActor.run {
            try withSettings { controller, manager, preferences in
                controller.showWindow(nil)
                let field = try control("settings.shortcut", in: controller, as: NSTextField.self)
                field.stringValue = "Shift+A"
                let save = try control("settings.save", in: controller, as: NSButton.self)
                save.performClick(nil)
                XCTAssertEqual(preferences.hotkey, .defaultCapture)
                XCTAssertNil(manager.shortcut)
                let status = try control("settings.status", in: controller, as: NSTextField.self)
                XCTAssertTrue(status.stringValue.contains("至少需要"))
                XCTAssertEqual(status.textColor, NSColor.systemRed)
            }
        }
    }

    func testClosingDuringRecordingReleasesSuspendedTrigger() async throws {
        try await MainActor.run {
            try withSettings { controller, manager, _ in
                controller.showWindow(nil)
                let record = try control("settings.record", in: controller, as: NSButton.self)
                record.performClick(nil)
                XCTAssertTrue(manager.isSuspended)
                controller.close()
                XCTAssertFalse(manager.isSuspended)
                XCTAssertNil(manager.onSuspendedTrigger)
            }
        }
    }
}

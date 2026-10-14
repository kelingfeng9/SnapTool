import AppKit
import XCTest
@testable import SnapTool

final class HotKeyShortcutTests: XCTestCase {
    func testDefaultAndTextFormsAgree() throws {
        XCTAssertEqual(HotKeyShortcut.defaultCapture.displayName, "⌃⌥A")
        XCTAssertEqual(try HotKeyShortcut.parse("Ctrl+Option+A"), .defaultCapture)
        XCTAssertEqual(try HotKeyShortcut.parse("⌃⌥A"), .defaultCapture)
        XCTAssertEqual(try HotKeyShortcut.parse(" ctrl + alt + a "), .defaultCapture)
        XCTAssertEqual(try HotKeyShortcut.parse("Cmd+Shift+S").displayName, "⇧⌘S")
    }

    func testEverySupportedKeyRoundTrips() throws {
        for code in HotKeyShortcut.keyNames.keys {
            let value = HotKeyShortcut(keyCode: code, modifierFlags: UInt32(NSEvent.ModifierFlags.control.rawValue))
            XCTAssertEqual(try HotKeyShortcut.parse(value.displayName), value, "keyCode \(code)")
        }
    }

    func testAliasesAndFunctionKeys() throws {
        XCTAssertEqual(try HotKeyShortcut.parse("Control+Space").keyCode, 49)
        XCTAssertEqual(try HotKeyShortcut.parse("Ctrl+Return").keyCode, 36)
        XCTAssertEqual(try HotKeyShortcut.parse("Ctrl+Tab").keyCode, 48)
        XCTAssertEqual(try HotKeyShortcut.parse("Cmd+Left").keyCode, 123)
        XCTAssertEqual(try HotKeyShortcut.parse("Option+F20").keyCode, 90)
        XCTAssertEqual(try HotKeyShortcut.parse("Ctrl+Home").keyCode, 115)
    }

    func testAllTwentyFunctionKeysAreAvailableAndExtendedKeysHaveCorrectCodes() throws {
        for number in 1...20 {
            XCTAssertEqual(try HotKeyShortcut.parse("Ctrl+F\(number)").displayName, "⌃F\(number)")
        }
        let extended: [(String, UInt32)] = [("F13", 105), ("F14", 107), ("F15", 113), ("F16", 106)]
        for (name, code) in extended {
            let shortcut = try HotKeyShortcut.parse("Option+\(name)")
            XCTAssertEqual(shortcut.keyCode, code)
            XCTAssertEqual(try HotKeyShortcut.parse(shortcut.displayName), shortcut)
        }
    }

    func testMalformedAndUnmodifiedShortcutsAreRejected() {
        for text in ["A", "Shift+A", "Ctrl++A", "Ctrl+", "Ctrl+Ctrl+A", "Meta+A", "Ctrl+Esc", "Ctrl+F21", "Ctrl+A+B"] {
            XCTAssertThrowsError(try HotKeyShortcut.parse(text), text)
        }
        XCTAssertThrowsError(try HotKeyShortcut(keyCode: 53, modifierFlags: UInt32(NSEvent.ModifierFlags.command.rawValue)).validate())
        XCTAssertThrowsError(try HotKeyShortcut(keyCode: 0, modifierFlags: UInt32.max).validate())
    }

    func testCodablePreservesHardwareKeyAndFlags() throws {
        let value = try HotKeyShortcut.parse("Ctrl+Option+Shift+Command+Q")
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(HotKeyShortcut.self, from: data), value)
        XCTAssertEqual(value.carbonModifiers, 0x100 | 0x200 | 0x800 | 0x1000)
    }
}

final class PreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var preferences: Preferences!

    override func setUp() {
        suiteName = "SnapTool.SettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = Preferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        preferences = nil
        defaults = nil
    }

    func testDefaultsAreSmallAndPredictable() {
        XCTAssertEqual(preferences.hotkey, .defaultCapture)
        XCTAssertEqual(preferences.ocrLanguages, [])
        XCTAssertTrue(preferences.recognizePinnedWindows)
        XCTAssertEqual(preferences.defaultLineWidth, 3)
    }

    func testPreferencesSurviveNewInstance() throws {
        let shortcut = try HotKeyShortcut.parse("Cmd+Shift+S")
        preferences.hotkey = shortcut
        preferences.ocrLanguages = ["zh-Hans"]
        preferences.recognizePinnedWindows = false
        preferences.defaultColor = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.8)
        preferences.defaultLineWidth = 6
        let restored = Preferences(defaults: defaults)
        XCTAssertEqual(restored.hotkey, shortcut)
        XCTAssertEqual(restored.ocrLanguages, ["zh-Hans"])
        XCTAssertFalse(restored.recognizePinnedWindows)
        XCTAssertEqual(restored.defaultLineWidth, 6)
        let color = restored.defaultColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(color.redComponent, 0.1, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.8, accuracy: 0.001)
    }

    func testCorruptOrOutOfRangeSettingsUseDefaults() throws {
        defaults.set(Data("bad-json".utf8), forKey: "captureHotKey")
        XCTAssertEqual(preferences.hotkey, .defaultCapture)
        let invalid = HotKeyShortcut(keyCode: 53, modifierFlags: 0)
        defaults.set(try JSONEncoder().encode(invalid), forKey: "captureHotKey")
        XCTAssertEqual(preferences.hotkey, .defaultCapture)
        defaults.set(-10, forKey: "annotationLineWidth")
        XCTAssertEqual(preferences.defaultLineWidth, 3)
        defaults.set([0.1, 0.2], forKey: "annotationColor")
        XCTAssertEqual(preferences.defaultColor.alphaComponent, 1)
        preferences.defaultLineWidth = 99
        XCTAssertEqual(preferences.defaultLineWidth, 24)
        preferences.defaultLineWidth = 0
        XCTAssertEqual(preferences.defaultLineWidth, 1)
    }

    func testInvalidShortcutDoesNotReplaceValidPreference() throws {
        let valid = try HotKeyShortcut.parse("Option+F1")
        preferences.hotkey = valid
        preferences.hotkey = HotKeyShortcut(keyCode: 53, modifierFlags: 0)
        XCTAssertEqual(preferences.hotkey, valid)
    }
}

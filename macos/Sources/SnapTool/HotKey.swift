import AppKit
import Carbon

/// A hardware key plus the four standard AppKit modifier bits. It contains no event monitor.
struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifierFlags: UInt32

    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    static let defaultCapture = HotKeyShortcut(keyCode: 0, modifierFlags: UInt32(NSEvent.ModifierFlags.control.union(.option).rawValue))

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(modifierFlags)) }
    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + (Self.keyNames[keyCode] ?? "Key\(keyCode)")
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    func validate() throws {
        guard Self.keyNames[keyCode] != nil else { throw HotKeyError.unsupportedKey }
        guard modifiers.subtracting(Self.supportedModifiers).isEmpty else { throw HotKeyError.invalidModifiers }
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else { throw HotKeyError.modifierRequired }
    }

    init(keyCode: UInt32, modifierFlags: UInt32) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    init(event: NSEvent) throws {
        self.init(keyCode: UInt32(event.keyCode), modifierFlags: UInt32(event.modifierFlags.intersection(Self.supportedModifiers).rawValue))
        try validate()
    }

    /// Accepts both the displayed form (⌃⌥A) and Ctrl+Option+A.
    static func parse(_ text: String) throws -> HotKeyShortcut {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for (symbol, name) in [("⌃", "CTRL+"), ("⌥", "OPTION+"), ("⇧", "SHIFT+"), ("⌘", "CMD+")] {
            normalized = normalized.replacingOccurrences(of: symbol, with: name)
        }
        let parts = normalized.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts.contains("") else { throw HotKeyError.invalidText }
        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            let flag: NSEvent.ModifierFlags
            switch part {
            case "CTRL", "CONTROL", "控制": flag = .control
            case "ALT", "OPT", "OPTION", "选项": flag = .option
            case "SHIFT", "移位": flag = .shift
            case "CMD", "COMMAND", "命令": flag = .command
            default: throw HotKeyError.invalidText
            }
            guard !flags.contains(flag) else { throw HotKeyError.invalidText }
            flags.insert(flag)
        }
        let aliases = ["SPACE": "空格", "RETURN": "↩", "ENTER": "↩", "TAB": "⇥", "LEFT": "←", "RIGHT": "→", "UP": "↑", "DOWN": "↓", "BACKSPACE": "⌫", "DELETE": "⌦"]
        let name = aliases[parts.last!] ?? parts.last!
        guard let code = keyNames.first(where: { $0.value.uppercased() == name })?.key else { throw HotKeyError.unsupportedKey }
        let shortcut = HotKeyShortcut(keyCode: code, modifierFlags: UInt32(flags.rawValue))
        try shortcut.validate()
        return shortcut
    }

    // The labels follow the standard Apple hardware key positions, including non-letter keys.
    static let keyNames: [UInt32: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
        12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4",
        22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 30:"]", 31:"O",
        32:"U", 33:"[", 34:"I", 35:"P", 36:"↩", 37:"L", 38:"J", 39:"'", 40:"K", 41:";",
        42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"⇥", 49:"空格", 50:"`", 51:"⌫",
        64:"F17", 79:"F18", 80:"F19", 90:"F20", 96:"F5", 97:"F6", 98:"F7", 99:"F3",
        100:"F8", 101:"F9", 103:"F11", 105:"F13", 106:"F16", 107:"F14", 109:"F10",
        111:"F12", 113:"F15", 115:"Home", 116:"PageUp",
        117:"⌦", 118:"F4", 119:"End", 120:"F2", 121:"PageDown", 122:"F1", 123:"←",
        124:"→", 125:"↓", 126:"↑"
    ]
}

enum HotKeyError: LocalizedError {
    case unsupportedKey, invalidModifiers, modifierRequired, invalidText
    case registration(OSStatus), handler(OSStatus), release(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedKey: return "请选择字母、数字、方向键或 F1–F20 等支持的按键。Esc 用于取消截图。"
        case .invalidModifiers: return "只支持 Control、Option、Shift、Command 修饰键。"
        case .modifierRequired: return "快捷键至少需要 Control、Option 或 Command 中的一个，可同时使用 Shift。"
        case .invalidText: return "请输入例如 Ctrl+Option+A、Cmd+Shift+S，或点击“录制”按下组合键。"
        case .registration(let code): return "无法注册快捷键，可能已被系统或其他应用占用（\(code)）。原快捷键仍有效。"
        case .handler(let code): return "无法安装快捷键处理器（\(code)）。"
        case .release(let code): return "无法切换快捷键（\(code)）。原快捷键仍有效，请重试。"
        }
    }
}

/// Uses Carbon's registered hot-key events, without Accessibility or input-monitoring permission.
final class HotKeyManager {
    var onTrigger: (() -> Void)?
    var isSuspended = false
    var onSuspendedTrigger: ((HotKeyShortcut) -> Void)?
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var currentID: UInt32 = 0
    private var nextID: UInt32 = 1
    private(set) var shortcut: HotKeyShortcut?
    private static let signature: OSType = 0x534E4150 // SNAP

    func register(_ newShortcut: HotKeyShortcut) throws {
        precondition(Thread.isMainThread)
        try newShortcut.validate()
        if newShortcut == shortcut { return }
        try installHandlerIfNeeded()
        var candidate: EventHotKeyRef?
        let candidateID = nextID
        nextID = nextID &+ 1
        if nextID == 0 { nextID = 1 }
        let id = EventHotKeyID(signature: Self.signature, id: candidateID)
        let status = RegisterEventHotKey(newShortcut.keyCode, newShortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let registered = candidate else { throw HotKeyError.registration(status) }
        if let old = hotKeyRef {
            let releaseStatus = UnregisterEventHotKey(old)
            guard releaseStatus == noErr else {
                UnregisterEventHotKey(registered)
                throw HotKeyError.release(releaseStatus)
            }
        }
        hotKeyRef = registered
        currentID = candidateID
        shortcut = newShortcut
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        shortcut = nil
        currentID = 0
    }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, pointer in
            guard let event = event, let pointer = pointer else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(pointer).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyManager.signature, id.id == manager.currentID else { return OSStatus(eventNotHandledErr) }
            if manager.isSuspended {
                if let shortcut = manager.shortcut { manager.onSuspendedTrigger?(shortcut) }
            } else { manager.onTrigger?() }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { throw HotKeyError.handler(status) }
    }

    deinit {
        unregister()
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }
}

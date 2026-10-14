import AppKit

/// Stores only small user choices. Screenshots and OCR results are never persisted here.
final class Preferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hotkey: HotKeyShortcut {
        get {
            guard let data = defaults.data(forKey: "captureHotKey"),
                  let value = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
                  (try? value.validate()) != nil else { return .defaultCapture }
            return value
        }
        set {
            guard (try? newValue.validate()) != nil, let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "captureHotKey")
        }
    }

    /// Empty means Vision chooses languages automatically.
    var ocrLanguages: [String] {
        get { defaults.stringArray(forKey: "ocrLanguages") ?? [] }
        set { defaults.set(Array(Set(newValue.filter { !$0.isEmpty })).sorted(), forKey: "ocrLanguages") }
    }

    var recognizePinnedWindows: Bool {
        get { defaults.object(forKey: "recognizePinnedWindows") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "recognizePinnedWindows") }
    }

    var defaultColor: NSColor {
        get {
            guard let values = defaults.array(forKey: "annotationColor") as? [Double], values.count == 4,
                  values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return NSColor(srgbRed: 1, green: 0.32, blue: 0.1, alpha: 1) }
            return NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: values[3])
        }
        set {
            guard let color = newValue.usingColorSpace(.sRGB) else { return }
            defaults.set([Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent)], forKey: "annotationColor")
        }
    }

    var defaultLineWidth: CGFloat {
        get {
            let value = defaults.double(forKey: "annotationLineWidth")
            return value.isFinite && value >= 1 && value <= 24 ? CGFloat(value) : 3
        }
        set {
            guard newValue.isFinite else { return }
            defaults.set(Double(min(24, max(1, newValue))), forKey: "annotationLineWidth")
        }
    }
}

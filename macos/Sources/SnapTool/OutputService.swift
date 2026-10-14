import AppKit
import CoreGraphics
import UniformTypeIdentifiers

enum OutputServiceError: LocalizedError {
    case encodingFailed
    case clipboardFailed
    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "图片编码失败。"
        case .clipboardFailed: return "无法写入剪贴板，请重试。"
        }
    }
}

@MainActor
enum OutputService {
    private static let directoryKey = "SnapTool.lastSaveDirectory"

    static func copy(_ image: CGImage) throws {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]),
              let tiff = representation.representation(using: .tiff, properties: [:]) else {
            throw OutputServiceError.encodingFailed
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw OutputServiceError.clipboardFailed }
    }

    static func copyText(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    static func copyColor(red: UInt8, green: UInt8, blue: UInt8, hex: Bool = true) {
        copyText(hex ? String(format: "#%02X%02X%02X", red, green, blue) : "RGB(\(red), \(green), \(blue))")
    }

    @discardableResult
    static func save(_ image: CGImage, parent: NSWindow? = nil) async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = filename(extension: "png")
        if let path = UserDefaults.standard.string(forKey: directoryKey),
           FileManager.default.fileExists(atPath: path) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        }
        let accessory = SaveFormatAccessory(panel: panel)
        panel.accessoryView = accessory.view
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let parent {
                panel.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK, let url = panel.url else { return nil }
        let data = try encode(image, format: accessory.format)
        try data.write(to: url, options: .atomic)
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: directoryKey)
        return url
    }

    @discardableResult
    static func quickSave(_ image: CGImage) throws -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        let directory = pictures.appendingPathComponent("SnapTool", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename(extension: "png"))
        let staging = directory.appendingPathComponent(".SnapTool-\(UUID().uuidString).png")
        do {
            try encode(image, format: .png).write(to: staging, options: .atomic)
            // moveItem refuses an existing destination; atomic and withoutOverwriting cannot be combined.
            try FileManager.default.moveItem(at: staging, to: url)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        copyText(url.path)
        return url
    }

    private static func filename(extension suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "SnapTool-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).\(suffix)"
    }

    private static func encode(_ image: CGImage, format: ImageFormat) throws -> Data {
        let source: CGImage
        if format == .png {
            source = image
        } else {
            guard let white = whiteBackground(image) else { throw OutputServiceError.encodingFailed }
            source = white
        }
        let representation = NSBitmapImageRep(cgImage: source)
        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg ? [.compressionFactor: 0.92] : [:]
        guard let data = representation.representation(using: format.bitmapType, properties: properties) else {
            throw OutputServiceError.encodingFailed
        }
        return data
    }

    private static func whiteBackground(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private enum ImageFormat: Int {
        case png, jpeg, bmp
        var suffix: String { ["png", "jpg", "bmp"][rawValue] }
        var contentType: UTType { [.png, .jpeg, .bmp][rawValue] }
        var bitmapType: NSBitmapImageRep.FileType { [.png, .jpeg, .bmp][rawValue] }
    }

    private final class SaveFormatAccessory: NSObject {
        let panel: NSSavePanel
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 28), pullsDown: false)
        let view: NSView
        var format: ImageFormat { ImageFormat(rawValue: popup.indexOfSelectedItem) ?? .png }

        init(panel: NSSavePanel) {
            self.panel = panel
            let label = NSTextField(labelWithString: "格式：")
            let stack = NSStackView(views: [label, popup])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 260, height: 32)
            view = stack
            super.init()
            popup.addItems(withTitles: ["PNG（保留透明）", "JPEG（白色背景）", "BMP（白色背景）"])
            popup.target = self
            popup.action = #selector(changeFormat)
        }

        @objc private func changeFormat() {
            panel.allowedContentTypes = [format.contentType]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(name).\(format.suffix)"
        }
    }
}

import AppKit
import CoreGraphics
import ScreenCaptureKit

struct WindowTarget {
    let id: CGWindowID
    /// Top-left-origin points relative to the combined desktop, not image pixels.
    let rect: CGRect
    let title: String
}

struct DesktopCapture {
    let image: CGImage
    /// Global AppKit coordinates: bottom-left origin, including negative display origins.
    let frame: NSRect
    let scale: CGFloat
    let windows: [WindowTarget]
}

enum CaptureServiceError: LocalizedError {
    case permissionDenied
    case noDisplays
    case unavailableDisplay
    case imageAllocation
    case excessiveDesktop

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "需要屏幕录制权限。请在系统设置 → 隐私与安全性 → 屏幕录制中允许 SnapTool，然后重新启动应用。"
        case .noDisplays: return "未找到可截图的显示器。"
        case .unavailableDisplay: return "显示器配置发生变化，请重新截图。"
        case .imageAllocation: return "无法创建截图，请关闭部分应用后重试。"
        case .excessiveDesktop: return "桌面分辨率过大，请减少显示器数量后重试。"
        }
    }
}

@MainActor
enum CaptureService {
    static func capture() async throws -> DesktopCapture {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureServiceError.permissionDenied
        }
        let screens = NSScreen.screens
        guard let primary = screens.first else { throw CaptureServiceError.noDisplays }
        let desktop = screens.dropFirst().reduce(primary.frame) { $0.union($1.frame) }
        let scale = screens.map(\.backingScaleFactor).max() ?? 1
        let width = Int(ceil(desktop.width * scale))
        let height = Int(ceil(desktop.height * scale))
        // Bound allocation before multiplying; a 64 MP canvas is already 256 MB.
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              width <= 64_000_000 / height else { throw CaptureServiceError.excessiveDesktop }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureServiceError.permissionDenied }
            throw error
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let pins = ownWindows.filter { PinWindow.activeWindowIDs.contains($0.windowID) }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureServiceError.imageAllocation
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.interpolationQuality = .high

        // Capture sequentially to avoid simultaneously retaining one extra bitmap per display.
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                throw CaptureServiceError.unavailableDisplay
            }
            let filter: SCContentFilter
            if ownApps.isEmpty {
                filter = SCContentFilter(display: display, excludingWindows: ownWindows.filter { !PinWindow.activeWindowIDs.contains($0.windowID) })
            } else {
                filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: pins)
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
            configuration.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let destination = CGRect(x: (screen.frame.minX - desktop.minX) * scale,
                                     y: (screen.frame.minY - desktop.minY) * scale,
                                     width: screen.frame.width * scale,
                                     height: screen.frame.height * scale)
            context.draw(image, in: destination)
        }
        guard let image = context.makeImage() else { throw CaptureServiceError.imageAllocation }
        let windows = windowTargets(content: content, desktop: desktop, primaryTop: primary.frame.maxY,
                                    excluding: ownPID)
        return DesktopCapture(image: image, frame: desktop, scale: scale, windows: windows)
    }

    private static func windowTargets(content: SCShareableContent, desktop: NSRect,
                                      primaryTop: CGFloat, excluding pid: pid_t) -> [WindowTarget] {
        let pinIDs = PinWindow.activeWindowIDs
        let candidates = Dictionary(uniqueKeysWithValues: content.windows.compactMap { window -> (CGWindowID, SCWindow)? in
            let isPin = pinIDs.contains(window.windowID)
            guard window.isOnScreen, window.owningApplication?.processID != pid || isPin,
                  window.windowLayer == 0 || isPin,
                  window.frame.width >= 20, window.frame.height >= 20 else { return nil }
            return (window.windowID, window)
        })
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let bounds = CGRect(origin: .zero, size: desktop.size)
        var result: [WindowTarget] = []
        // Quartz supplies front-to-back order, so overlapping windows select the visible front one.
        for item in info {
            guard let id = item[kCGWindowNumber as String] as? NSNumber,
                  let window = candidates[id.uint32Value],
                  ((item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01 else { continue }
            let rect = CGRect(x: window.frame.minX - desktop.minX,
                              y: window.frame.minY + desktop.maxY - primaryTop,
                              width: window.frame.width, height: window.frame.height).intersection(bounds)
            guard !rect.isNull, rect.width >= 20, rect.height >= 20 else { continue }
            let title = pinIDs.contains(window.windowID) ? "SnapTool 贴图"
                : (window.title?.isEmpty == false ? window.title! : (window.owningApplication?.applicationName ?? "窗口"))
            result.append(WindowTarget(id: window.windowID, rect: rect, title: title))
        }
        return result
    }
}

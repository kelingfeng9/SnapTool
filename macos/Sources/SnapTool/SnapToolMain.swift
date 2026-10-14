import AppKit

@main
struct SnapToolMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let isCheck = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--documentation-snapshots")
        if !isCheck, let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.kelingfeng9.SnapTool.capture"),
                object: nil, userInfo: nil, deliverImmediately: true)
            existing.activate(options: [])
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

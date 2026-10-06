import AppKit

@main
enum MicVolumeApp {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            exit(Diagnostics.selfTest())
        }
        if let index = args.firstIndex(of: "--snapshot") {
            exit(Diagnostics.snapshot(to: index + 1 < args.count ? args[index + 1] : "/tmp/micvolume.png"))
        }
        if args.contains("--preview") {
            Diagnostics.preview()
            return
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.mic-volume"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty { exit(0) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

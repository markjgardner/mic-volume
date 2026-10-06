import AppKit
import CoreAudio
import ServiceManagement

/// Polls which apps are currently capturing audio input (only while the panel is open).
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var apps: [String] = []
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let names = MicUsage.appsUsingInput()
        if names != apps { apps = names }
    }
}

enum MicUsage {
    struct Client {
        let pid: pid_t
        let bundleID: String
        let devices: [AudioDeviceID]
    }

    static func inputClients() -> [Client] {
        HAL.objectList(HAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard HAL.read(object, HAL.prop(kAudioProcessPropertyIsRunningInput), initial: UInt32(0)) == 1,
                  let pid = HAL.read(object, HAL.prop(kAudioProcessPropertyPID), initial: pid_t(0)) else { return nil }
            return Client(pid: pid,
                          bundleID: HAL.string(object, kAudioProcessPropertyBundleID) ?? "",
                          devices: HAL.objectList(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
        }
    }

    @MainActor
    static func appsUsingInput() -> [String] {
        let own = getpid()
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var seen = Set<String>()
        var names: [String] = []
        for client in inputClients() where client.pid != own {
            let name = displayName(client, regularApps: regularApps)
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    /// Maps helper processes (e.g. "Microsoft Teams ModuleHost") to the app the user knows.
    @MainActor
    static func displayName(_ client: Client, regularApps: [NSRunningApplication]) -> String {
        let process = NSRunningApplication(processIdentifier: client.pid)
        if let process, process.activationPolicy == .regular, let name = process.localizedName { return name }
        if !client.bundleID.isEmpty,
           let parent = regularApps
               .filter({ app in app.bundleIdentifier.map { client.bundleID.hasPrefix($0 + ".") } ?? false })
               .max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }),
           let name = parent.localizedName {
            return name
        }
        if var name = process?.localizedName {
            for suffix in [" Graphics and Media", " Web Content", " Networking", " ModuleHost", " WebView"] where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
            }
            if let range = name.range(of: " Helper") { name = String(name[..<range.lowerBound]) }
            return name
        }
        return client.bundleID.isEmpty ? "Process \(client.pid)" : client.bundleID
    }
}

/// "Open at login" via the login items API, with a LaunchAgent fallback if registration is refused.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var note: String?

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.local.mic-volume.plist")
    }

    init() { refresh() }

    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notRegistered: return FileManager.default.fileExists(atPath: agentURL.path) ? "launch agent" : "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
            || FileManager.default.fileExists(atPath: agentURL.path)
        note = status == .requiresApproval
            ? "Approve Mic Volume in System Settings > General > Login Items." : nil
    }

    func set(_ on: Bool) {
        if on {
            do {
                try SMAppService.mainApp.register()
                try? FileManager.default.removeItem(at: agentURL)
            } catch {
                logger.error("Login item registration failed (\(error.localizedDescription, privacy: .public)); using a LaunchAgent")
                writeLaunchAgent()
            }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentURL)
        }
        refresh()
    }

    private func writeLaunchAgent() {
        let plist: [String: Any] = [
            "Label": "com.local.mic-volume",
            "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL)
        } catch {
            note = "Couldn't set up Open at login: \(error.localizedDescription)"
        }
    }
}

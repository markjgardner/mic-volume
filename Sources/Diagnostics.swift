import AppKit
import CoreAudio
import SwiftUI

/// Command-line checks: `--self-test`, `--snapshot <png>`, and `--preview`.
@MainActor
enum Diagnostics {
    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func format(_ value: Float?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "n/a"
    }

    // MARK: Self-test

    static func selfTest() -> Int32 {
        let model = MicModel(mode: .test)
        return withExtendedLifetime(model) { runSelfTest(model) }
    }

    private static func runSelfTest(_ model: MicModel) -> Int32 {
        let clients = MicUsage.inputClients()
        print("Input devices:")
        for device in model.devices {
            let users = clients.filter { $0.devices.contains(device.id) }
                .map { $0.bundleID.isEmpty ? "pid \($0.pid)" : $0.bundleID }
            print("  [\(device.id)] \(device.name)\(device.id == model.current?.id ? " (default)" : "")"
                  + " volume=\(format(device.volume)) volumeElements=\(device.volumeElements)"
                  + " muted=\(device.hardwareMuted.map(String.init(describing:)) ?? "n/a") muteElements=\(device.muteElements)"
                  + (users.isEmpty ? "" : " in use by \(users.joined(separator: ", "))"))
        }
        print("Apps using input: \(MicUsage.appsUsingInput())")

        // Only exercise a device nobody is using, and never the default input.
        if clients.contains(where: { $0.devices.isEmpty }) {
            print("SKIP write tests: an app is capturing audio from an unknown device.")
            return 0
        }
        let busy = Set(clients.flatMap(\.devices))
        guard let device = model.devices.first(where: {
            $0.canSetVolume && !busy.contains($0.id) && $0.id != model.current?.id
        }) else {
            print("SKIP write tests: no idle, adjustable, non-default input device.")
            return 0
        }
        print("Testing on idle device: \(device.name)")

        let volumeAddress = { (element: AudioObjectPropertyElement) in
            HAL.prop(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element)
        }
        let muteAddress = { (element: AudioObjectPropertyElement) in
            HAL.prop(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput, element: element)
        }
        let originalVolumes = device.volumeElements.map { ($0, HAL.read(device.id, volumeAddress($0), initial: Float32(0))) }
        let originalMutes = device.muteElements.map { ($0, HAL.read(device.id, muteAddress($0), initial: UInt32(0))) }

        var passed = 0
        var failed = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL"): \(name)")
            if ok { passed += 1 } else { failed += 1 }
        }
        func near(_ a: Float?, _ b: Float) -> Bool { a.map { abs($0 - b) < 0.02 } ?? false }
        func events() -> [String] { model.eventLog.filter { $0.uid == device.uid }.map(\.message) }

        // 1. Mic Volume's own writes are not treated as external.
        let base: Float = (device.volume ?? 0.5) > 0.5 ? 0.30 : 0.70
        model.setVolume(base, on: device)
        spin(0.5)
        check(near(device.volume, base), "set volume to \(percent(base)) (read back \(format(device.volume)))")
        check(events().isEmpty, "own change is not reported as external")

        // 2. Unlocked: an external change is reported and left alone.
        let external = base + 0.15
        device.setVolume(external)
        spin(0.6)
        check(events().last?.contains("outside Mic Volume") == true, "external change reported: \(events().last ?? "none")")
        check(near(device.volume, external), "unlocked external change is left alone (\(format(device.volume)))")

        // 3. Locked: an external change is reverted and counted once.
        model.setLocked(true, on: device)
        let target = model.lockTarget(for: device) ?? -1
        let blockedBefore = model.blockedCount
        device.setVolume(target - 0.25)
        spin(0.8)
        check(near(device.volume, target), "locked volume restored to \(percent(target)) (\(format(device.volume)))")
        check(model.blockedCount == blockedBefore + 1, "blocked count incremented once (\(model.blockedCount - blockedBefore))")
        check(events().last?.hasPrefix("Restored") == true, "event: \(events().last ?? "none")")

        // 4. Locked: a change made in Mic Volume sticks and moves the lock.
        let userValue = target - 0.10
        model.setVolume(userValue, on: device)
        spin(0.6)
        check(near(device.volume, userValue), "user change while locked sticks (\(format(device.volume)))")
        check(near(model.lockTarget(for: device), userValue), "lock target follows the user change")

        // 5. Mute is enforced against external unmutes.
        if device.hasHardwareMute {
            model.setMuted(true, on: device)
            spin(0.4)
            check(device.hardwareMuted == true, "muted via Mic Volume")
            device.setHardwareMute(false)
            spin(0.8)
            check(device.hardwareMuted == true, "external unmute reverted (\(events().last ?? "none"))")
            model.setMuted(false, on: device)
            spin(0.4)
            check(device.hardwareMuted == false, "unmuted via Mic Volume")
        } else {
            model.setMuted(true, on: device)
            spin(0.4)
            check((device.volume ?? 1) < 0.01, "soft-muted via Mic Volume")
            device.setVolume(0.5)
            spin(0.8)
            check((device.volume ?? 1) < 0.01, "kept soft-muted after an external change")
            model.setMuted(false, on: device)
            spin(0.4)
            check(near(device.volume, userValue), "soft unmute restores the locked level")
        }

        // Clean up: release the lock/mute, then restore the original raw values.
        model.setLocked(false, on: device)
        if model.isMuted(device) { model.setMuted(false, on: device) }
        for (element, value) in originalVolumes { if let value { HAL.write(device.id, volumeAddress(element), value) } }
        for (element, value) in originalMutes { if let value { HAL.write(device.id, muteAddress(element), value) } }
        spin(0.4)
        let restored = originalVolumes.allSatisfy { element, value in
            value == nil || abs((HAL.read(device.id, volumeAddress(element), initial: Float32(0)) ?? -1) - value!) < 0.002
        } && originalMutes.allSatisfy { element, value in
            value == nil || HAL.read(device.id, muteAddress(element), initial: UInt32(0)) == value
        }
        check(restored, "original settings restored (volume \(format(device.volume)), muted \(device.hardwareMuted.map(String.init(describing:)) ?? "n/a"))")

        print(failed == 0 ? "All \(passed) checks passed." : "\(failed) of \(passed + failed) checks FAILED.")
        return failed == 0 ? 0 : 1
    }

    // MARK: Snapshot and preview (read-only model, simulated meter, no microphone access)

    private static func makePreviewView() -> (some View, [AnyObject]) {
        let model = MicModel(mode: .observeOnly)
        let meter = LevelMeter()
        meter.simulate(level: 0.55, peak: 0.7)
        let usage = UsageMonitor()
        usage.refresh()
        let login = LoginItem()
        let view = PopoverView(model: model, usage: usage, login: login, meter: meter, actions: PanelActions())
            .background(Color(nsColor: .windowBackgroundColor))
        return (view, [model, meter, usage, login])
    }

    static func snapshot(to path: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let (view, keepAlive) = makePreviewView()
        return withExtendedLifetime(keepAlive) {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            spin(0.5)
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]),
                  (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
            print("Wrote \(path) (\(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)) pt)")
            return 0
        }
    }

    static func preview() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let (view, keepAlive) = makePreviewView()
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Mic Volume Preview"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        withExtendedLifetime((keepAlive, window)) { app.run() }
    }
}

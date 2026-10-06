import AppKit
import CoreAudio
import os

let logger = Logger(subsystem: "com.local.mic-volume", category: "mic")

func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }

/// C callback for HAL property changes; hops to the main actor.
private func halListener(_ object: AudioObjectID, _ count: UInt32,
                         _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                         _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { return noErr }
    let model = Unmanaged<MicModel>.fromOpaque(context).takeUnretainedValue()
    let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { model.halChanged(object: object, selectors: selectors) }
    }
    return noErr
}

/// Tracks input devices, follows the system default input, and enforces per-device
/// volume locks and mutes against changes made by other apps.
@MainActor
final class MicModel: ObservableObject {
    enum Mode {
        case app          // persist settings, enforce locks
        case observeOnly  // read-only (snapshots)
        case test         // enforce, but never load or save settings
    }

    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var current: InputDevice?
    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var lockTarget: Float?
    @Published private(set) var blockedCount = 0
    @Published private(set) var lastEvent: String?

    /// Recent external-change events per device (used by the self-test).
    private(set) var eventLog: [(uid: String, message: String)] = []
    var onDefaultDeviceChange: (() -> Void)?
    var isEditing = false {
        didSet { if !isEditing { reloadCurrent() } }
    }

    private let mode: Mode
    private var lockedVolumes: [String: Double]
    private var softMuteRestore: [String: Double]
    private var enforcedMute = Set<String>()
    private var lastVolume: [AudioDeviceID: Float] = [:]
    private var lastMute: [AudioDeviceID: Bool] = [:]
    private var ownVolumeWrites: [AudioDeviceID: [(value: Float, time: Date)]] = [:]
    private var ownMuteWrites: [AudioDeviceID: [(value: Bool, time: Date)]] = [:]
    private var listening: [AudioDeviceID: [AudioObjectPropertyAddress]] = [:]
    private var pendingEnforce: [AudioDeviceID: DispatchWorkItem] = [:]
    private let clock: DateFormatter

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    init(mode: Mode = .app) {
        self.mode = mode
        let defaults = UserDefaults.standard
        let load = mode != .test
        lockedVolumes = load ? (defaults.dictionary(forKey: Keys.locked) as? [String: Double]) ?? [:] : [:]
        softMuteRestore = load ? (defaults.dictionary(forKey: Keys.softMute) as? [String: Double]) ?? [:] : [:]
        clock = DateFormatter()
        clock.dateStyle = .none
        clock.timeStyle = .short
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = HAL.prop(selector)
            AudioObjectAddPropertyListener(HAL.system, &address, halListener, context)
        }
        refreshDevices()
        bindDefault()
    }

    // MARK: Public controls (current device)

    func setVolume(_ value: Float) { if let device = current { setVolume(value, on: device) } }
    func toggleMute() { if let device = current { setMuted(!isMuted(device), on: device) } }
    func setLocked(_ locked: Bool) { if let device = current { setLocked(locked, on: device) } }

    func selectDevice(_ id: AudioDeviceID) {
        guard mode != .observeOnly, id != current?.id else { return }
        HAL.setDefaultInputDevice(id)
        bindDefault()
    }

    func isMuted(_ device: InputDevice) -> Bool {
        device.hardwareMuted == true || softMuteRestore[device.uid] != nil
    }

    func lockTarget(for device: InputDevice) -> Float? {
        lockedVolumes[device.uid].map { Float($0) }
    }

    /// The level a lock would hold right now (the pre-mute level while soft-muted).
    var lockCandidate: Float {
        if let lockTarget { return lockTarget }
        if let uid = current?.uid, let restore = softMuteRestore[uid] { return Float(restore) }
        return volume
    }

    // MARK: Controls (any device)

    func setVolume(_ value: Float, on device: InputDevice) {
        guard device.canSetVolume else { return }
        let value = min(max(value, 0), 1)
        if softMuteRestore.removeValue(forKey: device.uid) != nil { save() }
        if value > 0, device.hardwareMuted == true {
            enforcedMute.remove(device.uid)
            writeMute(device, false)
        }
        let actual = writeVolume(device, value) ?? value
        if lockedVolumes[device.uid] != nil {
            lockedVolumes[device.uid] = Double(actual)
            save()
        }
        if device.id == current?.id {
            volume = value
            muted = isMuted(device)
            lockTarget = lockedVolumes[device.uid].map { Float($0) }
        }
    }

    func setMuted(_ mute: Bool, on device: InputDevice) {
        if device.hasHardwareMute {
            if mute { enforcedMute.insert(device.uid) } else { enforcedMute.remove(device.uid) }
            writeMute(device, mute)
        } else if device.canSetVolume {
            // No hardware mute: mute by dropping the volume to 0 and remember the level.
            if mute, softMuteRestore[device.uid] == nil {
                softMuteRestore[device.uid] = Double(device.volume ?? volume)
                writeVolume(device, 0)
            } else if !mute, let restore = softMuteRestore.removeValue(forKey: device.uid) {
                writeVolume(device, Float(lockedVolumes[device.uid] ?? (restore > 0.02 ? restore : 0.5)))
            }
            save()
        }
        logger.notice("\(device.name, privacy: .public): \(mute ? "muted" : "unmuted", privacy: .public) by Mic Volume")
        if device.id == current?.id { reloadCurrent() }
    }

    func setLocked(_ locked: Bool, on device: InputDevice) {
        guard device.canSetVolume else { return }
        lockedVolumes[device.uid] = locked ? (softMuteRestore[device.uid] ?? Double(device.volume ?? volume)) : nil
        save()
        logger.notice("\(device.name, privacy: .public): lock \(locked ? "on" : "off", privacy: .public)")
        if device.id == current?.id { reloadCurrent() }
    }

    // MARK: Device tracking

    private func refreshDevices() {
        let found = HAL.objectList(HAL.system, kAudioHardwarePropertyDevices)
            .compactMap(InputDevice.load)
            .sorted { lhs, rhs in
                let l = lhs.transport == kAudioDeviceTransportTypeBuiltIn
                let r = rhs.transport == kAudioDeviceTransportTypeBuiltIn
                return l != r ? l : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        let foundIDs = Set(found.map(\.id))
        for (id, addresses) in listening where !foundIDs.contains(id) {
            for address in addresses {
                var address = address
                AudioObjectRemovePropertyListener(id, &address, halListener, context)
            }
            listening[id] = nil
            lastVolume[id] = nil
            lastMute[id] = nil
            pendingEnforce.removeValue(forKey: id)?.cancel()
        }
        devices = found
        for device in found where listening[device.id] == nil {
            listening[device.id] = device.listenAddresses.filter { address in
                var address = address
                return AudioObjectAddPropertyListener(device.id, &address, halListener, context) == noErr
            }
            lastVolume[device.id] = device.volume
            lastMute[device.id] = device.hardwareMuted
            if softMuteRestore[device.uid] != nil, (device.volume ?? 0) > 0.005 {
                softMuteRestore[device.uid] = nil  // unmuted while Mic Volume wasn't running
                save()
            }
            if needsEnforcement(device) { scheduleEnforce(device) }
        }
    }

    private func bindDefault() {
        let defaultID = HAL.defaultInputDevice()
        let device = devices.first { $0.id == defaultID }
        let changed = device?.id != current?.id
        current = device
        reloadCurrent()
        if changed { onDefaultDeviceChange?() }
    }

    private func reloadCurrent() {
        guard let device = current else {
            muted = false
            lockTarget = nil
            return
        }
        if !isEditing, let value = device.volume { volume = value }
        muted = isMuted(device)
        lockTarget = lockedVolumes[device.uid].map { Float($0) }
    }

    fileprivate func halChanged(object: AudioObjectID, selectors: [AudioObjectPropertySelector]) {
        if object == HAL.system {
            if selectors.contains(kAudioHardwarePropertyDevices) { refreshDevices() }
            bindDefault()
            return
        }
        guard let device = devices.first(where: { $0.id == object }) else { return }
        deviceChanged(device)
    }

    private func deviceChanged(_ device: InputDevice) {
        let now = Date()
        if let value = device.volume {
            let previous = lastVolume[device.id]
            lastVolume[device.id] = value
            if let previous, abs(value - previous) > 0.0005, !isOwnVolume(device.id, value, now) {
                externalVolumeChange(device, to: value)
            }
        }
        if let value = device.hardwareMuted {
            let previous = lastMute[device.id]
            lastMute[device.id] = value
            if let previous, value != previous, !isOwnMute(device.id, value, now) {
                externalMuteChange(device, muted: value)
            }
        }
        if device.id == current?.id { reloadCurrent() }
    }

    // MARK: Own-write bookkeeping

    private func isOwnVolume(_ id: AudioDeviceID, _ value: Float, _ now: Date) -> Bool {
        let recent = (ownVolumeWrites[id] ?? []).filter { now.timeIntervalSince($0.time) < 1.5 }
        ownVolumeWrites[id] = recent
        return recent.contains { abs($0.value - value) < 0.006 }
    }

    private func isOwnMute(_ id: AudioDeviceID, _ value: Bool, _ now: Date) -> Bool {
        let recent = (ownMuteWrites[id] ?? []).filter { now.timeIntervalSince($0.time) < 1.5 }
        ownMuteWrites[id] = recent
        return recent.contains { $0.value == value }
    }

    /// Writes a volume and records both the requested and read-back value, since devices quantize.
    @discardableResult
    private func writeVolume(_ device: InputDevice, _ value: Float) -> Float? {
        guard mode != .observeOnly else { return nil }
        let target = min(max(value, 0), 1)
        let now = Date()
        var writes = ownVolumeWrites[device.id, default: []].suffix(200)
        writes.append((value: target, time: now))
        guard device.setVolume(target) else {
            ownVolumeWrites[device.id] = Array(writes)
            return nil
        }
        let actual = device.volume ?? target
        writes.append((value: actual, time: now))
        ownVolumeWrites[device.id] = Array(writes)
        lastVolume[device.id] = actual
        return actual
    }

    private func writeMute(_ device: InputDevice, _ value: Bool) {
        guard mode != .observeOnly else { return }
        ownMuteWrites[device.id, default: []].append((value: value, time: Date()))
        device.setHardwareMute(value)
        lastMute[device.id] = device.hardwareMuted ?? value
    }

    // MARK: External changes and enforcement

    private func externalVolumeChange(_ device: InputDevice, to value: Float) {
        guard mode != .observeOnly else { return }
        if softMuteRestore[device.uid] != nil {
            if value > 0.005 { block(device, "Kept muted after a change to \(percent(value))") }
        } else if let target = lockedVolumes[device.uid].map({ Float($0) }) {
            if abs(value - target) > 0.006 { block(device, "Restored \(percent(target)) after a change to \(percent(value))") }
        } else {
            note(device, "Changed to \(percent(value)) outside Mic Volume")
        }
    }

    private func externalMuteChange(_ device: InputDevice, muted: Bool) {
        guard mode != .observeOnly else { return }
        if !muted, enforcedMute.contains(device.uid) {
            block(device, "Kept muted after an unmute attempt")
        } else {
            note(device, muted ? "Muted outside Mic Volume" : "Unmuted outside Mic Volume")
        }
    }

    private func block(_ device: InputDevice, _ message: String) {
        blockedCount += 1
        note(device, message)
        scheduleEnforce(device)
    }

    private func note(_ device: InputDevice, _ message: String) {
        let prefix = device.id == current?.id ? "" : "\(device.name): "
        lastEvent = "\(prefix)\(message) · \(clock.string(from: Date()))"
        eventLog.append((uid: device.uid, message: message))
        if eventLog.count > 50 { eventLog.removeFirst(eventLog.count - 50) }
        logger.notice("\(device.name, privacy: .public): \(message, privacy: .public)")
    }

    private func needsEnforcement(_ device: InputDevice) -> Bool {
        guard mode != .observeOnly else { return false }
        if softMuteRestore[device.uid] != nil { return (device.volume ?? 0) > 0.005 }
        if let target = lockedVolumes[device.uid], let value = device.volume, abs(value - Float(target)) > 0.006 { return true }
        return enforcedMute.contains(device.uid) && device.hardwareMuted == false
    }

    /// Debounced so a burst of changes (e.g. auto gain control) results in one restore.
    private func scheduleEnforce(_ device: InputDevice) {
        let id = device.id
        pendingEnforce[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.enforce(id) }
        }
        pendingEnforce[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func enforce(_ id: AudioDeviceID) {
        pendingEnforce[id] = nil
        guard mode != .observeOnly, let device = devices.first(where: { $0.id == id }) else { return }
        if softMuteRestore[device.uid] != nil {
            if (device.volume ?? 0) > 0.005 { writeVolume(device, 0) }
        } else if let target = lockedVolumes[device.uid], let value = device.volume, abs(value - Float(target)) > 0.006 {
            writeVolume(device, Float(target))
        }
        if enforcedMute.contains(device.uid), device.hardwareMuted == false { writeMute(device, true) }
        if id == current?.id { reloadCurrent() }
    }

    private func save() {
        guard mode == .app else { return }
        UserDefaults.standard.set(lockedVolumes, forKey: Keys.locked)
        UserDefaults.standard.set(softMuteRestore, forKey: Keys.softMute)
    }

    private enum Keys {
        static let locked = "lockedVolumes"
        static let softMute = "softMuteRestore"
    }
}

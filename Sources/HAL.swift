import CoreAudio
import Foundation

/// Thin helpers over the CoreAudio HAL C API.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func prop(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func write<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeBytes(of: &value) { buffer in
            AudioObjectSetPropertyData(object, &address, 0, nil, size, buffer.baseAddress!)
        }
        return status == noErr
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard let value = read(object, prop(selector), initial: Unmanaged<CFString>?.none), let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = prop(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = prop(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        guard let id = read(system, prop(kAudioHardwarePropertyDefaultInputDevice), initial: AudioDeviceID(0)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        write(system, prop(kAudioHardwarePropertyDefaultInputDevice), id)
    }
}

/// A snapshot of an input device's identity and controls. Values are read live from the HAL.
struct InputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let volumeElements: [AudioObjectPropertyElement]
    let muteElements: [AudioObjectPropertyElement]

    var canSetVolume: Bool { !volumeElements.isEmpty }
    var hasHardwareMute: Bool { !muteElements.isEmpty }
    var canMute: Bool { hasHardwareMute || canSetVolume }

    static func load(_ id: AudioDeviceID) -> InputDevice? {
        let channels = HAL.inputChannelCount(id)
        guard channels > 0 else { return nil }
        return InputDevice(
            id: id,
            uid: HAL.string(id, kAudioDevicePropertyDeviceUID) ?? "device-\(id)",
            name: HAL.string(id, kAudioObjectPropertyName) ?? "Input \(id)",
            transport: HAL.read(id, HAL.prop(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0,
            volumeElements: settableElements(id, kAudioDevicePropertyVolumeScalar, channels),
            muteElements: settableElements(id, kAudioDevicePropertyMute, channels))
    }

    /// Devices expose a control either on the main element or per channel (e.g. USB webcams).
    private static func settableElements(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                         _ channels: Int) -> [AudioObjectPropertyElement] {
        func settable(_ element: AudioObjectPropertyElement) -> Bool {
            let address = HAL.prop(selector, scope: kAudioDevicePropertyScopeInput, element: element)
            return HAL.has(id, address) && HAL.isSettable(id, address)
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...UInt32(channels)).filter(settable)
    }

    private func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        HAL.prop(selector, scope: kAudioDevicePropertyScopeInput, element: element)
    }

    var volume: Float? {
        let values = volumeElements.compactMap { HAL.read(id, address(kAudioDevicePropertyVolumeScalar, $0), initial: Float32(0)) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        guard canSetVolume else { return false }
        let clamped = Float32(min(max(value, 0), 1))
        return volumeElements.map { HAL.write(id, address(kAudioDevicePropertyVolumeScalar, $0), clamped) }.allSatisfy { $0 }
    }

    var hardwareMuted: Bool? {
        let values = muteElements.compactMap { HAL.read(id, address(kAudioDevicePropertyMute, $0), initial: UInt32(0)) }
        return values.isEmpty ? nil : values.contains { $0 != 0 }
    }

    @discardableResult
    func setHardwareMute(_ muted: Bool) -> Bool {
        guard hasHardwareMute else { return false }
        return muteElements.map { HAL.write(id, address(kAudioDevicePropertyMute, $0), UInt32(muted ? 1 : 0)) }.allSatisfy { $0 }
    }

    var listenAddresses: [AudioObjectPropertyAddress] {
        volumeElements.map { address(kAudioDevicePropertyVolumeScalar, $0) }
            + muteElements.map { address(kAudioDevicePropertyMute, $0) }
    }

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case Self.fourCC("ccwd"), Self.fourCC("ccwl"): return "iphone"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "mic"
        }
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

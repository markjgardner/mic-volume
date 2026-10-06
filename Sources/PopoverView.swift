import CoreAudio
import SwiftUI

struct PanelActions {
    var openSoundSettings: @MainActor () -> Void = {}
    var openPrivacySettings: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = {}
}

struct PopoverView: View {
    @ObservedObject var model: MicModel
    @ObservedObject var usage: UsageMonitor
    @ObservedObject var login: LoginItem
    let meter: LevelMeter
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let device = model.current {
                devicePicker
                LevelSection(meter: meter, openPrivacy: actions.openPrivacySettings)
                volumeRow(device)
                if device.canSetVolume { lockRow }
            } else {
                Text("No microphone is connected.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            usageRow
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.muted ? Color.red : Color.accentColor)
                .frame(width: 20)
            Text("Microphone")
                .font(.headline)
            Spacer()
            Button(action: actions.openSoundSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Open Sound settings")
        }
    }

    private var devicePicker: some View {
        Picker("Input device", selection: Binding(
            get: { model.current?.id ?? AudioDeviceID(0) },
            set: { model.selectDevice($0) })) {
            ForEach(model.devices) { device in
                Label(device.name, systemImage: device.symbol).tag(device.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    @ViewBuilder
    private func volumeRow(_ device: InputDevice) -> some View {
        HStack(spacing: 8) {
            Button { model.toggleMute() } label: {
                Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(model.muted ? Color.red : Color.primary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!device.canMute)
            .help(model.muted ? "Unmute" : "Mute")

            if device.canSetVolume {
                Slider(value: Binding(get: { Double(model.volume) }, set: { model.setVolume(Float($0)) }),
                       in: 0...1,
                       onEditingChanged: { model.isEditing = $0 })
                    .opacity(model.muted ? 0.5 : 1)
                Text(model.muted ? "Muted" : percent(model.volume))
                    .monospacedDigit()
                    .foregroundStyle(model.muted ? Color.red : Color.primary)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Text("Fixed")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        if !device.canSetVolume {
            Text("\(device.name) doesn't let apps change its input volume.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var lockRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lock volume at \(percent(model.lockCandidate))")
                Text("Stops apps like Teams and Zoom from auto-adjusting it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Lock volume", isOn: Binding(get: { model.lockTarget != nil }, set: { model.setLocked($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        if model.blockedCount > 0 || model.lastEvent != nil {
            VStack(alignment: .leading, spacing: 2) {
                if model.blockedCount > 0 {
                    Text("Blocked \(model.blockedCount) change\(model.blockedCount == 1 ? "" : "s") since launch")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let event = model.lastEvent {
                    Text(event)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var usageRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(usage.apps.isEmpty ? Color.secondary.opacity(0.4) : Color.orange)
                .frame(width: 7, height: 7)
            Text(usage.apps.isEmpty
                 ? "No apps are using the microphone"
                 : "In use by \(ListFormatter.localizedString(byJoining: usage.apps))")
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Open at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit", action: actions.quit)
            }
            if let note = login.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Observes the meter on its own so ~45 updates per second only redraw this section.
struct LevelSection: View {
    @ObservedObject var meter: LevelMeter
    let openPrivacy: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SegmentedMeter(level: meter.level, peak: meter.peak, active: meter.status == .running)
                .frame(height: 10)
            switch meter.status {
            case .denied:
                HStack(spacing: 4) {
                    Text("The level meter needs microphone access.")
                    Button("Turn on in Privacy settings", action: openPrivacy)
                        .buttonStyle(.link)
                }
                .font(.caption)
            case .requesting:
                Text("Waiting for microphone access…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle, .running:
                EmptyView()
            }
        }
    }
}

struct SegmentedMeter: View {
    let level: Float
    let peak: Float
    let active: Bool
    private let segments = 30

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let lit = active ? Int((level * Float(segments)).rounded()) : 0
            let peakIndex = active && peak > 0.02 ? min(segments - 1, Int(peak * Float(segments))) : -1
            for index in 0..<segments {
                let fraction = Float(index + 1) / Float(segments)
                let color: Color = fraction > 0.95 ? .red : fraction > 0.8 ? .yellow : .green
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: size.height)
                let on = index < lit || index == peakIndex
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(on ? color : color.opacity(0.18)))
            }
        }
        .opacity(active ? 1 : 0.6)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(active ? percent(level) : "Off")
    }
}

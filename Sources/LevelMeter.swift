import Accelerate
import AVFoundation

/// Live input level from the default input device. Runs only while the panel is open,
/// so the microphone (and the orange privacy indicator) isn't held open in the background.
@MainActor
final class LevelMeter: ObservableObject {
    enum Status: Equatable {
        case idle, requesting, running, denied
        case unavailable(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var peak: Float = 0

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var wanted = false
    private var peakHeldAt = Date.distantPast
    private var restartWork: DispatchWorkItem?

    func start() {
        wanted = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            status = .requesting
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard let self else { return }
                guard granted else { self.status = .denied; return }
                self.status = .idle
                if self.wanted { self.startEngine() }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        wanted = false
        restartWork?.cancel()
        teardown()
        level = 0
        peak = 0
        if status == .running { status = .idle }
    }

    /// Called when the default input device or engine configuration changes.
    func restartSoon() {
        guard wanted, status != .requesting, status != .denied else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                self.startEngine()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Shows a fixed level (used for offscreen snapshots).
    func simulate(level: Float, peak: Float) {
        self.level = level
        self.peak = peak
        status = .running
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func startEngine() {
        teardown()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // Installing a tap on a zero-channel input raises an Objective-C exception.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            status = .unavailable("No input signal")
            return
        }
        let sink: @Sendable (Float, Float) -> Void = { [weak self] rms, peak in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.ingest(rms: rms, peak: peak) }
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.tap(sink))
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartSoon() }
        }
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            status = .running
        } catch {
            input.removeTap(onBus: 0)
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            status = .unavailable("Couldn't start the meter")
            logger.error("Level meter failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ingest(rms: Float, peak newPeak: Float) {
        guard wanted, status == .running else { return }
        let target = Self.normalize(rms)
        level = target > level ? target : level + (target - level) * 0.3
        let p = Self.normalize(newPeak)
        let now = Date()
        if p >= peak {
            peak = p
            peakHeldAt = now
        } else if now.timeIntervalSince(peakHeldAt) > 1.0 {
            peak = max(p, peak - 0.02)
        }
    }

    /// Maps -60...0 dBFS to 0...1.
    nonisolated static func normalize(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        return min(max((20 * log10f(amplitude) + 60) / 60, 0), 1)
    }

    /// Built outside the main actor because the tap runs on a real-time audio thread.
    nonisolated static func tap(_ report: @escaping @Sendable (Float, Float) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0 else { return }
            let interleaved = buffer.format.isInterleaved
            let count = vDSP_Length(interleaved ? frames * channels : frames)
            var rms: Float = 0
            var peak: Float = 0
            for plane in 0..<(interleaved ? 1 : channels) {
                var r: Float = 0
                var p: Float = 0
                vDSP_rmsqv(data[plane], 1, &r, count)
                vDSP_maxmgv(data[plane], 1, &p, count)
                rms = max(rms, r)
                peak = max(peak, p)
            }
            report(rms, peak)
        }
    }
}

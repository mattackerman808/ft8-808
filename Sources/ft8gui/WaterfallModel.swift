import Foundation
import QuartzCore
import FT8808Engine
import FT8Codec
import HamlibRig

/// One decoded FT8 message, with parsed bits for display + waterfall overlay.
struct Decode: Identifiable {
    let id = UUID()
    let time: Date            // slot time (UTC)
    let mediaTime: CFTimeInterval  // arrival, for overlay aging
    let freq: Float           // audio offset Hz
    let snr: Float
    let text: String
    let call: String?         // sender callsign, if parsed
    let isCQ: Bool
}

/// Drives the live waterfall AND the decoder off one shared capture
/// (`LiveRadioSource`): the spectrum stream feeds the Metal renderer, the slot
/// stream feeds `DecodeEngine`. Decodes land in `decodes` for the list and the
/// on-waterfall overlay.
@MainActor
final class WaterfallModel: ObservableObject {
    @Published var devices: [AudioDeviceInfo] = []
    @Published var selectedUID: String?
    @Published var isRunning = false
    @Published var status = "Idle"
    @Published var mode: WaterfallMode = .threeD {
        didSet { renderer.mode = mode }
    }
    @Published private(set) var frameRate: Double = 0
    @Published private(set) var decodes: [Decode] = []

    // Rig status (read-only polling) for the meter deck.
    @Published private(set) var rigState = RigState(frequencyHz: 0, mode: .usb,
                                                    transmitting: false, connected: false)
    @Published private(set) var rigMeters: RigMeters?
    @Published var meterTest = false

    private var rig: RigController?
    private var rigTask: Task<Void, Never>?

    let renderer = WaterfallRenderer()

    // Waterfall time depth and passband, for the overlay's freq/time mapping.
    private(set) var visibleSeconds: Double = 24
    private(set) var fMin: Float = 200
    private(set) var fMax: Float = 3000

    private var radio: LiveRadioSource?
    private var frameTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?

    private let targetVisibleSeconds: Double = 24
    private let maxDecodes = 400

    // Adaptive normalisation state (dB).
    private var floorDB = Float.nan
    private var spanDB = Float.nan
    private var frameCount = 0
    private var rateClock = CACurrentMediaTime()

    init() {
        refreshDevices()
        selectedUID = devices.first(where: { $0.likelyRig })?.uid ?? devices.first?.uid
        Task { await connectRig() }
    }

    // MARK: Rig (read-only)

    /// Open the configured rig and poll state + meters. Polling is non-destructive
    /// (state + SM/RM/SW meters only — never RFPOWER, per the shim/CLAUDE.md).
    private func connectRig() async {
        guard let spec = ConfigStore.load().rigSpec else { return }
        do {
            let r = try RigSpec.controller(spec)
            try await r.open()
            rig = r
        } catch {
            return  // no rig / open failed; meters stay idle (Test still works)
        }
        rigTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let rig = self.rig else { break }
                self.rigState = await rig.state()
                self.rigMeters = await rig.meters()
                try? await Task.sleep(nanoseconds: 150_000_000)   // ~7 Hz
            }
        }
    }

    var transmitting: Bool { rigState.transmitting }

    /// Needle targets (power, SWR, ALC) as 0...1 fractions. In Test mode they
    /// sweep so the meters can be seen without transmitting.
    func meterTargets(testTime t: Double) -> (Double, Double, Double) {
        if meterTest {
            return (0.5 + 0.45 * sin(t * 1.3),
                    0.35 + 0.30 * sin(t * 0.7 + 1.1),
                    0.5 + 0.45 * sin(t * 1.9 + 2.2))
        }
        let m = rigMeters
        let power = Double(m?.powerPercent ?? m?.powerWatts.map { $0 } ?? 0) / 100.0
        let swr = swrFraction(Double(m?.swr ?? 1))
        let alc = Double(m?.alc ?? 0)        // scale is rig-dependent; clamped
        return (clamp01(power), clamp01(swr), clamp01(alc))
    }

    /// Map SWR (1…∞) onto the needle with a believable non-linear scale that
    /// matches the 1 / 1.5 / 2 / 3 / ∞ tick layout.
    private func swrFraction(_ swr: Double) -> Double {
        let pts: [(Double, Double)] = [(1, 0), (1.5, 0.25), (2, 0.5), (3, 0.75), (10, 1)]
        if swr <= pts[0].0 { return 0 }
        for i in 1..<pts.count where swr <= pts[i].0 {
            let (v0, f0) = pts[i - 1], (v1, f1) = pts[i]
            return f0 + (f1 - f0) * (swr - v0) / (v1 - v0)
        }
        return 1
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    func refreshDevices() {
        devices = AudioDevices.allDevices().filter { $0.inputChannels > 0 }
    }

    func start() {
        guard !isRunning else { return }
        let radio = LiveRadioSource(device: selectedUID, fftSize: 2048, hop: 256)
        self.radio = radio
        fMin = radio.fMin
        fMax = radio.fMax

        let rows = max(64, Int((targetVisibleSeconds * radio.framesPerSecond).rounded()))
        visibleSeconds = Double(rows) / radio.framesPerSecond
        renderer.configure(binCount: radio.binCount, historyRows: rows,
                           rowsPerSecond: radio.framesPerSecond)

        floorDB = .nan
        spanDB = .nan
        frameCount = 0
        rateClock = CACurrentMediaTime()
        decodes = []
        isRunning = true
        status = "Listening…"

        // Waterfall: continuous spectrum frames.
        frameTask = Task { @MainActor [weak self] in
            for await frame in radio.frames() {
                guard let self else { break }
                self.consume(frame)
            }
            guard let self else { return }
            if let err = radio.lastError { self.status = "\(err)" }
            self.isRunning = false
        }

        // Decoder: 15 s slots → FT8 messages.
        let engine = DecodeEngine()
        decodeTask = Task { @MainActor [weak self] in
            for await result in engine.results(from: radio) {
                guard let self else { break }
                self.ingest(result)
            }
        }
    }

    func stop() {
        frameTask?.cancel(); frameTask = nil
        decodeTask?.cancel(); decodeTask = nil
        radio?.stop(); radio = nil
        isRunning = false
        status = "Stopped"
        frameRate = 0
    }

    func toggle() { isRunning ? stop() : start() }

    // MARK: Spectrum → renderer

    private func consume(_ frame: SpectrumFrame) {
        renderer.pushRow(normalize(frame.magnitudesDB), mediaTime: CACurrentMediaTime())

        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - rateClock
        if elapsed >= 0.5 {
            frameRate = Double(frameCount) / elapsed
            frameCount = 0
            rateClock = now
        }
    }

    // MARK: Slots → decodes

    private func ingest(_ result: SlotResult) {
        let now = CACurrentMediaTime()
        let slotTime = result.startTime ?? Date()
        let span = max(1, fMax - fMin)
        // Strongest first, so the list reads like WSJT-X.
        for m in result.messages.sorted(by: { $0.score > $1.score }) {
            let parsed = QSOMessages.parse(m.text)
            let isCQ = parsed?.isCQ ?? false
            decodes.insert(Decode(time: slotTime, mediaTime: now, freq: m.frequencyHz,
                                  snr: m.snrDb, text: m.text,
                                  call: parsed?.deCall, isCQ: isCQ),
                           at: 0)
            // Tag on the waterfall (drawn inside the Metal pass for perfect sync).
            renderer.addDecodeLabel(parsed?.deCall ?? m.text,
                                    xf: (m.frequencyHz - fMin) / span,
                                    isCQ: isCQ, mediaTime: now)
        }
        if decodes.count > maxDecodes { decodes.removeLast(decodes.count - maxDecodes) }
    }

    /// Power-dB bins → [0,1] with slowly-adapting percentile floor/span.
    private func normalize(_ db: [Float]) -> [Float] {
        guard !db.isEmpty else { return db }
        let sorted = db.sorted()
        let lo = sorted[sorted.count / 10]
        let hi = sorted[min(sorted.count - 1, sorted.count * 98 / 100)]
        let targetSpan = max(18, hi - lo)

        floorDB = floorDB.isNaN ? lo : floorDB * 0.97 + lo * 0.03
        spanDB = spanDB.isNaN ? targetSpan : spanDB * 0.9 + targetSpan * 0.1

        let f = floorDB
        let s = max(1, spanDB)
        return db.map { max(0, min(1, ($0 - f) / s)) }
    }
}

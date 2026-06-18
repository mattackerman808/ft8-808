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
    let grid: String?         // sender grid, if parsed
    let isCQ: Bool
    let toMe: Bool            // addressed to my callsign
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

    // Operating state.
    @Published var txOffsetHz: Float = 1500
    @Published var selectedID: UUID?
    @Published var cqOnly = false           // Passband list: show only CQ calls
    @Published var qso: QSOSequencer?

    // Transmit (keys the rig). `txEnabled` arms the slot loop; `sending` is true
    // while a message is actually going out.
    @Published var txEnabled = false
    @Published var sending = false
    private var txTask: Task<Void, Never>?
    private var txParity: SlotParity = .even

    // Tuner / transmit (tune keys the rig).
    @Published var tuning = false
    @Published var autoTuning = false
    @Published var txLevelDb: Float = -30
    private var tx: TxAudioOutput?

    private var config = ConfigStore.load()
    var myCall: String { config.callsign }
    var myGrid: String { config.grid }
    var currentConfig: StationConfig { config }

    /// Selected decode (for answering / QSO preview).
    var selectedDecode: Decode? { decodes.first { $0.id == selectedID } }

    /// The QSO to display: the live one, or a preview built from the selected
    /// decode so the panel shows what we'd send if we answered it.
    var displayQSO: QSOSequencer? {
        if let qso { return qso }
        guard let d = selectedDecode, let call = d.call, !myCall.isEmpty else { return nil }
        return QSOSequencer(answer: call, dxGrid: d.grid, heardSnr: Int(d.snr.rounded()),
                            myCall: myCall, myGrid: myGrid)
    }
    var qsoIsPreview: Bool { qso == nil }

    /// Involves me (addressed to me, or from my current QSO partner) — these
    /// always show through any filter.
    private func mine(_ d: Decode) -> Bool {
        if d.toMe { return true }
        if let dx = qso?.dxCall, !dx.isEmpty, let c = d.call, c == dx { return true }
        return false
    }

    /// Right list: the RX-frequency window — decodes within ±80 Hz of the
    /// RX/TX offset, plus anything involving me.
    var rxDecodes: [Decode] {
        decodes.filter { abs($0.freq - txOffsetHz) <= 80 || mine($0) }
    }

    /// Left (passband) list: the whole band, optionally CQ-only.
    var passbandDecodes: [Decode] {
        cqOnly ? decodes.filter { $0.isCQ || mine($0) } : decodes
    }

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

    @Published var waterfallEnabled = true

    init() {
        refreshDevices()
        if let name = config.audioInput,
           let d = devices.first(where: { $0.name == name || $0.uid == name }) {
            selectedUID = d.uid
        } else {
            selectedUID = devices.first(where: { $0.likelyRig })?.uid ?? devices.first?.uid
        }
        if config.txOffsetHz > 0 { txOffsetHz = config.txOffsetHz }
        if config.txDriveDb < 0 { txLevelDb = config.txDriveDb }
        // Restore the saved waterfall display mode (Off / 2D / 3D).
        let dm = UserDefaults.standard.object(forKey: "displayMode") as? Int ?? 2
        waterfallEnabled = (dm != 0)
        mode = (dm == 1) ? .twoD : .threeD
        Task { await connectRig() }
        start()    // auto-start; the device comes from Settings (config.audioInput)
    }

    /// 0 = Off, 1 = 2D, 2 = 3D — for the segmented control, persisted.
    var displayModeRaw: Int { !waterfallEnabled ? 0 : (mode == .twoD ? 1 : 2) }

    func setDisplayMode(_ raw: Int) {
        UserDefaults.standard.set(raw, forKey: "displayMode")
        switch raw {
        case 0: setWaterfall(false)
        case 1: setWaterfall(true); mode = .twoD
        default: setWaterfall(true); mode = .threeD
        }
    }

    /// Toggle the waterfall rendering. When off we stop consuming spectrum frames
    /// (no FFT/Metal work); the decoder keeps running.
    func setWaterfall(_ on: Bool) {
        guard on != waterfallEnabled else { return }
        waterfallEnabled = on
        if on { startFrames() } else { frameTask?.cancel(); frameTask = nil }
    }

    // MARK: Tuner (keys the transmitter)

    static func amplitude(fromDb db: Float) -> Float { db <= -90 ? 0 : pow(10, db / 20) }

    func toggleTune() { Task { tuning ? await stopTune() : await startTune() } }

    func startTune() async {
        guard !tuning, let rig else { return }
        // Free the rig's USB codec from capture before the TX unit grabs it.
        radio?.suspend()
        let out = TxAudioOutput(frequencyHz: txOffsetHz, device: config.audioOutput)
        out.amplitude = Self.amplitude(fromDb: txLevelDb)
        do {
            try out.start()
            try await rig.setPTT(true)
        } catch {
            out.stop()
            try? await rig.setPTT(false)
            radio?.resume()
            status = "tune failed: \(error)"
            return
        }
        tx = out
        tuning = true
        status = "Tuning…"
    }

    func stopTune() async {
        guard tuning else { return }
        tx?.stop(); tx = nil
        try? await rig?.setPTT(false)
        tuning = false
        radio?.resume()
        status = isRunning ? "Listening…" : "Idle"
    }

    func setDrive(_ db: Float) {
        txLevelDb = max(-60, min(0, db))
        tx?.amplitude = Self.amplitude(fromDb: txLevelDb)
    }

    /// Persist the current drive level (call when the slider drag ends, so we
    /// don't write the file on every tick).
    func commitDrive() {
        if config.txDriveDb != txLevelDb {
            config.txDriveDb = txLevelDb
            saveConfig()
        }
    }

    /// Sweep TX drive, find the power knee (lowest drive reaching ~97% of peak),
    /// set it, stop, and persist. Ported from the TUI's autoTune.
    func autoTune() async {
        guard !autoTuning, let rig else { return }
        let startDb: Float = -34
        // Drop to the sweep's start BEFORE keying, so we never blip at the
        // slider's current (possibly high) level.
        setDrive(startDb)
        if !tuning { await startTune(); guard tuning else { return } }
        guard let probe = await rig.meters(),
              probe.powerWatts != nil || probe.powerPercent != nil else {
            status = "auto-tune needs rig power readback over CAT"
            return
        }
        autoTuning = true
        defer { autoTuning = false }

        func power(_ m: RigMeters?) -> Float { m?.powerWatts ?? ((m?.powerPercent ?? 0) * 100) }
        var samples: [(db: Float, power: Float, alc: Float)] = []
        var db = startDb
        while db <= -3 {
            if !tuning || Task.isCancelled { break }
            setDrive(db)
            try? await Task.sleep(nanoseconds: 600_000_000)
            let p1 = power(await rig.meters())
            try? await Task.sleep(nanoseconds: 350_000_000)
            let m2 = await rig.meters()
            samples.append((db, max(p1, power(m2)), m2?.alc ?? 0))
            status = String(format: "auto-tune %+.0f dBFS → %.0f W", db, max(p1, power(m2)))
            db += 2
        }
        let maxPower = samples.map(\.power).max() ?? 0
        if maxPower <= 0 {
            await stopTune()
            status = "auto-tune: no RF at any drive — check rig USB audio is the TX source"
            return
        }
        let target = maxPower * 0.97
        let pick = samples.first(where: { $0.power >= target }) ?? samples.max(by: { $0.power < $1.power })
        let knee = pick?.db ?? txLevelDb
        setDrive(knee)
        await stopTune()
        config.txDriveDb = txLevelDb
        saveConfig()
        status = String(format: "auto-tune → %+.0f dBFS ≈%.0f W ALC %.2f (saved)",
                        knee, pick?.power ?? 0, pick?.alc ?? 0)
    }

    // MARK: Settings / config

    private func saveConfig() { try? ConfigStore.save(config) }

    /// Apply edited settings: persist, re-sync the waterfall input, and reconnect
    /// the rig if its spec changed.
    func applySettings(_ newConfig: StationConfig) {
        let rigChanged = newConfig.rigSpec != config.rigSpec
        let inputChanged = newConfig.audioInput != config.audioInput
        config = newConfig
        saveConfig()
        if config.txOffsetHz > 0 { txOffsetHz = config.txOffsetHz }
        // Point the waterfall input at the configured capture device.
        if let name = config.audioInput,
           let dev = devices.first(where: { $0.name == name || $0.uid == name }) {
            selectedUID = dev.uid
        }
        if inputChanged { stop(); start() }   // re-open capture on the new device
        if rigChanged { Task { await reconnectRig() } }
    }

    func reconnectRig() async {
        rigTask?.cancel(); rigTask = nil
        await (rig as? HamlibRigController)?.close()
        rig = nil
        rigState = RigState(frequencyHz: 0, mode: .usb, transmitting: false, connected: false)
        rigMeters = nil
        await connectRig()
    }

    // MARK: LoTW

    func uploadLog() {
        guard let loc = config.lotwLocation, !loc.isEmpty else {
            status = "Set a LoTW location in Settings"; return
        }
        let path = ADIFLog.defaultURL().path
        let bin = config.tqslPath
        status = "Uploading to LoTW…"
        Task.detached {
            let outcome = TQSLUploader.upload(adifPath: path, location: loc, binary: bin)
            let msg: String
            switch outcome {
            case let .uploaded(n): msg = "LoTW: uploaded \(n) QSO\(n == 1 ? "" : "s")"
            case .nothingNew:      msg = "LoTW: nothing new (all already uploaded)"
            case let .failure(e):  msg = "LoTW: \(e)"
            }
            await MainActor.run { self.status = msg }
        }
    }

    // MARK: Operating actions (no transmit yet — set up state only)

    func select(_ d: Decode) { selectedID = (selectedID == d.id) ? nil : d.id }

    /// Arm the sequencer to call CQ (sits on Tx6). Does NOT transmit until
    /// Enable TX is pressed.
    func callCQ() {
        guard !myCall.isEmpty else { return }
        qso = QSOSequencer(callCQ: myCall, myGrid: myGrid, directive: config.cqDirective)
        txParity = .even
        status = "CQ armed — press Enable TX"
    }

    /// Commit a QSO answering the selected decode (on its frequency, opposite slot).
    func answerSelected() {
        guard let d = selectedDecode, let call = d.call, !myCall.isEmpty else { return }
        qso = QSOSequencer(answer: call, dxGrid: d.grid, heardSnr: Int(d.snr.rounded()),
                           myCall: myCall, myGrid: myGrid)
        txParity = SlotClock.parity(at: d.time).toggled
        setTxOffset(d.freq)
    }

    func clearQSO() {
        haltTX()
        qso = nil
        selectedID = nil
    }

    // MARK: Transmit

    /// Enable TX button: arm (and commit a selected decode as the QSO if needed),
    /// or — if already armed — disarm, letting any in-flight message finish.
    func enableTX() async {
        if txEnabled { disarmTX(); return }
        if qso == nil { answerSelected() }
        guard qso != nil else { status = "Nothing to send — Call CQ or select a decode"; return }
        if tuning { await stopTune() }
        txEnabled = true
        status = "Armed — TX on next \(txParity == .even ? ":00/:30" : ":15/:45")"
        startTxLoop()
    }

    /// Stop arming; an in-flight transmission completes (not cut).
    func disarmTX() {
        txEnabled = false
        status = sending ? "Finishing current TX…" : (isRunning ? "Listening…" : "Idle")
    }

    /// Stop transmitting immediately, mid-message if needed.
    func haltTX() {
        txEnabled = false
        txTask?.cancel(); txTask = nil
        tx?.stop(); tx = nil
        sending = false
        Task { try? await rig?.setPTT(false) }
        status = "TX halted"
    }

    private func startTxLoop() {
        txTask?.cancel()
        txTask = Task { @MainActor [weak self] in
            while let self, self.txEnabled, !Task.isCancelled {
                let wait = SlotClock.secondsUntilNextSlot(parity: self.txParity, after: Date())
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                if Task.isCancelled || !self.txEnabled { break }
                await self.transmitCurrentSlot()
            }
        }
    }

    private func transmitCurrentSlot() async {
        guard txEnabled, !sending, let rig else { return }
        // Grace: let this slot's decode advance the QSO before picking text.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard txEnabled, !sending, !Task.isCancelled, let text = qso?.message() else { return }
        let closing = qso?.phase == .rr73 || qso?.phase == .seventyThree

        let proto: FT8Protocol = config.proto == "ft4" ? .ft4 : .ft8
        let sr = 48_000
        let body: [Float]
        do {
            let tones = try FT8Codec.encode(text, protocol: proto)
            let msg = FT8Codec.synthesize(tones: tones, baseFrequencyHz: txOffsetHz,
                                          protocol: proto, sampleRate: sr)
            let pad = [Float](repeating: 0, count: sr / 10)
            body = pad + msg + pad
        } catch {
            status = "TX encode failed: \(error)"; disarmTX(); return
        }

        // Do NOT suspend RX capture — the rig's RX/TX codec halves are separate
        // devices; the `sending` flag drops the self-decode slot instead.
        let player = WaveformPlayer(samples: body, amplitude: Self.amplitude(fromDb: txLevelDb))
        let out = TxAudioOutput(player: player, sampleRate: Double(sr), device: config.audioOutput)
        do {
            try await rig.setPTT(true)
            try out.start()
        } catch {
            out.stop(); try? await rig.setPTT(false)
            status = "TX start failed: \(error)"; disarmTX(); return
        }
        tx = out
        sending = true
        status = "Sending: \(text)"

        // Finish the message even if disarmed mid-flight; Halt cancels the task.
        while !player.isFinished && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        out.stop()
        tx = nil
        try? await rig.setPTT(false)
        sending = false
        if closing && txEnabled { completeQSO() }
        else { status = txEnabled ? "Armed" : (isRunning ? "Listening…" : "Idle") }
    }

    /// Final message sent — log the QSO and stop transmitting.
    private func completeQSO() {
        guard let q = qso else { return }
        let isFt4 = config.proto == "ft4"
        let rec = ADIFRecord(
            call: q.dxCall,
            dateUTC: Date(),
            freqMHz: Double(rigState.frequencyHz) / 1_000_000,
            mode: isFt4 ? "MFSK" : "FT8",
            submode: isFt4 ? "FT4" : nil,
            rstSent: QSOMessages.formatReport(q.reportToSend),
            rstRcvd: q.reportReceived.map(QSOMessages.formatReport) ?? "",
            grid: q.dxGrid,
            myCall: myCall, myGrid: myGrid)
        _ = try? ADIFLog.append(rec)
        let call = q.dxCall
        qso = nil
        txEnabled = false
        txTask?.cancel(); txTask = nil
        status = "Logged \(call)"
        if config.lotwEnabled { uploadLog() }
    }

    /// Snap the TX audio offset into the passband on a 5 Hz grid. `persist`
    /// saves it to config — pass false during a continuous drag, then commit on
    /// release (so we don't rewrite config.json on every drag tick).
    func setTxOffset(_ hz: Float, persist: Bool = true) {
        let lo = fMin, hi = fMax - 60
        txOffsetHz = (min(hi, max(lo, hz)) / 5).rounded() * 5
        renderer.txFraction = (txOffsetHz - fMin) / max(1, fMax - fMin)
        if persist { commitTxOffset() }
    }

    func commitTxOffset() {
        if config.txOffsetHz != txOffsetHz {
            config.txOffsetHz = txOffsetHz
            saveConfig()
        }
    }

    // MARK: Rig (read-only)

    /// Open the configured rig and poll state + meters. Polling is non-destructive
    /// (state + SM/RM/SW meters only — never RFPOWER, per the shim/CLAUDE.md).
    private func connectRig() async {
        guard let spec = config.rigSpec else { return }
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
                // Publish only on change — assigning @Published every poll would
                // re-render the whole view tree (both decode lists) at 7 Hz.
                let s = await rig.state()
                if s != self.rigState { self.rigState = s }
                let m = await rig.meters()
                if m != self.rigMeters { self.rigMeters = m }
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
        renderer.txFraction = (txOffsetHz - fMin) / max(1, fMax - fMin)

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

        // Waterfall: continuous spectrum frames (only when enabled).
        if waterfallEnabled { startFrames() }

        // Decoder: 15 s slots → FT8 messages (always running).
        let engine = DecodeEngine()
        decodeTask = Task { @MainActor [weak self] in
            for await result in engine.results(from: radio) {
                guard let self else { break }
                self.ingest(result)
            }
        }
    }

    private func startFrames() {
        guard let radio, frameTask == nil else { return }
        frameTask = Task { @MainActor [weak self] in
            for await frame in radio.frames() {
                guard let self else { break }
                self.consume(frame)
            }
            if let err = radio.lastError { self?.status = "\(err)" }
        }
    }

    func stop() {
        haltTX()
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
        guard !sending else { return }   // drop the slot containing our own TX
        let now = CACurrentMediaTime()
        let slotTime = result.startTime ?? Date()
        let span = max(1, fMax - fMin)
        // Strongest first, so the list reads like WSJT-X.
        for m in result.messages.sorted(by: { $0.score > $1.score }) {
            let parsed = QSOMessages.parse(m.text)
            let isCQ = parsed?.isCQ ?? false
            let toMe = !myCall.isEmpty && parsed?.toCall?.uppercased() == myCall.uppercased()
            decodes.insert(Decode(time: slotTime, mediaTime: now, freq: m.frequencyHz,
                                  snr: m.snrDb, text: m.text,
                                  call: parsed?.deCall, grid: parsed?.grid, isCQ: isCQ, toMe: toMe),
                           at: 0)
            // Tag on the waterfall (drawn inside the Metal pass for perfect sync).
            renderer.addDecodeLabel(parsed?.deCall ?? m.text,
                                    xf: (m.frequencyHz - fMin) / span,
                                    isCQ: isCQ, mediaTime: now)
            // Advance a live QSO as its messages arrive.
            if qso != nil, let p = parsed {
                var q = qso!
                if q.receive(p, snr: Int(m.snrDb.rounded())) { qso = q }
            }
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

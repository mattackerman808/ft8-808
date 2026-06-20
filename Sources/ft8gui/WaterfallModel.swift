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
    var isTx = false         // our own transmitted message (TX echo), not an RX decode
    var isLogged = false     // a "✓ QSO logged" banner line, not a real decode

    /// Even (:00/:30) vs odd (:15/:45) slot this was heard in — drives the
    /// parity marker and the opposite-slot reply.
    var isEvenSlot: Bool { SlotClock.parity(at: time) == .even }
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
    /// One-shot "pounce": a freshly loaded contact transmits ASAP — fires in the
    /// CURRENT slot if it's ours and early enough for the message to still fit,
    /// and skips the decode-grace (the initial reply needs no decode-wait).
    /// Cleared after the first transmit so ongoing QSOs keep their grace.
    private var pounceArmed = false
    private let pounceWindow: Double = 2.0   // s into our slot; message must still fit 15 s
    /// Set by Halt to cut the current over without disabling TX; reset each send.
    private var abortCurrent = false
    /// Which 15 s sequence we transmit in (even :00/:30, odd :15/:45). Operator-
    /// settable for CQ; auto-set to the opposite slot when answering a decode.
    @Published var txParity: SlotParity = .even

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
        if d.isTx || d.isLogged || d.toMe { return true }   // my TX / log banner / to me
        if let dx = qso?.dxCall, !dx.isEmpty, let c = d.call, c == dx { return true }
        return false
    }

    /// Right list: the RX-frequency window — decodes within ±80 Hz of the
    /// RX/TX offset, plus anything involving me.
    var rxDecodes: [Decode] {
        decodes.filter { abs($0.freq - txOffsetHz) <= 80 || mine($0) }
    }

    /// Left (passband) list: real band activity. Our own TX echoes and the
    /// logged-QSO banner are RX-box-only, so keep them out of here.
    var passbandDecodes: [Decode] {
        let band = decodes.filter { !$0.isTx && !$0.isLogged }
        return cqOnly ? band.filter { $0.isCQ || mine($0) } : band
    }

    // Rig status (read-only polling) for the meter deck.
    @Published private(set) var rigState = RigState(frequencyHz: 0, mode: .usb,
                                                    transmitting: false, connected: false)
    @Published private(set) var rigMeters: RigMeters?
    @Published var meterTest = false

    /// Callsigns already worked (uppercased), read from the ADIF log — drives the
    /// "worked before" (red) highlight in the decode lists. Refreshed after each
    /// logged QSO.
    @Published private(set) var workedCalls: Set<String> = []

    private var rig: RigController?
    private var rigTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

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

    // Rolling "busy map" (per-slot EMA of the normalized spectrum) + its passband,
    // for the free-frequency picker — mirrors the TUI's auto-pick.
    private var avgSpectrum: [Float] = []
    private var pickPassband: ClosedRange<Float> = 200...3000

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
        workedCalls = ADIFLog.workedCalls()
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
        rigState.transmitting = true
        startMeterPoll()
        status = "Tuning…"
    }

    func stopTune() async {
        guard tuning else { return }
        tx?.stop(); tx = nil
        try? await rig?.setPTT(false)
        stopMeterPoll()
        rigState.transmitting = false
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

    /// Sweep TX drive and settle on the power knee (lowest drive reaching ~97%
    /// of the peak seen), then stop and persist. Faithful port of the TUI's
    /// autoTune — same -34→-3 sweep, no early break.
    func autoTune() async {
        guard !autoTuning, let rig else { return }

        if !tuning { await startTune(); guard tuning else { return } }

        // Need power readback to find the knee.
        guard let probe = await rig.meters(),
              probe.powerWatts != nil || probe.powerPercent != nil else {
            await stopTune()   // keyed above; never leave the rig transmitting
            status = "auto-tune needs rig power readback over CAT (not reported)"
            return
        }

        autoTuning = true
        defer { autoTuning = false }

        func power(_ m: RigMeters?) -> Float { m?.powerWatts ?? ((m?.powerPercent ?? 0) * 100) }

        // Sweep up, no early break. The FTDX power meter lags over CAT, so per
        // step we settle, then take TWO reads and keep the higher — that absorbs
        // the meter still catching up to a rising level.
        let startDb: Float = -60   // start fully backed off (slider minimum), then ramp up
        let maxDb: Float = -3
        let stepDb: Float = 2
        var samples: [(db: Float, power: Float, alc: Float)] = []
        var db = startDb
        while db <= maxDb {
            if !tuning || Task.isCancelled { break }
            setDrive(db)
            try? await Task.sleep(nanoseconds: 600_000_000)
            let p1 = power(await rig.meters())
            try? await Task.sleep(nanoseconds: 350_000_000)
            let m2 = await rig.meters()
            let p = max(p1, power(m2))        // keep the settled (higher) reading
            let alc = m2?.alc ?? 0
            samples.append((db, p, alc))
            status = String(format: "auto-tune %+.0f dBFS → %.0f W  ALC %.2f", db, p, alc)
            db += stepDb
        }

        let maxPower = samples.map(\.power).max() ?? 0
        if maxPower <= 0 {
            await stopTune()
            status = "auto-tune: no RF at any drive — check rig USB audio is the TX source"
            return
        }
        // FT8 wants ALC barely tickling: past that point more drive only feeds ALC
        // compression (= splatter), not power. So pick the HIGHEST drive whose ALC
        // is still in the clean zone — that's the real knee. Only if the rig never
        // shows usable ALC (stays under the limit even at full drive) do we fall
        // back to the 97%-of-peak power knee.
        let alcLimit: Float = 1.0
        let pick: (db: Float, power: Float, alc: Float)?
        if (samples.map(\.alc).max() ?? 0) > alcLimit {
            pick = samples.filter { $0.alc <= alcLimit }.max(by: { $0.db < $1.db })
                ?? samples.min(by: { $0.alc < $1.alc })
        } else {
            let target = maxPower * 0.97
            pick = samples.first(where: { $0.power >= target })
                ?? samples.max(by: { $0.power < $1.power })
        }
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
        meterTask?.cancel(); meterTask = nil
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
            await self.setStatus(msg)
        }
    }

    /// Set the status line from an off-main task (see `applyMeters` note).
    private func setStatus(_ s: String) { status = s }

    // MARK: Operating actions — load a contact into the sequencer

    /// Click a decode → load a QSO with that station, on its frequency, in the
    /// opposite slot, replacing any current QSO. If the decode is already
    /// addressed to us (a station answering our CQ — grid / report / R-report),
    /// resume at the correct reply instead of restarting at Tx1; otherwise we
    /// answer fresh (send our grid first). If TX is enabled it transmits on the
    /// next correct slot — no extra click. Decodes without an answerable callsign
    /// just get selected (highlighted).
    func select(_ d: Decode) {
        selectedID = d.id
        guard let call = d.call, !call.isEmpty, !myCall.isEmpty,
              call.uppercased() != myCall.uppercased() else { return }
        let snr = Int(d.snr.rounded())
        if d.toMe, let p = QSOMessages.parse(d.text), p.deCall != nil {
            // Mid-exchange reply to us — pick up at the right phase. Pull a grid
            // from an earlier decode of this station if this message has none.
            let grid = d.grid ?? decodes.first {
                $0.call?.uppercased() == call.uppercased() && $0.grid != nil
            }?.grid
            qso = QSOSequencer(resuming: p, dxGrid: grid, heardSnr: snr,
                               myCall: myCall, myGrid: myGrid)
        } else {
            qso = QSOSequencer(answer: call, dxGrid: d.grid, heardSnr: snr,
                               myCall: myCall, myGrid: myGrid)
        }
        txParity = SlotClock.parity(at: d.time).toggled
        setTxOffset(d.freq)
        pounceArmed = true               // go this slot if we're early enough
        if txEnabled { startTxLoop() }   // resync the slot loop to the new parity
        status = txEnabled ? "Answering \(call)" : "Answering \(call) — Enable TX to send"
    }

    /// Call CQ — and a toggle: while we're still calling CQ (nobody's answered),
    /// pressing it again stops (clears the CQ). Keeps the master TX toggle as-is.
    func callCQ() {
        guard !myCall.isEmpty else { return }
        if let q = qso, q.phase == .cq {           // already calling CQ → stop
            cutCurrentSend()
            qso = nil
            status = txEnabled ? "CQ stopped — still armed" : "CQ stopped"
            return
        }
        qso = QSOSequencer(callCQ: myCall, myGrid: myGrid, directive: config.cqDirective)
        selectedID = nil
        pounceArmed = true
        if txEnabled { startTxLoop() }
        status = txEnabled ? "Calling CQ (\(txParity == .even ? "even" : "odd") slot)"
                           : "CQ loaded — Enable TX to send"
    }

    /// Clear the loaded contact and stop any in-flight over (cancels an armed
    /// QSO). The master TX toggle is left on, ready for the next station / CQ.
    func clearQSO() {
        cutCurrentSend()
        qso = nil
        selectedID = nil
        status = txEnabled ? "Cleared — TX still armed" : (isRunning ? "Listening…" : "Idle")
    }

    // MARK: Transmit

    /// Master TX toggle. On → the slot loop transmits the loaded QSO each correct
    /// slot. Off → disarm AND halt any in-flight over immediately.
    func enableTX() async {
        if txEnabled { disarmTX(); return }
        if tuning { await stopTune() }
        txEnabled = true
        if qso != nil { pounceArmed = true }   // fire the loaded contact ASAP
        status = qso == nil ? "TX enabled — pick a station or Call CQ"
                            : "TX enabled — \(txParity == .even ? ":00/:30" : ":15/:45") slot"
        startTxLoop()
    }

    /// Master off: stop the slot loop, cut any in-flight over, drop PTT.
    func disarmTX() {
        txEnabled = false
        pounceArmed = false
        txTask?.cancel(); txTask = nil
        cutCurrentSend()
        status = isRunning ? "Listening…" : "Idle"
    }

    /// Halt — stop the CURRENT over only; leaves TX armed (the loop resumes next
    /// cycle). Toggle Enable TX off, or Clear / Call CQ, to actually disarm.
    func haltTX() {
        cutCurrentSend()
        status = txEnabled ? "TX halted — still armed" : "TX halted"
    }

    /// Stop the in-flight transmission now: break the send's wait loop, kill the
    /// audio, drop PTT. Does NOT touch the master toggle or cancel the slot loop.
    private func cutCurrentSend() {
        abortCurrent = true
        pounceArmed = false
        tx?.stop(); tx = nil
        stopMeterPoll()
        rigState.transmitting = false
        sending = false
        Task { try? await rig?.setPTT(false) }
    }

    private func startTxLoop() {
        txTask?.cancel()
        txTask = Task { @MainActor [weak self] in
            while let self, self.txEnabled, !Task.isCancelled {
                let now = Date()
                let posInSlot = now.timeIntervalSince1970
                    .truncatingRemainder(dividingBy: SlotClock.slotSeconds)
                let inOurSlot = SlotClock.parity(at: now) == self.txParity
                // Pounce: a freshly armed contact goes out in THIS slot if it's
                // ours and we're early enough for the message to still fit;
                // otherwise wait for the next slot boundary.
                let fireNow = self.pounceArmed && inOurSlot
                            && posInSlot < self.pounceWindow && self.qso?.message() != nil
                if !fireNow {
                    let wait = SlotClock.secondsUntilNextSlot(parity: self.txParity, after: now)
                    try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                    if Task.isCancelled || !self.txEnabled { break }
                }
                let skipGrace = self.pounceArmed   // initial reply needs no decode-wait
                self.pounceArmed = false
                await self.transmitCurrentSlot(pounce: skipGrace)
            }
        }
    }

    private func transmitCurrentSlot(pounce: Bool = false) async {
        guard txEnabled, !sending, let rig else { return }
        if !pounce {
            // Grace: let this slot's decode advance the QSO before picking text.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
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
        abortCurrent = false           // fresh over; Halt sets this to cut it short
        rigState.transmitting = true   // instant TX lamp/glow; the poll confirms it
        startMeterPoll()               // live PWR / ALC / SWR off the rig over CAT
        addTxEcho(text)                // show our own TX in the decode lists
        status = "Sending: \(text)"

        // Run the message out; Halt (abortCurrent) or disarm (task cancel) cut it.
        while !player.isFinished && !Task.isCancelled && !abortCurrent {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        let aborted = abortCurrent || Task.isCancelled
        out.stop()
        tx = nil
        try? await rig.setPTT(false)
        stopMeterPoll()
        rigState.transmitting = false
        sending = false
        if closing && txEnabled && !aborted { completeQSO() }       // don't log a cut QSO
        else if !aborted { status = txEnabled ? "TX enabled" : (isRunning ? "Listening…" : "Idle") }
    }

    /// Insert our own transmitted message into the decode lists (TX echo) so the
    /// operator sees what went out, in the RX-frequency window and the passband.
    private func addTxEcho(_ text: String) {
        decodes.insert(Decode(time: Date(), mediaTime: CACurrentMediaTime(),
                              freq: txOffsetHz, snr: 0, text: text,
                              call: myCall, grid: nil, isCQ: text.hasPrefix("CQ"),
                              toMe: false, isTx: true), at: 0)
        if decodes.count > maxDecodes { decodes.removeLast(decodes.count - maxDecodes) }
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
        workedCalls.insert(q.dxCall.uppercased())   // light it up red right away
        let sent = QSOMessages.formatReport(q.reportToSend)
        let rcvd = q.reportReceived.map(QSOMessages.formatReport) ?? "—"
        addLoggedBanner(call: q.dxCall, sent: sent, rcvd: rcvd)
        let call = q.dxCall
        qso = nil
        // Leave the master TX toggle on (idles with no QSO loaded) so the next
        // station/CQ goes out without re-enabling.
        status = "Logged \(call) — pick next or Call CQ"
        if config.lotwEnabled { uploadLog() }
    }

    /// Drop a green "✓ QSO logged" banner line into the decode lists, like the
    /// TUI, so a completed QSO is clearly marked in the feed (not just the status).
    private func addLoggedBanner(call: String, sent: String, rcvd: String) {
        let text = "✓ QSO  \(call)  sent \(sent)  rcvd \(rcvd)"
        decodes.insert(Decode(time: Date(), mediaTime: CACurrentMediaTime(),
                              freq: txOffsetHz, snr: 0, text: text,
                              call: call, grid: nil, isCQ: false, toMe: false,
                              isLogged: true), at: 0)
        if decodes.count > maxDecodes { decodes.removeLast(decodes.count - maxDecodes) }
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

    // MARK: Rig tuning (write)

    /// The current band, if the rig's dial matches a known FT8 frequency.
    var currentBand: FT8Band? { FT8Bands.matching(rigState.frequencyHz) }

    /// Set the rig's VFO. Optimistically updates the display; the poll confirms.
    /// Refused while transmitting (never move the dial mid-over).
    func setRigFrequency(_ hz: Int) {
        guard let rig, rigState.connected, !sending else { return }
        let target = max(0, hz)
        rigState.frequencyHz = target
        Task { try? await rig.setFrequency(target) }
    }

    /// Jump to a band's standard FT8 dial frequency.
    func tuneToBand(_ band: FT8Band) { setRigFrequency(band.dialHz) }

    /// Nudge the VFO up/down (e.g. the tuning steppers).
    func nudgeFrequency(_ deltaHz: Int) { setRigFrequency(rigState.frequencyHz + deltaHz) }

    /// Pick a clear, central ~50 Hz TX audio offset from the rolling busy map —
    /// the TUI's free-frequency feature. Prefers the 800–2000 Hz heart of the band.
    func autoPickTxFrequency() {
        guard let hz = FrequencyPicker.clearOffset(busyMap: avgSpectrum,
                                                   passband: pickPassband,
                                                   usable: 500...2500) else {
            status = "No spectrum yet — wait for a slot"
            return
        }
        setTxOffset(hz)
        status = "Auto-pick → TX \(Int(txOffsetHz)) Hz"
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
                // State only (freq/mode/PTT). Meters are polled separately — see
                // startMeterPoll(). Publish only on change: assigning @Published
                // every poll would re-render the whole view tree (both decode lists).
                let s = await rig.state()
                if s != self.rigState { self.rigState = s }
                try? await Task.sleep(nanoseconds: 500_000_000)   // 2 Hz
            }
        }
    }

    /// Poll the rig's TX meters (PWR/ALC/SWR) a few times a second while keyed.
    /// Deliberately a SEPARATE task from the state poll, and off the MainActor:
    /// folding meters into the state loop made every meter read wait behind the
    /// freq/mode CAT reads (and the 60 fps Metal/SwiftUI render load on the
    /// MainActor), which starved them to nothing and left the GUI gauges frozen
    /// at zero during transmit even though isolated reads (auto-tune, the TUI)
    /// worked. Mirrors ft8term's dedicated `startMeterPoll`.
    private func startMeterPoll() {
        guard meterTask == nil, let rig = self.rig else { return }
        meterTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let m = await rig.meters()
                await self?.applyMeters(m)
                try? await Task.sleep(nanoseconds: 200_000_000)   // 5 Hz
            }
        }
    }

    /// Publish a fresh meter reading (main-actor state). Called from the off-main
    /// meter poll; a plain `MainActor.run { self… }` trips Swift 6's sending-self
    /// check, whereas a main-actor method call is clean.
    private func applyMeters(_ m: RigMeters?) {
        // Detect a wide-scale ALC rig (Kenwood/Yaesu ~0–5): once it reports above
        // the Hamlib-standard 0–1 range, normalise the gauge by 5 from then on.
        if let a = m?.alc, a > 1.0 { alcWideScale = true }
        if m != rigMeters { rigMeters = m }
    }

    /// Stop the meter poll and drop the needles back to zero (no RF off-air).
    private func stopMeterPoll() {
        meterTask?.cancel()
        meterTask = nil
        rigMeters = nil
    }

    var transmitting: Bool { rigState.transmitting }

    /// True while we're calling CQ and nobody has answered yet (so the Call CQ
    /// button can act as a toggle / show "Stop CQ").
    var isCallingCQ: Bool { qso?.phase == .cq }

    /// Needle targets (power, SWR, ALC) as 0...1 fractions. In Test mode they
    /// sweep so the meters can be seen without transmitting.
    func meterTargets(testTime t: Double) -> (Double, Double, Double) {
        if meterTest {
            return (0.5 + 0.45 * sin(t * 1.3),
                    0.35 + 0.30 * sin(t * 0.7 + 1.1),
                    0.5 + 0.45 * sin(t * 1.9 + 2.2))
        }
        let m = rigMeters
        // powerWatts is in watts (≈0…100 full scale → /100); powerPercent is a
        // 0…1 fraction of the rig's max (Hamlib convention) — already the needle
        // fraction, do NOT divide. (Dividing the fraction by 100 pinned PWR at 0.)
        let power: Double
        if let w = m?.powerWatts { power = Double(w) / 100.0 }
        else if let p = m?.powerPercent { power = Double(p) }
        else { power = 0 }
        let swr = swrFraction(Double(m?.swr ?? 1))
        // ALC scale is rig-dependent: Hamlib's spec is 0–1, but Kenwood/Yaesu
        // report ~0–5 over CAT (a light "1 bar" reads ~1.0 and pegs a raw gauge).
        // Only normalise by 5 for rigs we've actually seen exceed 1.0 — standard
        // 0–1 rigs are left untouched.
        let rawAlc = Double(m?.alc ?? 0)
        let alc = alcWideScale ? rawAlc / Self.alcFullScale : rawAlc
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

    /// Full-scale ALC reading for wide-scale (Kenwood/Yaesu ~0–5) rigs.
    private static let alcFullScale: Double = 5
    /// Set once the rig reports ALC above 1.0 — i.e. it's on the ~0–5 scale, not
    /// the Hamlib-standard 0–1. Until then we pass ALC through unscaled.
    private var alcWideScale = false

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
        // `frameRate` is @Published and a change re-lays-out the whole UI (the two
        // big decode VStacks). It's only a status readout, so update it slowly.
        if elapsed >= 3.0 {
            frameRate = Double(frameCount) / elapsed
            frameCount = 0
            rateClock = now
        }
    }

    // MARK: Slots → decodes

    private func ingest(_ result: SlotResult) {
        guard !sending else { return }   // drop the slot containing our own TX

        // Maintain a rolling busy map (exponential moving average) so the free-
        // frequency picker sees recent occupancy, not one noisy slot. Skip while
        // tuning — that capture is the rig's TX monitor, not real RX.
        if !tuning {
            if avgSpectrum.count != result.spectrum.count {
                avgSpectrum = result.spectrum
            } else {
                for i in avgSpectrum.indices {
                    avgSpectrum[i] = avgSpectrum[i] * 0.6 + result.spectrum[i] * 0.4
                }
            }
            pickPassband = result.passband
        }

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

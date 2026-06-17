import Foundation
import FT8Codec
import FT8808Engine
import HamlibRig
import AVFoundation
import CoreAudio
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Thread-safe level accumulator for the `--meter` capture probe (the audio tap
/// runs on a real-time thread; the main loop reads snapshots).
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0, rms: Float = 0, frames: Int = 0
    func update(peak p: Float, rms r: Float, frames f: Int) {
        lock.lock(); peak = max(peak, p); rms = r; frames += f; lock.unlock()
    }
    func snapshot() -> (peak: Float, rms: Float, frames: Int) {
        lock.lock(); defer { peak = 0; lock.unlock() }; return (peak, rms, frames)
    }
}

// ft8term — terminal FT8 client. Milestone 1 increment: drive the engine from a
// recorded WAV and render a live status line, spectrum, and band-activity log.
//
//   swift run ft8term <file.wav> [--ft4]
//
// Live audio capture and rig/TX control arrive in later increments; the rig
// shown here is the MockRigController.

// ---- A line in the scrolling band-activity log (decode or note) --------------
struct ActivityLine {
    let text: String              // pre-formatted content
    let cq: Bool                  // highlight CQ calls
    var message: FT8Message? = nil    // structured decode (nil for notes / TX echo)
    var parity: SlotParity? = nil     // slot we heard it in (for opposite-slot reply)
    var mine: Bool = false            // involves my call (QSO column) or my own TX
    var toMe: Bool = false            // my call appears in the message (highlight green)
    var deCall: String? = nil         // sender callsign (for worked-before check)
}

@MainActor
final class App {
    let engine: DecodeEngine
    let source: any AudioSource
    let liveSource: LiveAudioSource?   // non-nil in live mode; suspended during TX
    let rig: RigController
    let sourceLabel: String
    let outDevice: String?
    let spectrumCols: Int
    let proto: FT8Protocol

    private var config: StationConfig
    private var spectrum: [Float] = []
    private var avgSpectrum: [Float] = []          // rolling busy map for auto-pick
    private var passband: ClosedRange<Float> = 200...3000
    private var txOffsetHz: Float                  // where the TX cursor / tone sits
    private var activity: [ActivityLine] = []
    private var slotCount = 0
    private var finished = false
    private var quit: CheckedContinuation<Void, Never>?
    private var rigState = RigState(frequencyHz: 14_074_000, mode: .usb,
                                    transmitting: false, connected: true)

    // Tune (transmit-audio calibration) state.
    private var tx: TxAudioOutput?
    private var tuning = false
    private var tuneBusy = false        // guards async start/stop transitions
    private var txLevelDb: Float = -40  // audio drive in dBFS (fine control)
    private var lastMeters: RigMeters?
    private var meterTask: Task<Void, Never>?
    private var notice: String? { didSet { noticeSetAt = (notice == nil) ? nil : Date() } }
    private var noticeSetAt: Date?
    private var autoTuning = false

    // Transmit (CQ / QSO) state.
    private var txEnabled = false             // master "Enable TX" trigger
    private var txParity: SlotParity = .even  // which 15 s sequence we transmit in
    private var qso: QSOSequencer?            // active CQ / QSO state machine
    private var txTask: Task<Void, Never>?    // slot-aligned scheduler loop
    private var sending = false               // a waveform is on the air right now
    private var selectedIndex: Int?           // selected decode in the activity log
    private var bandTop = 0                    // top visible band row (frozen while selecting)
    private var workedCalls: Set<String> = []  // calls already in the ADIF log (worked-before)

    // Settings panel.
    private enum Mode { case receive, settings }
    private var mode: Mode = .receive
    private var settings: SettingsEditor?

    private static func amplitude(fromDb db: Float) -> Float {
        db <= -90 ? 0 : pow(10, db / 20)
    }

    /// Half-width of the Rx-frequency filter for the right column (Hz).
    private static let rxFilterTolHz: Float = 12

    private let pendingNotice: String?

    init(source: any AudioSource, label: String, proto: FT8Protocol, rig: RigController,
         outDevice: String?, config: StationConfig, initialNotice: String? = nil) {
        let (rows, cols) = Terminal.size()
        _ = rows
        let columns = max(20, cols - 2)
        self.engine = DecodeEngine(proto: proto, spectrumColumns: columns)
        self.spectrumCols = columns
        self.proto = proto
        self.source = source
        self.liveSource = source as? LiveAudioSource
        self.rig = rig
        self.sourceLabel = label
        self.outDevice = outDevice
        self.config = config
        self.pendingNotice = initialNotice
        self.txOffsetHz = config.txOffsetHz
        self.txLevelDb = config.txDriveDb
    }

    private let interactive = isatty(STDIN_FILENO) == 1

    private var clockTask: Task<Void, Never>?

    func run() async {
        workedCalls = ADIFLog.workedCalls()
        rigState = await rig.state()
        if let pendingNotice { notice = pendingNotice }
        if interactive { startKeyReader(); startRigPoll(); startClock() }
        render()
        let engine = self.engine      // Sendable structs — safe to capture.
        let source = self.source
        let consume = Task { [weak self] in
            for await result in engine.results(from: source) {
                if Task.isCancelled { break }
                self?.apply(result)
            }
            self?.markFinished()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.quit = c
        }
        // Always leave the rig in receive on the way out.
        clockTask?.cancel(); clockTask = nil
        meterTask?.cancel(); meterTask = nil
        disableTx()
        tx?.stop(); tx = nil
        // Unconditionally un-key on the way out — never depend on the tuning
        // flag (a half-started tune could have PTT on with tuning == false).
        try? await rig.setPTT(false); tuning = false
        // Persist the current TX offset / drive for next launch.
        config.txOffsetHz = txOffsetHz
        config.txDriveDb = txLevelDb
        saveConfig()
        consume.cancel()
    }

    private func apply(_ r: SlotResult) {
        // Ignore captured audio while transmitting — it's the rig's TX monitor,
        // not real receive, so it would show phantom decodes/waterfall.
        guard !tuning, !sending else { return }
        slotCount += 1
        spectrum = r.spectrum
        passband = r.passband

        // Maintain a rolling "busy map" (exponential moving average) so auto-pick
        // sees recent occupancy, not just one noisy slot.
        if avgSpectrum.count != r.spectrum.count {
            avgSpectrum = r.spectrum
        } else {
            for i in avgSpectrum.indices {
                avgSpectrum[i] = avgSpectrum[i] * 0.6 + r.spectrum[i] * 0.4
            }
        }

        let parity = r.startTime.map { SlotClock.parity(at: $0) }
        let myCall = config.callsign.uppercased()
        for m in r.messages.sorted(by: { $0.score > $1.score }) {
            let snr = String(format: "%+4.0f", m.snrDb)
            let dt = String(format: "%+4.1f", m.timeSeconds)
            let freq = String(format: "%4.0f", m.frequencyHz)
            // "Mine" = directed to me, or from the station I'm working.
            let p = QSOMessages.parse(m.text)
            let toMe = !myCall.isEmpty && (p?.toCall == myCall || p?.deCall == myCall)
            let mine = toMe || (qso?.dxCall.isEmpty == false && p?.deCall == qso!.dxCall)
            activity.append(ActivityLine(text: " \(snr) \(dt) \(freq)  \(m.text)",
                                         cq: m.text.hasPrefix("CQ"),
                                         message: m, parity: parity, mine: mine,
                                         toMe: toMe, deCall: p?.deCall))
            // Advance an in-progress QSO when the DX replies to us.
            if qso != nil, let p, qso!.receive(p, snr: Int(m.snrDb.rounded())) {
                if qso!.isComplete { completeQSO() }
            }
        }
        render()
    }

    private func markFinished() {
        finished = true
        // Surface a live-capture failure (e.g. permission/device) instead of
        // silently showing no audio.
        if let err = liveSource?.lastError { notice = "audio: \(err)" }
        render()
        // In non-interactive/batch mode there is no key to wait for: exit once
        // the source is exhausted.
        if !interactive { quit?.resume(); quit = nil }
    }

    /// Animate the cycle bar / clock by re-rendering a few times a second.
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                self.render()
            }
        }
    }

    /// Refresh the rig status line once a second so a real rig's freq/mode/PTT
    /// stay current.
    private func startRigPoll() {
        let rig = self.rig
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let s = await rig.state()
                guard let self else { return }
                if s != self.rigState { self.rigState = s; self.render() }
            }
        }
    }

    private func startKeyReader() {
        let thread = Thread {
            var byte: UInt8 = 0
            while read(STDIN_FILENO, &byte, 1) == 1 {
                if byte == 0x1B { // ESC — arrow sequence (ESC [ A/B/C/D) or a lone Esc
                    // Poll briefly so a bare Esc doesn't block waiting for a key.
                    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                    if poll(&pfd, 1, 40) > 0, (pfd.revents & Int16(POLLIN)) != 0 {
                        var b1: UInt8 = 0
                        if read(STDIN_FILENO, &b1, 1) == 1 {
                            if b1 == 0x5B || b1 == 0x4F {   // CSI '[' or SS3 'O' (app cursor keys)
                                var b2: UInt8 = 0
                                if read(STDIN_FILENO, &b2, 1) == 1 {
                                    let dir = b2
                                    Task { @MainActor in self.handleArrow(dir) }
                                }
                            } else {
                                let other = b1
                                Task { @MainActor in self.handleKey(27); self.handleKey(other) }
                            }
                        }
                    } else {
                        Task { @MainActor in self.handleKey(27) } // lone Esc
                    }
                    continue
                }
                let c = byte
                Task { @MainActor in self.handleKey(c) }
                // Keep reading until the process exits — do NOT stop on 'q',
                // which is context-dependent (it cancels settings, etc.).
            }
            // EOF / closed stdin (e.g. piped or non-interactive): quit cleanly.
            Task { @MainActor in self.handleKey(UInt8(ascii: "q")) }
        }
        thread.stackSize = 1 << 16
        thread.start()
    }

    private func handleKey(_ c: UInt8) {
        // Ctrl-C always quits (and the quit path un-keys), from any mode.
        if c == 3 { quit?.resume(); quit = nil; return }
        if mode == .settings { settingsKey(c); return }
        switch c {
        case UInt8(ascii: "q"):
            quit?.resume(); quit = nil
        case UInt8(ascii: "s"), UInt8(ascii: "S"):
            openSettings()
        case UInt8(ascii: "t"), UInt8(ascii: "T"):
            toggleTune()
        case UInt8(ascii: "+"), UInt8(ascii: "="):
            if tuning && !autoTuning { setLevelDb(txLevelDb + 1) }
        case UInt8(ascii: "-"), UInt8(ascii: "_"):
            if tuning && !autoTuning { setLevelDb(txLevelDb - 1) }
        case UInt8(ascii: "a"), UInt8(ascii: "A"):
            if !autoTuning { Task { await autoTune() } }
        case UInt8(ascii: ","):                 // TX cursor: fine left
            setTxOffset(txOffsetHz - 10)
        case UInt8(ascii: "."):                 // fine right
            setTxOffset(txOffsetHz + 10)
        case UInt8(ascii: "<"):                 // coarse left
            setTxOffset(txOffsetHz - 100)
        case UInt8(ascii: ">"):                 // coarse right
            setTxOffset(txOffsetHz + 100)
        case UInt8(ascii: "f"), UInt8(ascii: "F"):
            autoPickTxFrequency()
        case UInt8(ascii: "c"), UInt8(ascii: "C"):
            callCQ()
        case UInt8(ascii: "e"), UInt8(ascii: "E"):
            toggleTx()
        case UInt8(ascii: "o"), UInt8(ascii: "O"):
            toggleParity()
        case 13, 10:                       // Enter — answer the selected decode
            answerSelected()
        case UInt8(ascii: "k"): moveSelection(-1)   // vim-style selection fallback
        case UInt8(ascii: "j"): moveSelection(1)
        case 27:                                    // Esc — clear selection, else abandon QSO
            if selectedIndex != nil { selectedIndex = nil; render() }
            else if qso != nil { disableTx(); qso = nil; notice = "QSO cleared"; render() }
        default:
            break
        }
    }

    /// Arrow keys: ↑/↓ move the decode-selection cursor; ←/→ nudge the TX cursor
    /// (fine). Coarse TX moves stay on `<`/`>`.
    private func handleArrow(_ dir: UInt8) {
        if mode == .settings { settingsArrow(dir); return }
        switch dir {
        case 0x41: moveSelection(-1)              // up
        case 0x42: moveSelection(1)               // down
        case 0x43: setTxOffset(txOffsetHz + 10)   // right
        case 0x44: setTxOffset(txOffsetHz - 10)   // left
        default:
            // Diagnostic: surface an unexpected arrow code so we can see what
            // this terminal actually sends for the arrow keys.
            notice = "unrecognized arrow code \(dir) — use j/k to select"
            render()
        }
    }

    // ---- Settings panel ------------------------------------------------------

    private func openSettings() {
        // Never enter settings while keyed — stop the tone and un-key first.
        if tuning { Task { await stopTune(); openSettingsNow() }; return }
        openSettingsNow()
    }

    private func openSettingsNow() {
        settings = SettingsEditor(
            config: config,
            serialPorts: SerialPorts.list(),
            inputDevices: AudioDevices.inputDevices(),
            outputDevices: AudioDevices.outputDevices())
        mode = .settings
        render()
    }

    private func closeSettings() {
        settings = nil
        mode = .receive
        render()
    }

    private func applySettings() {
        guard let ed = settings else { return }
        ed.apply(to: &config)
        saveConfig()
        settings = nil
        mode = .receive
        notice = "settings saved — restart to apply rig/audio/proto changes"
        render()
    }

    private func settingsKey(_ c: UInt8) {
        guard let ed = settings else { return }
        if ed.rigPicking {
            switch c {
            case 13, 10: ed.rigPickerChoose()
            case 27, 9: ed.rigPickerCancel()           // Esc / Tab cancels
            case 127, 8: ed.rigPickerBackspace()
            case 32...126: ed.rigPickerType(Character(UnicodeScalar(c)))
            default: break
            }
            render(); return
        }
        if ed.editing {
            switch c {
            case 13, 10: ed.commitEdit()
            case 27: ed.editing = false                // Esc: cancel edit
            case 127, 8: ed.backspace()
            case 32...126: ed.typeCharacter(Character(UnicodeScalar(c)))
            default: break
            }
            render(); return
        }
        switch c {
        case 13, 10:
            if ed.selected == ed.rigFieldIndex { ed.startRigPicker() }
            else { ed.activate() }
        case 27, UInt8(ascii: "q"): closeSettings()    // Esc / q: cancel
        case UInt8(ascii: "s"): applySettings()        // s: save
        default: break
        }
        render()
    }

    private func settingsArrow(_ dir: UInt8) {
        guard let ed = settings else { return }
        if ed.rigPicking {
            switch dir {
            case 0x41: ed.rigPickerMove(-1)
            case 0x42: ed.rigPickerMove(1)
            default: break
            }
            render(); return
        }
        guard !ed.editing else { return }
        switch dir {
        case 0x41: ed.moveSelection(-1)  // up
        case 0x42: ed.moveSelection(1)   // down
        case 0x44, 0x43:                 // left/right
            if ed.selected == ed.rigFieldIndex { ed.startRigPicker() }
            else { ed.cycle(dir == 0x44 ? -1 : 1) }
        default: break
        }
        render()
    }

    /// Move the TX cursor, keeping room for the ~50 Hz signal inside the passband.
    private func setTxOffset(_ hz: Float) {
        let lo = passband.lowerBound
        let hi = passband.upperBound - 60
        txOffsetHz = (max(lo, min(hi, hz)) / 5).rounded() * 5   // snap to 5 Hz
        tx?.setFrequency(txOffsetHz)                            // follow live while tuning
        render()
    }

    private func saveConfig() { try? ConfigStore.save(config) }

    /// Auto-pick a clear, usable, central ~50 Hz slice from the busy map.
    private func autoPickTxFrequency() {
        let spec = avgSpectrum.isEmpty ? spectrum : avgSpectrum
        // Prefer the 800–2000 Hz heart of the band, strongly centered.
        guard let hz = FrequencyPicker.clearOffset(busyMap: spec, passband: passband,
                                                   usable: 800...2000) else {
            notice = "no spectrum yet — wait for a slot"; render(); return
        }
        setTxOffset(hz)
        notice = "auto-pick → TX \(Int(txOffsetHz)) Hz"
    }

    // ---- Tune (transmit-audio calibration) -----------------------------------

    private func toggleTune() {
        guard !tuneBusy else { return }
        if tuning { Task { await stopTune() } }
        else { Task { await startTune() } }
    }

    private func startTune() async {
        guard !tuning, !tuneBusy else { return }
        // Tune and message-TX both key the rig and own the codec — never both.
        if txEnabled || sending { disableTx() }
        tuneBusy = true
        defer { tuneBusy = false }

        // Release the rig's USB codec from capture before the TX engine grabs it.
        liveSource?.suspend()

        // Note: rear/USB audio routing is handled by the DATA PTT in the Hamlib
        // shim (RIG_PTT_ON_DATA → Kenwood "TX1;"), so we deliberately do NOT
        // switch the rig to a data mode here — that would clamp the passband to
        // the data-mode roofing filter. The rig stays in plain USB for FT8.
        let out = TxAudioOutput(frequencyHz: txOffsetHz, device: outDevice)
        out.amplitude = Self.amplitude(fromDb: txLevelDb)
        do {
            try out.start()
            try await rig.setPTT(true)
        } catch {
            out.stop()
            try? await rig.setPTT(false)
            liveSource?.resume()        // restore capture if tune couldn't start
            notice = "tune failed: \(error)"
            render()
            return
        }
        tx = out
        tuning = true
        rigState.transmitting = true
        notice = nil
        startMeterPoll()
        render()
    }

    private func stopTune() async {
        guard tuning, !tuneBusy else { return }
        tuneBusy = true
        defer { tuneBusy = false }

        meterTask?.cancel(); meterTask = nil
        lastMeters = nil
        tx?.stop()
        tx = nil
        try? await rig.setPTT(false)
        tuning = false
        rigState.transmitting = false
        render()
        await resumeCapture()           // settle + retry so receive comes back
    }

    /// Poll the rig's TX meters a few times a second while tuning.
    private func startMeterPoll() {
        let rig = self.rig
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                let m = await rig.meters()
                guard let self else { return }
                if m != self.lastMeters { self.lastMeters = m; self.render() }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func setLevelDb(_ db: Float) {
        txLevelDb = max(-60, min(0, db))
        tx?.amplitude = Self.amplitude(fromDb: txLevelDb)
        render()
    }

    /// Bring receive capture back after a transmit. The TX AUHAL output may not
    /// have released the rig's codec the instant we stop it, so `resume()` can
    /// fail transiently — settle briefly and retry rather than silently leaving
    /// RX dead (which looked like "no decodes after transmitting").
    private func resumeCapture() async {
        guard let live = liveSource else { return }
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if live.resume() { return }
        }
        notice = "receive didn't resume — toggle [T]une or restart if decodes stop"
        render()
    }

    // ---- Transmit: CQ + slot-aligned scheduling -----------------------------

    /// `C` — call CQ: start the sequencer in CQ mode and transmit each slot.
    private func callCQ() {
        guard requireStation() else { return }
        if tuning { Task { await stopTune(); callCQ() }; return }
        qso = QSOSequencer(callCQ: config.callsign, myGrid: config.grid,
                           directive: config.cqDirective)
        txEnabled = true
        startTxLoop()
        notice = "calling CQ on next \(txParity == .even ? "even" : "odd") slot"
        render()
    }

    /// Enter — answer the selected decode: set up the QSO, reply on the DX's
    /// frequency, and transmit in the opposite slot.
    private func answerSelected() {
        guard requireStation() else { return }
        guard let i = selectedIndex, i < activity.count, let m = activity[i].message else {
            notice = "no decode selected — ↑/↓ to pick, Enter to answer"; render(); return
        }
        guard let p = QSOMessages.parse(m.text), let dx = p.deCall else {
            notice = "no callsign to answer on that line"; render(); return
        }
        if tuning { Task { await stopTune(); answerSelected() }; return }
        qso = QSOSequencer(answer: dx, dxGrid: p.grid, heardSnr: Int(m.snrDb.rounded()),
                           myCall: config.callsign, myGrid: config.grid)
        txParity = (activity[i].parity ?? SlotClock.parity(at: Date())).toggled
        setTxOffset(m.frequencyHz)              // call on their frequency
        selectedIndex = nil                     // clear: panel now shows the live QSO
        txEnabled = true
        startTxLoop()
        notice = "answering \(dx) — TX \(txParity == .even ? "even" : "odd") slot"
        render()
    }

    /// `E` — toggle the master Enable-TX trigger (defaults to CQ if nothing set).
    private func toggleTx() {
        if txEnabled { disableTx(); notice = "TX disabled"; render(); return }
        guard requireStation() else { return }
        if tuning { Task { await stopTune(); toggleTx() }; return }
        if qso == nil {
            qso = QSOSequencer(callCQ: config.callsign, myGrid: config.grid,
                               directive: config.cqDirective)
        }
        txEnabled = true
        startTxLoop()
        notice = "TX enabled"
        render()
    }

    /// `O` — swap the even/odd transmit sequence.
    private func toggleParity() {
        txParity = txParity.toggled
        notice = "TX slot: \(txParity.label)"
        render()
    }

    private func requireStation() -> Bool {
        if config.isStationSet { return true }
        notice = "set your callsign & grid in [S]ettings first"
        render()
        return false
    }

    private func disableTx() {
        txEnabled = false
        txTask?.cancel(); txTask = nil
    }

    /// The QSO reached 73 — log it to the activity feed + ADIF, and stop TX.
    private func completeQSO() {
        if let q = qso {
            let sent = QSOMessages.formatReport(q.reportToSend)
            let rcvd = q.reportReceived.map { QSOMessages.formatReport($0) } ?? "—"
            activity.append(ActivityLine(text: " \(Terminal.fg256(46))✓ QSO  \(q.dxCall)"
                + "  sent \(sent)  rcvd \(rcvd)\(Terminal.reset)",
                cq: false, mine: true))
            logQSOToADIF(q, sent: sent)
        }
        disableTx()
        qso = nil
    }

    /// Append the completed QSO to the ADIF log file.
    private func logQSOToADIF(_ q: QSOSequencer, sent: String) {
        let rec = ADIFRecord(
            call: q.dxCall,
            dateUTC: Date(),
            freqMHz: Double(rigState.frequencyHz) / 1_000_000,
            mode: proto == .ft4 ? "MFSK" : "FT8",
            submode: proto == .ft4 ? "FT4" : nil,
            rstSent: sent,
            rstRcvd: q.reportReceived.map { QSOMessages.formatReport($0) } ?? "",
            grid: (q.dxGrid?.isEmpty == false) ? q.dxGrid : nil,
            myCall: config.callsign,
            myGrid: config.grid)
        do {
            let url = try ADIFLog.append(rec)
            workedCalls.insert(q.dxCall.uppercased())
            notice = "✓ logged \(q.dxCall) → \(url.lastPathComponent)"
        } catch {
            notice = "QSO done but ADIF log failed: \(error.localizedDescription)"
        }
    }

    /// The QSO to display in the state panel: the live one, or a preview built
    /// from the currently-selected decode (so you can see what you'd send).
    private func activeOrPreviewQSO() -> (q: QSOSequencer, preview: Bool)? {
        // A live selection previews first (so you can switch stations mid-QSO);
        // otherwise show the active QSO.
        if config.isStationSet, let i = selectedIndex, i < activity.count,
           let m = activity[i].message, let p = QSOMessages.parse(m.text), let dx = p.deCall {
            return (QSOSequencer(answer: dx, dxGrid: p.grid, heardSnr: Int(m.snrDb.rounded()),
                                 myCall: config.callsign, myGrid: config.grid), true)
        }
        if let q = qso { return (q, false) }
        return nil
    }

    /// Navigation controls under the LEFT (band) column — they act on it.
    private func bandControls() -> String {
        " \(Terminal.dim)↑↓/jk\(Terminal.reset) pick   \(Terminal.dim)⏎\(Terminal.reset) answer"
    }

    /// QSO/TX controls at the bottom of the RIGHT column (near the QSO panel).
    private func qsoControls() -> String {
        " \(Terminal.bold)[C]\(Terminal.reset)Q   \(Terminal.bold)[E]\(Terminal.reset) TX   "
        + "\(Terminal.bold)[O]\(Terminal.reset) slot   \(Terminal.dim)esc\(Terminal.reset) clear"
    }

    /// WSJT-X-style state panel: DX call/grid + the Tx1–Tx6 sequence with the
    /// current step highlighted, then a QSO-controls line. Always non-empty (the
    /// controls show even when idle, so they sit with the QSO area not the top).
    private func qsoPanel(width: Int) -> [String] {
        guard let (q, preview) = activeOrPreviewQSO() else { return [qsoControls()] }
        let mc = q.myCall, mg = q.myGrid, dx = q.dxCall, r = q.reportToSend
        let rows: [(String, String, QSOSequencer.Phase)] = [
            ("Tx1", dx.isEmpty ? "" : QSOMessages.reply(dx: dx, myCall: mc, myGrid: mg), .reply),
            ("Tx2", dx.isEmpty ? "" : QSOMessages.report(dx: dx, myCall: mc, snr: r), .report),
            ("Tx3", dx.isEmpty ? "" : QSOMessages.rogerReport(dx: dx, myCall: mc, snr: r), .rReport),
            ("Tx4", dx.isEmpty ? "" : QSOMessages.roger(dx: dx, myCall: mc), .rr73),
            ("Tx5", dx.isEmpty ? "" : QSOMessages.seventyThree(dx: dx, myCall: mc), .seventyThree),
            ("Tx6", QSOMessages.cq(call: mc, grid: mg, directive: config.cqDirective), .cq),
        ]
        let dxInfo = dx.isEmpty ? "\(Terminal.dim)(awaiting answer)\(Terminal.reset)"
            : "\(Terminal.bold)\(dx)\(Terminal.reset)\(q.dxGrid.map { " \(Terminal.dim)\($0)\(Terminal.reset)" } ?? "")"
        let state = preview
            ? "\(Terminal.dim)⏎ to answer\(Terminal.reset)"
            : (sending ? "\(Terminal.fg256(196))● ON AIR\(Terminal.reset)"
                       : "\(Terminal.fg256(208))○ armed\(Terminal.reset)")
        var lines = [" \(Terminal.fg256(45))\(preview ? "LOAD" : "QSO")\(Terminal.reset)  "
            + "DX \(dxInfo)  \(Terminal.dim)\(txParity == .even ? "even" : "odd") slot\(Terminal.reset)  \(state)"]
        for (label, text, phase) in rows {
            let cur = phase == q.phase
            let marker = cur ? "\(Terminal.fg256(45))▸\(Terminal.reset)" : " "
            let style = cur ? Terminal.bold : Terminal.dim
            let body = text.isEmpty ? "—" : text
            let tag = cur ? "  \(Terminal.fg256(preview ? 244 : 196))\(preview ? "next" : "now")\(Terminal.reset)" : ""
            lines.append("  \(marker) \(style)\(label)  \(body)\(Terminal.reset)\(tag)")
        }
        lines.append(qsoControls())
        return lines
    }

    /// ↑/↓ — move the decode-selection cursor over message-bearing log lines.
    private func moveSelection(_ delta: Int) {
        let idxs = activity.indices.filter { activity[$0].message != nil }
        guard !idxs.isEmpty else { return }
        if let cur = selectedIndex, let pos = idxs.firstIndex(of: cur) {
            selectedIndex = idxs[max(0, min(idxs.count - 1, pos + delta))]
        } else {
            selectedIndex = idxs.last   // first press selects the newest (bottom of view)
        }
        render()
    }

    /// Slot-aligned scheduler: sleep to the next matching boundary, transmit the
    /// queued message, repeat while enabled. Runs on the main actor (it only
    /// ever suspends — the audio plays on the AUHAL thread).
    private func startTxLoop() {
        txTask?.cancel()
        txTask = Task { [weak self] in
            while let self, self.txEnabled, !Task.isCancelled {
                let wait = SlotClock.secondsUntilNextSlot(parity: self.txParity, after: Date())
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                if Task.isCancelled || !self.txEnabled { break }
                await self.transmitCurrentSlot()
            }
        }
    }

    /// Encode + synthesize the sequencer's current message and play it for one
    /// slot, keyed via PTT. We wait a short grace period after the boundary so
    /// the just-ended slot's decode can land and advance the QSO — i.e. we reply
    /// in the SAME cycle. The first symbol then lands ~grace+0.1 s into the slot
    /// (DT ≈ +1.4 s, well within the decoder's sync window).
    private func transmitCurrentSlot() async {
        guard txEnabled, !tuning, !sending else { return }
        // Grace: let this slot's decode advance the QSO before we pick the text.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard txEnabled, !tuning, !sending, !Task.isCancelled,
              let text = qso?.message() else { return }
        // Closing message (RR73 or 73): this is the last thing we send — log the
        // QSO and stop after it goes out, rather than waiting forever for a final
        // confirmation the DX often doesn't send.
        let closing = qso?.phase == .rr73 || qso?.phase == .seventyThree
        let sr = 48_000
        let body: [Float]
        do {
            let tones = try FT8Codec.encode(text, protocol: proto)
            let msg = FT8Codec.synthesize(tones: tones, baseFrequencyHz: txOffsetHz,
                                          protocol: proto, sampleRate: sr)
            let lead = [Float](repeating: 0, count: sr / 10)  // 0.1 s (grace is the lead)
            let tail = [Float](repeating: 0, count: sr / 10)  // 0.1 s guard
            body = lead + msg + tail
        } catch {
            notice = "TX encode failed: \(error)"; disableTx(); render(); return
        }

        let player = WaveformPlayer(samples: body, amplitude: Self.amplitude(fromDb: txLevelDb))
        let out = TxAudioOutput(player: player, sampleRate: Double(sr), device: outDevice)
        // Do NOT suspend RX capture: the rig exposes its codec as separate input
        // (RX) and output (TX) CoreAudio devices, so the capture AVAudioEngine and
        // the TX AUHAL output run on different devices and don't fight. Tearing
        // capture down and rebuilding it every transmit was what wedged the audio
        // driver. The `sending` flag makes apply() drop the TX-monitor slots.
        do {
            try await rig.setPTT(true)
            try out.start()
        } catch {
            out.stop(); try? await rig.setPTT(false)
            notice = "TX start failed: \(error)"; disableTx(); render(); return
        }
        sending = true
        rigState.transmitting = true
        activity.append(ActivityLine(text: " \(Terminal.fg256(196))Tx\(Terminal.reset)        \(text)", cq: false, mine: true))
        render()

        // Wait out the slot; bail early if TX is disabled mid-transmission.
        while !player.isFinished && txEnabled && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        out.stop()
        try? await rig.setPTT(false)
        sending = false
        rigState.transmitting = false
        if closing && txEnabled { completeQSO() }   // sent our final → log + stop
        render()
    }

    /// Find the clean drive level by sweeping and reading the POWER curve: below
    /// the knee power tracks drive, at/above it the rig limits and power flattens.
    /// We sweep up until power clearly plateaus, then settle at the LOWEST drive
    /// that reaches ~97% of the peak — max power with the least audio (no ALC).
    /// Independent of the rig's ALC scale.
    private func autoTune() async {
        guard !autoTuning, !tuneBusy else { return }

        if !tuning { await startTune(); guard tuning else { return } }

        // Need power readback to find the knee.
        guard let probe = await rig.meters(),
              probe.powerWatts != nil || probe.powerPercent != nil else {
            notice = "auto-tune needs rig power readback over CAT (not reported)"
            render()
            return
        }

        autoTuning = true
        defer { autoTuning = false }

        func power(_ m: RigMeters?) -> Float { m?.powerWatts ?? ((m?.powerPercent ?? 0) * 100) }

        // Sweep up, no early break. The FTDX power meter lags over CAT, so per
        // step we settle, then take TWO reads and keep the higher — that absorbs
        // the meter still catching up to a rising level. Each step is logged so
        // the actual power curve is visible.
        logNote("\(Terminal.dim)── auto-tune sweep ──\(Terminal.reset)")
        let startDb: Float = -34   // start low, but sweep up far enough for low-gain rigs
        let maxDb: Float = -3
        let stepDb: Float = 2
        var samples: [(db: Float, power: Float, alc: Float)] = []
        var db = startDb

        while db <= maxDb {
            if !tuning || Task.isCancelled { break }
            setLevelDb(db)
            try? await Task.sleep(nanoseconds: 600_000_000)
            let p1 = power(await rig.meters())
            try? await Task.sleep(nanoseconds: 350_000_000)
            let m2 = await rig.meters()
            lastMeters = m2
            let p = max(p1, power(m2))        // keep the settled (higher) reading
            let alc = m2?.alc ?? 0
            samples.append((db, p, alc))
            logNote(String(format: "  %+.0f dBFS   %3.0f W   ALC %.2f", db, p, alc))
            render()
            db += stepDb
        }

        // Target the POWER knee: the LOWEST drive reaching ~97% of the peak seen.
        // Report the power MEASURED AT that step (no fresh read after dropping the
        // level — that catches the meter mid-transition and reads near zero).
        let maxPower = samples.map(\.power).max() ?? 0

        // No power even at full drive → audio isn't reaching the rig's modulator.
        if maxPower <= 0 {
            await stopTune()
            notice = "auto-tune: no RF at any drive — check the rig's USB audio is the TX "
                + "source and the Mac output volume for the codec is up (--list-audio)."
            render()
            return
        }

        let target = maxPower * 0.97
        let pick = samples.first(where: { $0.power >= target })
            ?? samples.max(by: { $0.power < $1.power })
        let knee = pick?.db ?? txLevelDb
        let resultAlc = pick?.alc ?? 0
        let kneePower = pick?.power ?? 0

        setLevelDb(knee)

        // Calibration done — stop transmitting and persist the drive level.
        await stopTune()
        config.txDriveDb = txLevelDb
        saveConfig()
        notice = String(format: "auto-tune → %+.0f dBFS  ≈%.0f W  ALC %.2f  (TX off, saved)",
                        knee, kneePower, resultAlc)
        logNote(String(format: "\(Terminal.fg256(45))→ knee %+.0f dBFS  %.0f W  ALC %.2f\(Terminal.reset)",
                       knee, kneePower, resultAlc))
        render()
    }

    // ---- Rendering -----------------------------------------------------------
    /// Write a frame flicker-free: home, clear each line to EOL, wipe below.
    private func commit(_ body: String) {
        let framed = Terminal.home()
            + body.replacingOccurrences(of: "\r\n", with: "\u{001B}[K\r\n")
            + "\u{001B}[0J"
        Terminal.write(framed)
    }

    private func render() {
        if mode == .settings, let ed = settings {
            commit(renderSettings(ed))
            return
        }
        let (rows, cols) = Terminal.size()
        let width = max(40, cols)
        var out = ""

        // Status line.
        let utc = Self.utcStamp()
        let s = rigState
        let mhz = String(format: "%.3f", Double(s.frequencyHz) / 1_000_000)
        let tx = (s.transmitting || tuning) ? "\(Terminal.fg256(196))TX\(Terminal.reset)"
                                            : "\(Terminal.fg256(46))RX\(Terminal.reset)"
        let rigLine = s.connected ? "\(mhz) MHz \(s.mode.rawValue)  \(tx)" : "no rig"
        let station = config.isStationSet
            ? "\(Terminal.fg256(45))\(config.callsign)\(Terminal.reset) \(Terminal.dim)\(config.grid)\(Terminal.reset)"
            : "\(Terminal.fg256(208))set --call/--grid\(Terminal.reset)"
        out += Terminal.bold + Terminal.fg256(45) + " FT8-808 " + Terminal.reset
        out += Terminal.dim + " \(utc)  " + Terminal.reset
        out += rigLine + "  \(station)\r\n"

        // Global app controls at the top; QSO controls live with the QSO panel.
        out += " \(Terminal.bold)[Q]\(Terminal.reset)uit  \(Terminal.bold)[T]\(Terminal.reset)une  "
            + "\(Terminal.bold)[F]\(Terminal.reset)ind  \(Terminal.bold)[S]\(Terminal.reset)ettings\r\n"

        // FT8 15 s cycle progress bar.
        out += renderCycleBar(width: width) + "\r\n"
        out += rule(width)

        // Spectrum (8 rows tall) + TX frequency cursor row.
        out += renderSpectrum(height: 8, width: width)
        out += renderTxCursor(width: width) + "\r\n"
        out += rule(width)

        // Two columns: entire band (left, full height) | Rx frequency over the
        // QSO state panel (right). The right pane filters to decodes within ±tol
        // of the Rx/Tx audio frequency (WSJT-X's "Rx Frequency"), plus my own Tx
        // and to-me traffic; the state machine sits beneath it (WSJT-X layout).
        // Chrome rows: status, hints, cycle, rule, 8 spectrum, cursor, rule,
        // column header, footer rule, footer = 17.
        let height = max(3, rows - 17)
        let colW = max(18, (width - 3) / 2)
        let rxFreq = txOffsetHz
        let tol = Self.rxFilterTolHz

        out += Terminal.dim + cell(" dB   dt  freq  Band — entire passband", colW)
            + " │ " + cell("Rx \(Int(rxFreq)) Hz ±\(Int(tol))", colW) + Terminal.reset + "\r\n"

        // Left column reserves its last row for the band/navigation controls.
        let bandHeight = max(1, height - 1)

        // Band column (left): when nothing is selected, follow the newest
        // decodes. While selecting, FREEZE the window (so neither arrow presses
        // nor newly-arriving decodes shift the column) and scroll only when the
        // cursor would leave the view. `bandTop` persists across renders.
        let bandAll = activity.enumerated().filter { $0.element.message != nil }
        let n = bandAll.count
        if let sel = selectedIndex, let pos = bandAll.firstIndex(where: { $0.offset == sel }) {
            if pos < bandTop { bandTop = pos }                                  // cursor above window
            else if pos >= bandTop + bandHeight { bandTop = pos - bandHeight + 1 } // below window
            bandTop = max(0, min(bandTop, max(0, n - bandHeight)))
        } else {
            bandTop = max(0, n - bandHeight)                                    // follow newest
        }
        let band = Array(bandAll[bandTop..<min(n, bandTop + bandHeight)])
        let bandPad = bandHeight - band.count

        // Right column: Rx-frequency decodes on top, QSO state panel on the
        // bottom (separated by a thin rule). The panel always ends with the
        // QSO controls line, so its last row aligns with the left controls row.
        let panel = qsoPanel(width: colW)
        let rxTopRows = panel.isEmpty ? height : max(1, height - panel.count - 1)
        let atRx = Array(activity.filter { line in
            if line.mine { return true }
            if let m = line.message { return abs(m.frequencyHz - rxFreq) <= tol }
            return false
        }.suffix(rxTopRows))
        let rxPad = rxTopRows - atRx.count

        for row in 0..<height {
            // Left cell: band decodes, then the navigation controls on the last row.
            var left = "", leftHi = false
            if row == height - 1 {
                left = bandControls()
            } else {
                let bi = row - bandPad
                if bi >= 0 && bi < band.count {
                    leftHi = band[bi].offset == selectedIndex
                    left = leftHi ? band[bi].element.text : format(band[bi].element)
                }
            }
            // Right cell: decodes, then a separator, then the panel.
            var right = ""
            if row < rxTopRows {
                let qi = row - rxPad
                right = qi >= 0 ? format(atRx[qi]) : ""
            } else if row == rxTopRows && !panel.isEmpty {
                right = Terminal.dim + String(repeating: "─", count: colW) + Terminal.reset
            } else if !panel.isEmpty {
                let pi = row - rxTopRows - 1
                if pi < panel.count { right = panel[pi] }
            }
            out += cell(left, colW, highlight: leftHi)
                + "\(Terminal.dim) │ \(Terminal.reset)" + cell(right, colW) + "\r\n"
        }

        // Footer: tune banner, transient notice, or live status (no key hints —
        // those now live at the top).
        out += rule(width)
        if tuning {
            let amp = Self.amplitude(fromDb: txLevelDb)
            let label = autoTuning
                ? "\(Terminal.fg256(45))⟳ AUTO-TUNE\(Terminal.reset)"
                : "\(Terminal.fg256(196))● TUNE/TX\(Terminal.reset)"
            out += " \(Terminal.bold)\(label)\(Terminal.reset)  "
                + "drive \(dbBar(txLevelDb, width: 14)) "
                + String(format: "%+.0f dBFS ", txLevelDb)
                + "\(Terminal.dim)(amp \(String(format: "%.3f", amp)))\(Terminal.reset)  "
                + meterText()
                + "  \(Terminal.dim)[+/-] [A]uto [T]stop\(Terminal.reset)"
        } else if let notice, let at = noticeSetAt, Date().timeIntervalSince(at) < 8 {
            out += " \(Terminal.fg256(208))\(notice)\(Terminal.reset)"
        } else {
            let status = finished
                ? "\(Terminal.fg256(244))done — \(activity.count) decode(s) over \(slotCount) slot(s)\(Terminal.reset)"
                : "\(Terminal.dim)decoding…\(Terminal.reset)"
            out += " \(Terminal.dim)\(sourceLabel)\(Terminal.reset)  \(status)"
        }

        commit(out)
    }

    /// Fixed-width terminal cell: clip `s` to `width` VISIBLE columns (skipping
    /// ANSI escapes so colors don't count toward the width), close any open
    /// color, and pad with spaces to exactly `width`.
    private func cell(_ s: String, _ width: Int, highlight: Bool = false) -> String {
        var body = "", visible = 0
        var i = s.startIndex
        while i < s.endIndex && visible < width {
            let c = s[i]
            if c == "\u{1B}" {                       // copy the whole escape seq
                body.append(c)
                i = s.index(after: i)
                while i < s.endIndex {
                    let cj = s[i]; body.append(cj); i = s.index(after: i)
                    if cj.isLetter { break }
                }
            } else {
                body.append(c); visible += 1; i = s.index(after: i)
            }
        }
        if visible < width { body += String(repeating: " ", count: width - visible) }
        // Highlight wraps the full padded width (selected row is plain text).
        return highlight ? Terminal.reverse + body + Terminal.reset
                         : body + Terminal.reset
    }

    private func format(_ line: ActivityLine, selected: Bool = false) -> String {
        // Colour priority: my call (green) > worked-before (red) > CQ (yellow) > normal.
        let color: String
        if line.toMe { color = Terminal.fg256(46) }
        else if let dc = line.deCall, workedCalls.contains(dc) { color = Terminal.fg256(196) }
        else if line.cq { color = Terminal.fg256(220) }
        else { color = Terminal.fg256(252) }
        if selected {
            return "\(Terminal.bold)\(Terminal.fg256(45))▸\(Terminal.reset)\(color)\(line.text.dropFirst())\(Terminal.reset)"
        }
        // Decodes get a left-edge slot-parity marker (even=blue, odd=orange) so
        // the alternating even/odd sequence is visible down the band column. The
        // marker replaces the line's leading space, keeping column alignment.
        if let p = line.parity {
            let mark = p == .even ? "\(Terminal.fg256(33))▎\(Terminal.reset)"
                                  : "\(Terminal.fg256(208))▎\(Terminal.reset)"
            return "\(mark)\(color)\(line.text.dropFirst())\(Terminal.reset)"
        }
        return "\(color)\(line.text)\(Terminal.reset)"
    }

    private func logNote(_ s: String) {
        activity.append(ActivityLine(text: s, cq: false))
    }

    private func renderSpectrum(height: Int, width: Int) -> String {
        if tuning {
            var s = ""
            let mid = height / 2
            for row in 0..<height {
                if row == mid {
                    s += "  \(Terminal.fg256(196))▶ transmitting\(Terminal.reset) "
                        + "\(Terminal.dim)— receive paused\(Terminal.reset)\r\n"
                } else {
                    s += "\r\n"
                }
            }
            return s
        }
        guard !spectrum.isEmpty else {
            var s = ""
            for _ in 0..<height { s += Terminal.dim + "  (awaiting first slot…)".padding(toLength: min(width, 40), withPad: " ", startingAt: 0) + Terminal.reset + "\r\n" }
            return s
        }
        let cols = min(width, spectrum.count)
        var lines = ""
        for row in 0..<height {
            // Top row is the highest amplitude band.
            let threshold = Float(height - row) / Float(height)
            var line = ""
            for c in 0..<cols {
                let v = spectrum[c]
                if v >= threshold {
                    line += Terminal.fg256(heatColor(v)) + "█" + Terminal.reset
                } else if v >= threshold - (0.5 / Float(height)) {
                    line += Terminal.fg256(heatColor(v)) + "▄" + Terminal.reset
                } else {
                    line += " "
                }
            }
            lines += line + "\r\n"
        }
        return lines
    }

    /// Blue → cyan → green → yellow → red over [0,1] using xterm-256 cube.
    private func heatColor(_ v: Float) -> Int {
        let stops = [21, 39, 51, 46, 226, 208, 196]
        let idx = min(stops.count - 1, max(0, Int(v * Float(stops.count))))
        return stops[idx]
    }

    private func renderSettings(_ ed: SettingsEditor) -> String {
        if ed.rigPicking { return renderRigPicker(ed) }

        var out = Terminal.bold + Terminal.fg256(45) + " FT8-808 Settings" + Terminal.reset + "\r\n"
        out += rule(min(Terminal.size().cols, 60)) + "\r\n"

        for (i, field) in ed.fields.enumerated() {
            let selected = i == ed.selected
            let marker = selected ? "\(Terminal.fg256(45))▸\(Terminal.reset)" : " "
            let label = field.label.padding(toLength: 10, withPad: " ", startingAt: 0)

            let value: String
            if selected && ed.editing {
                value = "\(Terminal.fg256(231))\(ed.buffer)\(Terminal.fg256(201))▏\(Terminal.reset)"
            } else if selected {
                let v = ed.displayValue(at: i)
                if case .choice = field.kind {
                    value = "\(Terminal.fg256(231))‹ \(v) ›\(Terminal.reset)"
                } else {
                    value = "\(Terminal.fg256(231))\(v)\(Terminal.reset)"
                }
            } else {
                value = "\(Terminal.dim)\(ed.displayValue(at: i))\(Terminal.reset)"
            }
            out += "  \(marker) \(Terminal.dim)\(label)\(Terminal.reset)  \(value)\r\n"
        }

        // Detail line for the selected field (USB chip, transport, "likely rig"…).
        out += "\r\n"
        if let d = ed.detail() {
            out += "  \(Terminal.fg256(45))↳ \(d)\(Terminal.reset)\r\n"
        } else {
            out += "\r\n"
        }

        out += rule(min(Terminal.size().cols, 60)) + "\r\n"
        if ed.editing {
            out += " \(Terminal.dim)typing… \(Terminal.bold)[Enter]\(Terminal.reset)\(Terminal.dim) done\(Terminal.reset)"
        } else {
            out += " \(Terminal.bold)↑↓\(Terminal.reset) field  \(Terminal.bold)←→\(Terminal.reset) change  "
                + "\(Terminal.bold)[Enter]\(Terminal.reset) edit  "
                + "\(Terminal.bold)[S]\(Terminal.reset)ave  \(Terminal.bold)[Q]\(Terminal.reset) cancel"
        }
        return out
    }

    private func renderRigPicker(_ ed: SettingsEditor) -> String {
        let (rows, _) = Terminal.size()
        var out = Terminal.bold + Terminal.fg256(45) + " Select rig" + Terminal.reset
            + "  \(Terminal.dim)type to filter · ↑↓ select · Enter choose · Esc cancel\(Terminal.reset)\r\n"
        out += rule(min(Terminal.size().cols, 64)) + "\r\n"
        out += "  \(Terminal.dim)filter:\(Terminal.reset) \(Terminal.fg256(231))\(ed.rigQuery)\(Terminal.fg256(201))▏\(Terminal.reset)\r\n\r\n"

        let filtered = ed.filteredRigs
        if filtered.isEmpty {
            out += "  \(Terminal.dim)(no matching rigs)\(Terminal.reset)\r\n"
            return out
        }
        // Scrolling viewport around the selection.
        let visible = max(5, rows - 9)
        var start = max(0, ed.rigSelected - visible / 2)
        start = min(start, max(0, filtered.count - visible))
        let end = min(filtered.count, start + visible)
        for i in start..<end {
            let r = filtered[i]
            let sel = i == ed.rigSelected
            let marker = sel ? "\(Terminal.fg256(45))▸\(Terminal.reset)" : " "
            let color = sel ? Terminal.fg256(231) : Terminal.dim
            out += "  \(marker) \(color)\(r.displayName)\(Terminal.reset)"
                + "  \(Terminal.dim)[\(r.status)] #\(r.model)\(Terminal.reset)\r\n"
        }
        out += "\r\n  \(Terminal.dim)\(filtered.count) of \(SettingsEditor.rigs().count) rigs\(Terminal.reset)\r\n"
        return out
    }

    /// A `▲` marker aligned under the waterfall column for the TX audio offset.
    private func renderTxCursor(width: Int) -> String {
        let cols = min(width, spectrumCols)
        let span = passband.upperBound - passband.lowerBound
        let frac = (txOffsetHz - passband.lowerBound) / span
        let col = max(0, min(cols - 1, Int(frac * Float(cols))))
        let pre = String(repeating: " ", count: col)
        let post = String(repeating: " ", count: max(0, cols - col - 1))
        return pre + Terminal.fg256(201) + "▲" + Terminal.reset + post
            + "  " + Terminal.fg256(201) + "Rx/Tx \(Int(txOffsetHz)) Hz" + Terminal.reset
    }

    /// Bar for the drive level mapped over −60…0 dBFS.
    private func dbBar(_ db: Float, width: Int) -> String {
        let frac = max(0, min(1, (db + 60) / 60))
        let n = Int((frac * Float(width)).rounded())
        return Terminal.fg256(45) + "["
            + String(repeating: "█", count: n)
            + Terminal.dim + String(repeating: "·", count: max(0, width - n))
            + Terminal.reset + Terminal.fg256(45) + "]" + Terminal.reset
    }

    /// Safe Float→Int: never traps on NaN/inf/out-of-range (clamps).
    private func safeInt(_ v: Float, _ limit: Float = 99_999) -> Int {
        guard v.isFinite else { return 0 }
        return Int(Swift.max(-limit, Swift.min(limit, v)).rounded())
    }

    /// Live rig TX meters; ALC turns red once it deflects (the overdrive cue).
    private func meterText() -> String {
        guard let m = lastMeters else { return "\(Terminal.dim)meters n/a\(Terminal.reset)" }
        var parts: [String] = []
        if let w = m.powerWatts { parts.append("PWR \(safeInt(w))W") }
        else if let p = m.powerPercent { parts.append("PWR \(safeInt(p * 100))%") }
        if let set = m.powerSetPercent { parts.append("\(Terminal.dim)SET \(safeInt(set * 100))%\(Terminal.reset)") }
        if let a = m.alc, a.isFinite {
            let col = a > 0.05 ? Terminal.fg256(196) : Terminal.fg256(46)
            parts.append("\(col)ALC \(String(format: "%.2f", a))\(Terminal.reset)")
        }
        if let s = m.swr, s.isFinite { parts.append("SWR \(String(format: "%.1f", s))") }
        return parts.isEmpty ? "\(Terminal.dim)no meters\(Terminal.reset)" : parts.joined(separator: "  ")
    }

    private func rule(_ width: Int) -> String {
        Terminal.dim + String(repeating: "─", count: min(width, 200)) + Terminal.reset + "\r\n"
    }

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func utcStamp() -> String {
        utcFormatter.string(from: Date())
    }

    /// WSJT-X-style bar that fills over the current 15 s FT8 window (UTC-aligned).
    private func renderCycleBar(width: Int) -> String {
        let slot = 15.0
        let sec = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: slot)
        let barWidth = max(10, min(width - 24, 64))
        let filled = max(0, min(barWidth, Int((Double(barWidth) * sec / slot).rounded())))
        let color = tuning ? Terminal.fg256(196) : Terminal.fg256(46)
        let bar = color + String(repeating: "█", count: filled) + Terminal.reset
                + Terminal.dim + String(repeating: "·", count: barWidth - filled) + Terminal.reset
        // Current slot parity (even = :00/:30, odd = :15/:45), colour-matched to
        // the band-activity markers, plus our TX sequence when armed.
        let cur = SlotClock.parity(at: Date())
        let slotCol = cur == .even ? Terminal.fg256(33) : Terminal.fg256(208)
        let slotTxt = "\(slotCol)\(cur == .even ? "even" : "odd")\(Terminal.reset)"
        let txInfo = txEnabled
            ? "  \(Terminal.fg256(196))TX \(txParity == .even ? "even" : "odd")\(Terminal.reset)"
            : ""
        return " \(Terminal.dim)cycle\(Terminal.reset) \(bar) "
             + String(format: "%04.1f", sec) + "\(Terminal.dim)/15s\(Terminal.reset)  "
             + "\(Terminal.dim)slot\(Terminal.reset) \(slotTxt)\(txInfo)"
    }
}

// ---- Entry point -------------------------------------------------------------
//
//   ft8term <file.wav> [--ft4] [--rig <spec>]
//
// --rig specs:
//   dummy                         Hamlib software-simulated rig (bundled)
//   <model>[,<device>[,<baud>]]   any Hamlib model number, e.g.
//                                 3073,/dev/cu.usbserial-1410,38400  (Kenwood TS-590)
//   (omitted)                     mock rig (fixed 14.074 MHz USB)
func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      ft8term                       live receive (default)
      ft8term <file.wav>            decode a recording instead
      ft8term --list-audio          list audio devices (flags the rig codec)
      ft8term --list-serial         list serial ports (flags the rig CAT port)

      options (saved to ~/.config/ft8-808/config.json):
        --call <CALL>  --grid <GRID>     your station
        --rig <spec>                     dummy | name-or-model[,device[,baud]]
                                         e.g. ftdx101d,/dev/cu.usbserial-0,38400
        --audio <name>   --out <name>    capture / TX device (rig codec)
        --ft4 | --ft8                    protocol

    Configure once, then just run: ft8term

    In the live view:
      ←/→ or ,/.   move TX cursor (offset)      <  >   coarse
      F            auto-pick the quietest slice
      T            tune (key TX + tone; +/- set drive; A auto-tune)
      Q            quit

    """.utf8))
    exit(2)
}

func errExit(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
if args.contains("--help") || args.contains("-h") { usage() }

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// --list-audio: print all audio devices with detail and flag the likely rig.
if args.contains("--list-audio") {
    let devices = AudioDevices.allDevices()
        .sorted { ($0.likelyRig ? 0 : 1, $0.name) < ($1.likelyRig ? 0 : 1, $1.name) }
    if devices.isEmpty {
        print("No audio devices found.")
        exit(0)
    }
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    print("Audio devices:\n")
    for d in devices {
        let io = "\(d.inputChannels) in / \(d.outputChannels) out"
        var flag = ""
        if d.likelyRig {
            let dir = d.inputChannels > 0 ? "RX/capture" : "TX/output"
            flag = "   ← likely rig (\(dir))"
        }
        print("  \(pad(d.name, 26)) \(pad(d.transport, 10)) \(pad(io, 14)) \(d.manufacturer)\(flag)")
        print("  \(pad("", 26)) \(pad("uid:", 10)) \(d.uid)\n")
    }
    if let rig = devices.first(where: { $0.likelyRig }) {
        let name = rig.name.trimmingCharacters(in: .whitespaces)
        print("Your rig's codec looks like: \(rig.name)  (\(rig.manufacturer))")
        print("Many rigs show it twice — an RX (input) half and a TX (output) half,")
        print("same name. FT8-808 picks the right half per direction automatically, so:")
        print("\n  ft8term --audio \"\(name)\"\n")
    } else {
        print("Use:  ft8term --audio \"<name substring or uid>\"")
    }
    exit(0)
}

// --list-rigs: print all Hamlib-supported rigs (optionally filtered by a term).
if args.contains("--list-rigs") {
    let term = flagValue("--list-rigs")?.lowercased()
    let rigs = HamlibRigs.all().filter { rig in
        guard let term, !term.isEmpty else { return true }
        return rig.displayName.lowercased().contains(term)
    }
    print("Hamlib rigs (\(rigs.count)):\n")
    for r in rigs {
        print("  \(String(r.model))\t\(r.displayName)  [\(r.status)]")
    }
    exit(0)
}

// --tone [device]: play a 1.5 kHz test tone for 5 s — isolates the audio output
// path from rig/PTT/tune. No CAT, no keying.
if let i = args.firstIndex(of: "--tone") {
    let device: String? = (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? args[i + 1] : nil
    print("Playing 1500 Hz tone → \(device ?? "default output") for 5 s…")
    let tone = TxAudioOutput(frequencyHz: 1500, device: device)
    tone.amplitude = 0.2   // ~-14 dBFS, clearly audible on a speaker
    do {
        try tone.start()
    } catch {
        print("error: \(error)")
        exit(1)
    }
    try? await Task.sleep(nanoseconds: 5_000_000_000)
    tone.stop()
    print("done.")
    exit(0)
}

// --meter [device]: probe OUR capture path — chosen input device, its hardware
// format, and the live signal level — to see whether the app can capture (vs.
// the device working in other apps). Mirrors LiveAudioSource's device selection.
if let i = args.firstIndex(of: "--meter") {
    let arg: String? = (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? args[i + 1] : nil
    let query = arg ?? config.audioInput
    print("Input probe — query: \(query ?? "system default input")")

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: print("mic permission: authorized")
    case .notDetermined:
        print("mic permission: requesting…")
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        print("mic permission: \(ok ? "granted" : "DENIED")")
    case .denied, .restricted:
        print("mic permission: DENIED — enable your terminal under System Settings ▸ Privacy & Security ▸ Microphone")
    @unknown default: break
    }

    var deviceID: AudioDeviceID? = nil
    if let q = query {
        if let dev = AudioDevices.find(q, scope: .input) {
            print("selected device: \(dev.name)  id=\(dev.id)  inCh=\(dev.channels)")
            deviceID = dev.id
        } else {
            print("NO input device matched query \"\(q)\" — using system default")
        }
    } else {
        print("using system default input")
    }

    // Raw AUHAL capture at 12 kHz mono (the real receive path).
    let box = LevelBox()
    let cap = AudioCaptureUnit(deviceID: deviceID, sampleRate: 12_000) { samples in
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        box.update(peak: peak, rms: 0, frames: samples.count)
    }
    do { try cap.start() } catch { print("capture start FAILED: \(error)"); exit(1) }
    print("capturing 4 s via raw AUHAL (12 kHz mono) …")
    for _ in 0..<8 {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let s = box.snapshot()
        let pdb = s.peak > 0 ? 20 * log10(s.peak) : -120
        print(String(format: "  peak %6.1f dBFS   frames %d", pdb, s.frames))
    }
    cap.stop()
    print("done.")
    exit(0)
}

// --list-serial: print serial ports with USB identity, flag the likely CAT port.
if args.contains("--list-serial") {
    let ports = SerialPorts.list()
    if ports.isEmpty {
        print("No serial ports found.")
    } else {
        print("Serial ports:\n")
        for p in ports {
            let flag = p.likelyRig ? "   ← " : "      "
            print("  \(p.path)\n  \(flag)\(p.detail)\n")
        }
        if let rig = ports.first(where: { $0.likelyRig }) {
            print("Likely rig CAT port: \(rig.path)")
        }
    }
    exit(0)
}

// Load persisted config and fold in any CLI overrides (which then persist, so
// you can configure once with flags and just run `ft8term` afterwards).
var config = ConfigStore.load()
if let c = flagValue("--call")  { config.callsign = c.uppercased() }
if let g = flagValue("--grid")  { config.grid = g.uppercased() }
if let r = flagValue("--rig")   { config.rigSpec = r }
if let a = flagValue("--audio") { config.audioInput = a }
if let o = flagValue("--out")   { config.audioOutput = o }
if args.contains("--ft4") { config.proto = "ft4" } else if args.contains("--ft8") { config.proto = "ft8" }
try? ConfigStore.save(config)

let proto: FT8Protocol = config.proto == "ft4" ? .ft4 : .ft8

// Positional args = tokens that aren't flags or flag values.
let valueFlags: Set<String> = ["--rig", "--audio", "--out", "--call", "--grid"]
var positionals: [String] = []
do {
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            if valueFlags.contains(a) { i += 1 } // skip this flag's value
        } else {
            positionals.append(a)
        }
        i += 1
    }
}

// Resolve an audio device: use the configured one if it's actually present,
// otherwise auto-detect the rig's USB codec. So TX audio reaches the rig by
// default (not the Mac speakers), and a swapped rig is picked up automatically.
func rigCodec(scope: AudioDevices.Scope) -> String? {
    AudioDevices.devices(scope: scope).first {
        $0.transport == "USB" && !$0.manufacturer.lowercased().contains("apple")
    }?.name
}
func resolveAudio(_ configured: String?, scope: AudioDevices.Scope) -> String? {
    let devices = AudioDevices.devices(scope: scope)
    if let c = configured, devices.contains(where: { $0.name == c }) { return c }
    return rigCodec(scope: scope)
}
let audioDevice = resolveAudio(config.audioInput, scope: .input)
let outDevice = resolveAudio(config.audioOutput ?? config.audioInput, scope: .output)

// A WAV path argument decodes that recording; with no path we go live (default).
let source: any AudioSource
let sourceLabel: String
if let path = positionals.first {
    let wavURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: wavURL.path) else {
        errExit("file not found: \(wavURL.path)")
    }
    source = WavFileSource(url: wavURL)
    sourceLabel = wavURL.lastPathComponent
} else {
    source = LiveAudioSource(device: audioDevice)
    sourceLabel = "live: \(audioDevice ?? "default input")"
}

func makeRig(spec: String?) async -> (rig: RigController, warning: String?) {
    guard let spec else { return (MockRigController(), nil) }
    do {
        let rig = try RigSpec.controller(spec)
        try await rig.open()
        return (rig, nil)
    } catch {
        // Don't bail — start without CAT so the user can fix it in Settings.
        return (NullRigController(), "rig open failed (\(spec)) — press S to set the right port")
    }
}

// On Ctrl-C / kill: drop PTT first (never leave the rig keyed), then restore.
signal(SIGINT)  { _ in HamlibRigController.panicUnkey(); Terminal.restore(); exit(0) }
signal(SIGTERM) { _ in HamlibRigController.panicUnkey(); Terminal.restore(); exit(0) }
// On a crash (Swift trap, segfault…): un-key + restore the terminal so the
// shell isn't left in raw mode (the staircased-output mess), then re-raise to
// still get the backtrace.
for crashSig in [SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP] {
    signal(crashSig) { s in
        HamlibRigController.panicUnkey()
        Terminal.restore()
        signal(s, SIG_DFL)
        raise(s)
    }
}

let (rig, rigWarning) = await makeRig(spec: config.rigSpec)
Terminal.enableRawMode()
let app = App(source: source, label: sourceLabel, proto: proto, rig: rig,
              outDevice: outDevice, config: config, initialNotice: rigWarning)
await app.run()
Terminal.restore()

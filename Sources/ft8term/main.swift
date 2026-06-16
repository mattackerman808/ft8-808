import Foundation
import FT8Codec
import FT8808Engine
import HamlibRig
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// ft8term — terminal FT8 client. Milestone 1 increment: drive the engine from a
// recorded WAV and render a live status line, spectrum, and band-activity log.
//
//   swift run ft8term <file.wav> [--ft4]
//
// Live audio capture and rig/TX control arrive in later increments; the rig
// shown here is the MockRigController.

// ---- A line in the scrolling band-activity log (decode or note) --------------
struct ActivityLine {
    let text: String   // pre-formatted content
    let cq: Bool       // highlight CQ calls
}

@MainActor
final class App {
    let engine: DecodeEngine
    let source: any AudioSource
    let audioIO: AudioIO?   // non-nil in live mode; owns capture + TX tone
    let rig: RigController
    let sourceLabel: String
    let spectrumCols: Int

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
    private var tuning = false
    private var tuneBusy = false        // guards async start/stop transitions
    private var txLevelDb: Float = -40  // audio drive in dBFS (fine control)
    private var lastMeters: RigMeters?
    private var meterTask: Task<Void, Never>?
    private var notice: String?
    private var autoTuning = false

    // Settings panel.
    private enum Mode { case receive, settings }
    private var mode: Mode = .receive
    private var settings: SettingsEditor?

    private static func amplitude(fromDb db: Float) -> Float {
        db <= -90 ? 0 : pow(10, db / 20)
    }

    init(source: any AudioSource, label: String, proto: FT8Protocol, rig: RigController,
         config: StationConfig) {
        let (rows, cols) = Terminal.size()
        _ = rows
        let columns = max(20, cols - 2)
        self.engine = DecodeEngine(proto: proto, spectrumColumns: columns)
        self.spectrumCols = columns
        self.source = source
        self.audioIO = source as? AudioIO
        self.rig = rig
        self.sourceLabel = label
        self.config = config
        self.txOffsetHz = config.txOffsetHz
        self.txLevelDb = config.txDriveDb
    }

    private let interactive = isatty(STDIN_FILENO) == 1

    private var clockTask: Task<Void, Never>?

    func run() async {
        rigState = await rig.state()
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
        audioIO?.toneAmplitude = 0
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
        guard !tuning else { return }
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

        for m in r.messages.sorted(by: { $0.score > $1.score }) {
            let snr = String(format: "%+4.0f", m.snrDb)
            let dt = String(format: "%+4.1f", m.timeSeconds)
            let freq = String(format: "%4.0f", m.frequencyHz)
            activity.append(ActivityLine(text: " \(snr) \(dt) \(freq)  \(m.text)",
                                         cq: m.text.hasPrefix("CQ")))
        }
        render()
    }

    private func markFinished() {
        finished = true
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
                if byte == 0x1B { // ESC — possible arrow key (ESC [ A/B/C/D)
                    var b1: UInt8 = 0, b2: UInt8 = 0
                    if read(STDIN_FILENO, &b1, 1) == 1, b1 == 0x5B,
                       read(STDIN_FILENO, &b2, 1) == 1 {
                        let dir = b2
                        Task { @MainActor in self.handleArrow(dir) }
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
        default:
            break
        }
    }

    /// Arrow keys: ←/→ move the TX cursor (fine), ↑/↓ move it coarse.
    private func handleArrow(_ dir: UInt8) {
        if mode == .settings { settingsArrow(dir); return }
        switch dir {
        case 0x44: setTxOffset(txOffsetHz - 10)   // left
        case 0x43: setTxOffset(txOffsetHz + 10)   // right
        case 0x41: setTxOffset(txOffsetHz + 100)  // up
        case 0x42: setTxOffset(txOffsetHz - 100)  // down
        default: break
        }
    }

    // ---- Settings panel ------------------------------------------------------

    private func openSettings() {
        // Never enter settings while keyed — stop the tone and un-key first.
        if tuning { Task { await stopTune(); openSettingsNow() }; return }
        openSettingsNow()
    }

    private func openSettingsNow() {
        let serials = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") && ($0.contains("usb") || $0.contains("serial")) }
            .map { "/dev/\($0)" }.sorted()
        settings = SettingsEditor(
            config: config,
            serialPorts: serials,
            inputDevices: AudioDevices.inputDevices().map(\.name),
            outputDevices: AudioDevices.outputDevices().map(\.name))
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
        if ed.editing {
            switch c {
            case 13, 10: ed.commitEdit()
            case 127, 8: ed.backspace()
            case 32...126: ed.typeCharacter(Character(UnicodeScalar(c)))
            default: break
            }
            render(); return
        }
        switch c {
        case 13, 10: ed.activate()                     // Enter: edit text / cycle choice
        case UInt8(ascii: "s"): applySettings()        // s: save
        case UInt8(ascii: "q"): closeSettings()        // q: cancel
        default: break
        }
        render()
    }

    private func settingsArrow(_ dir: UInt8) {
        guard let ed = settings, !ed.editing else { return }
        switch dir {
        case 0x41: ed.moveSelection(-1)  // up
        case 0x42: ed.moveSelection(1)   // down
        case 0x44: ed.cycle(-1)          // left
        case 0x43: ed.cycle(1)           // right
        default: break
        }
        render()
    }

    /// Move the TX cursor, keeping room for the ~50 Hz signal inside the passband.
    private func setTxOffset(_ hz: Float) {
        let lo = passband.lowerBound
        let hi = passband.upperBound - 60
        txOffsetHz = (max(lo, min(hi, hz)) / 5).rounded() * 5   // snap to 5 Hz
        audioIO?.setToneFrequency(txOffsetHz)                   // follow live while tuning
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
        guard let audioIO else {
            notice = "tune needs live audio (run with --live)"
            render(); return
        }
        tuneBusy = true
        defer { tuneBusy = false }

        // Same engine for RX and TX — just raise the tone and key PTT.
        audioIO.setToneFrequency(txOffsetHz)
        audioIO.toneAmplitude = Self.amplitude(fromDb: txLevelDb)
        do {
            try await rig.setPTT(true)
        } catch {
            audioIO.toneAmplitude = 0
            notice = "tune failed: \(error)"
            render()
            return
        }
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
        audioIO?.toneAmplitude = 0      // mute the tone (engine keeps running for RX)
        try? await rig.setPTT(false)
        tuning = false
        rigState.transmitting = false
        render()
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
        audioIO?.toneAmplitude = Self.amplitude(fromDb: txLevelDb)
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
        let startDb: Float = -30   // power is already meaningful here; skip dead low end
        let maxDb: Float = -13
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

        // FT8 15 s cycle progress bar.
        out += renderCycleBar(width: width) + "\r\n"
        out += rule(width)

        // Spectrum (8 rows tall) + TX frequency cursor row.
        out += renderSpectrum(height: 8, width: width)
        out += renderTxCursor(width: width) + "\r\n"
        out += rule(width)

        // Band-activity header + log.
        out += Terminal.dim + "  dB   dt   freq  message" + Terminal.reset + "\r\n"
        let headerRows = 5 // status, cycle bar, rules
        let spectrumRows = 9 // 8 spectrum + TX cursor row
        let footerRows = 2
        let logCapacity = max(3, rows - (headerRows + spectrumRows + footerRows + 2))
        let shown = activity.suffix(logCapacity)
        for line in shown {
            out += format(line) + "\r\n"
        }
        // Pad to push footer down.
        for _ in 0..<max(0, logCapacity - shown.count) { out += "\r\n" }

        // Footer.
        out += rule(width)
        if tuning {
            // Prominent TX banner: drive level (dB) + live rig meters.
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
        } else if let notice {
            out += " \(Terminal.fg256(208))\(notice)\(Terminal.reset)"
        } else {
            let status = finished
                ? "\(Terminal.fg256(244))done — \(activity.count) decode(s) over \(slotCount) slot(s)\(Terminal.reset)"
                : "\(Terminal.dim)decoding…\(Terminal.reset)"
            out += " \(Terminal.bold)[Q]\(Terminal.reset)uit  \(Terminal.bold)[T]\(Terminal.reset)une  "
                + "\(Terminal.bold)←/→\(Terminal.reset) TX  \(Terminal.bold)[F]\(Terminal.reset)ind  "
                + "\(Terminal.bold)[S]\(Terminal.reset)ettings  "
                + "\(Terminal.dim)\(sourceLabel)\(Terminal.reset)  \(status)"
        }

        commit(out)
    }

    private func format(_ line: ActivityLine) -> String {
        let color = line.cq ? Terminal.fg256(220) : Terminal.fg256(252)
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
                // Hint the choice arrows for choice fields.
                let v = ed.values[i]
                if case .choice = field.kind {
                    value = "\(Terminal.fg256(231))‹ \(v) ›\(Terminal.reset)"
                } else {
                    value = "\(Terminal.fg256(231))\(v)\(Terminal.reset)"
                }
            } else {
                value = "\(Terminal.dim)\(ed.values[i])\(Terminal.reset)"
            }
            out += "  \(marker) \(Terminal.dim)\(label)\(Terminal.reset)  \(value)\r\n"
        }

        out += "\r\n" + rule(min(Terminal.size().cols, 60)) + "\r\n"
        if ed.editing {
            out += " \(Terminal.dim)typing… \(Terminal.bold)[Enter]\(Terminal.reset)\(Terminal.dim) done\(Terminal.reset)"
        } else {
            out += " \(Terminal.bold)↑↓\(Terminal.reset) field  \(Terminal.bold)←→\(Terminal.reset) change  "
                + "\(Terminal.bold)[Enter]\(Terminal.reset) edit  "
                + "\(Terminal.bold)[S]\(Terminal.reset)ave  \(Terminal.bold)[Q]\(Terminal.reset) cancel"
        }
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
            + "  " + Terminal.fg256(201) + "TX \(Int(txOffsetHz)) Hz" + Terminal.reset
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

    /// Live rig TX meters; ALC turns red once it deflects (the overdrive cue).
    private func meterText() -> String {
        guard let m = lastMeters else { return "\(Terminal.dim)meters n/a\(Terminal.reset)" }
        var parts: [String] = []
        if let w = m.powerWatts { parts.append("PWR \(Int(w.rounded()))W") }
        else if let p = m.powerPercent { parts.append("PWR \(Int((p * 100).rounded()))%") }
        if let set = m.powerSetPercent { parts.append("\(Terminal.dim)SET \(Int((set * 100).rounded()))%\(Terminal.reset)") }
        if let a = m.alc {
            let col = a > 0.05 ? Terminal.fg256(196) : Terminal.fg256(46)
            parts.append("\(col)ALC \(String(format: "%.2f", a))\(Terminal.reset)")
        }
        if let s = m.swr { parts.append("SWR \(String(format: "%.1f", s))") }
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
        let label = tuning ? "TX" : "RX"
        return " \(Terminal.dim)cycle\(Terminal.reset) \(bar) "
             + String(format: "%04.1f", sec) + "\(Terminal.dim)/15s\(Terminal.reset)  "
             + "\(color)\(label)\(Terminal.reset)"
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
      ft8term <file.wav> [--ft4] [--rig <spec>]      decode a recording
      ft8term --live [--audio <name>] [--ft4] [--rig <spec>] [--out <name>]   live receive
      ft8term --list-audio                           list input devices

      <spec> = dummy | name-or-model[,device[,baud]]   (e.g. ftdx101d,/dev/cu...,38400)
      --out  output device for Tune (defaults to the --audio device)
      --call <CALL>  --grid <GRID>   set your station (persisted)

    Flags are saved to ~/.config/ft8-808/config.json, so once set you can just
    run: ft8term --live

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
guard args.count >= 2 else { usage() }

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// --list-audio: print input devices and exit (no terminal takeover).
if args.contains("--list-audio") {
    let devices = AudioDevices.inputDevices()
    let defID = AudioDevices.defaultInputDeviceID()
    if devices.isEmpty {
        print("No audio input devices found.")
    } else {
        print("Audio input devices:")
        for d in devices {
            let star = (d.id == defID) ? " (default)" : ""
            print("  \(d.name)  [\(d.channels) ch]\(star)\n    uid: \(d.uid)")
        }
        print("\nUse: ft8term --live --audio \"<name substring or uid>\"")
    }
    exit(0)
}

// Load persisted config and fold in any CLI overrides (which then persist, so
// you can configure once with flags and just `ft8term --live` afterwards).
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

let audioDevice = config.audioInput
// Tune output: explicit --out, else the same codec we capture from (the rig).
let outDevice = config.audioOutput ?? config.audioInput

// Decide the audio source: --live (capture) or a WAV path.
let live = args.contains("--live")
let source: any AudioSource
let sourceLabel: String
if live {
    source = AudioIO(captureDevice: audioDevice, playbackDevice: outDevice,
                     toneFrequencyHz: config.txOffsetHz)
    sourceLabel = "live: \(audioDevice ?? "default input")"
} else {
    guard let path = positionals.first else { usage() }
    let wavURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: wavURL.path) else {
        errExit("file not found: \(wavURL.path)")
    }
    source = WavFileSource(url: wavURL)
    sourceLabel = wavURL.lastPathComponent
}

func makeRig(spec: String?) async -> RigController {
    guard let spec else { return MockRigController() }
    do {
        let rig = try RigSpec.controller(spec)
        try await rig.open()
        return rig
    } catch {
        errExit("\(error)")
    }
}

// On Ctrl-C / kill: drop PTT first (never leave the rig keyed), then restore.
signal(SIGINT)  { _ in HamlibRigController.panicUnkey(); Terminal.restore(); exit(0) }
signal(SIGTERM) { _ in HamlibRigController.panicUnkey(); Terminal.restore(); exit(0) }

let rig = await makeRig(spec: config.rigSpec)
Terminal.enableRawMode()
let app = App(source: source, label: sourceLabel, proto: proto, rig: rig,
              config: config)
await app.run()
Terminal.restore()

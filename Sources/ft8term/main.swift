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

// ---- A decoded line for the scrolling band-activity log ----------------------
struct ActivityLine {
    let slot: Int
    let message: FT8Message
}

@MainActor
final class App {
    let engine: DecodeEngine
    let source: any AudioSource
    let rig: RigController
    let sourceLabel: String
    let outDevice: String?
    let spectrumCols: Int

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
    private var notice: String?
    private var autoTuning = false

    private static func amplitude(fromDb db: Float) -> Float {
        db <= -90 ? 0 : pow(10, db / 20)
    }

    init(source: any AudioSource, label: String, proto: FT8Protocol, rig: RigController,
         outDevice: String?, txOffsetHz: Float = 1500) {
        let (rows, cols) = Terminal.size()
        _ = rows
        let columns = max(20, cols - 2)
        self.engine = DecodeEngine(proto: proto, spectrumColumns: columns)
        self.spectrumCols = columns
        self.source = source
        self.rig = rig
        self.sourceLabel = label
        self.outDevice = outDevice
        self.txOffsetHz = txOffsetHz
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
        tx?.stop(); tx = nil
        if tuning { try? await rig.setPTT(false); tuning = false }
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
            activity.append(ActivityLine(slot: r.index, message: m))
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
                if c == UInt8(ascii: "q") || c == 3 { return } // q or Ctrl-C
            }
            // EOF / closed stdin (e.g. piped or non-interactive): quit cleanly.
            Task { @MainActor in self.handleKey(UInt8(ascii: "q")) }
        }
        thread.stackSize = 1 << 16
        thread.start()
    }

    private func handleKey(_ c: UInt8) {
        switch c {
        case UInt8(ascii: "q"), 3:
            quit?.resume(); quit = nil
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
        switch dir {
        case 0x44: setTxOffset(txOffsetHz - 10)   // left
        case 0x43: setTxOffset(txOffsetHz + 10)   // right
        case 0x41: setTxOffset(txOffsetHz + 100)  // up
        case 0x42: setTxOffset(txOffsetHz - 100)  // down
        default: break
        }
    }

    /// Move the TX cursor, keeping room for the ~50 Hz signal inside the passband.
    private func setTxOffset(_ hz: Float) {
        let lo = passband.lowerBound
        let hi = passband.upperBound - 60
        txOffsetHz = (max(lo, min(hi, hz)) / 5).rounded() * 5   // snap to 5 Hz
        tx?.setFrequency(txOffsetHz)                            // follow live while tuning
        render()
    }

    /// Auto-pick the quietest ~50 Hz slice for transmitting, using the busy map.
    private func autoPickTxFrequency() {
        let spec = avgSpectrum.isEmpty ? spectrum : avgSpectrum
        guard spec.count > 4 else { notice = "no spectrum yet — wait for a slot"; render(); return }

        let cols = spec.count
        let span = passband.upperBound - passband.lowerBound
        let win = max(1, Int((50.0 / span) * Float(cols)))      // ~50 Hz in columns

        // Prefix sums → fast sliding-window energy.
        var prefix = [Float](repeating: 0, count: cols + 1)
        for i in 0..<cols { prefix[i + 1] = prefix[i] + spec[i] }

        var bestStart = 0
        var bestEnergy = Float.greatestFiniteMagnitude
        for start in 0...(cols - win) {
            let e = prefix[start + win] - prefix[start]
            if e < bestEnergy { bestEnergy = e; bestStart = start }
        }
        let centerCol = Float(bestStart) + Float(win) / 2
        let hz = passband.lowerBound + (centerCol / Float(cols)) * span
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
        tuneBusy = true
        defer { tuneBusy = false }

        let out = TxAudioOutput(frequencyHz: txOffsetHz, device: outDevice)
        out.amplitude = Self.amplitude(fromDb: txLevelDb)
        do {
            try out.start()
            try await rig.setPTT(true)
        } catch {
            out.stop()
            try? await rig.setPTT(false)
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

        let startDb: Float = -45
        let maxDb: Float = -10   // backstop; ALC onset / power plateau normally stop us first
        let alcClean: Float = 0.05  // ALC at/below this = essentially no ALC action
        var samples: [(db: Float, power: Float, alc: Float)] = []
        var maxPower: Float = 0
        var flat = 0
        var db = startDb

        while db <= maxDb {
            if !tuning || Task.isCancelled { break }
            setLevelDb(db)
            try? await Task.sleep(nanoseconds: 280_000_000) // let the rig settle
            let m = await rig.meters()
            lastMeters = m
            let p = power(m)
            let alc = m?.alc ?? 0
            samples.append((db, p, alc))
            notice = String(format: "auto-tune: %+.0f dBFS  %.0f W  ALC %.2f", db, p, alc)
            render()

            if p > maxPower + max(0.5, maxPower * 0.02) {
                maxPower = p
                flat = 0
            } else {
                flat += 1
            }
            // Stop once ALC is clearly deflecting and power has stopped climbing,
            // or power plateaus with meaningful output (guards the dead low end).
            if alc > 0.15 && flat >= 1 { break }
            if flat >= 3 && maxPower > 5 { break }
            db += 1
        }

        // Prefer the CLEAN knee: the highest drive that keeps ALC near zero (best
        // for FT8). Fall back to the lowest drive reaching ~97% of peak if ALC
        // never deflected.
        let knee: Float
        let resultAlc: Float
        if let clean = samples.filter({ $0.alc <= alcClean && $0.power > maxPower * 0.5 })
                              .max(by: { $0.db < $1.db }) {
            knee = clean.db
            resultAlc = clean.alc
        } else {
            let target = maxPower * 0.97
            let pick = samples.first(where: { $0.power >= target }) ?? samples.max(by: { $0.power < $1.power })
            knee = pick?.db ?? txLevelDb
            resultAlc = pick?.alc ?? 0
        }

        setLevelDb(knee)
        try? await Task.sleep(nanoseconds: 300_000_000)
        lastMeters = await rig.meters()
        let finalPower = power(lastMeters)

        // Calibration done — stop transmitting. The drive level (txLevelDb) is
        // kept for the next tune / transmit.
        await stopTune()
        notice = String(format: "auto-tune → %+.0f dBFS  ≈%.0f W  ALC %.2f  (TX off)",
                        knee, finalPower, resultAlc)
        render()
    }

    // ---- Rendering -----------------------------------------------------------
    private func render() {
        let (rows, cols) = Terminal.size()
        let width = max(40, cols)
        var out = Terminal.home()

        // Status line.
        let utc = Self.utcStamp()
        let s = rigState
        let mhz = String(format: "%.3f", Double(s.frequencyHz) / 1_000_000)
        let tx = (s.transmitting || tuning) ? "\(Terminal.fg256(196))TX\(Terminal.reset)"
                                            : "\(Terminal.fg256(46))RX\(Terminal.reset)"
        let rigLine = s.connected ? "\(mhz) MHz \(s.mode.rawValue)  \(tx)" : "no rig"
        out += Terminal.bold + Terminal.fg256(45) + " FT8-808 " + Terminal.reset
        out += Terminal.dim + " \(utc)  " + Terminal.reset
        out += rigLine + "\r\n"

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
                + "\(Terminal.dim)\(sourceLabel)\(Terminal.reset)  \(status)"
        }

        // Smooth redraw: clear each line to EOL and wipe below, rather than a
        // full-screen clear — avoids flicker at the cycle bar's refresh rate.
        out = out.replacingOccurrences(of: "\r\n", with: "\u{001B}[K\r\n") + "\u{001B}[0J"
        Terminal.write(out)
    }

    private func format(_ line: ActivityLine) -> String {
        let m = line.message
        let snr = String(format: "%+4.0f", m.snrDb)
        let dt = String(format: "%+4.1f", m.timeSeconds)
        let freq = String(format: "%4.0f", m.frequencyHz)
        let color = m.text.hasPrefix("CQ") ? Terminal.fg256(220) : Terminal.fg256(252)
        return " \(snr) \(dt) \(freq)  \(color)\(m.text)\(Terminal.reset)"
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

let proto: FT8Protocol = args.contains("--ft4") ? .ft4 : .ft8

// Positional args = tokens that aren't flags or flag values.
let valueFlags: Set<String> = ["--rig", "--audio", "--out", "--tune-freq"]
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

let audioDevice = flagValue("--audio")
// Tune output: explicit --out, else the same codec we capture from (the rig).
let outDevice = flagValue("--out") ?? audioDevice
let tuneFreq = Float(flagValue("--tune-freq") ?? "") ?? 1500

// Decide the audio source: --live (capture) or a WAV path.
let live = args.contains("--live")
let source: any AudioSource
let sourceLabel: String
if live {
    source = LiveAudioSource(device: audioDevice)
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

func makeRig() async -> RigController {
    guard let i = args.firstIndex(of: "--rig"), i + 1 < args.count else {
        return MockRigController()
    }
    do {
        let rig = try RigSpec.controller(args[i + 1])
        try await rig.open()
        return rig
    } catch {
        errExit("\(error)")
    }
}

// On Ctrl-C / kill: drop PTT first (never leave the rig keyed), then restore.
signal(SIGINT)  { _ in HamlibRigController.panicUnkey(); Terminal.restore(); exit(0) }
signal(SIGTERM) { _ in HamlibRigController.panicUnkey(); Terminal.restore(); exit(0) }

let rig = await makeRig()
Terminal.enableRawMode()
let app = App(source: source, label: sourceLabel, proto: proto, rig: rig,
              outDevice: outDevice, txOffsetHz: tuneFreq)
await app.run()
Terminal.restore()

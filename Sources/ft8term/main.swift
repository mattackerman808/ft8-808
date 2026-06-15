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
    let tuneFreq: Float

    private var spectrum: [Float] = []
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
    private var txLevel: Float = 0.05
    private var notice: String?

    init(source: any AudioSource, label: String, proto: FT8Protocol, rig: RigController,
         outDevice: String?, tuneFreq: Float = 1500) {
        let (rows, cols) = Terminal.size()
        _ = rows
        self.engine = DecodeEngine(proto: proto, spectrumColumns: max(20, cols - 2))
        self.source = source
        self.rig = rig
        self.sourceLabel = label
        self.outDevice = outDevice
        self.tuneFreq = tuneFreq
    }

    private let interactive = isatty(STDIN_FILENO) == 1

    func run() async {
        rigState = await rig.state()
        if interactive { startKeyReader(); startRigPoll() }
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
        tx?.stop(); tx = nil
        if tuning { try? await rig.setPTT(false); tuning = false }
        consume.cancel()
    }

    private func apply(_ r: SlotResult) {
        slotCount += 1
        spectrum = r.spectrum
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
            if tuning { setLevel(txLevel + 0.02) }
        case UInt8(ascii: "-"), UInt8(ascii: "_"):
            if tuning { setLevel(txLevel - 0.02) }
        default:
            break
        }
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

        let out = TxAudioOutput(frequencyHz: tuneFreq, device: outDevice)
        out.amplitude = txLevel
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
        render()
    }

    private func stopTune() async {
        guard tuning, !tuneBusy else { return }
        tuneBusy = true
        defer { tuneBusy = false }

        tx?.stop()
        tx = nil
        try? await rig.setPTT(false)
        tuning = false
        rigState.transmitting = false
        render()
    }

    private func setLevel(_ v: Float) {
        txLevel = max(0, min(1, v))
        tx?.amplitude = txLevel
        render()
    }

    // ---- Rendering -----------------------------------------------------------
    private func render() {
        let (rows, cols) = Terminal.size()
        let width = max(40, cols)
        var out = Terminal.clear

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
        out += rule(width)

        // Spectrum (8 rows tall).
        out += renderSpectrum(height: 8, width: width)
        out += rule(width)

        // Band-activity header + log.
        out += Terminal.dim + "  dB   dt   freq  message" + Terminal.reset + "\r\n"
        let headerRows = 4 // status, rule, rule already counted approx
        let spectrumRows = 8
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
            // Prominent TX banner with the live drive-level bar.
            let bar = txLevelBar(txLevel, width: min(width - 30, 30))
            out += " \(Terminal.bold)\(Terminal.fg256(196))● TUNE / TX\(Terminal.reset)  "
                + "drive \(bar)  "
                + "\(Terminal.dim)[+/-] level   [T] stop\(Terminal.reset)"
        } else if let notice {
            out += " \(Terminal.fg256(208))\(notice)\(Terminal.reset)"
        } else {
            let status = finished
                ? "\(Terminal.fg256(244))done — \(activity.count) decode(s) over \(slotCount) slot(s)\(Terminal.reset)"
                : "\(Terminal.dim)decoding…\(Terminal.reset)"
            out += " \(Terminal.bold)[Q]\(Terminal.reset)uit  \(Terminal.bold)[T]\(Terminal.reset)une  "
                + "\(Terminal.dim)\(sourceLabel)\(Terminal.reset)   \(status)"
        }

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

    private func txLevelBar(_ v: Float, width: Int) -> String {
        let n = Int((v * Float(width)).rounded())
        let filled = String(repeating: "█", count: max(0, min(width, n)))
        let empty = String(repeating: "·", count: max(0, width - n))
        return "\(Terminal.fg256(196))\(filled)\(Terminal.dim)\(empty)\(Terminal.reset) "
            + String(format: "%.2f", v)
    }

    private func rule(_ width: Int) -> String {
        Terminal.dim + String(repeating: "─", count: min(width, 200)) + Terminal.reset + "\r\n"
    }

    private static func utcStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
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

    In the live view: [T] tune (key TX + steady tone, +/- to set drive), [Q] quit.

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
              outDevice: outDevice, tuneFreq: tuneFreq)
await app.run()
Terminal.restore()

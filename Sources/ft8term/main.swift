import Foundation
import FT8Codec
import FT8808Engine
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
    let source: WavFileSource
    let rig: RigController
    let fileName: String

    private var spectrum: [Float] = []
    private var activity: [ActivityLine] = []
    private var slotCount = 0
    private var finished = false
    private var quit: CheckedContinuation<Void, Never>?
    private var rigState = RigState(frequencyHz: 14_074_000, mode: .usb,
                                    transmitting: false, connected: true)

    init(wavURL: URL, proto: FT8Protocol) {
        let (rows, cols) = Terminal.size()
        _ = rows
        self.engine = DecodeEngine(proto: proto, spectrumColumns: max(20, cols - 2))
        self.source = WavFileSource(url: wavURL)
        self.rig = MockRigController()
        self.fileName = wavURL.lastPathComponent
    }

    private let interactive = isatty(STDIN_FILENO) == 1

    func run() async {
        rigState = await rig.state()
        if interactive { startKeyReader() }
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
        default:
            break
        }
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
        let tx = s.transmitting ? "\(Terminal.fg256(196))TX\(Terminal.reset)"
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
        let status = finished
            ? "\(Terminal.fg256(244))done — \(activity.count) decode(s) over \(slotCount) slot(s)\(Terminal.reset)"
            : "\(Terminal.dim)decoding…\(Terminal.reset)"
        out += " \(Terminal.bold)[Q]\(Terminal.reset)uit   \(Terminal.dim)\(fileName)\(Terminal.reset)   \(status)"

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
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ft8term <file.wav> [--ft4]\n".utf8))
    exit(2)
}
let wavURL = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: wavURL.path) else {
    FileHandle.standardError.write(Data("error: file not found: \(wavURL.path)\n".utf8))
    exit(1)
}
let proto: FT8Protocol = args.contains("--ft4") ? .ft4 : .ft8

// Restore the terminal on Ctrl-C even if we're mid-render.
signal(SIGINT) { _ in
    Terminal.restore()
    exit(0)
}

Terminal.enableRawMode()
let app = App(wavURL: wavURL, proto: proto)
await app.run()
Terminal.restore()

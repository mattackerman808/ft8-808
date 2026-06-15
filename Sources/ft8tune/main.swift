import Foundation
import FT8808Engine
import HamlibRig
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// ft8tune — transmit-audio calibration, like WSJT-X "Tune".
//
// Keys the rig and plays a steady tone to its audio input (USB codec). You raise
// the level until the rig shows full rated RF power with NO ALC deflection — the
// correct drive for clean FT8. Use a dummy load. Ctrl-C un-keys immediately.

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(code)
}

func usage() -> Never {
    die("""
    ft8tune — transmit-audio calibration (steady tone, like WSJT-X Tune)

    usage:
      ft8tune list                                   list audio OUTPUT devices
      ft8tune --rig <spec> [--out <device>] [--freq <hz>] [--start <level>]

      <spec>   = dummy | name-or-model[,device[,baud]]
                 e.g. ftdx101d,/dev/cu.usbserial-00943F8D0,38400
      <device> = output device name substring or UID (e.g. "USB AUDIO")
      --freq   tone frequency in Hz (default 1500)
      --start  initial level 0.0–1.0 (default 0.05 — start LOW)
    """, 2)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

if args[1] == "list" {
    let outs = AudioDevices.outputDevices()
    if outs.isEmpty {
        print("No audio output devices found.")
    } else {
        print("Audio output devices:")
        for d in outs { print("  \(d.name)  [\(d.channels) ch]\n    uid: \(d.uid)") }
    }
    exit(0)
}

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let rigSpec = flagValue("--rig") else { die("error: --rig <spec> is required") }
let outDevice = flagValue("--out")
let freq = Float(flagValue("--freq") ?? "") ?? 1500
var level = max(0, min(1, Float(flagValue("--start") ?? "") ?? 0.05))

// Build + open the rig.
let rig: HamlibRigController
do { rig = try RigSpec.controller(rigSpec) } catch { die("error: \(error)") }
do {
    try await rig.open()
} catch {
    die("error: \(error)\nhint: quit other rig software — /dev/cu.* ports aren't exclusive.")
}

// Emergency un-key: if anything kills us mid-transmit, drop PTT first.
signal(SIGINT)  { _ in HamlibRigController.panicUnkey(); _exit(1) }
signal(SIGTERM) { _ in HamlibRigController.panicUnkey(); _exit(1) }

let tx = TxAudioOutput(frequencyHz: freq, device: outDevice)
tx.amplitude = level

func bar(_ v: Float) -> String {
    let n = Int((v * 20).rounded())
    return "[" + String(repeating: "█", count: n) + String(repeating: "·", count: 20 - n)
        + "] " + String(format: "%.2f", v)
}

func shutdown() async {
    tx.stop()
    try? await rig.setPTT(false)
    await rig.close()
}

print("""

  FT8-808 tune — \(Int(freq)) Hz → \(outDevice ?? "default output device")
  ┌─────────────────────────────────────────────────────────────┐
  │  ⚠  THIS KEYS YOUR TRANSMITTER.  Use a dummy load.            │
  │  Raise the level until the rig hits full power with NO ALC.   │
  └─────────────────────────────────────────────────────────────┘
  commands:  +  louder   -  softer   <0–1>  set level   q  stop & un-key

""")

do {
    try tx.start()
    try await rig.setPTT(true)
} catch {
    await shutdown()
    die("error: \(error)")
}

print("  keyed.  \(bar(level))")
loop: while true {
    FileHandle.standardOutput.write(Data("  level> ".utf8))
    guard let line = readLine(strippingNewline: true) else { break } // EOF (e.g. Ctrl-D)
    switch line.trimmingCharacters(in: .whitespaces) {
    case "q", "quit", "stop": break loop
    case "+": level = min(1, level + 0.02)
    case "-": level = max(0, level - 0.02)
    case "": continue
    case let s:
        guard let v = Float(s) else { print("  ? use +, -, a number 0–1, or q"); continue }
        level = max(0, min(1, v))
    }
    tx.amplitude = level
    print("          \(bar(level))")
}

await shutdown()
print("  un-keyed.  final level: \(String(format: "%.2f", level))")

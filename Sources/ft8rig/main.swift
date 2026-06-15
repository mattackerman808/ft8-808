import Foundation
import FT8808Engine
import HamlibRig

// ft8rig — rig-control diagnostics for FT8-808 (dogfoods HamlibRigController).
//
//   ft8rig ports                          list candidate serial ports
//   ft8rig probe   --rig <spec>           READ-ONLY: open, print freq/mode/PTT
//   ft8rig setfreq --rig <spec> <hz>      set VFO frequency (no RF)
//   ft8rig setmode --rig <spec> <mode>    set mode: usb|lsb|cw|data (no RF)
//   ft8rig ptt     --rig <spec> on|off    *** KEYS THE TRANSMITTER ***
//
// <spec> = dummy | <name-or-model>[,<device>[,<baud>]]
//   e.g.  ftdx101d,/dev/cu.usbserial-00943F8D0,38400
//         1040,/dev/cu.usbserial-00943F8D0,38400

// A few named models for convenience (Hamlib model numbers).
let rigAliases: [String: Int] = [
    "dummy": HamlibModel.dummy,
    "netrigctl": HamlibModel.netRigctl,
    "ftdx101d": 1040,
    "ftdx101mp": 1044,
]

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    die("""
    usage:
      ft8rig ports
      ft8rig probe   --rig <spec>
      ft8rig setfreq --rig <spec> <hz>
      ft8rig setmode --rig <spec> <usb|lsb|cw|data>
      ft8rig ptt     --rig <spec> <on|off>   (keys TX — use a dummy load!)

      <spec> = dummy | <name-or-model>[,<device>[,<baud>]]
      known names: \(rigAliases.keys.sorted().joined(separator: ", "))
    """, code: 2)
}

func parseRigSpec(_ args: [String]) -> HamlibRigController {
    guard let i = args.firstIndex(of: "--rig"), i + 1 < args.count else {
        die("error: --rig <spec> is required")
    }
    let parts = args[i + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    let key = parts[0].lowercased()
    let model: Int
    if let m = rigAliases[key] { model = m }
    else if let m = Int(parts[0]) { model = m }
    else { die("error: unknown rig '\(parts[0])'") }
    let device = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
    let baud = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
    return HamlibRigController(model: model, device: device, serialSpeed: baud)
}

func listPorts() {
    let cu = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
    let ports = cu.filter { $0.hasPrefix("cu.") && ($0.contains("usb") || $0.contains("serial")) }.sorted()
    if ports.isEmpty {
        print("No USB serial ports found.")
    } else {
        print("Candidate serial ports:")
        for p in ports { print("  /dev/\(p)") }
    }
}

func openOrDie(_ rig: HamlibRigController) async {
    do {
        try await rig.open()
    } catch {
        die("""
        error: \(error)
        hint: is another app (WSJT-X, etc.) holding the serial port? Serial ports
              are exclusive — close other rig-control software and retry.
        """)
    }
}

func formatState(_ s: RigState) -> String {
    let mhz = String(format: "%.6f", Double(s.frequencyHz) / 1_000_000)
    return "freq=\(mhz) MHz  mode=\(s.mode.rawValue)  ptt=\(s.transmitting ? "ON (TX)" : "off")  connected=\(s.connected)"
}

// ---- Dispatch ----------------------------------------------------------------
let args = CommandLine.arguments
guard args.count >= 2 else { usage() }
let command = args[1]

switch command {
case "ports":
    listPorts()

case "probe":
    let rig = parseRigSpec(args)
    await openOrDie(rig)
    let s = await rig.state()
    print(formatState(s))
    await rig.close()

case "setfreq":
    let rig = parseRigSpec(args)
    guard let hz = args.last.flatMap({ Int($0) }) else { die("error: setfreq needs <hz>") }
    await openOrDie(rig)
    do {
        try await rig.setFrequency(hz)
        print("set freq -> \(formatState(await rig.state()))")
    } catch { die("error: \(error)") }
    await rig.close()

case "setmode":
    let rig = parseRigSpec(args)
    let modeMap: [String: RigMode] = ["usb": .usb, "lsb": .lsb, "cw": .cw, "data": .data]
    guard let mode = args.last.flatMap({ modeMap[$0.lowercased()] }) else {
        die("error: setmode needs <usb|lsb|cw|data>")
    }
    await openOrDie(rig)
    do {
        try await rig.setMode(mode)
        print("set mode -> \(formatState(await rig.state()))")
    } catch { die("error: \(error)") }
    await rig.close()

case "ptt":
    let rig = parseRigSpec(args)
    guard let onoff = args.last, onoff == "on" || onoff == "off" else {
        die("error: ptt needs <on|off>")
    }
    await openOrDie(rig)
    do {
        try await rig.setPTT(onoff == "on")
        print("PTT \(onoff) -> \(formatState(await rig.state()))")
    } catch { die("error: \(error)") }
    await rig.close()

case "ptttest":
    // Safe momentary keying: key ON, confirm, then ALWAYS key OFF before closing
    // (so the rig can never be left transmitting).
    let rig = parseRigSpec(args)
    await openOrDie(rig)
    do {
        print("keying TX…")
        try await rig.setPTT(true)
        let on = await rig.state()
        print("  PTT on  -> \(formatState(on))")
        try await Task.sleep(nanoseconds: 800_000_000)
        try await rig.setPTT(false)
        let off = await rig.state()
        print("  PTT off -> \(formatState(off))")
        if on.transmitting && !off.transmitting {
            print("PTT keying verified ✓")
        } else {
            print("WARNING: PTT did not toggle as expected — check the rig is in RX now.")
        }
    } catch {
        // Best-effort un-key on any failure.
        try? await rig.setPTT(false)
        die("error: \(error)")
    }
    await rig.close()

default:
    usage()
}

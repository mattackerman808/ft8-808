# FT8-808

A modern, Swift-native macOS client for the **FT8** digital amateur-radio mode — the same
core idea as [WSJT-X](https://github.com/WSJTX/wsjtx), but with a proper native macOS
interface (SwiftUI/AppKit), CoreAudio-based audio processing, and native rig control.

> FT8-808 is an independent project. It is **not** affiliated with or derived from the
> WSJT-X source code (see [Licensing](#licensing)).

## Why

WSJT-X is the canonical, excellent FT8 implementation, but it's a cross-platform Qt app.
On macOS it feels non-native. FT8-808 aims for a first-class Mac experience: native
windowing, menus, accessibility, Metal-rendered waterfall, and clean rig integration.

## Is FT8 open?

Yes — in two ways that matter for this project:

1. **The protocol is openly published.** Franke (K9AN), Somerville (G4WJS), and Taylor
   (K1JT), *"The FT4 and FT8 Communication Protocols,"* QEX Jul/Aug 2020
   ([PDF](https://wsjt.sourceforge.io/FT4_FT8_QEX.pdf)). It fully specifies the 77-bit
   payload, 14-bit CRC, LDPC(174,91) code, Gray-coded 8-FSK mapping, and the three 7×7
   Costas sync arrays. This is enough for a clean-room implementation under any license.

2. **The reference decoder (WSJT-X) is GPLv3.** We deliberately do **not** read or port it,
   to keep FT8-808 free of GPL obligations.

### FT8 in one paragraph

15-second TX/RX slots aligned to UTC. 8-FSK at 6.25 baud, 6.25 Hz tone spacing (~50 Hz
occupied bandwidth). 79 symbols per transmission: 58 data + 21 sync (three 7-symbol Costas
arrays at start/middle/end). A 77-bit message + 14-bit CRC is LDPC-encoded to 174 bits →
58 data symbols. Decoding = Costas-based time/freq sync → soft 8-FSK demod → LDPC decode.

## Planned architecture

| Layer | Plan |
|---|---|
| **Codec (DSP)** | Wrap [`kgoba/ft8_lib`](https://github.com/kgoba/ft8_lib) (**MIT**) as a SwiftPM C target for encode/decode. No GPL code. |
| **Audio I/O** | `AVAudioEngine` / CoreAudio — 12 kHz mono capture, UTC-aligned 15 s windows; playback to rig. |
| **DSP/display** | Accelerate (`vDSP`) FFT → Metal / SwiftUI `Canvas` waterfall + spectrum. |
| **Rig control** | Hamlib (LGPL) wrapper, or native serial CAT (IOKit / ORSSerialPort). PTT via CAT or DTR/RTS. |
| **Time** | Monitor NTP offset; warn on clock drift beyond slot tolerance. |
| **QSO logic** | Message-sequencing state machine, grid squares, signal reports, ADIF logging. |
| **UI** | SwiftUI + AppKit, native macOS. |

## Status

Working FT8 decoder + a terminal client. A headless `FT8808Engine` library
holds the radio logic; front-ends are thin clients over it (terminal now, native
macOS app later). See [`docs/architecture.md`](docs/architecture.md) and
[`docs/roadmap.md`](docs/roadmap.md).

```sh
swift run ft8decode path/to/slot.wav          # one-shot decode, WSJT-X-style lines
swift run ft8term  path/to/slot.wav           # terminal UI: spectrum + band activity
```

`ft8term` runs interactively in a TTY (`q` to quit) and in batch mode when piped
(processes the file, prints the final frame, exits).

## Licensing

- FT8-808's own code: license **TBD** (a permissive choice such as MIT keeps us compatible
  with `ft8_lib` and avoids GPL obligations).
- We rely on the **published protocol spec**, not WSJT-X source.
- Bundled/linked deps keep their own licenses: `ft8_lib` (MIT), Hamlib (LGPL, dynamically
  linked).

## References

- FT4/FT8 protocol paper (QEX 2020): https://wsjt.sourceforge.io/FT4_FT8_QEX.pdf
- `ft8_lib` (MIT C codec): https://github.com/kgoba/ft8_lib
- WSJT-X (GPLv3 reference — for behavior reference, not code reuse): https://github.com/WSJTX/wsjtx
- Hamlib (rig control): https://github.com/Hamlib/Hamlib

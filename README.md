# FT8-808

A **Swift-native FT8 station for macOS** — live decode, waterfall, rig control, and
fully automated QSOs. It ships as a **native macOS app** (GPU 3D/2D waterfall) and a
**fast terminal UI**, both over one shared engine. The same job as
[WSJT-X](https://github.com/WSJTX/wsjtx), built from the published protocol with a
clean-room, GPL-free codebase.

> FT8-808 is an independent project. It does **not** read or port WSJT-X source; it
> relies on the openly published FT4/FT8 protocol spec and the MIT-licensed
> [`ft8_lib`](https://github.com/kgoba/ft8_lib). See [Licensing](#licensing).

It makes **real contacts on the air** — receive, decode, pick a station (or call CQ),
auto-sequence the exchange through to `73`, log it to ADIF — from the mouse in the app or
the keyboard in the terminal client (`ft8term`, shown here):

```
 [Q]uit  [T]une  [F]ind  [S]ettings
 cycle ████████████████████░░░░░░░  12.3/15s  slot even
 ───────────────────────────────────────────────────────────────────
   ▁▂▃▅▇█  live waterfall / spectrum (vDSP FFT, noise-floor scaled)
                          ▲  Rx/Tx 1370 Hz
 ───────────────────────────────────────────────────────────────────
  dB   dt  freq  Band — entire passband │ Rx 570 Hz ±12
 ▎-13 +0.7 2409  EI9KF KB8BSN EL89       │  -14 +0.5  572  CQ AI5OS EM10
 ▎-10 +0.5  569  N6ACK AI5OS RR73        │  Tx        AI5OS N6ACK CM97
 ▎-18 +0.8  991  CQ WD8LOE EM63          │  ● PWR 92W  ALC 1.8  SWR 1.2
 ...                                     │  ▸ Tx3  AI5OS N6ACK R-13   now
                                         │  ✓ QSO  AI5OS sent -10 rcvd -16
   ↑↓/jk pick   ⏎ answer                 │  [C]Q  [E] TX  [O] slot  esc clear
 ───────────────────────────────────────────────────────────────────
 live: USB Audio CODEC   decoding…
```

## Features

- **Live receive** — CoreAudio capture from the rig's USB codec, UTC-aligned 15 s
  slots, full `ft8_lib` decode, with realistic SNR (WSJT-X-comparable, computed from
  the waterfall — not a sync-score proxy).
- **Waterfall / spectrum** — vDSP FFT with noise-floor-referenced scaling; the app renders
  it as a live Metal **3D or 2D** waterfall you click to set Tx frequency.
- **Dual band view** — entire passband on the left, your Rx-frequency traffic on the
  right (the WSJT-X "Band Activity / Rx Frequency" split).
- **Callsign highlighting** — your call green, worked-before (from your ADIF log) red,
  per-token; even/odd slot markers down the band column.
- **Rig control** — bundled Hamlib (no `brew install`): CAT frequency/mode and PTT.
- **Transmit** — GFSK waveform synthesis, slot-aligned, keyed via CAT. Tune + auto-tune
  drive calibration with live PWR/ALC/SWR meters.
- **Automated QSOs** — pick a decode and the state machine sequences the whole exchange
  (CQ → grid → report → R-report → RR73 → 73), then auto-completes.
- **ADIF logging** — every QSO appended to `~/.config/ft8-808/ft8-808.adi`, importable
  into LoTW / QRZ / Club Log.
- **LoTW auto-upload** — optional: each logged QSO is signed and uploaded to ARRL
  Logbook of The World via your installed [TrustedQSL](https://lotw.arrl.org/lotw-help/cmdline/)
  (`tqsl`). Enable in **[S]ettings** (or `--lotw --lotw-location "<name>"`). On
  launch (and on enabling) it catches up the whole log — anything logged while it
  was off — and **U** uploads the whole log on demand. TQSL dedups, so nothing is
  sent twice.
- **Self-contained** — one `swift build`; Hamlib ships as a relocatable xcframework.

## Install

Download the latest **signed + notarized `.pkg`** from
[**Releases**](https://github.com/mattackerman808/ft8-808/releases) and double-click it.
It installs both front-ends:

- **`FT8-808.app`** → `/Applications` — the native macOS app, and
- **`ft8term`** → `/usr/local/bin` — the terminal client (on your `PATH`).

They share one config at `~/.config/ft8-808/config.json`, so you can use either
interchangeably. The package is notarized, so Gatekeeper clears it with no warning.
Universal (Apple Silicon + Intel), **macOS 13+**. You'll need a rig with a USB audio
codec + CAT; Hamlib is bundled (no `brew install`).

## Build from source

Requirements: **macOS 13+** and **Swift 6** (Xcode 16 / recent toolchain).

```sh
git clone https://github.com/mattackerman808/ft8-808.git
cd ft8-808
swift build
swift run ft8gui             # the native app
swift run ft8term            # the terminal client
```

## Using the app (GUI)

Launch **FT8-808** (from `/Applications`, Spotlight, or `swift run ft8gui`). On the first
run, click the **⚙ gear** to set your callsign, grid, rig (CAT port + Hamlib model), and
audio input/output. macOS asks for microphone access the first time it captures — that's
your rig's receive audio.

**Tune the radio** — from the top bar:
- **Band** menu — jump to a band's standard FT8 dial frequency.
- **Scroll over the VFO digits** to tune; scrolling over the MHz / kHz / Hz part of the
  readout steps that place. The **▲▼** steppers nudge ±1 kHz.

**Work a station:**
1. Flip **Enable TX** on (top bar) — the master transmit switch; it glows red when armed.
2. **Click a decode** in the Passband or RX Frequency list. It loads the QSO — replying on
   the station's frequency, in the opposite slot — and if you clicked early enough in your
   own slot it goes out *that* cycle ("pounce"). Click another station to switch to it.
3. Or hit **Call CQ** and let callers come to you.

The sequencer runs the whole exchange (reply → report → roger → `RR73`/`73`), logs the QSO
to ADIF, and drops a green **✓ QSO** banner in the list. Then pick the next one.

Handy bits: **Find Free** (on the RX/TX bar) drops you on a clear Tx frequency · the
**Even/Odd** selector picks your transmit cycle · the **gauges** read live PWR/SWR/ALC · the
**antenna icon** opens the Tuner (key a carrier, set drive, or auto-tune) · worked-before
calls show **red**, your own call **green**, and the bar under the RX/TX field tracks the
15 s cycle.

## Using the terminal client (TUI)

`ft8term` is the same station, keyboard-driven — handy over SSH or on a headless shack box.
First run, press **`S`** for Settings to set callsign, grid, rig, and audio — or pass flags:

```sh
ft8term                      # if installed; or `swift run ft8term` from source
ft8term --call N0CALL --grid FN42 \
        --rig ts590sg,/dev/cu.usbserial-XXXX,115200 \
        --audio "USB Audio CODEC"
```

| Key | Action |
|---|---|
| `↑`/`↓` or `j`/`k` | pick a decode in the band column |
| `⏎` | answer the selected station (replies on their freq, opposite slot) |
| `C` | call CQ (press again to stop) |
| `E` | enable / disable TX |
| `O` | swap even/odd transmit slot |
| `esc` | clear selection / abandon the active QSO |
| `←`/`→`, `,`/`.`, `<`/`>` | move the Rx/Tx frequency cursor |
| `F` | auto-pick a clear Tx frequency |
| `T` | tune (key PTT + tone); `+`/`-` drive, `A` auto-tune |
| `S` | settings · `Q` quit |

Decode a recorded slot, WSJT-X style:

```sh
ft8term path/to/slot.wav             # TUI batch mode (prints the final frame, exits)
swift run ft8decode path/to/slot.wav # one-shot decoder (dev tool, build from source)
```

### Diagnostics

```sh
ft8term --list-audio                 # audio devices (flags the rig codec)
ft8term --list-serial                # serial ports (flags the rig CAT port)
ft8term --list-rigs                  # Hamlib-supported rigs
ft8term --meter "USB Audio CODEC"    # probe the capture path + live level
swift run ft8rig ...                 # standalone rig CAT/PTT diagnostic (dev tool)
```

## How it works

15-second UTC-aligned TX/RX slots. 8-FSK at 6.25 baud, 6.25 Hz tone spacing. 79 symbols
(58 data + 21 Costas sync). A 77-bit message + 14-bit CRC → LDPC(174,91) → tones. Decode =
Costas sync → soft 8-FSK demod → LDPC. The protocol is fully specified in
[*The FT4 and FT8 Communication Protocols*](https://wsjt.sourceforge.io/FT4_FT8_QEX.pdf)
(Franke/Somerville/Taylor, QEX 2020) — enough for a clean-room build with no GPL code.

**Architecture:** a headless `FT8808Engine` library holds all the radio logic; the
front-ends are thin clients over it — the `ft8gui` app and the `ft8term` TUI.

| Target | Role |
|---|---|
| `CFT8` | vendored `ft8_lib` (MIT) + a C shim: decode pipeline, GFSK synth, SNR estimate |
| `FT8Codec` | Swift wrapper — `decode`, `encode`, `synthesize` |
| `FT8808Engine` | audio (raw AUHAL capture/playback), slot timing, spectrum, QSO sequencer, ADIF, rig protocol |
| `CHamlib` / `HamlibRig` | bundled Hamlib xcframework + actor-based `RigController` |
| `ft8gui` | native macOS app — SwiftUI + Metal 3D/2D waterfall over the engine |
| `ft8term` / `ft8rig` / `ft8decode` | terminal client + diagnostics |

See [`docs/architecture.md`](docs/architecture.md), [`docs/roadmap.md`](docs/roadmap.md),
and [`CLAUDE.md`](CLAUDE.md) (orientation for AI agents and new contributors — the
hard-won macOS-audio and rig-control gotchas live there).

## Licensing

- **FT8-808's own code: MIT** (see [`LICENSE`](LICENSE)).
- Bundled/linked deps keep their licenses — `ft8_lib` (MIT), Hamlib (LGPL-2.1+, dynamically
  linked). Full third-party notices and LGPL compliance details in [`NOTICE.md`](NOTICE.md).
- We use the **published protocol spec**, never WSJT-X (GPLv3) source.

## References

- FT4/FT8 protocol paper (QEX 2020): https://wsjt.sourceforge.io/FT4_FT8_QEX.pdf
- `ft8_lib` (MIT C codec): https://github.com/kgoba/ft8_lib
- Hamlib (rig control): https://github.com/Hamlib/Hamlib
- WSJT-X (GPLv3 — behavioral reference only, no code reuse): https://github.com/WSJTX/wsjtx

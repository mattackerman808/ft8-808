# CLAUDE.md — orientation for AI agents (and humans)

FT8-808 is a Swift-native FT8 amateur-radio station for macOS: live decode, waterfall,
rig control, transmit, automated QSOs, ADIF logging. This file is the map and the
landmine-flags. Read it before changing audio or rig code — several things here were
expensive to learn and are easy to regress.

## Build / test / run

```sh
swift build
swift test                                   # pure logic is unit-tested; keep it green
swift run ft8term                            # live station (uses ~/.config/ft8-808/config.json)
swift run ft8term path/to/slot.wav           # decode a recorded slot (batch)
swift run ft8term --meter "USB Audio CODEC"  # probe the capture path + live input level
swift run ft8term --list-audio|--list-serial|--list-rigs
```

- Swift 6, macOS 13+. SwiftPM only (no Xcode project).
- Hamlib is **bundled** as `Vendor/Hamlib.xcframework` (committed, ~11 MB). Rebuild with
  `Scripts/build-hamlib.sh`. End users never run `brew install`.
- `swift run` from the repo root. If a build complains about `Info.plist`, you've `cd`'d
  into a vendor subdir — go back to the root.

## Layout (headless engine + thin clients)

All radio logic lives in `FT8808Engine`; front-ends are thin.

- `Sources/CFT8/` — vendored `ft8_lib` (MIT) + `shim/ft8808_shim.c` (decode pipeline,
  GFSK synthesis, **SNR estimate**). `Sources/CFT8/include/ft8808_shim.h` is the C ABI.
- `Sources/FT8Codec/` — Swift wrapper: `decode`, `encode`, `synthesize`, `transmitAudio`.
- `Sources/FT8808Engine/` — the core:
  - `AudioCaptureUnit.swift` — **raw AUHAL input** capture (see gotchas).
  - `TxAudioOutput.swift` + `AudioRenderSource.swift` + `ToneGenerator.swift` — **raw AUHAL output**.
  - `LiveAudioSource.swift` — drives `AudioCaptureUnit` → `SlotAccumulator` → slots.
  - `SlotAccumulator.swift` / `SlotClock.swift` — UTC 15 s slot math + even/odd parity.
  - `Spectrum.swift` — vDSP FFT waterfall (noise-floor-referenced scaling).
  - `QSOMessages.swift` / `QSOSequencer.swift` — message gen/parse + the QSO state machine.
  - `ADIFLog.swift` — append-only ADIF log + worked-before reader.
  - `RigController.swift` (protocol), `StationConfig.swift`.
- `Sources/CHamlib/` + `Sources/HamlibRig/` — Hamlib C shim + actor `RigController`.
- `Sources/ft8term/` — the TUI (`main.swift` is large; `Terminal.swift`, `SettingsPanel.swift`).
- `Sources/ft8rig/`, `Sources/ft8decode/` — diagnostics / one-shot decode.

## ⚠️ Hard-won gotchas — do not regress these

### CoreAudio: use raw AUHAL, never AVAudioEngine (both directions)
For the rig's USB codec, use raw CoreAudio `kAudioUnitSubType_HALOutput` units.
- **Capture:** AVAudioEngine's `inputNode` mis-binds a non-default device — it reports a
  stale downstream format (we saw 16000 Hz/1ch) that doesn't match the hardware (48000/2),
  so the tap delivers **zero buffers**, or `engine.start()` fails with **-10868**. Fixed by
  `AudioCaptureUnit` (HAL input). HAL input units do stereo→mono but **not** sample-rate
  conversion, so capture at the hardware rate and resample to 12 kHz in software.
- **Output:** AVAudioEngine's graph silently failed on the same codec. Fixed by AUHAL output.
- Diagnose with `--meter` (shows device, CoreAudio nominal rate, inputNode formats, live
  level) and cross-check with `ffmpeg -f avfoundation -i ":<idx>" -af volumedetect`. If
  ffmpeg reads a healthy level but we get silence, it's our capture path, not the device.
- A wedged codec survives an app restart; clear it with a USB replug or `sudo killall coreaudiod`.

### Keep RX capture running through message-TX
The rig exposes its USB codec as **separate** input (RX) and output (TX) CoreAudio devices,
so capture and the TX output unit don't conflict. Do **not** suspend/resume the capture
engine every transmit — that churn is what wedges the audio driver. The `sending` flag in
`ft8term` makes the decoder drop the TX-monitor slots instead.

### Kenwood (and Hamlib) rig quirks
- **DATA PTT:** the Kenwood TS-590S/SG default `ptt_type` is `RIG_PTT_RIG_MICDATA`. Key with
  `RIG_PTT_ON_DATA` (→ CAT `TX1;`) so it routes the rear/USB-codec audio, not the front mic.
  On Yaesu (`RIG_PTT_RIG`) the frontend collapses it to plain `RIG_PTT_ON`, so it's a no-op.
  This is in the shim's `ft8808_rig_set_ptt`. (Symptom if wrong: rig keys but makes no RF.)
- **Never read `RIG_LEVEL_RFPOWER` in the meter poll.** On Kenwood, `get_level(RFPOWER)` runs
  a destructive `PC;PC000;PC;PC255;PC;PC000;` probe whenever PTT is off, leaving the rig at its
  5 W minimum (Hamlib issue #1595). The shim's `get_meters` reads only SM/RM/SW.
- **`set_mode` uses `RIG_PASSBAND_NOCHANGE`** so changing mode never clamps the user's filter.
- **FT8 mode is USB, not DATA** on the FTDX-101D (DATA-U engages the 600 Hz roofing filter).
  Don't hardcode DATA.

### SNR is computed, not faked
`ft8808_estimate_snr` (in the shim) measures signal vs noise at the 21 Costas sync symbols
and normalizes to the 2500 Hz reference (−26 dB), giving WSJT-X-comparable values. Do **not**
revert to `score * 0.5` (that's the sync score, ~always +10). Kenwood reports ALC on a 0–5
scale (not 0–1) — the meter color threshold is naive about that; flagged, not yet rig-aware.

### Slot timing
Slots are `floor(epoch/15)`; even parity = `:00/:30`, odd = `:15/:45`. When you answer a
station you transmit in the **opposite** parity. The TX scheduler waits ~1.5 s after the
boundary (grace) so the just-ended slot's decode can advance the QSO and you reply the
**same cycle**; the synthesized buffer then has minimal lead (first symbol ≈ +1.5 s, DT well
within the sync window).

## Conventions

- **Test the pure logic** (slot math, message gen/parse, sequencer, ADIF, waveform). Audio/rig
  paths are validated with `--meter` / on-air, not unit tests.
- Keep C interop confined to `CFT8`/`CHamlib`; the rest is Swift.
- The TUI redraws a full flicker-free frame each render (home + clear-to-EOL). That's by
  design — don't try to do partial updates.
- **Commits/PRs: no AI or "Co-Authored-By" attribution.** Keep messages factual and specific.
- License is MIT; never read or port WSJT-X (GPLv3). New deps must be MIT/BSD/LGPL-compatible
  and recorded in `NOTICE.md`.

## Status & where to go next

Working end-to-end on the air (first QSO logged). See `docs/roadmap.md`. Likely next:
ALC color threshold made rig-aware, new-DXCC highlighting, free-text macros, an "add past
QSO" path, and eventually the native macOS app (Milestone 5) over the same `FT8808Engine`.

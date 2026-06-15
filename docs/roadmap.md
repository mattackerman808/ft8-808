# Roadmap

Ordered to de-risk the hardest/unknown parts first.

**Strategy:** a headless `FT8808Engine` library holds all radio logic (codec,
audio, rig, QSO, logging). Front-ends are thin clients over it — the terminal
client `ft8term` first (SSH-friendly, no graphics yak-shaving), the native
macOS app later. See [architecture.md](architecture.md).

## Milestone 0 — Spike the codec (de-risk decode) ✅
- [x] Vendor `ft8_lib`, build it as a SwiftPM C target (`CFT8`).
- [x] Swift `FT8Codec` wrapper: `decode(samples:)` and `decode(wavPath:)`.
- [x] Prove it: decode known-good recordings under XCTest. ~38 ms/slot.
- [ ] Encode path (`encode(String) -> [Float]`) — deferred to Milestone 4 (TX).

## Milestone 1 — Headless engine + terminal client
- [x] `FT8808Engine`: `AudioSource` protocol, `WavFileSource`, `DecodeEngine`
      streaming per-slot `SlotResult`s, vDSP `Spectrum`, `RigController` (+ mock).
- [x] `ft8term`: raw-mode ANSI TUI — status line, color spectrum/waterfall,
      scrolling band-activity log. Interactive (TTY) and batch (piped) modes.
- [x] Live `AVAudioEngine` capture source → resample to 12 kHz mono, UTC 15 s
      slot alignment (`SlotAccumulator`, unit-tested), CoreAudio device picker.
- [x] `ft8term --live [--audio <name>]` and `--list-audio`; embedded Info.plist
      so the CLI can prompt for mic permission.
- [x] Verified live decode end-to-end on the FTDX-101D's USB codec — real
      off-air decodes + live CAT frequency in the status line. 🎉
- [ ] NTP / clock-offset display (warn when drift exceeds slot tolerance).
- [ ] Scrolling (time-axis) waterfall once audio is live, not just per-slot.

## Milestone 2 — Rig control (Hamlib) — bundled
- [x] Bundle Hamlib 4.7.1 (LGPL) as a relocatable `Hamlib.xcframework` via
      `Scripts/build-hamlib.sh` — **no `brew install` for end users**. Dylib is
      self-contained (only `/usr/lib/libSystem`), `@rpath`-linked.
- [x] `CHamlib` C shim + `HamlibRigController` (actor) implementing
      `RigController`: open, get/set freq, mode, PTT.
- [x] Verified end-to-end against Hamlib's software dummy rig (no hardware).
- [x] `ft8term --rig <dummy|model[,device[,baud]]>`; live status-line polling.
- [x] `ft8rig` diagnostic CLI (ports / probe / setfreq / setmode / ptt) with
      named-rig aliases.
- [x] Verified on real hardware — Yaesu FTDX-101D (model 1040, 38400 baud):
      CAT read, set-frequency, set-mode, and momentary PTT keying all confirmed.
- [ ] Make FT8 operating mode configurable per rig (do NOT hardcode DATA): on
      the FTDX-101D, DATA-U engages the narrow 600 Hz roofing filter and breaks
      FT8's wide passband — USB is the right mode there.
- [ ] Universal (arm64 + x86_64) dylib: `ARCHS="arm64 x86_64" build-hamlib.sh`.
- [ ] Rig picker UI; code-sign the bundled dylib for notarised distribution.

## Milestone 3 — QSO logic + logging
- [ ] Message parsing into structured fields (call_to / call_de / grid / report).
- [ ] Auto-sequencing state machine (CQ → grid → report → R-report → RR73 → 73).
- [ ] ADIF logging.

## Milestone 4 — Transmit
- [x] `FT8Codec.encode(text) -> tones` over ft8_lib's encoder; `synthesize` +
      `transmitAudio` GFSK waveform synthesis (reference ft8_lib algorithm).
- [x] Proven offline: encode → synth → decode round-trips for CQ / report /
      RR73 at multiple audio offsets (no RF).
- [ ] Audio OUTPUT to the rig's USB codec (AVAudioEngine output node).
- [ ] On-air TX: key PTT at the UTC boundary, play the slot, un-key (dummy load).
- [ ] Close the loop: complete an automated QSO from `ft8term`.

## Milestone 5 — macOS app
- [ ] SwiftUI/AppKit app over the same `FT8808Engine`.
- [ ] Metal 3D waterfall, band-activity + QSO panels, preferences.
- [ ] Accessibility, color schemes, logging UI.

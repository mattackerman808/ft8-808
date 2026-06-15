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
- [ ] Live `AVAudioEngine` capture source → 12 kHz mono, UTC 15 s slot alignment.
- [ ] NTP / clock-offset display (warn when drift exceeds slot tolerance).
- [ ] Scrolling (time-axis) waterfall once audio is live, not just per-slot.

## Milestone 2 — Rig control (Hamlib)
- [ ] `CHamlib` system-library target; `HamlibRigController` implementing
      `RigController` (freq read/set, mode, PTT).
- [ ] Rig picker / serial config; surface live freq+mode in the TUI status line.

## Milestone 3 — QSO logic + logging
- [ ] Message parsing into structured fields (call_to / call_de / grid / report).
- [ ] Auto-sequencing state machine (CQ → grid → report → R-report → RR73 → 73).
- [ ] ADIF logging.

## Milestone 4 — Transmit
- [ ] `FT8Codec.encode(String) -> [Float]` over ft8_lib's encoder.
- [ ] 8-FSK (GFSK-shaped) audio synthesis; output device + PTT keying.
- [ ] Close the loop: complete an automated QSO from `ft8term`.

## Milestone 5 — macOS app
- [ ] SwiftUI/AppKit app over the same `FT8808Engine`.
- [ ] Metal 3D waterfall, band-activity + QSO panels, preferences.
- [ ] Accessibility, color schemes, logging UI.

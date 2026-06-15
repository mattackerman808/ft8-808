# Roadmap

Ordered to de-risk the hardest/unknown parts first.

## Milestone 0 — Spike the codec (de-risk decode) ✅
- [x] Vendor `ft8_lib`, build it as a SwiftPM C target (`CFT8`).
- [x] Swift `FT8Codec` wrapper: `decode(samples:)` and `decode(wavPath:)`.
- [x] Prove it: decode known-good recordings (`191111_110130.wav` → 4 msgs,
      `websdr_test14_12k.wav` → 13 msgs) under XCTest. ~38 ms/slot.
- [ ] Encode path (`encode(String) -> [Float]`) — deferred to Milestone 3 (TX).

## Milestone 1 — Audio in + waterfall
- [ ] AVAudioEngine capture, resample to 12 kHz mono.
- [ ] vDSP FFT → live waterfall (Metal or Canvas).
- [ ] UTC slot alignment + NTP-offset display.

## Milestone 2 — Decode loop
- [ ] Per-slot windowing → codec decode → on-screen band activity list.
- [ ] Parse messages (CQ / grid / report / RR73 / 73).

## Milestone 3 — Transmit
- [ ] 8-FSK (GFSK-shaped) audio synthesis from encoded symbols.
- [ ] Output device selection + audio level/PTT test.

## Milestone 4 — Rig control
- [ ] Native CAT for one target rig (freq read/set, PTT).
- [ ] Optional: Hamlib backend for broad rig support.

## Milestone 5 — QSO + logging
- [ ] Auto-sequencing state machine (CQ → 73).
- [ ] ADIF logging.

## Milestone 6 — Polish
- [ ] Native macOS UX, preferences, multi-decode, color schemes, accessibility.

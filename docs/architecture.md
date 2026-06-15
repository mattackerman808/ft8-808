# Architecture

This is a design sketch, not a commitment. It exists to make the moving parts explicit.

## Module boundaries

```
+-----------------------------------------------------------+
|                          UI (SwiftUI/AppKit)              |
|   Waterfall view · Band activity · QSO panel · Settings   |
+----------------------+------------------+-----------------+
                       |                  |
              +--------v------+   +-------v---------+
              |  QSO engine   |   |  Audio engine   |
              | state machine |   | AVAudioEngine   |
              | ADIF logging  |   | 12 kHz mono I/O |
              +--------+------+   +-------+---------+
                       |                  |
              +--------v------------------v---------+
              |        FT8 codec (Swift wrapper)    |
              |   encode(msg) / decode(samples)     |
              +------------------+------------------+
                                 |
                       +---------v---------+
                       |  ft8_lib (C, MIT) |
                       +-------------------+

              +-----------------------------+
              |   Rig control (CAT + PTT)   |  <- Hamlib (LGPL) or native serial
              +-----------------------------+
```

## Critical timing path (RX)

1. CoreAudio delivers input buffers continuously at the chosen rate (resample to 12 kHz).
2. Audio engine maintains a ring buffer and tags samples with a monotonic clock mapped to UTC.
3. At each 15 s slot boundary (UTC seconds 0/15/30/45, ± guard), hand the ~15 s window to the codec.
4. Codec runs FFT-based waterfall update (live) and full `ft8_lib` decode (per slot).
5. Decoded messages → QSO engine → UI + log.

The hard constraint: the slot window must be UTC-aligned to within FT8's sync tolerance
(roughly ±0.5 s usable). So clock discipline (NTP offset awareness) is a first-class concern,
not an afterthought.

## Critical timing path (TX)

1. QSO engine decides the next message (e.g. `CQ K1ABC FN42`), encodes via codec → 79 symbols.
2. At the next slot boundary, synthesize 8-FSK audio (GFSK-shaped tone transitions) at the
   chosen audio offset, stream to output device feeding the rig.
3. Assert PTT (CAT or DTR/RTS) just before audio, release after.

## ft8_lib integration

- Vendor `ft8_lib` under `Vendor/ft8_lib/` (or a submodule), expose as a SwiftPM C target.
- Thin Swift wrapper (`FT8Codec`) presenting Swift-native `encode`/`decode` APIs over the C ABI.
- Keep all C-interop confined to that one module so the rest of the app is pure Swift.

## Open questions

- Hamlib (broad rig support, LGPL C dependency, bundling complexity) vs. native CAT
  (clean Swift, but per-rig work). Likely: start native for one rig, add Hamlib later.
- Resampling strategy if the codec device isn't 12 kHz-native.
- Metal vs. SwiftUI Canvas for the waterfall at acceptable CPU.

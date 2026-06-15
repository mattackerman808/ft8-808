# Third-party notices

FT8-808 is MIT-licensed (see `LICENSE`). It bundles and adapts the following:

## ft8_lib

- Source: https://github.com/kgoba/ft8_lib
- License: MIT — Copyright (c) 2018 Kārlis Goba
- Full text: `Sources/CFT8/ft8_lib.LICENSE.txt`
- Location: `Sources/CFT8/{ft8,fft,common}/`
- Notes: Vendored encode/decode codec (LDPC, Costas sync, message pack/unpack)
  plus the KISS FFT it depends on. `common/audio.c` (PortAudio) is intentionally
  **not** vendored. `Sources/CFT8/shim/ft8808_shim.c` adapts the decode pipeline
  and callsign hashtable from `demo/decode_ft8.c`.

Deliberately **not** used anywhere in this project: WSJT-X (GPLv3). FT8-808
relies only on the openly published FT4/FT8 protocol specification and the
MIT-licensed ft8_lib.

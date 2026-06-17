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

## Hamlib

- Source: https://github.com/Hamlib/Hamlib (release 4.7.1)
- License: **LGPL-2.1-or-later** — full text: `Vendor/Hamlib.LICENSE.txt`
- Bundled artifact: `Vendor/Hamlib.xcframework` (a shared `libhamlib.4.dylib`),
  built by `Scripts/build-hamlib.sh`. Headers are vendored under
  `Sources/CHamlib/vendor/hamlib/` to compile the shim.
- LGPL compliance: Hamlib is **dynamically linked** as an unmodified shared
  library, and the user can replace the bundled dylib with their own build
  (it is `@rpath`-linked, and in the app bundle lives in `Contents/Frameworks/`).
  This keeps FT8-808's own MIT terms intact.
- **Written offer:** the complete corresponding source for the bundled Hamlib is
  the unmodified release tarball at
  https://github.com/Hamlib/Hamlib/releases/tag/4.7.1
  (SHA-256 `d197a08a3d5d936d7571ae573f745bbba619e88998742c8267e3fcb0fb3d5974`),
  built with the flags in `Scripts/build-hamlib.sh`.

## TrustedQSL (`tqsl`) — invoked, not bundled

- Source: https://sourceforge.net/p/trustedqsl/tqsl/
- Used for: signing and uploading QSOs to ARRL Logbook of The World (LoTW).
- Integration: FT8-808 **shells out** to the user's own installed `tqsl`
  command-line tool (see `Sources/FT8808Engine/TQSLUploader.swift`). No
  TrustedQSL source or library is copied, linked, or distributed with FT8-808 —
  it is an optional external program the operator installs and configures
  separately (with their own LoTW certificate and station location). This keeps
  FT8-808's MIT terms intact and reuses the operator's already-validated setup.

Deliberately **not** used anywhere in this project: WSJT-X (GPLv3). FT8-808
relies only on the openly published FT4/FT8 protocol specification and the
MIT-licensed ft8_lib.

# Static RAR fixtures (NOT tool-generated)

These archives are **irreplaceable by `tool/generate_fixtures.dart`** and
live here, outside `test/fixtures/rar/`, on purpose: the generator wipes
its own `test/fixtures/<set>` directory before each run
(`outDir.deleteSync(recursive: true)`), and it runs rar 7.x, which **cannot
author RAR4 (v4)** — `-ma4` was removed. Keeping these under `rar/` would
mean the next `dart run tool/generate_fixtures.dart --only rar` silently
deletes them.

| File | Provenance |
| --- | --- |
| `enc_rar4_store.rar` | rar 6.24, `-ma4 -m0 -psecret` — encrypted RAR4 store (hello.txt, lorem.txt, nested/notes.txt) |
| `enc_rar4.rar` | rar 6.24, `-ma4 -m3 -psecret` — encrypted RAR4 compressed (same members) |
| `filter_delta.rar` | rar 6.24, `-ma4 -m5` over `grad.bmp` (24-bit gradient BMP) — trips the **delta** filter (kind 0) |
| `filter_e8.rar` | rar 6.24, `-ma4 -m5` over `x86call.bin` (synthetic x86 with dense CALLs to a fixed target) — trips the **x86 E8** filter (kind 1) |
| `filter_rgb.rar` | rar 6.24, `-ma4 -m5 -mm` over `rgbimg.bmp` (correlated-channel BMP) — trips the **RGB** filter (kind 3) plus a delta block |
| `filter_audio.rar` | rar 6.24, `-ma4 -m5` over `a_audio.raw` (16-bit stereo PCM sine) — trips the **audio** filter (kind 4) |

The `filter_*.rar` archives are the CI regression guard for the RAR4 RarVM
standard filters (`rar4_filters_test.dart` decodes them byte-exact on
VM/dart2js/dart2wasm via the default CRC-32 verify). RAR's filter selection is
content- and heuristic-driven, so the *inputs* above are what trips each
filter, not a flag: a 24-bit BMP or PCM tends toward delta/audio, the `-mm`
multimedia mode is needed for RGB, and E8 needs code-like data whose CALL
targets converge (so the filter is a clear compression win). The corpus
additionally exercises delta across 37 real pages.

To regenerate (only if the content must change): download rar 6.24
(`https://www.rarlab.com/rar/rarmacos-arm-624.tar.gz`; a `curl` download
avoids the Gatekeeper quarantine that blocks the Homebrew cask) and re-author
with the commands above. After regenerating a `filter_*` archive, confirm it
still trips the intended filter (decode it and check the entry is byte-exact —
a wrong filter would throw `ChecksumMismatchException`). See
`koni_rar/doc/notes.md` for the encryption and filter format details these
exercise.

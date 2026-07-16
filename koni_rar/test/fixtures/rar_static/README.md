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
| `hp_rar4.rar` | rar 6.24, `-ma4 -m3 -hpsecret` — RAR4 **encrypted headers** (`-hp`, same members); the block headers themselves are AES-encrypted, so even listing needs the password |
| `hp_rar4_store.rar` | rar 6.24, `-ma4 -m0 -hpsecret` — RAR4 `-hp` over stored members (isolates the header crypto from the method-29 decoder) |
| `filter_delta.rar` | rar 6.24, `-ma4 -m5` over `grad.bmp` (24-bit gradient BMP) — trips the **delta** filter (kind 0) |
| `filter_e8.rar` | rar 6.24, `-ma4 -m5` over `x86call.bin` (synthetic x86 with dense CALLs to a fixed target) — trips the **x86 E8** filter (kind 1) |
| `filter_rgb.rar` | rar 6.24, `-ma4 -m5 -mm` over `rgbimg.bmp` (correlated-channel BMP) — trips the **RGB** filter (kind 3) plus a delta block |
| `filter_audio.rar` | rar 6.24, `-ma4 -m5` over `a_audio.raw` (16-bit stereo PCM sine) — trips the **audio** filter (kind 4) |
| `solid_rar4.rar` | rar 6.24, `-ma4 -m3 -s` over five text files sharing a vocabulary — a **solid** run where later files reference earlier ones through the shared window |
| `ppmd_rar4.rar` | rar 6.24, `-ma4 -m5 -mc16:1t+` over repeated sentences (18771 B) — forces **PPMd variant H** ("text compression"); exercises literals, rescale/glue, and the PPMd LZ escape (code 4) in a 1 MB model |
| `ppmd_rar4_runs.rar` | rar 6.24, `-ma4 -m5 -mc32:1t+` over 324600 B of long repeated runs — a **PPMd** stream that leans on the distance-1 (code 5) and distance (code 4) escapes. Note: libarchive 3.7.4's own RAR reader fails this stream (`Internal error extracting RAR file`); `unrar` and this decoder both decode it |
| `solid_ppmd.rar` | rar 6.24, `-ma4 -m5 -mct+ -s` over three text files — a **solid PPMd** run. The first member decodes; a continuation is a typed `UnsupportedFeatureException` (the cross-file PPMd model transition is defined only by the GPL unrar — libarchive supports no solid RAR at all) |
| `ppmd_switch.rar` | rar 6.24, `-ma4 -m5 -mc:1t` over ~62 KB of natural-ish text + a repetitive binary block + a short text tail — RAR's `-mct` auto-mode switches compression **mid-file from PPMd to method-29 (LZSS)** (PPMd escape code 0 → an LZSS table block). Exercises R8's block-switch hand-off; byte-exact vs unrar |
| `rar2_lz.rar` | **DOS RAR 2.50**, `-m3` over prose (15361 B) — **RAR 2.0 (unpack v20)** LZ block; literal + match mix |
| `rar2_lz_repeat.rar` | **DOS RAR 2.50**, `-m3` over 128200 B of a repeated 16-byte pattern — v20 LZ, match-heavy (short/reused offsets) |
| `rar2_audio.rar` | **DOS RAR 2.50**, `-m5 -mm` over 16-bit PCM — a v20 **multimedia/audio** block, which is a typed `UnsupportedFeatureException` (no correct permissive reference; `rardecode`'s audio decoder mis-decodes it) |
| `rar2_solid.rar` | **DOS RAR 2.50**, `-m3 -s` over two text files — a **solid** v20 run. The run's first file decodes; a continuation is a typed `UnsupportedFeatureException` (full solid-v20 decode is deferred) |

The `rar2_*.rar` fixtures need **DOS RAR 2.50** — no modern tool writes unpack
version 20 (rar 7.x/6.24 only write v29/v50, and rar 2.x is a 32-bit i386 binary
Rosetta 2 can't run). To regenerate: download `https://www.rarlab.com/rar/rar250.exe`
(a RAR SFX), extract `RAR.EXE` with `unrar x rar250.exe RAR.EXE`, then run it under
DOSBox (`brew install dosbox`; headless with `SDL_VIDEODRIVER=dummy dosbox -conf
<conf> -exit`, a `[autoexec]` that mounts the work dir and runs `rar a -m3 out.rar
in.txt`). `unrar` (any modern version) reads v20 and is the byte-exact oracle.

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

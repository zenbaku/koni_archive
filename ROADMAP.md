# koni_archive: Roadmap

Tracking document for the milestones behind each release. Update the Status
column as work lands.

Last updated: 2026-07-17 · Statuses: ⬜ not started · 🟨 in progress · ✅ done

---

## Phase 1: Reading

| #   | Milestone            | Scope (summary)                                                                  | Exit criterion                                        | Status |
| --- | -------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------- | ------ |
| M0  | Scaffolding          | Pub workspace, package skeletons, lints, CI (VM ×3 OS + dart2js + dart2wasm), fixture generator, MIT licenses, conformance-runner skeleton | CI green on all platforms with empty packages         | ✅     |
| M1  | Core                 | `ByteSource` (+ memory/file/blob impls), byte/bit readers, CRC32/Adler32, exceptions, entry model, path normalization, detection registry | Core API dartdoc'd; registry drives detection e2e     | ✅     |
| M2  | TAR                  | ustar + PAX + GNU long names, base-256, all entry types represented               | Real-world tarballs (incl. CBT) list & stream          | ✅     |
| M3  | ZIP (stored)         | EOCD scan, central directory, implicit dirs, encodings, ZIP64-detect→error        | Stored-only ZIPs list & stream                         | ✅     |
| M4  | Inflate + GZIP       | Inflate codec (vector-tested standalone), gzip framing incl. multi-member, `.gz` single-entry adapter | Codec passes canonical vectors; `.gz` opens as archive | ✅     |
| M5  | ZIP (deflate)        | Wire inflate into M3                                                              | **CBZ works end-to-end → tag 0.1.0** (6 packages)      | ✅     |
| M6  | tar.gz               | Layered detection, documented random-access strategy (sequential + cache)         | `.tar.gz`/`.tgz` opens as the inner TAR                | ✅     |
| M7  | ZIP hardening        | ZIP64, data-descriptor edge cases, encoding hook, encrypted-entry detection polish | ZIP64 fixtures pass; mojibake fixtures decode via hook | ✅     |
| M8  | 7z                   | Container + LZMA → LZMA2 → BCJ(x86) → delta; solid-block LRU cache; BCJ2/PPMd/AES→typed errors | CB7 page-flip usable (bench recorded)                  | ✅     |
| M9  | RAR5                 | ✅ Gate passed: provenance signed off 2026-07-15. Container + RAR5 codec           | CBR (v5) works                                         | ✅     |
| M10 | RAR4                 | Container + store + method-29 (v29 LZSS/Huffman) + RarVM standard filters (delta/E8/RGB/audio); PPMd/custom-VM/solid→typed errors | CBR (v4) works (flagship use case complete)            | ✅     |

Every milestone additionally carries the standing definition of done:
all CI platforms green incl. dart2wasm, fixtures passing,
fuzz smoke clean, dartdoc complete, CHANGELOG entry, benchmarks recorded on hot
paths.

### Dependencies

```mermaid
flowchart LR
    M0 --> M1 --> M2
    M1 --> M3 --> M5
    M1 --> M4 --> M5
    M2 --> M6
    M4 --> M6
    M5 --> M7
    M4 --> M8 --> M9 --> M10
    G{{provenance sign-off}} -.-> M9
```

M2/M3/M4 are independent after M1 (fixed order above, but slippage in one does not
block the others). M8's LZMA work has no dependency on ZIP milestones, only on
the codec infrastructure from M4's standalone-codec pattern.

### Release points

* **0.1.0** at M5: facade, core, codecs, tar, zip, gzip (CBZ/CBT support).
* **0.2.0** at M8: sevenz (CB7 support).
* **0.3.0** at M10: rar (CBR support). **Phase 1 complete (2026-07-15).**
* **0.4.0** at P2-4b: writing: TAR, ZIP, and 7z with the pure-Dart
  LZMA/LZMA2 encoder (CBT/CBZ/CB7 authoring). **Phase 2 write milestones
  complete (2026-07-15).** Git-only, not published to pub.dev.
* **0.5.0** at P3-5: reading password-protected archives across all
  formats (ZIP zipcrypto/AES, 7z AES, RAR5/RAR4 file encryption). **Phase 3
  complete (2026-07-15).** Git-only.
* **0.6.0**: write-side encryption (Phase 4: ZIP WinZip AES-256, 7z AES-256
  + `-mhe`), the 7z-reader `isEncrypted` fix, and the new `koni_http_source`
  package (remote reads over HTTP Range). **First release published to
  pub.dev (2026-07-15).**
* **0.7.0**: the RAR completeness track (R1–R9): RAR4 RarVM filters (standard
  + a generic interpreter), RAR5/RAR4 `-hp` encrypted headers, solid RAR4,
  multi-volume RAR (new `ArchiveReadOptions.nextVolume`), RAR4 PPMd variant H
  (solid + non-solid, incl. a mid-file PPMd→method-29 switch), and RAR 2.0/2.6
  (v20/v26) LZ. **RAR reading is essentially complete (2026-07-16).** Git-only.
* **0.8.0**: `ArchiveWriteOptions.allowUnsafePaths` (author a deliberately
  hostile-path archive as a Zip-Slip test fixture; ZIP/TAR/7z writers).
  Git-only.
* **0.9.0**: read-side decompression-bomb guards — `ArchiveReadOptions`
  `maxEntrySize` (per-entry decoded-byte cap; aborts a streamed decode) and
  `maxEntryCount` (declared-entry cap). Enforced at the
  `ArchiveFormat.openReader` seam (readers now override `createReader`), so no
  format or direct-reader path can bypass them; ZIP rejects an over-count
  directory before allocating it, and the layered-gzip open-time decode is
  capped too. **First item off the options backlog (2026-07-17).** Git-only.
* All packages stay 0.x with lockstep minor bumps until the API stabilizes.

---

## Phase 2: Writing

| #   | Milestone   | Scope (summary)                                   | Status |
| --- | ----------- | ------------------------------------------------- | ------ |
| P2-1 | Write API  | Format-agnostic `ArchiveWriter` abstraction       | ✅     |
| P2-2 | TAR write  | ustar + PAX emission, streaming input             | ✅     |
| P2-3 | ZIP write  | Stored + deflate compression, ZIP64               | ✅     |
| P2-4a | 7z write: container | Full write container + Copy/Deflate, no new codec | ✅     |
| P2-4b | 7z write: LZMA      | LZMA/LZMA2 encoder (range coder + match finder)   | ✅     |

Scope agreed in `koni_sevenz/doc/writing-scope.md` (commit to the LZMA path;
4a de-risks the container, 4b is the load-bearing encoder). RAR writing is
permanently out of scope.

---

## Phase 3: Encryption/password support, read side (scope in `doc/encryption-scope.md`)

| #    | Milestone            | Scope (summary)                                                    | Status |
| ---- | -------------------- | ------------------------------------------------------------------ | ------ |
| P3-1 | Crypto primitives    | AES, CBC/CTR, SHA-1, SHA-256, HMAC, PBKDF2 in koni_codecs; vector-tested on VM + dart2js + dart2wasm | ✅     |
| P3-2 | ZIP decryption       | zipcrypto + WinZip AE-1/AE-2; `password` read option + `InvalidPasswordException` in core | ✅     |
| P3-3 | 7z decryption        | AES-256 coder peeled ahead of the folder chain + encrypted headers (`-mhe`) | ✅     |
| P3-4 | RAR5 decryption      | File-data decryption (`-p`), PBKDF2 keys, check value, tweaked CRCs; `-hp` headers deferred (typed error, layout documented) | ✅     |
| P3-5 | RAR4 decryption      | Salted file data (iterated-SHA-1 KDF, AES-128), store + compressed; fixtures via rar 6.24; encrypted headers stay deferred | ✅     |

Release point: **0.5.0** at P3-5 (lockstep, git-only). **Phase 3 complete
(2026-07-15).** ZIP strong-encryption (SES) stays deferred; see the scope
doc.

---

## Phase 4: Encryption/password support, write side (scope in `doc/encryption-scope.md`)

| #    | Milestone       | Scope (summary)                                                  | Status |
| ---- | --------------- | ---------------------------------------------------------------- | ------ |
| P4-1 | ZIP encryption  | WinZip AES-256 (AE-2, method 99): per-entry salt, PBKDF2-HMAC-SHA1 keys, AES-CTR + HMAC-SHA1 tag, CRC zeroed | ✅     |
| P4-2 | 7z encryption   | AES-256-CBC file data: `compressor → AES` folder chain, iterated-SHA-256 KDF, per-folder IV; **plus `-mhe` encrypted headers** via `encryptHeader` | ✅     |

`ArchiveWriteOptions.password` (whole-archive, AES-256) drives both; add
`encryptHeader` for 7z `-mhe` (hides entry names). TAR rejects any password
(no standard encryption). Verified by self round-trip on VM + dart2js +
dart2wasm and by `7zz x -p` decrypting our output byte-for-byte (incl. `7zz
l -p` listing a hidden-header archive). Deferred: ZIP traditional zipcrypto
(write), ZIP AES-128/192 (write); see the scope doc.

---

## RAR completeness (post-0.6.0, depth-first)

Owner directive after the 0.6.0 pub.dev launch: make each already-shipped
format *excellent* before adding new formats, RAR first. Full RAR *reading*
support is the goal (RAR writing stays permanently out of scope). Agreed
order of attack:

| # | Item | Status |
| --- | --- | ------ |
| R1 | RAR4 RarVM **standard filters** (delta, x86 E8/E9, RGB, audio): unblocks 37 delta-filtered pages in the corpus | ✅ (byte-exact vs rar 6.24 on VM/dart2js/dart2wasm; conformance now 0 deferrals) |
| R2 | RAR5 `-hp` encrypted-header **read** | ✅ (per-block IV + block-key CBC headers; byte-exact vs rar 7.x on VM/dart2js/dart2wasm; wrong/no-password typed errors) |
| R3 | Solid RAR4 | ✅ (persistent tables/offset-cache/window across the run; byte-exact vs unrar on VM/dart2js/dart2wasm; fuzz-hardened) |
| R4 | Multi-volume (RAR4 + RAR5) | ✅ (`ArchiveReadOptions.nextVolume` resolver; split files reassembled across volumes; store + compressed, both versions, byte-exact vs unrar on VM/dart2js/dart2wasm) |
| R5 | RAR4 PPMd (variant H): the finale; large, no corpus coverage | ✅ (public-domain Ppmd7 model + RAR range decoder; byte-exact vs unrar/CRC from 82 B to 2.6 MB, order 2–63, mem 1–8 MB, non-solid **and solid**, on VM/dart2js/dart2wasm; fuzz-hardened. Only a mid-file PPMd→method-29 switch stays a typed error; see R8) |
| R6 | Custom (non-standard) RAR4 **RarVM** filter programs: a generic bytecode interpreter | ✅ (`rar4_vm.dart`: full pseudo-x86 VM adapted from the BSD Go `rardecode` `vm.go`/`filters.go`; standard set keeps its native fast path. Byte-exact by running the 4 standard programs (real RarVM bytecode) through the VM to the same `unrar`-checked fixtures, on VM/dart2js/dart2wasm; hand-assembled op-coverage test + fuzz-hardened. Filter-through-PPMd stays a typed error) |
| R7 | RAR4 **`-hp` encrypted headers** (read) | ✅ (per-block `salt[8]·AES-128-CBC(header)` with the RAR3 SHA-1 KDF; byte-exact vs `unrar`/CRC on VM/dart2js/dart2wasm, fuzz-hardened; wrong password → `InvalidPasswordException` via the 16-bit header CRC. Fixtures authored with rar 6.24. Multi-volume `-hp` threads the password but is unverified; no split fixture) |
| R8 | Mid-file **PPMd→method-29 (LZSS) block switch** (escape code 0) | ✅ (the switch decodes: the range decoder reads whole bytes through the shared bit-reader, so `_parseCodes` reads the block boundary the same way for either method; no read-ahead to undo. Byte-exact vs `unrar` on `ppmd_switch.rar` (VM/dart2js/dart2wasm), fuzz-hardened. Still typed errors: a filter *through* a PPMd escape (code 3) and a *solid*-run mid-file switch; no rar-6.24 fixture emits either, doubly rare) |
| R9 | **RAR 1.5 / 2.0** legacy unpack methods (v15/v20, incl. RAR2 multimedia/audio) | ✅ for **RAR 2.0 (v20) LZ**: byte-exact vs `unrar` on VM/dart2js/dart2wasm, fuzz-hardened; fixtures authored with DOS RAR 2.50 under DOSBox. v26 shares the v20 decoder but is untested (no fixture). Typed errors (no permissive reference, only GPL unrar): **v15** (RAR 1.5; `rardecode` returns `ErrUnsupportedDecoder`), the **multimedia/audio** block (`rardecode`'s decoder mis-decodes it vs `unrar`), and **solid v20 continuations** (run start still decodes; full solid-v20 decode deferred) |

The BSD Go `rardecode` reader (established as a clean-room reference in R5;
it, unlike libarchive, implements the whole RAR family) reopens the RAR
completeness track. It **lifts the license boundary** that had deferred the
generic RarVM interpreter (R6) and RAR4 `-hp` headers (R7): those were held back
because the only prior interpreter/`-hp` reference was the GPL unrar, and
`rardecode` is BSD-2-Clause. R8 (mid-file PPMd↔LZSS switch) and R9 (legacy
methods) are now reference-backed too. **R5–R9 have all landed**. The RAR
completeness track is essentially done. What remains are the small, doubly-rare
typed-error sub-cases with no authorable rar-6.24 fixture (a filter reached
*through* a PPMd escape; solid-run mid-file switch; the RAR 2.x audio block;
RAR 1.5 v15) and RAR *writing* (permanently out of scope). Separately,
`rardecode` is a second *independent* implementation (not
just the `unrar` black-box binary), worth a source-level cross-read to
re-verify the fiddly already-shipped paths (RAR5 filter math, the method-29
offset cache, the encryption KDFs) if a bug ever surfaces. RAR *writing* stays
permanently out of scope.

### R5: remaining typed error (resolved in R8)

The one RAR4 PPMd hole was a *mid-file* PPMd→method-29 (LZSS) block switch
(escape code 0 selecting an LZSS block); **R8 closed it** (see the R8 section).
Two doubly-rare sub-cases stay typed errors: a filter reached *through* a PPMd
escape (code 3) and a mid-file switch inside a *solid* PPMd run.

### R5: RAR4 PPMd (variant H), done (2026-07-16)

PPMd variant H (Dmitry Shkarin's PPMII, RAR's `-mct` "text compression") now
decodes. `rar4_ppmd.dart` ports the **public-domain** Ppmd7 codec (Igor Pavlov,
via libarchive's `archive_ppmd7.c`; a range decoder, an order-N context model
with SEE, a suffix-linked context tree, and a unit sub-allocator) with RAR's
range-decoder variant and escape-char dispatch adapted from libarchive's BSD
`rar.c`. Full detail in `koni_rar/doc/notes.md` ("RAR4 PPMd"); provenance in
`doc/references.md` + `NOTICE`.

* **Verified:** byte-exact vs `unrar`/CRC-32 from 82 B to 2.6 MB, order 2–63,
  memory 1–8 MB, non-solid and solid, on VM + dart2js + dart2wasm
  (`test/rar4_ppmd_web_test.dart`); fuzz-hardened (corrupt input → typed errors
  only, 100k+ iterations). Fixtures authored with **rar 6.24** live in
  `test/fixtures/rar_static/ppmd_rar4*.rar` and `solid_ppmd.rar` (the manga
  corpus never triggers PPMd, so these are the only oracle). This decoder even
  handles a stream libarchive 3.7.4 itself fails.
* **Solid PPMd** was closed after web research surfaced the BSD Go `rardecode`
  reader, which handles solid RAR (libarchive does not): each solid file is a
  PPMd block ending with an escape-code-2 marker, and the shared model + escape
  symbol carry across files (the escape resets only on flag 0x40). Verified on
  2–5-file runs incl. a 1-byte and 2×730 KB members.
* **Remaining typed error:** a *mid-file* PPMd→method-29 (LZSS) block switch
  (escape code 0 → an LZSS block); the PPMd↔LZSS loop hand-off is unimplemented.
  A code-0 to another PPMd block is handled. Rare. Needs `-mct` auto-mode over
  alternating text/non-text content.

### R6: Custom (non-standard) RAR4 RarVM filter programs, done (2026-07-16)

`rar4_vm.dart` (`RarVm`) is a full pseudo-x86 interpreter (8 registers, a 256 KiB
address space, C/Z/S flags, ~40 opcodes), so *any* method-29 filter program
decodes, not just the four fingerprinted standard ones. The standard set keeps
its native fast path in `rar4_filters.dart`; only a non-standard program falls
through to the VM. Full detail in `koni_rar/doc/notes.md` ("RAR4 RarVM generic
interpreter").

* **The unblock:** deferred until now **by license** (the only interpreter
  reference was the GPL unrar); the BSD-2-Clause Go `rardecode` `vm.go`/
  `filters.go` retired that boundary. Machine + opcode/flag semantics + program
  bit-decoding adapted from `vm.go`, the filter global-block wiring from
  `filters.go` (notice in `NOTICE`, attribution in `references.md`).
* **Verification: the standard programs are the oracle.** Modern rar can't
  author a non-standard filter program (the custom-filter mechanism is gone), so
  there is no bespoke fixture. Instead a test seam (`debugForceRar4Vm`) routes
  the four standard programs (which *are* real RarVM bytecode) through the VM
  and checks the same CRC-verified fixtures (byte-exact transitively vs `unrar`),
  on VM/dart2js/dart2wasm, incl. the multi-filter RGB+delta archive. A
  hand-assembled program covers the opcodes the standard set doesn't reach
  (`sar`/`adc`/`sbb`/`div`/`xor`/`and`/`or`); the standard programs already
  exercise the precision-sensitive `mul`/`shl`/`shr`/`neg`. Fuzz-hardened. The
  web gate caught a real dart2js trap (a 64-bit typed list for the shift table).
* **Deferred:** a filter reached *through* a PPMd escape; the generic VM can run
  any program, but the filter bytes arriving via the PPMd symbol stream are not
  wired into it (rare; folded into R8's PPMd hand-off work).

### R7: RAR4 `-hp` encrypted headers (read), done (2026-07-16)

RAR4 file-data decryption (`-p`, P3-5) already worked; `-hp` (encrypted
*headers*) now reads with a password too. The block headers are decrypted inline
during the container walk in `rar4_container.dart`
(`_parseRar4EncryptedHeaders`), reusing the RAR3 SHA-1 KDF + AES-128-CBC from
`-p`. Full detail in `koni_rar/doc/notes.md` ("RAR4 header encryption").

* **The framing (confirmed empirically, then cross-checked vs `rardecode`):**
  the marker and main header stay **plaintext**; the main header carries the
  `MHD_PASSWORD` flag (`0x0080`), which triggers the encrypted walk. Every block
  after it is `salt[8] · AES-128-CBC(header padded to 16)`, with the cipher
  **re-initialised per block** from the salt-derived IV (CBC chains only within a
  block; no clear IV, unlike RAR5). The salt is one archive-wide value repeated
  before each block (so the `0x40000`-round KDF is memoized). File **data** stays
  keyed by each file's own SALT-flag key (the existing `-p` path).
* **Wrong password:** RAR3/4 has no password-check value, so the 16-bit header
  CRC (`crc32(header[2:size]) & 0xFFFF`) is the signal; a first-block failure is
  `InvalidPasswordException` (a 16-bit CRC can't fully separate a bad password
  from corruption, so the message says both); a later-block failure after a clean
  first block is `InvalidHeaderException`. No password → `EncryptedArchiveException`.
* **Verified:** byte-exact vs `unrar`/CRC-32 on VM + dart2js + dart2wasm
  (`test/rar4_hp_web_test.dart`), fuzz-hardened (mutated `-hp` archives opened
  *with* the password → typed errors only). Fixtures `hp_rar4.rar` /
  `hp_rar4_store.rar` authored with **rar 6.24** live in `test/fixtures/rar_static/`.
* **Provenance:** framing adapted from the BSD Go `rardecode` (`archive15.go`
  `readBlockHeader`/`parseArcBlock`, `decrypt_reader.go`); libarchive's RAR4
  reader has no crypto.
* **Deferred:** RAR4 `-hp` over a *multi-volume* set; the password is threaded
  through per-volume parsing, but no split `-hp` fixture exists to verify it.

### R8: Mid-file PPMd→method-29 (LZSS) block switch, done (2026-07-16)

Escape code 0 inside a PPMd block reads a new block header; if it selects a
method-29 (LZSS) block, decoding now continues in LZSS mode instead of throwing.
Full detail in `koni_rar/doc/notes.md` (the PPMd "mid-file block switch"
subsection).

* **The "hard part" was not hard.** The worry was resuming the Huffman bit-reader
  "after the range decoder's read-ahead". But the PPMd range decoder reads whole
  bytes through the *same* shared bit-reader as the Huffman decoder, so there is
  no read-ahead to undo: at the block boundary `_decodePpmdStep` code-0 calls
  `_parseCodes`, which aligns to a byte, reads the block-type bit, and sets up
  either another PPMd block or an LZSS table block (flipping `_ppmdActive`); the
  main loop then dispatches on it. This one change also subsumes the code-0→PPMd
  path, and the reverse LZSS→PPMd switch already worked (method-29 symbol-256 →
  `_parseCodes`). Exactly `rardecode`'s unified `fill()`/`readBlockHeader()`
  structure.
* **Fixture:** authored `ppmd_switch.rar` with rar 6.24: `-ma4 -m5 -mc:1t` over
  ~62 KB of natural-ish text (forces a PPMd block boundary) + a repetitive binary
  block (rar's `-mct` auto-mode picks the general/LZSS method for it) + a short
  text tail. Verified: the switch actually fires (reverting the fix makes it
  throw), byte-exact vs `unrar` on VM/dart2js/dart2wasm, and fuzz-hardened.
* **Still typed errors** (no rar-6.24 fixture emits either; doubly rare): a
  filter reached *through* a PPMd escape (code 3; rar applies filters on the
  LZSS path, not inside a PPMd block, so this could not be authored to verify),
  and a mid-file switch inside a *solid* PPMd run (the shared solid loop has no
  LZSS path and rejects it cleanly).

### R9: RAR 1.5 / 2.0 legacy unpack methods

koni_rar decodes method-29 (unpack v29, RAR 2.9/3.x), the format essentially
every modern `.rar` uses. Older archives declare unpack version 15 (RAR 1.5),
20 (RAR 2.0), or 26 (RAR 2.6), which use different LZ/Huffman schemes and, for
v20/v26, a multimedia/audio filter. R9 adds **v20/v26 LZ** decoding
(done 2026-07-16).

* **Container:** the v1.5 container was already parsed but discarded the
  unpack-version byte and hardcoded v29; it now preserves it
  (`Rar5FileHeader.unpackVersion`, distinct from the `version` family marker so
  RAR4/RAR5 decoder dispatch is untouched).
* **Decoder:** `rar20_decoder.dart` (`Rar20Decoder`): v20/v26 LZSS with the
  main/offset/length Huffman tables, adapted from the BSD `rardecode`
  (`decode20.go`/`decode20_lz.go`). The bit-reader and canonical Huffman decoder
  were factored into a shared `rar_bits.dart` (`Bits`/`Huffman`) reused by the
  method-29 and v20 decoders; the LZ base tables are the standard RAR tables.
* **Fixtures (the unblock):** no tool on the build machine authors v20 (rar ≥3
  writes v29; rar 2.x is 32-bit i386 that Rosetta 2 can't run), and no permissive
  test corpus exists. Solved by running **DOS RAR 2.50** (rarlab `rar250.exe`,
  extracted with `unrar`) under **DOSBox** (`brew install dosbox`, headless via
  `SDL_VIDEODRIVER=dummy`); `unrar` is the byte-exact oracle. Verified byte-exact
  on VM + dart2js + dart2wasm (`test/rar2_web_test.dart`,
  `rar_static/rar2_*.rar`); fuzz-hardened.
* **v26 (RAR 2.6):** routes to the same decoder (`rardecode` maps `case 20, 26`
  together) but is **untested**; DOS RAR 2.50 authors only v20, so there is no
  v26 fixture to verify against.
* **Typed errors (reference-bounded):** the **multimedia/audio** block:
  `rardecode`'s audio predictor mis-decodes it (verified: rardecode itself fails
  the audio fixture's CRC vs `unrar`), so no correct permissive reference exists;
  **v15 (RAR 1.5)**: `rardecode` returns `ErrUnsupportedDecoder`, libarchive is
  v29-only (only the GPL unrar has either); and **solid v20 continuations**: a
  solid run's first file decodes via the non-solid path, but continuations would
  misroute to the method-29 solid path, so they are rejected cleanly (full
  solid-v20 decode deferred: doubly rare). Store (method 0) is version-agnostic
  and decodes at any version.
* **Value:** breadth: vintage `.rar` files. Rare in practice (the manga corpus
  and any modern archive are v29/v50).

## Deferred backlog (typed errors today; candidates for post-Phase-1)

Roughly in expected demand order:

* ~~Encryption/password support (ZIP AES/zipcrypto, 7z AES, RAR)~~ → **Phase 3 above**
* ~~Write-side encryption (ZIP AES, 7z AES)~~ → **Phase 4 above**
* ~~7z reader: set `entry.isEncrypted` on parse~~ → done (matches the ZIP
  reader; the entry's folder-has-AES flag)
* Sequential (non-seekable) input for TAR/gzip
* ~~HTTP-range `ByteSource` package (remote CBZ page reads)~~ → done
  (`koni_http_source`: `HttpRangeByteSource`, `package:http` + injectable
  fetcher seam, `If-Range` guard; verified against a real `dart:io`
  `HttpServer`)
* gzip seek-index (zran-style) for random access into `.tar.gz`
* 7z BCJ2, PPMd
* GNU sparse tars
* Multi-volume archives: **done for RAR** (R4 above, via `nextVolume`); 7z/ZIP spanning still deferred
* New formats via the registry: XZ, BZip2/tar.bz2, CPIO, ISO, CAB, …

## Options backlog (post-0.8.0)

Additive `ArchiveReadOptions`/`ArchiveWriteOptions` surface. An option is
permanent public API and a 0.x minor costs one bump, so nothing here lands
speculatively: each waits for a concrete caller. (`allowUnsafePaths`, 0.8.0,
is the pattern: it shipped because konimanga's Zip-Slip test needed a hostile
fixture the safe writer refuses to author.)

* ~~**Read: decompression-bomb limits (`maxEntrySize`, `maxEntryCount`).**~~ →
  **shipped in 0.9.0.** Was the highest-value gap and a promise the code did
  not keep: the only size limit was `Archive.readBytes(maxSize:)`, a per-call
  parameter on the *convenience* method, while streaming through `openRead`
  (recommended "for anything large") was unbounded. `maxEntrySize` now bounds
  every streamed entry and `maxEntryCount` the directory-bomb variant.
  **On the scope note** ("enforcement must live in every reader, not only the
  facade, or a direct `ZipFormat().openReader(...)` bypasses it"): solved once,
  not per-reader, by making `ArchiveFormat.openReader` a concrete template that
  wraps the reader and delegating the format-specific parse to a new
  `createReader` override — so the guard is unbypassable *and* free for
  third-party formats, without threading a limit through five decoders. ZIP
  additionally rejects an over-count directory before allocating it; the
  layered-gzip open-time decode is capped by reading only the ISIZE trailer.
  Motivating consumer: konimanga (untrusted CBZ/CBR).

* **Write: compression level.** `ArchiveWriteOptions.compression` selects a
  *method*, never an effort level, and `DeflateEncoder` is const with no level.
  The knob already exists hardcoded: `RawDeflater._maxChain = 128` ("hash-chain
  search depth (ratio vs speed)"), so a coarse fast/default/best could thread
  it through. Honest zlib-style 1-9 levels are more than chain depth alone
  (lazy-match thresholds too), so prefer the coarse triple unless a caller
  needs zlib parity. Motivating case: konimanga's full backups (pages
  included) are large enough for speed-vs-size to matter, but nobody has hit
  it yet, hence deferred.

# Changelog

## 0.7.0 (2026-07-16)

Post-0.6.0 RAR completeness track (R1–R9): the reader now handles nearly the
whole RAR4 family. Highlights below (RAR *writing* stays out of scope).

- **RAR4 mid-file PPMd→method-29 (LZSS) block switch (R8)** — a `-mct` auto-mode
  archive that flips compression method mid-file (PPMd escape code 0 selecting an
  LZSS block) now decodes; it was a typed error before. The fix is small: the
  PPMd range decoder reads whole bytes through the *same* shared bit-reader as
  the Huffman decoder, so at the block boundary the decoder just aligns to a byte
  and reads the block-type bit (`_parseCodes`), and the LZSS decoder resumes from
  there — no range-decoder read-ahead to undo (mirroring the BSD Go `rardecode`'s
  unified `fill()`/`readBlockHeader()` loop). Byte-exact vs `unrar` on a fixture
  that starts in PPMd and switches to LZSS mid-file (`ppmd_switch.rar`, authored
  with rar 6.24), on VM + dart2js + dart2wasm; fuzz-hardened. Still typed errors
  (no rar-6.24 fixture emits them, doubly rare): a filter reached *through* a
  PPMd escape (code 3), and a mid-file switch inside a *solid* PPMd run.

- **RAR4 generic RarVM filter interpreter (R6)** — any method-29 filter program
  now decodes, not just the four fingerprinted standard ones (delta, x86 E8/E9,
  RGB, audio), which previously left a non-standard program a typed error.
  `rar4_vm.dart` is a full pseudo-x86 interpreter (8 registers, a 256 KiB
  address space, C/Z/S flags, ~40 opcodes) adapted from the BSD Go `rardecode`
  (`vm.go`/`filters.go`); the standard set keeps its native fast path. Verified
  byte-exact by routing the four standard programs — which *are* real RarVM
  bytecode — through the interpreter to the same CRC-checked fixtures (`unrar`
  the oracle; modern rar can't author a non-standard program), plus a
  hand-assembled program covering the opcodes the standard set doesn't reach,
  on VM + dart2js + dart2wasm; fuzz-hardened. All arithmetic is masked to 32
  bits (a split-halves multiply and a power-of-two shift table keep it exact on
  the web). Remaining typed error: a filter reached *through* a PPMd escape (the
  filter bytes arrive via the PPMd symbol stream, unwired).

- **RAR4 encrypted headers (`rar -ma4 -hp`, read)** now decode with
  `ArchiveReadOptions.password` (previously a typed error) — the whole archive,
  including entry names and sizes, is locked, so listing itself needs the
  password. The block headers are decrypted inline during the container walk
  (`rar4_container.dart`): after the plaintext marker + main header (which
  carries the `MHD_PASSWORD` flag), each following block is
  `salt[8] · AES-128-CBC(header padded to 16)` with the cipher re-initialised
  per block from the salt-derived IV, reusing the RAR3 SHA-1 KDF + AES-128
  already built for `-p`; file data between headers stays keyed by each file's
  own salt (the existing `-p` path). RAR4 has no password-check value, so a
  wrong password is caught by the 16-bit header CRC and reported as
  `InvalidPasswordException` (no password → `EncryptedArchiveException`).
  Byte-exact vs `unrar` on VM + dart2js + dart2wasm; fuzz-hardened. Framing
  cross-checked against the BSD Go `rardecode` (`archive15.go` /
  `decrypt_reader.go`) — libarchive's RAR4 reader has no crypto. Fixtures
  authored with rar 6.24 (7.x cannot create v4). Multi-volume `-hp` threads the
  password per volume but is unverified (no split `-hp` fixture).

- **RAR 2.0** (unpack version 20) **LZ** decoding — vintage `.rar` files now read
  (previously a misleading corruption error). `rar20_decoder.dart` is a
  clean-room LZSS+Huffman decoder adapted from the BSD Go `rardecode`
  (`decode20.go`/`decode20_lz.go`); the container now preserves the real
  unpack-version byte (`unpackVersion`, separate from the RAR4/RAR5 family
  marker), and the shared bit-reader/Huffman were factored into `rar_bits.dart`.
  Byte-exact vs `unrar` on VM + dart2js + dart2wasm; fuzz-hardened. Fixtures were
  authored with DOS RAR 2.50 under DOSBox (no modern tool writes v20). Store
  decodes at any version. **v26** (RAR 2.6) routes to the same decoder but is
  untested (DOS RAR 2.50 authors only v20). Reference-bounded typed errors: RAR
  1.5 (unpack v15), the RAR 2.x multimedia/**audio** block (no correct permissive
  reference — only the GPL unrar), and *solid* v20 continuations (the run's first
  file still decodes) — all raise `UnsupportedFeatureException`.

- **RAR4 PPMd (variant H)** — RAR's `-mct` "text compression" — now decodes
  (previously a typed error). `rar4_ppmd.dart` ports the public-domain Ppmd7
  codec (Igor Pavlov, via libarchive's `archive_ppmd7.c`): a range decoder, an
  order-N context model with SEE, a suffix-linked context tree, and a unit
  sub-allocator, with RAR's range-decoder variant and escape-char dispatch
  adapted from libarchive's BSD `rar.c`. No unrar or GPL source was consulted.
  All range-coder arithmetic is masked to 32 bits, so decoding is byte-exact on
  VM + dart2js + dart2wasm. Verified vs `unrar`/CRC-32 from 82 B to 2.6 MB,
  order 2–63, memory 1–8 MB; fuzz-hardened (corrupt input → typed errors only).
  **Solid** PPMd runs decode too: the run shares one model, escape symbol, and
  window across its files, each a PPMd block ending with an escape-code-2 marker
  (control flow adapted from the BSD Go `rardecode` reader, which libarchive —
  with no solid-RAR support — cannot supply; the model stays the same
  public-domain Ppmd7). Verified byte-exact vs unrar on 2–5-file runs incl. a
  1-byte and 2×730 KB members. One case stays a typed error: a *mid-file*
  PPMd→method-29 block switch (rare; needs `-mct` auto-mode over alternating
  text/non-text content).

- **Multi-volume RAR** sets (both RAR4 and RAR5) now read, when the caller
  supplies the other volumes via the new `ArchiveReadOptions.nextVolume`
  resolver (volume 1 is the source passed to the reader; later volumes are
  requested by number). A file split across volumes is reassembled by
  concatenating its per-volume packed segments and decoding the whole — store
  and compressed alike. The full-file CRC is taken from the final segment's
  header. A missing continuation volume → `UnexpectedEofException`; a
  multi-volume archive opened without a resolver → `UnsupportedFeatureException`.
  Verified byte-exact vs `unrar` (store + compressed, both versions) on VM +
  dart2js + dart2wasm (`test/rar_multivolume_test.dart`).

- **Solid RAR4** archives now decode (previously a typed error). One decoder
  carries the Huffman tables, repeated-offset cache, and window across the
  run — only the run's first compressed file parses a table block; later
  files reuse it — with each file's output kept for repeat/out-of-order
  reads. Verified byte-exact (sha256) against `unrar` on a cross-referencing
  five-file run on VM + dart2js + dart2wasm (`test/rar4_solid_test.dart`,
  `rar_static/solid_rar4.rar`); a fuzz-found partial-table crash on mutated
  input was fixed along the way (both hardened via the fuzz pool).

- RAR5 **encrypted headers** (`rar -hp`) now read with a password via
  `ArchiveReadOptions.password` (previously a typed error at open). The crypt
  header keys every following header block — each carries a clear 16-byte IV
  and is AES-256-CBC-decrypted, padded to 16 bytes — while file data stays
  encrypted only by its own per-file record. Wrong password →
  `InvalidPasswordException`; no password → `EncryptedArchiveException`. Also
  fixed the encrypted-file CRC tweak to key off the record's "use MAC" flag
  (bit 1) rather than the password-check flag (bit 0), which `-hp` sets
  independently. Adapted clean-room from the Go `rardecode` block framing
  (BSD; `doc/references.md`); verified byte-exact against `rar 7.x`-authored
  store and compressed fixtures on VM + dart2js + dart2wasm
  (`test/rar5_hp_test.dart`). (RAR4 `-hp` also reads in this release — see the
  R7 entry above.)

- RAR4 (method-29) now decodes the **RarVM standard filters** RAR's
  compressor auto-applies — delta, x86 E8, x86 E8/E9, RGB, and audio — so
  archives that use them read correctly instead of throwing
  `UnsupportedFeatureException` on those entries. Recognized by program
  fingerprint and run natively, adapted from libarchive's BSD `rar.c`
  (clean-room; see `doc/rar-provenance.md`). Custom (non-standard) VM
  programs remain a typed error (license-bounded: the only generic-interpreter
  reference is GPL unrar).
  - Verified byte-exact against genuine rar 6.24 output on VM + dart2js +
    dart2wasm (`test/fixtures/rar_static/filter_*.rar`,
    `test/rar4_filters_test.dart`), and the local corpus conformance now
    decodes all of the delta-filtered volume to unrar's sha256 with zero
    deferred entries.

## 0.6.0 (2026-07-15)

- Lockstep release with Phase 4 (write-side encryption for ZIP/7z); no
  changes to koni_rar (RAR writing is permanently out of scope). First
  release published to pub.dev.

## 0.5.0 (2026-07-15)

- P3-4/P3-5: RAR file decryption via `ArchiveReadOptions.password`.
  - RAR5 (`-p`): AES-256-CBC, the iterated-HMAC-SHA256 KDF, the 8-byte
    password-check value (reliable wrong-password signal), and hash-key-
    tweaked CRC verification — store, compressed, and solid.
  - RAR4 (`-ma4 -p`): AES-128-CBC with the bespoke RAR3 SHA-1 KDF
    (`0x40000` rounds, header salt); the plaintext CRC is verified, and a
    wrong password surfaces as a CRC mismatch (no check value exists).
  - Clean-room per `doc/rar-provenance.md`; verified byte-exact against
    `rar`-authored fixtures (RAR4's via rar 6.24, since 7.x cannot author
    v4). Green on VM + dart2js + dart2wasm.
  - Encrypted headers (`-hp`) stay a typed error; the RAR5 layout is
    reverse-engineered and documented in `doc/notes.md`.

## 0.4.0 (2026-07-15)

- Lockstep release; no changes since 0.3.0.

## 0.3.0 (2026-07-15)

- M10: RAR4 (v1.5) reader — **the real-world CBR flagship**.
  - Container: v1.5 base blocks, MAIN/FILE/ENDARC headers, store + the
    method-29 (v2.9/v3+) LZSS+Huffman codec, non-solid.
  - Clean-room decoder (owner-approved provenance): four canonical Huffman
    codes from a precode, repeated-offset cache, short/long matches —
    verified byte-identical to `unrar` against the owner's real CBR corpus.
  - PPMd, RarVM filters, and solid RAR4 are typed errors (the corpus uses
    none of them except one filtered double-page spread, which surfaces as
    a per-entry unsupported-feature error while the rest of the archive
    still reads).
- M9: RAR5 reader — clean-room LZ + Huffman literals, distance cache,
  delta/x86/ARM filters; store and methods 1–5, solid and non-solid.
  Container, extra records (encryption, REDIR symlinks), UTF-8 names,
  mtime, unix modes. CBR (v5) works; multi-volume/encrypted are typed
  errors. §7 hardened (size caps, uniform integer cap, permissive UTF-8,
  fuzz smoke).

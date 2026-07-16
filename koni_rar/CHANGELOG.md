# Changelog

## Unreleased

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
  (`test/rar5_hp_test.dart`). RAR4 `-hp` stays a documented deferral.

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

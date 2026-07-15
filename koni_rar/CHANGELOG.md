# Changelog

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

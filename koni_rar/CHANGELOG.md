# Changelog

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

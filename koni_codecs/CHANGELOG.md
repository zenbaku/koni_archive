# Changelog

## 0.2.0 (2026-07-15)

- M8: LZMA (`LzmaDecoder`), LZMA2 (`Lzma2Decoder`), and branch filters
  (`deltaDecode`, `bcjX86Decode`) — implemented from the public-domain
  LZMA specification, differential-tested against liblzma (CPython
  vectors), chunk-driven with buffer-backed windows.

## 0.1.0 (2026-07-15)

- M4: inflate + gzip codecs.
  - `InflateDecoder` (raw DEFLATE, RFC 1951): chunk-driven synchronous
    state machine, vector-tested standalone (CPython-zlib references,
    degenerate dynamic Huffman, stored-block boundaries, dart:io zlib
    differential), with an inflate_fast-style hot loop (bench recorded).
  - `GzipDecoder` (RFC 1952): multi-member, FNAME/FEXTRA/FCOMMENT/FHCRC,
    per-member CRC-32 + ISIZE verification, gzip(1)-compatible
    trailing-garbage tolerance.
  - Resumable engines (`RawInflater`, `RawGzipDecoder`) exported for
    framing layers.
- M1: `BitReader` — LSB-first (DEFLATE bit order) bit cursor over byte
  buffers, with byte alignment and aligned whole-byte reads. Malformed
  input throws `FormatException` (the package's documented error idiom;
  see `doc/notes.md`).
- M0: package scaffolding — pub workspace membership, shared strict lints,
  CI matrix (VM on Linux/macOS/Windows; web via dart2js and dart2wasm).

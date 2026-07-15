# Changelog

## 0.4.0-dev (unreleased)

- P2-4b: LZMA/LZMA2 compression — `LzmaEncoder`, `Lzma2Encoder`, and the
  carry-aware `RangeEncoder`, the encode direction of the M8 decoders
  (identical probability-model layout, lockstep updates). Hash-chain match
  finder over an input-scaled table with rep-distance matches and a
  one-step lazy heuristic (7-Zip fast-mode shape; optimal parsing is a
  deferred ratio lever). LZMA2 framing with per-chunk range-coder restart,
  uncompressed-chunk fallback for incompressible spans, and state-reset
  resynchronization. Buffer-based one-shot API mirroring the decoders (the
  input buffer is the window). Output is byte-identical on VM, dart2js,
  and dart2wasm (golden-pinned) and decodes under liblzma (CPython
  interop: FORMAT_ALONE for LZMA1, FORMAT_RAW for LZMA2) and our own
  decoders; ratio lands within ~1 point of liblzma preset 6 on repo docs
  (bench recorded).

- P2-3: `DeflateEncoder` (raw DEFLATE, RFC 1951) — the compression
  counterpart of `InflateDecoder`, added for the ZIP writer. Greedy LZ77
  (hash-chain matching) with fixed-Huffman blocks, ≤ 32 KiB blocks (bounded
  memory, no cross-block matches). dart:convert `Converter` idiom (one-shot
  or `startChunkedConversion`) over the resumable `RawDeflater` engine.
  Output is universally decodable — differential-tested against `dart:io`
  zlib and Info-ZIP `unzip`, not just our own inflater. Ratio improvements
  (lazy matching, dynamic Huffman) are deferred; correctness and portability
  (VM/dart2js/dart2wasm) come first. Bench recorded in bench/results/.

## 0.3.0 (2026-07-15)

- Lockstep release; no changes since 0.2.0.

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

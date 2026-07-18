# Changelog

## 0.10.0 (2026-07-18)

- Adds a **bzip2 encoder** (`Bzip2Encoder`) and a **Zstandard encoder**
  (`ZstdEncoder`), the encode directions of the new decoders. `Bzip2Encoder`
  runs the full pipeline (RLE1 → BWT → MTF/RLE2 → length-limited Huffman → `BZh`
  framing) with a deterministic rotation sort. `ZstdEncoder` writes a single
  frame of LZ sequences over the predefined FSE tables (a from-scratch tANS
  encoder) with Huffman literals (direct-weight table, falling back to raw for
  byte alphabets over 128 or when it does not beat raw). Both are byte-decodable
  by `bzip2` / `zstd` and byte-identical across the VM, dart2js, and dart2wasm.
- Fixes the Zstandard decoder's compressed-literals **sizeFormat-3** size parse:
  it built one 36-bit value with a `<< 28` shift that truncates to 32 bits on
  dart2js, corrupting `Compressed_Size` for large Huffman literal blocks; each
  size is now assembled from `< 2^18` bit fields.
- Adds a **Zstandard decoder** (`ZstdDecoder`, a `dart:convert` `Converter`, and
  the resumable `RawZstdDecoder`): the full RFC 8878 format — frame/block
  framing, FSE (tANS) and Huffman entropy coding, sequences with the three
  repeat offsets, back-reference matches (overlapping copies included),
  concatenated and skippable frames, and XXH64 content-checksum verification
  (on native 64-bit platforms; skipped under dart2js/dart2wasm). Dictionary and
  legacy-v0.x frames are typed errors. `RawZstdDecoder` is pull-based
  (`addInput` → `close` → `nextBlock`) with a mandatory 128 MiB window cap.
  Backs the new `koni_zstd` package.
- Adds a **bzip2 decoder** (`Bzip2Decoder`, a `dart:convert` `Converter`, and
  the resumable `RawBzip2Decoder`): the full format (`BZh1`–`BZh9`) — MSB-first
  bit stream, per-group Huffman, MTF/RLE2, inverse BWT, RLE1, and the
  CRC-32/BZIP2 block/stream checks — with concatenated streams. `RawBzip2Decoder`
  is pull-based (`addInput` → `close` → `nextBlock`), so callers decode one
  ≤ 900 KiB block at a time. Backs the new `koni_bzip2` package as well as ZIP
  method 12 and 7z's BZip2 coder.

## 0.9.0 (2026-07-17)

- Lockstep release; no changes to this package since 0.8.0.

## 0.8.0 (2026-07-16)

- Lockstep release; no changes to this package since 0.7.0.

## 0.7.0 (2026-07-16)

- Lockstep release; no changes to this package since 0.6.0.

## 0.6.0 (2026-07-15)

- No code changes; the AES/CBC/CTR/SHA/HMAC/PBKDF2 primitives (`crypto.dart`)
  are now used by the write side too (7z AES-256, ZIP WinZip AES). Docs
  updated from "read" to "read and write"; the non-constant-time /
  no-zeroization caveats are unchanged.
- First release published to pub.dev.

## 0.5.0 (2026-07-15)

- P3-1: cryptographic primitives for the Phase 3 decryption work, in the
  new `package:koni_codecs/crypto.dart` entrypoint: AES-128/192/256 (T-table,
  encrypt + decrypt), CBC and the WinZip little-endian CTR mode, SHA-1,
  SHA-256, HMAC, and PBKDF2. Zero-dependency, standards-defined
  (FIPS-197, SP 800-38A, FIPS 180-4, RFC 2104/8018), vector-tested, and
  dart2js/dart2wasm-exact. Not constant-time (archive reading, not a TLS
  stack), documented as such.

## 0.4.0 (2026-07-15)

- P2-4b: LZMA/LZMA2 compression: `LzmaEncoder`, `Lzma2Encoder`, and the
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

- P2-3: `DeflateEncoder` (raw DEFLATE, RFC 1951), the compression
  counterpart of `InflateDecoder`, added for the ZIP writer. Greedy LZ77
  (hash-chain matching) with fixed-Huffman blocks, ≤ 32 KiB blocks (bounded
  memory, no cross-block matches). dart:convert `Converter` idiom (one-shot
  or `startChunkedConversion`) over the resumable `RawDeflater` engine.
  Output is universally decodable, differential-tested against `dart:io`
  zlib and Info-ZIP `unzip`, not just our own inflater. Ratio improvements
  (lazy matching, dynamic Huffman) are deferred; correctness and portability
  (VM/dart2js/dart2wasm) come first. Bench recorded in bench/results/.

## 0.3.0 (2026-07-15)

- Lockstep release; no changes since 0.2.0.

## 0.2.0 (2026-07-15)

- M8: LZMA (`LzmaDecoder`), LZMA2 (`Lzma2Decoder`), and branch filters
  (`deltaDecode`, `bcjX86Decode`), implemented from the public-domain
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
- M1: `BitReader`, LSB-first (DEFLATE bit order) bit cursor over byte
  buffers, with byte alignment and aligned whole-byte reads. Malformed
  input throws `FormatException` (the package's documented error idiom;
  see `doc/notes.md`).
- M0: package scaffolding: pub workspace membership, shared strict lints,
  CI matrix (VM on Linux/macOS/Windows; web via dart2js and dart2wasm).

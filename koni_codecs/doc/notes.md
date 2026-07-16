# koni_codecs: implementation notes

Decisions made where the format left room.

## Error idiom: `FormatException` (M1)

The zero-dependency policy forbids `koni_codecs` from depending on any package,
including `koni_archive_core`, so the typed `ArchiveException` hierarchy is out of
reach here. Codecs follow the `dart:convert` idiom instead: malformed input
throws `FormatException`. Format packages translate that into
`CorruptArchiveException` (with format/offset/entry context) at the archive
boundary, preserving the fuzz invariant.

## Bit order (M1)

`BitReader` is LSB-first, DEFLATE's (RFC 1951) bit order. An MSB-first
reader will be added only when a codec that needs one lands (no speculative
code).

## Inflate (M4)

- Chunk-driven resumable state machine (`RawInflater`): input may split at
  any byte boundary; suspension points cover every read. Public codec
  surface is `InflateDecoder` (dart:convert `Converter` idiom).
- Bit buffer invariant: ≤ 23 bits between fills, so every shift stays below
  2^31, portable to dart2js's 32-bit bitwise ops.
- Huffman completeness rules match zlib: the code-length tree must be
  complete; literal/distance trees may be a degenerate single code;
  distance trees may be empty. Oversubscription is always fatal.
- Output: 64 KiB chunks; the 32 KiB history window is refreshed in bulk at
  flush time (not per byte), and a fast decode loop with local-cached bit
  state runs while ≥ 8 input bytes and ≥ 258 output bytes of slack are
  guaranteed (zlib's inflate_fast idea). See bench/results for numbers.
- `takeLeftoverBytes` returns whole input bytes buffered past the stream
  end after discarding the final byte's bit padding; this is how framing
  layers (gzip, ZIP) locate their trailers.

## Gzip framing (M4)

- Multi-member files decode as concatenated output; each member's
  CRC-32 and ISIZE are verified by default. Trailing bytes that do not
  start with the gzip magic are ignored, matching gzip(1); a truncated
  *member* is always an error.
- Member headers are capped at 1 MiB (FEXTRA/FNAME/FCOMMENT are
  attacker-controlled). FHCRC is verified when present.
- This package duplicates a private CRC-32 (1 KiB table): the zero-
  dependency policy forbids using koni_archive_core's.

## Deflate encoding (P2-3)

The compression counterpart of the M4 inflater, added for the ZIP writer.
`DeflateEncoder` (dart:convert `Converter`, one-shot or `startChunkedConversion`)
sits over the resumable `RawDeflater` engine, mirroring the decode side.

- **Correctness before ratio.** Greedy LZ77 (hash-chain match finding,
  chain depth 128) emitting *fixed*-Huffman blocks. Fixed codes were chosen
  over dynamic because they need no two-pass frequency counting and no
  code-length tree emission, and they decode everywhere. Output is
  universally decodable, verified against `dart:io`'s zlib and Info-ZIP
  `unzip`, not just our own inflater.
- **≤ 32 KiB blocks, no cross-block matches.** Input is buffered into 32 KiB
  blocks; matches are only sought within the current block, so every match
  distance stays < 32768 (the DEFLATE window) by construction and memory is
  bounded regardless of input size. The cost is ratio at block seams, an
  explicitly deferred improvement, not a correctness gap.
- **LSB-first bit writer.** `_BitWriter` accumulates bits low-to-high (RFC
  1951 order); Huffman codes are pre-reversed into LSB-first form at table
  build time. The accumulator invariant keeps every value < 2^24 (bitCount
  < 8 before each write, value < 2^16), which dart2js's 32-bit bitwise ops
  model exactly, the same portability discipline as the inflate bit buffer.
- **Deferred ratio levers (not correctness):** lazy matching, dynamic
  Huffman blocks, cross-block matching, and a stored-block fallback for
  incompressible runs. Callers storing already-compressed data (CBZ images)
  sidestep the last one at the ZIP layer by selecting `stored` per entry.
  See `bench/results/2026-07-15-p2-3-deflate-encode-*` for the measured
  speed/ratio tradeoff versus package:archive and native zlib.

## Test vector provenance

Static vectors in `test/src/vectors.dart` were generated with CPython's
zlib module (`zlib.compressobj(level, zlib.DEFLATED, -15)`) and hand-framed
gzip members; the VM differential suite generates fresh vectors from
`dart:io`'s ZLibCodec on every run. Degenerate-Huffman and corruption
vectors are hand-rolled bit streams (see inflate_test.dart).

## LZMA / LZMA2 / branch filters (M8)

- Implemented from the public-domain LZMA specification (LzmaSpec.cpp /
  lzma-specification.txt, LZMA SDK). Differential-tested against liblzma
  through CPython's `lzma` module (FORMAT_ALONE, FORMAT_RAW LZMA2,
  FILTER_DELTA, FILTER_X86 pipelines).
- Archive containers always know output sizes, so `LzmaDecoder` /
  `Lzma2Decoder` write into a caller-provided buffer that doubles as the
  match window (no separate window management). Input is chunk-driven with
  suspension at symbol boundaries (64-byte starvation guard), the
  chunked model; the `Converter` facade is deferred until a standalone
  `.lzma`/`.xz` consumer exists.
- Range-coder arithmetic stays within unsigned 32-bit (explicit masks),
  portable to dart2js.
- `bcjX86Decode`/`deltaDecode` operate in place on whole buffers (folders
  decode as units in 7z); the BCJ algorithm follows the public-domain
  Bra86/xz-embedded reference and is vector-verified against liblzma.

Regeneration of LZMA vectors: see `test/src/lzma_vectors.dart` header
(CPython `lzma.compress` invocations are documented per vector).

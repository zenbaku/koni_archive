# koni_codecs — implementation notes

Decisions made where PROMPT_V1.md leaves room (recorded per §13.3).

## Error idiom: `FormatException` (M1)

§2 forbids `koni_codecs` from depending on any package — including
`koni_archive_core`, so the typed `ArchiveException` hierarchy is out of
reach here. Codecs follow the `dart:convert` idiom instead: malformed input
throws `FormatException`. Format packages translate that into
`CorruptArchiveException` (with format/offset/entry context) at the archive
boundary, preserving the §7 fuzz invariant.

## Bit order (M1)

`BitReader` is LSB-first — DEFLATE's (RFC 1951) bit order. An MSB-first
reader will be added only when a codec that needs one lands (no speculative
code, §13.1).

## Inflate (M4)

- Chunk-driven resumable state machine (`RawInflater`): input may split at
  any byte boundary; suspension points cover every read. Public codec
  surface is `InflateDecoder` (dart:convert `Converter` idiom, §6.4).
- Bit buffer invariant: ≤ 23 bits between fills, so every shift stays below
  2^31 — portable to dart2js's 32-bit bitwise ops.
- Huffman completeness rules match zlib: the code-length tree must be
  complete; literal/distance trees may be a degenerate single code;
  distance trees may be empty. Oversubscription is always fatal.
- Output: 64 KiB chunks; the 32 KiB history window is refreshed in bulk at
  flush time (not per byte), and a fast decode loop with local-cached bit
  state runs while ≥ 8 input bytes and ≥ 258 output bytes of slack are
  guaranteed (zlib's inflate_fast idea). See bench/results for numbers.
- `takeLeftoverBytes` returns whole input bytes buffered past the stream
  end after discarding the final byte's bit padding — this is how framing
  layers (gzip, ZIP) locate their trailers.

## Gzip framing (M4)

- Multi-member files (§8) decode as concatenated output; each member's
  CRC-32 and ISIZE are verified by default. Trailing bytes that do not
  start with the gzip magic are ignored, matching gzip(1); a truncated
  *member* is always an error.
- Member headers are capped at 1 MiB (FEXTRA/FNAME/FCOMMENT are
  attacker-controlled, §7). FHCRC is verified when present.
- This package duplicates a private CRC-32 (1 KiB table): the zero-
  dependency policy (§2) forbids using koni_archive_core's.

## Test vector provenance (§11, §13.7)

Static vectors in `test/src/vectors.dart` were generated with CPython's
zlib module (`zlib.compressobj(level, zlib.DEFLATED, -15)`) and hand-framed
gzip members; the VM differential suite generates fresh vectors from
`dart:io`'s ZLibCodec on every run. Degenerate-Huffman and corruption
vectors are hand-rolled bit streams (see inflate_test.dart).

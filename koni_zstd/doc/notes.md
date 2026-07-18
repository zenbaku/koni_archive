# koni_zstd: implementation notes

Decisions made where the Zstandard format left room.

## The codec lives in koni_codecs

Zstandard decoding is a general codec (`RawZstdDecoder` / `ZstdDecoder` in
`koni_codecs`), not archive-specific. This package is only the container glue —
detection, the single-entry adapter, and `.tar.zst` layering — mirroring
`koni_gzip` / `koni_xz` / `koni_bzip2`. See `koni_codecs`' zstd source for the
decode pipeline (frame/block framing, FSE, Huffman, sequences, XXH64).

## No guaranteed size

Zstandard *may* record a frame content size, but a stream can omit it and a
`.zst` may hold several frames. Rather than special-case the sometimes-present
size, the single-entry `.zst` reports `ArchiveEntry.uncompressedSize` as `-1`
(unknown) — the same sentinel as `koni_bzip2` (see the core `uncompressedSize`
dartdoc; `-1` avoids colliding with an empty file / synthesized directory at
`0`). Reading the entry still yields the full content. The layered `.tar.zst`
`ZstdDecompressedByteSource` decodes the whole container at open to learn its
`length` (capped by `maxContainerDecodeSize` ?? `maxEntrySize`, checked per
block), the gzip-style decode-and-cache shape.

## Streaming and memory

The reader feeds all compressed input to the decoder, then pulls one decoded
block (≤ 128 KiB) at a time and yields it. A `maxEntrySize` guard aborts between
blocks. Because zstd matches back-reference earlier output, the codec retains
the frame's decoded bytes (matches copy by absolute position); a **mandatory
window-size cap** (128 MiB, the reference decoder's default) bounds a hostile
tiny header, and — a future optimization — a true sliding window could bound
memory to the window rather than the whole frame.

## Writing: a correctness-first encoder

The write side (`ZstdWriteFormat` → `ZstdWriter` → `ZstdEncoder` in
`koni_codecs`) inverts the read pipeline into a valid `.zst`: a single frame,
single-segment header carrying the content size, no content checksum, no
dictionary; data split into ≤ 128 KiB blocks.

Deliberate simplifications keep it correct and small, at a ratio below `zstd`'s
(the output is always `zstd -d`-decodable):

- **Predefined FSE tables only.** Sequences are entropy-coded over the three
  predefined LL/OF/ML distributions (mode 0), so no entropy table is serialized.
  The tANS **encoder** is a from-scratch port of the FSE C-table build and the
  reverse-order symbol encode; it was isolated against the reader's FSE decoder
  (a symbol-stream round trip) before wiring the block, because the read order
  (init LL/OF/ML → per-sequence OF/ML/LL extras → LL/ML/OF state updates) has to
  match the encoder's append order exactly.
- **Raw literals.** Literals are stored uncompressed (literals type 0); Huffman
  literal coding — `zstd`'s main win on literal-heavy data — is a planned
  follow-up.
- **New offsets only.** Every match emits `Offset_Value = offset + 3`, never the
  repeat-offset codes. Always valid, and it keeps the sequence encoder simple.
- **Greedy match finder.** A hash-chain over the whole input (so a block's
  matches can reference earlier blocks within the single-segment window), bounded
  search depth, minimum match length 3.
- **Raw-block fallback.** A block whose compressed body is not smaller than its
  raw bytes is stored raw, so output never expands beyond framing overhead.

A latent decoder-table bug surfaced during the build: an isolated cross-check
found the `ML_bits` table needs exactly 32 leading zeros (codes 0–31), and the
encoder's copy must match the reader's — an off-by-one there over-reads the
match-length extra bits and over-produces the block. The encoder is verified
byte-identical across the VM, dart2js, and dart2wasm (all its arithmetic is
32-bit-safe; no 64-bit checksum on write).

## Deferrals

- **Dictionaries** (`Dictionary_ID` present) and the **legacy v0.x** frame
  formats are typed errors, not silent mis-decodes.
- **ZIP method 93** (zstd inside a ZIP): the codec is ready, but no tool on the
  build machine authors a method-93 ZIP, so the wiring is deferred rather than
  shipped untested (Info-ZIP `zip` and `7zz` here cannot produce one).

## Error translation

The codec throws `FormatException` (including converting a `RangeError` from a
corrupt stream into one, so mutated input always surfaces as a typed error); the
reader and decompressed source map that to `CorruptArchiveException`.

## Provenance

Clean-room from RFC 8878, verified byte-for-byte against `zstd` 1.5.7 across raw
/ RLE / compressed blocks, raw + Huffman literals (direct and FSE weights, 1-
and 4-stream), predefined and FSE-compressed sequence tables, repeat offsets,
overlapping matches, multi-block, multi-frame, and the XXH64 checksum. The codec
is independent of libzstd.

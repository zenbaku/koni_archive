# koni_bzip2: implementation notes

Decisions made where the bzip2 format left room.

## The codec lives in koni_codecs

bzip2 decoding is a general codec (`RawBzip2Decoder` / `Bzip2Decoder` in
`koni_codecs`), not archive-specific: it also backs ZIP method 12 and 7z's
BZip2 coder. This package is only the container glue — detection, the
single-entry adapter, and `.tar.bz2` layering — mirroring `koni_gzip` /
`koni_xz`. See `koni_codecs`' bzip2 source for the decode pipeline (MSB-first
bit reader, per-group Huffman, MTF/RLE2, inverse BWT, RLE1, CRC-32/BZIP2).

## No stored size

Unlike gzip (ISIZE) or xz (stream index), **bzip2 records no decompressed
size**. Two consequences:

- The single-entry `.bz2` reports `ArchiveEntry.uncompressedSize` as `-1`
  (unknown) rather than decoding the whole file at open just to fill it in
  (`open` stays O(metadata), the contract every reader upholds). `-1` is used,
  not `0`, because `0` is indistinguishable from an empty file (and is what the
  VFS uses for synthesized directories). Reading the entry still yields the full
  content. The core `uncompressedSize` dartdoc documents the sentinel.
- The layered `.tar.bz2` `Bzip2DecompressedByteSource` genuinely must decode the
  **whole** container at open to learn its `length` — there is no cheap size
  probe. This is the gzip-style "decode and cache" shape, minus the trailer
  read, and is capped by `maxContainerDecodeSize` (falling back to
  `maxEntrySize`): the running total is checked as each block is decoded, so a
  bomb never fully materializes.

## Streaming

The reader feeds all compressed input to the decoder (blocks are bit-aligned;
the source is random-access, so buffering the compressed bytes is cheap), then
pulls one decoded block at a time and yields it. Peak memory is
compressed-size + one ≤ 900 KiB block, and a `maxEntrySize` guard aborts between
blocks — the same per-block-yield shape as the xz reader (and, unlike a
push/`onOutput` model, one that never materializes the whole output before the
first yield).

## Writing: a correctness-first encoder

The write side (`Bzip2WriteFormat` → `Bzip2Writer` → `Bzip2Encoder` in
`koni_codecs`) inverts the read pipeline: RLE1 → forward Burrows–Wheeler
transform → MTF/RLE2 → length-limited Huffman → MSB-first bitstream, in `BZh`
framing.

Two deliberate simplifications keep it correct and small at a small ratio cost
(output is always `bzip2 -d`-decodable):

- **One Huffman table per block**, pointed to by the two required groups, rather
  than `bzip2`'s 2–6-table iterative optimization. The length-limited Huffman is
  a direct port of `bzip2`'s `hbMakeCodeLengths` (20-bit cap, frequency scaling
  on overflow).
- **Prefix-doubling BWT.** The forward transform is a prefix-doubling suffix sort
  over the block's cyclic rotations. Periodic input produces identical rotations
  (equal rank forever); since Dart's `sort` is not stable, the rotation order is
  finalized by a total-order re-sort breaking ties by start index — the transform
  is then bit-for-bit deterministic across the VM, dart2js, and dart2wasm.
  (Identical rotations are interchangeable, so any tie order inverts; this just
  pins one for reproducibility.)

Regression guarded in tests: an early `RLE1` used a reused scratch buffer with a
copy-free `BytesBuilder`, so a flush past ~256 bytes aliased and corrupted
already-emitted slices. The `_rle1` boundary is now covered for every input
length across the flush point.

## Randomized blocks

bzip2 ≤ 0.9.0 could set a "randomized" block flag; no encoder has emitted it in
decades and no fixture can be authored for it, so it is a typed error rather
than a silent mis-decode or an untestable derandomization path (the RAR-subcase
pattern).

## Error translation

The codec throws `FormatException`; the reader and decompressed source map that
to `CorruptArchiveException` with bzip2/entry context. bzip2's block and stream
CRCs are integral to the codec and always verified, so there is no
`verifyChecksums` toggle.

## Provenance

Clean-room from the bzip2 format (Julian Seward), verified byte-for-byte against
`bzip2` 1.0.8 output and cross-checked with CPython's `bz2` module. The codec is
independent of libbzip2.

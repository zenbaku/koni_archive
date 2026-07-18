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

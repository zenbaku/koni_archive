# koni_bzip2 feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| Single-stream `.bz2` | opens as a single-entry archive |
| Concatenated multi-stream files | decoded end to end |
| All block sizes (`BZh1`–`BZh9`) | 100 KiB–900 KiB blocks |
| Block + stream CRC verification | integral to the codec, always checked |
| Streaming reads | one bzip2 block (≤ 900 KiB) in memory at a time |
| `maxEntrySize` | aborts a decode that grows past the limit (between blocks) |

## Supported (writing)

| Feature | Notes |
| --- | --- |
| Single-stream `.bz2` output | `Bzip2WriteFormat` compresses one byte stream (single-member container) via `Bzip2Encoder` |
| Block sizes `-1`..`-9` | `Bzip2WriteFormat(blockSize100k: 1..9)`; 9 is the default and best ratio |
| Multi-block output | input larger than one block is split into independent blocks with a combined stream CRC |
| `bzip2` / libbz2 interop | output decodes byte-for-byte under the `bzip2` CLI; byte-identical across VM, dart2js, dart2wasm |

## Supported (layering)

| Feature | Notes |
| --- | --- |
| `.tar.bz2` / `.tbz2` / `.tbz` presentation as the inner TAR | via `Bzip2Format(layeredFormats:)` + `Bzip2DecompressedByteSource`. bzip2 records no size, so the container is decoded in full at open (capped by `maxContainerDecodeSize`, falling back to `maxEntrySize`) — a one-time cost; see doc/notes.md |

## Typed errors (never a silent mis-decode)

| Feature | Status |
| --- | --- |
| Randomized blocks | `FormatException` → `CorruptArchiveException` (deprecated pre-0.9 bzip2 feature, unauthorable today) |
| A failed block or stream CRC | `CorruptArchiveException` |

## Notes

- `.bz2` stores no filename, timestamp, or decompressed size. The entry name is
  derived from the container; `uncompressedSize` is `-1` (unknown).
- The bzip2 **codec** (in `koni_codecs`) also backs ZIP method 12 and 7z's
  BZip2 coder.

## Not yet / out of scope

| Feature | Status |
| --- | --- |
| 2–6-table Huffman optimization on write | not yet — the encoder uses a single per-block Huffman table (still `bzip2 -d`-compatible), so ratio is a little below `bzip2`'s |
| Random access below block granularity | inherent to the format |

## Spec references

- The bzip2 format (Julian Seward), as implemented by `bzip2` 1.0.8
- `bzip2` as the reference tool for fixtures; CPython's `bz2` module cross-checks

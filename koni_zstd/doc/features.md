# koni_zstd feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| Single-frame `.zst` | opens as a single-entry archive |
| Concatenated frames + skippable frames | decoded / skipped end to end |
| Raw / RLE / Compressed blocks | full block set |
| Raw / RLE / Huffman literals | direct and FSE-compressed Huffman weights; 1- and 4-stream |
| Sequences (predefined / RLE / FSE-compressed / repeat tables) | with the 3 repeat offsets |
| XXH64 content checksum | verified on native 64-bit platforms; skipped on the web (decode is independent) |
| Streaming reads | one block (≤ 128 KiB) at a time |
| `maxEntrySize` | aborts a decode that grows past the limit |

## Supported (writing)

| Feature | Notes |
| --- | --- |
| Single-frame `.zst` output | `ZstdWriteFormat` compresses one byte stream (single-member container) via `ZstdEncoder` |
| LZ sequences over predefined FSE tables | hash-chain match finder (net-cost-scored candidates + one-step lazy lookahead); a from-scratch tANS encoder; new offsets only |
| Huffman literals | direct or FSE-compressed weight table (whichever is smaller), 1- and 4-stream; used when it beats raw. FSE weights also cover a literal alphabet with a byte value `> 128` (direct weights cannot), else raw fallback |
| Raw-block fallback | incompressible blocks are stored raw, so output never expands much |
| `zstd` / libzstd interop | output decodes byte-for-byte under the `zstd` CLI; byte-identical across VM, dart2js, dart2wasm |

## Supported (layering)

| Feature | Notes |
| --- | --- |
| `.tar.zst` / `.tzst` presentation as the inner TAR | via `ZstdFormat(layeredFormats:)` + `ZstdDecompressedByteSource`. zstd may omit the content size, so the container is decoded in full at open (capped by `maxContainerDecodeSize`, falling back to `maxEntrySize`) |

## Typed errors (never a silent mis-decode)

| Feature | Status |
| --- | --- |
| Dictionary-compressed frames (`Dictionary_ID` set) | `FormatException` → `CorruptArchiveException` |
| Legacy (v0.x) frame formats | as above |
| A declared window over 128 MiB | rejected before allocation |

## Not yet / out of scope

| Feature | Status |
| --- | --- |
| Custom FSE sequence tables / repeat modes on write | not yet — the writer always uses the predefined sequence tables |
| Dictionary support | deferred (typed error) |
| ZIP method 93 (zstd-in-ZIP) | deferred — no tool on hand authors it for a fixture |

## Notes

- `.zst` stores no filename and may omit the decompressed size; the entry name
  is derived from the container and `uncompressedSize` is `-1` (unknown).
- The zstd **codec** (in `koni_codecs`) is the general decoder.

## Spec references

- RFC 8878 (Zstandard Compression and the `application/zstd` Media Type)
- `zstd` 1.5.7 as the reference tool for fixtures

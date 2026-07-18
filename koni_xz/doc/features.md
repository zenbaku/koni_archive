# koni_xz feature matrix

## Supported

| Feature | Notes |
| --- | --- |
| Single-stream `.xz` | opens as a single-entry archive |
| Concatenated multi-stream files | decoded as one concatenated stream (with inter-stream padding) |
| Multi-block streams (`xz -T0`) | each block decoded independently, presented as one entry |
| LZMA2 payload | the sole compression filter xz allows |
| Delta filter | reverse-applied after decompression |
| x86 BCJ filter (start offset 0) | reverse-applied after decompression |
| Integrity checks: None / CRC-32 / CRC-64 / SHA-256 | verified per block, on by default; `verifyChecksums: false` opt-out |
| Streaming reads | one block in memory at a time |
| `maxEntrySize` | a block over the limit is rejected before allocation |

## Supported (layering)

| Feature | Notes |
| --- | --- |
| `.tar.xz` / `.txz` presentation as the inner TAR | via `XzFormat(layeredFormats:)` + `XzDecompressedByteSource` (block-by-block decode + in-memory cache, see doc/notes.md for the cost model); `maxContainerDecodeSize` caps the open-time decode |

## Supported (writing, `XzWriteFormat`)

| Feature | Notes |
| --- | --- |
| One entry → single-block `.xz` | LZMA2 payload, CRC-64 check; output decodable by `xz` / liblzma |
| Empty input | a valid zero-block stream (byte-identical to `xz < /dev/null`) |
| Size-checked streaming input | `addStream` verifies the declared size (the payload is buffered to encode) |

### Not written / rejected

| Feature | Status |
| --- | --- |
| A second entry, or a directory / link / other type | rejected (xz is a single-member container) |
| Encryption (a password) | rejected (`.xz` has none, like TAR) |
| Non-LZMA2 compression | rejected |
| Transform filters (delta / BCJ), non-CRC-64 checks, multi-block splitting | not written (single LZMA2 block + CRC-64 only) |
| The entry name | not stored (`.xz` has no filename field), so a round trip preserves content, not the name |

## Typed errors (never a silent mis-read)

| Feature | Status |
| --- | --- |
| Non-x86 BCJ filters (ARM, ARM64, ARMThumb, PPC, SPARC, IA-64, RISC-V) | `UnsupportedCompressionException` |
| x86 BCJ with a non-zero start offset | `UnsupportedFeatureException` |
| Reserved / unsupported check ids | `InvalidHeaderException` at open |
| Concatenation that does not reconcile against the file length | `InvalidHeaderException` |
| A size field past 2^48 | `UnsupportedFeatureException` |

## Not yet / out of scope

| Feature | Status |
| --- | --- |
| Random access below block granularity | inherent to LZMA2 (the block is the decode unit) |
| Sequential (non-seekable) input | out of scope (the index is read from the end) |
| Writing `.xz` | out of scope |

## Spec references

- The `.xz` file format specification (<https://tukaani.org/xz/xz-file-format.txt>)
- LZMA2 via `koni_codecs`; delta / x86 BCJ via `koni_codecs/filters.dart`
  (public-domain BCJ; see that file's provenance note)
- `xz` (XZ Utils) as the reference tool for fixtures; CPython's `lzma` module
  cross-checks the codec

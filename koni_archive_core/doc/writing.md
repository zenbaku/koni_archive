# koni_archive_core — the write API (Phase 2)

The write side mirrors the read side (§16, symmetric read/write behind one
format-agnostic API), reusing the same entry types, compression enum,
checksums, and exception hierarchy. This document records the design
decisions (per §13.3).

## Shape (P2-1)

| Reading | Writing |
| --- | --- |
| `ByteSource` (random access) | `ByteSink` (sequential append) |
| `ArchiveFormat` / `ArchiveReader` | `ArchiveWriteFormat` / `ArchiveWriter` |
| `Archive.open(source)` (auto-detects) | `Archive.create(sink, format:)` (explicit) |
| `ArchiveEntry` (reader output) | `ArchiveEntrySpec` (caller input) |
| detection registry | *(none — writing can't sniff)* |

- **`ByteSink` is sequential, not a mirror of the random-access
  `ByteSource`.** Archive writing is append-only: TAR is pure append; ZIP
  streams its data and appends the central directory at `close`, tracking
  positions via `ByteSink.length`. Nothing seeks back, so there is no
  seekable sink.
- **`ArchiveEntrySpec` is separate from `ArchiveEntry`.** Reader-derived
  fields (`crc32`, `compressedSize`, `pathEscapedRoot`, `isEncrypted`) are
  meaningless as inputs. The add methods *return* the resulting
  `ArchiveEntry` (with computed CRC/sizes), so a write-then-read round trip
  is symmetric.
- **No write registry.** Writing always names the format explicitly, so
  the read side's detection registry has no counterpart.

## Load-bearing decisions

- **Write paths are rejected, not silently sanitized.** `validateWritePath`
  throws `ArgumentError` for absolute paths, drive letters, and `..`
  escapes (the writer's caller is a programmer; silently rewriting their
  path would surprise). This is the deliberate inverse of the read side's
  `normalizeEntryPath`, which sanitizes hostile archive bytes.
- **`addStream` requires `size`.** TAR records the size in the header
  *before* the data, so unknown-size streaming would force whole-entry
  buffering — an explicit non-goal that would dent the bounded-memory
  promise. Callers adding from disk or memory always know the size;
  `addBytes` fills it in. Unknown-size input is deferred (it would be an
  opt-in that names its memory cost, and only ZIP's data descriptors make
  it genuinely streaming).
- **Declared size is validated against streamed bytes.** Too few →
  `CorruptArchiveException`; too many → `SizeLimitExceededException`. This
  is the one place a size mismatch would otherwise silently corrupt the
  archive (the header size is already written).

## Reuse

`Crc32`/`Adler32`, `normalizeEntryPath`'s sibling `validateWritePath`, and
the `ArchiveEntryType` / `ArchiveCompression` enums are shared directly.
Format writers mirror their readers' field encoding (TAR octal/base-256/
checksum, ZIP structures). The deflate *encoder* (P2-3) will reuse CRC-32,
the RFC-1951 constant tables already in `koni_codecs`, and a bit-*writer*
mirroring the bit-reader — but LZ77 match-finding and Huffman construction
from frequencies are genuinely new (the decoder shares neither).

## Testing

Format writers are done only when a **reference tool extracts what they
wrote** (`tar tf`, `unzip -t`, then byte-compare) — self-round-tripping
through this project's own reader hides symmetric bugs, exactly as it would
on read. Round-trip is necessary; interop is the real check.

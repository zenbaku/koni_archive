# Changelog

## 0.3.0-dev (unreleased)

- Lockstep release; no changes since 0.2.0.

## 0.2.0 (2026-07-15)

- lockstep release; no changes since 0.1.0.

## 0.1.0 (2026-07-15)

- M7: `ArchiveReadOptions.entryNameDecoder` (caller-supplied decoder for
  formats with unreliable name encodings, §8); `ByteReader.readUint64le/be`
  now enforce a uniform 2^53 − 1 cap on every platform (fuzz-found: hostile
  fields could wrap negative on the VM).
- M5: `Crc32` upgraded to slicing-by-8 (~4x faster verified reads).
- M4: `ByteSource.name` (optional display name) — lets formats derive
  entry names from the container (gzip FNAME fallback, §8);
  `FileByteSource` reports its path, `MemoryByteSource`/`BlobByteSource`
  accept an optional `name:`.
- M3: `ArchiveReadOptions` (verifyChecksums, §7) threaded through
  `ArchiveFormat.openReader` and the registry driver; more
  `ArchiveCompression` constants (deflate64, bzip2, ppmd, zstd) for
  diagnostics.
- M1: core abstractions.
  - `ByteSource` (seekable, pread semantics) with `MemoryByteSource`;
    `FileByteSource` behind opt-in `io.dart`; `BlobByteSource` behind opt-in
    `web.dart` (dart2js + dart2wasm).
  - `ByteReader` (sync parsing cursor; portable 64-bit reads, typed EOF
    errors) and incremental `Crc32` / `Adler32`.
  - Typed exception hierarchy rooted at `ArchiveException` (§9), every type
    carrying format/offset/entry context.
  - Immutable `ArchiveEntry` model (`ArchiveEntryType`,
    `ArchiveCompression` with raw-id-carrying `unknown`).
  - `normalizeEntryPath` (§7): separators, drive letters, absolute paths,
    `.`/`..` resolution with root-escape flagging.
  - `ArchiveFormat` / `ArchiveReader` SPI and `ArchiveFormatRegistry` with
    detection driver (registration-order probing, first match wins,
    explicit-format escape hatch).
- M0: package scaffolding — pub workspace membership, shared strict lints,
  CI matrix (VM on Linux/macOS/Windows; web via dart2js and dart2wasm).

# Changelog

## 0.10.0 (2026-07-18)

- Adds `Crc64` (the `CRC-64/XZ` parameters) next to `Crc32`: a 64-bit CRC held
  in two 32-bit lanes and verified lane-wise, so it is exact under dart2js. It
  is the default integrity check of the `.xz` container and is used by the new
  `koni_xz` package.
- The checksums are foundational utilities meant to be used directly (e.g. to
  hand-build an archive — or a deliberately corrupt one — for tests). `Crc32`
  and `Crc64` gain a `bytes` getter and a `computeBytes` one-shot that return
  the checksum as its **little-endian on-the-wire bytes** (4 for CRC-32, 8 for
  CRC-64 — the form ZIP/gzip/xz store), so a caller no longer has to reassemble
  the lanes or hand-serialize the value.
- Adds `ByteWriter`, the append-only write mirror of `ByteReader`, for
  assembling archive headers (or deliberately malformed ones) by hand:
  `writeUint8` / `writeUint16` / `writeUint32` / `writeUint64` in little- and
  big-endian variants (64-bit split into two 32-bit writes, dart2js-safe and
  capped at 2^53-1 like the reader), plus `writeBytes`, `writeZeros`, a
  `length` cursor, and `takeBytes`.
- `ArchiveEntry.uncompressedSize` may now be `-1` to mean "unknown" for a format
  that records no decompressed size and whose reader does not eagerly
  decompress — currently only a bare `.bz2` (see `koni_bzip2`). Every other
  format still reports a real, non-negative size.

## 0.9.0 (2026-07-17)

- Decompression-bomb guards on the read side. `ArchiveReadOptions` gains
  `maxEntrySize` (a cap, in bytes, on any single entry's decoded output) and
  `maxEntryCount` (a cap on how many entries an archive may declare). Both are
  enforced at the `ArchiveFormat.openReader` seam, so they hold for every
  format and cannot be bypassed by using a reader directly instead of the
  facade: streaming an entry past `maxEntrySize` aborts the decode with
  `SizeLimitExceededException`, and opening an over-count archive throws the
  same. Null (the default) means unbounded, so behavior is unchanged unless a
  caller opts in.
- `maxContainerDecodeSize` bounds a reader's *bulk* decodes that are not a
  single entry's stream — a layered `.tar.gz` decompressed at open, or a 7z
  (compressed) header / solid folder decoded to reach an entry. For the
  `.tar.gz` open-time decode it **falls back to `maxEntrySize`** when unset, so
  a per-entry limit alone still guards against a gzip bomb at open; 7z's
  folder/header caps are opt-in only (a per-entry limit must not reject a small
  entry that merely lives in a larger solid folder). Both null leaves each
  format at its built-in behavior — a no-op for ZIP, plain TAR, and plain gzip;
  RAR does not yet enforce it (a documented gap on the solid-run decode).
- **SPI change (format implementers).** The method a format overrides to build
  its reader is now `ArchiveFormat.createReader`; `openReader` became the
  concrete entry point that wraps the reader with the guards above. A
  third-party format that overrode `openReader` must rename it to
  `createReader` — a compile error points at it. Application code is
  unaffected.
- `SizeLimitExceededException` now also covers the entry-count limit; its
  `limit` field carries a byte count for a size limit or an entry count for
  `maxEntryCount`.

## 0.8.0 (2026-07-16)

- `ArchiveWriteOptions` gains `allowUnsafePaths` (default `false`). When set,
  a writer skips the `validateWritePath` check and writes each
  `ArchiveEntrySpec.path` verbatim, including absolute paths, drive letters,
  and `..` segments that escape the archive root. It exists to author a
  hostile archive on purpose, e.g. a fixture that exercises a consumer's
  path-traversal ("Zip Slip") defenses, which the safe writer refuses to
  build. Purely additive: the default keeps the existing `ArgumentError`
  rejection, and the read side is untouched (every reader still normalizes
  paths at parse time and flags `pathEscapedRoot`, so reading such an archive
  back stays safe).

## 0.7.0 (2026-07-16)

- `ArchiveReadOptions` gains `nextVolume`, a resolver a reader calls to obtain
  the later volumes of a multi-volume archive (volume 1 is the source passed
  to the reader; `nextVolume(n)` returns volume `n` or null when there is no
  such volume). Consumed by the RAR reader; other formats ignore it. Purely
  additive; existing callers are unaffected.

## 0.6.0 (2026-07-15)

- Phase 4 (write-side encryption): `ArchiveWriteOptions` gains `password`
  (whole-archive AES-256 encryption, honored by the ZIP and 7z writers) and
  `encryptHeader` (7z `-mhe`). Same encoding contract as the read side; no
  changes to the reader model.
- First release published to pub.dev.

## 0.5.0 (2026-07-15)

- Phase 3 (decryption) API: `ArchiveReadOptions.password` for opening
  password-protected archives, and `InvalidPasswordException` (a subtype of
  `EncryptedArchiveException`) for a wrong password where the format carries
  a check value. `EncryptedArchiveException` now also covers unsupported
  encryption schemes, not just "no password given".

## 0.4.0 (2026-07-15)

- P2-1: write API: `ByteSink` (+ `BytesBuilderSink`, `FileByteSink` in
  io.dart), `ArchiveEntrySpec`, `ArchiveWriter` / `ArchiveWriteFormat`
  SPI, `ArchiveWriteOptions`, and `validateWritePath` (reject unsafe
  paths). Mirrors the read side; reuses the entry/compression enums,
  checksums, and exceptions. No format writers yet (TAR at P2-2).

## 0.3.0 (2026-07-15)

- Lockstep release; no changes since 0.2.0.

## 0.2.0 (2026-07-15)

- lockstep release; no changes since 0.1.0.

## 0.1.0 (2026-07-15)

- M7: `ArchiveReadOptions.entryNameDecoder` (caller-supplied decoder for
  formats with unreliable name encodings); `ByteReader.readUint64le/be`
  now enforce a uniform 2^53 − 1 cap on every platform (fuzz-found: hostile
  fields could wrap negative on the VM).
- M5: `Crc32` upgraded to slicing-by-8 (~4x faster verified reads).
- M4: `ByteSource.name` (optional display name): lets formats derive
  entry names from the container (gzip FNAME fallback);
  `FileByteSource` reports its path, `MemoryByteSource`/`BlobByteSource`
  accept an optional `name:`.
- M3: `ArchiveReadOptions` (verifyChecksums) threaded through
  `ArchiveFormat.openReader` and the registry driver; more
  `ArchiveCompression` constants (deflate64, bzip2, ppmd, zstd) for
  diagnostics.
- M1: core abstractions.
  - `ByteSource` (seekable, pread semantics) with `MemoryByteSource`;
    `FileByteSource` behind opt-in `io.dart`; `BlobByteSource` behind opt-in
    `web.dart` (dart2js + dart2wasm).
  - `ByteReader` (sync parsing cursor; portable 64-bit reads, typed EOF
    errors) and incremental `Crc32` / `Adler32`.
  - Typed exception hierarchy rooted at `ArchiveException`, every type
    carrying format/offset/entry context.
  - Immutable `ArchiveEntry` model (`ArchiveEntryType`,
    `ArchiveCompression` with raw-id-carrying `unknown`).
  - `normalizeEntryPath`: separators, drive letters, absolute paths,
    `.`/`..` resolution with root-escape flagging.
  - `ArchiveFormat` / `ArchiveReader` SPI and `ArchiveFormatRegistry` with
    detection driver (registration-order probing, first match wins,
    explicit-format escape hatch).
- M0: package scaffolding: pub workspace membership, shared strict lints,
  CI matrix (VM on Linux/macOS/Windows; web via dart2js and dart2wasm).

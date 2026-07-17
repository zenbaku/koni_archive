# Changelog

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

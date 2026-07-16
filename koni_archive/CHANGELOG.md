# Changelog

## 0.7.0 (2026-07-16)

- RAR reading is substantially more complete through the facade (via
  `koni_rar` 0.7.0): RAR4 PPMd (variant H, solid and non-solid, including a
  mid-file PPMd→method-29 block switch), the generic RarVM filter interpreter
  (any method-29 filter program, not just the standard four), RAR4 `-hp`
  encrypted headers, RAR 2.0/2.6 (v20/v26) LZ, solid RAR4, and multi-volume
  RAR sets — the last via the new `ArchiveReadOptions.nextVolume` resolver.
  Many archives that previously threw a typed error now decode.

## 0.6.0 (2026-07-15)

- Phase 4 (write-side encryption) flows through the facade:
  `ArchiveWriteOptions.password` encrypts ZIP (WinZip AES-256) and 7z
  (AES-256) output, and `encryptHeader` drives 7z `-mhe`. Every writer's
  encrypted output is interop-verified against 7-Zip.
- Remote archives: pair the facade with the new `koni_http_source` package
  (`HttpRangeByteSource`) to read entries out of a remote archive over HTTP
  Range requests, without downloading the whole file.
- First release published to pub.dev.

## 0.5.0 (2026-07-15)

- Phase 3 (decryption, read side): opening a password-protected archive now
  works across every format — pass `ArchiveReadOptions.password`. ZIP
  (zipcrypto + WinZip AES), 7z (AES-256, incl. `-mhe` headers), RAR5
  (`-p`), and RAR4 (`-ma4 -p`). Re-exports the new
  `InvalidPasswordException`. Encrypted headers for RAR (`-hp`) and
  write-side encryption stay out of scope — see `doc/encryption-scope.md`.

## 0.4.0 (2026-07-15)

- P2-4b: 7z writing is now format-faithful — **LZMA2 is the default
  coder** (was deflate), with LZMA (v1) also selectable per entry or
  globally, and headers are LZMA-compressed (kEncodedHeader) whenever that
  is smaller. Powered by the new koni_codecs encoders (liblzma- and
  7zz-interop-verified); `7zz t`/`7zz x` validate and extract every coder
  byte-for-byte, including multi-chunk LZMA2 with uncompressed-chunk
  fallbacks. LZMA folders buffer the entry's uncompressed bytes while
  encoding (the buffer is the match window); Copy/Deflate entries still
  stream. Solid folders remain deferred (one folder per file).

- P2-4a: `SevenZWriteFormat` re-exported from the facade — write `.7z`/`.cb7`
  via `Archive.create(sink, format: const SevenZWriteFormat())`. Copy and
  Deflate (default at the time) folders, one per non-empty file; full container
  (signature/start header, PackInfo/UnpackInfo with per-folder CRC-32,
  uncompressed FilesInfo), UTF-16 names, FILETIME mtimes, unix modes,
  directories, empty files, and symlinks. `7zz` validates and extracts our
  output byte-for-byte (interop; 300-entry archive exercises multi-byte 7z
  numbers, symlink restored via `-snl`).
  - **Not streaming, by construction:** 7z's leading signature header
    references the trailing header's position, so the writer buffers the
    compressed packed streams in memory until `close()` (peak memory ≈
    compressed archive size). Inherent to appending a random-access format —
    unlike TAR/ZIP writing.
  - Deferred to P2-4b (tracked): LZMA/LZMA2 folders (and the default codec
    switching deflate → LZMA2), compressed headers, and solid folders (today
    one folder per file, so no cross-file compression).

- P2-3: `ZipWriteFormat` re-exported from the facade — write `.zip`/`.cbz`
  via `Archive.create(sink, format: const ZipWriteFormat())`. Stored +
  deflate compression (per-entry or global), streaming append-only output
  (data descriptors, no seek-back), ZIP64 when count/size overflows 32 bits,
  directories, and symlinks. Info-ZIP `unzip` validates and extracts our
  output byte-for-byte (interop, incl. a 70k-entry ZIP64 archive).

- P2-2: `TarWriteFormat` re-exported from the facade — write `.tar`/`.cbt`
  via `Archive.create(sink, format: const TarWriteFormat())` without a
  direct koni_tar dependency.

- P2-1: `Archive.create(sink, format:)` and the `createArchiveFile`
  (io.dart) write sugar, plus the write types re-exported. No built-in
  write formats registered yet.

## 0.3.0 (2026-07-15)

- M10: RAR4 support — RAR5 **and** RAR4 `.rar`/`.cbr` archives open through
  `Archive.open`. **Phase 1 complete**: ZIP, TAR, GZIP, 7z, and RAR all
  read behind the one format-agnostic API, on VM and web. The real-world
  CBR corpus (RAR4) decodes byte-identically to reference tools.
- M9: `RarFormat` registered in `builtInFormats` — RAR5 `.rar`/`.cbr`
  archives open through `Archive.open`. RAR4 is a typed error (M10).

## 0.2.0 (2026-07-15)

- M8: `SevenZFormat` registered in `builtInFormats` — `.7z`/`.cb7`
  archives open through `Archive.open`; CB7 page-flip served by the
  solid-block LRU cache.

## 0.1.0 (2026-07-15)

- M6: the facade layers TAR into gzip — `.tar.gz`/`.tgz` opens as the
  inner TAR through `Archive.open` (format auto-detection unchanged).
- M5: **first release point — CBZ works end-to-end** (deflate wired into
  the ZIP reader). Facade README and example (a CBZ page extractor with
  preloading) added.
- M4: `GzipFormat` registered in `builtInFormats` (between zip and tar) —
  bare `.gz` files open as single-entry archives through `Archive.open`.
- M3: `ZipFormat` registered in `builtInFormats` (before TAR — precise
  magic first) — stored `.zip`/`.cbz` archives open through
  `Archive.open`; `ArchiveReadOptions` (`verifyChecksums`) accepted by
  `Archive.open`/`openBytes` and the platform sugar.
- M2: `TarFormat` registered in `builtInFormats` — `.tar` and `.cbt`
  archives open through `Archive.open` with format auto-detection.
- M1: the `Archive` facade (§4).
  - `Archive.open` (auto-detection via `builtInFormats` or a custom
    registry, `format:` escape hatch) and `Archive.openBytes`; platform
    sugar `openArchiveFile` (`io.dart`) and `openArchiveBlob` (`web.dart`).
  - Entry access: `entries` (index order, duplicates included), `entry()` /
    `exists()` (exact, case-sensitive, last-wins).
  - Streaming-first reads: `openRead` / `openReadPath`, `readBytes` with
    `maxSize` bomb protection; concurrent entry streams; `close()` errors
    in-flight streams with `ArchiveClosedException` and is idempotent.
  - VFS view: `walk()` (documented depth-first pre-order), `files`,
    `directories` (implicit directories synthesized), `glob()`.
  - No formats are registered yet — they land per milestone (TAR at M2).
- M0: package scaffolding — pub workspace membership, shared strict lints,
  CI matrix (VM on Linux/macOS/Windows; web via dart2js and dart2wasm).

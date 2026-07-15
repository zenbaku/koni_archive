# Changelog

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

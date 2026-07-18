# Changelog

## 0.10.0 (2026-07-18)

- **BZip2-coder folders now decode** (via the new `koni_codecs` bzip2 decoder),
  replacing the previous typed error. BCJ2 and PPMd folders remain typed errors.

## 0.9.0 (2026-07-17)

- Honors the read-side size limits (`ArchiveReadOptions.maxEntrySize` /
  `maxEntryCount`) via the shared reader seam, plus `maxContainerDecodeSize` to
  bound 7z's bulk decodes: reading even a small entry decodes its whole
  (possibly compressed) header or solid folder, and this caps that decode,
  tightening 7z's built-in backstops (64 MiB header, 1 GiB folder) to a
  caller-chosen value. Those backstops still apply when the option is null.

## 0.8.0 (2026-07-16)

- The writer honors `ArchiveWriteOptions.allowUnsafePaths` (see
  `koni_archive_core` 0.8.0): with it set, an entry path is written verbatim
  rather than validated.

## 0.7.0 (2026-07-16)

- Lockstep release; no changes to this package since 0.6.0.

## 0.6.0 (2026-07-15)

- P4-2: 7z write-side encryption. `ArchiveWriteOptions.password` encrypts
  each content folder as a `compressor → AES-256-CBC` chain (iterated-SHA-256
  KDF, per-folder IV); `ArchiveWriteOptions.encryptHeader` additionally
  encrypts the header (`-mhe`), hiding entry names and requiring the password
  at open. Interop: real 7-Zip (`7zz x -p`, `7zz l -p`) reads both
  byte-for-byte. Green on VM + dart2js + dart2wasm.
- The reader now reports `entry.isEncrypted` (folder-carries-an-AES-coder),
  matching the ZIP reader.
- First release published to pub.dev.

## 0.5.0 (2026-07-15)

- P3-3: 7z AES-256 decryption via `ArchiveReadOptions.password`. The AES
  coder is peeled ahead of the codec chain (decrypt into a buffer, then the
  existing decompress/filter path); the KDF is 7-Zip's iterated SHA-256
  (UTF-16LE password), not PBKDF2. Works in solid folders and for encrypted
  headers (`-mhe`, password required at open). 7z has no password verifier,
  so a wrong password surfaces as corrupt data or a checksum mismatch,
  always typed. Interop: 7zz `-p`/`-mhe` fixtures decrypt byte-identically;
  green on VM + dart2js + dart2wasm.

## 0.4.0 (2026-07-15)

- P2-4b: format-faithful 7z writing: **LZMA2 (coder `21`) is the default
  folder coder**, with LZMA (`03 01 01`) also selectable, powered by the
  new koni_codecs encoders. The header itself is LZMA-compressed
  (kEncodedHeader) whenever that is smaller than plain. Dictionary sized
  to the entry (4 KiB–8 MiB). LZMA entries buffer their uncompressed
  bytes while encoding (the buffer is the match window); Copy/Deflate
  entries still stream. Interop DoD: `7zz t`/`7zz x` validate and extract
  every coder byte-for-byte, incl. >2 MiB multi-chunk LZMA2 with
  uncompressed-chunk fallbacks and encoded headers; the LZMA codecs are
  additionally liblzma-verified in koni_codecs.
- P2-4a: the 7z write container, `SevenZWriter` / `SevenZWriteFormat`:
  signature + start header (next-header CRC), PackInfo, UnpackInfo with
  per-folder CRC-32, FilesInfo (UTF-16LE names, FILETIME mtimes, unix
  modes, dirs, empty files, symlinks), Copy and Deflate coders, one folder
  per non-empty file (non-solid). Buffers packed streams until `close()`
  (the leading signature header references the trailing header, inherent
  to the format, documented). Solid folders remain deferred.

## 0.3.0 (2026-07-15)

- Lockstep release; no changes since 0.2.0.

## 0.2.0 (2026-07-15)

- M8: 7z reader, full scope.
  - Container: signature/start headers (CRC-verified), compressed
    (kEncodedHeader) headers, folders/coders/bind pairs, substreams,
    FilesInfo (names, mtimes, attributes, empty files/dirs).
  - Codec chains: LZMA, LZMA2, Copy, Deflate + Delta/BCJ(x86) filters.
  - Solid blocks with a size-capped LRU cache; CB7 page-flip is
    sub-millisecond after the first read (bench recorded).
  - BCJ2/PPMd/bzip2 → typed errors naming the codec; AES → typed
    encryption errors (streams at openRead, headers at open);
    hardening (header/folder size caps, uniform 2^53−1 integer cap,
    fuzz smoke in CI).
- M0: package scaffolding.

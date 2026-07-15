# Changelog

## 0.3.0 (2026-07-15)

- Lockstep release; no changes since 0.2.0.

## 0.2.0 (2026-07-15)

- M8: 7z reader, full §8 scope.
  - Container: signature/start headers (CRC-verified), compressed
    (kEncodedHeader) headers, folders/coders/bind pairs, substreams,
    FilesInfo (names, mtimes, attributes, empty files/dirs).
  - Codec chains: LZMA, LZMA2, Copy, Deflate + Delta/BCJ(x86) filters.
  - Solid blocks with a size-capped LRU cache — CB7 page-flip is
    sub-millisecond after the first read (bench recorded).
  - BCJ2/PPMd/bzip2 → typed errors naming the codec; AES → typed
    encryption errors (streams at openRead, headers at open); §7
    hardening (header/folder size caps, uniform 2^53−1 integer cap,
    fuzz smoke in CI).
- M0: package scaffolding.

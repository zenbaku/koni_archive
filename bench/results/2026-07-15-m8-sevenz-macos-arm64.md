# 7z benchmarks (M8): CB7 page-flip

Produced by `dart run --no-enable-asserts bench/bin/sevenz_bench.dart`
(requires 7zz on PATH; the CB7 is built on the fly).

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- input: 120 pages x 512 KiB, solid LZMA2 (60 MiB decoded)
- baseline: none; package:archive has no 7z support

| step | time |
| --- | --- |
| open (header decode) | 14.0 ms |
| first page read (solid block decode + CRC) | 91.1 ms |
| next page read (LRU cache hit + CRC) | 0.8 ms |
| backwards page read (LRU cache hit + CRC) | 0.6 ms |

## Reading the numbers

- The exit criterion, "CB7 page-flip usable", holds: the first page
  pays the solid-block cost once (the whole 60 MiB folder decodes in
  ~91 ms), and every subsequent flip, forward or backward, is
  sub-millisecond out of the size-capped LRU cache.
- `open` includes decoding the LZMA-compressed header block (the caveat
  documented for 7z).
- Synthetic pages are highly compressible; photographic CB7 pages decode
  slower in absolute terms but the shape (one block decode, then cache
  hits) is what matters for readers.

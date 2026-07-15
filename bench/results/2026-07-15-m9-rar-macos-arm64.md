# RAR benchmarks (M9): CBR page-flip

Produced by `dart run --no-enable-asserts bench/bin/rar_bench.dart`
(requires `rar` on PATH; the CBR is built on the fly).

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- input: 120 pages x 512 KiB, RAR5 -m3 (non-solid; ~1 MiB compressed, 60 MiB decoded)
- baseline: none — package:archive has no RAR support

| step | time |
| --- | --- |
| open (header walk) | 7.6 ms |
| read page 57 (decode + CRC) | 8.5 ms |
| read page 2 (decode + CRC) | 1.2 ms |

## Reading the numbers

- The §8 exit criterion — "CBR (v5) works" — holds end-to-end: each page
  is an independent non-solid RAR5 stream, so a random page decodes in
  ~8 ms (Huffman + LZ over 512 KiB) with CRC verification on. Comic
  readers open one page at a time, so there is no solid-block penalty for
  the common CBR layout.
- Solid CBRs (rarer) share a window; the reader decodes the run once and
  serves later pages from the per-file cache (see the solid random-access
  test).
- The clean-room decoder is not yet micro-optimized; correctness against
  `unrar` output came first (§13.5). A quick-table fast path already
  handles the common short codes.

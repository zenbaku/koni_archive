# 7z-write benchmarks (P2-4a)

Produced by `dart run --no-enable-asserts bench/bin/sevenz_write_bench.dart`.

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- runs: best of 5 (after 2 warmup)
- baseline: none — package:archive has no 7z support, so times are absolute

| scenario | time | throughput (input) | archive |
| --- | --- | --- | --- |
| CB7: 120 stored pages (512 KiB) | 98.8 ms | 607 MiB/s | 60.0 MiB |
| 5000 deflated small files | 108.7 ms | 3 MiB/s | 0.2 MiB |

## Reading the numbers

- **Stored CB7 (the page-flip write target):** 607 MiB/s, bound by the
  memcpy into the packed buffer plus the per-folder CRC-32. This is the
  common `.cb7` case (already-compressed images, Copy folders) and it is
  fast. The whole 60 MiB is held in memory until `close()` — see the
  buffering caveat below.
- **5000 deflated small files:** the low MiB/s is *overhead-bound, not
  throughput-bound* — total input is ~0.35 MiB, so ~22 µs/file of
  per-entry cost (async `addBytes`, a fresh deflate block per file, and the
  one-folder-per-file container bookkeeping) dominates. This is the visible
  cost of the P2-4a layout: one folder per non-empty file means no
  cross-file compression and per-file header/folder overhead. Solid folders
  (P2-4b) are the lever that amortizes both.

## Memory note (by construction)

7z writing buffers the compressed packed streams in memory until `close()`:
the leading signature header records the trailing header's offset/size/CRC,
which an append-only sink cannot patch retroactively. Peak memory is bounded
by the *compressed* archive size (input still streams through the
compressor) — but a Copy-stored CB7 effectively holds the whole archive in
RAM. This is inherent to appending a random-access format, unlike TAR/ZIP.

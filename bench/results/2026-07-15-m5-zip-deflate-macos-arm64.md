# ZIP benchmarks (M5, deflate wired in)

Produced by `dart run --no-enable-asserts bench/bin/zip_bench.dart`.

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- inputs: list = 20k entries x 64 B stored; stored cbz = 120 x 512 KiB; deflated cbz = 120 x 512 KiB (level 6)
- runs: best of 5 (after 2 warmup)
- baseline: package:archive 4.x (`ZipDecoder().decodeBytes`; note: it does not verify checksums)

| scenario | koni_archive | package:archive | ratio |
| --- | --- | --- | --- |
| list 20k entries | 10.8 ms | 14.8 ms | 1.37x |
| open CBZ + read 1 page (CRC verified, default) | 0.7 ms | 0.1 ms | 0.08x |
| open CBZ + read 1 page (verifyChecksums: false) | 0.1 ms | 0.1 ms | 0.39x |
| open deflated CBZ + read 1 page (CRC verified) | 3.1 ms | 1.0 ms | 0.33x |

## Changes since the M3 record

- Core `Crc32` upgraded to slicing-by-8 (~300 MiB/s → ~1.2 GiB/s): the
  verified stored-page read dropped from 1.8 ms to 0.7 ms and the verified
  deflated-page read from 4.1 ms to 3.1 ms.

## Reading the numbers

- Every "read 1 page" number stays comfortably inside a comic reader's
  page-flip budget; random access holds (119 other pages untouched).
- The remaining gap on verified reads is the verify-by-default promise
  itself (package:archive performs no verification) plus the inflate
  throughput difference recorded in the M4 results.

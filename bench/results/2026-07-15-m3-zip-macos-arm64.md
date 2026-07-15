# ZIP benchmarks (M3, stored entries)

Produced by `dart run --no-enable-asserts bench/bin/zip_bench.dart`.

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- inputs: list = 20k entries x 64 B stored (5 MiB); cbz = 120 pages x 512 KiB stored (60 MiB)
- runs: best of 5 (after 2 warmup)
- baseline: package:archive 4.x (`ZipDecoder().decodeBytes`)

| scenario | koni_archive | package:archive | ratio |
| --- | --- | --- | --- |
| list 20k entries | 10.4 ms | 15.0 ms | 1.44x |
| open CBZ + read 1 page (CRC verified, default) | 1.8 ms | 0.1 ms | 0.03x |
| open CBZ + read 1 page (verifyChecksums: false) | 0.1 ms | 0.1 ms | 0.38x |

## Reading the numbers

- **list**: 1.4x faster — one bulk central-directory read + a linear parse.
- **page read**: package:archive does not verify checksums; with
  verification disabled the two are equal within noise (both ~0.1 ms —
  ratios at that scale are noise). The default-path cost is CRC-32 over the
  512 KiB page (~300 MiB/s single-table implementation) — the price of §7's
  verify-by-default. A sliced (multi-table) CRC-32 is the obvious future
  optimization if verified reads ever dominate a profile.
- Random access held: reading page 57 never touched the other 119 pages.

# TAR benchmarks (M2)

Produced by `dart run --no-enable-asserts bench/bin/tar_bench.dart`.

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- inputs: list = 20k entries x 512 B (20 MiB); extract = 256 entries x 256 KiB (64 MiB)
- runs: best of 5 (after 2 warmup)
- baseline: package:archive 4.x (`TarDecoder().decodeBytes`)

| scenario | koni_archive | package:archive | ratio |
| --- | --- | --- | --- |
| list 20k entries | 38.9 ms | 37.6 ms | 0.97x |
| sequential extract 64 MiB | 2.3 ms | 0.5 ms | 0.22x |

## Reading the numbers

- **list**: parity. Both walk one header per entry; koni_archive pays one
  `Future` per 512-byte header read against the `ByteSource` abstraction
  (which is what lets the same reader serve files, blobs, and future
  HTTP-range sources), package:archive requires the whole archive in memory
  first. A buffered header walk (one `read` per ~64 KiB span) is the obvious
  future optimization if listing ever dominates a profile.
- **extract**: for TAR both implementations are essentially slicing views
  over in-memory bytes (no decompression), so this measures streaming
  overhead, not throughput: 64 MiB in 2.3 ms ≈ 27 GiB/s. The 4.6x gap is
  the cost of 64 KiB chunked async streaming vs handing out one whole-file
  view per entry — the price of the bounded-memory guarantee (§10/§11),
  and irrelevant at these absolute numbers.

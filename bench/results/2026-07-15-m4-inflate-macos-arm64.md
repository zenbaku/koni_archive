# Inflate benchmarks (M4)

Produced by `dart run --no-enable-asserts bench/bin/inflate_bench.dart`.

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- input: 64 MiB payload of mixed compressibility, deflate level 6 (~18 MiB compressed)
- runs: best of 5 (after 2 warmup)

| decoder | time | throughput (decoded) |
| --- | --- | --- |
| koni_codecs InflateDecoder | 114.0 ms | 561 MiB/s |
| package:archive Inflate | 74.6 ms | 858 MiB/s |
| dart:io ZLibCodec (native) | 26.0 ms | 2464 MiB/s |

## Reading the numbers

- The decoder started at 282 MiB/s; two optimization passes (bulk window
  refresh at flush time instead of per-byte double writes, then an
  inflate_fast-style hot loop with local-cached bit state) brought it to
  561 MiB/s while keeping all 49 codec tests green.
- package:archive decodes into one whole-output pre-allocated buffer — the
  output *is* the window, no flushing, unbounded memory. koni_codecs is a
  chunk-driven state machine with bounded memory regardless of stream size
  (§6.4/§11); the remaining ~1.5x is largely that structural difference.
- Context for the flagship use case: a 512 KiB CBZ page decodes in ~1 ms.
- dart:io's native zlib is unavailable on the web, which is a Phase-1
  target (§1) — it is shown as a reference ceiling, not a baseline.

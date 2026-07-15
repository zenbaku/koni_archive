# LZMA-encode benchmarks (P2-4b)

Produced by `dart run --no-enable-asserts bench/bin/lzma_encode_bench.dart`.

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- runs: best of 5 (after 2 warmup)
- payloads: 8 MiB seeded pseudo-prose (Zipf-ish word draws); 8 MiB
  incompressible noise
- baseline: none — package:archive has no LZMA encoder; koni_codecs'
  DeflateEncoder runs on the same payloads as an in-repo reference

| encoder / payload | time | throughput | output | ratio |
| --- | --- | --- | --- | --- |
| LzmaEncoder, prose | 903.2 ms | 8.9 MiB/s | 1.70 MiB | 21.3% |
| Lzma2Encoder, prose | 880.3 ms | 9.1 MiB/s | 1.70 MiB | 21.3% |
| DeflateEncoder, prose (reference) | 1543.3 ms | 5.2 MiB/s | 2.07 MiB | 25.9% |
| LzmaEncoder, noise | 2881.2 ms | 2.8 MiB/s | 8.11 MiB | 101.4% |
| Lzma2Encoder, noise | 2500.0 ms | 3.2 MiB/s | 8.00 MiB | 100.0% |
| DeflateEncoder, noise (reference) | 454.0 ms | 17.6 MiB/s | 8.44 MiB | 105.4% |

## Reading the numbers

- **Prose (the compressible case):** the LZMA coders beat our own deflate
  on *both* time and ratio — the greedy+lazy parser with rep matches earns
  its keep. Against liblzma preset 6 on repo docs the ratio lands within
  ~1 point (44.9% vs 44.3% on README.md; 42.8% vs 41.9% on PROMPT_V1.md) —
  strong for a fast-mode parser; 7zz's optimal-price parser remains the
  deferred ratio lever.
- **Noise (the worst case):** every match probe fails, so throughput is
  bound by hash-chain probing over random memory. The input-scaled hash
  table (16–22 bits) is what keeps this at MiB/s — a fixed 2^17 table
  measured ~0.4 MiB/s on the same payload (~64 colliding candidates per
  bucket, each probe a cache miss). LZMA2's uncompressed-chunk fallback
  caps the size at 100.0% (+3 bytes per 64 KiB); LZMA1 has no fallback and
  expands ~1.4%. For real archives the incompressible path is CB7 images,
  which belong in Copy folders (see the 7z-write bench), not LZMA.
- Timings on this laptop drift ~2× run-to-run under thermal load; ratios
  are exact and stable. Treat times as order-of-magnitude.

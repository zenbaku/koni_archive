# Deflate-encode benchmarks (P2-3, ZIP writer)

Produced by `dart run --no-enable-asserts bench/bin/deflate_bench.dart`.

- date: 2026-07-15
- dart: 3.12.2 (stable) on macos_arm64 (Apple Silicon)
- os: macOS 26.2 (Build 25C56)
- input: 32 MiB mixed-compressibility payload (same shape the M4 inflate
  bench decodes)
- runs: best of 5 (after 2 warmup)
- baseline: package:archive 4.x (`Deflate`) and the platform zlib
  (`dart:io ZLibCodec` level 6, raw)

| encoder | time | throughput (input) | ratio |
| --- | --- | --- | --- |
| koni_codecs DeflateEncoder | 342.3 ms | 93 MiB/s | 16.40x |
| package:archive Deflate | 578.8 ms | 55 MiB/s | 28.73x |
| dart:io ZLibCodec level 6 (native) | 68.8 ms | 465 MiB/s | 15.35x |

## Reading the numbers

- Encoding is the ZIP-writer hot path (stored entries are a memcpy; the CPU
  goes into deflate). At 93 MiB/s the pure-Dart encoder is ~1.7x faster than
  package:archive's and, as expected, well behind native zlib, the price of
  no FFI, on a code path that runs identically on VM, dart2js, and dart2wasm.
- Ratio is honest about the documented ceiling. On this payload the encoder
  edges out native zlib level 6 (16.40x vs 15.35x) but trails
  package:archive (28.73x). The gap is exactly the deferred ratio work called
  out in `koni_codecs/doc/notes.md`: greedy (non-lazy) matching, fixed
  Huffman only, and no cross-block matching (matches never span a 32 KiB
  block). These are ratio improvements, not correctness ones; output is
  universally decodable (verified: dart:io zlib and Info-ZIP `unzip` both
  read koni_codecs deflate streams).
- The encoder is deliberately conservative for correctness first. Lazy
  matching and dynamic-Huffman blocks are the obvious next ratio levers if a
  future milestone wants to close the package:archive gap.

# zstd codec fixtures

Authored with `zstd` (Zstandard CLI v1.5.7) at level 19, most with `--check`
(XXH64 content checksum). Inputs are deterministic (reproduced in
`zstd_test.dart`). `concat.zst` = `tiny.zst` ++ `text.zst` (two frames).
Exercises: raw/RLE/compressed blocks, raw + Huffman literals (direct & FSE
weights, 1- and 4-stream), predefined + FSE-compressed sequence tables, repeat
offsets, overlapping matches, multi-block, multi-frame, and the checksum.

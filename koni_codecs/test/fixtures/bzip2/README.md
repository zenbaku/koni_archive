# bzip2 codec fixtures

Authored with `bzip2` (bzip2, a block-sorting file compressor. Version 1.0.8).
Inputs are deterministic (reproduced in `bzip2_test.dart`):

- `empty.bz2`   — empty input
- `tiny.bz2`    — `"hello bzip2 world\n"` (`bzip2 -9`)
- `text.bz2`    — `"the quick brown fox jumps over the lazy dog. " * 2000` (`bzip2 -9`)
- `multi.bz2`   — `(i*7 + (i>>3)) & 0xFF` for i in 0..259999 (`bzip2 -1`, 100 KiB blocks → multi-block)
- `random.bz2`  — an LCG byte stream, ~50 KiB, incompressible (`bzip2 -9`)
- `concat.bz2`  — `tiny.bz2` ++ `text.bz2` (concatenated streams)

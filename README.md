# koni_archive

Read and write archives in pure Dart (ZIP, TAR, gzip, xz, bzip2, zstd, 7z, and
RAR) through one API, on every platform Dart targets. No native code, no FFI, no
shelling out to `unzip` or `7z`.

It treats an archive as a random-access filesystem you stream out of: list the
entries, then pull the ones you want without holding the whole archive (or
even a whole entry) in memory. That makes it a good fit for comic and ebook
readers, which is where it started: open a CBZ, glob the pages, and decode
them one at a time.

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('volume01.cbz');
for (final page in archive.glob('*.png')) {
  final bytes = await archive.readBytes(page);
  // ...
}
await archive.close();
```

## What it does

- **Reads** ZIP, TAR, gzip (`.tar.gz`), xz (`.tar.xz`), bzip2 (`.tar.bz2`), zstd
  (`.tar.zst`), 7z, and RAR (CBZ, CBT, CB7, and CBR comics included).
- **Writes** ZIP, TAR, 7z, xz, bzip2, and zstd — 7z/xz with a pure-Dart
  LZMA/LZMA2 encoder, bzip2 with a from-scratch BWT/Huffman encoder, and zstd
  with a from-scratch tANS sequence encoder (LZ matches, raw literals).
- **Encrypts, both ways.** Decrypts ZIP (zipcrypto and WinZip AES), 7z
  (AES-256, encrypted headers included), and RAR5/RAR4; writes encrypted ZIP
  and 7z with AES-256.
- **Streams from anywhere.** Bounded memory for any entry size, plus an
  `HttpRangeByteSource` that reads a page out of a remote archive over HTTP
  without downloading the rest.
- **Runs where Dart runs**: the VM, Flutter, and the web under both dart2js
  and dart2wasm.

Every reader and writer is tested against the reference tools (`unzip`,
`bsdtar`, `7zz`, `rar`, `bzip2`, and liblzma for the LZMA codecs), fuzzed in CI,
and checked byte-for-byte against a corpus of real comic archives. RAR is the
one read-only format — writing it is barred by licensing, not by scope.

This is version **0.7.0** (0.6.0 was the first release on pub.dev). See
[ROADMAP.md](ROADMAP.md) for what's done and what's deferred.

## Packages

Most applications depend only on `koni_archive`, the facade.

| Package | What it is |
| --- | --- |
| [`koni_archive`](koni_archive/) | The facade: `Archive.open()`, every format registered (the package most apps use) |
| [`koni_archive_core`](koni_archive_core/) | Shared types: `ByteSource`, the entry model, exceptions, checksums, format detection |
| [`koni_codecs`](koni_codecs/) | Compression codecs (deflate, LZMA/LZMA2, both directions) and crypto primitives, usable on their own |
| [`koni_tar`](koni_tar/) | TAR reader and writer (ustar, PAX, GNU) |
| [`koni_zip`](koni_zip/) | ZIP reader and writer (ZIP64; zipcrypto and WinZip AES) |
| [`koni_gzip`](koni_gzip/) | gzip: a bare `.gz`, and `.tar.gz` presented as its inner TAR |
| [`koni_xz`](koni_xz/) | xz reader and writer: a bare `.xz` (write via LZMA2), and `.tar.xz` presented as its inner TAR |
| [`koni_bzip2`](koni_bzip2/) | bzip2: a bare `.bz2`, and `.tar.bz2` presented as its inner TAR (codec also backs ZIP method 12 and 7z) |
| [`koni_zstd`](koni_zstd/) | Zstandard: a bare `.zst`, and `.tar.zst` presented as its inner TAR |
| [`koni_sevenz`](koni_sevenz/) | 7z reader and writer (LZMA2 by default; AES-256) |
| [`koni_rar`](koni_rar/) | RAR4/RAR5 reader, clean-room |
| [`koni_http_source`](koni_http_source/) | An `HttpRangeByteSource` for reading a remote archive without downloading it |
| [`bench`](bench/) | Benchmarks; a workspace member, never published |

## Development

This is a [pub workspace](https://dart.dev/tools/pub/workspaces), Dart 3.7 or
newer. With [Task](https://taskfile.dev) installed, `task verify` runs the
formatter, the analyzer, and the full test matrix; `task --list` shows the
rest. The raw commands:

```sh
dart pub get
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed .
dart run tool/run_tests.dart --platform vm
dart run tool/run_tests.dart --platform chrome --compiler dart2js
dart run tool/run_tests.dart --platform chrome --compiler dart2wasm
```

Test fixtures are generated once by `tool/generate_fixtures.dart` on a machine
that has the reference tools, then committed, so CI never needs the tools
itself. The conformance suite compares against a private corpus of real
archives; it reads the corpus path from `KONI_ARCHIVE_CORPUS_DIR` and skips
when that isn't set.

## License

MIT. See [LICENSE](LICENSE). Each package carries its own copy.

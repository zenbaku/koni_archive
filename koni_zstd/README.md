# koni_zstd

Zstandard reader and writer for the
[koni_archive](https://github.com/zenbaku/koni_archive) ecosystem: a bare `.zst`
opens as a single-entry archive, and `.tar.zst`/`.tzst` opens as the inner TAR
via layered detection. Writing produces a `.zst` that `zstd` / libzstd decode
byte-for-byte. Pure Dart, runs everywhere Dart runs including the web (dart2js
and dart2wasm).

Most applications should depend on the `koni_archive` facade, which
registers this format automatically:

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('logs.zst'); // auto-detected
final entry = archive.entries.single;              // name from the file name
await for (final chunk in archive.openRead(entry)) {
  // bounded-memory streaming
}
```

Writing compresses one byte stream (`.zst` is a single-member container) with
`ZstdWriteFormat`:

```dart
import 'package:koni_archive/io.dart';

final sink = BytesBuilderSink();
final writer = Archive.create(sink, format: const ZstdWriteFormat());
await writer.addBytes(ArchiveEntrySpec(path: 'logs.txt'), bytes);
await writer.close();
await sink.close();
// sink.takeBytes() is a valid .zst, decodable by `zstd -d`.
```

The writer is correctness-first: LZ sequences over the **predefined** FSE tables,
plus **Huffman** literal coding when it beats storing literals raw (the ratio is
still below `zstd`'s, which also compresses the sequence tables and searches
harder). `.zst` stores no filename, so a write-then-read round trip preserves the
*content*, not the entry name. It has no encryption, so a password is rejected.

Decodes the Zstandard format (RFC 8878) via `koni_codecs`: FSE + Huffman
entropy coding, sequences with repeat offsets, back-reference matches, one
block (≤ 128 KiB) at a time. Concatenated frames and skippable frames are
handled, and the XXH64 content checksum is verified on platforms with native
64-bit integers (skipped under dart2js/dart2wasm — decode correctness does not
depend on it). `.zst` carries no filename and may omit the decompressed size,
so the single entry is named from the container and its `uncompressedSize` is
`-1` (unknown). Typed errors: dictionary-compressed frames and the legacy
(v0.x) formats.

See [doc/features.md](doc/features.md) for the matrix and
[doc/notes.md](doc/notes.md) for design decisions.

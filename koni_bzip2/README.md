# koni_bzip2

BZip2 reader and writer for the
[koni_archive](https://github.com/zenbaku/koni_archive) ecosystem: a bare `.bz2`
opens as a single-entry archive, and `.tar.bz2`/`.tbz2` opens as the inner TAR
via layered detection. Writing produces a `.bz2` that `bzip2` / libbz2 decode
byte-for-byte. Pure Dart, runs everywhere Dart runs including the web (dart2js
and dart2wasm).

Most applications should depend on the `koni_archive` facade, which
registers this format automatically:

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('logs.bz2'); // auto-detected
final entry = archive.entries.single;              // name from the file name
await for (final chunk in archive.openRead(entry)) {
  // bounded-memory streaming; block/stream CRCs verified by the codec
}
```

Writing compresses one byte stream (`.bz2` is a single-member container) with
`Bzip2WriteFormat`:

```dart
import 'package:koni_archive/io.dart';

final sink = BytesBuilderSink();
final writer = Archive.create(sink, format: const Bzip2WriteFormat());
await writer.addBytes(ArchiveEntrySpec(path: 'logs.txt'), bytes);
await writer.close();
await sink.close();
// sink.takeBytes() is a valid .bz2, decodable by `bzip2 -d`.
```

`Bzip2WriteFormat(blockSize100k: 1..9)` selects the block size like `bzip2
-1`..`-9` (9 is the default and the best ratio). `.bz2` stores no filename, so a
write-then-read round trip preserves the *content*, not the entry name. It has
no encryption, so a password is rejected.

Decodes the bzip2 format (`BZh1`–`BZh9`) via `koni_codecs`, one block (≤ 900 KiB)
at a time so memory stays bounded regardless of entry size. Concatenated streams
are handled. `.bz2` stores no filename, timestamp, or decompressed size, so the
single entry is named from the container and its `uncompressedSize` is `-1`
(unknown) — reading the entry still yields the full content. Randomized blocks (a
deprecated pre-0.9 bzip2 feature) are a typed error.

The same codec also decodes bzip2 inside **ZIP** (method 12) and **7z** (the
BZip2 coder) — those live in `koni_zip` and `koni_sevenz`.

See [doc/features.md](doc/features.md) for the matrix and
[doc/notes.md](doc/notes.md) for design decisions.

# koni_bzip2

BZip2 adapter for the [koni_archive](https://github.com/zenbaku/koni_archive)
ecosystem: a bare `.bz2` opens as a single-entry archive, and
`.tar.bz2`/`.tbz2` opens as the inner TAR via layered detection. Pure Dart,
runs everywhere Dart runs including the web (dart2js and dart2wasm).

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

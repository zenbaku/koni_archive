# koni_xz

XZ reader and writer for the [koni_archive](https://github.com/zenbaku/koni_archive)
ecosystem: a bare `.xz` opens as a single-entry archive, and
`.tar.xz`/`.txz` opens as the inner TAR via layered detection. Pure Dart,
runs everywhere Dart runs including the web (dart2js and dart2wasm).

Most applications should depend on the `koni_archive` facade, which
registers this format automatically:

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('logs.xz'); // auto-detected
final entry = archive.entries.single;             // name from the file name
await for (final chunk in archive.openRead(entry)) {
  // bounded-memory streaming; the block check (CRC-64 by default) verified
}
```

**Reading:** the `.xz` container is decoded block by block — each block's LZMA2
payload is decompressed into a buffer sized from the stream index, its transform
filters (delta / x86 BCJ) are reverse-applied, and its integrity check (None,
CRC-32, CRC-64, or SHA-256) is verified. Concatenated streams and multi-block
files (`xz -T0`) are handled. `.xz` stores no filename or timestamp, so the
single entry is named from the container.

**Writing** (`XzWriteFormat`): compresses one byte stream with LZMA2 as a single
block with a CRC-64 check, the output decodable by `xz` / liblzma:

```dart
import 'package:koni_archive/koni_archive.dart';

final sink = BytesBuilderSink();
final writer = Archive.create(sink, format: const XzWriteFormat());
await writer.addBytes(ArchiveEntrySpec(path: 'data'), bytes);
await writer.close();
await sink.close();
final xz = sink.takeBytes();
```

`.xz` is a single-member container, so the writer takes exactly one entry and
has no encryption. See [doc/features.md](doc/features.md) for the matrix and
[doc/notes.md](doc/notes.md) for design decisions.

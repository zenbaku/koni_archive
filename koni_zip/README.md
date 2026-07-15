# koni_zip

ZIP reader for the [koni_archive](https://github.com/koni-archive)
ecosystem, including CBZ comic archives — pure Dart, runs everywhere Dart
runs including the web (dart2js and dart2wasm).

Most applications should depend on the `koni_archive` facade, which
registers this format automatically:

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('volume01.cbz'); // auto-detected
final page = archive.glob('*.png').first;
await for (final chunk in archive.openRead(page)) {
  // bounded-memory streaming; CRC-32 verified by default
}
```

Stored and deflated entries stream end-to-end with CRC-32 verification —
CBZ works, validated against a real-world corpus via reference-tool
manifests. Exotic methods, encrypted entries, and ZIP64 are detected with
typed errors that never brick the rest of the archive. See
[doc/features.md](doc/features.md) for the full matrix and
[doc/notes.md](doc/notes.md) for design decisions.

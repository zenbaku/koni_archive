# koni_gzip

GZIP adapter for the [koni_archive](https://github.com/koni-archive)
ecosystem — a bare `.gz` opens as a single-entry archive; `.tar.gz`
layering arrives with M6. Pure Dart, runs everywhere Dart runs including
the web (dart2js and dart2wasm).

Most applications should depend on the `koni_archive` facade, which
registers this format automatically:

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('logs.gz'); // auto-detected
final entry = archive.entries.single;             // name from FNAME
await for (final chunk in archive.openRead(entry)) {
  // bounded-memory streaming; CRC-32/ISIZE verified per member
}
```

See [doc/features.md](doc/features.md) for the matrix and
[doc/notes.md](doc/notes.md) for design decisions.

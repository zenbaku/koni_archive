# koni_tar

TAR reader + writer (ustar, PAX, GNU extensions) for the
[koni_archive](https://github.com/koni-archive) ecosystem — pure Dart, runs
everywhere Dart runs including the web (dart2js and dart2wasm).

Most applications should depend on the `koni_archive` facade, which
registers this format automatically:

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('comics.cbt'); // format auto-detected
final page = archive.glob('*.png').first;
await for (final chunk in archive.openRead(page)) {
  // bounded-memory streaming
}
```

Depend on `koni_tar` directly only to build a custom format registry:

```dart
import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/koni_tar.dart';

final registry = ArchiveFormatRegistry([const TarFormat()]);
final reader = await registry.openReader(source);
```

Reading: ustar, PAX (per-file + global), GNU long names/links, v7,
base-256 fields, all entry types as metadata. GNU sparse entries are
detected and throw a typed error (deferred). Writing emits ustar with PAX
extensions where needed, from streaming input — interop-verified against
bsdtar. See
[doc/features.md](doc/features.md) for the full matrix and
[doc/notes.md](doc/notes.md) for design decisions.

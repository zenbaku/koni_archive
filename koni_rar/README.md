# koni_rar

Clean-room RAR4/RAR5 reader for the
[koni_archive](https://github.com/koni-archive) ecosystem, including CBR
comic archives — pure Dart, runs everywhere Dart runs including the web
(dart2js and dart2wasm).

Most applications should depend on the `koni_archive` facade, which
registers this format automatically:

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('volume01.cbr'); // auto-detected
final page = archive.glob('*.jpg').first;
await for (final chunk in archive.openRead(page)) {
  // clean-room RAR5 decode, CRC-verified
}
```

Current scope (M9): RAR5 store + compressed (methods 1–5), solid and
non-solid, with delta/x86/ARM filters. RAR4 is the next milestone (M10);
until then it is detected and reported with a typed error. Multi-volume
and encrypted archives are typed errors.

**Provenance:** clean-room implementation — see
[doc/rar-provenance.md](doc/rar-provenance.md) (the owner-approved policy)
and [doc/references.md](doc/references.md) / [NOTICE](NOTICE) for
attribution. No unrar or GPL source was consulted. See
[doc/features.md](doc/features.md) and [doc/notes.md](doc/notes.md).

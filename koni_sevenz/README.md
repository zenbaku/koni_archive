# koni_sevenz

7z reader + writer for the [koni_archive](https://github.com/koni-archive)
ecosystem, including CB7 comic archives — pure Dart, runs everywhere Dart
runs including the web (dart2js and dart2wasm).

Most applications should depend on the `koni_archive` facade, which
registers this format automatically:

```dart
import 'package:koni_archive/io.dart';

final archive = await openArchiveFile('volume01.cb7'); // auto-detected
final pages = archive.glob('*.png').toList();
// First read decodes the solid block once; flips then hit the LRU cache.
final page = await archive.readBytes(pages[0], maxSize: 50 << 20);
```

Reading: LZMA/LZMA2/Copy/Deflate folders with Delta/BCJ(x86) filter
chains, solid blocks (size-capped LRU cache), compressed headers, CRC
verification by default. AES-256-encrypted archives — including encrypted
headers (`-mhe`) — decrypt via `ArchiveReadOptions.password`. BCJ2 and
PPMd are detected with typed errors.

Writing: LZMA2 folders by default (Copy per entry via
`ArchiveCompression.stored`), compressed headers, with the ecosystem's own
pure-Dart LZMA/LZMA2 encoder — interop-verified against 7zz.

See [doc/features.md](doc/features.md) and [doc/notes.md](doc/notes.md).

# koni_sevenz

7z reader for the [koni_archive](https://github.com/koni-archive)
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

Supported: LZMA/LZMA2/Copy/Deflate folders with Delta/BCJ(x86) filter
chains, solid blocks (size-capped LRU cache), compressed headers,
CRC verification by default. BCJ2/PPMd/AES are detected with typed errors.
See [doc/features.md](doc/features.md) and [doc/notes.md](doc/notes.md).

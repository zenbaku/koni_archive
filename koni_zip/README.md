# koni_zip

ZIP reader + writer for the [koni_archive](https://github.com/zenbaku/koni_archive)
ecosystem, including CBZ comic archives. Pure Dart, runs everywhere Dart
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

Stored and deflated entries stream end-to-end with CRC-32 verification,
ZIP64 included; CBZ works, validated against a real-world corpus via
reference-tool manifests. Password-protected archives, both traditional
PKWARE ("zipcrypto") and WinZip AES, decrypt when you pass
`ArchiveReadOptions.password`. Writing emits stored + deflate with ZIP64
where needed, interop-verified against Info-ZIP unzip; pass
`ArchiveWriteOptions.password` to encrypt with WinZip AES-256 (AE-2),
verified against 7-Zip. Exotic compression methods and ZIP strong
encryption (SES) are detected with typed errors that never brick the rest
of the archive. See
[doc/features.md](doc/features.md) for the full matrix and
[doc/notes.md](doc/notes.md) for design decisions.

# koni_rar

Clean-room RAR4/RAR5 reader for the
[koni_archive](https://github.com/zenbaku/koni_archive) ecosystem, including CBR
comic archives. Pure Dart, runs everywhere Dart runs including the web
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

Current scope: RAR5 store + compressed (methods 1–5), solid and non-solid,
with delta/x86/ARM filters; RAR4 store + method-29 (the classic v29
LZSS/Huffman), **solid**, the **RarVM filters** (the standard delta/x86/RGB/
audio programs plus a generic interpreter for any other program), **PPMd
variant H** (`-mct`, solid and non-solid, including a mid-file PPMd→method-29
switch), and **RAR 2.0/2.6** (v20/v26) LZ. Password-protected file data *and*
**encrypted headers (`-hp`)** decrypt for both generations via
`ArchiveReadOptions.password`: RAR5 (AES-256, PBKDF2-HMAC-SHA256, check-value
verification) and RAR4 (AES-128, iterated-SHA-1 KDF). **Multi-volume** sets
read via `ArchiveReadOptions.nextVolume`. Remaining typed errors are
narrow and rare (a filter reached *through* a PPMd escape, a solid-run
mid-file switch, RAR 1.5, the RAR 2.x audio block); RAR *writing* is out of
scope. See [doc/features.md](doc/features.md) for the full matrix.

**Provenance:** clean-room implementation. See
[doc/rar-provenance.md](doc/rar-provenance.md) (the owner-approved policy)
and [doc/references.md](doc/references.md) / [NOTICE](NOTICE) for
attribution. No unrar or GPL source was consulted. See
[doc/features.md](doc/features.md) and [doc/notes.md](doc/notes.md).

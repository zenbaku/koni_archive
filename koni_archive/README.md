# koni_archive

Format-agnostic archive reading and writing for pure Dart — one
streaming-first API that reads ZIP/CBZ, TAR/CBT, GZIP (incl. `.tar.gz`),
7z/CB7, and RAR/CBR, and writes ZIP, TAR, and 7z (7z with a pure-Dart
LZMA/LZMA2 encoder). No native code, no FFI, no external executables. Runs
everywhere Dart runs: the VM, Flutter (all platforms), and the web via
**both dart2js and dart2wasm**.

## Quick start

```dart
import 'package:koni_archive/io.dart'; // VM/Flutter; web.dart for browsers

final archive = await openArchiveFile('volume01.cbz'); // format auto-detected

for (final entry in archive.glob('*.png')) {
  print('${entry.path}  ${entry.uncompressedSize} B');
}

// Streaming is the primary API: bounded memory for any entry size.
await for (final chunk in archive.openReadPath('page001.png')) {
  sink.add(chunk);
}

// Whole-entry convenience, with decompression-bomb protection.
final bytes = await archive.readBytes(entry, maxSize: 50 << 20);

await archive.close();
```

Password-protected archives (ZIP zipcrypto/AES, 7z AES-256 incl. encrypted
headers, RAR5/RAR4) decrypt transparently — supply the password at open:

```dart
final archive = await openArchiveFile(
  'locked.cbz',
  options: const ArchiveReadOptions(password: 'hunter2'),
);
```

On the web, open a user-picked file without downloading it into memory:

```dart
import 'package:koni_archive/web.dart';

final archive = await openArchiveBlob(fileInput.files!.item(0)!);
```

Writing mirrors reading — pick a format, add entries, close:

```dart
final writer = await createArchiveFile(
  'volume01.cb7',
  format: const SevenZWriteFormat(), // or ZipWriteFormat, TarWriteFormat
);
await writer.addBytes(ArchiveEntrySpec(path: 'page001.png'), pngBytes);
await writer.close();
```

Every writer's output is interop-verified against its reference tool (7zz,
Info-ZIP unzip, bsdtar) in CI-facing tests; 7z defaults to LZMA2 folders
with compressed headers, and already-compressed content can opt into
`ArchiveCompression.stored` per entry.

## The virtual-filesystem model

An `Archive` is a read-only virtual filesystem: you never care which format
is underneath.

- `entries` — the raw index, in archive order, duplicates included.
- `entry(path)` / `exists(path)` — exact, case-sensitive lookup; duplicate
  paths resolve last-wins.
- `walk()`, `files`, `directories` — the VFS view: one node per unique
  path, implicit parent directories synthesized (many ZIPs omit them),
  depth-first pre-order.
- `glob('ch01/*.webp')` — pattern matching over the VFS view.

All entry paths are normalized and sanitized at parse time (`/` separators,
no drive letters, no `..` escapes — attempts are flagged on the entry, never
followed). Checksums are verified by default; symlinks are metadata only.

## Concurrency and the isolate pattern (Flutter)

Multiple entry streams may be open simultaneously — a reader preloads page
N+1 while displaying page N:

```dart
final current = archive.readBytes(pages[n]);
final next = archive.readBytes(pages[n + 1]); // in flight concurrently
```

Decompression is CPU-bound. In Flutter apps, wrap whole-entry reads in
`Isolate.run` so the UI thread never janks — entries are immutable and
isolate-transferable by design:

```dart
final page = await Isolate.run(() async {
  final archive = await openArchiveFile(path);
  try {
    return await archive.readBytes(archive.entry(pagePath)!);
  } finally {
    await archive.close();
  }
});
```

(On the web, isolates don't exist; calls run inline — which is why nothing
in this API *requires* them.)

## Why not package:archive?

`package:archive` is a fine general-purpose library; koni_archive exists
for a different job — treating archives as random-access virtual
filesystems for streaming consumption:

| | koni_archive | package:archive |
| --- | --- | --- |
| Read model | random access via `ByteSource` (file, blob, memory; HTTP-range possible) | whole archive bytes in memory (or VM-only file APIs) |
| Entry content | single-subscription streams, bounded memory at any size | whole entry buffers |
| Open cost | metadata only — no content decode | varies; content slices held per file |
| Checksums | verified by default, typed error on mismatch | not verified on read |
| Hostile input | typed `ArchiveException` hierarchy, fuzzed in CI, path sanitization + escape flags | assorted exceptions |
| Formats | open registry — third-party formats plug in | fixed set |
| Web | dart2js **and** dart2wasm tested in CI | dart2js |
| Writing | TAR, ZIP, 7z (pure-Dart LZMA/LZMA2 encoder), interop-verified | yes |

If you are building a comic/ebook reader, file explorer, or anything that
streams files out of archives, this is the library shaped for it.

## Errors

Everything archive-related throws a typed `ArchiveException`:
`UnsupportedFormatException`, `CorruptArchiveException`,
`UnexpectedEofException`, `ChecksumMismatchException`,
`EncryptedArchiveException` (a password is required),
`InvalidPasswordException` (the supplied password is wrong, where the
format carries a check value), `UnsupportedCompressionException` (naming
the method), and friends. Entry-scoped problems surface when *reading that
entry* — one exotic entry never bricks the archive.

## Status

`0.5.0` (git-only, lockstep releases) — reading, writing, and read-side
decryption are complete. ZIP/CBZ (stored + deflate, ZIP64), TAR/CBT
(ustar/PAX/GNU), GZIP (multi-member, layered `.tar.gz`), 7z/CB7
(LZMA/LZMA2/BCJ/delta, solid-block cache), and RAR/CBR (clean-room RAR5 +
RAR4) read; TAR, ZIP, and 7z write; password-protected ZIP, 7z, and RAR
archives decrypt via `ArchiveReadOptions.password`. All of it is tested
against reference tools, differential-tested against package:archive,
fuzzed in CI, and verified on the VM, dart2js, and dart2wasm. What remains
(write-side encryption, RAR `-hp` headers, multi-volume, …) is tracked in
`ROADMAP.md` at the repository root.

See `example/` for a CBZ page extractor demonstrating streaming +
preloading.

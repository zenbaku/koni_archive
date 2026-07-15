# koni_archive

Format-agnostic archive reading for pure Dart — one streaming-first API over
ZIP/CBZ, TAR/CBT, and GZIP today, with 7z/CB7 and RAR/CBR on the roadmap.
No native code, no FFI, no external executables. Runs everywhere Dart runs:
the VM, Flutter (all platforms), and the web via **both dart2js and
dart2wasm**.

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

On the web, open a user-picked file without downloading it into memory:

```dart
import 'package:koni_archive/web.dart';

final archive = await openArchiveBlob(fileInput.files!.item(0)!);
```

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
| Writing | not yet (Phase 2) | yes |

If you need archive *writing* today, use `package:archive`. If you are
building a comic/ebook reader, file explorer, or anything that streams
files out of archives, this is the library shaped for it.

## Errors

Everything archive-related throws a typed `ArchiveException`:
`UnsupportedFormatException`, `CorruptArchiveException`,
`UnexpectedEofException`, `ChecksumMismatchException`,
`EncryptedArchiveException`, `UnsupportedCompressionException` (naming the
method), and friends. Entry-scoped problems surface when *reading that
entry* — one exotic entry never bricks the archive.

## Status

`0.1.0` — ZIP (stored + deflate, CBZ), TAR (ustar/PAX/GNU, CBT), and GZIP
are tested against reference tools, differential-tested against
package:archive, and fuzzed in CI. ZIP64 and encrypted entries are detected
with typed errors. 7z (CB7) and RAR (CBR) are the next milestones — see
`ROADMAP.md` at the repository root.

See `example/` for a CBZ page extractor demonstrating streaming +
preloading.

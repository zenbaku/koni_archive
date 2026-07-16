// CBZ/CBT page extractor: the flagship streaming + preloading flow.
//
//   dart run example/extract_pages.dart <archive.cbz> [outputDir]
//
// Demonstrates:
//   - format-agnostic opening (the same code handles CBZ, CBT, .gz, ...)
//   - the VFS view (glob over normalized paths)
//   - bounded-memory streaming to disk
//   - reader-style preloading: page N+1 decodes while page N writes

import 'dart:io';

import 'package:koni_archive/io.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run example/extract_pages.dart '
      '<archive.cbz> [outputDir]',
    );
    exitCode = 64;
    return;
  }
  final outputDir = Directory(args.length > 1 ? args[1] : 'pages')
    ..createSync(recursive: true);

  final archive = await openArchiveFile(args[0]);
  try {
    stdout.writeln('format: ${archive.format.name}');

    // Comic pages: images anywhere in the archive, in reading order.
    final pages = [
      for (final ext in ['png', 'jpg', 'jpeg', 'webp', 'gif'])
        ...archive.glob('**.$ext'),
    ]..sort((a, b) => a.path.compareTo(b.path));
    stdout.writeln('${pages.length} page(s)');

    // Stream each page to disk while the NEXT page is already decoding;
    // multiple entry streams are first-class.
    Future<void>? inFlight;
    for (var i = 0; i < pages.length; i++) {
      final current = inFlight ?? _extract(archive, pages[i], outputDir);
      inFlight =
          i + 1 < pages.length
              ? _extract(archive, pages[i + 1], outputDir)
              : null;
      await current;
    }
    await inFlight;

    stdout.writeln('extracted to ${outputDir.path}/');
  } on ArchiveException catch (e) {
    stderr.writeln('cannot read archive: $e');
    exitCode = 1;
  } finally {
    await archive.close();
  }
}

Future<void> _extract(
  Archive archive,
  ArchiveEntry page,
  Directory outputDir,
) async {
  // Flatten the path for output; the entry path is already sanitized.
  final name = page.path.replaceAll('/', '_');
  final sink = File('${outputDir.path}/$name').openWrite();
  try {
    // Bounded memory regardless of page size: chunks flow straight to disk.
    await sink.addStream(archive.openRead(page));
  } finally {
    await sink.close();
  }
}

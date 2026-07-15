@TestOn('vm')
library;

import 'dart:convert';

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// End-to-end proof of the architecture (M2 exit criterion): a real
/// bsdtar-generated CBT through the facade — detection, VFS view, glob,
/// streaming — with zero format-specific code in sight.
void main() {
  const cbt = '../koni_tar/test/fixtures/tar/synthetic_comic.cbt';

  test('a CBT comic opens, lists, globs, and streams via the facade', () async {
    final archive = await openArchiveFile(cbt);
    addTearDown(archive.close);

    expect(archive.format.name, 'tar');
    expect(archive.exists('comic/ComicInfo.xml'), isTrue);

    final pages = archive.glob('comic/*.png').toList();
    expect(pages.map((e) => e.path), [
      'comic/page001.png',
      'comic/page002.png',
      'comic/page003.png',
    ]);

    // Preload-style concurrent reads (§4).
    final contents = await Future.wait([
      for (final page in pages) archive.readBytes(page, maxSize: 1 << 20),
    ]);
    for (final content in contents) {
      expect(content.take(8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(content, hasLength(1032));
    }

    final info = utf8.decode(
      await archive.readBytes(archive.entry('comic/ComicInfo.xml')!),
    );
    expect(info, contains('Synthetic'));
  });

  test('builtInFormats registers tar', () {
    expect(builtInFormats.formats.map((f) => f.name), contains('tar'));
  });
}

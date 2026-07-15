@TestOn('vm')
library;

import 'dart:convert';

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// The CB7 flagship flow (§1/§8) through the facade against a real
/// 7zz-generated solid archive.
void main() {
  const cb7 = '../koni_sevenz/test/fixtures/sevenz/synthetic_comic.cb7';

  test('a solid CB7 opens, globs, and page-flips via the facade', () async {
    final archive = await openArchiveFile(cb7);
    addTearDown(archive.close);

    expect(archive.format.name, '7z');
    final pages = archive.glob('comic/*.png').toList();
    expect(pages, hasLength(3));
    expect(pages.first.compression.name, 'lzma2');

    // Page-flip with preload (§4): the solid block decodes once, then the
    // LRU cache serves every page.
    final contents = await Future.wait([
      for (final page in pages) archive.readBytes(page, maxSize: 1 << 20),
    ]);
    for (final content in contents) {
      expect(content, hasLength(1032));
      expect(content.take(8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }
    expect(
      utf8.decode(
        await archive.readBytes(archive.entry('comic/ComicInfo.xml')!),
      ),
      contains('Synthetic'),
    );
  });

  test('builtInFormats includes 7z after zip', () {
    expect(
      builtInFormats.formats.map((f) => f.name).toList(),
      containsAllInOrder(<String>['zip', '7z', 'tar']),
    );
  });
}

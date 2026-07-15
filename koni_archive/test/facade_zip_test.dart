@TestOn('vm')
library;

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// The CBZ flagship flow (§1) through the facade against a real
/// zip(1)-generated fixture, plus detection-order sanity.
void main() {
  const cbz = '../koni_zip/test/fixtures/zip/synthetic_comic.cbz';
  const cbzDeflated =
      '../koni_zip/test/fixtures/zip/synthetic_comic_deflated.cbz';

  test('a stored CBZ opens, globs, and streams via the facade', () async {
    final archive = await openArchiveFile(cbz);
    addTearDown(archive.close);

    expect(archive.format.name, 'zip');
    final pages = archive.glob('comic/*.png').toList();
    expect(pages, hasLength(3));

    // Reader-style page flip: preload next page while reading the current.
    final contents = await Future.wait([
      for (final page in pages) archive.readBytes(page, maxSize: 1 << 20),
    ]);
    for (final content in contents) {
      expect(content.take(8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }
  });

  test('a deflated CBZ works end-to-end (M5 exit criterion)', () async {
    final archive = await openArchiveFile(cbzDeflated);
    addTearDown(archive.close);

    expect(archive.format.name, 'zip');
    final pages = archive.glob('comic/*.png').toList();
    expect(pages, hasLength(3));
    expect(pages.first.compression.name, 'deflate');

    // Page-flip with preload: read page N while preloading N+1 (§4).
    final contents = await Future.wait([
      for (final page in pages) archive.readBytes(page, maxSize: 1 << 20),
    ]);
    for (final content in contents) {
      expect(content, hasLength(1032));
      expect(content.take(8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }
  });

  test('builtInFormats probes zip before tar (precise magic first)', () {
    expect(
      builtInFormats.formats.map((f) => f.name).toList(),
      containsAllInOrder(<String>['zip', 'tar']),
    );
  });
}

@TestOn('vm')
library;

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// The CBR flagship flow (§1/§8) through the facade against a real
/// rar-generated compressed archive.
void main() {
  const cbr = '../koni_rar/test/fixtures/rar/synthetic_comic.cbr';

  test('a compressed CBR opens, globs, and streams via the facade', () async {
    final archive = await openArchiveFile(cbr);
    addTearDown(archive.close);

    expect(archive.format.name, 'rar');
    final pages = archive.glob('comic/*.png').toList();
    expect(pages, hasLength(3));

    final contents = await Future.wait([
      for (final page in pages) archive.readBytes(page, maxSize: 1 << 20),
    ]);
    for (final content in contents) {
      expect(content, hasLength(1032));
      expect(content.take(8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }
  });

  test('builtInFormats registers all six formats in detection order', () {
    expect(builtInFormats.formats.map((f) => f.name).toList(), [
      'zip',
      '7z',
      'rar',
      'gzip',
      'tar',
    ]);
  });
}

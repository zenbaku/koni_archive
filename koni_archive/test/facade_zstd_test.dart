@TestOn('vm')
library;

import 'dart:convert';

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// A bare `.zst` and a layered `.tar.zst` through the facade: auto-detection,
/// single-entry vs inner-TAR presentation.
void main() {
  test('a .zst opens as a single-entry archive via the facade', () async {
    final archive = await openArchiveFile(
      '../koni_zstd/test/fixtures/zstd/hello.zst',
    );
    addTearDown(archive.close);

    expect(archive.format.name, 'zstd');
    expect(archive.entries, hasLength(1));
    final entry = archive.entries.single;
    expect(entry.uncompressedSize, -1);
    expect(utf8.decode(await archive.readBytes(entry)), 'hello, zstd!\n' * 4);
  });

  test('a .tar.zst presents as the inner TAR (layering)', () async {
    final archive = await openArchiveFile(
      '../koni_zstd/test/fixtures/zstd/sample.tar.zst',
    );
    addTearDown(archive.close);

    expect(archive.format.name, 'tar', reason: 'the inner format wins');
    expect(
      archive.entries.map((e) => e.path),
      containsAll(<String>['hello.txt', 'prose.bin']),
    );
    final prose = await archive.readBytes(archive.entry('prose.bin')!);
    expect(prose, hasLength(90000));
  });
}

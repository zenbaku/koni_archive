@TestOn('vm')
library;

import 'dart:convert';

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// A bare `.bz2` and a layered `.tar.bz2` through the facade: auto-detection,
/// single-entry vs inner-TAR presentation.
void main() {
  test('a .bz2 opens as a single-entry archive via the facade', () async {
    final archive = await openArchiveFile(
      '../koni_bzip2/test/fixtures/bzip2/hello.bz2',
    );
    addTearDown(archive.close);

    expect(archive.format.name, 'bzip2');
    expect(archive.entries, hasLength(1));
    final entry = archive.entries.single;
    expect(entry.uncompressedSize, -1, reason: 'bzip2 records no size');
    expect(utf8.decode(await archive.readBytes(entry)), 'hello, bzip2!\n' * 4);
  });

  test('a .tar.bz2 presents as the inner TAR (layering)', () async {
    final archive = await openArchiveFile(
      '../koni_bzip2/test/fixtures/bzip2/sample.tar.bz2',
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

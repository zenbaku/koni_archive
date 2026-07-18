@TestOn('vm')
library;

import 'dart:convert';

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// A bare `.gz` through the facade: single-entry archive, name from FNAME,
/// streaming decode with verification.
void main() {
  const gz = '../koni_gzip/test/fixtures/gzip/hello.txt.gz';

  test('a .gz opens as a single-entry archive via the facade', () async {
    final archive = await openArchiveFile(gz);
    addTearDown(archive.close);

    expect(archive.format.name, 'gzip');
    expect(archive.entries, hasLength(1));
    expect(archive.exists('hello.txt'), isTrue);
    expect(
      utf8.decode(await archive.readBytes(archive.entry('hello.txt')!)),
      'hello, gzip!\n',
    );
  });

  test('a .tar.gz presents as the inner TAR (layering, M6)', () async {
    final archive = await openArchiveFile(
      '../koni_gzip/test/fixtures/gzip/tarball.tar.gz',
    );
    addTearDown(archive.close);

    expect(archive.format.name, 'tar', reason: 'the inner format wins');
    expect(archive.entries.map((e) => e.path), [
      'hello.txt',
      'second.txt',
      'data.bin',
    ]);
    expect(
      utf8.decode(await archive.readBytes(archive.entry('hello.txt')!)),
      'hello, gzip!\n',
    );
    // Random access to the LAST entry: sequential decode + cache behind
    // the scenes, transparent here.
    final data = await archive.readBytes(archive.entry('data.bin')!);
    expect(data, hasLength(100000));
    expect(data[99999], (99999 * 7 + 99) & 0xFF);
    // And backwards again, served from cache.
    expect(
      utf8.decode(await archive.readBytes(archive.entry('second.txt')!)),
      'second member content\n',
    );
  });

  test('builtInFormats order: precise magics first, tar last', () {
    expect(builtInFormats.formats.map((f) => f.name).toList(), [
      'zip',
      '7z',
      'rar',
      'gzip',
      'xz',
      'bzip2',
      'zstd',
      'tar',
    ]);
  });
}

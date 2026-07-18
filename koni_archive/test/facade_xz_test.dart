@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// A bare `.xz` and a layered `.tar.xz` through the facade: auto-detection,
/// single-entry vs inner-TAR presentation, streaming decode with verification.
void main() {
  const hello =
      'Hello, xz world!\nHello, xz world!\nHello, xz world!\n'
      'Hello, xz world!\n';

  test('a .xz opens as a single-entry archive via the facade', () async {
    final archive = await openArchiveFile(
      '../koni_xz/test/fixtures/xz/hello_crc64.xz',
    );
    addTearDown(archive.close);

    expect(archive.format.name, 'xz');
    expect(archive.entries, hasLength(1));
    final entry = archive.entries.single;
    expect(utf8.decode(await archive.readBytes(entry)), hello);
  });

  test('a .tar.xz presents as the inner TAR (layering)', () async {
    final archive = await openArchiveFile(
      '../koni_xz/test/fixtures/xz/sample.tar.xz',
    );
    addTearDown(archive.close);

    expect(archive.format.name, 'tar', reason: 'the inner format wins');
    final names = archive.entries.map((e) => e.path).toList();
    expect(names, containsAll(<String>['hello.txt', 'prose.bin']));
    expect(
      utf8.decode(await archive.readBytes(archive.entry('hello.txt')!)),
      hello,
    );
    // The larger last entry decodes too (block-by-block + cache behind the
    // scenes, transparent here).
    final prose = await archive.readBytes(archive.entry('prose.bin')!);
    expect(prose, hasLength(45000));
  });

  test('Archive.create writes an .xz that Archive.open reads back', () async {
    final payload = Uint8List.fromList(('lorem ipsum dolor. ' * 400).codeUnits);
    final sink = BytesBuilderSink();
    final writer = Archive.create(sink, format: const XzWriteFormat());
    await writer.addBytes(ArchiveEntrySpec(path: 'ignored.txt'), payload);
    await writer.close();
    await sink.close();

    final archive = await Archive.openBytes(sink.takeBytes());
    addTearDown(archive.close);
    expect(archive.format.name, 'xz');
    expect(archive.entries, hasLength(1));
    expect(await archive.readBytes(archive.entries.single), payload);
  });
}

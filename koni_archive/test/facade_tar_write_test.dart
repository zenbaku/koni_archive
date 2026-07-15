import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive/koni_archive.dart';
import 'package:test/test.dart';

/// The write→read round trip through the facade: create a TAR with
/// `Archive.create` + `TarWriteFormat`, then open it with `Archive.open`
/// (auto-detected). Runs on VM and web.
void main() {
  test('write a CBT-shaped archive and read it back', () async {
    final sink = BytesBuilderSink();
    final writer = Archive.create(sink, format: const TarWriteFormat());
    expect(writer.format.name, 'tar');

    final pages = <String, Uint8List>{
      'comic/page001.png': Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2]),
      'comic/page002.png': Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 3, 4]),
      'comic/ComicInfo.xml': Uint8List.fromList(utf8.encode('<ComicInfo/>')),
    };
    await writer.addEntry(
      ArchiveEntrySpec(path: 'comic', type: ArchiveEntryType.directory),
    );
    for (final MapEntry(key: path, value: content) in pages.entries) {
      await writer.addBytes(ArchiveEntrySpec(path: path), content);
    }
    await writer.close();
    await sink.close();

    final archive = await Archive.openBytes(sink.takeBytes());
    addTearDown(archive.close);
    expect(archive.format.name, 'tar');
    for (final MapEntry(key: path, value: content) in pages.entries) {
      expect(await archive.readBytes(archive.entry(path)!), content);
    }
    expect(archive.glob('comic/*.png').map((e) => e.path), [
      'comic/page001.png',
      'comic/page002.png',
    ]);
  });
}

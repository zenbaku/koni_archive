import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:test/test.dart';

/// Platform-neutral reader tests (run on VM, dart2js, and dart2wasm) over
/// an embedded reference archive: `7zz a -m0=LZMA2 tiny.7z hello.txt`
/// (content 'hello, 7z!\n', mtime 2020-01-02T03:04:05Z; 7zz 26.02).
const String _tiny7zBase64 =
    'N3q8ryccAASZnO0iDwAAAAAAAABaAAAAAAAAANQKjWoBAApoZWxsbywgN3ohCgABBAYAAQkP'
    'AAcLAQABISEBAAwLAAgKAcfJzB8AAAUBGQwAAAAAAAAAAAAAAAARFQBoAGUAbABsAG8ALgB0'
    'AHgAdAAAABQKAQCAAMRKGcHVARUGAQAggKSBAAA=';

void main() {
  final bytes = base64.decode(_tiny7zBase64);

  test('opens, lists, and streams on every platform', () async {
    final reader = await const SevenZFormat().openReader(
      MemoryByteSource(Uint8List.fromList(bytes)),
      const ArchiveReadOptions(),
    );
    final entry = reader.entries.single;
    expect(entry.path, 'hello.txt');
    expect(entry.type, ArchiveEntryType.file);
    expect(entry.uncompressedSize, 11);
    expect(entry.modified, DateTime.utc(2020, 1, 2, 3, 4, 5));
    final chunks = await reader.openRead(entry).toList();
    expect(utf8.decode(chunks.expand<int>((c) => c).toList()), 'hello, 7z!\n');
    await reader.close();
  });

  test('detection accepts the magic and rejects noise', () async {
    const format = SevenZFormat();
    expect(
      await format.matches(MemoryByteSource(Uint8List.fromList(bytes))),
      isTrue,
    );
    expect(
      await format.matches(
        MemoryByteSource(Uint8List.fromList(List.filled(64, 0x51))),
      ),
      isFalse,
    );
  });
}

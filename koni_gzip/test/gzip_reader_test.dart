import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_gzip/koni_gzip.dart';
import 'package:test/test.dart';

/// Platform-neutral reader tests (run on VM, dart2js, and dart2wasm) over
/// an embedded reference member: FNAME 'hello.txt', MTIME 1577934245,
/// content 'hello, gzip!\n' (provenance: CPython zlib; see
/// koni_codecs/test/src/vectors.dart).
const List<int> _gzipNamed = [
  0x1F, 0x8B, 0x08, 0x08, 0xA5, 0x5D, 0x0D, 0x5E, 0x02, 0x03, 0x68, 0x65, //
  0x6C, 0x6C, 0x6F, 0x2E, 0x74, 0x78, 0x74, 0x00, 0xCB, 0x48, 0xCD, 0xC9,
  0xC9, 0xD7, 0x51, 0x48, 0xAF, 0xCA, 0x2C, 0x50, 0xE4, 0x02, 0x00, 0xF0,
  0x5F, 0xD8, 0x40, 0x0D, 0x00, 0x00, 0x00,
];

void main() {
  test('opens as a single-entry archive and streams (all platforms)', () async {
    final reader = await const GzipFormat().openReader(
      MemoryByteSource(Uint8List.fromList(_gzipNamed)),
      const ArchiveReadOptions(),
    );
    final entry = reader.entries.single;
    expect(entry.path, 'hello.txt');
    expect(entry.modified, DateTime.utc(2020, 1, 2, 3, 4, 5));
    expect(entry.uncompressedSize, 13);
    final chunks = await reader.openRead(entry).toList();
    expect(
      utf8.decode(chunks.expand<int>((c) => c).toList()),
      'hello, gzip!\n',
    );
    await reader.close();
  });

  test('detection accepts the magic and rejects noise', () async {
    const format = GzipFormat();
    expect(
      await format.matches(MemoryByteSource(Uint8List.fromList(_gzipNamed))),
      isTrue,
    );
    expect(
      await format.matches(
        MemoryByteSource(Uint8List.fromList(List.filled(64, 0xAB))),
      ),
      isFalse,
    );
  });
}

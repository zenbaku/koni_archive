@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

/// A bzip2-compressed (method 12) ZIP, authored by 7zz; see
/// test/fixtures/zip/fixtures_manifest.json.
Uint8List _fixture(String name) =>
    Uint8List.fromList(File('test/fixtures/zip/$name').readAsBytesSync());

Future<Uint8List> _read(ArchiveReader reader, String path) async {
  final entry = reader.entries.firstWhere((e) => e.path == path);
  final b = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(entry)) {
    b.add(chunk);
  }
  return b.takeBytes();
}

void main() {
  test('method 12 (bzip2) entries decode with a verified CRC', () async {
    final reader = await const ZipFormat().openReader(
      MemoryByteSource(_fixture('bzip2.zip')),
      const ArchiveReadOptions(),
    );
    // The bigger entry proves the multi-chunk path; the reader verifies the
    // ZIP CRC-32 and uncompressed size, so a clean read is proof of decode.
    final data = reader.entries.firstWhere(
      (e) => e.path == 'nested/deep/data.bin',
    );
    expect(data.compression, ArchiveCompression.bzip2);
    expect(
      await _read(reader, 'nested/deep/data.bin'),
      Uint8List.fromList(List.generate(2600, (i) => (i * 7 + 3) & 0xFF)),
    );
    expect(utf8.decode(await _read(reader, 'hello.txt')), 'hello, zip!\n');
    await reader.close();
  });
}

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:test/test.dart';

/// A BZip2-coder 7z archive, authored by 7zz; see
/// test/fixtures/sevenz/fixtures_manifest.json.
Uint8List _fixture(String name) =>
    Uint8List.fromList(File('test/fixtures/sevenz/$name').readAsBytesSync());

Future<Uint8List> _read(ArchiveReader reader, String path) async {
  final entry = reader.entries.firstWhere((e) => e.path == path);
  final b = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(entry)) {
    b.add(chunk);
  }
  return b.takeBytes();
}

void main() {
  test('BZip2-coder folders decode', () async {
    final reader = await const SevenZFormat().openReader(
      MemoryByteSource(_fixture('bzip2.7z')),
      const ArchiveReadOptions(),
    );
    final data = reader.entries.firstWhere(
      (e) => e.path == 'nested/deep/data.bin',
    );
    expect(data.compression, ArchiveCompression.bzip2);
    expect(
      await _read(reader, 'nested/deep/data.bin'),
      Uint8List.fromList(
        List.generate(100000, (i) => ((i * 7) ^ (i >> 3)) & 0xFF),
      ),
    );
    expect(utf8.decode(await _read(reader, 'hello.txt')), 'hello, 7z!\n');
    await reader.close();
  });
}

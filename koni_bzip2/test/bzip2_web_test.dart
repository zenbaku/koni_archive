// Web-runnable bzip2 reader round-trip: a small .bz2 inlined as base64 (no
// dart:io), decoded through the format reader, so the reader plumbing + codec
// run on dart2js and dart2wasm. Run:
//   dart test test/bzip2_web_test.dart -p chrome
//   dart test test/bzip2_web_test.dart -p chrome -c dart2wasm
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_bzip2/koni_bzip2.dart';
import 'package:test/test.dart';

// bzip2 -9 of "hello, bzip2!\n" * 4.
const _helloBz2 =
    'QlpoOTFBWSZTWRuNLF4AAA/ZgAAQYAQQABJkwBAgADEA0ABVQAaaWLmCDxo6bJIJEknxdyRThQkBuNLF4A==';

void main() {
  test('a .bz2 decodes through the reader on this platform', () async {
    final reader = await const Bzip2Format().openReader(
      MemoryByteSource(base64.decode(_helloBz2), name: 'hello.bz2'),
      const ArchiveReadOptions(),
    );
    final out = BytesBuilder(copy: false);
    await for (final chunk in reader.openRead(reader.entries.single)) {
      out.add(chunk);
    }
    await reader.close();
    expect(
      out.takeBytes(),
      Uint8List.fromList(('hello, bzip2!\n' * 4).codeUnits),
    );
  });
}

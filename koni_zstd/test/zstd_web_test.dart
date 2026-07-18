// Web-runnable zstd reader round-trip: a small .zst inlined as base64 (no
// dart:io), decoded through the format reader, so the reader plumbing + the
// full zstd codec run on dart2js and dart2wasm. Run:
//   dart test test/zstd_web_test.dart -p chrome
//   dart test test/zstd_web_test.dart -p chrome -c dart2wasm
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zstd/koni_zstd.dart';
import 'package:test/test.dart';

// zstd -19 --check of "hello, zstd!\n" * 4.
const _helloZst = 'KLUv/SQ0pQAAcGhlbGxvLCB6c3RkIQpoAQDhmUp5yB5J';

void main() {
  test('a .zst decodes through the reader on this platform', () async {
    final reader = await const ZstdFormat().openReader(
      MemoryByteSource(base64.decode(_helloZst), name: 'hello.zst'),
      const ArchiveReadOptions(),
    );
    final out = BytesBuilder(copy: false);
    await for (final chunk in reader.openRead(reader.entries.single)) {
      out.add(chunk);
    }
    await reader.close();
    expect(
      out.takeBytes(),
      Uint8List.fromList(('hello, zstd!\n' * 4).codeUnits),
    );
  });
}

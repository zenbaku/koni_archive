// Web-runnable xz WRITE round-trip: write with XzWriteFormat, read back with
// XzFormat, all in memory (no dart:io), so the VLI encoder, CRC-64, the LZMA2
// encoder, and the container framing run on dart2js and dart2wasm too. Run:
//   dart test test/xz_writer_web_test.dart -p chrome
//   dart test test/xz_writer_web_test.dart -p chrome -c dart2wasm
library;

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_xz/koni_xz.dart';
import 'package:test/test.dart';

Future<Uint8List> _writeThenRead(Uint8List data) async {
  final sink = BytesBuilderSink();
  final writer = const XzWriteFormat().openWriter(
    sink,
    const ArchiveWriteOptions(),
  );
  await writer.addBytes(ArchiveEntrySpec(path: 'data'), data);
  await writer.close();
  await sink.close();

  final reader = await const XzFormat().openReader(
    MemoryByteSource(sink.takeBytes()),
    const ArchiveReadOptions(),
  );
  final out = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(reader.entries.single)) {
    out.add(chunk);
  }
  await reader.close();
  return out.takeBytes();
}

void main() {
  test('write -> read round-trips on this platform', () async {
    final cases = <Uint8List>[
      Uint8List(0),
      Uint8List.fromList('hello, xz writer!\n'.codeUnits),
      // Compressible text (real LZMA2 matches).
      Uint8List.fromList(('the quick brown fox. ' * 2000).codeUnits),
      // A ramp.
      Uint8List.fromList(List<int>.generate(20000, (i) => (i * 7) & 0xFF)),
      // Less compressible (exercises the encoder's uncompressed-chunk path).
      Uint8List.fromList(
        List<int>.generate(8192, (i) => (i * 131 + 17) & 0xFF),
      ),
    ];
    for (final data in cases) {
      expect(await _writeThenRead(data), data, reason: '${data.length} bytes');
    }
  });
}

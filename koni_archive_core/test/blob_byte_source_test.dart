@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:koni_archive_core/web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

web.Blob _blobOf(Uint8List bytes) => web.Blob(<JSAny>[bytes.toJS].toJS);

void main() {
  group('BlobByteSource', () {
    final data = Uint8List.fromList(List.generate(256, (i) => i));

    test('exposes length and reads exact ranges', () async {
      final source = BlobByteSource(_blobOf(data));
      expect(source.length, 256);
      expect(await source.read(0, 4), [0, 1, 2, 3]);
      expect(await source.read(250, 6), [250, 251, 252, 253, 254, 255]);
    });

    test('supports overlapping in-flight reads (pread semantics)', () async {
      final source = BlobByteSource(_blobOf(data));
      final results = await Future.wait([
        for (var i = 0; i < 16; i++) source.read(i * 8, 8),
      ]);
      for (var i = 0; i < 16; i++) {
        expect(results[i], List.generate(8, (j) => i * 8 + j));
      }
    });

    test('read past end throws UnexpectedEofException', () {
      final source = BlobByteSource(_blobOf(data));
      expect(() => source.read(255, 2), throwsA(isA<UnexpectedEofException>()));
    });

    test('read after close throws ArchiveClosedException', () async {
      final source = BlobByteSource(_blobOf(data));
      await source.close();
      expect(() => source.read(0, 1), throwsA(isA<ArchiveClosedException>()));
    });
  });
}

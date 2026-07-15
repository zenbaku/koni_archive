import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryByteSource', () {
    final data = Uint8List.fromList(List.generate(64, (i) => i));

    test('exposes length and reads exact ranges', () async {
      final source = MemoryByteSource(data);
      expect(source.length, 64);
      expect(await source.read(0, 4), [0, 1, 2, 3]);
      expect(await source.read(60, 4), [60, 61, 62, 63]);
      expect(await source.read(10, 0), isEmpty);
    });

    test('supports overlapping in-flight reads (pread semantics)', () async {
      final source = MemoryByteSource(data);
      final futures = [for (var i = 0; i < 32; i++) source.read(i, 16)];
      final results = await Future.wait(futures);
      for (var i = 0; i < 32; i++) {
        expect(results[i], List.generate(16, (j) => i + j));
      }
    });

    test('read past end throws UnexpectedEofException', () {
      final source = MemoryByteSource(data);
      expect(() => source.read(60, 5), throwsA(isA<UnexpectedEofException>()));
      expect(() => source.read(64, 1), throwsA(isA<UnexpectedEofException>()));
      // Reading zero bytes at the very end is legal.
      expect(source.read(64, 0), completes);
    });

    test('negative arguments are programmer errors', () {
      final source = MemoryByteSource(data);
      expect(() => source.read(-1, 4), throwsArgumentError);
      expect(() => source.read(0, -4), throwsArgumentError);
    });

    test('read after close throws ArchiveClosedException', () async {
      final source = MemoryByteSource(data);
      await source.close();
      expect(() => source.read(0, 1), throwsA(isA<ArchiveClosedException>()));
    });

    test('close is idempotent', () async {
      final source = MemoryByteSource(data);
      await source.close();
      await source.close();
    });
  });
}

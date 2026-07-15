@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/io.dart';
import 'package:test/test.dart';

void main() {
  group('FileByteSource', () {
    late Directory tempDir;
    late String path;
    final data = Uint8List.fromList(
      List.generate(4096, (i) => (i * 7 + 13) & 0xFF),
    );

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('koni_archive_test');
      path = '${tempDir.path}${Platform.pathSeparator}data.bin';
      File(path).writeAsBytesSync(data);
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    test('exposes length and reads exact ranges', () async {
      final source = await FileByteSource.open(path);
      addTearDown(source.close);
      expect(source.length, data.length);
      expect(await source.read(0, 8), data.sublist(0, 8));
      expect(await source.read(4000, 96), data.sublist(4000, 4096));
    });

    test('overlapping in-flight reads do not interfere', () async {
      final source = await FileByteSource.open(path);
      addTearDown(source.close);
      // Fire many overlapping reads without awaiting in between: with a
      // shared cursor and no serialization these would corrupt each other.
      final offsets = [0, 4000, 128, 3500, 1, 2048, 77, 4095, 300, 1024];
      final results = await Future.wait([
        for (final offset in offsets)
          source.read(offset, 32.clamp(0, data.length - offset)),
      ]);
      for (var i = 0; i < offsets.length; i++) {
        final offset = offsets[i];
        final len = 32.clamp(0, data.length - offset);
        expect(
          results[i],
          data.sublist(offset, offset + len),
          reason: 'read at offset $offset',
        );
      }
    });

    test('read past end throws UnexpectedEofException', () async {
      final source = await FileByteSource.open(path);
      addTearDown(source.close);
      expect(
        () => source.read(data.length - 1, 2),
        throwsA(isA<UnexpectedEofException>()),
      );
    });

    test('read after close throws ArchiveClosedException', () async {
      final source = await FileByteSource.open(path);
      await source.close();
      expect(() => source.read(0, 1), throwsA(isA<ArchiveClosedException>()));
    });

    test('close is idempotent and waits for in-flight reads', () async {
      final source = await FileByteSource.open(path);
      final pending = source.read(0, 4096);
      await source.close();
      await source.close();
      expect(await pending, data);
    });
  });
}

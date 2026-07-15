@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/io.dart';
import 'package:test/test.dart';

void main() {
  group('FileByteSink', () {
    late Directory tempDir;
    late String path;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('koni_sink_test');
      path = '${tempDir.path}${Platform.pathSeparator}out.bin';
    });
    tearDown(() => tempDir.deleteSync(recursive: true));

    test('appends bytes and tracks length; file matches', () async {
      final sink = await FileByteSink.create(path);
      await sink.add(Uint8List.fromList([1, 2, 3]));
      await sink.add(Uint8List.fromList(List.generate(4096, (i) => i & 0xFF)));
      expect(sink.length, 3 + 4096);
      await sink.close();
      final bytes = File(path).readAsBytesSync();
      expect(bytes.length, 3 + 4096);
      expect(bytes.sublist(0, 3), [1, 2, 3]);
      expect(bytes[4098], 4095 & 0xFF);
    });

    test('serializes un-awaited writes in order', () async {
      final sink = await FileByteSink.create(path);
      // Fire writes without awaiting between them: the internal lock must
      // preserve order.
      final futures = [
        for (var i = 0; i < 50; i++) sink.add(Uint8List.fromList([i])),
      ];
      await Future.wait(futures);
      await sink.close();
      expect(File(path).readAsBytesSync(), List.generate(50, (i) => i));
    });

    test('add after close throws; close is idempotent', () async {
      final sink = await FileByteSink.create(path);
      await sink.close();
      await sink.close();
      expect(
        () => sink.add(Uint8List(1)),
        throwsA(isA<ArchiveClosedException>()),
      );
    });

    test('truncates an existing file', () async {
      File(path).writeAsBytesSync(List.filled(1000, 0xFF));
      final sink = await FileByteSink.create(path);
      await sink.add(Uint8List.fromList([1, 2]));
      await sink.close();
      expect(File(path).readAsBytesSync(), [1, 2]);
    });
  });
}

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

void main() {
  group('BytesBuilderSink', () {
    test('accumulates writes and tracks length', () async {
      final sink = BytesBuilderSink();
      expect(sink.length, 0);
      await sink.add(Uint8List.fromList([1, 2, 3]));
      expect(sink.length, 3);
      await sink.add(Uint8List.fromList([4, 5]));
      expect(sink.length, 5);
      await sink.close();
      expect(sink.takeBytes(), [1, 2, 3, 4, 5]);
    });

    test('copies input so callers may reuse their buffer', () async {
      final sink = BytesBuilderSink();
      final buffer = Uint8List.fromList([9, 9]);
      await sink.add(buffer);
      buffer[0] = 0; // mutate after add
      await sink.close();
      expect(sink.takeBytes(), [9, 9]);
    });

    test('add after close throws ArchiveClosedException', () async {
      final sink = BytesBuilderSink();
      await sink.close();
      expect(
        () => sink.add(Uint8List(1)),
        throwsA(isA<ArchiveClosedException>()),
      );
    });

    test('takeBytes before close throws; length stable after take', () async {
      final sink = BytesBuilderSink();
      await sink.add(Uint8List.fromList([1, 2]));
      expect(sink.takeBytes, throwsStateError);
      await sink.close();
      expect(sink.takeBytes(), [1, 2]);
      expect(sink.length, 2);
    });

    test('close is idempotent', () async {
      final sink = BytesBuilderSink();
      await sink.close();
      await sink.close();
    });
  });

  group('validateWritePath', () {
    test('passes and cleans safe relative paths', () {
      expect(validateWritePath('a/b/c.txt'), 'a/b/c.txt');
      expect(validateWritePath(r'a\b\c.txt'), 'a/b/c.txt');
      expect(validateWritePath('a/./b//c'), 'a/b/c');
      expect(validateWritePath('page001.webp'), 'page001.webp');
    });

    test('rejects absolute paths', () {
      expect(() => validateWritePath('/etc/passwd'), throwsArgumentError);
      expect(() => validateWritePath(r'\windows'), throwsArgumentError);
    });

    test('rejects drive letters', () {
      expect(() => validateWritePath(r'C:\evil'), throwsArgumentError);
      expect(() => validateWritePath('c:rel'), throwsArgumentError);
    });

    test('rejects .. traversal anywhere', () {
      expect(() => validateWritePath('../x'), throwsArgumentError);
      expect(() => validateWritePath('a/../../x'), throwsArgumentError);
      expect(() => validateWritePath('a/b/..'), throwsArgumentError);
    });

    test('rejects empty results', () {
      expect(() => validateWritePath(''), throwsArgumentError);
      expect(() => validateWritePath('.'), throwsArgumentError);
      expect(() => validateWritePath('/'), throwsArgumentError);
    });

    test('keeps unicode and dotted names', () {
      expect(validateWritePath('日本語/ページ.png'), '日本語/ページ.png');
      expect(validateWritePath('dots..in..name/f'), 'dots..in..name/f');
    });
  });
}

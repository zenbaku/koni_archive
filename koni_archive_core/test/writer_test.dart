import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

/// Test-only write format that serializes entries as
/// `path\n<length>\n<bytes>` records — enough to prove the SPI end-to-end
/// (mirrors the M1 stub-format reader test).
final class _StubWriteFormat extends ArchiveWriteFormat {
  const _StubWriteFormat();

  @override
  String get name => 'stub';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) =>
      _StubWriter(this, sink);
}

final class _StubWriter extends ArchiveWriter {
  _StubWriter(this.format, this._sink);

  @override
  final ArchiveWriteFormat format;
  final ByteSink _sink;
  bool _closed = false;

  @override
  Future<ArchiveEntry> addStream(
    ArchiveEntrySpec spec,
    Stream<Uint8List> content, {
    required int size,
  }) async {
    if (_closed) {
      throw ArchiveClosedException('addStream after close', format: 'stub');
    }
    final path = validateWritePath(spec.path);
    final crc = Crc32();
    var written = 0;
    await _sink.add(Uint8List.fromList(utf8.encode('$path\n$size\n')));
    await for (final chunk in content) {
      written += chunk.length;
      if (written > size) {
        throw SizeLimitExceededException(
          'stream exceeded declared size $size',
          limit: size,
          entryPath: path,
        );
      }
      crc.add(chunk);
      await _sink.add(chunk);
    }
    if (written != size) {
      throw CorruptArchiveException(
        'stream produced $written bytes, declared $size',
        entryPath: path,
      );
    }
    return ArchiveEntry(
      path: path,
      type: spec.type,
      uncompressedSize: size,
      compressedSize: size,
      crc32: crc.value,
      modified: spec.modified,
      posixMode: spec.posixMode,
      linkTarget: spec.linkTarget,
    );
  }

  @override
  Future<ArchiveEntry> addEntry(ArchiveEntrySpec spec) async {
    if (spec.type == ArchiveEntryType.file) {
      throw ArgumentError.value(spec.type, 'spec.type', 'file needs content');
    }
    final path = validateWritePath(spec.path);
    await _sink.add(Uint8List.fromList(utf8.encode('$path\n0\n')));
    return ArchiveEntry(
      path: path,
      type: spec.type,
      uncompressedSize: 0,
      linkTarget: spec.linkTarget,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

void main() {
  group('ArchiveWriter SPI (via stub format)', () {
    test('addBytes writes content and returns a computed entry', () async {
      final sink = BytesBuilderSink();
      final writer = _StubWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      final data = Uint8List.fromList(utf8.encode('hello'));
      final entry = await writer.addBytes(
        ArchiveEntrySpec(path: 'a/b.txt'),
        data,
      );
      await writer.close();

      expect(entry.path, 'a/b.txt');
      expect(entry.uncompressedSize, 5);
      expect(entry.crc32, Crc32.compute(data));
      await sink.close();
      expect(utf8.decode(sink.takeBytes()), 'a/b.txt\n5\nhello');
    });

    test('addStream streams content with bounded memory', () async {
      final sink = BytesBuilderSink();
      final writer = _StubWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      final chunks = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5]),
      ];
      final entry = await writer.addStream(
        ArchiveEntrySpec(path: 'data.bin'),
        Stream.fromIterable(chunks),
        size: 5,
      );
      expect(entry.uncompressedSize, 5);
      await writer.close();
    });

    test(
      'addStream rejects a size mismatch (§ streamed != declared)',
      () async {
        final sink = BytesBuilderSink();
        final writer = _StubWriteFormat().openWriter(
          sink,
          const ArchiveWriteOptions(),
        );
        await expectLater(
          writer.addStream(
            ArchiveEntrySpec(path: 'short'),
            Stream.value(Uint8List.fromList([1, 2])),
            size: 5,
          ),
          throwsA(isA<CorruptArchiveException>()),
        );
        await expectLater(
          writer.addStream(
            ArchiveEntrySpec(path: 'long'),
            Stream.value(Uint8List.fromList([1, 2, 3, 4, 5, 6])),
            size: 5,
          ),
          throwsA(isA<SizeLimitExceededException>()),
        );
      },
    );

    test('invalid paths are rejected before any bytes are written', () async {
      final sink = BytesBuilderSink();
      final writer = _StubWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await expectLater(
        writer.addBytes(ArchiveEntrySpec(path: '../escape'), Uint8List(0)),
        throwsArgumentError,
      );
    });

    test('addEntry writes a directory; a file spec is rejected', () async {
      final sink = BytesBuilderSink();
      final writer = _StubWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      final dir = await writer.addEntry(
        ArchiveEntrySpec(path: 'folder', type: ArchiveEntryType.directory),
      );
      expect(dir.type, ArchiveEntryType.directory);
      await expectLater(
        writer.addEntry(
          ArchiveEntrySpec(path: 'f', type: ArchiveEntryType.file),
        ),
        throwsArgumentError,
      );
    });

    test('add after close throws ArchiveClosedException', () async {
      final sink = BytesBuilderSink();
      final writer = _StubWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await writer.close();
      await expectLater(
        writer.addBytes(ArchiveEntrySpec(path: 'x'), Uint8List(0)),
        throwsA(isA<ArchiveClosedException>()),
      );
    });
  });

  group('ArchiveEntrySpec', () {
    test('symlink requires a link target (assert)', () {
      expect(
        () => ArchiveEntrySpec(path: 'l', type: ArchiveEntryType.symlink),
        throwsA(isA<AssertionError>()),
      );
      // With a target it is fine.
      expect(
        ArchiveEntrySpec(
          path: 'l',
          type: ArchiveEntryType.symlink,
          linkTarget: 'target',
        ).linkTarget,
        'target',
      );
    });

    test('modified must be UTC (assert)', () {
      expect(
        () => ArchiveEntrySpec(path: 'x', modified: DateTime(2020)),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}

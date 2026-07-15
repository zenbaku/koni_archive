import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_gzip/koni_gzip.dart';
import 'package:test/test.dart';

/// Reference member from koni_codecs' vectors: FNAME 'hello.txt', content
/// 'hello, gzip!\n' (13 bytes).
const List<int> _gz = [
  0x1F, 0x8B, 0x08, 0x08, 0xA5, 0x5D, 0x0D, 0x5E, 0x02, 0x03, 0x68, 0x65, //
  0x6C, 0x6C, 0x6F, 0x2E, 0x74, 0x78, 0x74, 0x00, 0xCB, 0x48, 0xCD, 0xC9,
  0xC9, 0xD7, 0x51, 0x48, 0xAF, 0xCA, 0x2C, 0x50, 0xE4, 0x02, 0x00, 0xF0,
  0x5F, 0xD8, 0x40, 0x0D, 0x00, 0x00, 0x00,
];

Future<GzipDecompressedByteSource> _open({String? name}) =>
    GzipDecompressedByteSource.open(
      MemoryByteSource(Uint8List.fromList(_gz), name: name),
    );

void main() {
  group('GzipDecompressedByteSource', () {
    test('length comes from ISIZE; no decode happens at open', () async {
      final source = await _open();
      expect(source.length, 13);
    });

    test('reads decode sequentially and serve from cache, any order', () async {
      final source = await _open();
      // Backwards and overlapping reads: the cache serves them all.
      expect(utf8.decode(await source.read(7, 6)), 'gzip!\n');
      expect(utf8.decode(await source.read(0, 5)), 'hello');
      expect(utf8.decode(await source.read(0, 13)), 'hello, gzip!\n');
      expect(await source.read(13, 0), isEmpty);
    });

    test('supports overlapping in-flight reads (pread semantics)', () async {
      final source = await _open();
      final results = await Future.wait([
        for (var i = 0; i < 13; i++) source.read(i, 13 - i),
      ]);
      for (var i = 0; i < 13; i++) {
        expect(utf8.decode(results[i]), 'hello, gzip!\n'.substring(i));
      }
    });

    test('reads past ISIZE throw UnexpectedEofException', () async {
      final source = await _open();
      expect(() => source.read(10, 5), throwsA(isA<UnexpectedEofException>()));
    });

    test('a corrupted container surfaces as a typed error on read', () async {
      final bytes = Uint8List.fromList(_gz);
      bytes[25] ^= 0x40; // damage the deflate body
      final source = await GzipDecompressedByteSource.open(
        MemoryByteSource(bytes),
      );
      await expectLater(
        source.read(0, 13),
        throwsA(isA<CorruptArchiveException>()),
      );
    });

    test(
      'an ISIZE that overpromises is a typed error when discovered',
      () async {
        final bytes = Uint8List.fromList(_gz);
        bytes[bytes.length - 4] = 200; // claim 200 decoded bytes
        final source = await GzipDecompressedByteSource.open(
          MemoryByteSource(bytes),
          verifyChecksums: false, // the ISIZE-mismatch trailer check would
          // otherwise fire first; this test targets the source's own check
        );
        expect(source.length, 200);
        await expectLater(
          source.read(150, 10),
          throwsA(isA<CorruptArchiveException>()),
        );
      },
    );

    test('derives the inner name from the container name', () async {
      expect((await _open(name: 'x/foo.tar.gz')).name, 'x/foo.tar');
      expect((await _open(name: 'foo.tgz')).name, 'foo.tar');
      expect((await _open(name: 'foo.gz')).name, 'foo');
      expect((await _open()).name, isNull);
    });

    test('read after close throws ArchiveClosedException', () async {
      final source = await _open();
      await source.close();
      expect(() => source.read(0, 1), throwsA(isA<ArchiveClosedException>()));
    });
  });

  group('GzipFormat layering with a stub inner format', () {
    test('inner format sees decompressed bytes and wins; mismatch falls '
        'back to single-entry', () async {
      final probed = <String>[];
      final stub = _HeadFormat('stub-inner', 'hello', probed);
      const noMatch = 'nope!';
      final layered = GzipFormat(layeredFormats: [stub]);

      final reader = await layered.openReader(
        MemoryByteSource(Uint8List.fromList(_gz)),
        const ArchiveReadOptions(),
      );
      expect(reader.format.name, 'stub-inner');
      expect(probed, isNotEmpty);

      final mismatched = GzipFormat(
        layeredFormats: [_HeadFormat('other', noMatch, probed)],
      );
      final fallback = await mismatched.openReader(
        MemoryByteSource(Uint8List.fromList(_gz)),
        const ArchiveReadOptions(),
      );
      expect(fallback.format.name, 'gzip');
      expect(fallback.entries.single.path, 'hello.txt');
    });
  });
}

/// Test-only inner format matching a text prefix of the decompressed head.
final class _HeadFormat extends ArchiveFormat {
  _HeadFormat(this.name, this._magic, this._probed);

  @override
  final String name;
  final String _magic;
  final List<String> _probed;

  @override
  Future<bool> matches(ByteSource source) async {
    _probed.add(name);
    final head = await source.read(0, _magic.length);
    return utf8.decode(head, allowMalformed: true) == _magic;
  }

  @override
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async => _FixedReader(this, source);
}

final class _FixedReader extends ArchiveReader {
  _FixedReader(this.format, this._source);

  @override
  final ArchiveFormat format;
  final ByteSource _source;

  @override
  List<ArchiveEntry> get entries => List.unmodifiable([
    ArchiveEntry(
      path: 'inner',
      type: ArchiveEntryType.file,
      uncompressedSize: _source.length,
    ),
  ]);

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) =>
      Stream.fromFuture(_source.read(0, _source.length));

  @override
  Future<void> close() async {}
}

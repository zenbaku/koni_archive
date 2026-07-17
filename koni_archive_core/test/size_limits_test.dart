import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

/// Exercises the decompression-bomb guards enforced at the
/// `ArchiveFormat.openReader` seam (`maxEntrySize`, `maxEntryCount`) with a
/// controllable stub format, so the checks are tested directly — including the
/// bypass-proof path of calling a format's reader without the facade. Runs on
/// VM and web (no fixtures, no I/O).
void main() {
  final source = MemoryByteSource(Uint8List.fromList([0]));
  Uint8List bytes(int n) => Uint8List(n);

  ArchiveEntry entry(String path) => ArchiveEntry(
    path: path,
    type: ArchiveEntryType.file,
    uncompressedSize: 0,
  );

  group('maxEntrySize', () {
    test('aborts the decode once decoded output crosses the limit', () async {
      final e = entry('big');
      final format = _StubFormat(
        entries: [e],
        chunks: [bytes(10), bytes(10), bytes(10), bytes(10), bytes(10)],
      );
      final reader = await format.openReader(
        source,
        const ArchiveReadOptions(maxEntrySize: 25),
      );

      final received = <int>[];
      await expectLater(
        reader.openRead(e).forEach(received.addAll),
        throwsA(
          isA<SizeLimitExceededException>()
              .having((x) => x.limit, 'limit', 25)
              .having((x) => x.entryPath, 'entryPath', 'big')
              .having((x) => x.format, 'format', 'stub'),
        ),
      );

      // Only the two chunks that stay within the limit reach the caller; the
      // one that crosses it is never yielded.
      expect(received, hasLength(20));
      // And the decode stopped early: the underlying reader was not drained of
      // its remaining two chunks.
      expect(format.lastReader!.chunksProduced, 3);
    });

    test('a limit equal to the exact decoded size passes', () async {
      final e = entry('exact');
      final format = _StubFormat(
        entries: [e],
        chunks: [bytes(10), bytes(10), bytes(5)],
      );
      final reader = await format.openReader(
        source,
        const ArchiveReadOptions(maxEntrySize: 25),
      );

      final received = <int>[];
      await reader.openRead(e).forEach(received.addAll);
      expect(received, hasLength(25));
    });

    test('null (default) leaves the reader unwrapped and unbounded', () async {
      final e = entry('unbounded');
      final format = _StubFormat(entries: [e], chunks: [bytes(1000)]);
      final reader = await format.openReader(
        source,
        const ArchiveReadOptions(),
      );
      final received = <int>[];
      await reader.openRead(e).forEach(received.addAll);
      expect(received, hasLength(1000));
    });

    test('preserves entry identity and order through the wrapper', () async {
      final a = entry('a');
      final b = entry('b');
      final format = _StubFormat(entries: [a, b], chunks: const []);
      final reader = await format.openReader(
        source,
        const ArchiveReadOptions(maxEntrySize: 1),
      );
      expect(reader.entries, [same(a), same(b)]);
    });
  });

  group('maxEntryCount', () {
    test(
      'rejects an archive that declares more entries than the limit',
      () async {
        final format = _StubFormat(
          entries: [entry('a'), entry('b'), entry('c'), entry('d'), entry('e')],
        );
        await expectLater(
          format.openReader(source, const ArchiveReadOptions(maxEntryCount: 3)),
          throwsA(
            isA<SizeLimitExceededException>()
                .having((x) => x.limit, 'limit', 3)
                .having((x) => x.format, 'format', 'stub'),
          ),
        );
        // The reader is closed when the count check rejects it.
        expect(format.lastReader!.closed, isTrue);
      },
    );

    test('a count equal to the entry total is allowed', () async {
      final format = _StubFormat(entries: [entry('a'), entry('b'), entry('c')]);
      final reader = await format.openReader(
        source,
        const ArchiveReadOptions(maxEntryCount: 3),
      );
      expect(reader.entries, hasLength(3));
    });

    test('null (default) allows any number of entries', () async {
      final format = _StubFormat(
        entries: List.generate(1000, (i) => entry('e$i')),
      );
      final reader = await format.openReader(
        source,
        const ArchiveReadOptions(),
      );
      expect(reader.entries, hasLength(1000));
    });
  });
}

/// A format that hands back a reader emitting a fixed chunk sequence for its
/// single content entry. Records the reader it created so tests can inspect
/// how far the decode ran and whether it was closed.
final class _StubFormat extends ArchiveFormat {
  _StubFormat({required this.entries, this.chunks = const []});

  final List<ArchiveEntry> entries;
  final List<Uint8List> chunks;
  _StubReader? lastReader;

  @override
  String get name => 'stub';

  @override
  Future<bool> matches(ByteSource source) async => true;

  @override
  Future<ArchiveReader> createReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async => lastReader = _StubReader(this, List.unmodifiable(entries), chunks);
}

final class _StubReader extends ArchiveReader {
  _StubReader(this.format, this.entries, this._chunks);

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final List<Uint8List> _chunks;

  /// How many chunks the underlying decode actually produced; a bounded read
  /// that aborts early stops pulling before the sequence is exhausted.
  int chunksProduced = 0;
  bool closed = false;

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) async* {
    for (final chunk in _chunks) {
      chunksProduced++;
      yield chunk;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

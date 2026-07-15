import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive/koni_archive.dart';
import 'package:test/test.dart';

/// Test-only format: magic 'STUB' at offset 0, entries/content injected per
/// test. Exercises the facade exactly the way a format package plugs in.
final class _StubFormat extends ArchiveFormat {
  _StubFormat(this._entries, this._content, {this.onOpenRead});

  final List<ArchiveEntry> _entries;
  final Map<String, List<String>> _content; // path -> chunks (last wins)
  final Stream<Uint8List> Function(ArchiveEntry entry)? onOpenRead;

  @override
  String get name => 'stub';

  @override
  Future<bool> matches(ByteSource source) async {
    final head = await source.read(0, 4);
    return head[0] == 0x53 &&
        head[1] == 0x54 &&
        head[2] == 0x55 &&
        head[3] == 0x42;
  }

  @override
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async => _StubReader(this);
}

final class _StubReader extends ArchiveReader {
  _StubReader(this._format);

  final _StubFormat _format;
  bool closed = false;

  @override
  ArchiveFormat get format => _format;

  @override
  List<ArchiveEntry> get entries => List.unmodifiable(_format._entries);

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    final custom = _format.onOpenRead;
    if (custom != null) return custom(entry);
    final chunks = _format._content[entry.path] ?? const <String>[];
    return Stream.fromIterable([
      for (final chunk in chunks) Uint8List.fromList(utf8.encode(chunk)),
    ]);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

ArchiveEntry _file(String path, int size) => ArchiveEntry(
  path: path,
  type: ArchiveEntryType.file,
  uncompressedSize: size,
);

ArchiveEntry _dir(String path) => ArchiveEntry(
  path: path,
  type: ArchiveEntryType.directory,
  uncompressedSize: 0,
);

final Uint8List _stubBytes = Uint8List.fromList(utf8.encode('STUB....'));

Future<Archive> _openStub(_StubFormat format) =>
    Archive.openBytes(_stubBytes, registry: ArchiveFormatRegistry([format]));

Future<String> _collect(Stream<Uint8List> stream) async =>
    utf8.decode((await stream.toList()).expand<int>((c) => c).toList());

void main() {
  group('Archive.open', () {
    test('auto-detects the format and exposes it', () async {
      final archive = await _openStub(_StubFormat([_file('a', 1)], {}));
      expect(archive.format.name, 'stub');
      expect(archive.isClosed, isFalse);
      await archive.close();
    });

    test('throws UnsupportedFormatException when nothing matches and leaves '
        'the source open', () async {
      final source = MemoryByteSource(Uint8List.fromList(utf8.encode('????')));
      await expectLater(
        Archive.open(source, registry: ArchiveFormatRegistry()),
        throwsA(isA<UnsupportedFormatException>()),
      );
      // Source not taken over: still readable.
      expect(await source.read(0, 4), utf8.encode('????'));
      await source.close();
    });

    test('format: forces a format, skipping detection (§5)', () async {
      final format = _StubFormat(
        [_file('a', 1)],
        {
          'a': ['x'],
        },
      );
      // Bytes do NOT carry the STUB magic; detection would fail.
      final archive = await Archive.openBytes(
        Uint8List.fromList(utf8.encode('not-stub')),
        registry: ArchiveFormatRegistry(),
        format: format,
      );
      expect(archive.format.name, 'stub');
      await archive.close();
    });

    test('default registry is builtInFormats; unmatched bytes throw', () async {
      expect(builtInFormats.formats, isNotEmpty);
      // 8 bytes match no built-in (tar needs at least a 512-byte block).
      await expectLater(
        Archive.openBytes(_stubBytes),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });
  });

  group('entry lookup (§4)', () {
    test('entries keeps duplicates in index order; entry() is last-wins, '
        'exact, case-sensitive', () async {
      final first = _file('dup.txt', 1);
      final second = _file('dup.txt', 2);
      final archive = await _openStub(
        _StubFormat([first, _file('other.txt', 3), second], {}),
      );
      expect(archive.entries, hasLength(3));
      expect(archive.entries[0], same(first));
      expect(archive.entry('dup.txt'), same(second));
      expect(archive.entry('DUP.TXT'), isNull);
      expect(archive.entry('missing'), isNull);
      expect(archive.exists('dup.txt'), isTrue);
      expect(archive.exists('missing'), isFalse);
      await archive.close();
    });
  });

  group('reading (§4)', () {
    test('openRead streams chunks; openReadPath is sugar', () async {
      final archive = await _openStub(
        _StubFormat(
          [_file('greeting.txt', 11)],
          {
            'greeting.txt': ['hello', ' ', 'world'],
          },
        ),
      );
      expect(
        await _collect(archive.openRead(archive.entry('greeting.txt')!)),
        'hello world',
      );
      expect(
        await _collect(archive.openReadPath('greeting.txt')),
        'hello world',
      );
      await archive.close();
    });

    test(
      'openReadPath on an absent path throws EntryNotFoundException',
      () async {
        final archive = await _openStub(_StubFormat([], {}));
        expect(
          () => archive.openReadPath('nope'),
          throwsA(
            isA<EntryNotFoundException>()
                .having((e) => e.entryPath, 'entryPath', 'nope')
                .having((e) => e.format, 'format', 'stub'),
          ),
        );
        await archive.close();
      },
    );

    test('multiple entry streams can be open simultaneously', () async {
      final archive = await _openStub(
        _StubFormat(
          [_file('a', 1), _file('b', 1)],
          {
            'a': ['AAA'],
            'b': ['BBB'],
          },
        ),
      );
      final aStream = archive.openRead(archive.entry('a')!);
      final bStream = archive.openRead(archive.entry('b')!);
      final results = await Future.wait([_collect(aStream), _collect(bStream)]);
      expect(results, ['AAA', 'BBB']);
      await archive.close();
    });

    test('readBytes collects the stream', () async {
      final archive = await _openStub(
        _StubFormat(
          [_file('a', 6)],
          {
            'a': ['abc', 'def'],
          },
        ),
      );
      expect(
        utf8.decode(await archive.readBytes(archive.entry('a')!)),
        'abcdef',
      );
      await archive.close();
    });

    test('readBytes enforces maxSize with a typed error (§7)', () async {
      final archive = await _openStub(
        _StubFormat(
          [_file('bomb', 1000)],
          {
            'bomb': ['xxxxxxxxxx', 'yyyyyyyyyy'],
          },
        ),
      );
      await expectLater(
        archive.readBytes(archive.entry('bomb')!, maxSize: 15),
        throwsA(
          isA<SizeLimitExceededException>()
              .having((e) => e.limit, 'limit', 15)
              .having((e) => e.entryPath, 'entryPath', 'bomb'),
        ),
      );
      // The rest of the archive stays usable.
      expect(await archive.readBytes(archive.entry('bomb')!), hasLength(20));
      await archive.close();
    });

    test('mid-decode errors arrive through the stream, typed (§9)', () async {
      final archive = await _openStub(
        _StubFormat(
          [_file('bad', 10)],
          {},
          onOpenRead: (entry) async* {
            yield Uint8List.fromList([1, 2, 3]);
            throw CorruptArchiveException(
              'bitstream damaged',
              entryPath: entry.path,
            );
          },
        ),
      );
      final events = <Object>[];
      await archive
          .openRead(archive.entry('bad')!)
          .handleError((Object e) => events.add(e))
          .drain<void>();
      expect(events.single, isA<CorruptArchiveException>());
      await archive.close();
    });
  });

  group('close (§4)', () {
    test('is idempotent and closes reader + source', () async {
      final source = MemoryByteSource(_stubBytes);
      final format = _StubFormat([_file('a', 1)], {});
      final archive = await Archive.open(
        source,
        registry: ArchiveFormatRegistry([format]),
      );
      await archive.close();
      await archive.close();
      expect(archive.isClosed, isTrue);
      expect(() => source.read(0, 1), throwsA(isA<ArchiveClosedException>()));
    });

    test(
      'openRead/openReadPath after close throw ArchiveClosedException',
      () async {
        final archive = await _openStub(_StubFormat([_file('a', 1)], {}));
        final entry = archive.entry('a')!;
        await archive.close();
        expect(
          () => archive.openRead(entry),
          throwsA(isA<ArchiveClosedException>()),
        );
        expect(
          () => archive.openReadPath('a'),
          throwsA(isA<ArchiveClosedException>()),
        );
      },
    );

    test('errors in-flight streams with ArchiveClosedException', () async {
      // A reader stream that emits one chunk and then hangs forever.
      final hang = Completer<void>();
      final archive = await _openStub(
        _StubFormat(
          [_file('slow', 100)],
          {},
          onOpenRead: (_) async* {
            yield Uint8List.fromList([1]);
            await hang.future;
          },
        ),
      );
      final events = <Object>[];
      final done = Completer<void>();
      archive
          .openRead(archive.entry('slow')!)
          .listen(events.add, onError: events.add, onDone: done.complete);
      await Future<void>.delayed(Duration.zero);
      await archive.close();
      await done.future;
      expect(events, hasLength(2));
      expect(events[0], isA<Uint8List>());
      expect(events[1], isA<ArchiveClosedException>());
    });
  });

  group('virtual filesystem view (§4)', () {
    Future<Archive> vfsArchive() => _openStub(
      _StubFormat([_file('b/x.txt', 1), _file('a/y/z.txt', 1), _dir('a')], {}),
    );

    test(
      'walk is depth-first pre-order with synthesized directories',
      () async {
        final archive = await _openStub(
          _StubFormat([
            _file('b/x.txt', 1),
            _file('a/y/z.txt', 1),
            _dir('a'),
          ], {}),
        );
        expect(archive.walk().map((e) => e.path).toList(), [
          'a',
          'a/y',
          'a/y/z.txt',
          'b',
          'b/x.txt',
        ]);
        // 'a' is the stored entry; 'a/y' and 'b' are synthesized directories.
        final byPath = {for (final e in archive.walk()) e.path: e};
        expect(byPath['a/y']!.type, ArchiveEntryType.directory);
        expect(byPath['a/y']!.uncompressedSize, 0);
        expect(byPath['b']!.type, ArchiveEntryType.directory);
        await archive.close();
      },
    );

    test('files and directories filter the VFS view', () async {
      final archive = await vfsArchive();
      expect(archive.files.map((e) => e.path), everyElement(endsWith('.txt')));
      expect(
        archive.directories.map((e) => e.path).toList(),
        containsAll(<String>['a', 'a/y', 'b']),
      );
      await archive.close();
    });

    test('duplicate paths collapse to one VFS node (last wins)', () async {
      final archive = await _openStub(
        _StubFormat([_file('dup', 1), _file('dup', 2)], {}),
      );
      final nodes = archive.walk().where((e) => e.path == 'dup').toList();
      expect(nodes, hasLength(1));
      expect(nodes.single.uncompressedSize, 2);
      await archive.close();
    });

    test('glob matches VFS paths', () async {
      final archive = await _openStub(
        _StubFormat([
          _file('ch01/page001.webp', 1),
          _file('ch01/page002.webp', 1),
          _file('ch02/page001.webp', 1),
          _file('cover.jpg', 1),
        ], {}),
      );
      expect(archive.glob('ch01/*.webp').map((e) => e.path).toList(), [
        'ch01/page001.webp',
        'ch01/page002.webp',
      ]);
      expect(archive.glob('**.webp').map((e) => e.path), hasLength(3));
      expect(archive.glob('*.jpg').map((e) => e.path).toList(), ['cover.jpg']);
      await archive.close();
    });
  });
}

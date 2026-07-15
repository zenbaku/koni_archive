import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

/// Test-only format matching a 4-byte magic at offset 0 — exercises the
/// registry exactly the way a real format package plugs in (§5).
final class _MagicFormat extends ArchiveFormat {
  _MagicFormat(this.name, String magic) : _magic = ascii.encode(magic);

  @override
  final String name;
  final List<int> _magic;

  int openCalls = 0;

  @override
  Future<bool> matches(ByteSource source) async {
    final head = await source.read(0, _magic.length);
    for (var i = 0; i < _magic.length; i++) {
      if (head[i] != _magic[i]) return false;
    }
    return true;
  }

  @override
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    openCalls++;
    return _FixedReader(this);
  }
}

final class _FixedReader extends ArchiveReader {
  _FixedReader(this.format);

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries = List.unmodifiable([
    ArchiveEntry(
      path: 'hello.txt',
      type: ArchiveEntryType.file,
      uncompressedSize: 5,
    ),
  ]);

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) =>
      Stream.value(Uint8List.fromList(ascii.encode('hello')));

  @override
  Future<void> close() async {}
}

MemoryByteSource _sourceOf(String text) =>
    MemoryByteSource(Uint8List.fromList(ascii.encode(text)));

void main() {
  group('ArchiveFormatRegistry', () {
    test('detects by probing formats in registration order', () async {
      final stub = _MagicFormat('stub', 'STUB');
      final other = _MagicFormat('other', 'OTHR');
      final registry = ArchiveFormatRegistry([stub, other]);

      expect(await registry.detect(_sourceOf('STUB....')), same(stub));
      expect(await registry.detect(_sourceOf('OTHR....')), same(other));
      expect(await registry.detect(_sourceOf('none....')), isNull);
    });

    test('first registered match wins', () async {
      final first = _MagicFormat('first', 'SAME');
      final second = _MagicFormat('second', 'SAME');
      final registry =
          ArchiveFormatRegistry()
            ..register(first)
            ..register(second);
      expect(await registry.detect(_sourceOf('SAME....')), same(first));
    });

    test('a probe throwing ArchiveException is treated as non-match', () async {
      // 'LONGMAGIC' probe over-reads a 2-byte source -> UnexpectedEof inside
      // matches(); detection must move on, not abort.
      final greedy = _MagicFormat('greedy', 'LONGMAGIC');
      final tiny = _MagicFormat('tiny', 'Hi');
      final registry = ArchiveFormatRegistry([greedy, tiny]);
      expect(await registry.detect(_sourceOf('Hi')), same(tiny));
      expect(await registry.detect(_sourceOf('x')), isNull);
    });

    test('openReader drives detection end-to-end', () async {
      final stub = _MagicFormat('stub', 'STUB');
      final registry = ArchiveFormatRegistry([stub]);
      final reader = await registry.openReader(_sourceOf('STUB payload'));

      expect(reader.format.name, 'stub');
      expect(reader.entries, hasLength(1));
      expect(reader.entries.single.path, 'hello.txt');
      final content = await reader.openRead(reader.entries.single).toList();
      expect(utf8.decode(content.expand<int>((c) => c).toList()), 'hello');
      await reader.close();
    });

    test('openReader throws UnsupportedFormatException naming formats', () {
      final registry = ArchiveFormatRegistry([
        _MagicFormat('stub', 'STUB'),
        _MagicFormat('other', 'OTHR'),
      ]);
      expect(
        () => registry.openReader(_sourceOf('mystery bytes')),
        throwsA(
          isA<UnsupportedFormatException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('stub'), contains('other')),
          ),
        ),
      );
    });

    test('an explicit format skips detection (§5 escape hatch)', () async {
      final stub = _MagicFormat('stub', 'STUB');
      final registry = ArchiveFormatRegistry(); // empty on purpose
      final reader = await registry.openReader(
        _sourceOf('anything at all'),
        format: stub,
      );
      expect(reader.format.name, 'stub');
      expect(stub.openCalls, 1);
    });

    test('formats view is unmodifiable and ordered', () {
      final a = _MagicFormat('a', 'AAAA');
      final b = _MagicFormat('b', 'BBBB');
      final registry = ArchiveFormatRegistry([a])..register(b);
      expect(registry.formats.map((f) => f.name), ['a', 'b']);
      expect(() => registry.formats.add(a), throwsUnsupportedError);
    });
  });
}

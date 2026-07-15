import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/koni_tar.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// Writes an archive to memory via the given [build] callback.
Future<Uint8List> writeArchive(
  Future<void> Function(ArchiveWriter writer) build,
) async {
  final sink = BytesBuilderSink();
  final writer = const TarWriteFormat().openWriter(
    sink,
    const ArchiveWriteOptions(),
  );
  await build(writer);
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<Map<String, Uint8List>> readAll(Uint8List archive) async {
  final reader = await const TarFormat().openReader(
    MemoryByteSource(archive),
    const ArchiveReadOptions(),
  );
  final result = <String, Uint8List>{};
  for (final entry in reader.entries) {
    if (entry.type == ArchiveEntryType.file) {
      final chunks = await reader.openRead(entry).toList();
      result[entry.path] = Uint8List.fromList(
        chunks.expand<int>((c) => c).toList(),
      );
    } else {
      result[entry.path] = Uint8List(0);
    }
  }
  return result;
}

void main() {
  group('round-trip through the reader', () {
    test('files, sizes, and content survive', () async {
      final data = Uint8List.fromList(
        List.generate(3000, (i) => (i * 7 + 1) & 0xFF),
      );
      final archive = await writeArchive((w) async {
        await w.addBytes(ArchiveEntrySpec(path: 'hello.txt'), _bytes('hi\n'));
        await w.addBytes(ArchiveEntrySpec(path: 'empty.txt'), Uint8List(0));
        await w.addBytes(ArchiveEntrySpec(path: 'nested/deep/data.bin'), data);
      });
      final files = await readAll(archive);
      expect(
        files.keys,
        containsAll(<String>['hello.txt', 'empty.txt', 'nested/deep/data.bin']),
      );
      expect(utf8.decode(files['hello.txt']!), 'hi\n');
      expect(files['empty.txt'], isEmpty);
      expect(files['nested/deep/data.bin'], data);
    });

    test('metadata (mode, mtime) round-trips', () async {
      final when = DateTime.utc(2021, 6, 15, 12, 30, 45);
      final archive = await writeArchive((w) async {
        await w.addBytes(
          ArchiveEntrySpec(
            path: 'f.txt',
            modified: when,
            posixMode: int.parse('640', radix: 8),
          ),
          _bytes('x'),
        );
      });
      final reader = await const TarFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      final entry = reader.entries.single;
      expect(entry.modified, when);
      expect(entry.posixMode! & 0xFFF, int.parse('640', radix: 8));
    });

    test('directories and symlinks round-trip', () async {
      final archive = await writeArchive((w) async {
        await w.addEntry(
          ArchiveEntrySpec(path: 'dir', type: ArchiveEntryType.directory),
        );
        await w.addEntry(
          ArchiveEntrySpec(
            path: 'link',
            type: ArchiveEntryType.symlink,
            linkTarget: 'dir/target',
          ),
        );
      });
      final reader = await const TarFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      final byPath = {for (final e in reader.entries) e.path: e};
      expect(byPath['dir']!.type, ArchiveEntryType.directory);
      expect(byPath['link']!.type, ArchiveEntryType.symlink);
      expect(byPath['link']!.linkTarget, 'dir/target');
    });

    test('unicode names round-trip', () async {
      final archive = await writeArchive((w) async {
        await w.addBytes(
          ArchiveEntrySpec(path: '日本語/ページ001.txt'),
          _bytes('unicode'),
        );
      });
      final files = await readAll(archive);
      expect(utf8.decode(files['日本語/ページ001.txt']!), 'unicode');
    });

    test('long names use PAX and round-trip', () async {
      final longName = '${'L' * 160}.txt';
      final archive = await writeArchive((w) async {
        await w.addBytes(ArchiveEntrySpec(path: longName), _bytes('long'));
      });
      // A PAX 'x' header should precede the file (more than one 512 block
      // of headers before the data).
      final files = await readAll(archive);
      expect(files.keys, contains(longName));
      expect(utf8.decode(files[longName]!), 'long');
    });

    test('a prefix-splittable long name round-trips', () async {
      // 120-char name that splits on a slash into prefix ≤155 + name ≤100.
      final name = '${'a' * 80}/${'b' * 40}.txt';
      final archive = await writeArchive((w) async {
        await w.addBytes(ArchiveEntrySpec(path: name), _bytes('split'));
      });
      final files = await readAll(archive);
      expect(utf8.decode(files[name]!), 'split');
    });
  });

  group('streaming and validation', () {
    test('addStream writes chunked content', () async {
      final archive = await writeArchive((w) async {
        await w.addStream(
          ArchiveEntrySpec(path: 'stream.bin'),
          Stream.fromIterable([_bytes('chunk one '), _bytes('chunk two')]),
          size: 19,
        );
      });
      final files = await readAll(archive);
      expect(utf8.decode(files['stream.bin']!), 'chunk one chunk two');
    });

    test('a size mismatch is a typed error', () async {
      final sink = BytesBuilderSink();
      final writer = const TarWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await expectLater(
        writer.addStream(
          ArchiveEntrySpec(path: 'x'),
          Stream.value(_bytes('too short')),
          size: 100,
        ),
        throwsA(isA<CorruptArchiveException>()),
      );
    });

    test('invalid paths are rejected', () async {
      final sink = BytesBuilderSink();
      final writer = const TarWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await expectLater(
        writer.addBytes(ArchiveEntrySpec(path: '../evil'), Uint8List(0)),
        throwsArgumentError,
      );
    });

    test('non-stored compression is rejected', () async {
      final sink = BytesBuilderSink();
      final writer = const TarWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await expectLater(
        writer.addBytes(
          ArchiveEntrySpec(path: 'x', compression: ArchiveCompression.deflate),
          Uint8List(0),
        ),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });

    test('add after close throws', () async {
      final sink = BytesBuilderSink();
      final writer = const TarWriteFormat().openWriter(
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

  test('output ends with two zero blocks', () async {
    final archive = await writeArchive((w) async {
      await w.addBytes(ArchiveEntrySpec(path: 'a'), _bytes('a'));
    });
    expect(archive.length % 512, 0);
    final tail = archive.sublist(archive.length - 1024);
    expect(tail.every((b) => b == 0), isTrue);
  });
}

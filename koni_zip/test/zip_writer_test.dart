import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

Future<Uint8List> writeArchive(
  Future<void> Function(ArchiveWriter writer) build, {
  ArchiveWriteOptions options = const ArchiveWriteOptions(),
}) async {
  final sink = BytesBuilderSink();
  final writer = const ZipWriteFormat().openWriter(sink, options);
  await build(writer);
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<Map<String, Uint8List>> readAll(Uint8List archive) async {
  final reader = await const ZipFormat().openReader(
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
    }
  }
  return result;
}

void main() {
  group('round-trip through the reader (CRC verified)', () {
    test('deflate (default) entries survive', () async {
      final data = Uint8List.fromList(utf8.encode('koni archive! ' * 500));
      final archive = await writeArchive((w) async {
        await w.addBytes(ArchiveEntrySpec(path: 'hello.txt'), _bytes('hi\n'));
        await w.addBytes(ArchiveEntrySpec(path: 'nested/deep/data.txt'), data);
        await w.addBytes(ArchiveEntrySpec(path: 'empty.txt'), Uint8List(0));
      });
      final files = await readAll(archive);
      expect(utf8.decode(files['hello.txt']!), 'hi\n');
      expect(files['nested/deep/data.txt'], data);
      expect(files['empty.txt'], isEmpty);
      // The default is deflate: a redundant file should be smaller stored.
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      final big = reader.entries.firstWhere((e) => e.path.endsWith('data.txt'));
      expect(big.compression, ArchiveCompression.deflate);
      expect(big.compressedSize, lessThan(big.uncompressedSize));
    });

    test('stored entries survive', () async {
      final data = Uint8List.fromList(
        List.generate(3000, (i) => (i * 7) & 0xFF),
      );
      final archive = await writeArchive(
        (w) async {
          await w.addBytes(ArchiveEntrySpec(path: 'raw.bin'), data);
        },
        options: const ArchiveWriteOptions(
          compression: ArchiveCompression.stored,
        ),
      );
      final files = await readAll(archive);
      expect(files['raw.bin'], data);
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      expect(reader.entries.single.compression, ArchiveCompression.stored);
    });

    test('per-entry compression override', () async {
      final archive = await writeArchive((w) async {
        await w.addBytes(
          ArchiveEntrySpec(
            path: 'image.png',
            compression: ArchiveCompression.stored,
          ),
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]),
        );
        await w.addBytes(
          ArchiveEntrySpec(path: 'text.txt'),
          _bytes('ab' * 100),
        );
      });
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      final byPath = {for (final e in reader.entries) e.path: e};
      expect(byPath['image.png']!.compression, ArchiveCompression.stored);
      expect(byPath['text.txt']!.compression, ArchiveCompression.deflate);
    });

    test('metadata, directories, and unicode names', () async {
      final when = DateTime.utc(2021, 6, 15, 12, 30, 44);
      final archive = await writeArchive((w) async {
        await w.addEntry(
          ArchiveEntrySpec(path: 'dir', type: ArchiveEntryType.directory),
        );
        await w.addBytes(
          ArchiveEntrySpec(
            path: '日本語/ページ001.txt',
            modified: when,
            posixMode: int.parse('644', radix: 8),
          ),
          _bytes('unicode'),
        );
      });
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      final byPath = {for (final e in reader.entries) e.path: e};
      expect(byPath.keys, contains('dir'));
      expect(byPath['dir']!.type, ArchiveEntryType.directory);
      final page = byPath['日本語/ページ001.txt']!;
      expect(page.modified, when);
      expect(page.posixMode! & 0x1FF, int.parse('644', radix: 8));
    });

    test('symlinks store the target and round-trip type', () async {
      final archive = await writeArchive((w) async {
        await w.addEntry(
          ArchiveEntrySpec(
            path: 'latest',
            type: ArchiveEntryType.symlink,
            linkTarget: 'releases/v2',
          ),
        );
      });
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      final entry = reader.entries.single;
      expect(entry.type, ArchiveEntryType.symlink);
      // The link target is the entry content (ZIP convention).
      final target = await reader.openRead(entry).toList();
      expect(utf8.decode(target.expand<int>((c) => c).toList()), 'releases/v2');
    });

    test('a large-count archive triggers the ZIP64 end record', () async {
      // >0xFFFF entries forces the ZIP64 EOCD path; our reader parses it.
      final archive = await writeArchive(
        (w) async {
          for (var i = 0; i < 70000; i++) {
            await w.addBytes(ArchiveEntrySpec(path: 'e$i'), Uint8List(0));
          }
        },
        options: const ArchiveWriteOptions(
          compression: ArchiveCompression.stored,
        ),
      );
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(archive),
        const ArchiveReadOptions(),
      );
      expect(reader.entries.length, 70000);
      expect(reader.entries.first.path, 'e0');
      expect(reader.entries.last.path, 'e69999');
    });
  });

  group('validation', () {
    test('invalid paths and size mismatch are typed errors', () async {
      final sink = BytesBuilderSink();
      final writer = const ZipWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await expectLater(
        writer.addBytes(ArchiveEntrySpec(path: '../x'), Uint8List(0)),
        throwsArgumentError,
      );
      await expectLater(
        writer.addStream(
          ArchiveEntrySpec(path: 'y'),
          Stream.value(_bytes('too long!')),
          size: 3,
        ),
        throwsA(isA<SizeLimitExceededException>()),
      );
    });

    test('unsupported compression method is rejected', () async {
      final sink = BytesBuilderSink();
      final writer = const ZipWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(compression: ArchiveCompression.lzma),
      );
      await expectLater(
        writer.addBytes(ArchiveEntrySpec(path: 'x'), Uint8List(0)),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });
  });
}

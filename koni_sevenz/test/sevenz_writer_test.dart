import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

Future<Uint8List> writeArchive(
  Future<void> Function(ArchiveWriter writer) build, {
  ArchiveWriteOptions options = const ArchiveWriteOptions(),
}) async {
  final sink = BytesBuilderSink();
  final writer = const SevenZWriteFormat().openWriter(sink, options);
  await build(writer);
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<SevenZReader> read(Uint8List archive) => SevenZReader.parse(
  const SevenZFormat(),
  MemoryByteSource(archive),
  const ArchiveReadOptions(),
);

Future<Map<String, Uint8List>> readFiles(Uint8List archive) async {
  final reader = await read(archive);
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
  group('round-trip through the reader (CRC verified by default)', () {
    test('deflate (default) entries survive', () async {
      final data = Uint8List.fromList(utf8.encode('koni 7z! ' * 500));
      late ArchiveEntry written;
      final archive = await writeArchive((w) async {
        await w.addBytes(ArchiveEntrySpec(path: 'hello.txt'), _bytes('hi\n'));
        written = await w.addBytes(
          ArchiveEntrySpec(path: 'nested/deep/data.txt'),
          data,
        );
      });
      final files = await readFiles(archive);
      expect(utf8.decode(files['hello.txt']!), 'hi\n');
      expect(files['nested/deep/data.txt'], data);

      // The writer's returned entry carries the compressed size; the redundant
      // input compressed well. (The reader exposes uncompressed size only.)
      expect(written.compression, ArchiveCompression.deflate);
      expect(written.compressedSize, lessThan(written.uncompressedSize));

      final reader = await read(archive);
      final big = reader.entries.firstWhere((e) => e.path.endsWith('data.txt'));
      expect(big.compression, ArchiveCompression.deflate);
    });

    test('stored (copy) entries survive', () async {
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
      expect((await readFiles(archive))['raw.bin'], data);
      final reader = await read(archive);
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
      final reader = await read(archive);
      final byPath = {for (final e in reader.entries) e.path: e};
      expect(byPath['image.png']!.compression, ArchiveCompression.stored);
      expect(byPath['text.txt']!.compression, ArchiveCompression.deflate);
    });

    test('metadata, directories, empty files, and unicode names', () async {
      final when = DateTime.utc(2021, 6, 15, 12, 30, 44);
      final archive = await writeArchive((w) async {
        await w.addEntry(
          ArchiveEntrySpec(path: 'dir', type: ArchiveEntryType.directory),
        );
        await w.addBytes(ArchiveEntrySpec(path: 'empty.txt'), Uint8List(0));
        await w.addBytes(
          ArchiveEntrySpec(
            path: '日本語/ページ.txt',
            modified: when,
            posixMode: int.parse('644', radix: 8),
          ),
          _bytes('unicode'),
        );
      });
      final reader = await read(archive);
      final byPath = {for (final e in reader.entries) e.path: e};
      expect(byPath['dir']!.type, ArchiveEntryType.directory);
      expect(byPath['empty.txt']!.type, ArchiveEntryType.file);
      expect(byPath['empty.txt']!.uncompressedSize, 0);
      final page = byPath['日本語/ページ.txt']!;
      expect(page.modified, when);
      expect(page.posixMode! & 0x1FF, int.parse('644', radix: 8));
      expect(
        utf8.decode((await readFiles(archive))['日本語/ページ.txt']!),
        'unicode',
      );
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
      final reader = await read(archive);
      final entry = reader.entries.single;
      expect(entry.type, ArchiveEntryType.symlink);
      final target = await reader.openRead(entry).toList();
      expect(utf8.decode(target.expand<int>((c) => c).toList()), 'releases/v2');
    });

    test('a many-entry archive round-trips', () async {
      final archive = await writeArchive((w) async {
        for (var i = 0; i < 200; i++) {
          await w.addBytes(
            ArchiveEntrySpec(path: 'e$i.txt'),
            _bytes('body $i'),
          );
        }
      });
      final files = await readFiles(archive);
      expect(files.length, 200);
      expect(utf8.decode(files['e0.txt']!), 'body 0');
      expect(utf8.decode(files['e199.txt']!), 'body 199');
    });

    test('an empty archive round-trips to zero entries', () async {
      final archive = await writeArchive((w) async {});
      final reader = await read(archive);
      expect(reader.entries, isEmpty);
    });
  });

  group('validation', () {
    test('invalid paths and size mismatch are typed errors', () async {
      final sink = BytesBuilderSink();
      final writer = const SevenZWriteFormat().openWriter(
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
      final writer = const SevenZWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(compression: ArchiveCompression.lzma),
      );
      await expectLater(
        writer.addBytes(ArchiveEntrySpec(path: 'x'), _bytes('data')),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });
  });
}

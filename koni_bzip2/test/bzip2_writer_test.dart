@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_bzip2/koni_bzip2.dart';
import 'package:test/test.dart';

Future<Uint8List> writeBz2(
  Uint8List data, {
  ArchiveWriteOptions options = const ArchiveWriteOptions(),
  ArchiveEntrySpec? spec,
  int blockSize100k = 9,
}) async {
  final sink = BytesBuilderSink();
  final writer = Bzip2WriteFormat(
    blockSize100k: blockSize100k,
  ).openWriter(sink, options);
  await writer.addBytes(spec ?? ArchiveEntrySpec(path: 'data'), data);
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<Uint8List> readBack(Uint8List bz2) async {
  final reader = await const Bzip2Format().openReader(
    MemoryByteSource(bz2),
    const ArchiveReadOptions(),
  );
  final out = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(reader.entries.single)) {
    out.add(chunk);
  }
  await reader.close();
  return out.takeBytes();
}

/// Decodes [bz2] with the real `bzip2` binary, or null when it is unavailable.
Future<Uint8List?> bzip2Decode(Uint8List bz2) async {
  try {
    await Process.run('bzip2', ['--help']);
  } on ProcessException {
    return null;
  }
  final proc = await Process.start('bzip2', ['-dc']);
  proc.stdin.add(bz2);
  await proc.stdin.close();
  final out = <int>[];
  final collect = proc.stdout.forEach(out.addAll);
  final err = await proc.stderr.transform(systemEncoding.decoder).join();
  await collect;
  final code = await proc.exitCode;
  if (code != 0) fail('bzip2 -d failed (exit $code): $err');
  return Uint8List.fromList(out);
}

void main() {
  final sample = Uint8List.fromList(('the quick brown fox. ' * 800).codeUnits);

  group('round trip through our own reader', () {
    test('preserves content', () async {
      expect(await readBack(await writeBz2(sample)), sample);
    });

    test('empty input writes a valid, readable empty stream', () async {
      final bz2 = await writeBz2(Uint8List(0));
      expect(bz2.sublist(0, 4), 'BZh9'.codeUnits);
      expect(await readBack(bz2), isEmpty);
    });

    test('an unwritten entry still closes to a valid empty stream', () async {
      final sink = BytesBuilderSink();
      final writer = const Bzip2WriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await writer.close();
      await sink.close();
      expect(await readBack(sink.takeBytes()), isEmpty);
    });

    test('reported entry metadata is accurate', () async {
      final sink = BytesBuilderSink();
      final writer = const Bzip2WriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      final entry = await writer.addBytes(
        ArchiveEntrySpec(path: 'data.txt'),
        sample,
      );
      await writer.close();
      await sink.close();
      expect(entry.uncompressedSize, sample.length);
      expect(entry.compressedSize, sink.takeBytes().length);
      expect(entry.compression, ArchiveCompression.bzip2);
    });

    test('the block-size level is honored', () async {
      for (final level in [1, 5, 9]) {
        expect(
          await readBack(await writeBz2(sample, blockSize100k: level)),
          sample,
          reason: 'L$level',
        );
      }
    });
  });

  group('output decodes with the real bzip2', () {
    test('repetitive text', () async {
      final decoded = await bzip2Decode(await writeBz2(sample));
      if (decoded == null) {
        markTestSkipped('bzip2 binary not available');
        return;
      }
      expect(decoded, sample);
    });

    test('multi-block, small block size', () async {
      final data = Uint8List.fromList(
        List.generate(260000, (i) => (i * 7 + (i >> 3)) & 0xFF),
      );
      final decoded = await bzip2Decode(await writeBz2(data, blockSize100k: 1));
      if (decoded == null) {
        markTestSkipped('bzip2 binary not available');
        return;
      }
      expect(decoded, data);
    });
  });

  group('rejects unsupported operations', () {
    test('a password (bzip2 has no encryption)', () {
      expect(
        () => const Bzip2WriteFormat().openWriter(
          BytesBuilderSink(),
          const ArchiveWriteOptions(password: 'secret'),
        ),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });

    test('a second entry', () async {
      final sink = BytesBuilderSink();
      final writer = const Bzip2WriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await writer.addBytes(ArchiveEntrySpec(path: 'a'), sample);
      await expectLater(
        writer.addBytes(ArchiveEntrySpec(path: 'b'), sample),
        throwsStateError,
      );
    });

    test('a directory entry', () async {
      final sink = BytesBuilderSink();
      final writer = const Bzip2WriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await expectLater(
        writer.addEntry(
          ArchiveEntrySpec(path: 'dir/', type: ArchiveEntryType.directory),
        ),
        throwsArgumentError,
      );
    });

    test('a mismatched per-entry compression', () async {
      final sink = BytesBuilderSink();
      final writer = const Bzip2WriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await expectLater(
        writer.addBytes(
          ArchiveEntrySpec(path: 'a', compression: ArchiveCompression.zstd),
          sample,
        ),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });
  });
}

@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zstd/koni_zstd.dart';
import 'package:test/test.dart';

Future<Uint8List> writeZst(
  Uint8List data, {
  ArchiveWriteOptions options = const ArchiveWriteOptions(),
  ArchiveEntrySpec? spec,
}) async {
  final sink = BytesBuilderSink();
  final writer = const ZstdWriteFormat().openWriter(sink, options);
  await writer.addBytes(spec ?? ArchiveEntrySpec(path: 'data'), data);
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<Uint8List> readBack(Uint8List zst) async {
  final reader = await const ZstdFormat().openReader(
    MemoryByteSource(zst),
    const ArchiveReadOptions(),
  );
  final out = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(reader.entries.single)) {
    out.add(chunk);
  }
  await reader.close();
  return out.takeBytes();
}

/// Decodes [zst] with the real `zstd` binary, or null when it is unavailable.
Future<Uint8List?> zstdDecode(Uint8List zst) async {
  try {
    await Process.run('zstd', ['--version']);
  } on ProcessException {
    return null;
  }
  final proc = await Process.start('zstd', ['-dc']);
  proc.stdin.add(zst);
  await proc.stdin.close();
  final out = <int>[];
  final collect = proc.stdout.forEach(out.addAll);
  final err = await proc.stderr.transform(systemEncoding.decoder).join();
  await collect;
  final code = await proc.exitCode;
  if (code != 0) fail('zstd -d failed (exit $code): $err');
  return Uint8List.fromList(out);
}

void main() {
  final sample = Uint8List.fromList(('the quick brown fox. ' * 800).codeUnits);

  group('round trip through our own reader', () {
    test('preserves content', () async {
      expect(await readBack(await writeZst(sample)), sample);
    });

    test('empty input writes a valid, readable empty frame', () async {
      final zst = await writeZst(Uint8List(0));
      expect(zst.sublist(0, 4), [0x28, 0xB5, 0x2F, 0xFD]); // frame magic
      expect(await readBack(zst), isEmpty);
    });

    test('an unwritten entry still closes to a valid empty frame', () async {
      final sink = BytesBuilderSink();
      final writer = const ZstdWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await writer.close();
      await sink.close();
      expect(await readBack(sink.takeBytes()), isEmpty);
    });

    test('reported entry metadata is accurate', () async {
      final sink = BytesBuilderSink();
      final writer = const ZstdWriteFormat().openWriter(
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
      expect(entry.compression, ArchiveCompression.zstd);
    });
  });

  group('output decodes with the real zstd', () {
    test('repetitive text', () async {
      final decoded = await zstdDecode(await writeZst(sample));
      if (decoded == null) {
        markTestSkipped('zstd binary not available');
        return;
      }
      expect(decoded, sample);
    });

    test('multi-block content', () async {
      final data = Uint8List.fromList(
        List.generate(
          400000,
          (i) => (i % 900 < 560) ? 97 + (i % 6) : (i * 11) & 0xFF,
        ),
      );
      final decoded = await zstdDecode(await writeZst(data));
      if (decoded == null) {
        markTestSkipped('zstd binary not available');
        return;
      }
      expect(decoded, data);
    });
  });

  group('rejects unsupported operations', () {
    test('a password (zstd has no encryption)', () {
      expect(
        () => const ZstdWriteFormat().openWriter(
          BytesBuilderSink(),
          const ArchiveWriteOptions(password: 'secret'),
        ),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });

    test('a second entry', () async {
      final sink = BytesBuilderSink();
      final writer = const ZstdWriteFormat().openWriter(
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
      final writer = const ZstdWriteFormat().openWriter(
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
      final writer = const ZstdWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await expectLater(
        writer.addBytes(
          ArchiveEntrySpec(path: 'a', compression: ArchiveCompression.bzip2),
          sample,
        ),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });
  });
}

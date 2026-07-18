@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_xz/koni_xz.dart';
import 'package:test/test.dart';

Future<Uint8List> writeXz(
  Uint8List data, {
  ArchiveWriteOptions options = const ArchiveWriteOptions(),
  ArchiveEntrySpec? spec,
}) async {
  final sink = BytesBuilderSink();
  final writer = const XzWriteFormat().openWriter(sink, options);
  await writer.addBytes(spec ?? ArchiveEntrySpec(path: 'data'), data);
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<Uint8List> readBack(Uint8List xz) async {
  final reader = await const XzFormat().openReader(
    MemoryByteSource(xz),
    const ArchiveReadOptions(),
  );
  final out = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(reader.entries.single)) {
    out.add(chunk);
  }
  await reader.close();
  return out.takeBytes();
}

/// Decodes [xz] with the real `xz` binary, or null when `xz` is not installed.
Future<Uint8List?> xzDecode(Uint8List xz) async {
  final ProcessResult probe;
  try {
    probe = await Process.run('xz', ['--version']);
  } on ProcessException {
    return null;
  }
  if (probe.exitCode != 0) return null;
  final proc = await Process.start('xz', ['-dc']);
  proc.stdin.add(xz);
  await proc.stdin.close();
  final out = <int>[];
  await proc.stdout.forEach(out.addAll);
  final err = await proc.stderr.transform(systemEncoding.decoder).join();
  final code = await proc.exitCode;
  if (code != 0) fail('xz -d failed: $err');
  return Uint8List.fromList(out);
}

void main() {
  final sample = Uint8List.fromList(('the quick brown fox. ' * 800).codeUnits);

  group('round trip through our own reader', () {
    for (final data in <(String, Uint8List)>[
      ('empty', Uint8List(0)),
      ('tiny', Uint8List.fromList('hi\n'.codeUnits)),
      ('compressible text', sample),
      ('ramp', Uint8List.fromList(List.generate(20000, (i) => (i * 7) & 0xFF))),
      (
        'incompressible',
        Uint8List.fromList(List.generate(8192, (i) => (i * 131 + 17) & 0xFF)),
      ),
    ]) {
      test('${data.$1} round-trips', () async {
        expect(await readBack(await writeXz(data.$2)), data.$2);
      });
    }
  });

  group('entry metadata', () {
    test('the returned entry reports sizes and LZMA2', () async {
      final sink = BytesBuilderSink();
      final writer = const XzWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      final entry = await writer.addBytes(
        ArchiveEntrySpec(path: 'data'),
        sample,
      );
      await writer.close();
      await sink.close();
      expect(entry.type, ArchiveEntryType.file);
      expect(entry.uncompressedSize, sample.length);
      expect(entry.compression, ArchiveCompression.lzma2);
      expect(entry.compressedSize, sink.takeBytes().length);
      expect(entry.compressedSize, lessThan(sample.length)); // it compressed
    });
  });

  group('empty stream', () {
    test('matches the xz-authored empty.xz byte-for-byte', () async {
      final ours = await writeXz(Uint8List(0));
      final xzEmpty = Uint8List.fromList(
        File('test/fixtures/xz/empty.xz').readAsBytesSync(),
      );
      expect(ours, xzEmpty);
    });

    test('closing with no entry at all writes the empty stream', () async {
      final sink = BytesBuilderSink();
      final writer = const XzWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await writer.close();
      await sink.close();
      expect(await readBack(sink.takeBytes()), isEmpty);
    });
  });

  group('rejections', () {
    test('a second entry is rejected', () async {
      final sink = BytesBuilderSink();
      final writer = const XzWriteFormat().openWriter(
        sink,
        const ArchiveWriteOptions(),
      );
      await writer.addBytes(ArchiveEntrySpec(path: 'a'), sample);
      expect(
        () => writer.addBytes(ArchiveEntrySpec(path: 'b'), sample),
        throwsStateError,
      );
    });

    test('a password is rejected at openWriter', () {
      expect(
        () => const XzWriteFormat().openWriter(
          BytesBuilderSink(),
          const ArchiveWriteOptions(password: 'secret'),
        ),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });

    test('a directory/other entry is rejected', () async {
      final writer = const XzWriteFormat().openWriter(
        BytesBuilderSink(),
        const ArchiveWriteOptions(),
      );
      expect(
        () => writer.addEntry(
          ArchiveEntrySpec(path: 'd', type: ArchiveEntryType.directory),
        ),
        throwsArgumentError,
      );
    });

    test('a non-LZMA2 compression request is rejected', () async {
      final writer = const XzWriteFormat().openWriter(
        BytesBuilderSink(),
        const ArchiveWriteOptions(),
      );
      expect(
        () => writer.addBytes(
          ArchiveEntrySpec(path: 'x', compression: ArchiveCompression.deflate),
          sample,
        ),
        throwsA(isA<UnsupportedCompressionException>()),
      );
    });

    test('over-declared size is a typed error', () async {
      final writer = const XzWriteFormat().openWriter(
        BytesBuilderSink(),
        const ArchiveWriteOptions(),
      );
      expect(
        writer.addStream(
          ArchiveEntrySpec(path: 'x'),
          Stream.value(Uint8List.fromList([1, 2, 3])),
          size: 2, // fewer than streamed
        ),
        throwsA(isA<SizeLimitExceededException>()),
      );
    });

    test('under-declared size is a typed error', () async {
      final writer = const XzWriteFormat().openWriter(
        BytesBuilderSink(),
        const ArchiveWriteOptions(),
      );
      expect(
        writer.addStream(
          ArchiveEntrySpec(path: 'x'),
          Stream.value(Uint8List.fromList([1, 2, 3])),
          size: 5, // more than streamed
        ),
        throwsA(isA<CorruptArchiveException>()),
      );
    });
  });

  group('interop with the xz tool (skipped when absent)', () {
    for (final data in <(String, Uint8List)>[
      ('empty', Uint8List(0)),
      ('text', sample),
      ('ramp', Uint8List.fromList(List.generate(30000, (i) => (i * 7) & 0xFF))),
    ]) {
      test('xz -d decodes our ${data.$1} output', () async {
        final decoded = await xzDecode(await writeXz(data.$2));
        if (decoded == null) {
          markTestSkipped('xz not installed');
          return;
        }
        expect(decoded, data.$2);
      });
    }
  });
}

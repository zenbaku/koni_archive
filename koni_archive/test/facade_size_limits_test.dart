import 'dart:typed_data';

import 'package:koni_archive/koni_archive.dart';
import 'package:test/test.dart';

/// End-to-end decompression-bomb guards through the facade over a real ZIP
/// built with the writer: one large, highly compressible entry (a genuine
/// bomb shape — tiny compressed, large decoded) plus two small ones. Runs on
/// VM and web (no fixtures).
void main() {
  Future<Uint8List> buildZip() async {
    final sink = BytesBuilderSink();
    final writer = Archive.create(sink, format: const ZipWriteFormat());
    // 50 000 zero bytes deflate to a handful of bytes: the classic bomb shape.
    await writer.addBytes(ArchiveEntrySpec(path: 'big.bin'), Uint8List(50000));
    await writer.addBytes(
      ArchiveEntrySpec(path: 'small1.bin'),
      Uint8List.fromList([1, 2, 3]),
    );
    await writer.addBytes(
      ArchiveEntrySpec(path: 'small2.bin'),
      Uint8List.fromList([4, 5, 6]),
    );
    await writer.close();
    await sink.close();
    return sink.takeBytes();
  }

  test(
    'maxEntrySize aborts a streamed decode that grows past the limit',
    () async {
      final archive = await Archive.openBytes(
        await buildZip(),
        options: const ArchiveReadOptions(maxEntrySize: 1024),
      );
      addTearDown(archive.close);
      final big = archive.entry('big.bin')!;

      // Streaming through openRead errors mid-decode...
      await expectLater(
        archive.openRead(big).drain<void>(),
        throwsA(
          isA<SizeLimitExceededException>()
              .having((e) => e.limit, 'limit', 1024)
              .having((e) => e.entryPath, 'entryPath', 'big.bin')
              .having((e) => e.format, 'format', 'zip'),
        ),
      );
      // ...and so does the whole-entry convenience.
      await expectLater(
        archive.readBytes(big),
        throwsA(isA<SizeLimitExceededException>()),
      );
      // A small entry under the limit is unaffected.
      expect(await archive.readBytes(archive.entry('small1.bin')!), [1, 2, 3]);
    },
  );

  test(
    'a maxEntrySize equal to the decoded size reads the whole entry',
    () async {
      final archive = await Archive.openBytes(
        await buildZip(),
        options: const ArchiveReadOptions(maxEntrySize: 50000),
      );
      addTearDown(archive.close);
      expect(
        await archive.readBytes(archive.entry('big.bin')!),
        hasLength(50000),
      );
    },
  );

  test("readBytes's maxSize composes as a tighter, per-call bound", () async {
    final archive = await Archive.openBytes(
      await buildZip(),
      options: const ArchiveReadOptions(maxEntrySize: 50000),
    );
    addTearDown(archive.close);
    await expectLater(
      archive.readBytes(archive.entry('big.bin')!, maxSize: 100),
      throwsA(isA<SizeLimitExceededException>()),
    );
  });

  test('maxEntryCount rejects an over-count archive at open', () async {
    final zip = await buildZip(); // three entries
    await expectLater(
      Archive.openBytes(
        zip,
        options: const ArchiveReadOptions(maxEntryCount: 2),
      ),
      throwsA(
        isA<SizeLimitExceededException>()
            .having((e) => e.limit, 'limit', 2)
            .having((e) => e.format, 'format', 'zip'),
      ),
    );
    // Exactly the entry count is allowed.
    final ok = await Archive.openBytes(
      zip,
      options: const ArchiveReadOptions(maxEntryCount: 3),
    );
    addTearDown(ok.close);
    expect(ok.entries, hasLength(3));
  });

  test('no limits: the large entry reads unbounded (control)', () async {
    final archive = await Archive.openBytes(await buildZip());
    addTearDown(archive.close);
    expect(
      await archive.readBytes(archive.entry('big.bin')!),
      hasLength(50000),
    );
  });
}

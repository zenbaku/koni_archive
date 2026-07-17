@TestOn('vm')
library;

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// `.tar.gz` is the one format with an open-time bulk decode: the container is
/// decompressed while its inner TAR is enumerated, before any per-entry stream
/// exists. That decode is bounded by `maxContainerDecodeSize`, which for gzip
/// **falls back to `maxEntrySize`** when unset (the container is a one-time
/// open cost, so a per-entry limit alone still protects against a gzip bomb).
/// The fixture's inner tar is ~100 KB (`data.bin` alone is 100 000 bytes).
void main() {
  const tarGz = '../koni_gzip/test/fixtures/gzip/tarball.tar.gz';

  test(
    'maxContainerDecodeSize below the decompressed size rejects at open',
    () async {
      await expectLater(
        openArchiveFile(
          tarGz,
          options: const ArchiveReadOptions(maxContainerDecodeSize: 1000),
        ),
        throwsA(
          isA<SizeLimitExceededException>()
              .having((e) => e.format, 'format', 'gzip')
              .having((e) => e.limit, 'limit', 1000),
        ),
      );
    },
  );

  test(
    'maxContainerDecodeSize above the decompressed size opens and reads',
    () async {
      final archive = await openArchiveFile(
        tarGz,
        options: const ArchiveReadOptions(maxContainerDecodeSize: 200000),
      );
      addTearDown(archive.close);
      expect(archive.format.name, 'tar');
      expect(
        await archive.readBytes(archive.entry('data.bin')!),
        hasLength(100000),
      );
    },
  );

  test('maxEntrySize alone bounds the container decode (falls back)', () async {
    // With no explicit container limit, maxEntrySize is the fallback: the
    // ~100 KB container exceeds 1000, so it is rejected at open.
    await expectLater(
      openArchiveFile(
        tarGz,
        options: const ArchiveReadOptions(maxEntrySize: 1000),
      ),
      throwsA(
        isA<SizeLimitExceededException>()
            .having((e) => e.format, 'format', 'gzip')
            .having((e) => e.limit, 'limit', 1000),
      ),
    );
  });

  test(
    'an explicit maxContainerDecodeSize overrides the maxEntrySize fallback',
    () async {
      // Container bounded by the explicit 200 000 (opens), while maxEntrySize
      // still bounds each entry's own output.
      final archive = await openArchiveFile(
        tarGz,
        options: const ArchiveReadOptions(
          maxEntrySize: 1000,
          maxContainerDecodeSize: 200000,
        ),
      );
      addTearDown(archive.close);
      // A small entry under the per-entry limit reads fine...
      expect(await archive.readBytes(archive.entry('hello.txt')!), isNotEmpty);
      // ...but data.bin (100 000 B) exceeds the per-entry limit.
      await expectLater(
        archive.readBytes(archive.entry('data.bin')!),
        throwsA(
          isA<SizeLimitExceededException>().having(
            (e) => e.limit,
            'limit',
            1000,
          ),
        ),
      );
    },
  );
}

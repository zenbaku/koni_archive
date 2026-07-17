@TestOn('vm')
library;

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// The one open-time decompression vector: a layered `.tar.gz` is decompressed
/// while its inner TAR is enumerated, before any per-entry stream exists.
/// `maxEntrySize` caps that decode too, so the container is rejected at open
/// rather than read fully into memory. The fixture's inner tar is ~100 KB
/// (`data.bin` alone is 100 000 bytes).
void main() {
  const tarGz = '../koni_gzip/test/fixtures/gzip/tarball.tar.gz';

  test('a maxEntrySize below the decompressed size rejects at open', () async {
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

  test('a maxEntrySize above the decompressed size opens and reads', () async {
    final archive = await openArchiveFile(
      tarGz,
      options: const ArchiveReadOptions(maxEntrySize: 200000),
    );
    addTearDown(archive.close);
    expect(archive.format.name, 'tar');
    expect(
      await archive.readBytes(archive.entry('data.bin')!),
      hasLength(100000),
    );
  });
}

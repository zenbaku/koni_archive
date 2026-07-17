@TestOn('vm')
library;

import 'package:koni_archive/io.dart';
import 'package:test/test.dart';

/// The reason the container-cap fallback is gzip-only, not uniform: a 7z solid
/// folder is decoded as a unit to reach any entry, so it is routinely larger
/// than the entry you asked for. `maxEntrySize` must therefore **not** bound
/// the folder decode — otherwise a per-entry limit would reject a small entry
/// buried in a bigger solid folder (breaking solid-CB7 page-flipping). Only an
/// explicit `maxContainerDecodeSize` bounds it.
///
/// The fixture is a real solid CB7: 3 pages of 1032 bytes in one folder, so
/// the folder is ~3 KB while each page is ~1 KB.
void main() {
  const cb7 = '../koni_sevenz/test/fixtures/sevenz/synthetic_comic.cb7';

  test(
    'maxEntrySize between a page and the folder still reads the page',
    () async {
      // 2000 is above one 1032-byte page but below the ~3 KB solid folder.
      final archive = await openArchiveFile(
        cb7,
        options: const ArchiveReadOptions(maxEntrySize: 2000),
      );
      addTearDown(archive.close);
      final page = archive.glob('comic/*.png').first;
      // Reading decodes the whole solid folder (~3 KB); maxEntrySize does not
      // bound that, and the page itself (1032 B) is under the per-entry limit.
      expect(await archive.readBytes(page), hasLength(1032));
    },
  );

  test(
    'an explicit maxContainerDecodeSize does bound the same folder decode',
    () async {
      final archive = await openArchiveFile(
        cb7,
        options: const ArchiveReadOptions(maxContainerDecodeSize: 2000),
      );
      addTearDown(archive.close);
      final page = archive.glob('comic/*.png').first;
      // Same 2000, but as a container cap: the ~3 KB folder decode is rejected.
      await expectLater(
        archive.readBytes(page),
        throwsA(
          isA<SizeLimitExceededException>()
              .having((e) => e.format, 'format', '7z')
              .having((e) => e.limit, 'limit', 2000),
        ),
      );
    },
  );
}

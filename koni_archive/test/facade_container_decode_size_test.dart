import 'dart:typed_data';

import 'package:koni_archive/koni_archive.dart';
import 'package:test/test.dart';

/// `maxContainerDecodeSize` bounds 7z's bulk decodes. Reading even a small
/// entry decodes its whole (solid) folder as a unit, and this caps that
/// decode — tightening 7z's built-in 1 GiB folder / 64 MiB header backstops
/// to a caller-chosen value (the per-entry `maxEntrySize` never sees the
/// folder-sized internal decode). Built in memory with the writer (LZMA2), so
/// it runs on VM and web.
void main() {
  Future<Uint8List> buildSevenZ() async {
    final sink = BytesBuilderSink();
    final writer = Archive.create(sink, format: const SevenZWriteFormat());
    await writer.addBytes(ArchiveEntrySpec(path: 'big.bin'), Uint8List(50000));
    await writer.close();
    await sink.close();
    return sink.takeBytes();
  }

  test(
    'a folder decode past maxContainerDecodeSize is rejected on read',
    () async {
      final archive = await Archive.openBytes(
        await buildSevenZ(),
        options: const ArchiveReadOptions(maxContainerDecodeSize: 1000),
      );
      addTearDown(archive.close);
      await expectLater(
        archive.readBytes(archive.entry('big.bin')!), // folder unpackSize 50000
        throwsA(
          isA<SizeLimitExceededException>()
              .having((e) => e.format, 'format', '7z')
              .having((e) => e.limit, 'limit', 1000),
        ),
      );
    },
  );

  test('a limit at or above the folder size reads normally', () async {
    final archive = await Archive.openBytes(
      await buildSevenZ(),
      options: const ArchiveReadOptions(maxContainerDecodeSize: 50000),
    );
    addTearDown(archive.close);
    expect(
      await archive.readBytes(archive.entry('big.bin')!),
      hasLength(50000),
    );
  });

  test('null (default) leaves 7z at its built-in caps (control)', () async {
    final archive = await Archive.openBytes(await buildSevenZ());
    addTearDown(archive.close);
    expect(
      await archive.readBytes(archive.entry('big.bin')!),
      hasLength(50000),
    );
  });
}

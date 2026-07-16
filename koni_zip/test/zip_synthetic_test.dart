import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

import 'src/zip_builder.dart';

Future<ArchiveReader> parse(
  Uint8List bytes, {
  ArchiveReadOptions options = const ArchiveReadOptions(),
}) => const ZipFormat().openReader(MemoryByteSource(bytes), options);

Future<String> collectString(ArchiveReader reader, ArchiveEntry entry) async =>
    utf8.decode(
      (await reader.openRead(entry).toList()).expand<int>((c) => c).toList(),
    );

void main() {
  group('synthetic archives (shapes zip(1) cannot emit on demand)', () {
    test('duplicate paths are all listed in index order', () async {
      final reader = await parse(
        buildZip([
          ZipEntrySpec('dup.txt', 'first'),
          ZipEntrySpec('dup.txt', 'second!'),
        ]),
      );
      expect(reader.entries.map((e) => e.path), ['dup.txt', 'dup.txt']);
      expect(await collectString(reader, reader.entries[0]), 'first');
      expect(await collectString(reader, reader.entries[1]), 'second!');
    });

    test('backslash separators normalize', () async {
      final reader = await parse(
        buildZip([ZipEntrySpec(r'dir\sub\file.txt', 'x')]),
      );
      expect(reader.entries.single.path, 'dir/sub/file.txt');
    });

    test('traversal names are sanitized and flagged', () async {
      final reader = await parse(
        buildZip([ZipEntrySpec('../../etc/passwd', 'pwnd')]),
      );
      final entry = reader.entries.single;
      expect(entry.path, 'etc/passwd');
      expect(entry.pathEscapedRoot, isTrue);
      expect(await collectString(reader, entry), 'pwnd');
    });

    test('data-descriptor entries read via central directory values', () async {
      final reader = await parse(
        buildZip([
          ZipEntrySpec('dd.txt', 'described data', dataDescriptor: true),
          ZipEntrySpec('after.txt', 'ok'),
        ]),
      );
      expect(await collectString(reader, reader.entries[0]), 'described data');
      expect(await collectString(reader, reader.entries[1]), 'ok');
    });

    test('CP437 fallback for non-UTF-8 names without the flag', () async {
      // 0x82 0x8A = "éè" in CP437; invalid as UTF-8.
      final reader = await parse(
        buildZip([
          ZipEntrySpec(
            '',
            'x',
            nameBytes: [0x82, 0x8A, 0x2E, 0x74, 0x78, 0x74],
          ),
        ]),
      );
      expect(reader.entries.single.path, 'éè.txt');
    });

    test('UT extra-field timestamps beat DOS timestamps', () async {
      final reader = await parse(
        buildZip([
          ZipEntrySpec('t.txt', 'x', extra: utExtra(1577934245)),
          ZipEntrySpec('dos.txt', 'x'),
        ]),
      );
      expect(
        reader.entries[0].modified,
        DateTime.utc(2020, 1, 2, 3, 4, 5),
        reason: 'UT: exact unix time',
      );
      expect(
        reader.entries[1].modified,
        DateTime.utc(2020, 1, 2, 3, 4, 6),
        reason: 'DOS: 2 s resolution, wall time exposed as UTC',
      );
    });

    test('CRC-32 is verified by default; opt-out honored', () async {
      final bytes = buildZip([
        ZipEntrySpec('bad.txt', 'corrupted content', crcOverride: 0xDEADBEEF),
      ]);

      final verifying = await parse(bytes);
      await expectLater(
        verifying.openRead(verifying.entries.single).toList(),
        throwsA(
          isA<ChecksumMismatchException>()
              .having((e) => e.actual, 'actual', isNot(0xDEADBEEF))
              .having((e) => e.entryPath, 'entryPath', 'bad.txt'),
        ),
      );

      final lax = await parse(
        bytes,
        options: const ArchiveReadOptions(verifyChecksums: false),
      );
      expect(await collectString(lax, lax.entries.single), 'corrupted content');
    });

    test('ZIP64 end-of-central-directory structures parse (M7)', () async {
      final reader = await parse(
        buildZip([
          ZipEntrySpec('a.txt', 'zip64 eocd'),
          ZipEntrySpec('b.txt', 'two'),
        ], zip64Eocd: true),
      );
      expect(reader.entries.map((e) => e.path), ['a.txt', 'b.txt']);
      expect(await collectString(reader, reader.entries[0]), 'zip64 eocd');
      expect(await collectString(reader, reader.entries[1]), 'two');
    });

    test('ZIP64 per-entry size extras parse (M7)', () async {
      final reader = await parse(
        buildZip([
          ZipEntrySpec('big.txt', 'sized via the 0x0001 extra', zip64: true),
        ], zip64Eocd: true),
      );
      final entry = reader.entries.single;
      expect(entry.uncompressedSize, 26);
      expect(entry.compressedSize, 26);
      expect(await collectString(reader, entry), 'sized via the 0x0001 extra');
    });

    test('a prefixed ZIP64 archive recovers its offset delta', () async {
      final bytes = buildZip([
        ZipEntrySpec('inner.txt', 'prefixed zip64'),
      ], zip64Eocd: true);
      final prefixed = Uint8List.fromList([
        ...List.filled(1000, 0x2A),
        ...bytes,
      ]);
      final reader = await parse(prefixed);
      expect(
        await collectString(reader, reader.entries.single),
        'prefixed zip64',
      );
    });

    test('ZIP64 markers without a locator are corrupt, typed', () async {
      await expectLater(
        parse(buildZip([ZipEntrySpec('a', 'x')], cdOffsetOverride: 0xFFFFFFFF)),
        throwsA(isA<CorruptArchiveException>()),
      );
    });

    test('the caller-supplied name decoder handles mojibake (M7)', () async {
      // 'テスト.txt' in Shift-JIS, not valid UTF-8, garbage in CP437.
      const sjisName = [
        0x83,
        0x65,
        0x83,
        0x58,
        0x83,
        0x67,
        0x2E,
        0x74,
        0x78,
        0x74,
      ];
      final bytes = buildZip([
        ZipEntrySpec('', 'content', nameBytes: sjisName),
      ]);

      final defaulted = await parse(bytes);
      expect(
        defaulted.entries.single.path,
        isNot('テスト.txt'),
        reason: 'CP437 fallback cannot know this is Shift-JIS',
      );

      // A real app would use a charset package; the hook contract only
      // needs bytes -> string.
      const sjisKatakana = {0x65: 'テ', 0x58: 'ス', 0x67: 'ト'};
      final hooked = await parse(
        bytes,
        options: ArchiveReadOptions(
          entryNameDecoder: (nameBytes) {
            final buffer = StringBuffer();
            for (var i = 0; i < nameBytes.length; i++) {
              if (nameBytes[i] == 0x83) {
                buffer.write(sjisKatakana[nameBytes[++i]]);
              } else {
                buffer.writeCharCode(nameBytes[i]);
              }
            }
            return buffer.toString();
          },
        ),
      );
      expect(hooked.entries.single.path, 'テスト.txt');
      expect(await collectString(hooked, hooked.entries.single), 'content');
    });

    test('AE-x entries expose the inner method and encryption (M7)', () async {
      final bytes = buildZip([
        ZipEntrySpec(
          'secret.bin',
          'ciphertext-ish',
          method: 99,
          extra: const [
            0x01, 0x99, 7, 0, // id 0x9901, size 7
            0x02, 0x00, // vendor version AE-2
            0x41, 0x45, // 'AE'
            0x03, // strength: AES-256
            0x08, 0x00, // actual method: deflate
          ],
        ),
      ]);
      final reader = await parse(bytes);
      final entry = reader.entries.single;
      expect(entry.isEncrypted, isTrue);
      expect(entry.compression, ArchiveCompression.deflate);
      expect(
        () => reader.openRead(entry),
        throwsA(isA<EncryptedArchiveException>()),
      );
    });

    test(
      'strong-encryption flag (bit 6) marks the entry encrypted (M7)',
      () async {
        final bytes = buildZip([ZipEntrySpec('s', 'x')]);
        // Set bit 6 in the central directory flags (offset within the CD
        // record: sig(4)+madeBy(2)+needed(2) = 8).
        var at = -1;
        for (var i = 0; i < bytes.length - 4; i++) {
          if (bytes[i] == 0x50 &&
              bytes[i + 1] == 0x4B &&
              bytes[i + 2] == 0x01 &&
              bytes[i + 3] == 0x02) {
            at = i;
            break;
          }
        }
        bytes[at + 8] |= 0x40;
        final reader = await parse(bytes);
        expect(reader.entries.single.isEncrypted, isTrue);
      },
    );

    test('multi-volume EOCD throws a typed error', () async {
      await expectLater(
        parse(buildZip([ZipEntrySpec('a', 'x')], diskNumber: 1)),
        throwsA(
          isA<UnsupportedFeatureException>().having(
            (e) => e.message,
            'message',
            contains('multi-volume'),
          ),
        ),
      );
    });

    test('trailing junk after the EOCD is tolerated (fallback scan)', () async {
      final reader = await parse(
        buildZip([
          ZipEntrySpec('a.txt', 'content'),
        ], trailingJunk: List.filled(100, 0x00)),
      );
      expect(await collectString(reader, reader.entries.single), 'content');
    });

    test(
      'a central entry pointing at garbage fails at openRead only',
      () async {
        final bytes = buildZip([
          ZipEntrySpec('ok.txt', 'fine'),
          ZipEntrySpec('broken.txt', 'never seen'),
        ]);
        // Corrupt the *second* local header signature (the first PK\x03\x04
        // after offset 0).
        var at = -1;
        for (var i = 4; i < bytes.length - 4; i++) {
          if (bytes[i] == 0x50 &&
              bytes[i + 1] == 0x4B &&
              bytes[i + 2] == 0x03 &&
              bytes[i + 3] == 0x04) {
            at = i;
            break;
          }
        }
        expect(at, greaterThan(0));
        bytes[at] = 0x51;

        final reader = await parse(bytes);
        expect(reader.entries, hasLength(2));
        expect(await collectString(reader, reader.entries[0]), 'fine');
        await expectLater(
          reader.openRead(reader.entries[1]).toList(),
          throwsA(isA<CorruptArchiveException>()),
        );
      },
    );

    test('hostile entry counts fail cleanly, no OOM', () async {
      // EOCD claims more entries than the central directory can hold.
      final bytes = buildZip([
        ZipEntrySpec('a', 'x'),
      ], totalEntriesOverride: 20000);
      await expectLater(parse(bytes), throwsA(isA<CorruptArchiveException>()));
    });

    test('truncated central directory throws typed errors', () async {
      final full = buildZip([ZipEntrySpec('a.txt', 'content')]);
      for (final cut in [full.length - 1, full.length - 12, 30, 21, 4]) {
        final sliced = Uint8List.sublistView(full, 0, cut);
        await expectLater(
          parse(sliced),
          throwsA(isA<ArchiveException>()),
          reason: 'cut at $cut',
        );
      }
    });
  });
}

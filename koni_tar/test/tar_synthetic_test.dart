import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/koni_tar.dart';
import 'package:test/test.dart';

import 'src/tar_builder.dart';

Future<ArchiveReader> parse(Uint8List bytes) => const TarFormat().openReader(
  MemoryByteSource(bytes),
  const ArchiveReadOptions(),
);

Future<String> collectString(ArchiveReader reader, ArchiveEntry entry) async =>
    utf8.decode(
      (await reader.openRead(entry).toList()).expand<int>((c) => c).toList(),
    );

void main() {
  group('synthetic headers (shapes reference tools cannot emit on demand)', () {
    test('base-256 size field is honored', () async {
      // A size just over the octal-11-digit ceiling is impractical to ship
      // as a real fixture; encode a small size in base-256 instead — the
      // parser cannot tell the difference.
      final content = utf8.encode('base-256 sized');
      final header = tarHeader(
        name: 'b256.txt',
        size: 0,
        mutate: (block) => putBase256(block, 124, 12, content.length),
      );
      final reader = await parse(tarArchive([header, tarData(content)]));
      expect(reader.entries.single.uncompressedSize, content.length);
      expect(
        await collectString(reader, reader.entries.single),
        'base-256 sized',
      );
    });

    test('base-256 negative mtime (pre-epoch) is honored', () async {
      final header = tarHeader(
        name: 'old.txt',
        mutate: (block) => putBase256(block, 136, 12, -86400),
      );
      final reader = await parse(tarArchive([header]));
      expect(reader.entries.single.modified, DateTime.utc(1969, 12, 31));
    });

    test('device entries are represented, not materialized', () async {
      final header = tarHeader(name: 'dev/null', typeFlag: '3');
      final reader = await parse(tarArchive([header]));
      expect(reader.entries.single.type, ArchiveEntryType.characterDevice);
      expect(await collectString(reader, reader.entries.single), isEmpty);
    });

    test('unknown type flags are represented as other', () async {
      final header = tarHeader(name: 'weird', typeFlag: 'Z');
      final reader = await parse(tarArchive([header]));
      expect(reader.entries.single.type, ArchiveEntryType.other);
    });

    test('path traversal is sanitized and flagged, never raw (§7)', () async {
      final header = tarHeader(name: '../../etc/passwd', size: 4);
      final reader = await parse(
        tarArchive([header, tarData(utf8.encode('pwnd'))]),
      );
      final entry = reader.entries.single;
      expect(entry.path, 'etc/passwd');
      expect(entry.pathEscapedRoot, isTrue);
      // Content is still readable; only the path is sanitized.
      expect(await collectString(reader, entry), 'pwnd');
    });

    test('hardlink with a nonzero size consumes no data blocks '
        '(GNU/bsdtar behavior)', () async {
      // Some historic tars record the source file's size on hardlinks.
      final hard = tarHeader(
        name: 'hard.txt',
        typeFlag: '1',
        linkName: 'orig.txt',
        size: 999,
      );
      final follower = tarHeader(name: 'after.txt', size: 2);
      final reader = await parse(
        tarArchive([hard, follower, tarData(utf8.encode('ok'))]),
      );
      expect(reader.entries.map((e) => e.path), ['hard.txt', 'after.txt']);
      expect(await collectString(reader, reader.entries[1]), 'ok');
    });

    test('PAX mtime and size override the header fields', () async {
      final paxData = utf8.encode(
        paxRecord('mtime', '1577934245.123456') + paxRecord('size', '6'),
      );
      final pax = tarHeader(
        name: 'PaxHeaders/f',
        typeFlag: 'x',
        size: paxData.length,
      );
      final file = tarHeader(name: 'f.txt', size: 0);
      final reader = await parse(
        tarArchive([
          pax,
          tarData(paxData),
          file,
          tarData(utf8.encode('abcdef')),
        ]),
      );
      final entry = reader.entries.single;
      expect(entry.uncompressedSize, 6);
      expect(entry.modified, DateTime.utc(2020, 1, 2, 3, 4, 5, 123, 456));
      expect(await collectString(reader, entry), 'abcdef');
    });

    test(
      'global PAX headers apply to subsequent entries; per-file wins',
      () async {
        final globalData = utf8.encode(paxRecord('path', 'global-name'));
        final global = tarHeader(
          name: 'g',
          typeFlag: 'g',
          size: globalData.length,
        );
        final fileA = tarHeader(name: 'a.txt');
        final perFileData = utf8.encode(paxRecord('path', 'file-name'));
        final perFile = tarHeader(
          name: 'p',
          typeFlag: 'x',
          size: perFileData.length,
        );
        final fileB = tarHeader(name: 'b.txt');
        final reader = await parse(
          tarArchive([
            global,
            tarData(globalData),
            fileA,
            perFile,
            tarData(perFileData),
            fileB,
          ]),
        );
        expect(reader.entries.map((e) => e.path), ['global-name', 'file-name']);
      },
    );

    test(
      'GNU sparse entries list but reading throws a typed error (§8)',
      () async {
        final sparseData = utf8.encode('not really sparse data');
        final sparse = tarHeader(
          name: 'sparse.bin',
          typeFlag: 'S',
          size: sparseData.length,
        );
        final follower = tarHeader(name: 'after.txt', size: 2);
        final reader = await parse(
          tarArchive([
            sparse,
            tarData(sparseData),
            follower,
            tarData(utf8.encode('ok')),
          ]),
        );
        expect(reader.entries.map((e) => e.path), ['sparse.bin', 'after.txt']);
        expect(
          () => reader.openRead(reader.entries.first),
          throwsA(
            isA<UnsupportedFeatureException>()
                .having((e) => e.entryPath, 'entryPath', 'sparse.bin')
                .having((e) => e.message, 'message', contains('sparse')),
          ),
        );
        // The rest of the archive stays readable (§9).
        expect(await collectString(reader, reader.entries[1]), 'ok');
      },
    );
  });

  group('corruption and truncation (typed errors only, §7)', () {
    test('bad checksum throws InvalidHeaderException', () {
      final bytes = tarArchive([tarHeader(name: 'x', corruptChecksum: true)]);
      expect(() => parse(bytes), throwsA(isA<InvalidHeaderException>()));
    });

    test('entry data past EOF throws UnexpectedEofException', () {
      final header = tarHeader(name: 'huge.bin', size: 1000000);
      expect(
        () => parse(tarArchive([header])),
        throwsA(
          isA<UnexpectedEofException>().having(
            (e) => e.entryPath,
            'entryPath',
            'huge.bin',
          ),
        ),
      );
    });

    test('a header block cut mid-way ends the walk cleanly', () async {
      final full = tarArchive([
        tarHeader(name: 'ok.txt', size: 2),
        tarData(utf8.encode('ok')),
      ]);
      // Slice to a non-block-multiple length inside what would be the next
      // header: the walk must stop, not crash or hang.
      final truncated = Uint8List.sublistView(full, 0, 1200);
      final reader = await parse(truncated);
      expect(reader.entries.map((e) => e.path), ['ok.txt']);
    });

    test('metadata entries with absurd sizes are rejected (§7)', () {
      final pax = tarHeader(
        name: 'p',
        typeFlag: 'x',
        size: 500 * 1024 * 1024, // pretends half a gigabyte of PAX records
      );
      expect(
        () => parse(tarArchive([pax, tarHeader(name: 'f')])),
        throwsA(isA<ArchiveException>()),
      );
    });

    test(
      'garbage that accidentally passes no checks throws, never hangs',
      () async {
        final garbage = Uint8List.fromList(
          List.generate(4096, (i) => (i * 251 + 7) & 0xFF),
        );
        await expectLater(
          () => parse(garbage),
          throwsA(isA<ArchiveException>()),
        );
      },
    );
  });
}

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

void main() {
  group('ArchiveCompression', () {
    test('known constants have names and no raw id', () {
      expect(ArchiveCompression.stored.name, 'stored');
      expect(ArchiveCompression.stored.rawId, isNull);
      expect(ArchiveCompression.deflate.toString(), 'deflate');
    });

    test('unknown carries the raw method id for diagnostics', () {
      const unknown = ArchiveCompression.unknown(98);
      expect(unknown.name, 'unknown');
      expect(unknown.rawId, 98);
      expect(unknown.toString(), 'unknown(0x62)');
    });

    test('has value equality', () {
      expect(
        const ArchiveCompression.unknown(98),
        const ArchiveCompression.unknown(98),
      );
      expect(
        const ArchiveCompression.unknown(98),
        isNot(const ArchiveCompression.unknown(99)),
      );
      expect(ArchiveCompression.stored, isNot(ArchiveCompression.deflate));
    });
  });

  group('ArchiveEntry', () {
    test('carries the full model with sensible defaults', () {
      final entry = ArchiveEntry(
        path: 'ch01/page001.webp',
        type: ArchiveEntryType.file,
        uncompressedSize: 12345,
      );
      expect(entry.path, 'ch01/page001.webp');
      expect(entry.isFile, isTrue);
      expect(entry.isDirectory, isFalse);
      expect(entry.compression, ArchiveCompression.stored);
      expect(entry.compressedSize, isNull);
      expect(entry.modified, isNull);
      expect(entry.linkTarget, isNull);
      expect(entry.posixMode, isNull);
      expect(entry.crc32, isNull);
      expect(entry.isEncrypted, isFalse);
      expect(entry.pathEscapedRoot, isFalse);
    });

    test('accepts UTC modification times', () {
      final entry = ArchiveEntry(
        path: 'f',
        type: ArchiveEntryType.file,
        uncompressedSize: 0,
        modified: DateTime.utc(2020, 1, 2, 3, 4, 5),
      );
      expect(entry.modified!.isUtc, isTrue);
    });

    test('represents exotic types as metadata', () {
      final link = ArchiveEntry(
        path: 'latest',
        type: ArchiveEntryType.symlink,
        uncompressedSize: 0,
        linkTarget: 'releases/v2',
      );
      expect(link.type, ArchiveEntryType.symlink);
      expect(link.linkTarget, 'releases/v2');
    });

    test('toString is informative', () {
      final entry = ArchiveEntry(
        path: 'a.txt',
        type: ArchiveEntryType.file,
        uncompressedSize: 7,
        isEncrypted: true,
      );
      expect(entry.toString(), contains('a.txt'));
      expect(entry.toString(), contains('encrypted'));
    });
  });
}

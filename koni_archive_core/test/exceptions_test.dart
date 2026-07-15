import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

void main() {
  group('exception hierarchy', () {
    test('all subtypes are ArchiveExceptions', () {
      final all = <ArchiveException>[
        UnsupportedFormatException('m'),
        CorruptArchiveException('m'),
        UnexpectedEofException('m'),
        InvalidHeaderException('m'),
        ChecksumMismatchException('m'),
        UnsupportedFeatureException('m'),
        UnsupportedCompressionException('m'),
        EncryptedArchiveException('m'),
        SizeLimitExceededException('m'),
        ArchiveClosedException('m'),
        EntryNotFoundException('m'),
      ];
      for (final e in all) {
        expect(e, isA<ArchiveException>());
        expect(e, isA<Exception>());
      }
    });

    test('truncation and bad headers are corruption', () {
      expect(UnexpectedEofException('m'), isA<CorruptArchiveException>());
      expect(InvalidHeaderException('m'), isA<CorruptArchiveException>());
      expect(ChecksumMismatchException('m'), isA<CorruptArchiveException>());
    });

    test('unsupported compression is an unsupported feature', () {
      expect(
        UnsupportedCompressionException('m'),
        isA<UnsupportedFeatureException>(),
      );
    });

    test('toString carries message and context', () {
      final e = CorruptArchiveException(
        'central directory truncated',
        format: 'zip',
        offset: 1234,
        entryPath: 'a/b.txt',
      );
      final s = e.toString();
      expect(s, contains('central directory truncated'));
      expect(s, contains('format: zip'));
      expect(s, contains('offset: 1234'));
      expect(s, contains('entry: a/b.txt'));
    });

    test('toString omits absent context', () {
      expect(ArchiveException('boom').toString(), endsWith('boom'));
    });

    test('diagnostic payload fields are preserved', () {
      final compression = UnsupportedCompressionException(
        'ppmd is not supported',
        methodName: 'ppmd',
        methodId: 98,
      );
      expect(compression.methodName, 'ppmd');
      expect(compression.methodId, 98);

      final checksum = ChecksumMismatchException(
        'crc32 mismatch',
        expected: 0xCBF43926,
        actual: 0xDEADBEEF,
      );
      expect(checksum.expected, 0xCBF43926);
      expect(checksum.actual, 0xDEADBEEF);

      final size = SizeLimitExceededException('too big', limit: 1024);
      expect(size.limit, 1024);
    });
  });
}

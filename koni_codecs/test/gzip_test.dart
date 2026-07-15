import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

import 'src/vectors.dart';

void main() {
  group('single member', () {
    test('decodes content and exposes header metadata', () {
      GzipMemberHeader? seen;
      final decoder = GzipDecoder(onMemberHeader: (h) => seen = h);
      expect(utf8.decode(decoder.convert(gzipNamed)), 'hello, gzip!\n');
      expect(seen!.fileName, 'hello.txt');
      expect(seen!.modified, DateTime.utc(2020, 1, 2, 3, 4, 5));
      expect(seen!.comment, isNull);
    });

    test('anonymous member has no name or mtime', () {
      GzipMemberHeader? seen;
      final decoder = GzipDecoder(onMemberHeader: (h) => seen = h);
      expect(utf8.decode(decoder.convert(gzipSecond)), 'second member\n');
      expect(seen!.fileName, isNull);
      expect(seen!.modified, isNull);
    });
  });

  group('multi-member (§8)', () {
    final concatenated = Uint8List.fromList([...gzipNamed, ...gzipSecond]);

    test('decodes concatenated members into concatenated output', () {
      final headers = <GzipMemberHeader>[];
      final decoder = GzipDecoder(onMemberHeader: headers.add);
      expect(
        utf8.decode(decoder.convert(concatenated)),
        'hello, gzip!\nsecond member\n',
      );
      expect(headers, hasLength(2));
      expect(headers[0].fileName, 'hello.txt');
      expect(headers[1].fileName, isNull);
    });

    test('chunk boundaries never matter, even mid-trailer', () {
      for (final chunkSize in [1, 3, 7, 41]) {
        final out = BytesBuilder(copy: false);
        final sink = const GzipDecoder().startChunkedConversion(
          ByteConversionSink.withCallback(out.add),
        );
        for (var i = 0; i < concatenated.length; i += chunkSize) {
          sink.add(
            concatenated.sublist(i, min(i + chunkSize, concatenated.length)),
          );
        }
        sink.close();
        expect(
          utf8.decode(out.takeBytes()),
          'hello, gzip!\nsecond member\n',
          reason: 'chunk size $chunkSize',
        );
      }
    });

    test('trailing non-gzip garbage is ignored (gzip(1) behavior)', () {
      final withGarbage = Uint8List.fromList([...gzipNamed, 0x00, 0x51, 0x99]);
      expect(
        utf8.decode(const GzipDecoder().convert(withGarbage)),
        'hello, gzip!\n',
      );
      // A lone 0x1F at the very end is also garbage, not a member start.
      final loneMagicByte = Uint8List.fromList([...gzipNamed, 0x1F]);
      expect(
        utf8.decode(const GzipDecoder().convert(loneMagicByte)),
        'hello, gzip!\n',
      );
    });
  });

  group('malformed input throws FormatException', () {
    test('bad magic', () {
      expect(
        () => const GzipDecoder().convert([0x50, 0x4B, 3, 4, 0, 0, 0, 0, 0, 0]),
        throwsFormatException,
      );
    });

    test('reserved flag bits', () {
      final bad = Uint8List.fromList(gzipNamed);
      bad[3] |= 0x80;
      expect(() => const GzipDecoder().convert(bad), throwsFormatException);
    });

    test('unsupported compression method', () {
      final bad = Uint8List.fromList(gzipNamed);
      bad[2] = 7;
      expect(() => const GzipDecoder().convert(bad), throwsFormatException);
    });

    test('CRC-32 mismatch detected by default, ignorable on opt-out', () {
      final bad = Uint8List.fromList(gzipNamed);
      bad[bad.length - 5] ^= 0xFF; // corrupt stored CRC (last 8: crc+isize)
      expect(() => const GzipDecoder().convert(bad), throwsFormatException);
      expect(
        utf8.decode(const GzipDecoder(verifyChecksums: false).convert(bad)),
        'hello, gzip!\n',
      );
    });

    test('ISIZE mismatch', () {
      final bad = Uint8List.fromList(gzipNamed);
      bad[bad.length - 1] ^= 0x01;
      expect(() => const GzipDecoder().convert(bad), throwsFormatException);
    });

    test('truncation at every prefix', () {
      for (var cut = 0; cut < gzipNamed.length; cut++) {
        expect(
          () => const GzipDecoder().convert(gzipNamed.sublist(0, cut)),
          throwsFormatException,
          reason: 'cut at $cut',
        );
      }
    });

    test('second member truncated', () {
      final bad = Uint8List.fromList([
        ...gzipNamed,
        ...gzipSecond.sublist(0, 15),
      ]);
      expect(() => const GzipDecoder().convert(bad), throwsFormatException);
    });
  });

  group('tryParseGzipHeader', () {
    test('returns null for undecidably short input', () {
      expect(
        tryParseGzipHeader(Uint8List.fromList(gzipNamed.sublist(0, 5))),
        isNull,
      );
      // FNAME's NUL not reached yet:
      expect(
        tryParseGzipHeader(Uint8List.fromList(gzipNamed.sublist(0, 14))),
        isNull,
      );
    });

    test('parses a complete header and reports its length', () {
      final (header, length) =
          tryParseGzipHeader(Uint8List.fromList(gzipNamed))!;
      expect(header.fileName, 'hello.txt');
      expect(length, 20); // 10 fixed + 'hello.txt' + NUL
    });
  });
}

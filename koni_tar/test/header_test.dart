import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/src/header.dart';
import 'package:test/test.dart';

import 'src/tar_builder.dart';

Uint8List _field(List<int> bytes) {
  final block = Uint8List(512);
  block.setRange(0, bytes.length, bytes);
  return block;
}

void main() {
  group('parseNumeric (octal)', () {
    test('parses NUL- and space-terminated octal', () {
      expect(parseNumeric(_field('0000644\x00'.codeUnits), 0, 8, 0, 'f'), 420);
      expect(parseNumeric(_field('0000644 '.codeUnits), 0, 8, 0, 'f'), 420);
      expect(parseNumeric(_field('   644 \x00'.codeUnits), 0, 8, 0, 'f'), 420);
    });

    test('blank field is null', () {
      expect(parseNumeric(_field('        '.codeUnits), 0, 8, 0, 'f'), isNull);
      expect(
        parseNumeric(_field([0, 0, 0, 0, 0, 0, 0, 0]), 0, 8, 0, 'f'),
        isNull,
      );
    });

    test('garbage throws InvalidHeaderException with offset', () {
      expect(
        () => parseNumeric(_field('12x4    '.codeUnits), 0, 8, 100, 'size'),
        throwsA(
          isA<InvalidHeaderException>()
              .having((e) => e.offset, 'offset', 100)
              .having((e) => e.format, 'format', 'tar'),
        ),
      );
      expect(
        () => parseNumeric(_field('99999999'.codeUnits), 0, 8, 0, 'f'),
        throwsA(isA<InvalidHeaderException>()),
      );
    });
  });

  group('parseNumeric (base-256)', () {
    Uint8List encoded(int value, [int len = 12]) {
      final block = Uint8List(512);
      putBase256(block, 0, len, value);
      return block;
    }

    test('round-trips positive values', () {
      for (final value in [0, 1, 511, 0x100000000, 17179869184 /* 16 GiB */]) {
        expect(
          parseNumeric(encoded(value), 0, 12, 0, 'size'),
          value,
          reason: '$value',
        );
      }
    });

    test('round-trips negative values (mtime before 1970)', () {
      for (final value in [-1, -256, -1577934245]) {
        expect(
          parseNumeric(encoded(value), 0, 12, 0, 'mtime'),
          value,
          reason: '$value',
        );
      }
    });
  });

  group('TarHeader.parse', () {
    test('parses a well-formed ustar header', () {
      final header =
          TarHeader.parse(
            tarHeader(name: 'dir/file.txt', size: 1234, typeFlag: '0'),
            0,
          )!;
      expect(header.name, 'dir/file.txt');
      expect(header.size, 1234);
      expect(header.mode, 420);
      expect(header.mtime, 1577934245);
      expect(header.typeFlag, 0x30);
      expect(header.magicIsUstar, isTrue);
      expect(header.fullName, 'dir/file.txt');
    });

    test('applies the POSIX prefix field', () {
      final header =
          TarHeader.parse(
            tarHeader(name: 'file.txt', prefix: 'some/long/prefix'),
            0,
          )!;
      expect(header.fullName, 'some/long/prefix/file.txt');
    });

    test('returns null for an all-zero block (end marker)', () {
      expect(TarHeader.parse(Uint8List(512), 0), isNull);
    });

    test('rejects a corrupted checksum with context', () {
      expect(
        () =>
            TarHeader.parse(tarHeader(name: 'f', corruptChecksum: true), 2048),
        throwsA(
          isA<InvalidHeaderException>().having((e) => e.offset, 'offset', 2048),
        ),
      );
    });

    test('accepts a signed-byte checksum (historic tars)', () {
      // A name with high-bit bytes makes signed and unsigned sums differ.
      final block = tarHeader(name: 'ファイル', mutate: (b) {});
      // Recompute the checksum the *signed* way.
      for (var i = 148; i < 156; i++) {
        block[i] = 0x20;
      }
      var signed = 0;
      for (final byte in block) {
        signed += byte < 128 ? byte : byte - 256;
      }
      final digits = signed.toRadixString(8).padLeft(6, '0');
      for (var i = 0; i < 6; i++) {
        block[148 + i] = digits.codeUnitAt(i);
      }
      block[154] = 0;
      block[155] = 0x20;
      expect(TarHeader.parse(block, 0)!.name, 'ファイル');
    });

    test('checksumLooksValid never throws', () {
      expect(TarHeader.checksumLooksValid(Uint8List(512)), isFalse);
      expect(
        TarHeader.checksumLooksValid(_field('garbage'.codeUnits)..[0] = 0xFF),
        isFalse,
      );
      expect(TarHeader.checksumLooksValid(tarHeader(name: 'ok')), isTrue);
    });
  });

  group('decodeTarString', () {
    test('decodes UTF-8 and stops at NUL', () {
      // UTF-8 bytes for 日本, then NUL, then junk that must be ignored.
      const utf8Bytes = [0xE6, 0x97, 0xA5, 0xE6, 0x9C, 0xAC];
      final bytes = Uint8List(32);
      bytes.setRange(0, utf8Bytes.length, utf8Bytes);
      bytes[utf8Bytes.length + 1] = 0x41;
      expect(decodeTarString(bytes, 0, 32), '日本');
    });

    test('falls back to Latin-1 for invalid UTF-8 (never throws, §7)', () {
      final bytes = Uint8List(8);
      bytes[0] = 0xE9; // é in Latin-1; invalid alone in UTF-8
      bytes[1] = 0x74; // t
      bytes[2] = 0xE9;
      expect(decodeTarString(bytes, 0, 8), 'été');
    });
  });
}

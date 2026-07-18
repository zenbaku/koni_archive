import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

Uint8List _ascii(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('Crc32', () {
    test('matches canonical vectors', () {
      expect(Crc32.compute(_ascii('')), 0x00000000);
      expect(Crc32.compute(_ascii('123456789')), 0xCBF43926);
      expect(
        Crc32.compute(_ascii('The quick brown fox jumps over the lazy dog')),
        0x414FA339,
      );
    });

    test('incremental chunked result equals one-shot', () {
      final data = Uint8List.fromList(
        List.generate(10000, (i) => (i * 31 + 7) & 0xFF),
      );
      final oneShot = Crc32.compute(data);
      final crc = Crc32();
      for (var i = 0; i < data.length; i += 977) {
        final end = (i + 977 <= data.length) ? i + 977 : data.length;
        crc.add(data, i, end);
      }
      expect(crc.value, oneShot);
      // value is non-destructive.
      expect(crc.value, oneShot);
    });

    test('reset returns to initial state', () {
      final crc = Crc32()..add(_ascii('junk'));
      crc.reset();
      crc.add(_ascii('123456789'));
      expect(crc.value, 0xCBF43926);
    });

    test('value stays within unsigned 32-bit range', () {
      final crc = Crc32()..add(Uint8List.fromList(List.filled(100000, 0xFF)));
      expect(crc.value, inInclusiveRange(0, 0xFFFFFFFF));
    });

    test('bytes/computeBytes are the value in little-endian', () {
      // 0xCBF43926 little-endian.
      expect(Crc32.computeBytes(_ascii('123456789')), [0x26, 0x39, 0xF4, 0xCB]);
      final crc = Crc32()..add(_ascii('123456789'));
      expect(crc.bytes, Crc32.computeBytes(_ascii('123456789')));
    });
  });

  group('Crc64', () {
    test('matches the canonical CRC-64/XZ vector, lane by lane', () {
      // Empty input: init all-ones XOR final all-ones = 0.
      final empty = Crc64()..add(_ascii(''));
      expect(empty.low, 0x00000000);
      expect(empty.high, 0x00000000);

      // "123456789" -> 0x995DC9BBDF1939FA (the standard check value).
      final check = Crc64()..add(_ascii('123456789'));
      expect(check.low, 0xDF1939FA);
      expect(check.high, 0x995DC9BB);
    });

    test('incremental chunked result equals one-shot', () {
      final data = Uint8List.fromList(
        List.generate(10000, (i) => (i * 31 + 7) & 0xFF),
      );
      final oneShot = Crc64()..add(data);
      final chunked = Crc64();
      for (var i = 0; i < data.length; i += 977) {
        final end = (i + 977 <= data.length) ? i + 977 : data.length;
        chunked.add(data, i, end);
      }
      expect(chunked.low, oneShot.low);
      expect(chunked.high, oneShot.high);
    });

    test('reset returns to initial state', () {
      final crc = Crc64()..add(_ascii('junk'));
      crc.reset();
      crc.add(_ascii('123456789'));
      expect(crc.low, 0xDF1939FA);
      expect(crc.high, 0x995DC9BB);
    });

    test('lanes stay within unsigned 32-bit range', () {
      final crc = Crc64()..add(Uint8List.fromList(List.filled(100000, 0xFF)));
      expect(crc.low, inInclusiveRange(0, 0xFFFFFFFF));
      expect(crc.high, inInclusiveRange(0, 0xFFFFFFFF));
    });

    test('bytes/computeBytes are 8 little-endian bytes (low then high)', () {
      // 0x995DC9BBDF1939FA little-endian: low 0xDF1939FA, then high 0x995DC9BB.
      expect(Crc64.computeBytes(_ascii('123456789')), [
        0xFA,
        0x39,
        0x19,
        0xDF,
        0xBB,
        0xC9,
        0x5D,
        0x99,
      ]);
      final crc = Crc64()..add(_ascii('123456789'));
      expect(crc.bytes, Crc64.computeBytes(_ascii('123456789')));
    });
  });

  group('Adler32', () {
    test('matches canonical vectors', () {
      expect(Adler32.compute(_ascii('')), 1);
      expect(Adler32.compute(_ascii('123456789')), 0x091E01DE);
      expect(Adler32.compute(_ascii('Wikipedia')), 0x11E60398);
    });

    test('incremental chunked result equals one-shot across NMAX blocks', () {
      // Longer than the 5552-byte deferred-modulo block.
      final data = Uint8List.fromList(
        List.generate(50000, (i) => (i * 13 + 5) & 0xFF),
      );
      final oneShot = Adler32.compute(data);
      final adler = Adler32();
      for (var i = 0; i < data.length; i += 6001) {
        final end = (i + 6001 <= data.length) ? i + 6001 : data.length;
        adler.add(data, i, end);
      }
      expect(adler.value, oneShot);
      expect(adler.value, inInclusiveRange(0, 0xFFFFFFFF));
    });

    test('reset returns to initial state', () {
      final adler = Adler32()..add(_ascii('junk'));
      adler.reset();
      expect(adler.value, 1);
    });
  });
}

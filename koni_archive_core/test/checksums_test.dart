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

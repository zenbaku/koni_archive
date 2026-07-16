import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

void main() {
  group('BitReader (LSB-first, DEFLATE bit order)', () {
    test('reads bits least-significant-first within each byte', () {
      // 0xB4 = 1011_0100b -> bit sequence (LSB first): 0,0,1,0,1,1,0,1
      final reader = BitReader(Uint8List.fromList([0xB4]));
      expect(reader.readBits(3), 4); // bits 0,0,1 -> 100b
      expect(reader.readBit(), false);
      expect(reader.readBits(4), 0xB); // bits 1,1,0,1 -> 1011b
      expect(reader.isAtEnd, isTrue);
    });

    test('reads values spanning byte boundaries', () {
      final reader = BitReader(Uint8List.fromList([0xB4, 0x61]));
      expect(reader.readBits(16), 0x61B4);

      final reader2 = BitReader(Uint8List.fromList([0xB4, 0x61, 0xFF]));
      expect(reader2.readBits(5), 0xB4 & 0x1F);
      expect(reader2.readBits(11), (0x61B4 >> 5) & 0x7FF);
      expect(reader2.readBits(8), 0xFF);
    });

    test('tracks bitsRemaining', () {
      final reader = BitReader(Uint8List.fromList([0, 0, 0]));
      expect(reader.bitsRemaining, 24);
      reader.readBits(5);
      expect(reader.bitsRemaining, 19);
      reader.readBits(19);
      expect(reader.bitsRemaining, 0);
    });

    test('alignToByte discards to the next boundary', () {
      final reader = BitReader(Uint8List.fromList([0xFF, 0x2A]));
      reader.readBits(3);
      reader.alignToByte();
      expect(reader.readBits(8), 0x2A);
      // Aligning when already aligned is a no-op.
      final reader2 = BitReader(Uint8List.fromList([0x11, 0x22]));
      reader2.readBits(8);
      reader2.alignToByte();
      expect(reader2.readBits(8), 0x22);
    });

    test('readAlignedBytes returns whole bytes after alignment', () {
      final reader = BitReader(Uint8List.fromList([0x01, 0xAA, 0xBB, 0xCC]));
      reader.readBits(2);
      reader.alignToByte();
      expect(reader.readAlignedBytes(2), [0xAA, 0xBB]);
      expect(reader.readBits(8), 0xCC);
      expect(
        () =>
            BitReader(Uint8List.fromList([1]))
              ..readBits(1)
              ..readAlignedBytes(1),
        throwsStateError,
      );
    });

    test('over-read throws FormatException (codec idiom)', () {
      final reader = BitReader(Uint8List.fromList([0xFF]));
      reader.readBits(6);
      expect(() => reader.readBits(3), throwsFormatException);
      expect(
        () => BitReader(Uint8List(1)).readAlignedBytes(2),
        throwsFormatException,
      );
    });

    test('respects start/end slicing', () {
      final reader = BitReader(
        Uint8List.fromList([0xAA, 0x12, 0x34, 0xBB]),
        start: 1,
        end: 3,
      );
      expect(reader.bitsRemaining, 16);
      expect(reader.readBits(16), 0x3412);
      expect(reader.isAtEnd, isTrue);
    });

    test('rejects out-of-range bit counts', () {
      final reader = BitReader(Uint8List.fromList([0, 0, 0, 0]));
      expect(() => reader.readBits(25), throwsArgumentError);
      expect(() => reader.readBits(-1), throwsArgumentError);
      expect(reader.readBits(24), 0);
      expect(reader.readBits(0), 0);
    });
  });
}

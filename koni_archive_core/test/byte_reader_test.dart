import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

void main() {
  group('ByteReader', () {
    test('reads unsigned integers in both endiannesses', () {
      final reader = ByteReader(
        Uint8List.fromList([
          0x01, // u8
          0x34, 0x12, // u16le
          0x12, 0x34, // u16be
          0x78, 0x56, 0x34, 0x12, // u32le
          0x12, 0x34, 0x56, 0x78, // u32be
        ]),
      );
      expect(reader.readUint8(), 0x01);
      expect(reader.readUint16le(), 0x1234);
      expect(reader.readUint16be(), 0x1234);
      expect(reader.readUint32le(), 0x12345678);
      expect(reader.readUint32be(), 0x12345678);
      expect(reader.isAtEnd, isTrue);
    });

    test('reads 64-bit integers composed portably', () {
      // 0x0012345678ABCDEF < 2^53: exactly representable on every platform,
      // including dart2js.
      final reader = ByteReader(
        Uint8List.fromList([
          0xEF, 0xCD, 0xAB, 0x78, 0x56, 0x34, 0x12, 0x00, // u64le
          0x00, 0x12, 0x34, 0x56, 0x78, 0xAB, 0xCD, 0xEF, // u64be
        ]),
      );
      const expected = 0x0012345678ABCDEF;
      expect(reader.readUint64le(), expected);
      expect(reader.readUint64be(), expected);
    });

    test('64-bit values beyond 2^53 throw uniformly (§7)', () {
      // A hostile value with the top bit set would wrap negative on the VM
      // if composed naively; the uniform cap rejects it everywhere.
      for (final bytes in [
        [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01], // 0x0102...
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], // would wrap
      ]) {
        expect(
          () => ByteReader(Uint8List.fromList(bytes)).readUint64le(),
          throwsA(isA<UnsupportedFeatureException>()),
          reason: '$bytes',
        );
      }
    });

    test('readBytes returns a view and advances', () {
      final backing = Uint8List.fromList([1, 2, 3, 4, 5]);
      final reader = ByteReader(backing);
      final view = reader.readBytes(3);
      expect(view, [1, 2, 3]);
      expect(reader.position, 3);
      expect(reader.remaining, 2);
      // View semantics (no defensive copy, §10).
      backing[0] = 99;
      expect(view[0], 99);
    });

    test('skip advances without reading; position is settable', () {
      final reader = ByteReader(Uint8List.fromList([1, 2, 3, 4]));
      reader.skip(2);
      expect(reader.readUint8(), 3);
      reader.position = 0;
      expect(reader.readUint8(), 1);
      expect(() => reader.position = 5, throwsArgumentError);
      expect(() => reader.position = -1, throwsArgumentError);
    });

    test('over-read throws UnexpectedEofException with archive offset', () {
      final reader = ByteReader(Uint8List.fromList([1, 2]), baseOffset: 100);
      reader.skip(1);
      expect(
        () => reader.readUint32le(),
        throwsA(
          isA<UnexpectedEofException>().having((e) => e.offset, 'offset', 101),
        ),
      );
      // Failed read must not move the cursor.
      expect(reader.position, 1);
      expect(reader.readUint8(), 2);
    });

    test('zero-length reads at the end are legal', () {
      final reader = ByteReader(Uint8List.fromList([1]));
      reader.skip(1);
      expect(reader.readBytes(0), isEmpty);
      expect(reader.isAtEnd, isTrue);
    });
  });
}

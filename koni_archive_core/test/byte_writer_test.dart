import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

void main() {
  group('byte order', () {
    test('little- and big-endian widths write the expected bytes', () {
      final w =
          ByteWriter()
            ..writeUint8(0xAB)
            ..writeUint16le(0x0102)
            ..writeUint16be(0x0102)
            ..writeUint32le(0x01020304)
            ..writeUint32be(0x01020304);
      expect(w.takeBytes(), [
        0xAB,
        0x02, 0x01, // uint16 LE
        0x01, 0x02, // uint16 BE
        0x04, 0x03, 0x02, 0x01, // uint32 LE
        0x01, 0x02, 0x03, 0x04, // uint32 BE
      ]);
    });

    test('64-bit LE/BE are split correctly', () {
      // Fits in 2^53-1 (a 64-bit field written from a safe int always has a
      // zero top byte); distinct lower bytes still prove the split + order.
      final value = 0x1A2B3C4D5E6F70; // 0x001A2B3C4D5E6F70 as 8 bytes
      final le = (ByteWriter()..writeUint64le(value)).takeBytes();
      final be = (ByteWriter()..writeUint64be(value)).takeBytes();
      expect(le, [0x70, 0x6F, 0x5E, 0x4D, 0x3C, 0x2B, 0x1A, 0x00]);
      expect(be, [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E, 0x6F, 0x70]);
    });
  });

  group('round-trips through ByteReader', () {
    test('every width composes and decomposes symmetrically', () {
      final w =
          ByteWriter()
            ..writeUint8(200)
            ..writeUint16le(50000)
            ..writeUint16be(50000)
            ..writeUint32le(0xDEADBEEF)
            ..writeUint32be(0xDEADBEEF)
            ..writeUint64le(0x1FFFFFFFFFFFFF) // 2^53 - 1
            ..writeUint64be(1234567890123)
            ..writeBytes(const [1, 2, 3])
            ..writeZeros(2);
      final r = ByteReader(w.takeBytes());
      expect(r.readUint8(), 200);
      expect(r.readUint16le(), 50000);
      expect(r.readUint16be(), 50000);
      expect(r.readUint32le(), 0xDEADBEEF);
      expect(r.readUint32be(), 0xDEADBEEF);
      expect(r.readUint64le(), 0x1FFFFFFFFFFFFF);
      expect(r.readUint64be(), 1234567890123);
      expect(r.readBytes(3), [1, 2, 3]);
      expect(r.readBytes(2), [0, 0]);
      expect(r.isAtEnd, isTrue);
    });
  });

  group('length and takeBytes', () {
    test('length tracks bytes written; takeBytes clears', () {
      final w = ByteWriter();
      expect(w.length, 0);
      w.writeUint32le(0);
      expect(w.length, 4);
      w.writeBytes(const [9, 9]);
      expect(w.length, 6);
      expect(w.takeBytes(), hasLength(6));
      expect(w.length, 0, reason: 'takeBytes clears the buffer');
    });

    test('a reused scratch buffer does not corrupt earlier writes', () {
      // Two 32-bit writes in a row must not alias the shared scratch.
      final bytes =
          (ByteWriter()
                ..writeUint32le(0x11223344)
                ..writeUint32le(0x55667788))
              .takeBytes();
      expect(bytes, [0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55]);
    });
  });

  group('range checks', () {
    test('out-of-range values throw ArgumentError', () {
      expect(() => ByteWriter().writeUint8(256), throwsArgumentError);
      expect(() => ByteWriter().writeUint8(-1), throwsArgumentError);
      expect(() => ByteWriter().writeUint16le(0x10000), throwsArgumentError);
      expect(() => ByteWriter().writeUint32le(-1), throwsArgumentError);
      // 2^53 is past the exact-integer limit.
      expect(
        () => ByteWriter().writeUint64le(9007199254740992),
        throwsArgumentError,
      );
      expect(() => ByteWriter().writeZeros(-1), throwsArgumentError);
    });
  });
}

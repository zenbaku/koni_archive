import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_codecs/crypto.dart';
import 'package:test/test.dart';

String hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List ascii(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('SHA-1 (FIPS 180-4 / RFC 3174 vectors)', () {
    test('empty message', () {
      expect(
        hex(Sha1.compute(Uint8List(0))),
        'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      );
    });

    test('"abc"', () {
      expect(
        hex(Sha1.compute(ascii('abc'))),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
    });

    test('two-block message', () {
      expect(
        hex(
          Sha1.compute(
            ascii('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
          ),
        ),
        '84983e441c3bd26ebaae4aa1f95129e5e54670f1',
      );
    });

    test('one million a (chunked add)', () {
      final sha = Sha1();
      final chunk = Uint8List.fromList(List.filled(9973, 0x61));
      var written = 0;
      while (written < 1000000) {
        final take =
            1000000 - written < chunk.length ? 1000000 - written : chunk.length;
        sha.add(chunk, 0, take);
        written += take;
      }
      expect(hex(sha.finish()), '34aa973cd4c4daa4f61eeb2bdbad27316534016f');
    });

    test('copy() snapshots a running state without disturbing it', () {
      final sha = Sha1()..add(ascii('ab'));
      final snapshot = sha.copy();
      expect(
        hex(snapshot.finish()),
        hex(Sha1.compute(ascii('ab'))),
        reason: 'snapshot finishes the prefix',
      );
      sha.add(ascii('c'));
      expect(
        hex(sha.finish()),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
        reason: 'original continues unaffected',
      );
    });

    test('finish() twice and add-after-finish are errors', () {
      final sha = Sha1()..add(ascii('abc'));
      sha.finish();
      expect(sha.finish, throwsStateError);
      expect(() => sha.add(ascii('x')), throwsStateError);
      expect(sha.copy, throwsStateError);
    });
  });

  group('SHA-256 (FIPS 180-4 vectors)', () {
    test('empty message', () {
      expect(
        hex(Sha256.compute(Uint8List(0))),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('"abc"', () {
      expect(
        hex(Sha256.compute(ascii('abc'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('two-block message', () {
      expect(
        hex(
          Sha256.compute(
            ascii('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('one million a (chunked add)', () {
      final sha = Sha256();
      final chunk = Uint8List.fromList(List.filled(65536, 0x61));
      var written = 0;
      while (written < 1000000) {
        final take =
            1000000 - written < chunk.length ? 1000000 - written : chunk.length;
        sha.add(chunk, 0, take);
        written += take;
      }
      expect(
        hex(sha.finish()),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('unaligned incremental adds equal one-shot', () {
      final data = Uint8List.fromList(
        List.generate(1031, (i) => (i * 131) & 0xFF),
      );
      final oneShot = hex(Sha256.compute(data));
      final sha = Sha256();
      var i = 0;
      for (final step in const [1, 63, 64, 65, 130, 500, 208]) {
        sha.add(data, i, i + step);
        i += step;
      }
      expect(i, data.length);
      expect(hex(sha.finish()), oneShot);
    });
  });
}

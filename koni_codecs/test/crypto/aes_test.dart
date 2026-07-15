import 'dart:typed_data';

import 'package:koni_codecs/crypto.dart';
import 'package:test/test.dart';

String hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('AES block cipher (FIPS-197 appendix C)', () {
    const plain = '00112233445566778899aabbccddeeff';

    void check(String key, String expectedCipher) {
      final aes = Aes(unhex(key));
      final block = unhex(plain);
      final out = Uint8List(16);
      aes.encryptBlock(block, 0, out, 0);
      expect(hex(out), expectedCipher, reason: 'encrypt');
      final back = Uint8List(16);
      aes.decryptBlock(out, 0, back, 0);
      expect(hex(back), plain, reason: 'decrypt');
    }

    test('AES-128', () {
      check(
        '000102030405060708090a0b0c0d0e0f',
        '69c4e0d86a7b0430d8cdb78070b4c55a',
      );
    });

    test('AES-192', () {
      check(
        '000102030405060708090a0b0c0d0e0f1011121314151617',
        'dda97ca4864cdfe06eaf70a0ec0d7191',
      );
    });

    test('AES-256', () {
      check(
        '000102030405060708090a0b0c0d0e0f'
            '101112131415161718191a1b1c1d1e1f',
        '8ea2b7ca516745bfeafc49904b496089',
      );
    });

    test('in-place transform (input aliases output)', () {
      final aes = Aes(unhex('000102030405060708090a0b0c0d0e0f'));
      final block = unhex(plain);
      aes.encryptBlock(block, 0, block, 0);
      expect(hex(block), '69c4e0d86a7b0430d8cdb78070b4c55a');
      aes.decryptBlock(block, 0, block, 0);
      expect(hex(block), plain);
    });

    test('rejects bad key lengths', () {
      expect(() => Aes(Uint8List(15)), throwsArgumentError);
      expect(() => Aes(Uint8List(0)), throwsArgumentError);
      expect(() => Aes(Uint8List(33)), throwsArgumentError);
    });
  });

  group('AES-CBC (SP 800-38A F.2)', () {
    final plaintext = unhex(
      '6bc1bee22e409f96e93d7e117393172a'
      'ae2d8a571e03ac9c9eb76fac45af8e51'
      '30c81c46a35ce411e5fbc1191a0a52ef'
      'f69f2445df4f9b17ad2b417be66c3710',
    );
    final iv = unhex('000102030405060708090a0b0c0d0e0f');

    test('CBC-AES128 encrypt + decrypt (F.2.1/F.2.2)', () {
      final key = unhex('2b7e151628aed2a6abf7158809cf4f3c');
      const expected =
          '7649abac8119b246cee98e9b12e9197d'
          '5086cb9b507219ee95db113a917678b2'
          '73bed6b8e3c1743b7116e69e22229516'
          '3ff1caa1681fac09120eca307586e1a7';
      final data = Uint8List.fromList(plaintext);
      AesCbcEncryptor(Aes(key), iv).encryptInPlace(data);
      expect(hex(data), expected);
      AesCbcDecryptor(Aes(key), iv).decryptInPlace(data);
      expect(hex(data), hex(plaintext));
    });

    test('CBC-AES256 encrypt + decrypt (F.2.5/F.2.6)', () {
      final key = unhex(
        '603deb1015ca71be2b73aef0857d7781'
        '1f352c073b6108d72d9810a30914dff4',
      );
      const expected =
          'f58c4c04d6e5f1ba779eabfb5f7bfbd6'
          '9cfc4e967edb808d679f777bc6702c7d'
          '39f23369a9d9bacfa530e26304231461'
          'b2eb05e2c39be9fcda6c19078c6a9d1b';
      final data = Uint8List.fromList(plaintext);
      AesCbcEncryptor(Aes(key), iv).encryptInPlace(data);
      expect(hex(data), expected);
      AesCbcDecryptor(Aes(key), iv).decryptInPlace(data);
      expect(hex(data), hex(plaintext));
    });

    test('chunked decryption chains across calls', () {
      final key = unhex('2b7e151628aed2a6abf7158809cf4f3c');
      final data = Uint8List.fromList(plaintext);
      AesCbcEncryptor(Aes(key), iv).encryptInPlace(data);
      final chunked = AesCbcDecryptor(Aes(key), iv);
      chunked.decryptInPlace(data, 0, 16);
      chunked.decryptInPlace(data, 16, 48);
      chunked.decryptInPlace(data, 48, 64);
      expect(hex(data), hex(plaintext));
    });

    test('rejects partial blocks and bad IVs', () {
      final key = unhex('2b7e151628aed2a6abf7158809cf4f3c');
      expect(
        () => AesCbcDecryptor(Aes(key), iv).decryptInPlace(Uint8List(15)),
        throwsArgumentError,
      );
      expect(
        () => AesCbcDecryptor(Aes(key), Uint8List(8)),
        throwsArgumentError,
      );
    });
  });

  group('AES-CTR, WinZip little-endian variant', () {
    test('first counter block is 1 (little-endian), no nonce', () {
      // The keystream's first block must be AES-ECB(counter=01 00 .. 00):
      // pinned by encrypting that block directly.
      final key = unhex('2b7e151628aed2a6abf7158809cf4f3c');
      final counter1 = Uint8List(16)..[0] = 1;
      final expected = Uint8List(16);
      Aes(key).encryptBlock(counter1, 0, expected, 0);

      final zeros = Uint8List(16);
      AesCtrLeStream(Aes(key)).processInPlace(zeros);
      expect(hex(zeros), hex(expected));
    });

    test('byte-granular chunking equals whole-buffer processing', () {
      final key = unhex(
        '603deb1015ca71be2b73aef0857d7781'
        '1f352c073b6108d72d9810a30914dff4',
      );
      final data = Uint8List.fromList(
        List.generate(1000, (i) => (i * 37) & 0xFF),
      );
      final whole = Uint8List.fromList(data);
      AesCtrLeStream(Aes(key)).processInPlace(whole);

      final chunked = Uint8List.fromList(data);
      final stream = AesCtrLeStream(Aes(key));
      var i = 0;
      for (final step in const [1, 15, 16, 17, 100, 851]) {
        stream.processInPlace(chunked, i, i + step);
        i += step;
      }
      expect(i, data.length);
      expect(hex(chunked), hex(whole));
    });

    test('round-trips (XOR keystream is its own inverse)', () {
      final key = unhex('000102030405060708090a0b0c0d0e0f');
      final data = Uint8List.fromList(List.generate(333, (i) => i & 0xFF));
      final original = Uint8List.fromList(data);
      AesCtrLeStream(Aes(key)).processInPlace(data);
      expect(data, isNot(equals(original)));
      AesCtrLeStream(Aes(key)).processInPlace(data);
      expect(data, original);
    });

    test('counter carries into the second byte after 256 blocks', () {
      final key = unhex('000102030405060708090a0b0c0d0e0f');
      // Blocks 1..256 use counters 0x01..0x100: after 255*16 bytes the
      // 256th block's counter must be 00 01 00...; pin it directly.
      final expected = Uint8List(16);
      final counter256 = Uint8List(16)..[1] = 1;
      Aes(key).encryptBlock(counter256, 0, expected, 0);

      final data = Uint8List(256 * 16);
      AesCtrLeStream(Aes(key)).processInPlace(data);
      expect(hex(Uint8List.sublistView(data, 255 * 16)), hex(expected));
    });
  });
}

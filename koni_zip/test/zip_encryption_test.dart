@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

/// ZIP decryption (P3-2): traditional PKWARE ("zipcrypto") and WinZip AES
/// entries, authored by zip(1)/7zz; see fixtures_manifest.json.
Uint8List fixtureBytes(String name) =>
    File('test/fixtures/zip/$name').readAsBytesSync();

Future<ArchiveReader> open(String name, {String? password}) =>
    const ZipFormat().openReader(
      MemoryByteSource(fixtureBytes(name)),
      ArchiveReadOptions(password: password),
    );

Future<Uint8List> readAll(ArchiveReader reader, ArchiveEntry entry) async {
  final chunks = await reader.openRead(entry).toList();
  final out = <int>[];
  for (final c in chunks) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

ArchiveEntry byName(ArchiveReader reader, String name) =>
    reader.entries.firstWhere((e) => e.path == name);

final helloBytes = utf8.encode('hello, zip!\n');
final dataBytes = List.generate(2600, (i) => (i * 7 + 3) & 0xFF);

void main() {
  group('traditional PKWARE (zipcrypto)', () {
    test('stored entry decrypts with the password', () async {
      final reader = await open('encrypted.zip', password: 'secret');
      final entry = reader.entries.single;
      expect(entry.isEncrypted, isTrue);
      expect(await readAll(reader, entry), helloBytes);
    });

    test('deflated multi-file archive decrypts and inflates', () async {
      final reader = await open(
        'encrypted_zipcrypto_deflate.zip',
        password: 'secret',
      );
      expect(await readAll(reader, byName(reader, 'hello.txt')), helloBytes);
      expect(
        await readAll(reader, byName(reader, 'nested/deep/data.bin')),
        dataBytes,
      );
    });

    test('wrong password is rejected by the check byte', () async {
      final reader = await open('encrypted.zip', password: 'wrong');
      expect(
        () => reader.openRead(reader.entries.single).toList(),
        throwsA(isA<InvalidPasswordException>()),
      );
    });
  });

  group('WinZip AES', () {
    test(
      'AES-256 deflated archive decrypts (AE-2, HMAC-authenticated)',
      () async {
        final reader = await open('encrypted_aes256.zip', password: 'secret');
        expect(await readAll(reader, byName(reader, 'hello.txt')), helloBytes);
        expect(
          await readAll(reader, byName(reader, 'nested/deep/data.bin')),
          dataBytes,
        );
      },
    );

    test('AES-128 decrypts', () async {
      final reader = await open('encrypted_aes128.zip', password: 'secret');
      expect(await readAll(reader, reader.entries.single), helloBytes);
    });

    test('AES-256 stored (Copy) decrypts', () async {
      final reader = await open(
        'encrypted_aes256_stored.zip',
        password: 'secret',
      );
      final entry = reader.entries.single;
      expect(entry.compression, ArchiveCompression.stored);
      expect(await readAll(reader, entry), helloBytes);
    });

    test('the inner method is reported, not method 99', () async {
      final reader = await open('encrypted_aes256.zip', password: 'secret');
      // 7zz stores the 12-byte hello.txt but deflates the 2600-byte data.
      expect(
        byName(reader, 'nested/deep/data.bin').compression,
        ArchiveCompression.deflate,
      );
      expect(byName(reader, 'hello.txt').isEncrypted, isTrue);
    });

    test('wrong password is rejected by the PBKDF2 verifier', () async {
      final reader = await open('encrypted_aes128.zip', password: 'wrong');
      expect(
        () => reader.openRead(reader.entries.single).toList(),
        throwsA(isA<InvalidPasswordException>()),
      );
    });

    test('a corrupted MAC surfaces as a checksum mismatch', () async {
      // Flip a ciphertext byte: the password verifier still passes (it is
      // over the salt/key), but the HMAC over the ciphertext must not.
      final bytes = Uint8List.fromList(fixtureBytes('encrypted_aes128.zip'));
      // The ciphertext sits after the 30-byte local header + name + salt +
      // 2-byte verifier; byte 60 is safely inside it for this fixture.
      bytes[60] ^= 0xFF;
      final reader = await const ZipFormat().openReader(
        MemoryByteSource(bytes),
        const ArchiveReadOptions(password: 'secret'),
      );
      expect(
        () => reader.openRead(reader.entries.single).toList(),
        throwsA(isA<ChecksumMismatchException>()),
      );
    });

    test(
      'AE-1 archives verify the real CRC (byte-patched from AE-2)',
      () async {
        // 7zz only writes AE-2; synthesize the AE-1 variant by declaring
        // vendor version 1 and restoring the true plaintext CRC. The
        // ciphertext and keys are identical between AE-1 and AE-2.
        final crc = Crc32.compute(Uint8List.fromList(helloBytes));
        final ae1 = _patchAe2ToAe1(fixtureBytes('encrypted_aes128.zip'), crc);
        final reader = await const ZipFormat().openReader(
          MemoryByteSource(ae1),
          const ArchiveReadOptions(password: 'secret'),
        );
        expect(await readAll(reader, reader.entries.single), helloBytes);

        // A wrong CRC in the AE-1 record must now be caught (AE-2 ignores it).
        final ae1Bad = _patchAe2ToAe1(
          fixtureBytes('encrypted_aes128.zip'),
          crc ^ 0x1,
        );
        final badReader = await const ZipFormat().openReader(
          MemoryByteSource(ae1Bad),
          const ArchiveReadOptions(password: 'secret'),
        );
        expect(
          () => badReader.openRead(badReader.entries.single).toList(),
          throwsA(isA<ChecksumMismatchException>()),
        );
      },
    );
  });

  group('password handling', () {
    test(
      'no password on an encrypted entry throws (listing still works)',
      () async {
        final reader = await open('encrypted_aes256.zip');
        expect(reader.entries, isNotEmpty);
        expect(
          () => reader.openRead(reader.entries.first),
          throwsA(isA<EncryptedArchiveException>()),
        );
      },
    );

    test('InvalidPasswordException is an EncryptedArchiveException', () {
      expect(InvalidPasswordException('x'), isA<EncryptedArchiveException>());
    });
  });
}

/// Rewrites a WinZip AE-2 archive as AE-1: flips every 0x9901 extra's
/// vendor-version word to 1 and writes [crc] into every local and central
/// header CRC-32 field. Assumes a single-entry archive with no ZIP64.
Uint8List _patchAe2ToAe1(Uint8List source, int crc) {
  final b = Uint8List.fromList(source);
  void writeCrc(int offset) {
    b[offset] = crc & 0xFF;
    b[offset + 1] = (crc >> 8) & 0xFF;
    b[offset + 2] = (crc >> 16) & 0xFF;
    b[offset + 3] = (crc >> 24) & 0xFF;
  }

  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] == 0x50 && b[i + 1] == 0x4B) {
      if (b[i + 2] == 0x03 && b[i + 3] == 0x04) {
        writeCrc(i + 14);
      } else if (b[i + 2] == 0x01 && b[i + 3] == 0x02) {
        writeCrc(i + 16);
      }
    }
    // 0x9901 extra header (id=0x9901, size=7): set the version word to 1.
    if (b[i] == 0x01 && b[i + 1] == 0x99 && b[i + 2] == 0x07 && b[i + 3] == 0) {
      b[i + 4] = 1;
      b[i + 5] = 0;
    }
  }
  return b;
}

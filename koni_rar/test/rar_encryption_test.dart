@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

/// RAR5 file decryption (P3-4). Fixtures authored by `rar -psecret`; see
/// fixtures_manifest.json. AES-256-CBC with the iterated-HMAC-SHA256 KDF,
/// an 8-byte password-check value (reliable wrong-password signal), and a
/// hash-key-tweaked CRC verified on the default read path.
Uint8List fixtureBytes(String name) =>
    File('test/fixtures/rar/$name').readAsBytesSync();

Future<ArchiveReader> open(String name, {String? password}) =>
    const RarFormat().openReader(
      MemoryByteSource(fixtureBytes(name)),
      ArchiveReadOptions(password: password),
    );

Future<Uint8List> collect(ArchiveReader reader, ArchiveEntry entry) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(entry)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

ArchiveEntry file(ArchiveReader reader, String path) =>
    reader.entries.firstWhere((e) => e.path == path);

final helloBytes = utf8.encode('hello, rar!\n');
final unicodeBytes = utf8.encode('unicode page\n');
final dataBytes = List.generate(100000, (i) => ((i * 7) ^ (i >> 3)) & 0xFF);

void main() {
  group('file decryption', () {
    test('stored entry (rar -m0 -p)', () async {
      final reader = await open('encrypted.rar', password: 'secret');
      final entry = reader.entries.singleWhere((e) => e.isFile);
      expect(entry.isEncrypted, isTrue);
      expect(await collect(reader, entry), helloBytes);
    });

    test('compressed entries (rar -m3 -p), CRCs verified', () async {
      final reader = await open('encrypted_compressed.rar', password: 'secret');
      expect(await collect(reader, file(reader, 'hello.txt')), helloBytes);
      expect(
        await collect(reader, file(reader, 'nested/deep/data.bin')),
        dataBytes,
      );
      expect(
        await collect(reader, file(reader, '日本語/ページ001.txt')),
        unicodeBytes,
      );
    });

    test('solid entries (rar -m5 -s -p)', () async {
      final reader = await open('encrypted_solid.rar', password: 'secret');
      expect(await collect(reader, file(reader, 'hello.txt')), helloBytes);
      expect(
        await collect(reader, file(reader, 'nested/deep/data.bin')),
        dataBytes,
      );
    });
  });

  group('password handling', () {
    test('no password: throws at openRead, listing works', () async {
      final reader = await open('encrypted.rar');
      expect(reader.entries, isNotEmpty);
      expect(
        () => reader.openRead(reader.entries.singleWhere((e) => e.isFile)),
        throwsA(isA<EncryptedArchiveException>()),
      );
    });

    test('wrong password: rejected by the 8-byte check value', () async {
      final reader = await open('encrypted.rar', password: 'wrong');
      await expectLater(
        collect(reader, reader.entries.singleWhere((e) => e.isFile)),
        throwsA(isA<InvalidPasswordException>()),
      );
    });

    test(
      'encrypted headers (-hp) stay a typed error even with a password',
      () async {
        await expectLater(
          open('encrypted_headers.rar', password: 'secret'),
          throwsA(isA<EncryptedArchiveException>()),
        );
      },
    );
  });

  test('corrupted ciphertext fails the tweaked CRC', () async {
    // The stored CRC is hash-key-tweaked; corrupting a ciphertext byte
    // yields wrong plaintext whose tweaked CRC will not match.
    final bytes = Uint8List.fromList(fixtureBytes('encrypted.rar'));
    // The single 16-byte AES data block sits near the end, before the
    // end-of-archive marker; flip a byte well inside it.
    bytes[bytes.length - 12] ^= 0xFF;
    final reader = await const RarFormat().openReader(
      MemoryByteSource(bytes),
      const ArchiveReadOptions(password: 'secret'),
    );
    await expectLater(
      collect(reader, reader.entries.singleWhere((e) => e.isFile)),
      throwsA(isA<ChecksumMismatchException>()),
    );
  });
}

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:test/test.dart';

/// 7z AES-256 decryption (P3-3). Fixtures authored by 7zz with `-psecret`;
/// see fixtures_manifest.json. 7z carries no password verifier, so a wrong
/// password surfaces as corrupt data or a header CRC mismatch — never a
/// clean "bad password" (and never an untyped error).
Uint8List fixtureBytes(String name) =>
    File('test/fixtures/sevenz/$name').readAsBytesSync();

Future<ArchiveReader> open(String name, {String? password}) =>
    const SevenZFormat().openReader(
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

final helloBytes = utf8.encode('hello, 7z!\n');
final dataBytes = List.generate(100000, (i) => ((i * 7) ^ (i >> 3)) & 0xFF);

void main() {
  group('AES-256 body decryption', () {
    test('single file (AES → LZMA2)', () async {
      final reader = await open('encrypted.7z', password: 'secret');
      final entry = reader.entries.singleWhere((e) => e.isFile);
      expect(entry.isEncrypted, isFalse, reason: 'header is plaintext here');
      expect(await collect(reader, entry), helloBytes);
    });

    test('solid folder with multiple substreams', () async {
      final reader = await open('encrypted_solid.7z', password: 'secret');
      expect(await collect(reader, file(reader, 'hello.txt')), helloBytes);
      expect(
        await collect(reader, file(reader, 'nested/deep/data.bin')),
        dataBytes,
      );
    });

    test('AES over a Copy folder (the AES-only peel path)', () async {
      final reader = await open('encrypted_copy.7z', password: 'secret');
      expect(
        await collect(reader, reader.entries.singleWhere((e) => e.isFile)),
        helloBytes,
      );
    });
  });

  group('encrypted headers (password needed at open)', () {
    test('single file opens and decrypts', () async {
      final reader = await open('encrypted_header.7z', password: 'secret');
      expect(
        await collect(reader, reader.entries.singleWhere((e) => e.isFile)),
        helloBytes,
      );
    });

    test('solid archive opens and decrypts its content', () async {
      final reader = await open(
        'encrypted_header_solid.7z',
        password: 'secret',
      );
      expect(await collect(reader, file(reader, 'hello.txt')), helloBytes);
      expect(
        await collect(reader, file(reader, 'nested/deep/data.bin')),
        dataBytes,
      );
    });
  });

  group('missing / wrong password stays typed', () {
    test('no password: body throws at read, listing works', () async {
      final reader = await open('encrypted.7z');
      expect(reader.entries, isNotEmpty);
      expect(
        () => reader.openRead(reader.entries.singleWhere((e) => e.isFile)),
        throwsA(isA<EncryptedArchiveException>()),
      );
    });

    test('no password: encrypted header throws at open', () async {
      await expectLater(
        open('encrypted_header.7z'),
        throwsA(isA<EncryptedArchiveException>()),
      );
    });

    test('wrong password: body is corrupt, not an untyped error', () async {
      final reader = await open('encrypted.7z', password: 'wrong');
      await expectLater(
        collect(reader, reader.entries.singleWhere((e) => e.isFile)),
        throwsA(isA<ArchiveException>()),
      );
    });

    test('wrong password: encrypted header fails its CRC at open', () async {
      await expectLater(
        open('encrypted_header.7z', password: 'wrong'),
        throwsA(isA<ArchiveException>()),
      );
    });
  });
}

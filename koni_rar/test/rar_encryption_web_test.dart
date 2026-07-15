// Web-runnable RAR5 file decryption: small encrypted fixtures inlined as
// base64 (no dart:io) so the iterated-HMAC-SHA256 KDF, AES-256-CBC, and
// the hash-key-tweaked CRC run on dart2js and dart2wasm, not only the VM.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

// rar -psecret; hello.txt = "hello, rar!\n".
final encrypted = base64.decode(
  'UmFyIRoHAQAzkrXlCgEFBgAFAQGAgABkHKuZUQIDMZAABowApIMCpV0NXhaRC1WAAAEJaGVsbG8u'
  'dHh0MAEAAw/pN91JjdKIuxexmYE9/ZPDJxYc4JZw3SkyF3zAgORvhdwHKUgVHLFR2TTQNQlpCXot'
  'RHBD1DToMXbUYs0dd1ZRAwUEAA==',
);

// rar -m3 -psecret over hello.txt, empty.txt, nested/deep/data.bin, 日本語.
final encryptedCompressed = base64.decode(
  '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',
);

final helloBytes = utf8.encode('hello, rar!\n');
final dataBytes = List.generate(100000, (i) => ((i * 7) ^ (i >> 3)) & 0xFF);

Future<Uint8List> _read(Uint8List archive, String path, String pw) async {
  final reader = await const RarFormat().openReader(
    MemoryByteSource(archive),
    ArchiveReadOptions(password: pw),
  );
  final entry = reader.entries.firstWhere((e) => e.path == path);
  final builder = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(entry)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  test('stored decryption is correct on this platform', () async {
    expect(await _read(encrypted, 'hello.txt', 'secret'), helloBytes);
  });

  test('compressed decryption + tweaked CRC verify on this platform', () async {
    expect(await _read(encryptedCompressed, 'hello.txt', 'secret'), helloBytes);
    expect(
      await _read(encryptedCompressed, 'nested/deep/data.bin', 'secret'),
      dataBytes,
    );
  });

  test('wrong password is rejected on this platform', () async {
    await expectLater(
      _read(encrypted, 'hello.txt', 'wrong'),
      throwsA(isA<InvalidPasswordException>()),
    );
  });
}

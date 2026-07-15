// Web-runnable 7z AES decryption: two small encrypted fixtures inlined as
// base64 (no dart:io) so the iterated-SHA-256 KDF and the AES-CBC folder
// peel run on dart2js and dart2wasm, not only the VM.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:test/test.dart';

// 7zz -psecret, hello.txt "hello, 7z!\n". encrypted = AES→LZMA2,
// encryptedCopy = AES over a Copy folder.
final encrypted = base64.decode(
  'N3q8ryccAAQHx0+mEAAAAAAAAABqAAAAAAAAABc6tdXQa2HUijOkaePrB0xLSvVqAQQGAAEJ'
  'EAAHCwEAAiQG8QcBElMPV3SRDRmI7MMmeB/PiHf5CSEhAQABAAwPCwAICgHHycwfAAAFARkB'
  'ABEVAGgAZQBsAGwAbwAuAHQAeAB0AAAAFAoBAIAAxEoZwdUBFQYBACCApIEAAA==',
);
final encryptedCopy = base64.decode(
  'N3q8ryccAAQRlkF3EAAAAAAAAABqAAAAAAAAADIy3Rh9pKKqegcbnmU1+eBVhOUHAQQGAAEJ'
  'EAAHCwEAAiQG8QcBElMPMRCzdv7+/q2So3bMG8fhAgEAAQAMCwsACAoBx8nMHwAABQEZAwAA'
  'ABEVAGgAZQBsAGwAbwAuAHQAeAB0AAAAFAoBAIAAxEoZwdUBFQYBACCApIEAAA==',
);

final helloBytes = utf8.encode('hello, 7z!\n');

Future<Uint8List> _read(Uint8List archive, String pw) async {
  final reader = await const SevenZFormat().openReader(
    MemoryByteSource(archive),
    ArchiveReadOptions(password: pw),
  );
  final entry = reader.entries.singleWhere((e) => e.isFile);
  final builder = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(entry)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  test('AES→LZMA2 decrypts on this platform', () async {
    expect(await _read(encrypted, 'secret'), helloBytes);
  });

  test('AES-over-Copy decrypts on this platform', () async {
    expect(await _read(encryptedCopy, 'secret'), helloBytes);
  });

  test('wrong password stays a typed error on this platform', () async {
    await expectLater(
      _read(encrypted, 'wrong'),
      throwsA(isA<ArchiveException>()),
    );
  });
}

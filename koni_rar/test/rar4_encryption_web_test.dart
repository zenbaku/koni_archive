// Web-runnable RAR4 file decryption: encrypted v4 fixtures (authored with
// rar 6.24) inlined as base64, so the RAR3 SHA-1 KDF — including its
// 4-byte-word key byte-swap — and AES-128-CBC run on dart2js and
// dart2wasm, not only the VM. The store fixture isolates the crypto; the
// compressed one additionally drives the method-29 decoder end to end.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

// rar -ma4 -m0 -psecret hello.txt ; hello.txt = "hello, rar!\n" (stored).
final encryptedRar4Store = base64.decode(
  'UmFyIRoHAM+QcwAADQAAAAAAAAAxInQklDYAEAAAAAwAAAADbvdJOAh971wdMAkApIEAAGhlbGxv'
  'LnR4dACBbdHdbxT+APAo9ijeZDmLkxsc4Qrd7rKt7uRPxD17AEAHAA==',
);

// rar -ma4 -m3 -psecret over hello.txt, lorem.txt, nested/notes.txt.
final encryptedRar4 = base64.decode(
  'UmFyIRoHAM+QcwAADQAAAAAAAADrsnQklDYAIAAAAAwAAAADbvdJOLV871wdMwkApIEAAGhlbGxv'
  'LnR4dINQ7mwLiv6UALCRLZXPD6QcQ+oYvgq4IxgcREYWyme0Jeurx2gdJhh+j5+PdCTfdCSUNgB'
  'QAAAAjAoAAAM+8JH5tXzvXB0zCQCkgQAAbG9yZW0udHh0g1DubAuK/pQA8DcpFjI9miKiO+NuQy'
  'ImY5cLeEP38b6t/4foIt348oZs4NzS7CV1eYMafciZb73KfIYd9oiqGk27+k3iUs0GnU/fF1rH7'
  'Y3Usqh/fi57ur1p1vlC8wh0JJQ9AEAAAAAoBQAAA3vYIDS1fO9cHTMQAKSBAABuZXN0ZWRcbm90'
  'ZXMudHh0g1DubAuK/pQA8IHdMIHZiutleOaudeO7jeVadlQaTLh0CVL6MXBNQJESUXF9Yr5Xun7'
  'qotc9WDhgF4XPAhMiXBJQSeTUVDMFaZpX3MJFinTgkCsAAAAAAAAAAAADAAAAALV871wdMAYA7U'
  'EAAG5lc3RlZADwitkwxD17AEAHAA==',
);

final helloBytes = utf8.encode('hello, rar!\n');
final loremBytes = utf8.encode(
  'The quick brown fox jumps over the lazy dog. ' * 60,
);

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
  test('RAR4 KDF + AES-128 decrypt is correct on this platform', () async {
    expect(await _read(encryptedRar4Store, 'hello.txt', 'secret'), helloBytes);
  });

  test(
    'RAR4 decrypt + method-29 decode + CRC verify on this platform',
    () async {
      expect(await _read(encryptedRar4, 'hello.txt', 'secret'), helloBytes);
      expect(await _read(encryptedRar4, 'lorem.txt', 'secret'), loremBytes);
    },
  );

  test(
    'RAR4 wrong password fails the plaintext CRC on this platform',
    () async {
      // Store method: the wrong key yields wrong plaintext that fails the
      // (untweaked) CRC-32 check directly.
      await expectLater(
        _read(encryptedRar4Store, 'hello.txt', 'wrong'),
        throwsA(isA<ChecksumMismatchException>()),
      );
    },
  );
}

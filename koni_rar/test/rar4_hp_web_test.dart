// Web-runnable RAR4 encrypted-header (`-hp`) reading: the compressed v4 `-hp`
// fixture (authored with rar 6.24) inlined as base64, so the per-block header
// decrypt — the RAR3 SHA-1 KDF, AES-128-CBC, and the 16-bit header-CRC
// wrong-password check — runs on dart2js and dart2wasm (32-bit int traps), not
// only the VM. Decoding also drives the method-29 decoder end to end.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

// rar 6.24, `-ma4 -m3 -hpsecret` over hello.txt, lorem.txt, nested/notes.txt.
// With `-hp` the block headers are encrypted too, so even listing needs the
// password.
final hpRar4 = base64.decode(
  'UmFyIRoHAM6Zc4AADQAAAAAAAAB7RG5JXJYG2KSxjL/NzzXbiEKXRSL08aaXugML2vgkbnEZgy+y'
  'LUXL9f97H1HvxVv6Uqcyha0yDBce116fqmUiyHBkhpKciUuJAv/IyPDKStz1YyEF8i0Id7hSmXCY'
  'hak47C+Q3eeG1HtEbklclgbYKeVOgxJyAfAPmKxLiDGlu09aO1KBfy4YaUUo32T1KiFFb14oMjF+'
  'FM2D5zxkdaU4AiLdPSKUqgBQcPkwbpd7sNyG27s0lRKkrWnPJ2vBj88xv/1HFoWFVZ+Mkt+gZ23v'
  'J/5fD8T+2VZ70WiVo20NPIZJLAS9RxnJL0jhAwXaCDOsyUeHIUotJNYKBZQR+Anhe0RuSVyWBtg8'
  'SLh5ZyIGNeEbwJrwt8R75/232vWxJCmWNGiXSDVZYojAFKjSa10qM82WE1lLvklRNv1JSLdBxeZe'
  'FKIfLO4CpWzbGmEG96dIWgdJOQ6C6HQdWRSiCyYRzk1pR2flfw8cEZ1OZ14Bq/P6cnyEDdecg4WC'
  '1rOmF7t+o8q4bv137ntEbklclgbYe/3+vYbbVTdwv+vyQkJR9Q==',
);

final helloBytes = utf8.encode('hello, rar!\n');
final loremBytes = utf8.encode(
  'The quick brown fox jumps over the lazy dog. ' * 60,
);
final notesBytes = utf8.encode('koni archive phase 3 encryption. ' * 40);

Future<ArchiveReader> _open(Uint8List archive, String? pw) => const RarFormat()
    .openReader(MemoryByteSource(archive), ArchiveReadOptions(password: pw));

Future<Uint8List> _read(ArchiveReader reader, String path) async {
  final entry = reader.entries.firstWhere((e) => e.path == path);
  final builder = BytesBuilder(copy: false);
  await for (final chunk in reader.openRead(entry)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  test('RAR4 -hp header decrypt + method-29 + CRC on this platform', () async {
    final reader = await _open(hpRar4, 'secret');
    expect(
      reader.entries.map((e) => e.path),
      containsAll(<String>['hello.txt', 'lorem.txt', 'nested/notes.txt']),
    );
    expect(await _read(reader, 'hello.txt'), helloBytes);
    expect(await _read(reader, 'lorem.txt'), loremBytes);
    expect(await _read(reader, 'nested/notes.txt'), notesBytes);
  });

  test('RAR4 -hp wrong password fails the header CRC on this platform', () {
    // The 16-bit header CRC over the AES-decrypted block is the wrong-password
    // signal; this exercises the CRC-32 and AES paths under web int semantics.
    expect(_open(hpRar4, 'wrong'), throwsA(isA<InvalidPasswordException>()));
  });

  test('RAR4 -hp with no password is locked on this platform', () {
    expect(_open(hpRar4, null), throwsA(isA<EncryptedArchiveException>()));
  });
}

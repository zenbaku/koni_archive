// Web-runnable RAR5 encrypted-header (`-hp`) decoding. Both fixtures are real
// `rar 7.23 -hpsecret` archives (store and compressed) over hello.txt,
// lorem.txt, and nested/notes.txt, inlined as base64 (no dart:io) so the
// per-block header decryption runs on dart2js and dart2wasm, not just the VM.
// Reading verifies CRC-32 by default, so a decode that completes is byte-exact
// to what the compressor saw.
//
// Regenerate: `rar a -hpsecret -m0 hp_store.rar <files>` and `-m3` for
// hp_comp.rar (RAR5; authorable by rar 7.x). See `doc/notes.md`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:test/test.dart';

// store, -hpsecret (606 B)
final _hpStore = base64.decode(
  'UmFyIRoHAQABoG2gIQQAAAEPQ+Y3H94N1esE9QAHoSnGi5lPbMGkTZD+e2lB8mFtr/eXiZ7qNL2Z'
  '6END7Wjdv75N1W14NN/LDFZ4jhLG0N8hsna8f4d2x62Oa46K9jmvYV6nTS35znUAwCZ0uQakIlKZ'
  'qSF5PshlkZM/30/9hXP+RIDYIHHpLv6eANAkInTJsIUc3qjoUvUQT4BDhCvXb09yoJR4LyBvkjmd'
  'YgQlW49NskR1QEwL9gDNha4VhyZ0dZ3lntVHJUFHTdyrQncbFVg3Y5BvosydxwM9h3zL6A7LjWfM'
  'eqAw8bct3Ga5ltC9e7X02+0OoIXR7nN1p9XakrMrseBCWKwTDqHHoNLruv8b+jch8eeuUBzLz5fp'
  'BDMQItieJT9Kk5x1Hq4tk8lhGVNCldUup3lRK0BEULNdG0dv8L8JzDhdR6pDH+UxTOX56veahdBF'
  'tnOCKK1iKxlbwk1cFsNkRUbjBDg/dw48hlvfAhyICxejgjNwUSShMf5oYF86gWVsXHEtDXJRGLf1'
  'KK2Vz9kokE7QWjkVAaMZ1hMinzPqBeaZt24TtEIHUkSOvR7C28U4dyD3dGHY2xek2Wx6jr20dIhB'
  'Dw6pKLzeGbsP1DxxdHqbeaP/2S/CzlGnpEMCUrYC9qHkjAIfaTMwfLXf3T9/04AMnCVuMCioY0u9'
  'UnWqdEEkHGSPgY1151W4K/yJUAGEOOJC3Y4b/iUVZawx99LAWILEDf39s4J6qlROU7cLRT+V05LL'
  '7S2hR3EkwRNEk7yJRQXuj6v2PbhiDvEC4W+Ao3p0gcRk2gc+',
);

// compressed (-m3), -hpsecret (622 B)
final _hpComp = base64.decode(
  'UmFyIRoHAQBIUTZcIQQAAAEP3WBxYy48G2UoEH2asTHUCL12M1AZY3a8nIqCTEQYHlrjQt+l8EfK'
  'NL1tuR6CwNUWC86USwZhtSIWnppF7EvN7EM8AjFnXbrjMHyEOqR5kGJDXmzdX2zivQW8vJYQNX4/'
  'bls5Yy8DBclrVGdK+VK93m3jscDYiB8Qsf+cSw6e0TWYJ6CqrpKx5rzojtuyuZI0nPUw/Ok0txoa'
  'vSu7e+PGwwVD0/65BBrRB4lKbMF6lPHClk8CCZiqPuxmYJ1lPN44FNHXcY9FctzYIdfhc3MSrhRD'
  'MexfrEOTLMlcnfCdb2Z9oNcXhPDG9iLHpgq4mUdN/M8O5eInJV/NsQEkE+zFu7ZgiD4PGLSR+JO/'
  'pmxrui5aeBYSwLSWkhj1f6+iAf4D/K5hwEc3ka3CZXyqIjGWxaH0q9ikEthokRllEL3zcdNdlJF/'
  'Da8LqzA6mVyXUzZm1FwrYPjXsZnBrx701HdmaggLZ3rI+NfH4XPA8zoA3NtwmqCLuVqIMYW6/uxJ'
  'pD4PHAyOf8l5C1yiuLWRotkhM9zXs7edIiYcTsYrCLVepaDfSUZgLlUo2OLhLlnGYuIJ9jQmJ7et'
  'Dhg0F2YaGHwMnaXFcroje4uS6lcvkTsgaW80y1C2WJSfhcz+be5wCmnya6XKfCxl+Z97DEVxs/v2'
  'g1AitysS4flTBL/vAaENkPjSLjxCp4+MudTGx6ilGsoiWu8JVgUHzRWGW8y9+Wj/D12nXSNIg1tX'
  '4dod6B5cMEkFfx8+LomJE6DQVx2ovHEuX9n/mcVyuVeE1fPq76A6LGLAlLf9bUFBZCmG4w==',
);

Future<ArchiveReader> _open(Uint8List bytes, String? password) =>
    const RarFormat().openReader(
      MemoryByteSource(bytes),
      ArchiveReadOptions(password: password),
    );

Future<Map<String, String>> _readAll(Uint8List bytes, String password) async {
  final reader = await _open(bytes, password);
  final out = <String, String>{};
  for (final e in reader.entries.where((e) => !e.isDirectory)) {
    final chunks = await reader.openRead(e).toList();
    out[e.path] = utf8.decode(chunks.expand<int>((c) => c).toList());
  }
  await reader.close();
  return out;
}

const _expected = {
  'hello.txt': 'hello, encrypted headers!\n',
  'lorem.txt':
      'lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do '
      'eiusmod tempor\n',
  'nested/notes.txt': 'deep nested data\n',
};

void main() {
  for (final f in [
    (name: 'store', bytes: _hpStore),
    (name: 'compressed', bytes: _hpComp),
  ]) {
    group('RAR5 -hp ${f.name}', () {
      test('decrypts headers and data with the password', () async {
        expect(await _readAll(f.bytes, 'secret'), _expected);
      });

      test('wrong password is rejected at open', () async {
        await expectLater(
          _open(f.bytes, 'wrong'),
          throwsA(isA<InvalidPasswordException>()),
        );
      });

      test('missing password is a typed error at open', () async {
        await expectLater(
          _open(f.bytes, null),
          throwsA(isA<EncryptedArchiveException>()),
        );
      });
    });
  }
}

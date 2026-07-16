// Web-runnable subset of the ZIP decryption tests: small encrypted
// fixtures are embedded as base64 (no dart:io), so the traditional-cipher
// 32-bit key schedule and the AES pipeline are exercised on dart2js and
// dart2wasm, not only the VM. The primitives have their own web coverage
// in koni_codecs; this pins the ZIP glue end to end.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

Uint8List _b64(String s) => base64.decode(s.replaceAll('\n', ''));

// Authored by zip(1) (zipcrypto) and 7zz (WinZip AES); see
// test/fixtures/zip and its manifest. Kept small so the base64 is cheap.
final zipcryptoDeflate = _b64(
  'UEsDBAoACwAAAIMYIlAuQAnOGAAAAAwAAAAJAAAAaGVsbG8udHh0xnLhbBXAF5jodAOCYHkjz62w'
  'PerbuVCCUEsHCC5ACc4YAAAADAAAAFBLAwQUAAsACACDGCJQYHTO5jUBAAAoCgAAFAAAAG5lc3Rl'
  'ZC9kZWVwL2RhdGEuYmluLD/cxxtS2eLZU13jwRWr7wht85a7HXXF0AnvRyGrCdCxIn2YdCNO3Ir0'
  'vEzQoVpMfwiepxUisLopgKnR6VLRT9obH7APSq2Z6WspC0NTkthxGcQTeiQp5Q5sVHHo7JKparBc'
  'lg2AeBTOrB/85e0B5kNMDNdJo5Tx6ZeyMiBILRMshKXx15TR9zakGMSH2c9Vd4ekoczrpgTwvu4z'
  'Ebqlvkv2WNIHx0pIdq3JRcxOasBPw61VyFAfPvSYiRu9zkbh0Tn/ApkYZcjCXnazUL8tFXOGC1UR'
  'wNfwDsC+HKQakqqHkm9cpSJ40SuVOMWJNheha8fgvIStS7IrusXO+EdVImXcyjHeXwusIyS8S6tk'
  '5v38XyMF6SrnA8LFZzZGVVlWoc41n3b7UyxAuzAjBxkBkWkRCqjzUEsHCGB0zuY1AQAAKAoAAFBL'
  'AQIeAwoACwAAAIMYIlAuQAnOGAAAAAwAAAAJAAAAAAAAAAEAAACkgQAAAABoZWxsby50eHRQSwECH'
  'gMUAAsACACDGCJQYHTO5jUBAAAoCgAAFAAAAAAAAAAAAAAApIFPAAAAbmVzdGVkL2RlZXAvZGF0YS'
  '5iaW5QSwUGAAAAAAIAAgB5AAAAxgEAAAAA',
);

final aes256Deflate = _b64(
  'UEsDBDMAAQBjAIMYIlAAAAAAKAAAAAwAAAAJAAsAaGVsbG8udHh0AZkHAAIAQUUDAADXl23Kzm5h'
  'nmIp2q5Mvn6Fr/DTHCyaIWZZ/yETOHXaDJpafsaGbf1CUEsDBDMAAQBjAIMYIlAAAAAAUAEAACgK'
  'AAAUAAsAbmVzdGVkL2RlZXAvZGF0YS5iaW4BmQcAAgBBRQMIAK1WBcVTJy0uxSHks+rad+gYvgn2'
  '2DEy/CPZbao88tBKRlq0Si8bAW/DCRozRFRWn1D2/AIz2ibDnjb1Vy3tQHK1jY2O/tQopZM6anjC'
  'YbjANPXMRZsl5bhoueqHZI01IfsQIQR2hN0chQ3BK2akaEnxNAmFFaY68XYdtlO8faLZpqWNEo2e'
  '7455v761GZRNSG2HszzFRgWPHnxAsOMk0Shhw7f4efDB2wvpgSYyL1NL8ZzpUoUR9vySbZfAK3/L'
  'CyvNzy42L2hUrJx/+mc+0yKX822OEDABDKTyaEnNv6KyGTGHD9vBaCY4bvmE9ys0GZmTZPqLyb1k'
  'J6iC2pt5gvj5xdhoAYkIFym+Up1Jdq6pVYnr/IBo6PZt96Bf05P8V76QFAAEigiEG/yraKlZ0ex/'
  'tpgaaUS3yzboFnAINDMlG+YdliphznTd8JKgyVtGaFBLAQI/AzMAAQBjAIMYIlAAAAAAKAAAAAwA'
  'AAAJAC8AAAAAAAAAIICkgQAAAABoZWxsby50eHQKACAAAAAAAAEAGACAAMRKGcHVAQAAAAAAAAAA'
  'AAAAAAAAAAABmQcAAgBBRQMAAFBLAQI/AzMAAQBjAIMYIlAAAAAAUAEAACgKAAAUAC8AAAAAAAAA'
  'IICkgVoAAABuZXN0ZWQvZGVlcC9kYXRhLmJpbgoAIAAAAAAAAQAYAIAAxEoZwdUBAAAAAAAAAAAA'
  'AAAAAAAAAAGZBwACAEFFAwgAUEsFBgAAAAACAAIA1wAAAOcBAAAAAA==',
);

final helloBytes = utf8.encode('hello, zip!\n');
final dataBytes = List.generate(2600, (i) => (i * 7 + 3) & 0xFF);

Future<Uint8List> _read(Uint8List archive, String name, String pw) async {
  final reader = await const ZipFormat().openReader(
    MemoryByteSource(archive),
    ArchiveReadOptions(password: pw),
  );
  final entry = reader.entries.firstWhere((e) => e.path == name);
  final chunks = await reader.openRead(entry).toList();
  final out = <int>[];
  for (final c in chunks) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

void main() {
  test('zipcrypto decrypt+inflate is correct on this platform', () async {
    expect(await _read(zipcryptoDeflate, 'hello.txt', 'secret'), helloBytes);
    expect(
      await _read(zipcryptoDeflate, 'nested/deep/data.bin', 'secret'),
      dataBytes,
    );
  });

  test('WinZip AES-256 decrypt+inflate is correct on this platform', () async {
    expect(await _read(aes256Deflate, 'hello.txt', 'secret'), helloBytes);
    expect(
      await _read(aes256Deflate, 'nested/deep/data.bin', 'secret'),
      dataBytes,
    );
  });

  test('wrong password is rejected on this platform', () async {
    await expectLater(
      _read(aes256Deflate, 'hello.txt', 'wrong'),
      throwsA(isA<InvalidPasswordException>()),
    );
    await expectLater(
      _read(zipcryptoDeflate, 'hello.txt', 'wrong'),
      throwsA(isA<InvalidPasswordException>()),
    );
  });
}

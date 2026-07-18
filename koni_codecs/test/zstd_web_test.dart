// Web-runnable zstd decode: small fixtures inlined as base64 (no dart:io) so
// the FSE state machine, the canonical-Huffman rank fill, and both bit readers
// run on dart2js and dart2wasm, not only the VM. The content checksum is not
// verified on the web (XXH64 needs 64-bit multiply); decode correctness does
// not depend on it. Run:
//   dart test test/zstd_web_test.dart -p chrome
//   dart test test/zstd_web_test.dart -p chrome -c dart2wasm
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

const _empty = 'KLUv/SQAAQAAmenYUQ==';
const _tiny = 'KLUv/SQCEQAAaGn6OCbq';
const _rle = 'KLUv/WQAD0UAAAhBAQD894EQw1grbQ==';
const _text =
    'KLUv/WQIBrUBANQCdGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gAQDFFv6qDDSHfX8=';
const _dprose =
    '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';

Uint8List _decode(String b64) =>
    const ZstdDecoder().convert(base64.decode(b64));

Uint8List get _rleExpected => Uint8List(4096)..fillRange(0, 4096, 0x41);
Uint8List get _textExpected => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 40).codeUnits,
);
Uint8List get _dproseExpected {
  const words = [
    'the', 'quick', 'brown', 'fox', 'jumps', 'over', 'a', 'lazy', 'dog', //
    'while', 'zephyrs', 'blow', 'vexingly', 'across', 'quiet', 'meadows',
  ];
  final parts = <String>[];
  var x = 12345;
  for (var i = 0; i < 3000; i++) {
    x = (x * 1103 + 12345) % 100003; // stays < 2^27, dart2js-safe
    parts.add(words[x % words.length]);
  }
  return Uint8List.fromList(parts.join(' ').codeUnits);
}

void main() {
  test('raw / RLE / predefined-table blocks decode on this platform', () {
    expect(_decode(_empty), isEmpty);
    expect(_decode(_tiny), Uint8List.fromList('hi'.codeUnits));
    expect(_decode(_rle), _rleExpected);
    expect(_decode(_text), _textExpected);
  });

  test('Huffman literals + FSE-compressed tables decode on this platform', () {
    expect(_decode(_dprose), _dproseExpected);
  });
}

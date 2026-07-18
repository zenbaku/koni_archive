// Web-runnable bzip2 decode: small fixtures inlined as base64 (no dart:io) so
// the CRC-32/BZIP2 left-shift, the MSB-first bit reader, and the Huffman/BWT
// path run on dart2js and dart2wasm, not only the VM. Run:
//   dart test test/bzip2_web_test.dart -p chrome
//   dart test test/bzip2_web_test.dart -p chrome -c dart2wasm
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

const _empty = 'QlpoORdyRThQkAAAAAA=';
const _tinyB64 =
    'QlpoOTFBWSZTWaRTSlAAAAPZgAAQQAAQABZk0JAgACKYE2hqEAABw9xY8dyOE4D8XckU4UJCkU0pQA==';
const _textB64 =
    'QlpoOTFBWSZTWamqVxMAlG+RgEABP///8DABO1VQo0NAAAAJqqgAGgGhkClUmgNA0ABwCVX0JVZhKr6EqsgoMapBoqkGNUg31SDAJVdQlVkEqugSqwCB3qpB+qkGmqQe6pB9BKr4EqsQlV2CVWAUGmqQZVSD3VINVUg6BKryEqvYSqxCVWYQPlUg/VSDVVSDKqQZVSDCqELOqQZ1SD+LuSKcKEhU1SuJgA==';
const _concatB64 =
    'QlpoOTFBWSZTWaRTSlAAAAPZgAAQQAAQABZk0JAgACKYE2hqEAABw9xY8dyOE4D8XckU4UJCkU0pQEJaaDkxQVkmU1mpqlcTAJRvkYBAAT////AwATtVUKNDQAAACaqoABoBoZApVJoDQNAAcAlV9CVWYSq+hKrIKDGqQaKpBjVIN9UgwCVXUJVZBKroEqsAgd6qQfqpBpqkHuqQfQSq+BKrEJVdglVgFBpqkGVUg91SDVVIOgSq8hKr2EqsQlVmED5VIP1Ug1VUgyqkGVUgwqhCzqkGdUg/i7kinChIVNUriYA=';

Uint8List _decode(String b64) =>
    const Bzip2Decoder().convert(base64.decode(b64));

Uint8List get _tiny => Uint8List.fromList('hello bzip2 world\n'.codeUnits);
Uint8List get _text => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 2000).codeUnits,
);

void main() {
  test('empty / tiny / compressible decode on this platform', () {
    expect(_decode(_empty), isEmpty);
    expect(_decode(_tinyB64), _tiny);
    expect(_decode(_textB64), _text);
  });

  test('concatenated streams decode on this platform', () {
    expect(_decode(_concatB64), Uint8List.fromList([..._tiny, ..._text]));
  });
}

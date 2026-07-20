// Web-runnable bzip2 encode: exercises the encoder's CRC-32/BZIP2 left-shift
// table, the MSB-first bit writer, the BWT, and the length-limited Huffman on
// dart2js and dart2wasm, not only the VM. The encoder is deterministic (the
// rotation sort breaks ties by index), so its output is asserted byte-identical
// to the VM via length + fingerprint reference values, and round-trips through
// our own web-verified decoder. Run:
//   dart test test/bzip2_encoder_web_test.dart -p chrome
//   dart test test/bzip2_encoder_web_test.dart -p chrome -c dart2wasm
library;

import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// A dart2js-safe rolling fingerprint of the encoded bytes: `h * 31` stays well
/// under 2^53 for `h < 2^30`, so this is exact on every compile target — an
/// FNV-style multiply by a large prime is not (it overflows doubles on
/// dart2js). Used to assert byte-identical output against VM-computed values.
int _fp(Uint8List b) {
  var h = 0;
  for (final x in b) {
    h = (h * 31 + x) & 0x3FFFFFFF;
  }
  return h;
}

Uint8List _encode(Uint8List data, {int blockSize100k = 9}) =>
    Bzip2Encoder(blockSize100k: blockSize100k).encode(data);

Uint8List _roundTrip(Uint8List data, {int blockSize100k = 9}) =>
    const Bzip2Decoder().convert(_encode(data, blockSize100k: blockSize100k));

Uint8List get _tiny => Uint8List.fromList('hello bzip2 world\n'.codeUnits);
Uint8List get _text => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 400).codeUnits,
);
Uint8List get _ramp =>
    Uint8List.fromList(List.generate(9000, (i) => (i * 5) & 0xFF));

void main() {
  test('output is byte-identical to the VM reference on this platform', () {
    // (length, fingerprint) pairs computed on the VM; equal on dart2js and
    // dart2wasm iff the encoded bytes are identical.
    final tiny = _encode(_tiny);
    expect([tiny.length, _fp(tiny)], [60, 1064147010]);

    final ramp = _encode(
      Uint8List.fromList(List.generate(600, (i) => (i * 5) & 0xFF)),
    );
    expect([ramp.length, _fp(ramp)], [489, 216144596]);

    final big = _encode(
      Uint8List.fromList(
        List.generate(260000, (i) => (i * 7 + (i >> 3)) & 0xFF),
      ),
      blockSize100k: 1,
    );
    expect([big.length, _fp(big)], [3425, 496672874]);
  });

  test('encode + decode round-trips on this platform', () {
    expect(_roundTrip(Uint8List(0)), isEmpty);
    expect(_roundTrip(_tiny), _tiny);
    expect(_roundTrip(_text), _text);
    expect(_roundTrip(_ramp), _ramp);
    expect(
      _roundTrip(Uint8List.fromList(List.filled(4000, 0x5A))),
      Uint8List.fromList(List.filled(4000, 0x5A)),
    );
  });

  test('crosses the RLE1 buffer boundary on this platform', () {
    for (var n = 240; n <= 320; n++) {
      final data = Uint8List.fromList(
        List.generate(n, (i) => 'abcdef'.codeUnitAt(i % 6)),
      );
      expect(_roundTrip(data), data, reason: 'n=$n');
    }
  });

  test('block CRC / combined CRC match across multiple blocks', () {
    final data = Uint8List.fromList(
      List.generate(260000, (i) => (i * 7 + (i >> 3)) & 0xFF),
    );
    expect(_roundTrip(data, blockSize100k: 1), data);
  });
}

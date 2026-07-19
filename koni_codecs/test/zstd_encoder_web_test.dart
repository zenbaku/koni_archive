// Web-runnable zstd encode: exercises the FSE (tANS) encoder, the forward bit
// writer, the hash-chain match finder, and the frame/block framing on dart2js
// and dart2wasm, not only the VM. The encoder is deterministic, so its output
// is asserted byte-identical to the VM via length + fingerprint reference
// values, and round-trips through our own web-verified decoder. Run:
//   dart test test/zstd_encoder_web_test.dart -p chrome
//   dart test test/zstd_encoder_web_test.dart -p chrome -c dart2wasm
library;

import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';
import 'package:test/test.dart';

/// A dart2js-safe rolling fingerprint (`h * 31` stays under 2^53 for h < 2^30).
int _fp(Uint8List b) {
  var h = 0;
  for (final x in b) {
    h = (h * 31 + x) & 0x3FFFFFFF;
  }
  return h;
}

Uint8List _encode(Uint8List data) => ZstdEncoder().encode(data);
Uint8List _roundTrip(Uint8List data) =>
    const ZstdDecoder().convert(_encode(data));

/// A skewed ASCII stream via xorshift32 (all 32-bit ops, so it is generated
/// identically on every platform) — Huffman literals fire on it.
Uint8List _skew(int n) {
  var x = 2463534242;
  final o = Uint8List(n);
  for (var i = 0; i < n; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >>> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    final v = x % 100;
    o[i] =
        v < 40
            ? 97
            : v < 65
            ? 101
            : v < 80
            ? 116
            : v < 90
            ? 111
            : 98 + (v % 20);
  }
  return o;
}

/// A skewed alphabet whose highest byte value exceeds 128 (xorshift32, so it is
/// platform-identical) — only FSE-compressed Huffman weights can describe its
/// table, exercising the > 128 encode path on the web.
Uint8List _skewHigh(int n) {
  var x = 88172645;
  final o = Uint8List(n);
  for (var i = 0; i < n; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >>> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    final v = x % 100;
    o[i] =
        v < 60
            ? 200
            : v < 85
            ? 210 + (x % 6)
            : 129 + (x % 127);
  }
  return o;
}

Uint8List get _tiny => Uint8List.fromList('hello zstd world\n'.codeUnits);
Uint8List get _text => Uint8List.fromList(
  ('the quick brown fox jumps over the lazy dog. ' * 400).codeUnits,
);

void main() {
  test('output is byte-identical to the VM reference on this platform', () {
    // (length, fingerprint) computed on the VM; equal on dart2js/dart2wasm iff
    // the encoded bytes are identical.
    final text = _encode(
      Uint8List.fromList(('the quick brown fox. ' * 400).codeUnits),
    );
    expect([text.length, _fp(text)], [39, 423566707]);

    final ramp = _encode(
      Uint8List.fromList(List.generate(9000, (i) => (i * 5) & 0xFF)),
    );
    expect([ramp.length, _fp(ramp)], [276, 468381680]);

    final mixed = _encode(
      Uint8List.fromList([
        ...('abcabc ' * 500).codeUnits,
        ...List.filled(1500, 9),
      ]),
    );
    expect([mixed.length, _fp(mixed)], [28, 780153945]);

    // A ~220 KB structured input: the hash multiply must stay dart2js-exact
    // (`_mul32Low`) or the match buckets — and the output — would diverge here.
    final big = _encode(
      Uint8List.fromList(
        List.generate(
          220000,
          (i) => (i % 700 < 440) ? 97 + ((i * 3) % 11) : (i * 29) & 0xFF,
        ),
      ),
    );
    expect([big.length, _fp(big)], [4378, 43415572]);

    // Huffman-literal cases (skewed ASCII): 4-stream (30 KB) and single-stream.
    // Both select FSE-compressed Huffman weights over direct here (smaller).
    final huff = _encode(_skew(30000));
    expect([huff.length, _fp(huff)], [14380, 597695472]);
    final huffSmall = _encode(_skew(700));
    expect([huffSmall.length, _fp(huffSmall)], [369, 870691339]);

    // A > 128 alphabet: direct weights can't describe it, so this drives the
    // FSE-compressed-weights path — the same integer arithmetic on every
    // platform, so the compressed bytes must match the VM exactly.
    final skewHigh = _encode(_skewHigh(30000));
    expect([skewHigh.length, _fp(skewHigh)], [16116, 538066891]);
  });

  test('encode + decode round-trips on this platform', () {
    expect(_roundTrip(Uint8List(0)), isEmpty);
    expect(_roundTrip(_tiny), _tiny);
    expect(_roundTrip(_text), _text);
    expect(
      _roundTrip(Uint8List.fromList(List.filled(6000, 0x5A))),
      Uint8List.fromList(List.filled(6000, 0x5A)),
    );
    final ramp = Uint8List.fromList(List.generate(9000, (i) => (i * 5) & 0xFF));
    expect(_roundTrip(ramp), ramp);
    final skewHigh = _skewHigh(30000); // FSE Huffman weights (> 128 alphabet)
    expect(_roundTrip(skewHigh), skewHigh);
  });

  test('crosses the 128 KiB block boundary on this platform', () {
    final data = Uint8List.fromList(
      List.generate(
        200000,
        (i) => (i % 500 < 300) ? 65 + (i % 9) : (i * 7) & 0xFF,
      ),
    );
    expect(_roundTrip(data), data);
  });

  test('sizeFormat-3 Huffman literal blocks round-trip on this platform', () {
    // 120 KB heavily-skewed ASCII: a block's compressed literals exceed 16 KiB,
    // so the literals header uses sizeFormat 3 (the dart2js-fixed size parse).
    final data = _skew(120000);
    expect(_roundTrip(data), data);
  });
}

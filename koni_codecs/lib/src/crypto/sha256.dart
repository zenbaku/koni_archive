import 'dart:typed_data';

import 'block_hash.dart';

/// SHA-256 (FIPS 180-4) as an incremental hash.
///
/// Used by the 7z AES key derivation (iterated SHA-256) and RAR5
/// (PBKDF2-HMAC-SHA256, hash-key checksum tweaking). All arithmetic stays
/// within unsigned 32-bit range (dart2js-exact).
final class Sha256 extends BlockHash {
  /// Creates a SHA-256 hash in its initial state.
  Sha256();

  Sha256._copy(Sha256 source) : super.fromState(source) {
    _state.setAll(0, source._state);
  }

  @override
  int get digestSize => 32;

  static const List<int> _k = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, //
    0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
    0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
    0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
    0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
    0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
  ];

  final Uint32List _state = Uint32List(8)..setAll(0, const [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, //
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
  ]);

  final Uint32List _schedule = Uint32List(64);

  @override
  Sha256 copy() => Sha256._copy(this);

  static int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

  @override
  void compress(Uint8List block, int offset) {
    final w = _schedule;
    for (var i = 0; i < 16; i++) {
      final o = offset + i * 4;
      w[i] =
          (block[o] << 24) |
          (block[o + 1] << 16) |
          (block[o + 2] << 8) |
          block[o + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    final s = _state;
    var a = s[0], b = s[1], c = s[2], d = s[3];
    var e = s[4], f = s[5], g = s[6], h = s[7];
    for (var i = 0; i < 64; i++) {
      final e1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((e ^ 0xFFFFFFFF) & g);
      final t1 = (h + e1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final e0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (e0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    s[0] = (s[0] + a) & 0xFFFFFFFF;
    s[1] = (s[1] + b) & 0xFFFFFFFF;
    s[2] = (s[2] + c) & 0xFFFFFFFF;
    s[3] = (s[3] + d) & 0xFFFFFFFF;
    s[4] = (s[4] + e) & 0xFFFFFFFF;
    s[5] = (s[5] + f) & 0xFFFFFFFF;
    s[6] = (s[6] + g) & 0xFFFFFFFF;
    s[7] = (s[7] + h) & 0xFFFFFFFF;
  }

  @override
  void writeDigest(Uint8List out) {
    for (var i = 0; i < 8; i++) {
      final word = _state[i];
      out[i * 4] = word >>> 24;
      out[i * 4 + 1] = (word >>> 16) & 0xFF;
      out[i * 4 + 2] = (word >>> 8) & 0xFF;
      out[i * 4 + 3] = word & 0xFF;
    }
  }

  /// Computes the SHA-256 digest of [data] in one call.
  static Uint8List compute(Uint8List data) => (Sha256()..add(data)).finish();
}

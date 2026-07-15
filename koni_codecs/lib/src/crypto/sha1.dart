import 'dart:typed_data';

import 'block_hash.dart';

/// SHA-1 (FIPS 180-4) as an incremental hash.
///
/// Present for the formats that mandate it — WinZip AES (PBKDF2-HMAC-SHA1
/// and the HMAC-SHA1 authentication code) and the RAR4 key derivation —
/// not as a general-purpose recommendation: SHA-1 is cryptographically
/// broken for collision resistance. All arithmetic stays within unsigned
/// 32-bit range (dart2js-exact).
final class Sha1 extends BlockHash {
  /// Creates a SHA-1 hash in its initial state.
  Sha1();

  Sha1._copy(Sha1 source) : super.fromState(source) {
    _h0 = source._h0;
    _h1 = source._h1;
    _h2 = source._h2;
    _h3 = source._h3;
    _h4 = source._h4;
  }

  @override
  int get digestSize => 20;

  int _h0 = 0x67452301;
  int _h1 = 0xEFCDAB89;
  int _h2 = 0x98BADCFE;
  int _h3 = 0x10325476;
  int _h4 = 0xC3D2E1F0;

  final Uint32List _schedule = Uint32List(80);

  @override
  Sha1 copy() => Sha1._copy(this);

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
    for (var i = 16; i < 80; i++) {
      final x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = ((x << 1) | (x >>> 31)) & 0xFFFFFFFF;
    }
    var a = _h0, b = _h1, c = _h2, d = _h3, e = _h4;
    for (var i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | ((b ^ 0xFFFFFFFF) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final t = (((a << 5) | (a >>> 27)) + f + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = ((b << 30) | (b >>> 2)) & 0xFFFFFFFF;
      b = a;
      a = t;
    }
    _h0 = (_h0 + a) & 0xFFFFFFFF;
    _h1 = (_h1 + b) & 0xFFFFFFFF;
    _h2 = (_h2 + c) & 0xFFFFFFFF;
    _h3 = (_h3 + d) & 0xFFFFFFFF;
    _h4 = (_h4 + e) & 0xFFFFFFFF;
  }

  @override
  void writeDigest(Uint8List out) {
    _writeWord(out, 0, _h0);
    _writeWord(out, 4, _h1);
    _writeWord(out, 8, _h2);
    _writeWord(out, 12, _h3);
    _writeWord(out, 16, _h4);
  }

  static void _writeWord(Uint8List out, int offset, int word) {
    out[offset] = word >>> 24;
    out[offset + 1] = (word >>> 16) & 0xFF;
    out[offset + 2] = (word >>> 8) & 0xFF;
    out[offset + 3] = word & 0xFF;
  }

  /// Computes the SHA-1 digest of [data] in one call.
  static Uint8List compute(Uint8List data) => (Sha1()..add(data)).finish();
}

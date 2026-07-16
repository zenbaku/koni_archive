import 'dart:typed_data';

/// AES block cipher (FIPS-197), key sizes 128/192/256.
///
/// This is the raw 16-byte block transform; chaining modes live in
/// `aes_modes.dart`. The implementation is the classic T-table software
/// AES (four 1 KiB lookup tables per direction, four lookups + XORs per
/// column per round); the tables and S-boxes are *generated* from the
/// GF(2^8) definitions at first use rather than transcribed, and the FIPS
/// / SP 800-38A vector tests pin the result.
///
/// Not constant-time (table lookups are data-dependent), an accepted
/// non-goal for archive reading, recorded in `doc/encryption-scope.md`.
/// All arithmetic stays within unsigned 32-bit range (dart2js-exact).
final class Aes {
  /// Expands [key] (16, 24, or 32 bytes) into round keys for both
  /// directions.
  Aes(Uint8List key)
    : _rounds = switch (key.length) {
        16 => 10,
        24 => 12,
        32 => 14,
        _ =>
          throw ArgumentError.value(
            key.length,
            'key',
            'AES key must be 16, 24, or 32 bytes',
          ),
      } {
    _encKeys = _expandKey(key);
    _decKeys = _invertKey(_encKeys);
  }

  final int _rounds;
  late final Uint32List _encKeys;
  late final Uint32List _decKeys;

  static final _AesTables _t = _AesTables._();

  Uint32List _expandKey(Uint8List key) {
    final nk = key.length ~/ 4;
    final total = 4 * (_rounds + 1);
    final w = Uint32List(total);
    for (var i = 0; i < nk; i++) {
      w[i] =
          (key[i * 4] << 24) |
          (key[i * 4 + 1] << 16) |
          (key[i * 4 + 2] << 8) |
          key[i * 4 + 3];
    }
    var rcon = 1;
    for (var i = nk; i < total; i++) {
      var temp = w[i - 1];
      if (i % nk == 0) {
        temp =
            _subWord(((temp << 8) | (temp >>> 24)) & 0xFFFFFFFF) ^ (rcon << 24);
        rcon = _xtime(rcon);
      } else if (nk > 6 && i % nk == 4) {
        temp = _subWord(temp);
      }
      w[i] = w[i - nk] ^ temp;
    }
    return w;
  }

  /// Equivalent-inverse-cipher schedule: round keys in reverse round
  /// order, InvMixColumns applied to all but the first and last.
  Uint32List _invertKey(Uint32List ek) {
    final total = ek.length;
    final dk = Uint32List(total);
    for (var i = 0; i < total; i++) {
      dk[i] = ek[total - 4 - 4 * (i ~/ 4) + (i % 4)];
    }
    for (var i = 4; i < total - 4; i++) {
      dk[i] = _invMixWord(dk[i]);
    }
    return dk;
  }

  static int _subWord(int w) =>
      (_t.sbox[w >>> 24] << 24) |
      (_t.sbox[(w >>> 16) & 0xFF] << 16) |
      (_t.sbox[(w >>> 8) & 0xFF] << 8) |
      _t.sbox[w & 0xFF];

  static int _invMixWord(int w) {
    final b0 = w >>> 24, b1 = (w >>> 16) & 0xFF;
    final b2 = (w >>> 8) & 0xFF, b3 = w & 0xFF;
    final m = _t.mul;
    return ((m[0xE * 256 + b0] ^
                m[0xB * 256 + b1] ^
                m[0xD * 256 + b2] ^
                m[0x9 * 256 + b3]) <<
            24) |
        ((m[0x9 * 256 + b0] ^
                m[0xE * 256 + b1] ^
                m[0xB * 256 + b2] ^
                m[0xD * 256 + b3]) <<
            16) |
        ((m[0xD * 256 + b0] ^
                m[0x9 * 256 + b1] ^
                m[0xE * 256 + b2] ^
                m[0xB * 256 + b3]) <<
            8) |
        (m[0xB * 256 + b0] ^
            m[0xD * 256 + b1] ^
            m[0x9 * 256 + b2] ^
            m[0xE * 256 + b3]);
  }

  static int _xtime(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)) & 0xFF;

  /// Encrypts the block at `input[inputOffset..+16)` into
  /// `output[outputOffset..+16)` (may alias).
  void encryptBlock(
    Uint8List input,
    int inputOffset,
    Uint8List output,
    int outputOffset,
  ) {
    final rk = _encKeys;
    final te0 = _t.te0, te1 = _t.te1, te2 = _t.te2, te3 = _t.te3;
    var s0 = _load(input, inputOffset) ^ rk[0];
    var s1 = _load(input, inputOffset + 4) ^ rk[1];
    var s2 = _load(input, inputOffset + 8) ^ rk[2];
    var s3 = _load(input, inputOffset + 12) ^ rk[3];
    var k = 4;
    for (var round = 1; round < _rounds; round++, k += 4) {
      final t0 =
          te0[s0 >>> 24] ^
          te1[(s1 >>> 16) & 0xFF] ^
          te2[(s2 >>> 8) & 0xFF] ^
          te3[s3 & 0xFF] ^
          rk[k];
      final t1 =
          te0[s1 >>> 24] ^
          te1[(s2 >>> 16) & 0xFF] ^
          te2[(s3 >>> 8) & 0xFF] ^
          te3[s0 & 0xFF] ^
          rk[k + 1];
      final t2 =
          te0[s2 >>> 24] ^
          te1[(s3 >>> 16) & 0xFF] ^
          te2[(s0 >>> 8) & 0xFF] ^
          te3[s1 & 0xFF] ^
          rk[k + 2];
      final t3 =
          te0[s3 >>> 24] ^
          te1[(s0 >>> 16) & 0xFF] ^
          te2[(s1 >>> 8) & 0xFF] ^
          te3[s2 & 0xFF] ^
          rk[k + 3];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
    }
    final sbox = _t.sbox;
    _store(
      output,
      outputOffset,
      ((sbox[s0 >>> 24] << 24) |
              (sbox[(s1 >>> 16) & 0xFF] << 16) |
              (sbox[(s2 >>> 8) & 0xFF] << 8) |
              sbox[s3 & 0xFF]) ^
          rk[k],
    );
    _store(
      output,
      outputOffset + 4,
      ((sbox[s1 >>> 24] << 24) |
              (sbox[(s2 >>> 16) & 0xFF] << 16) |
              (sbox[(s3 >>> 8) & 0xFF] << 8) |
              sbox[s0 & 0xFF]) ^
          rk[k + 1],
    );
    _store(
      output,
      outputOffset + 8,
      ((sbox[s2 >>> 24] << 24) |
              (sbox[(s3 >>> 16) & 0xFF] << 16) |
              (sbox[(s0 >>> 8) & 0xFF] << 8) |
              sbox[s1 & 0xFF]) ^
          rk[k + 2],
    );
    _store(
      output,
      outputOffset + 12,
      ((sbox[s3 >>> 24] << 24) |
              (sbox[(s0 >>> 16) & 0xFF] << 16) |
              (sbox[(s1 >>> 8) & 0xFF] << 8) |
              sbox[s2 & 0xFF]) ^
          rk[k + 3],
    );
  }

  /// Decrypts the block at `input[inputOffset..+16)` into
  /// `output[outputOffset..+16)` (may alias).
  void decryptBlock(
    Uint8List input,
    int inputOffset,
    Uint8List output,
    int outputOffset,
  ) {
    final rk = _decKeys;
    final td0 = _t.td0, td1 = _t.td1, td2 = _t.td2, td3 = _t.td3;
    var s0 = _load(input, inputOffset) ^ rk[0];
    var s1 = _load(input, inputOffset + 4) ^ rk[1];
    var s2 = _load(input, inputOffset + 8) ^ rk[2];
    var s3 = _load(input, inputOffset + 12) ^ rk[3];
    var k = 4;
    for (var round = 1; round < _rounds; round++, k += 4) {
      final t0 =
          td0[s0 >>> 24] ^
          td1[(s3 >>> 16) & 0xFF] ^
          td2[(s2 >>> 8) & 0xFF] ^
          td3[s1 & 0xFF] ^
          rk[k];
      final t1 =
          td0[s1 >>> 24] ^
          td1[(s0 >>> 16) & 0xFF] ^
          td2[(s3 >>> 8) & 0xFF] ^
          td3[s2 & 0xFF] ^
          rk[k + 1];
      final t2 =
          td0[s2 >>> 24] ^
          td1[(s1 >>> 16) & 0xFF] ^
          td2[(s0 >>> 8) & 0xFF] ^
          td3[s3 & 0xFF] ^
          rk[k + 2];
      final t3 =
          td0[s3 >>> 24] ^
          td1[(s2 >>> 16) & 0xFF] ^
          td2[(s1 >>> 8) & 0xFF] ^
          td3[s0 & 0xFF] ^
          rk[k + 3];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
    }
    final inv = _t.invSbox;
    _store(
      output,
      outputOffset,
      ((inv[s0 >>> 24] << 24) |
              (inv[(s3 >>> 16) & 0xFF] << 16) |
              (inv[(s2 >>> 8) & 0xFF] << 8) |
              inv[s1 & 0xFF]) ^
          rk[k],
    );
    _store(
      output,
      outputOffset + 4,
      ((inv[s1 >>> 24] << 24) |
              (inv[(s0 >>> 16) & 0xFF] << 16) |
              (inv[(s3 >>> 8) & 0xFF] << 8) |
              inv[s2 & 0xFF]) ^
          rk[k + 1],
    );
    _store(
      output,
      outputOffset + 8,
      ((inv[s2 >>> 24] << 24) |
              (inv[(s1 >>> 16) & 0xFF] << 16) |
              (inv[(s0 >>> 8) & 0xFF] << 8) |
              inv[s3 & 0xFF]) ^
          rk[k + 2],
    );
    _store(
      output,
      outputOffset + 12,
      ((inv[s3 >>> 24] << 24) |
              (inv[(s2 >>> 16) & 0xFF] << 16) |
              (inv[(s1 >>> 8) & 0xFF] << 8) |
              inv[s0 & 0xFF]) ^
          rk[k + 3],
    );
  }

  static int _load(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static void _store(Uint8List bytes, int offset, int word) {
    bytes[offset] = word >>> 24;
    bytes[offset + 1] = (word >>> 16) & 0xFF;
    bytes[offset + 2] = (word >>> 8) & 0xFF;
    bytes[offset + 3] = word & 0xFF;
  }
}

/// Lazily built S-boxes, GF(2^8) multiplication rows, and T-tables.
final class _AesTables {
  _AesTables._() {
    // exp/log tables over GF(2^8) with generator 3 (x+1).
    final exp = Uint8List(256);
    final log = Uint8List(256);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      exp[i] = x;
      log[x] = i;
      x ^= Aes._xtime(x); // multiply by 3
    }

    int gfMul(int a, int b) =>
        a == 0 || b == 0 ? 0 : exp[(log[a] + log[b]) % 255];

    // Multiplication rows for the coefficients the tables need.
    for (final c in const [0x2, 0x3, 0x9, 0xB, 0xD, 0xE]) {
      for (var i = 0; i < 256; i++) {
        mul[c * 256 + i] = gfMul(c, i);
      }
    }

    // S-box: multiplicative inverse then the affine transform. The
    // exp cycle has period 255, so the inverse exponent is taken mod 255
    // (inverse of 1 is exp[0], not the never-written exp[255]).
    for (var i = 0; i < 256; i++) {
      final inv = i == 0 ? 0 : exp[(255 - log[i]) % 255];
      var s = inv;
      var r = inv;
      for (var k = 0; k < 4; k++) {
        r = ((r << 1) | (r >>> 7)) & 0xFF;
        s ^= r;
      }
      s ^= 0x63;
      sbox[i] = s;
      invSbox[s] = i;
    }

    // T-tables: MixColumns (rsp. InvMixColumns) of one substituted byte,
    // packed MSB-first; te1..te3 / td1..td3 are byte rotations of te0/td0.
    for (var i = 0; i < 256; i++) {
      final s = sbox[i];
      final e =
          (mul[0x2 * 256 + s] << 24) |
          (s << 16) |
          (s << 8) |
          mul[0x3 * 256 + s];
      te0[i] = e;
      te1[i] = ((e >>> 8) | (e << 24)) & 0xFFFFFFFF;
      te2[i] = ((e >>> 16) | (e << 16)) & 0xFFFFFFFF;
      te3[i] = ((e >>> 24) | (e << 8)) & 0xFFFFFFFF;

      final v = invSbox[i];
      final d =
          (mul[0xE * 256 + v] << 24) |
          (mul[0x9 * 256 + v] << 16) |
          (mul[0xD * 256 + v] << 8) |
          mul[0xB * 256 + v];
      td0[i] = d;
      td1[i] = ((d >>> 8) | (d << 24)) & 0xFFFFFFFF;
      td2[i] = ((d >>> 16) | (d << 16)) & 0xFFFFFFFF;
      td3[i] = ((d >>> 24) | (d << 8)) & 0xFFFFFFFF;
    }
  }

  final Uint8List sbox = Uint8List(256);
  final Uint8List invSbox = Uint8List(256);
  final Uint8List mul = Uint8List(16 * 256);
  final Uint32List te0 = Uint32List(256);
  final Uint32List te1 = Uint32List(256);
  final Uint32List te2 = Uint32List(256);
  final Uint32List te3 = Uint32List(256);
  final Uint32List td0 = Uint32List(256);
  final Uint32List td1 = Uint32List(256);
  final Uint32List td2 = Uint32List(256);
  final Uint32List td3 = Uint32List(256);
}

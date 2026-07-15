import 'dart:typed_data';

import 'package:koni_codecs/crypto.dart';

/// ZIP decryption schemes (Phase 3, P3-2): traditional PKWARE ("zipcrypto")
/// and WinZip AES (method 99). Both are format glue over the primitives in
/// `package:koni_codecs/crypto.dart`; the reader wires them into the entry
/// stream.

/// Traditional PKWARE stream cipher (APPNOTE §6.1).
///
/// A byte-at-a-time stream cipher keyed by three 32-bit words the password
/// seeds and each decrypted byte advances. The archive prepends a 12-byte
/// encryption header whose final byte is a one-in-256 password check
/// (against the CRC-32 high byte, or the DOS-time high byte when the entry
/// carries a data descriptor).
final class ZipCryptoCipher {
  /// Seeds the keys from [passwordBytes] (the raw password bytes; UTF-8 by
  /// our convention, `doc/encryption-scope.md`).
  ZipCryptoCipher(Uint8List passwordBytes) {
    for (final b in passwordBytes) {
      _updateKeys(b);
    }
  }

  int _key0 = 0x12345678;
  int _key1 = 0x23456789;
  int _key2 = 0x34567890;

  // CRC-32 byte table (reflected, polynomial 0xEDB88320) — the same
  // polynomial as core's Crc32, but that one exposes only a slicing-by-8
  // engine, so the single-byte step the key schedule needs is built here.
  static final Uint32List _crcTable = _buildCrcTable();

  static Uint32List _buildCrcTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      table[i] = c;
    }
    return table;
  }

  static int _crc32Byte(int crc, int b) =>
      (crc >>> 8) ^ _crcTable[(crc ^ b) & 0xFF];

  // 32-bit modular multiply, split so no intermediate exceeds 2^53 — the
  // dart2js/dart2wasm-safe form (a full 32×32 product would overflow the
  // exact-integer range and bitwise ops are 32-bit).
  static int _mul32(int a, int b) {
    final aLo = a & 0xFFFF;
    final aHi = a >>> 16;
    final lo = aLo * b;
    final hi = ((aHi * b) & 0xFFFF) << 16;
    return (lo + hi) & 0xFFFFFFFF;
  }

  void _updateKeys(int b) {
    _key0 = _crc32Byte(_key0, b);
    _key1 = (_key1 + (_key0 & 0xFF)) & 0xFFFFFFFF;
    _key1 = (_mul32(_key1, 134775813) + 1) & 0xFFFFFFFF;
    _key2 = _crc32Byte(_key2, _key1 >>> 24);
  }

  int _decryptByte() {
    final temp = (_key2 & 0xFFFF) | 2;
    return ((temp * (temp ^ 1)) >>> 8) & 0xFF;
  }

  /// Decrypts `data[start..end)` in place, advancing the key state.
  void process(Uint8List data, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, data.length);
    for (var i = start; i < stop; i++) {
      final c = data[i] ^ _decryptByte();
      _updateKeys(c);
      data[i] = c;
    }
  }

  /// Length of the encryption header prepended to the content.
  static const int headerSize = 12;
}

/// AES strengths WinZip AE encodes in the 0x9901 extra field.
class WinZipAesParams {
  /// Parses the strength byte (1/2/3) and vendor version (1 = AE-1,
  /// 2 = AE-2) from a 0x9901 extra payload; returns null if malformed.
  static WinZipAesParams? fromExtra(Uint8List extra) {
    if (extra.length < 7) return null;
    final vendorVersion = extra[0] | (extra[1] << 8);
    final strength = extra[4];
    final method = extra[5] | (extra[6] << 8);
    if (strength < 1 || strength > 3) return null;
    return WinZipAesParams._(vendorVersion, strength, method);
  }

  /// Parameters for *writing* an AE-2 entry (Phase 4): vendor version 2
  /// (HMAC-authenticated, CRC field zeroed), a caller-chosen [strength]
  /// (1/2/3 = AES-128/192/256) and the [method] actually applied under the
  /// encryption (0 stored, 8 deflate).
  factory WinZipAesParams.ae2({required int strength, required int method}) {
    if (strength < 1 || strength > 3) {
      throw ArgumentError.value(strength, 'strength', 'must be 1, 2, or 3');
    }
    return WinZipAesParams._(2, strength, method);
  }

  WinZipAesParams._(this.vendorVersion, this.strength, this.method);

  /// 1 = AE-1 (CRC is the real plaintext CRC), 2 = AE-2 (CRC field is 0).
  final int vendorVersion;

  /// 1 = AES-128, 2 = AES-192, 3 = AES-256.
  final int strength;

  /// The actual compression method applied under the encryption.
  final int method;

  /// Salt length in bytes: 8/12/16 for AES-128/192/256.
  int get saltLength => strength * 4 + 4;

  /// Key length in bytes: 16/24/32.
  int get keyLength => strength * 8 + 8;

  /// Total per-entry overhead: salt + 2-byte verifier + 10-byte MAC.
  int get overhead => saltLength + 2 + macLength;

  /// Truncated HMAC-SHA1 authentication code length.
  static const int macLength = 10;
}

/// WinZip AES entry decryptor: AES-CTR (little-endian counter) keystream
/// plus streaming HMAC-SHA1 authentication (APPNOTE + the AE-2 spec).
final class WinZipAesDecryptor {
  WinZipAesDecryptor._(this._ctr, this._hmac);

  /// Derives keys with PBKDF2-HMAC-SHA1 (1000 iterations) from
  /// [passwordBytes] and [salt], verifies the 2-byte password check
  /// [verifier], and returns a decryptor — or throws the caller-provided
  /// [onBadPassword] result when the verifier does not match.
  factory WinZipAesDecryptor.derive({
    required Uint8List passwordBytes,
    required WinZipAesParams params,
    required Uint8List salt,
    required Uint8List verifier,
    required Never Function() onBadPassword,
  }) {
    final keyLen = params.keyLength;
    final derived = pbkdf2(
      Hmac.sha1(passwordBytes),
      salt,
      1000,
      keyLen * 2 + 2,
    );
    final aesKey = Uint8List.sublistView(derived, 0, keyLen);
    final macKey = Uint8List.sublistView(derived, keyLen, keyLen * 2);
    final derivedVerifier = Uint8List.sublistView(derived, keyLen * 2);
    if (derivedVerifier[0] != verifier[0] ||
        derivedVerifier[1] != verifier[1]) {
      onBadPassword();
    }
    return WinZipAesDecryptor._(AesCtrLeStream(Aes(aesKey)), Hmac.sha1(macKey));
  }

  final AesCtrLeStream _ctr;
  final Hmac _hmac;

  /// Decrypts `data[start..end)` in place: the MAC is computed over the
  /// *ciphertext*, so HMAC is updated before the CTR keystream is applied.
  void process(Uint8List data, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, data.length);
    _hmac.add(data, start, stop);
    _ctr.processInPlace(data, start, stop);
  }

  /// Returns true if the 10-byte [mac] matches the authentication code
  /// over the ciphertext seen so far.
  bool verifyMac(Uint8List mac) {
    final full = _hmac.finish();
    for (var i = 0; i < WinZipAesParams.macLength; i++) {
      if (full[i] != mac[i]) return false;
    }
    return true;
  }
}

/// WinZip AES entry encryptor (Phase 4): the write mirror of
/// [WinZipAesDecryptor]. Same PBKDF2 key schedule; AES-CTR encrypts the
/// (already-compressed) plaintext in place and HMAC-SHA1 authenticates the
/// resulting ciphertext.
final class WinZipAesEncryptor {
  WinZipAesEncryptor._(this._ctr, this._hmac, this.salt, this.verifier);

  /// Derives keys with PBKDF2-HMAC-SHA1 (1000 iterations) from
  /// [passwordBytes] and the caller-generated [salt] (`params.saltLength`
  /// bytes), exposing the 2-byte [verifier] the entry stores after the salt.
  /// The salt is generated by the writer, not here, so this class stays free
  /// of any randomness source (it can run on any platform, deterministically
  /// in tests).
  factory WinZipAesEncryptor.derive({
    required Uint8List passwordBytes,
    required WinZipAesParams params,
    required Uint8List salt,
  }) {
    if (salt.length != params.saltLength) {
      throw ArgumentError.value(
        salt.length,
        'salt',
        'must be ${params.saltLength} bytes for this strength',
      );
    }
    final keyLen = params.keyLength;
    final derived = pbkdf2(
      Hmac.sha1(passwordBytes),
      salt,
      1000,
      keyLen * 2 + 2,
    );
    final aesKey = Uint8List.sublistView(derived, 0, keyLen);
    final macKey = Uint8List.sublistView(derived, keyLen, keyLen * 2);
    final verifier = Uint8List.fromList(
      Uint8List.sublistView(derived, keyLen * 2),
    );
    return WinZipAesEncryptor._(
      AesCtrLeStream(Aes(aesKey)),
      Hmac.sha1(macKey),
      salt,
      verifier,
    );
  }

  final AesCtrLeStream _ctr;
  final Hmac _hmac;

  /// The salt to write before the ciphertext.
  final Uint8List salt;

  /// The 2-byte password verifier to write after the salt.
  final Uint8List verifier;

  /// Encrypts `data[start..end)` in place (plaintext → ciphertext), then
  /// feeds the ciphertext to the running MAC — the reverse order of
  /// [WinZipAesDecryptor.process], because the MAC is always over ciphertext.
  void process(Uint8List data, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, data.length);
    _ctr.processInPlace(data, start, stop);
    _hmac.add(data, start, stop);
  }

  /// The 10-byte authentication code to append after the ciphertext.
  Uint8List finishMac() => Uint8List.fromList(
    Uint8List.sublistView(_hmac.finish(), 0, WinZipAesParams.macLength),
  );
}

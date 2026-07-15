import 'dart:typed_data';

import 'package:koni_codecs/crypto.dart';

/// 7z AES-256 decryption glue (Phase 3, P3-3): the AES coder (`06f10701`)
/// key derivation and coder-property parsing. The block cipher and CBC
/// mode come from `package:koni_codecs/crypto.dart`.

/// Parsed properties of a 7z AES coder: the KDF cost, salt, and IV.
///
/// Property byte layout (7-Zip `7zAes.cpp`): `props[0]` low 6 bits are the
/// cycle-power; its two high bits are the top bit of the salt and IV
/// sizes, whose remaining bits live in `props[1]`. Salt then IV follow.
/// 7-Zip's defaults are often a 0-byte salt and an IV shorter than 16
/// bytes (zero-padded on use).
final class SevenZAesProps {
  SevenZAesProps._(this.numCyclesPower, this.salt, this.iv);

  /// log2 of the KDF round count.
  final int numCyclesPower;

  /// Salt bytes (may be empty).
  final Uint8List salt;

  /// 16-byte CBC IV (short IVs are zero-padded).
  final Uint8List iv;

  /// Parses [props]; throws [FormatException] on a malformed field (the
  /// reader maps that to a typed archive error).
  factory SevenZAesProps.parse(Uint8List props) {
    if (props.isEmpty) {
      throw const FormatException('empty AES coder properties');
    }
    final b0 = props[0];
    final numCyclesPower = b0 & 0x3F;
    if ((b0 & 0xC0) == 0) {
      // No salt, no explicit IV — the whole-zero IV, default cost.
      return SevenZAesProps._(numCyclesPower, Uint8List(0), Uint8List(16));
    }
    if (props.length < 2) {
      throw const FormatException('truncated AES coder properties');
    }
    final b1 = props[1];
    final saltSize = ((b0 >> 7) & 1) + (b1 >> 4);
    final ivSize = ((b0 >> 6) & 1) + (b1 & 0x0F);
    if (props.length < 2 + saltSize + ivSize) {
      throw const FormatException('AES coder properties too short for salt/IV');
    }
    final salt = Uint8List.sublistView(props, 2, 2 + saltSize);
    final rawIv = Uint8List.sublistView(
      props,
      2 + saltSize,
      2 + saltSize + ivSize,
    );
    final iv = Uint8List(16)..setRange(0, rawIv.length, rawIv);
    return SevenZAesProps._(numCyclesPower, Uint8List.fromList(salt), iv);
  }

  /// Cache key: the derived key depends only on (password, salt,
  /// numCyclesPower) — never the IV — so folders sharing a salt reuse it.
  String cacheKey() =>
      '$numCyclesPower:${salt.map((b) => b.toRadixString(16)).join()}';
}

/// Derives the 32-byte AES-256 key for a 7z archive.
///
/// 7-Zip's KDF is **not** PBKDF2: a single SHA-256 context is updated
/// `2^numCyclesPower` times, each round absorbing `salt ‖ passwordUtf16le ‖
/// counter`, where the counter is an 8-byte little-endian round index; the
/// context is finalized once. The password is encoded UTF-16LE.
Uint8List deriveSevenZAesKey(String password, SevenZAesProps props) {
  // Special sentinel (7-Zip): power 0x3F would mean 2^63 rounds — never a
  // real archive; reject rather than hang.
  if (props.numCyclesPower >= 40) {
    throw const FormatException('implausible AES KDF cycle count');
  }
  final pw = _utf16le(password);
  final rounds = 1 << props.numCyclesPower;
  final sha = Sha256();
  final counter = Uint8List(8);
  final salt = props.salt;
  for (var round = 0; round < rounds; round++) {
    if (salt.isNotEmpty) sha.add(salt);
    if (pw.isNotEmpty) sha.add(pw);
    sha.add(counter);
    // 64-bit little-endian increment.
    for (var i = 0; i < 8; i++) {
      counter[i] = (counter[i] + 1) & 0xFF;
      if (counter[i] != 0) break;
    }
  }
  return sha.finish();
}

/// Decrypts [ciphertext] (a multiple of 16 bytes) in place with AES-256-CBC
/// under [key] and [iv]. The caller slices the plaintext to the coder's
/// declared output size (CBC leaves block padding on the tail).
void sevenZAesDecrypt(Uint8List key, Uint8List iv, Uint8List ciphertext) {
  AesCbcDecryptor(Aes(key), iv).decryptInPlace(ciphertext);
}

Uint8List _utf16le(String s) {
  final units = s.codeUnits; // UTF-16 code units, matching 7-Zip's wchar
  final out = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    out[i * 2] = units[i] & 0xFF;
    out[i * 2 + 1] = (units[i] >> 8) & 0xFF;
  }
  return out;
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_codecs/crypto.dart';

/// RAR5 decryption glue (Phase 3, P3-4).
///
/// Clean-room per `doc/rar-provenance.md`: the algorithm follows the public
/// RarLab RAR5 technote and permissively-licensed clean-room descriptions
/// (rarfile MIT docs; libarchive/BSD; the Go `rardecode`/Rust `unrar`-free
/// crates), and is pinned empirically against `rar`-authored fixtures (the
/// derived password-check value, the AES key, and the tweaked CRC all
/// reproduce the fixture bytes). No unrar/GPL source was consulted.
///
/// RAR5 uses AES-256-CBC. The key, a hash key (for checksum tweaking), and
/// a password-check value are derived together from one HMAC-SHA256 chain
/// (PBKDF2-style, but sharing the chain across three iteration milestones).
/// The password is encoded UTF-8.

/// Parsed RAR5 file/archive encryption record (the type-0x01 file extra or
/// the HEAD_CRYPT archive header).
final class Rar5EncryptionInfo {
  /// Creates a parsed encryption record.
  Rar5EncryptionInfo({
    required this.version,
    required this.flags,
    required this.lg2Count,
    required this.salt,
    required this.iv,
    required this.pswCheck,
    required this.pswCheckCsum,
  });

  /// Encryption version (0 = AES-256; anything else is unsupported).
  final int version;

  /// Encryption flags: bit 0 (`0x01`) => a password-check value is present
  /// and the file checksum is tweaked with the hash key.
  final int flags;

  /// log2 of the KDF iteration count.
  final int lg2Count;

  /// 16-byte salt.
  final Uint8List salt;

  /// 16-byte CBC IV.
  final Uint8List iv;

  /// 8-byte password-check value, when [usePswCheck].
  final Uint8List? pswCheck;

  /// 4-byte SHA-256 prefix protecting [pswCheck] against header corruption.
  final Uint8List? pswCheckCsum;

  /// Whether a password-check value is present (flag bit 0).
  bool get usePswCheck => flags & 0x01 != 0;

  /// Whether the file checksum is tweaked with the hash key (flag bit 1,
  /// "use MAC"). Independent of [usePswCheck]: a `-hp` file record sets this
  /// without a per-file password check (the check lives in the crypt header),
  /// so the tweak must key off this flag, not [usePswCheck].
  bool get useMac => flags & 0x02 != 0;

  /// AES-256 is the only defined RAR5 cipher.
  bool get isAes256 => version == 0;
}

/// Derived RAR5 keys plus the operations that need them.
final class Rar5Keys {
  Rar5Keys._(this.aesKey, this.hashKey, this.pswCheck);

  /// 32-byte AES-256 key.
  final Uint8List aesKey;

  /// 32-byte hash key (checksum tweaking).
  final Uint8List hashKey;

  /// 8-byte derived password-check value.
  final Uint8List pswCheck;

  /// Derives the key triple from [password] (UTF-8), [salt], and the
  /// iteration exponent [lg2Count].
  ///
  /// One HMAC-SHA256 chain is run; PBKDF2 with `2^lg2Count` iterations
  /// yields the AES key, 16 further iterations the hash key, and 16 more a
  /// 32-byte value folded to the 8-byte check.
  factory Rar5Keys.derive(String password, Uint8List salt, int lg2Count) {
    if (lg2Count < 0 || lg2Count > 24) {
      // The technote caps the accepted cost; reject the rest rather than
      // spin on an implausible round count.
      throw const FormatException('RAR5 KDF cost out of range');
    }
    final prf = Hmac.sha256(Uint8List.fromList(utf8.encode(password)));
    // U1 = HMAC(pw, salt || big-endian block index 1).
    final saltBlock = Uint8List(salt.length + 4)
      ..setRange(0, salt.length, salt);
    saltBlock[salt.length + 3] = 1;
    prf.reset();
    prf.add(saltBlock);
    var u = prf.finish();
    final fn = Uint8List.fromList(u);

    final total = 1 << lg2Count;
    final aesKey = Uint8List(32);
    final hashKey = Uint8List(32);
    final checkSource = Uint8List(32);
    var produced = 1; // fn currently holds the XOR of U1..U_produced.
    void snapshot() {
      if (produced == total) aesKey.setAll(0, fn);
      if (produced == total + 16) hashKey.setAll(0, fn);
      if (produced == total + 32) checkSource.setAll(0, fn);
    }

    snapshot(); // total may be 1 (lg2Count == 0).
    while (produced < total + 32) {
      prf.reset();
      prf.add(u);
      u = prf.finish();
      for (var j = 0; j < 32; j++) {
        fn[j] ^= u[j];
      }
      produced++;
      snapshot();
    }

    final pswCheck = Uint8List(8);
    for (var i = 0; i < 32; i++) {
      pswCheck[i % 8] ^= checkSource[i];
    }
    return Rar5Keys._(aesKey, hashKey, pswCheck);
  }

  /// Whether [expected] (the header's stored check) matches the derived
  /// value — the reliable RAR5 wrong-password signal.
  bool passwordMatches(Uint8List expected) {
    if (expected.length != 8) return false;
    for (var i = 0; i < 8; i++) {
      if (pswCheck[i] != expected[i]) return false;
    }
    return true;
  }

  /// AES-256-CBC-decrypts [data] (a multiple of 16 bytes) in place under
  /// this key and [iv].
  void decrypt(Uint8List data, Uint8List iv) {
    AesCbcDecryptor(Aes(aesKey), iv).decryptInPlace(data);
  }

  /// Transforms a plaintext CRC-32 into the value RAR5 stores for an
  /// encrypted file: `fold(HMAC-SHA256(hashKey, LE32(crc)))`. Comparing the
  /// transform of the *computed* CRC against the header's stored CRC
  /// verifies integrity without ever revealing the plaintext CRC.
  int tweakCrc(int crc) {
    final le =
        Uint8List(4)
          ..[0] = crc & 0xFF
          ..[1] = (crc >> 8) & 0xFF
          ..[2] = (crc >> 16) & 0xFF
          ..[3] = (crc >> 24) & 0xFF;
    final mac = Hmac.sha256(hashKey).compute(le);
    final out = Uint8List(4);
    for (var i = 0; i < mac.length; i++) {
      out[i % 4] ^= mac[i];
    }
    return out[0] | (out[1] << 8) | (out[2] << 16) | (out[3] << 24);
  }
}

/// Verifies the header's [pswCheckCsum] actually protects its [pswCheck]
/// (SHA-256 prefix) — guards against trusting a corrupted check value.
bool rar5PswCheckIntact(Uint8List pswCheck, Uint8List pswCheckCsum) {
  final digest = Sha256.compute(pswCheck);
  for (var i = 0; i < 4; i++) {
    if (digest[i] != pswCheckCsum[i]) return false;
  }
  return true;
}

/// Derived RAR4 (v29 / "RAR3") AES-128 key and IV.
///
/// The RAR3 KDF is a bespoke SHA-1 construction — not PBKDF2 — verified
/// byte-exact against `rar`-authored encrypted v4 fixtures. RAR4 stores the
/// **plaintext** CRC (no hash-key tweak) and carries no password-check
/// value, so a wrong password surfaces only as a CRC mismatch.
final class Rar4Keys {
  Rar4Keys._(this.aesKey, this.iv);

  /// 16-byte AES-128 key.
  final Uint8List aesKey;

  /// 16-byte CBC IV.
  final Uint8List iv;

  /// Derives the key and IV from [password] (UTF-16LE) and the 8-byte
  /// [salt] carried in the file header.
  ///
  /// Runs a SHA-1 chain of `0x40000` rounds, each absorbing
  /// `passwordUtf16le ‖ salt ‖ counter24le`; one IV byte is harvested from
  /// a clone-and-finalize every `0x4000` rounds, and the AES key is the
  /// final digest's first 16 bytes with each 4-byte word byte-reversed.
  factory Rar4Keys.derive(String password, Uint8List salt) {
    final raw = <int>[];
    for (final unit in password.codeUnits) {
      raw
        ..add(unit & 0xFF)
        ..add((unit >> 8) & 0xFF); // UTF-16LE
    }
    raw.addAll(salt);
    final rawBytes = Uint8List.fromList(raw);

    const rounds = 0x40000;
    const ivStep = rounds ~/ 16; // 0x4000
    final iv = Uint8List(16);
    final counter = Uint8List(3);
    final sha = Sha1();
    for (var i = 0; i < rounds; i++) {
      sha.add(rawBytes);
      counter[0] = i & 0xFF;
      counter[1] = (i >> 8) & 0xFF;
      counter[2] = (i >> 16) & 0xFF;
      sha.add(counter);
      if (i % ivStep == 0) {
        // Intermediate digest of the running state → one IV byte (its last).
        iv[i ~/ ivStep] = sha.copy().finish()[19];
      }
    }
    final digest = sha.finish();
    final aesKey = Uint8List(16);
    for (var word = 0; word < 4; word++) {
      for (var b = 0; b < 4; b++) {
        aesKey[word * 4 + b] = digest[word * 4 + (3 - b)];
      }
    }
    return Rar4Keys._(aesKey, iv);
  }

  /// AES-128-CBC-decrypts [data] (a multiple of 16 bytes) in place.
  void decrypt(Uint8List data) {
    AesCbcDecryptor(Aes(aesKey), iv).decryptInPlace(data);
  }
}

import 'dart:typed_data';

import 'aes.dart';

/// AES-CBC decryption (SP 800-38A) as an incremental whole-block
/// transform.
///
/// Used by 7z (AES-256), RAR5 (AES-256), and RAR4 (AES-128), all of which
/// pad ciphertext to 16 bytes and truncate the plaintext by *known size*
/// — so there is no padding scheme here: callers hand in complete blocks
/// and slice the output themselves. Sequential calls chain (the last
/// ciphertext block carries over), matching a stream decrypted in chunks.
final class AesCbcDecryptor {
  /// Creates a decryptor over [cipher] starting from [iv] (16 bytes).
  AesCbcDecryptor(this._cipher, Uint8List iv) : _prev = Uint8List(16) {
    if (iv.length != 16) {
      throw ArgumentError.value(iv.length, 'iv', 'must be 16 bytes');
    }
    _prev.setAll(0, iv);
  }

  final Aes _cipher;
  final Uint8List _prev;
  final Uint8List _block = Uint8List(16);

  /// Decrypts `data[start..end)` in place; the length must be a multiple
  /// of 16.
  void decryptInPlace(Uint8List data, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, data.length);
    if ((stop - start) % 16 != 0) {
      throw ArgumentError('CBC input must be a multiple of 16 bytes');
    }
    final prev = _prev;
    final block = _block;
    for (var i = start; i < stop; i += 16) {
      block.setRange(0, 16, data, i); // save ciphertext for the next chain
      _cipher.decryptBlock(data, i, data, i);
      for (var j = 0; j < 16; j++) {
        data[i + j] ^= prev[j];
      }
      prev.setAll(0, block);
    }
  }
}

/// AES-CBC encryption. Present for the primitives' round-trip tests and
/// the RAR4 fixture builder (P3-5); the write-side archive encryption
/// that would use it in production is deferred (`doc/encryption-scope.md`).
final class AesCbcEncryptor {
  /// Creates an encryptor over [cipher] starting from [iv] (16 bytes).
  AesCbcEncryptor(this._cipher, Uint8List iv) : _prev = Uint8List(16) {
    if (iv.length != 16) {
      throw ArgumentError.value(iv.length, 'iv', 'must be 16 bytes');
    }
    _prev.setAll(0, iv);
  }

  final Aes _cipher;
  final Uint8List _prev;

  /// Encrypts `data[start..end)` in place; the length must be a multiple
  /// of 16.
  void encryptInPlace(Uint8List data, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, data.length);
    if ((stop - start) % 16 != 0) {
      throw ArgumentError('CBC input must be a multiple of 16 bytes');
    }
    final prev = _prev;
    for (var i = start; i < stop; i += 16) {
      for (var j = 0; j < 16; j++) {
        data[i + j] ^= prev[j];
      }
      _cipher.encryptBlock(data, i, data, i);
      prev.setRange(0, 16, data, i);
    }
  }
}

/// The WinZip AES variant of CTR mode: the 16-byte counter block is a
/// **little-endian** integer starting at 1, with no nonce — not the
/// big-endian layout of SP 800-38A. XORing the keystream is its own
/// inverse, so one class serves encrypt and decrypt.
///
/// Byte-granular: chunk boundaries need not align to 16, matching ZIP's
/// streaming reads.
final class AesCtrLeStream {
  /// Creates the keystream over [cipher], counter starting at 1.
  AesCtrLeStream(this._cipher) {
    _counter[0] = 1;
  }

  final Aes _cipher;
  final Uint8List _counter = Uint8List(16);
  final Uint8List _keystream = Uint8List(16);
  int _used = 16; // Position within the current keystream block.

  /// XORs the keystream over `data[start..end)` in place.
  void processInPlace(Uint8List data, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, data.length);
    for (var i = start; i < stop; i++) {
      if (_used == 16) {
        _cipher.encryptBlock(_counter, 0, _keystream, 0);
        _used = 0;
        // Little-endian increment for the *next* block.
        for (var j = 0; j < 16; j++) {
          _counter[j] = (_counter[j] + 1) & 0xFF;
          if (_counter[j] != 0) break;
        }
      }
      data[i] ^= _keystream[_used++];
    }
  }
}

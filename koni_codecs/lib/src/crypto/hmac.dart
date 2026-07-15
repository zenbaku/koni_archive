import 'dart:typed_data';

import 'block_hash.dart';
import 'sha1.dart';
import 'sha256.dart';

/// HMAC (RFC 2104) over a SHA-family hash.
///
/// The keyed inner/outer pad states are compressed once at construction
/// and snapshotted per message, so authenticating many messages under one
/// key — PBKDF2's inner loop, WinZip AE streams — costs two compression
/// calls per message beyond the data itself.
///
/// Usage per message: [add] chunks, then [finish]; [reset] rearms the same
/// key for the next message.
final class Hmac {
  /// HMAC-SHA1 with [key] (any length; longer than 64 bytes is hashed
  /// first, per RFC 2104).
  Hmac.sha1(Uint8List key) : this._(Sha1.new, key, 20);

  /// HMAC-SHA256 with [key] (any length).
  Hmac.sha256(Uint8List key) : this._(Sha256.new, key, 32);

  Hmac._(BlockHash Function() createHash, Uint8List key, this.digestSize) {
    var normalizedKey = key;
    if (normalizedKey.length > BlockHash.blockSize) {
      normalizedKey = (createHash()..add(normalizedKey)).finish();
    }
    final pad = Uint8List(BlockHash.blockSize);
    for (var i = 0; i < BlockHash.blockSize; i++) {
      pad[i] = (i < normalizedKey.length ? normalizedKey[i] : 0) ^ 0x36;
    }
    _innerInit = createHash()..add(pad);
    for (var i = 0; i < BlockHash.blockSize; i++) {
      pad[i] ^= 0x36 ^ 0x5C;
    }
    _outerInit = createHash()..add(pad);
    _inner = _innerInit.copy();
  }

  /// MAC length in bytes (the underlying hash's digest size).
  final int digestSize;

  late final BlockHash _innerInit;
  late final BlockHash _outerInit;
  late BlockHash _inner;

  /// Updates the current message with `chunk[start..end)`.
  void add(Uint8List chunk, [int start = 0, int? end]) =>
      _inner.add(chunk, start, end);

  /// Completes the current message and returns its MAC. Call [reset]
  /// before authenticating another message.
  Uint8List finish() {
    final innerDigest = _inner.finish();
    return (_outerInit.copy()..add(innerDigest)).finish();
  }

  /// Rearms the MAC (same key) for a new message.
  void reset() => _inner = _innerInit.copy();

  /// Computes the MAC of [data] in one call (and rearms for the next
  /// message).
  Uint8List compute(Uint8List data) {
    reset();
    add(data);
    return finish();
  }
}

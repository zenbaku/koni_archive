import 'dart:typed_data';

import 'hmac.dart';

/// PBKDF2 (RFC 8018 §5.2) over an [Hmac] PRF.
///
/// Derives [length] bytes from the already-keyed [prf], [salt], and
/// [iterations]. Used by WinZip AES (HMAC-SHA1, 1000 iterations) and RAR5
/// (HMAC-SHA256, `2^count` iterations); the iterated-SHA KDFs of 7z and
/// RAR4 are *not* PBKDF2 and live with their formats.
///
/// The [prf] is consumed (rearmed internally between blocks); it remains
/// usable afterwards via its own `reset`.
Uint8List pbkdf2(Hmac prf, Uint8List salt, int iterations, int length) {
  if (iterations < 1) {
    throw ArgumentError.value(iterations, 'iterations', 'must be >= 1');
  }
  final digestSize = prf.digestSize;
  final blocks = (length + digestSize - 1) ~/ digestSize;
  final out = Uint8List(blocks * digestSize);
  final counter = Uint8List(4);
  for (var block = 1; block <= blocks; block++) {
    counter[0] = block >>> 24;
    counter[1] = (block >>> 16) & 0xFF;
    counter[2] = (block >>> 8) & 0xFF;
    counter[3] = block & 0xFF;
    prf.reset();
    prf.add(salt);
    prf.add(counter);
    var u = prf.finish();
    final accumulated = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      prf.reset();
      prf.add(u);
      u = prf.finish();
      for (var j = 0; j < digestSize; j++) {
        accumulated[j] ^= u[j];
      }
    }
    out.setRange((block - 1) * digestSize, block * digestSize, accumulated);
  }
  return Uint8List.sublistView(out, 0, length);
}

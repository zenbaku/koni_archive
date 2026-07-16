import 'dart:typed_data';

/// Incremental CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), the
/// checksum used by ZIP and gzip.
///
/// Feed data in chunks with [add]; [value] is non-destructive, so a
/// streaming reader can verify at end-of-stream without copying. All
/// arithmetic stays within unsigned 32-bit range, which dart2js models
/// exactly.
final class Crc32 {
  /// Creates a checksum in its initial state.
  Crc32();

  // Slicing-by-8 (Intel's technique): eight derived tables let the hot
  // loop fold 8 input bytes per iteration instead of 1 (checksum
  // verification is on the default read path of ZIP and gzip).
  static final Uint32List _tables = _buildTables();

  static Uint32List _buildTables() {
    final tables = Uint32List(256 * 8);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      tables[i] = c;
    }
    for (var slice = 1; slice < 8; slice++) {
      for (var i = 0; i < 256; i++) {
        final prev = tables[(slice - 1) * 256 + i];
        tables[slice * 256 + i] = tables[prev & 0xFF] ^ (prev >>> 8);
      }
    }
    return tables;
  }

  int _crc = 0xFFFFFFFF;

  /// Updates the checksum with `chunk[start..end)`.
  void add(Uint8List chunk, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, chunk.length);
    final t = _tables;
    var crc = _crc;
    var i = start;
    for (final fast = stop - 7; i < fast; i += 8) {
      final low =
          (crc ^
              (chunk[i] |
                  (chunk[i + 1] << 8) |
                  (chunk[i + 2] << 16) |
                  (chunk[i + 3] << 24))) &
          0xFFFFFFFF;
      final high =
          chunk[i + 4] |
          (chunk[i + 5] << 8) |
          (chunk[i + 6] << 16) |
          (chunk[i + 7] << 24);
      crc =
          t[0x700 + (low & 0xFF)] ^
          t[0x600 + ((low >>> 8) & 0xFF)] ^
          t[0x500 + ((low >>> 16) & 0xFF)] ^
          t[0x400 + (low >>> 24)] ^
          t[0x300 + (high & 0xFF)] ^
          t[0x200 + ((high >>> 8) & 0xFF)] ^
          t[0x100 + ((high >>> 16) & 0xFF)] ^
          t[high >>> 24];
    }
    for (; i < stop; i++) {
      crc = t[(crc ^ chunk[i]) & 0xFF] ^ (crc >>> 8);
    }
    _crc = crc;
  }

  /// The CRC-32 of all bytes added so far (an unsigned 32-bit value).
  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  /// Resets to the initial state.
  void reset() => _crc = 0xFFFFFFFF;

  /// Computes the CRC-32 of [data] in one call.
  static int compute(Uint8List data) => (Crc32()..add(data)).value;
}

/// Incremental Adler-32 (RFC 1950), the checksum used by zlib streams.
///
/// Same usage model as [Crc32].
final class Adler32 {
  /// Creates a checksum in its initial state.
  Adler32();

  // Largest n such that 255n(n+1)/2 + (n+1)(65520) stays below 2^32,
  // allowing the modulo to be deferred across a whole block (zlib's NMAX).
  static const int _nmax = 5552;
  static const int _mod = 65521;

  int _a = 1;
  int _b = 0;

  /// Updates the checksum with `chunk[start..end)`.
  void add(Uint8List chunk, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, chunk.length);
    var a = _a;
    var b = _b;
    var i = start;
    while (i < stop) {
      final blockEnd = (i + _nmax < stop) ? i + _nmax : stop;
      for (; i < blockEnd; i++) {
        a += chunk[i];
        b += a;
      }
      a %= _mod;
      b %= _mod;
    }
    _a = a;
    _b = b;
  }

  /// The Adler-32 of all bytes added so far (an unsigned 32-bit value).
  int get value => (_b << 16) | _a;

  /// Resets to the initial state.
  void reset() {
    _a = 1;
    _b = 0;
  }

  /// Computes the Adler-32 of [data] in one call.
  static int compute(Uint8List data) => (Adler32()..add(data)).value;
}

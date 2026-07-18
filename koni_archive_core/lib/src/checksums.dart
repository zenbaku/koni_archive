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

  /// The CRC-32 as four **little-endian** bytes — the on-the-wire form ZIP,
  /// gzip, and xz store, handy when hand-building an archive (or a deliberately
  /// broken one) for tests. Big-endian formats (e.g. PNG) should serialize
  /// [value] themselves.
  Uint8List get bytes {
    final v = value;
    return Uint8List.fromList([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);
  }

  /// Resets to the initial state.
  void reset() => _crc = 0xFFFFFFFF;

  /// Computes the CRC-32 of [data] in one call.
  static int compute(Uint8List data) => (Crc32()..add(data)).value;

  /// Computes the CRC-32 of [data] as four little-endian [bytes] in one call.
  static Uint8List computeBytes(Uint8List data) => (Crc32()..add(data)).bytes;
}

/// Incremental CRC-64 (the `CRC-64/XZ` parameters: polynomial
/// 0x42F0E1EBA9EA3693, reflected, init and final-xor all-ones), the default
/// integrity check in the `.xz` container.
///
/// A 64-bit value is held in two 32-bit lanes ([_hi], [_lo]) and every step
/// stays within unsigned 32-bit range, the same discipline as [Crc32]: a
/// native-`int` `crc >>> 8` on a 64-bit value would silently truncate under
/// dart2js (JS numbers give only 32-bit bitwise ops), so this never forms a
/// 64-bit `int`. Verify lane-wise against the stored little-endian bytes with
/// [low] and [high] rather than materializing the value.
final class Crc64 {
  /// Creates a checksum in its initial state.
  Crc64();

  // Reflected byte table, split into two 32-bit lanes so the fold never
  // needs a >32-bit shift.
  static final Uint32List _tableHi = _buildTables().$1;
  static final Uint32List _tableLo = _buildTables().$2;

  static (Uint32List, Uint32List) _buildTables() {
    // Reflected polynomial: bit-reverse of 0x42F0E1EBA9EA3693.
    const polyHi = 0xC96C5795;
    const polyLo = 0xD7870F42;
    final hi = Uint32List(256);
    final lo = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var cHi = 0;
      var cLo = n;
      for (var k = 0; k < 8; k++) {
        final lowBit = cLo & 1;
        // crc >>= 1 across the two lanes.
        cLo = ((cLo >>> 1) | ((cHi & 1) << 31)) & 0xFFFFFFFF;
        cHi = cHi >>> 1;
        if (lowBit != 0) {
          cHi ^= polyHi;
          cLo ^= polyLo;
        }
      }
      hi[n] = cHi;
      lo[n] = cLo;
    }
    return (hi, lo);
  }

  int _hi = 0xFFFFFFFF;
  int _lo = 0xFFFFFFFF;

  /// Updates the checksum with `chunk[start..end)`.
  void add(Uint8List chunk, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, chunk.length);
    final tHi = _tableHi;
    final tLo = _tableLo;
    var hi = _hi;
    var lo = _lo;
    for (var i = start; i < stop; i++) {
      final index = (lo ^ chunk[i]) & 0xFF;
      // crc = table[index] ^ (crc >>> 8), lane by lane.
      final shiftedLo = ((lo >>> 8) | ((hi & 0xFF) << 24)) & 0xFFFFFFFF;
      final shiftedHi = hi >>> 8;
      lo = shiftedLo ^ tLo[index];
      hi = shiftedHi ^ tHi[index];
    }
    _hi = hi;
    _lo = lo;
  }

  /// Low 32 bits of the CRC-64 of all bytes added so far, post final-xor.
  /// These are the first four (little-endian) bytes of the stored check.
  int get low => (_lo ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  /// High 32 bits of the CRC-64 of all bytes added so far, post final-xor.
  /// These are the last four (little-endian) bytes of the stored check.
  int get high => (_hi ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  /// The CRC-64 as eight **little-endian** bytes (the low 32 bits then the high
  /// 32 bits) — the on-the-wire form the `.xz` container stores, handy when
  /// hand-building an archive (or a deliberately broken one) for tests. Use
  /// [low]/[high] for lane-wise comparison without allocating.
  Uint8List get bytes {
    final lo = low;
    final hi = high;
    return Uint8List.fromList([
      lo & 0xFF,
      (lo >> 8) & 0xFF,
      (lo >> 16) & 0xFF,
      (lo >> 24) & 0xFF,
      hi & 0xFF,
      (hi >> 8) & 0xFF,
      (hi >> 16) & 0xFF,
      (hi >> 24) & 0xFF,
    ]);
  }

  /// Resets to the initial state.
  void reset() {
    _hi = 0xFFFFFFFF;
    _lo = 0xFFFFFFFF;
  }

  /// Computes the CRC-64 of [data] as eight little-endian [bytes] in one call.
  static Uint8List computeBytes(Uint8List data) => (Crc64()..add(data)).bytes;
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

import 'dart:typed_data';

/// Least-significant-bit-first bit cursor over a byte buffer, the bit order
/// DEFLATE (RFC 1951) uses.
///
/// Codecs are archive-agnostic, so on malformed input this class
/// throws [FormatException] (the `dart:convert` idiom) and the archive
/// layer translates that into its typed exception hierarchy.
final class BitReader {
  /// Creates a reader over `bytes[start..end)`, positioned at the first
  /// bit (bit 0 of `bytes[start]`).
  BitReader(Uint8List bytes, {int start = 0, int? end})
    : _bytes = bytes,
      _end = RangeError.checkValidRange(start, end, bytes.length),
      _byteIndex = start;

  final Uint8List _bytes;
  final int _end;

  int _byteIndex;
  // Bits consumed from _bytes[_byteIndex - consumed bytes] accumulate here,
  // low bits first. Invariant: 0 <= _bitCount <= 7 between calls, so
  // (_buffer during readBits) stays < 2^31 for count <= 24: JS-safe.
  int _buffer = 0;
  int _bitCount = 0;

  /// Bits remaining until the end of the buffer.
  int get bitsRemaining => (_end - _byteIndex) * 8 + _bitCount;

  /// Whether every bit has been consumed.
  bool get isAtEnd => bitsRemaining == 0;

  /// Reads [count] bits (0–24), LSB-first: the first bit read is the least
  /// significant bit of the result.
  ///
  /// Throws [FormatException] on over-read: truncated input, in codec
  /// terms.
  int readBits(int count) {
    if (count < 0 || count > 24) {
      throw ArgumentError.value(count, 'count', 'must be 0-24');
    }
    while (_bitCount < count) {
      if (_byteIndex >= _end) {
        throw const FormatException('unexpected end of input in bit stream');
      }
      _buffer |= _bytes[_byteIndex++] << _bitCount;
      _bitCount += 8;
    }
    final value = _buffer & ((1 << count) - 1);
    _buffer >>= count;
    _bitCount -= count;
    return value;
  }

  /// Reads a single bit.
  bool readBit() => readBits(1) != 0;

  /// Discards buffered bits up to the next byte boundary (used by DEFLATE
  /// stored blocks). No-op when already aligned.
  void alignToByte() {
    _buffer >>= _bitCount & 7;
    _bitCount -= _bitCount & 7;
  }

  /// Reads [count] whole bytes; the reader must be byte-aligned.
  ///
  /// Returns a view over the underlying buffer when possible (no copy).
  /// Throws [FormatException] on over-read and [StateError] if unaligned
  /// (programmer error: call [alignToByte] first).
  Uint8List readAlignedBytes(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'must be non-negative');
    }
    if (_bitCount & 7 != 0) {
      throw StateError('readAlignedBytes while not byte-aligned');
    }
    // Buffered whole bytes were already consumed from _bytes; step back.
    final start = _byteIndex - (_bitCount >> 3);
    if (start + count > _end) {
      throw const FormatException('unexpected end of input in bit stream');
    }
    _buffer = 0;
    _bitCount = 0;
    _byteIndex = start + count;
    return Uint8List.sublistView(_bytes, start, start + count);
  }
}

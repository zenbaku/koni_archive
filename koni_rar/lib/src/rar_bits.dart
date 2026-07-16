/// Shared RAR bit-reader and canonical Huffman decoder, used by the method-29
/// (RAR4 v29) and v20 (RAR 2.0/2.6) decoders. Both formats use MSB-first bit
/// order and RAR's `create_code` canonical Huffman assignment (codes in
/// increasing length, then symbol order), so the primitives are identical.
library;

import 'dart:typed_data';

final List<int> _pow2 = List<int>.generate(25, (i) => 1 << i);

/// MSB-first bit reader over a byte buffer (RAR bit order). Reads past the end
/// return zero bits, so a truncated stream degrades to a decode error rather
/// than an out-of-range crash.
final class Bits {
  /// Creates a reader over [_data], positioned at bit 0.
  Bits(this._data);

  final Uint8List _data;
  int _pos = 0; // absolute bit position

  /// Whether at least [n] more bits are available.
  bool has(int n) => _pos + n <= _data.length * 8;

  /// Current absolute bit position.
  int get bitPos => _pos;

  int _byteAt(int i) => i < _data.length ? _data[i] : 0;

  /// Peeks [n] bits (1–16) MSB-first without advancing.
  int peek(int n) {
    final byteIndex = _pos >> 3;
    final bitOffset = _pos & 7;
    var acc = _byteAt(byteIndex);
    acc = acc * 256 + _byteAt(byteIndex + 1);
    acc = acc * 256 + _byteAt(byteIndex + 2);
    // 3 bytes cover bitOffset (≤7) + n (≤16) = ≤23 bits.
    final drop = 24 - bitOffset - n;
    return (acc ~/ _pow2[drop]) % _pow2[n];
  }

  /// Reads and consumes [n] bits (1–16) MSB-first.
  int read(int n) {
    final v = peek(n);
    _pos += n;
    return v;
  }

  /// Advances the position by [n] bits.
  void consume(int n) => _pos += n;

  /// Discards bits up to the next byte boundary.
  void alignToByte() => _pos = (_pos + 7) & ~7;
}

/// Canonical Huffman decoder (RAR's `create_code` order): codes assigned in
/// increasing length, then symbol order, MSB-first. Decodes via a flat lookup
/// table indexed by the next `maxLength` bits.
final class Huffman {
  /// Builds a decoder from the low nibble of each of [count] code [lengths].
  Huffman(Uint8List lengths, int count) {
    var maxLen = 0;
    for (var i = 0; i < count; i++) {
      final l = lengths[i] & 0xF;
      if (l > maxLen) maxLen = l;
    }
    if (maxLen == 0) {
      // Empty code: decode always fails (a valid stream won't use it).
      _maxLength = 1;
      _table = Int32List(2)..fillRange(0, 2, -1);
      return;
    }
    _maxLength = maxLen;
    _table = Int32List(1 << maxLen)..fillRange(0, 1 << maxLen, -1);

    var code = 0;
    for (var len = 1; len <= maxLen; len++) {
      for (var sym = 0; sym < count; sym++) {
        if ((lengths[sym] & 0xF) != len) continue;
        // Fill every table slot whose top `len` bits equal this code. A code
        // beyond 2^len means the lengths over-subscribe the tree — impossible
        // for a valid table, reachable via mutated input.
        if (code >= (1 << len)) {
          throw const FormatException('over-subscribed RAR Huffman table');
        }
        final shift = maxLen - len;
        final base = code << shift;
        final entry = (len << 16) | sym;
        for (var i = 0; i < (1 << shift); i++) {
          _table[base + i] = entry;
        }
        code++;
      }
      code <<= 1;
    }
  }

  late final int _maxLength;
  late final Int32List _table;

  /// Decodes the next symbol from [bits], or throws [FormatException] on an
  /// invalid code.
  int decode(Bits bits) {
    final entry = _table[bits.peek(_maxLength)];
    if (entry < 0) {
      throw const FormatException('invalid RAR Huffman code');
    }
    bits.consume(entry >> 16);
    return entry & 0xFFFF;
  }
}

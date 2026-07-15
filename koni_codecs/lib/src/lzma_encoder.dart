import 'dart:typed_data';

/// LZMA range encoder — the encode-direction mirror of the range coder
/// inside `LzmaDecoder` (§8, P2-4b).
///
/// The bit probabilities, normalization threshold, and adaptation shifts are
/// identical to the decoder's; what the decoder does not have is the **carry
/// machinery**: the encoder's `low` register can overflow into a 33rd bit,
/// which retroactively increments bytes already determined. Pending `0xFF`
/// bytes are therefore counted (`_cacheSize`) rather than emitted, and are
/// materialized — as `0xFF` or, after a carry, `0x00` — only once a
/// non-`0xFF` byte pins them down.
///
/// `low` is manipulated with `%`/`~/` arithmetic (never bitwise) because it
/// exceeds 32 bits: Dart's web bitwise semantics truncate operands to 32
/// bits, which would silently drop the carry. Arithmetic stays exact below
/// 2^53 on the VM, dart2js, and dart2wasm alike.
final class RangeEncoder {
  /// Creates an encoder in the initial state (equivalent to [reset]).
  RangeEncoder();

  // low needs 33 bits (32-bit value + carry); range stays within 32 bits.
  int _low = 0;
  int _range = 0xFFFFFFFF;
  int _cache = 0;
  int _cacheSize = 1;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// Bytes emitted so far, including those still buffered here (but not the
  /// up-to-5 bytes still pending inside the coder until [flush]).
  int get emittedCount => _bytes.length;

  /// Returns to the initial state, dropping any buffered output (an LZMA2
  /// wrapper starts a fresh range-coded unit per chunk).
  void reset() {
    _low = 0;
    _range = 0xFFFFFFFF;
    _cache = 0;
    _cacheSize = 1;
    _bytes.clear();
  }

  /// Encodes [bit] under `probs[index]`, adapting the probability exactly
  /// like the decoder does (lockstep model updates).
  void encodeBit(Uint16List probs, int index, int bit) {
    final prob = probs[index];
    final bound = (_range >>> 11) * prob;
    if (bit == 0) {
      _range = bound;
      probs[index] = prob + ((2048 - prob) >> 5);
    } else {
      _low += bound;
      _range -= bound;
      probs[index] = prob - (prob >> 5);
    }
    if (_range < 0x1000000) {
      _range *= 256;
      _shiftLow();
    }
  }

  /// Encodes the low [count] bits of [value], MSB first, at fixed
  /// probability 1/2 (the decoder's `_directBits`).
  void encodeDirectBits(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _range >>>= 1;
      if ((value >> i) & 1 != 0) _low += _range;
      if (_range < 0x1000000) {
        _range *= 256;
        _shiftLow();
      }
    }
  }

  /// Encodes [symbol] as [numBits] bits, MSB first, through a bit-tree at
  /// `probs[offset..]` (the decoder's `_tree`).
  void encodeTree(Uint16List probs, int offset, int numBits, int symbol) {
    var m = 1;
    for (var i = numBits - 1; i >= 0; i--) {
      final bit = (symbol >> i) & 1;
      encodeBit(probs, offset + m, bit);
      m = (m << 1) | bit;
    }
  }

  /// Encodes [symbol] as [numBits] bits, LSB first, through a reverse
  /// bit-tree at `probs[offset..]` (the decoder's `_treeReverse`).
  void encodeTreeReverse(Uint16List probs, int offset, int numBits, int symbol) {
    var m = 1;
    var rest = symbol;
    for (var i = 0; i < numBits; i++) {
      final bit = rest & 1;
      rest >>= 1;
      encodeBit(probs, offset + m, bit);
      m = (m << 1) | bit;
    }
  }

  /// Flushes the 5 bytes still pending inside the coder. The stream is
  /// complete only after this; the encoder must be [reset] to be reused.
  void flush() {
    for (var i = 0; i < 5; i++) {
      _shiftLow();
    }
  }

  /// Hands all buffered output bytes to [onOutput] (cleared afterwards).
  void drain(void Function(Uint8List chunk) onOutput) {
    if (_bytes.length > 0) onOutput(_bytes.takeBytes());
  }

  void _shiftLow() {
    final low32 = _low % 0x100000000;
    final carry = _low ~/ 0x100000000; // 0 or 1
    if (low32 < 0xFF000000 || carry != 0) {
      _bytes.addByte((_cache + carry) & 0xFF);
      for (var i = 1; i < _cacheSize; i++) {
        _bytes.addByte((0xFF + carry) & 0xFF); // carried 0xFF run becomes 0x00
      }
      _cacheSize = 0;
      _cache = low32 ~/ 0x1000000; // bits 24–31 become the new pending byte
    }
    _cacheSize++;
    _low = (low32 % 0x1000000) * 256;
  }
}

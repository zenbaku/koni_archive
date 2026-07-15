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

/// LZMA compression — the encode direction of `LzmaDecoder` (§8, P2-4b).
///
/// Buffer-based like the decoder, whose output buffer doubles as the match
/// window: here the caller provides the entire input up front and it doubles
/// as the dictionary. One-shot: `LzmaEncoder().encode(data)`.
///
/// The probability-model layout and context computation are identical to the
/// decoder's; the two stay in lockstep by construction. Any literal/match
/// token choice therefore decodes correctly — parsing quality (this
/// milestone: literals only; match finding lands next) affects only ratio,
/// never validity.
///
/// The produced stream has no end marker: archive containers record exact
/// sizes, and LZMA decoders (ours, liblzma, 7zz) stop on the declared output
/// size.
final class LzmaEncoder {
  /// Creates an encoder with the given LZMA properties.
  ///
  /// Defaults are the universal `lc=3, lp=0, pb=2` (props byte 0x5D).
  /// [dictSize] is the dictionary size *declared* to decoders; match
  /// distances never exceed it. liblzma additionally requires
  /// `lc + lp <= 4`, so that is enforced here too.
  LzmaEncoder({this.lc = 3, this.lp = 0, this.pb = 2, this.dictSize = 1 << 23})
    : _lpMask = (1 << lp) - 1,
      _pbMask = (1 << pb) - 1 {
    if (lc < 0 || lc > 8 || lp < 0 || lp > 4 || pb < 0 || pb > 4 || lc + lp > 4) {
      throw ArgumentError('invalid LZMA properties lc=$lc lp=$lp pb=$pb');
    }
    if (dictSize < (1 << 12) || dictSize > (1 << 30)) {
      throw ArgumentError.value(
        dictSize,
        'dictSize',
        'must be in [4 KiB, 1 GiB]',
      );
    }
    _literal = Uint16List(0x300 << (lc + lp));
  }

  /// Literal-context bits (high bits of the previous byte used as context).
  final int lc;

  /// Literal-position bits.
  final int lp;

  /// Position bits (low bits of the position used as match context).
  final int pb;

  /// Declared dictionary size; an upper bound on match distances.
  final int dictSize;

  final int _lpMask;
  final int _pbMask;

  /// The packed properties byte, `(pb * 5 + lp) * 9 + lc`.
  int get propsByte => (pb * 5 + lp) * 9 + lc;

  /// The 5-byte 7z coder attribute blob: properties byte + dictionary size.
  Uint8List sevenZipProps() {
    final props = Uint8List(5);
    props[0] = propsByte;
    var d = dictSize;
    for (var i = 1; i < 5; i++) {
      props[i] = d % 256;
      d = d ~/ 256;
    }
    return props;
  }

  // ---- probability model (identical layout to LzmaDecoder's) ----
  static const int _probInit = 1024;

  final Uint16List _isMatch = Uint16List(12 << 4);
  final Uint16List _isRep = Uint16List(12);
  final Uint16List _isRepG0 = Uint16List(12);
  final Uint16List _isRepG1 = Uint16List(12);
  final Uint16List _isRepG2 = Uint16List(12);
  final Uint16List _isRep0Long = Uint16List(12 << 4);
  final Uint16List _posSlot = Uint16List(4 * 64);
  final Uint16List _specPos = Uint16List(115);
  final Uint16List _align = Uint16List(16);
  late Uint16List _literal;
  final Uint16List _lenProbs = Uint16List(2 + 16 * 8 + 16 * 8 + 256);
  final Uint16List _repLenProbs = Uint16List(2 + 16 * 8 + 16 * 8 + 256);

  int _state = 0;
  // rep1..rep3 arrive with rep-match encoding; literals only read rep0.
  int _rep0 = 0;

  final RangeEncoder _rc = RangeEncoder();

  Uint8List _data = Uint8List(0);

  void _resetState() {
    for (final probs in [
      _isMatch, _isRep, _isRepG0, _isRepG1, _isRepG2, _isRep0Long, //
      _posSlot, _specPos, _align, _literal, _lenProbs, _repLenProbs,
    ]) {
      probs.fillRange(0, probs.length, _probInit);
    }
    _state = 0;
    _rep0 = 0;
  }

  /// Encodes all of [data] as one raw LZMA stream (one range-coded unit,
  /// exactly what a 7z LZMA1 folder holds).
  Uint8List encode(Uint8List data) {
    _data = data;
    _resetState();
    _rc.reset();
    _encodeRange(0, data.length);
    _rc.flush();
    Uint8List? out;
    _rc.drain((chunk) => out = chunk);
    _data = Uint8List(0);
    return out ?? Uint8List(0);
  }

  // ---- token loop (this milestone: every byte is a literal) ----

  void _encodeRange(int from, int to) {
    for (var pos = from; pos < to; pos++) {
      final posState = pos & _pbMask;
      _rc.encodeBit(_isMatch, (_state << 4) + posState, 0);
      _encodeLiteral(pos);
    }
  }

  /// Mirrors the decoder's `_decodeLiteral`, including the matched-literal
  /// mode after matches (state >= 7), where bits are coded against the byte
  /// at distance rep0 until the first divergence.
  void _encodeLiteral(int pos) {
    final prevByte = pos > 0 ? _data[pos - 1] : 0;
    final litState = ((pos & _lpMask) << lc) + (prevByte >> (8 - lc));
    final offset = 0x300 * litState;
    final symbol = _data[pos];

    var m = 1;
    var i = 7;
    if (_state >= 7) {
      var matchByte = _data[pos - _rep0 - 1];
      while (i >= 0) {
        final matchBit = (matchByte >> 7) & 1;
        matchByte = (matchByte << 1) & 0xFF;
        final bit = (symbol >> i) & 1;
        _rc.encodeBit(_literal, offset + ((1 + matchBit) << 8) + m, bit);
        m = (m << 1) | bit;
        i--;
        if (matchBit != bit) break;
      }
    }
    while (i >= 0) {
      final bit = (symbol >> i) & 1;
      _rc.encodeBit(_literal, offset + m, bit);
      m = (m << 1) | bit;
      i--;
    }
    _state =
        _state < 4
            ? 0
            : _state < 10
            ? _state - 3
            : _state - 6;
  }
}

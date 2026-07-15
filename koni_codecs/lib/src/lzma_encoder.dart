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

  /// Upper bound on the bytes [flush] would still emit (the cached byte,
  /// any pending 0xFF run, and the low register). Lets a framing layer
  /// budget a chunk's packed size before flushing.
  int get pendingCount => _cacheSize + 4;

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
/// as the dictionary. One-shot: `LzmaEncoder().encode(data)`. Memory: the
/// hash-chain match finder keeps one 32-bit slot per input byte.
///
/// The probability-model layout and context computation are identical to the
/// decoder's; the two stay in lockstep by construction. Any literal/match
/// token choice therefore decodes correctly — parsing quality (greedy
/// hash-chain matching, the deflate approach rebuilt for LZMA's window;
/// 7zz's optimal-price parser is a deferred ratio lever) affects only ratio,
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
  int _rep0 = 0;
  int _rep1 = 0;
  int _rep2 = 0;
  int _rep3 = 0;

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
    _rep0 = _rep1 = _rep2 = _rep3 = 0;
  }

  /// Encodes all of [data] as one raw LZMA stream (one range-coded unit,
  /// exactly what a 7z LZMA1 folder holds).
  Uint8List encode(Uint8List data) {
    bind(data);
    _encodeRange(0, data.length, packLimit: _noPackLimit);
    final out = takeChunk();
    _bindData(_emptyData);
    return out;
  }

  // ---- chunk-wise API (the encode mirror of LzmaDecoder's, driven by
  // Lzma2Encoder the way Lzma2Decoder drives the decoder) ----

  /// Binds [data] as the input buffer and dictionary for chunk-wise
  /// encoding, resetting the model, match finder, and range coder.
  void bind(Uint8List data) {
    _bindData(data);
    _cachedValid = false;
    resetState();
    _rc.reset();
  }

  /// Resets the probability model, state, and rep distances — an LZMA2
  /// "state reset". The match-finder chains are untouched: they follow the
  /// data, not the model.
  void resetState() => _resetState();

  /// Encodes `data[from..to)` as one range-coded unit, stopping at a symbol
  /// boundary once the packed output approaches [packLimit] bytes. Returns
  /// the position actually reached — up to 272 bytes past [to] when the
  /// final match runs long; the caller declares whatever was reached.
  /// Finish the unit with [takeChunk].
  int encodeChunk(int from, int to, {required int packLimit}) =>
      _encodeRange(from, to, packLimit: packLimit);

  /// Flushes the current range-coded unit and returns its bytes, resetting
  /// the range coder for the next chunk (model and finder keep going).
  Uint8List takeChunk() {
    _rc.flush();
    Uint8List? out;
    _rc.drain((chunk) => out = chunk);
    _rc.reset();
    return out ?? Uint8List(0);
  }

  // ---- match finder: hash chains over the whole buffer ----
  //
  // The deflate finder's idea (head table + prev links), rebuilt for LZMA:
  // 4-byte hash, distances capped by dictSize instead of 32 KiB, matches up
  // to 273 bytes. Hash mixing uses only arithmetic that is exact and
  // identical on the VM, dart2js, and dart2wasm (no products above 2^53, no
  // bitwise ops on values at or above 2^32), so the compressed output is
  // byte-identical on every platform.

  static const int _minMatch = 4; // chain matches; reps go shorter
  static const int _maxMatch = 273;
  static const int _maxChain = 48; // search depth (ratio vs speed)
  static const int _niceLen = 64; // stop searching once this long
  static const int _hashBits = 17;

  static final Uint8List _emptyData = Uint8List(0);
  static final Int32List _emptyChain = Int32List(0);

  final Int32List _head = Int32List(1 << _hashBits);
  Int32List _prev = _emptyChain;
  int _dataEnd = 0;

  // Best match found by _findMatch (wire distance = _matchDist - 1).
  int _matchLen = 0;
  int _matchDist = 0;

  void _bindData(Uint8List data) {
    _data = data;
    _dataEnd = data.length;
    _head.fillRange(0, _head.length, -1);
    _prev = data.isEmpty ? _emptyChain : Int32List(data.length);
  }

  int _hash4(int i) {
    final d = _data;
    final x = d[i] + (d[i + 1] << 8) + (d[i + 2] << 16) + d[i + 3] * 0x1000000;
    final lo = x & 0xFFFF;
    final hi = x >>> 16;
    // lo * 40503 < 2^32 and the sum < 2^33; the final mask only keeps low
    // bits, which agree across platforms.
    return (lo * 40503 + hi * 27469) & ((1 << _hashBits) - 1);
  }

  /// Longest match ending the chain walk early at [_niceLen]; candidates
  /// arrive nearest-first, so the first hit at any length is also the
  /// shortest distance for that length. Inserts [pos] into the chain.
  /// Returns true when a match of at least [_minMatch] was found.
  bool _findMatch(int pos) {
    _matchLen = 0;
    if (pos + _minMatch > _dataEnd) {
      return false; // too close to the end even to hash
    }
    final maxLen =
        _dataEnd - pos < _maxMatch ? _dataEnd - pos : _maxMatch;
    final h = _hash4(pos);
    var candidate = _head[h];
    assert(
      candidate != pos,
      'position $pos inserted twice — lookahead cache not honored',
    );
    _prev[pos] = candidate;
    _head[h] = pos;

    final minPos = pos - dictSize > 0 ? pos - dictSize : 0;
    var bestLen = _minMatch - 1; // only lengths >= _minMatch can win
    var bestDist = 0;
    var chain = _maxChain;
    final data = _data;
    while (candidate >= minPos && chain-- > 0) {
      // Quick reject: a longer match must improve on byte [bestLen].
      if (data[candidate + bestLen] == data[pos + bestLen]) {
        var len = 0;
        while (len < maxLen && data[candidate + len] == data[pos + len]) {
          len++;
        }
        if (len > bestLen) {
          bestLen = len;
          bestDist = pos - candidate;
          if (len >= _niceLen || len == maxLen) break;
        }
      }
      candidate = _prev[candidate];
    }
    if (bestLen < _minMatch) return false;
    _matchLen = bestLen;
    _matchDist = bestDist;
    return true;
  }

  /// Inserts positions `[from, to)` into the hash chains (bytes covered by
  /// an emitted match still become future match candidates).
  void _insertRange(int from, int to) {
    final last = _dataEnd - _minMatch;
    final end = to < last + 1 ? to : last + 1;
    for (var i = from; i < end; i++) {
      final h = _hash4(i);
      _prev[i] = _head[h];
      _head[h] = i;
    }
  }

  // ---- token loop: greedy + rep preference + one-step lazy ----
  //
  // The decision shape of 7-Zip's fast mode (LzmaEnc's GetOptimumFast):
  // prefer a rep match when it is nearly as long as the chain match (reps
  // cost a few bits, new distances cost dozens); before committing to a
  // chain match, peek one position ahead and emit a literal instead when
  // the next position offers a decisively better match. Heuristic only —
  // every outcome is valid LZMA.

  /// Best rep-distance match at the scan position (0 when none).
  int _repLen = 0;
  int _repIndex = 0;

  // One-step lookahead cache: a lazy probe at pos+1 both finds and inserts,
  // so when the literal is taken, the probed match is reused at the next
  // iteration instead of re-searched (re-searching would insert the
  // position into its hash chain twice, corrupting it). A field, not a
  // loop local: a chunk boundary can fall right after a deferred literal.
  bool _cachedValid = false;
  int _cachedLen = 0;
  int _cachedDist = 0;

  /// A packLimit no chunk can hit (LZMA2's real one is 64 KiB). A literal,
  /// not `1 << 50`: dart2js shifts operate on 32 bits and evaluate that to
  /// zero — which would silence every stream to its 5 flush bytes.
  static const int _noPackLimit = 0x4000000000000; // 2^50

  /// Headroom kept below the pack limit: one symbol emits at most ~48 bits,
  /// so stopping 64 bytes early can never overshoot.
  static const int _packMargin = 64;

  int _encodeRange(int from, int to, {required int packLimit}) {
    var pos = from;

    while (pos < to) {
      if (_rc.emittedCount + _rc.pendingCount + _packMargin > packLimit) {
        break;
      }
      final posState = pos & _pbMask;

      int mainLen;
      int mainDist;
      if (_cachedValid) {
        mainLen = _cachedLen;
        mainDist = _cachedDist;
        _cachedValid = false;
      } else {
        mainLen = _findMatch(pos) ? _matchLen : 0;
        mainDist = _matchDist;
      }
      _scanReps(pos, to);

      // A rep nearly as long as the chain match wins: its distance is
      // (almost) free, while a new distance costs up to ~30 bits more.
      final repWins =
          _repLen >= 2 &&
          (_repLen + 1 >= mainLen ||
              (_repLen + 2 >= mainLen && mainDist >= (1 << 9)) ||
              (_repLen + 3 >= mainLen && mainDist >= (1 << 15)));
      if (repWins) {
        final len = _repLen;
        _encodeRep(posState, len, _repIndex);
        _insertRange(pos + 1, pos + len);
        pos += len;
        continue;
      }

      if (mainLen < _minMatch) {
        _rc.encodeBit(_isMatch, (_state << 4) + posState, 0);
        _encodeLiteral(pos);
        pos++;
        continue;
      }

      // Lazy step: probe pos+1; a decisively better match there means the
      // byte at pos goes out as a literal.
      if (mainLen < _niceLen && pos + 1 < to) {
        final nextLen = _findMatch(pos + 1) ? _matchLen : 0;
        final nextDist = _matchDist;
        var defer =
            nextLen >= 2 &&
            ((nextLen >= mainLen && nextDist < mainDist) ||
                (nextLen == mainLen + 1 && !_changePair(mainDist, nextDist)) ||
                nextLen > mainLen + 1 ||
                (nextLen + 1 >= mainLen &&
                    mainLen >= 3 &&
                    _changePair(nextDist, mainDist)));
        if (!defer) {
          // A rep at pos+1 almost as long as the chain match here also
          // makes the literal worthwhile: the rep next costs far less.
          _scanReps(pos + 1, to);
          defer = _repLen + 2 >= mainLen && _repLen >= 2;
        }
        if (defer) {
          _rc.encodeBit(_isMatch, (_state << 4) + posState, 0);
          _encodeLiteral(pos);
          pos++;
          _cachedValid = true;
          _cachedLen = nextLen;
          _cachedDist = nextDist;
          continue;
        }
        // Committing to the match at pos: pos+1 is already inserted by
        // the probe.
        _encodeMatch(posState, mainLen, mainDist - 1);
        _insertRange(pos + 2, pos + mainLen);
        pos += mainLen;
        continue;
      }

      _encodeMatch(posState, mainLen, mainDist - 1);
      _insertRange(pos + 1, pos + mainLen);
      pos += mainLen;
    }
    return pos;
  }

  /// Whether switching from a match at [smallDist] to one at [bigDist] is
  /// too expensive to be worth one extra byte (LzmaEnc's ChangePair).
  static bool _changePair(int smallDist, int bigDist) =>
      (bigDist >> 7) > smallDist;

  /// Finds the longest match at any of the four rep distances at [pos]
  /// (results in [_repLen]/[_repIndex]; length 0 when none reaches 2).
  void _scanReps(int pos, int to) {
    _repLen = 0;
    final maxLen = to - pos < _maxMatch ? to - pos : _maxMatch;
    if (maxLen < 2) return;
    final data = _data;
    for (var k = 0; k < 4; k++) {
      final dist =
          (k == 0
              ? _rep0
              : k == 1
              ? _rep1
              : k == 2
              ? _rep2
              : _rep3) +
          1;
      if (dist > pos) continue;
      final from = pos - dist;
      if (data[from] != data[pos] || data[from + 1] != data[pos + 1]) {
        continue;
      }
      var len = 2;
      while (len < maxLen && data[from + len] == data[pos + len]) {
        len++;
      }
      if (len > _repLen) {
        _repLen = len;
        _repIndex = k;
        if (len >= _niceLen || len == maxLen) return;
      }
    }
  }

  /// Encodes a rep match — the decoder's rep branch in reverse, including
  /// the rep-distance list rotation.
  void _encodeRep(int posState, int len, int index) {
    _rc.encodeBit(_isMatch, (_state << 4) + posState, 1);
    _rc.encodeBit(_isRep, _state, 1);
    if (index == 0) {
      _rc.encodeBit(_isRepG0, _state, 0);
      _rc.encodeBit(_isRep0Long, (_state << 4) + posState, 1);
    } else {
      _rc.encodeBit(_isRepG0, _state, 1);
      if (index == 1) {
        _rc.encodeBit(_isRepG1, _state, 0);
        final dist = _rep1;
        _rep1 = _rep0;
        _rep0 = dist;
      } else if (index == 2) {
        _rc.encodeBit(_isRepG1, _state, 1);
        _rc.encodeBit(_isRepG2, _state, 0);
        final dist = _rep2;
        _rep2 = _rep1;
        _rep1 = _rep0;
        _rep0 = dist;
      } else {
        _rc.encodeBit(_isRepG1, _state, 1);
        _rc.encodeBit(_isRepG2, _state, 1);
        final dist = _rep3;
        _rep3 = _rep2;
        _rep2 = _rep1;
        _rep1 = _rep0;
        _rep0 = dist;
      }
    }
    _encodeLength(_repLenProbs, len, posState);
    _state = _state < 7 ? 8 : 11;
  }

  /// Encodes a simple match (new distance): the decoder's simple-match
  /// branch in reverse. [dist] is the wire distance (real distance - 1).
  void _encodeMatch(int posState, int len, int dist) {
    _rc.encodeBit(_isMatch, (_state << 4) + posState, 1);
    _rc.encodeBit(_isRep, _state, 0);
    _rep3 = _rep2;
    _rep2 = _rep1;
    _rep1 = _rep0;
    _rep0 = dist;
    _encodeLength(_lenProbs, len, posState);

    final lenState = len - 2 > 3 ? 3 : len - 2;
    final slot = _slotFor(dist);
    _rc.encodeTree(_posSlot, lenState << 6, 6, slot);
    if (slot >= 4) {
      final numDirect = (slot >> 1) - 1;
      final base = (2 | (slot & 1)) << numDirect;
      final footer = dist - base;
      if (slot < 14) {
        _rc.encodeTreeReverse(_specPos, base - slot, numDirect, footer);
      } else {
        _rc.encodeDirectBits(footer >> 4, numDirect - 4);
        _rc.encodeTreeReverse(_align, 0, 4, footer & 15);
      }
    }
    _state = _state < 7 ? 7 : 10;
  }

  /// The position slot whose range contains [dist] (inverse of the
  /// decoder's slot-to-base expansion).
  static int _slotFor(int dist) {
    if (dist < 4) return dist;
    final n = dist.bitLength - 1; // floor(log2)
    return (n << 1) | ((dist >> (n - 1)) & 1);
  }

  /// Encodes a length (2–273) through a length coder's probability block —
  /// the decoder's `_length` in reverse.
  void _encodeLength(Uint16List probs, int len, int posState) {
    final v = len - 2;
    if (v < 8) {
      _rc.encodeBit(probs, 0, 0);
      _rc.encodeTree(probs, 2 + (posState << 3), 3, v);
    } else if (v < 16) {
      _rc.encodeBit(probs, 0, 1);
      _rc.encodeBit(probs, 1, 0);
      _rc.encodeTree(probs, 2 + 128 + (posState << 3), 3, v - 8);
    } else {
      _rc.encodeBit(probs, 0, 1);
      _rc.encodeBit(probs, 1, 1);
      _rc.encodeTree(probs, 2 + 256, 8, v - 16);
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

import 'dart:typed_data';

/// LZMA decompression — the primary 7z codec (§8).
///
/// Implemented from the public-domain LZMA specification (`LzmaSpec.cpp` /
/// `lzma-specification.txt` in the LZMA SDK, Igor Pavlov, public domain).
/// Synchronous and chunk-driven (§6.4): input may arrive split anywhere;
/// decoding suspends at symbol boundaries when fewer than a safety margin
/// of bytes are buffered. Malformed input throws [FormatException].
///
/// Unlike DEFLATE, LZMA in archive containers always has a known output
/// size, so the decoder writes into a caller-provided buffer which doubles
/// as the match window — there is no separate streaming sink. (A
/// `Converter` facade can wrap this when a standalone `.lzma` consumer
/// exists; none does yet, §13.1.)
final class LzmaDecoder {
  /// Creates a decoder writing into `output[0..output.length)`.
  ///
  /// Call [setProps] (or construct via [LzmaDecoder.sevenZip]) before
  /// feeding input.
  LzmaDecoder({required Uint8List output})
    : _output = output,
      _outEnd = output.length;

  /// Creates a decoder for a 7z LZMA coder: [props] is the coder's 5-byte
  /// attribute blob (properties byte + 32-bit dictionary size, which this
  /// buffer-backed decoder does not need).
  factory LzmaDecoder.sevenZip({
    required Uint8List props,
    required Uint8List output,
  }) {
    if (props.isEmpty) {
      throw const FormatException('missing LZMA properties');
    }
    return LzmaDecoder(output: output)..setProps(props[0]);
  }

  // ---- output (doubles as the match window) ----
  final Uint8List _output;
  int _outPos = 0;
  int _outEnd;
  int _dictStart = 0; // position of the last dictionary reset

  /// Decoded bytes so far (write position in the output buffer).
  int get outputPosition => _outPos;

  /// Whether the current chunk's output is complete.
  bool get isChunkComplete => _outPos >= _outEnd || _sawEndMarker;

  bool _sawEndMarker = false;

  // ---- LZMA properties ----
  int _lc = 0;
  int _lp = 0;
  int _pb = 0;
  int _pbMask = 0;
  int _lpMask = 0;

  /// Sets lc/lp/pb from the packed properties byte and (re)allocates the
  /// probability model. Throws [FormatException] for invalid values.
  void setProps(int propsByte) {
    if (propsByte >= 9 * 5 * 5) {
      throw const FormatException('invalid LZMA properties byte');
    }
    var d = propsByte;
    _lc = d % 9;
    d ~/= 9;
    _lp = d % 5;
    _pb = d ~/ 5;
    _pbMask = (1 << _pb) - 1;
    _lpMask = (1 << _lp) - 1;
    _literal = Uint16List(0x300 << (_lc + _lp));
    resetState();
  }

  // ---- probability model (11-bit probabilities, init 2^10) ----
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
  Uint16List _literal = Uint16List(0x300);

  // Length coders: [choice, choice2, low(16*8), mid(16*8), high(256)].
  final Uint16List _lenProbs = Uint16List(2 + 16 * 8 + 16 * 8 + 256);
  final Uint16List _repLenProbs = Uint16List(2 + 16 * 8 + 16 * 8 + 256);

  int _state = 0;
  int _rep0 = 0;
  int _rep1 = 0;
  int _rep2 = 0;
  int _rep3 = 0;

  /// Resets the probability model, state, and rep distances (LZMA2 "state
  /// reset"). Does not touch the dictionary or range coder.
  void resetState() {
    for (final probs in [
      _isMatch, _isRep, _isRepG0, _isRepG1, _isRepG2, _isRep0Long, //
      _posSlot, _specPos, _align, _literal, _lenProbs, _repLenProbs,
    ]) {
      probs.fillRange(0, probs.length, _probInit);
    }
    _state = 0;
    _rep0 = _rep1 = _rep2 = _rep3 = 0;
  }

  /// Marks the current output position as a dictionary boundary (LZMA2
  /// "dictionary reset"): matches may not reach behind it.
  void resetDictionary() {
    _dictStart = _outPos;
  }

  /// Moves the write position (an LZMA2 wrapper syncs it after copying an
  /// uncompressed chunk into the shared output buffer).
  void setPosition(int position) {
    _outPos = position;
  }

  /// Starts a new compressed chunk producing output up to [chunkOutEnd]
  /// (absolute position in the output buffer). The range coder re-reads
  /// its 5 initialization bytes — every LZMA2 chunk does this; a 7z LZMA1
  /// stream is one big chunk.
  void beginChunk(int chunkOutEnd) {
    _outEnd = chunkOutEnd;
    _rcInitialized = false;
    _sawEndMarker = false;
    // Discard any unread padding from the previous chunk's input and
    // re-arm the starvation guard.
    _input = _emptyBytes;
    _pos = 0;
    _inputComplete = false;
  }

  // ---- range decoder ----
  bool _rcInitialized = false;
  int _range = 0xFFFFFFFF;
  int _code = 0;

  // ---- input (small carry buffer between addInput calls) ----
  Uint8List _input = _emptyBytes;
  int _pos = 0;
  bool _inputComplete = false;
  static final Uint8List _emptyBytes = Uint8List(0);

  /// Upper bound on range-coder bytes one symbol can consume; decoding
  /// suspends between symbols when fewer are buffered (unless the caller
  /// declared the input complete).
  static const int _symbolGuard = 64;

  /// Declares that no more input will arrive (lets the tail decode without
  /// the safety margin).
  void setInputComplete() {
    _inputComplete = true;
    _run();
  }

  /// Feeds [chunk]; returns the number of bytes consumed. Unconsumed bytes
  /// (at most a small tail, unless output is complete) are buffered
  /// internally, so callers may simply feed sequential chunks and ignore
  /// the return value. Throws [FormatException] on corruption.
  int addInput(Uint8List chunk) {
    if (_pos < _input.length) {
      final rest = _input.length - _pos;
      final merged =
          Uint8List(rest + chunk.length)
            ..setRange(0, rest, _input, _pos)
            ..setRange(rest, rest + chunk.length, chunk);
      _input = merged;
    } else {
      _input = chunk;
    }
    _pos = 0;
    _run();
    return chunk.length; // everything is either consumed or buffered
  }

  int get _available => _input.length - _pos;

  int _nextByte() {
    if (_pos >= _input.length) {
      throw const FormatException('truncated LZMA stream');
    }
    return _input[_pos++];
  }

  void _rcInit() {
    if (_nextByte() != 0) {
      throw const FormatException('invalid LZMA range-coder init byte');
    }
    _code = 0;
    for (var i = 0; i < 4; i++) {
      _code = ((_code * 256) & 0xFFFFFFFF) | _nextByte();
    }
    _range = 0xFFFFFFFF;
    _rcInitialized = true;
  }

  int _bit(Uint16List probs, int index) {
    final prob = probs[index];
    final bound = (_range >>> 11) * prob;
    int symbol;
    if (_code < bound) {
      _range = bound;
      probs[index] = prob + ((2048 - prob) >> 5);
      symbol = 0;
    } else {
      _range -= bound;
      _code -= bound;
      probs[index] = prob - (prob >> 5);
      symbol = 1;
    }
    if (_range < 0x1000000) {
      _range = (_range * 256) & 0xFFFFFFFF;
      _code = ((_code * 256) & 0xFFFFFFFF) | _nextByte();
    }
    return symbol;
  }

  int _tree(Uint16List probs, int offset, int numBits) {
    var m = 1;
    for (var i = 0; i < numBits; i++) {
      m = (m << 1) | _bit(probs, offset + m);
    }
    return m - (1 << numBits);
  }

  int _treeReverse(Uint16List probs, int offset, int numBits) {
    var m = 1;
    var symbol = 0;
    for (var i = 0; i < numBits; i++) {
      final bit = _bit(probs, offset + m);
      m = (m << 1) | bit;
      symbol |= bit << i;
    }
    return symbol;
  }

  int _directBits(int count) {
    var result = 0;
    for (var i = 0; i < count; i++) {
      _range >>>= 1;
      result <<= 1;
      if (_code >= _range) {
        _code -= _range;
        result |= 1;
      }
      if (_range < 0x1000000) {
        _range = (_range * 256) & 0xFFFFFFFF;
        _code = ((_code * 256) & 0xFFFFFFFF) | _nextByte();
      }
    }
    return result;
  }

  /// Decodes a length (2–273) from a length coder's probability block.
  int _length(Uint16List probs, int posState) {
    if (_bit(probs, 0) == 0) {
      return 2 + _tree(probs, 2 + (posState << 3), 3);
    }
    if (_bit(probs, 1) == 0) {
      return 10 + _tree(probs, 2 + 128 + (posState << 3), 3);
    }
    return 18 + _tree(probs, 2 + 256, 8);
  }

  // ---- main decode loop ----

  void _run() {
    if (!_rcInitialized) {
      if (!_inputComplete && _available < 5 + _symbolGuard) return;
      _rcInit();
    }
    while (_outPos < _outEnd && !_sawEndMarker) {
      if (!_inputComplete && _available < _symbolGuard) return;
      _decodeSymbol();
    }
    if (_sawEndMarker && _outPos != _outEnd) {
      throw const FormatException(
        'LZMA end marker before the declared output size',
      );
    }
  }

  void _decodeSymbol() {
    final posState = (_outPos - _dictStart) & _pbMask;
    if (_bit(_isMatch, (_state << 4) + posState) == 0) {
      _decodeLiteral();
      return;
    }

    int length;
    if (_bit(_isRep, _state) == 0) {
      // Simple match: new distance.
      _rep3 = _rep2;
      _rep2 = _rep1;
      _rep1 = _rep0;
      length = _length(_lenProbs, posState);
      final lenState = length - 2 > 3 ? 3 : length - 2;
      final posSlot = _tree(_posSlot, lenState << 6, 6);
      var dist = posSlot;
      if (posSlot >= 4) {
        final numDirect = (posSlot >> 1) - 1;
        dist = (2 | (posSlot & 1)) << numDirect;
        if (posSlot < 14) {
          dist += _treeReverse(_specPos, dist - posSlot, numDirect);
        } else {
          dist += _directBits(numDirect - 4) << 4;
          dist += _treeReverse(_align, 0, 4);
        }
      }
      if (dist == 0xFFFFFFFF) {
        _sawEndMarker = true;
        return;
      }
      _rep0 = dist;
      _state = _state < 7 ? 7 : 10;
    } else {
      // Rep match: reuse a recent distance.
      if (_bit(_isRepG0, _state) == 0) {
        if (_bit(_isRep0Long, (_state << 4) + posState) == 0) {
          // Short rep: single byte at rep0.
          _state = _state < 7 ? 9 : 11;
          _copyMatch(1);
          return;
        }
      } else {
        int dist;
        if (_bit(_isRepG1, _state) == 0) {
          dist = _rep1;
        } else if (_bit(_isRepG2, _state) == 0) {
          dist = _rep2;
          _rep2 = _rep1;
        } else {
          dist = _rep3;
          _rep3 = _rep2;
          _rep2 = _rep1;
        }
        _rep1 = _rep0;
        _rep0 = dist;
      }
      length = _length(_repLenProbs, posState);
      _state = _state < 7 ? 8 : 11;
    }
    _copyMatch(length);
  }

  void _decodeLiteral() {
    final dictPos = _outPos - _dictStart;
    final prevByte = dictPos > 0 ? _output[_outPos - 1] : 0;
    final litState = ((dictPos & _lpMask) << _lc) + (prevByte >> (8 - _lc));
    final offset = 0x300 * litState;

    var symbol = 1;
    if (_state >= 7) {
      // Matched literal: fold in the byte at distance rep0.
      if (_rep0 + 1 > dictPos) {
        throw const FormatException('LZMA match byte before dictionary start');
      }
      var matchByte = _output[_outPos - _rep0 - 1];
      while (symbol < 0x100) {
        final matchBit = (matchByte >> 7) & 1;
        matchByte = (matchByte << 1) & 0xFF;
        final bit = _bit(_literal, offset + ((1 + matchBit) << 8) + symbol);
        symbol = (symbol << 1) | bit;
        if (matchBit != bit) break;
      }
    }
    while (symbol < 0x100) {
      symbol = (symbol << 1) | _bit(_literal, offset + symbol);
    }
    _output[_outPos++] = symbol & 0xFF;
    _state =
        _state < 4
            ? 0
            : _state < 10
            ? _state - 3
            : _state - 6;
  }

  void _copyMatch(int length) {
    final distance = _rep0 + 1;
    if (distance > _outPos - _dictStart) {
      throw const FormatException('LZMA match distance before dictionary');
    }
    if (_outPos + length > _outEnd) {
      throw const FormatException('LZMA match beyond declared output size');
    }
    var src = _outPos - distance;
    for (var i = 0; i < length; i++) {
      _output[_outPos++] = _output[src++];
    }
  }
}

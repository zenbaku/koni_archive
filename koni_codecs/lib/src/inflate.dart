import 'dart:convert';
import 'dart:typed_data';

/// DEFLATE (RFC 1951) decompression as a synchronous, chunk-driven state
/// machine: input may arrive split at any byte boundary, output is
/// emitted in bounded chunks, and no `await` appears anywhere. Malformed
/// input throws [FormatException] (the `dart:convert` idiom; the archive
/// layer translates).
///
/// One-shot:
///
/// ```dart
/// final decoded = const InflateDecoder().convert(compressed);
/// ```
///
/// Streaming:
///
/// ```dart
/// final sink = const InflateDecoder().startChunkedConversion(output);
/// sink.add(chunk1);
/// sink.add(chunk2);
/// sink.close();
/// ```
final class InflateDecoder extends Converter<List<int>, List<int>> {
  /// Creates the decoder. Stateless; state lives in each conversion.
  const InflateDecoder();

  /// Decompresses one complete raw DEFLATE stream.
  ///
  /// Throws [FormatException] if the stream is malformed, truncated, or
  /// followed by trailing bytes (a framing layer such as gzip should use
  /// [RawInflater] directly to locate the stream end).
  @override
  Uint8List convert(List<int> input) {
    final out = BytesBuilder(copy: false);
    final inflater = RawInflater(onOutput: out.add);
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    final consumed = inflater.addInput(bytes);
    inflater.finish(); // throws FormatException when truncated
    if (consumed < bytes.length || inflater.takeLeftoverBytes().isNotEmpty) {
      throw const FormatException('trailing data after deflate stream');
    }
    return out.takeBytes();
  }

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _InflateSink(sink);
}

final class _InflateSink implements ByteConversionSink {
  _InflateSink(this._downstream)
    : _inflater = RawInflater(onOutput: _downstream.add);

  final Sink<List<int>> _downstream;
  final RawInflater _inflater;

  @override
  void add(List<int> chunk) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    final consumed = _inflater.addInput(bytes);
    if (_inflater.isFinished &&
        (consumed < bytes.length || _inflater.takeLeftoverBytes().isNotEmpty)) {
      throw const FormatException('trailing data after deflate stream');
    }
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(chunk.sublist(start, end));
    if (isLast) close();
  }

  @override
  void close() {
    if (!_inflater.isFinished) {
      throw const FormatException('truncated deflate stream');
    }
    _downstream.close();
  }
}

// ---------------------------------------------------------------------------
// Resumable core
// ---------------------------------------------------------------------------

/// Resumable raw-DEFLATE decompressor, the engine under [InflateDecoder],
/// public for framing layers (gzip, ZIP) that must locate the end of the
/// stream and reclaim trailing bytes.
///
/// Feed input with [addInput]; decoded output is pushed to `onOutput` in
/// chunks of at most 64 KiB (ownership of each chunk transfers to the
/// callback). After [isFinished], [takeLeftoverBytes] returns whole input
/// bytes that were buffered past the stream's end.
final class RawInflater {
  /// Creates an inflater delivering decoded chunks to [onOutput].
  RawInflater({required this.onOutput});

  /// Receives each decoded chunk (at most 64 KiB; ownership transfers).
  final void Function(Uint8List chunk) onOutput;

  // ---- input bit buffer (invariant: _bitCount <= 23 between fills, so
  // every shift stays far below 2^31: portable to dart2js) ----
  Uint8List _input = _emptyBytes;
  int _pos = 0;
  int _bitBuf = 0;
  int _bitCount = 0;

  // ---- output: 64 KiB accumulation buffer; the 32 KiB history window is
  // refreshed in bulk at flush time (no per-byte double writes) ----
  static const int _outSize = 64 * 1024;
  static const int _windowSize = 32 * 1024;
  Uint8List _out = Uint8List(_outSize);
  int _outPos = 0;
  final Uint8List _window = Uint8List(_windowSize);
  int _windowFill = 0; // valid history bytes, left-aligned, oldest first
  int _flushedTotal = 0;

  int get _totalOut => _flushedTotal + _outPos;

  // ---- state machine ----
  _S _state = _S.blockHeader;
  bool _finalBlock = false;
  bool _finished = false;

  // stored blocks
  int _storedRemaining = 0;

  // dynamic header
  int _hlit = 0;
  int _hdist = 0;
  int _hclen = 0;
  int _lenIndex = 0;
  final Uint8List _codeLengthLengths = Uint8List(19);
  Uint8List _lengths = _emptyBytes; // hlit + hdist code lengths
  _Huffman? _codeLengthTree;
  int _repeatSymbol = -1; // pending 16/17/18 awaiting extra bits

  // decode loop
  _Huffman? _litTree;
  _Huffman? _distTree;
  int _matchLength = 0; // pending, through length-extra/distance states
  int _lengthSymbol = -1;
  int _distanceSymbol = -1;
  int _matchDistance = 0;

  static final Uint8List _emptyBytes = Uint8List(0);

  /// Whether the final block has been fully decoded.
  bool get isFinished => _finished;

  /// Total decoded bytes so far.
  int get totalOut => _totalOut;

  /// Consumes [input], decoding until it is exhausted or the stream ends.
  /// Returns the number of bytes consumed (always `input.length` unless the
  /// stream finished mid-buffer). Throws [FormatException] on corruption.
  int addInput(Uint8List input) {
    if (_finished) return 0;
    _input = input;
    _pos = 0;
    _run();
    final consumed = _pos;
    _input = _emptyBytes;
    _pos = 0;
    return consumed;
  }

  /// After [isFinished]: whole bytes that were read into the bit buffer but
  /// belong to whatever follows the deflate stream (a gzip trailer, the
  /// next ZIP record). At most 3 bytes. Clears the buffer.
  Uint8List takeLeftoverBytes() {
    if (!_finished) return _emptyBytes;
    // The deflate stream ends at an arbitrary bit; whatever remains of its
    // final byte is padding and belongs to no one. Discard it before
    // extracting whole bytes (loaded bytes are whole, so the sub-byte
    // remainder is exactly the padding).
    final padding = _bitCount & 7;
    _bitBuf >>= padding;
    _bitCount -= padding;
    final count = _bitCount >> 3;
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = _bitBuf & 0xFF;
      _bitBuf >>= 8;
    }
    _bitCount -= count << 3;
    return bytes;
  }

  /// Declares end of input. Throws [FormatException] if the stream is
  /// incomplete.
  void finish() {
    if (!_finished) {
      throw const FormatException('truncated deflate stream');
    }
  }

  // ---- bit input helpers -------------------------------------------------

  /// Fills the bit buffer to at least [n] bits (n <= 16). Returns false if
  /// input ran dry first.
  bool _fill(int n) {
    while (_bitCount < n) {
      if (_pos >= _input.length) return false;
      _bitBuf |= _input[_pos++] << _bitCount;
      _bitCount += 8;
    }
    return true;
  }

  int _take(int n) {
    final value = _bitBuf & ((1 << n) - 1);
    _bitBuf >>= n;
    _bitCount -= n;
    return value;
  }

  /// Decodes one Huffman symbol, or -1 when input starved (state
  /// unchanged: the peeked bits stay buffered).
  int _decodeSymbol(_Huffman tree) {
    // Fill as far as the longest code; near the end of input fewer bits may
    // be available, which is fine as long as the code completes.
    _fill(tree.maxLength);
    final entry = tree.table[_bitBuf & tree.mask];
    if (entry >= 0) {
      final length = entry >>> 16;
      if (length <= _bitCount) {
        _take(length);
        return entry & 0xFFFF;
      }
      return -1; // needs more bits than we have
    }
    // Invalid slot: genuine bad code if the lookup was fully specified,
    // starvation otherwise.
    if (_bitCount >= tree.maxLength) {
      throw const FormatException('invalid huffman code in deflate stream');
    }
    return -1;
  }

  // ---- output helpers ----------------------------------------------------

  void _flushOut() {
    if (_outPos == 0) return;
    // Refresh the history window with the tail of what is being flushed.
    if (_outPos >= _windowSize) {
      _window.setRange(0, _windowSize, _out, _outPos - _windowSize);
      _windowFill = _windowSize;
    } else {
      final keep =
          _windowFill + _outPos > _windowSize
              ? _windowSize - _outPos
              : _windowFill;
      if (keep > 0 && keep < _windowFill) {
        _window.setRange(0, keep, _window, _windowFill - keep);
      }
      _window.setRange(keep, keep + _outPos, _out);
      _windowFill = keep + _outPos;
    }
    _flushedTotal += _outPos;
    if (_outPos == _out.length) {
      onOutput(_out);
    } else {
      onOutput(Uint8List.sublistView(_out, 0, _outPos));
    }
    _out = Uint8List(_outSize);
    _outPos = 0;
  }

  void _emit(int byte) {
    _out[_outPos++] = byte;
    if (_outPos == _outSize) _flushOut();
  }

  // ---- the machine -------------------------------------------------------

  void _run() {
    while (true) {
      switch (_state) {
        case _S.blockHeader:
          if (!_fill(3)) return;
          _finalBlock = _take(1) != 0;
          switch (_take(2)) {
            case 0:
              // Stored: discard bits to the byte boundary.
              _take(_bitCount & 7);
              _state = _S.storedLength;
            case 1:
              _litTree = _Huffman.fixedLiterals;
              _distTree = _Huffman.fixedDistances;
              _state = _S.decode;
            case 2:
              _state = _S.dynamicHeader;
            default:
              throw const FormatException('invalid deflate block type 3');
          }

        case _S.storedLength:
          if (!_fill(16)) return;
          // LEN then NLEN, each 16 bits, byte-aligned.
          final len = _take(16);
          if (!_fill(16)) {
            // Push LEN back is impossible; keep a sub-state instead.
            _storedRemaining = len;
            _state = _S.storedNlen;
            return;
          }
          _checkStoredNlen(len, _take(16));
          _storedRemaining = len;
          _state = _S.storedCopy;

        case _S.storedNlen:
          if (!_fill(16)) return;
          _checkStoredNlen(_storedRemaining, _take(16));
          _state = _S.storedCopy;

        case _S.storedCopy:
          // Whole bytes: consume from the bit buffer first, then bulk-copy
          // straight from the input to the output buffer.
          while (_storedRemaining > 0 && _bitCount >= 8) {
            _emit(_take(8));
            _storedRemaining--;
          }
          while (_storedRemaining > 0 && _pos < _input.length) {
            final count = _min3(
              _storedRemaining,
              _input.length - _pos,
              _outSize - _outPos,
            );
            _out.setRange(_outPos, _outPos + count, _input, _pos);
            _outPos += count;
            _pos += count;
            _storedRemaining -= count;
            if (_outPos == _outSize) _flushOut();
          }
          if (_storedRemaining > 0) return;
          _state = _finalBlock ? _S.done : _S.blockHeader;
          if (_finalBlock) _finishStream();

        case _S.dynamicHeader:
          if (!_fill(14)) return;
          _hlit = _take(5) + 257;
          _hdist = _take(5) + 1;
          _hclen = _take(4) + 4;
          if (_hlit > 286 || _hdist > 30) {
            throw const FormatException(
              'invalid deflate dynamic header counts',
            );
          }
          _codeLengthLengths.fillRange(0, 19, 0);
          _lenIndex = 0;
          _state = _S.codeLengthCodes;

        case _S.codeLengthCodes:
          while (_lenIndex < _hclen) {
            if (!_fill(3)) return;
            _codeLengthLengths[_clOrder[_lenIndex++]] = _take(3);
          }
          _codeLengthTree = _Huffman(
            _codeLengthLengths,
            kind: _HuffmanKind.codes,
          );
          _lengths = Uint8List(_hlit + _hdist);
          _lenIndex = 0;
          _repeatSymbol = -1;
          _state = _S.codeLengths;

        case _S.codeLengths:
          if (!_readCodeLengths()) return;
          _litTree = _Huffman(
            Uint8List.sublistView(_lengths, 0, _hlit),
            kind: _HuffmanKind.literals,
          );
          _distTree = _Huffman(
            Uint8List.sublistView(_lengths, _hlit),
            kind: _HuffmanKind.distances,
          );
          _state = _S.decode;

        case _S.decode:
          if (_decodeFast()) break; // state changed; re-dispatch
          // Slow tail: precise starvation handling near buffer edges.
          while (true) {
            final symbol = _decodeSymbol(_litTree!);
            if (symbol < 0) return;
            if (symbol < 256) {
              _emit(symbol);
            } else if (symbol == 256) {
              _state = _finalBlock ? _S.done : _S.blockHeader;
              if (_finalBlock) _finishStream();
              break;
            } else {
              if (symbol > 285) {
                throw const FormatException('invalid deflate length symbol');
              }
              _lengthSymbol = symbol - 257;
              _state = _S.lengthExtra;
              break;
            }
          }

        case _S.lengthExtra:
          final extraBits = _lengthExtra[_lengthSymbol];
          if (!_fill(extraBits)) return;
          _matchLength = _lengthBase[_lengthSymbol] + _take(extraBits);
          _state = _S.distanceSymbolState;

        case _S.distanceSymbolState:
          final symbol = _decodeSymbol(_distTree!);
          if (symbol < 0) return;
          if (symbol > 29) {
            throw const FormatException('invalid deflate distance symbol');
          }
          _distanceSymbol = symbol;
          _state = _S.distanceExtra;

        case _S.distanceExtra:
          final extraBits = _distExtra[_distanceSymbol];
          if (!_fill(extraBits)) return;
          _matchDistance = _distBase[_distanceSymbol] + _take(extraBits);
          if (_matchDistance > _totalOut) {
            throw const FormatException(
              'deflate match distance beyond output start',
            );
          }
          _state = _S.copyMatch;

        case _S.copyMatch:
          // Never starves: reads from the current output buffer, or from
          // the history window for the portion preceding it.
          while (_matchLength > 0) {
            final dist = _matchDistance;
            if (dist <= _outPos) {
              // Source inside the current buffer (may overlap the write).
              final available = _outSize - _outPos;
              final count = _matchLength < available ? _matchLength : available;
              var src = _outPos - dist;
              if (dist >= count) {
                _out.setRange(_outPos, _outPos + count, _out, src);
                _outPos += count;
              } else {
                // Overlapping run (e.g. distance 1): byte-by-byte.
                for (var i = 0; i < count; i++) {
                  _out[_outPos++] = _out[src++];
                }
              }
              _matchLength -= count;
            } else {
              // The first (dist - _outPos) source bytes live in the history
              // window; once consumed, the loop falls into the branch above.
              final back = dist - _outPos;
              final src = _windowFill - back;
              final count = _min3(_matchLength, back, _outSize - _outPos);
              _out.setRange(_outPos, _outPos + count, _window, src);
              _outPos += count;
              _matchLength -= count;
            }
            if (_outPos == _outSize) _flushOut();
          }
          _state = _S.decode;

        case _S.done:
          return;
      }
    }
  }

  /// The hot decode loop (zlib's `inflate_fast` idea): runs with all bit
  /// state in locals while enough input (≥ 8 bytes per symbol worst case)
  /// and output slack (≥ 258 bytes per match) are guaranteed, so no
  /// starvation or flush handling appears inside. Returns true when the
  /// block ended (state changed); false to fall back to the precise path.
  bool _decodeFast() {
    final input = _input;
    final inputEnd = input.length - 8;
    final litTree = _litTree!;
    final distTree = _distTree!;
    final litTable = litTree.table;
    final litMask = litTree.mask;
    final distTable = distTree.table;
    final distMask = distTree.mask;
    final out = _out;
    final window = _window;
    var bitBuf = _bitBuf;
    var bitCount = _bitCount;
    var pos = _pos;
    var outPos = _outPos;

    void save() {
      _bitBuf = bitBuf;
      _bitCount = bitCount;
      _pos = pos;
      _outPos = outPos;
    }

    while (pos <= inputEnd && outPos + 258 <= _outSize) {
      while (bitCount < 15) {
        bitBuf |= input[pos++] << bitCount;
        bitCount += 8;
      }
      var entry = litTable[bitBuf & litMask];
      if (entry < 0) {
        save();
        throw const FormatException('invalid huffman code in deflate stream');
      }
      bitBuf >>= entry >>> 16;
      bitCount -= entry >>> 16;
      final symbol = entry & 0xFFFF;
      if (symbol < 256) {
        out[outPos++] = symbol;
        continue;
      }
      if (symbol == 256) {
        save();
        _state = _finalBlock ? _S.done : _S.blockHeader;
        if (_finalBlock) _finishStream();
        return true;
      }
      if (symbol > 285) {
        save();
        throw const FormatException('invalid deflate length symbol');
      }
      final lengthSymbol = symbol - 257;
      var extra = _lengthExtra[lengthSymbol];
      while (bitCount < extra) {
        bitBuf |= input[pos++] << bitCount;
        bitCount += 8;
      }
      final matchLength =
          _lengthBase[lengthSymbol] + (bitBuf & ((1 << extra) - 1));
      bitBuf >>= extra;
      bitCount -= extra;

      while (bitCount < 15) {
        bitBuf |= input[pos++] << bitCount;
        bitCount += 8;
      }
      entry = distTable[bitBuf & distMask];
      if (entry < 0) {
        save();
        throw const FormatException('invalid huffman code in deflate stream');
      }
      bitBuf >>= entry >>> 16;
      bitCount -= entry >>> 16;
      final distSymbol = entry & 0xFFFF;
      if (distSymbol > 29) {
        save();
        throw const FormatException('invalid deflate distance symbol');
      }
      extra = _distExtra[distSymbol];
      while (bitCount < extra) {
        bitBuf |= input[pos++] << bitCount;
        bitCount += 8;
      }
      final distance = _distBase[distSymbol] + (bitBuf & ((1 << extra) - 1));
      bitBuf >>= extra;
      bitCount -= extra;

      if (distance > _flushedTotal + outPos) {
        save();
        throw const FormatException(
          'deflate match distance beyond output start',
        );
      }

      // Copy (output slack of 258 is guaranteed; no flush can occur here).
      if (distance <= outPos) {
        var src = outPos - distance;
        if (distance >= matchLength) {
          out.setRange(outPos, outPos + matchLength, out, src);
          outPos += matchLength;
        } else {
          for (var i = 0; i < matchLength; i++) {
            out[outPos++] = out[src++];
          }
        }
      } else {
        final back = distance - outPos;
        final fromWindow = matchLength < back ? matchLength : back;
        out.setRange(outPos, outPos + fromWindow, window, _windowFill - back);
        outPos += fromWindow;
        var remaining = matchLength - fromWindow;
        if (remaining > 0) {
          var src = outPos - distance;
          if (distance >= remaining) {
            out.setRange(outPos, outPos + remaining, out, src);
            outPos += remaining;
          } else {
            while (remaining-- > 0) {
              out[outPos++] = out[src++];
            }
          }
        }
      }
    }
    save();
    if (_outPos == _outSize) _flushOut();
    return false;
  }

  /// Reads literal/distance code lengths (symbols 0-18 with repeats).
  /// Returns false when starved.
  bool _readCodeLengths() {
    final tree = _codeLengthTree!;
    while (_lenIndex < _lengths.length) {
      if (_repeatSymbol < 0) {
        final symbol = _decodeSymbol(tree);
        if (symbol < 0) return false;
        if (symbol < 16) {
          _lengths[_lenIndex++] = symbol;
          continue;
        }
        _repeatSymbol = symbol;
      }
      final int extraBits;
      final int base;
      switch (_repeatSymbol) {
        case 16:
          extraBits = 2;
          base = 3;
        case 17:
          extraBits = 3;
          base = 3;
        default: // 18
          extraBits = 7;
          base = 11;
      }
      if (!_fill(extraBits)) return false;
      final repeat = base + _take(extraBits);
      final int value;
      if (_repeatSymbol == 16) {
        if (_lenIndex == 0) {
          throw const FormatException(
            'deflate code-length repeat with no previous length',
          );
        }
        value = _lengths[_lenIndex - 1];
      } else {
        value = 0;
      }
      if (_lenIndex + repeat > _lengths.length) {
        throw const FormatException('deflate code-length repeat overflow');
      }
      _lengths.fillRange(_lenIndex, _lenIndex + repeat, value);
      _lenIndex += repeat;
      _repeatSymbol = -1;
    }
    return true;
  }

  void _checkStoredNlen(int len, int nlen) {
    if (len != (~nlen & 0xFFFF)) {
      throw const FormatException('deflate stored block length check failed');
    }
  }

  void _finishStream() {
    _finished = true;
    _flushOut();
  }

  // RFC 1951 §3.2.5 tables.
  static const List<int> _lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
  ];
  static const List<int> _lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ];
  static const List<int> _distBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, //
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, //
    12289, 16385, 24577,
  ];
  static const List<int> _distExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
  ];
  static const List<int> _clOrder = [
    16,
    17,
    18,
    0,
    8,
    7,
    9,
    6,
    10,
    5,
    11,
    4,
    12,
    3,
    13,
    2,
    14,
    1,
    15,
  ];
}

int _min3(int a, int b, int c) {
  final m = a < b ? a : b;
  return m < c ? m : c;
}

enum _S {
  blockHeader,
  storedLength,
  storedNlen,
  storedCopy,
  dynamicHeader,
  codeLengthCodes,
  codeLengths,
  decode,
  lengthExtra,
  distanceSymbolState,
  distanceExtra,
  copyMatch,
  done,
}

/// Which DEFLATE tree a table decodes determines how strictly
/// completeness is enforced (zlib semantics).
enum _HuffmanKind {
  /// The code-length (header) tree: must be complete.
  codes,

  /// The literal/length tree: complete, or a degenerate single code.
  literals,

  /// The distance tree: complete, a single code, or empty (a literal-only
  /// block needs no distances).
  distances,
}

/// Canonical Huffman decode table: one flat table indexed by the next
/// `maxLength` input bits (LSB-first as they arrive), entries
/// `(codeLength << 16) | symbol`, invalid slots -1.
final class _Huffman {
  factory _Huffman(Uint8List codeLengths, {required _HuffmanKind kind}) {
    final counts = List<int>.filled(16, 0);
    var maxLength = 0;
    var codeCount = 0;
    for (final length in codeLengths) {
      counts[length]++;
      if (length > maxLength) maxLength = length;
      if (length > 0) codeCount++;
    }
    if (maxLength == 0) {
      if (kind != _HuffmanKind.distances) {
        throw const FormatException('empty huffman table in deflate stream');
      }
      // No distance codes (legal for a literal-only block): a 1-bit table
      // where every lookup is an invalid code.
      return _Huffman._(Int32List(2)..fillRange(0, 2, -1), 1);
    }

    // Over-/under-subscription check (zlib semantics): oversubscription is
    // always fatal; incompleteness is tolerated only for a degenerate
    // single-code literal/distance tree.
    var left = 1;
    for (var length = 1; length <= 15; length++) {
      left <<= 1;
      left -= counts[length];
      if (left < 0) {
        throw const FormatException(
          'oversubscribed huffman table in deflate stream',
        );
      }
    }
    if (left > 0 && (kind == _HuffmanKind.codes || codeCount != 1)) {
      throw const FormatException('incomplete huffman table in deflate stream');
    }

    final table = Int32List(1 << maxLength)..fillRange(0, 1 << maxLength, -1);
    final nextCode = List<int>.filled(16, 0);
    var code = 0;
    for (var length = 1; length <= maxLength; length++) {
      code = (code + counts[length - 1]) << 1;
      nextCode[length] = code;
    }
    for (var symbol = 0; symbol < codeLengths.length; symbol++) {
      final length = codeLengths[symbol];
      if (length == 0) continue;
      final canonical = nextCode[length]++;
      // Bits arrive LSB-first: reverse the canonical (MSB-first) code.
      var reversed = 0;
      for (var bit = 0; bit < length; bit++) {
        reversed = (reversed << 1) | ((canonical >> bit) & 1);
      }
      final entry = (length << 16) | symbol;
      for (var i = reversed; i < table.length; i += 1 << length) {
        table[i] = entry;
      }
    }
    return _Huffman._(table, maxLength);
  }

  _Huffman._(this.table, this.maxLength) : mask = (1 << maxLength) - 1;

  final Int32List table;
  final int maxLength;
  final int mask;

  /// RFC 1951 §3.2.6 fixed literal/length tree.
  static final _Huffman fixedLiterals = _Huffman(
    Uint8List.fromList([
      for (var i = 0; i <= 143; i++) 8,
      for (var i = 144; i <= 255; i++) 9,
      for (var i = 256; i <= 279; i++) 7,
      for (var i = 280; i <= 287; i++) 8,
    ]),
    kind: _HuffmanKind.literals,
  );

  /// RFC 1951 §3.2.6 fixed distance tree.
  static final _Huffman fixedDistances = _Huffman(
    Uint8List.fromList(List.filled(32, 5)),
    kind: _HuffmanKind.distances,
  );
}

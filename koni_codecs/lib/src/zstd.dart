/// Zstandard (RFC 8878) decompression — read only, no dictionary.
///
/// Clean-room from the format spec: a stream of frames, each a sequence of
/// blocks (raw / RLE / compressed). A compressed block carries a literals
/// section (raw / RLE / Huffman) and a sequences section (FSE-coded
/// literal-length / offset / match-length triples) that are executed against a
/// back-reference window. Streams may concatenate frames and interleave
/// skippable frames.
///
/// [RawZstdDecoder] is the resumable engine: feed compressed input with
/// [RawZstdDecoder.addInput], call [RawZstdDecoder.close], then pull one decoded
/// block at a time with [RawZstdDecoder.nextBlock]. [ZstdDecoder] wraps it as a
/// one-shot [Converter].
///
/// The whole decoded output of a frame is retained (matches back-reference it
/// by absolute position); a mandatory window-size cap and, when the frame
/// records its content size, a pre-check bound the allocation. Not supported (a
/// typed [FormatException], never a silent mis-decode): dictionaries
/// (`Dictionary_ID` set) and the legacy (v0.x) frame formats.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The 4-byte Zstandard frame magic (0xFD2FB528, little-endian).
const int _zstdMagic = 0xFD2FB528;

/// Skippable-frame magic range: 0x184D2A50 .. 0x184D2A5F.
const int _skippableMagicMin = 0x184D2A50;
const int _skippableMagicMax = 0x184D2A5F;

/// Largest window this decoder accepts (windowLog 27 = 128 MiB), the reference
/// decoder's default cap. A frame declaring more is rejected rather than
/// triggering an unbounded allocation from a tiny hostile header.
const int _maxWindowSize = 1 << 27;

/// Largest single block's decompressed size (128 KiB), per the format.
const int _blockSizeMax = 1 << 17;

/// Resumable Zstandard decompressor. See the library docs for the pull model.
final class RawZstdDecoder {
  /// Creates a decoder; feed it with [addInput].
  RawZstdDecoder();

  final BytesBuilder _inputBuilder = BytesBuilder(copy: false);
  late Uint8List _input;
  int _ip = 0;
  bool _closed = false;
  bool _done = false;

  // Growable output buffer (retained for back-references).
  Uint8List _out = Uint8List(0);
  int _outLen = 0;
  // Start of the current frame within [_out]; back-references never cross it.
  int _frameStart = 0;

  // Frame state.
  bool _inFrame = false;
  bool _lastBlockSeen = false;
  int _windowSize = 0;
  bool _checksumFlag = false;

  /// Appends compressed input.
  void addInput(Uint8List chunk) {
    if (_closed) throw StateError('addInput after close()');
    _inputBuilder.add(chunk);
  }

  /// Declares the compressed input complete; blocks may then be pulled.
  void close() {
    if (_closed) return;
    _closed = true;
    _input = _inputBuilder.takeBytes();
  }

  /// Decodes and returns the next block's decoded bytes, or null at the end of
  /// input. Frame headers, skippable frames, and frame checksums are consumed
  /// transparently between blocks.
  Uint8List? nextBlock() {
    if (!_closed) throw StateError('close() the decoder before pulling blocks');
    try {
      return _nextBlock();
    } on RangeError catch (e) {
      throw FormatException('corrupt zstd stream: $e');
    } on ArgumentError catch (e) {
      throw FormatException('corrupt zstd stream: $e');
    }
  }

  Uint8List? _nextBlock() {
    while (true) {
      if (_done) return null;

      if (!_inFrame) {
        if (_ip >= _input.length) {
          _done = true;
          return null;
        }
        _parseFrameOrSkippable();
        continue; // a skippable frame produced no block; a real frame header
        // leaves us ready to read its first block.
      }

      if (_lastBlockSeen) {
        _finishFrame();
        continue;
      }

      final block = _decodeBlock();
      if (block != null) return block;
      // A zero-length block yields nothing; loop for the next.
    }
  }

  // --- framing ---------------------------------------------------------------

  void _parseFrameOrSkippable() {
    final magic = _readU32le();
    if (magic >= _skippableMagicMin && magic <= _skippableMagicMax) {
      final size = _readU32le();
      if (_ip + size > _input.length) {
        throw const FormatException('truncated zstd skippable frame');
      }
      _ip += size;
      return;
    }
    if (magic != _zstdMagic) {
      throw const FormatException('bad zstd frame magic');
    }
    _parseFrameHeader();
  }

  void _parseFrameHeader() {
    final desc = _readByte();
    final fcsFlag = (desc >> 6) & 3;
    final singleSegment = (desc >> 5) & 1;
    if ((desc >> 3) & 1 != 0) {
      throw const FormatException('reserved zstd frame-header bit set');
    }
    _checksumFlag = (desc >> 2) & 1 != 0;
    final dictIdFlag = desc & 3;

    int windowSize;
    if (singleSegment == 0) {
      final wd = _readByte();
      final exponent = wd >> 3;
      final mantissa = wd & 7;
      final windowLog = 10 + exponent;
      if (windowLog > 41) {
        throw const FormatException('zstd window is too large');
      }
      final windowBase = 1 << windowLog;
      windowSize = windowBase + (windowBase >> 3) * mantissa;
    } else {
      windowSize = 0; // set from the content size below
    }

    final dictIdSize = const [0, 1, 2, 4][dictIdFlag];
    var dictId = 0;
    for (var i = 0; i < dictIdSize; i++) {
      dictId |= _readByte() << (8 * i);
    }
    if (dictId != 0) {
      throw const FormatException(
        'dictionary-compressed zstd frames are not supported',
      );
    }

    final fcsFieldSize = fcsFlag == 0 ? singleSegment : (1 << fcsFlag);
    var contentSize = -1;
    if (fcsFieldSize > 0) {
      var v = 0;
      for (var i = 0; i < fcsFieldSize; i++) {
        v += _readByte() * _pow256(i);
      }
      if (fcsFieldSize == 2) v += 256;
      contentSize = v;
    }

    if (singleSegment == 1) {
      windowSize = contentSize < 0 ? 0 : contentSize;
    }
    if (windowSize > _maxWindowSize) {
      throw const FormatException('zstd window exceeds the supported limit');
    }

    _inFrame = true;
    _lastBlockSeen = false;
    _windowSize = windowSize;
    _frameStart = _outLen;
    _frameContentSize = contentSize;
    _resetFrameEntropy();
  }

  void _finishFrame() {
    if (_checksumFlag) {
      // Content checksum: the low 32 bits of XXH64 of the frame's decoded
      // content. Verified on platforms with native 64-bit integers (the VM and
      // Flutter); skipped under dart2js/dart2wasm, where a web-safe XXH64 would
      // need 64-bit-multiply emulation — decode correctness does not depend on
      // it. Both control by `verifyChecksum`.
      final stored = _readU32le();
      if (verifyChecksum && !_isWeb) {
        final actual = _xxh64(_out, _frameStart, _outLen) & 0xFFFFFFFF;
        if (actual != stored) {
          throw const FormatException('zstd content checksum mismatch');
        }
      }
    }
    if (_frameContentSize >= 0 && _outLen - _frameStart != _frameContentSize) {
      throw const FormatException(
        'zstd frame content size does not match the declared size',
      );
    }
    _inFrame = false;
  }

  /// Whether checksums are verified (when the platform supports native 64-bit
  /// integers). Defaults to true.
  bool verifyChecksum = true;

  // --- blocks ----------------------------------------------------------------

  Uint8List? _decodeBlock() {
    if (_ip + 3 > _input.length) {
      throw const FormatException('truncated zstd block header');
    }
    final header =
        _input[_ip] | (_input[_ip + 1] << 8) | (_input[_ip + 2] << 16);
    _ip += 3;
    final lastBlock = header & 1;
    final blockType = (header >> 1) & 3;
    final blockSize = header >> 3;
    _lastBlockSeen = lastBlock != 0;

    final blockMax =
        _windowSize == 0
            ? _blockSizeMax
            : (_windowSize < _blockSizeMax ? _windowSize : _blockSizeMax);

    final start = _outLen;
    _blockStart = start;
    switch (blockType) {
      case 0: // Raw
        if (blockSize > _blockSizeMax) {
          throw const FormatException('zstd raw block too large');
        }
        if (_ip + blockSize > _input.length) {
          throw const FormatException('truncated zstd raw block');
        }
        _ensureOut(blockSize);
        _out.setRange(_outLen, _outLen + blockSize, _input, _ip);
        _outLen += blockSize;
        _ip += blockSize;
      case 1: // RLE
        if (blockSize > _blockSizeMax) {
          throw const FormatException('zstd RLE block too large');
        }
        final b = _readByte();
        _ensureOut(blockSize);
        _out.fillRange(_outLen, _outLen + blockSize, b);
        _outLen += blockSize;
      case 2: // Compressed
        if (blockSize > _blockSizeMax) {
          throw const FormatException('zstd compressed block too large');
        }
        _decodeCompressedBlock(blockSize, blockMax);
      default: // 3, reserved
        throw const FormatException('reserved zstd block type');
    }

    if (start == _outLen) return null;
    return Uint8List.sublistView(_out, start, _outLen);
  }

  // --- output buffer ---------------------------------------------------------

  void _ensureOut(int extra) {
    final needed = _outLen + extra;
    if (needed <= _out.length) return;
    var cap = _out.isEmpty ? 1 << 16 : _out.length;
    while (cap < needed) {
      cap *= 2;
    }
    final grown = Uint8List(cap);
    grown.setRange(0, _outLen, _out);
    _out = grown;
  }

  // --- small readers ---------------------------------------------------------

  int _readByte() {
    if (_ip >= _input.length) {
      throw const FormatException('truncated zstd stream');
    }
    return _input[_ip++];
  }

  int _readU32le() {
    if (_ip + 4 > _input.length) {
      throw const FormatException('truncated zstd stream');
    }
    final v =
        _input[_ip] +
        _input[_ip + 1] * 0x100 +
        _input[_ip + 2] * 0x10000 +
        _input[_ip + 3] * 0x1000000;
    _ip += 4;
    return v;
  }

  static int _pow256(int i) => switch (i) {
    0 => 1,
    1 => 0x100,
    2 => 0x10000,
    3 => 0x1000000,
    4 => 0x100000000,
    5 => 0x10000000000,
    6 => 0x1000000000000,
    _ => 0x100000000000000,
  };

  int _frameContentSize = -1;

  // Per-frame entropy state (persists across blocks within a frame).
  final List<int> _repeatOffsets = [1, 4, 8];
  _HufTable? _prevHuf;
  _FseTable? _prevLL;
  _FseTable? _prevOF;
  _FseTable? _prevML;

  void _resetFrameEntropy() {
    _repeatOffsets[0] = 1;
    _repeatOffsets[1] = 4;
    _repeatOffsets[2] = 8;
    _prevHuf = null;
    _prevLL = null;
    _prevOF = null;
    _prevML = null;
  }

  void _decodeCompressedBlock(int blockSize, int blockMax) {
    final blockEnd = _ip + blockSize;
    // ---- Literals section ----
    final literals = _decodeLiterals(blockEnd);
    // ---- Sequences section ----
    final nbSeq = _readNumSequences(blockEnd);
    if (nbSeq == 0) {
      // No sequences: the block is just its literals.
      _ip = blockEnd;
      _appendBytes(literals, 0, literals.length);
      if (_outLen - _blockStart > blockMax) {
        throw const FormatException('zstd block output exceeds the block size');
      }
      return;
    }

    final modes = _readByte();
    final llMode = (modes >> 6) & 3;
    final ofMode = (modes >> 4) & 3;
    final mlMode = (modes >> 2) & 3;
    if (modes & 3 != 0) {
      throw const FormatException('reserved zstd sequence mode bits');
    }

    final llTable = _readFseTable(llMode, _llPredef, _prevLL, blockEnd, 9);
    final ofTable = _readFseTable(ofMode, _ofPredef, _prevOF, blockEnd, 8);
    final mlTable = _readFseTable(mlMode, _mlPredef, _prevML, blockEnd, 9);
    _prevLL = llTable;
    _prevOF = ofTable;
    _prevML = mlTable;

    _executeSequences(
      literals,
      llTable,
      ofTable,
      mlTable,
      nbSeq,
      _ip,
      blockEnd,
      blockMax,
    );
    _ip = blockEnd;
  }

  int _blockStart = 0;

  // ---- Literals section ----

  Uint8List _decodeLiterals(int blockEnd) {
    final header0 = _readByte();
    final litType = header0 & 3;
    final sizeFormat = (header0 >> 2) & 3;

    if (litType == 0 || litType == 1) {
      // Raw or RLE literals.
      int regenSize;
      switch (sizeFormat) {
        case 0:
        case 2:
          regenSize = header0 >> 3; // 5-bit size
        case 1:
          regenSize = (header0 >> 4) | (_readByte() << 4); // 12-bit
        default: // 3
          regenSize = (header0 >> 4) | (_readByte() << 4) | (_readByte() << 12);
      }
      if (litType == 0) {
        if (_ip + regenSize > blockEnd) {
          throw const FormatException('truncated raw literals');
        }
        final lits = Uint8List.sublistView(_input, _ip, _ip + regenSize);
        _ip += regenSize;
        return lits;
      } else {
        final b = _readByte();
        return Uint8List(regenSize)..fillRange(0, regenSize, b);
      }
    }

    // Compressed (2) or Treeless (3) literals: Huffman.
    int regenSize;
    int compSize;
    int streams;
    switch (sizeFormat) {
      case 0:
        // single stream, 10-bit sizes
        final v = header0 >> 4 | (_readByte() << 4) | (_readByte() << 12);
        regenSize = v & 0x3FF;
        compSize = (v >> 10) & 0x3FF;
        streams = 1;
      case 1:
        final v = header0 >> 4 | (_readByte() << 4) | (_readByte() << 12);
        regenSize = v & 0x3FF;
        compSize = (v >> 10) & 0x3FF;
        streams = 4;
      case 2:
        final v =
            header0 >> 4 |
            (_readByte() << 4) |
            (_readByte() << 12) |
            (_readByte() << 20);
        regenSize = v & 0x3FFF;
        compSize = (v >> 14) & 0x3FFF;
        streams = 4;
      default: // 3
        // 18-bit sizes span 5 bytes; a single 36-bit `v` would need bit 35,
        // and `(byte << 28) | …` truncates to 32 bits on dart2js (bits 32-35
        // lost), so assemble each size from its own bit fields (all < 2^18).
        final b1 = _readByte();
        final b2 = _readByte();
        final b3 = _readByte();
        final b4 = _readByte();
        regenSize = (header0 >> 4) | (b1 << 4) | ((b2 & 0x3F) << 12);
        compSize = (b2 >> 6) | (b3 << 2) | (b4 << 10);
        streams = 4;
    }

    final huffEnd = _ip + compSize;
    if (huffEnd > blockEnd) {
      throw const FormatException('truncated compressed literals');
    }
    _HufTable table;
    var weightsBytes = 0;
    if (litType == 2) {
      final built = _HufTable.read(_input, _ip, huffEnd);
      table = built.table;
      weightsBytes = built.headerBytes;
      _prevHuf = table;
    } else {
      final prev = _prevHuf;
      if (prev == null) {
        throw const FormatException('treeless literals without a prior table');
      }
      table = prev;
    }
    final out = Uint8List(regenSize);
    _decodeHuffmanLiterals(table, _ip + weightsBytes, huffEnd, streams, out);
    _ip = huffEnd;
    return out;
  }

  // ---- Sequences ----

  int _readNumSequences(int blockEnd) {
    final b0 = _readByte();
    if (b0 == 0) return 0;
    if (b0 < 128) return b0;
    if (b0 < 255) {
      return ((b0 - 128) << 8) + _readByte();
    }
    return _readByte() + (_readByte() << 8) + 0x7F00;
  }

  _FseTable _readFseTable(
    int mode,
    _FseTable predef,
    _FseTable? prev,
    int blockEnd,
    int maxLog,
  ) {
    switch (mode) {
      case 0: // Predefined
        return predef;
      case 1: // RLE (single symbol)
        final symbol = _readByte();
        return _FseTable.rle(symbol);
      case 2: // FSE_Compressed
        final r = _NCountReader(_input, _ip, blockEnd, maxLog);
        final counts = r.read();
        _ip = r.bytePos;
        return _FseTable.build(counts.counts, counts.tableLog);
      default: // 3 Repeat
        if (prev == null) {
          throw const FormatException('repeat FSE table without a prior table');
        }
        return prev;
    }
  }

  void _executeSequences(
    Uint8List literals,
    _FseTable llTable,
    _FseTable ofTable,
    _FseTable mlTable,
    int nbSeq,
    int seqStart,
    int blockEnd,
    int blockMax,
  ) {
    final bits = _ReverseBits(_input, seqStart, blockEnd);
    var llState = bits.readBits(llTable.tableLog);
    var ofState = bits.readBits(ofTable.tableLog);
    var mlState = bits.readBits(mlTable.tableLog);

    var litPos = 0;
    for (var i = 0; i < nbSeq; i++) {
      final ofCode = ofTable.symbol(ofState);
      final mlCode = mlTable.symbol(mlState);
      final llCode = llTable.symbol(llState);

      // Extra bits: offset, then match length, then literals length.
      final offsetValue =
          ofCode == 0 ? 1 : (1 << ofCode) + bits.readBits(ofCode);
      final matchLength = _mlBase[mlCode] + bits.readBits(_mlBits[mlCode]);
      final litLength = _llBase[llCode] + bits.readBits(_llBits[llCode]);

      final offset = _resolveOffset(offsetValue, litLength);

      // Emit literals then match.
      if (litPos + litLength > literals.length) {
        throw const FormatException('zstd sequence over-reads literals');
      }
      _appendBytes(literals, litPos, litPos + litLength);
      litPos += litLength;
      _copyMatch(offset, matchLength);

      if (_outLen - _blockStart > blockMax) {
        throw const FormatException('zstd block output exceeds the block size');
      }

      if (i < nbSeq - 1) {
        // Update states: LL, ML, OF (last sequence skips this).
        llState = llTable.next(llState, bits);
        mlState = mlTable.next(mlState, bits);
        ofState = ofTable.next(ofState, bits);
      }
    }

    // Trailing literals after the last sequence.
    if (litPos < literals.length) {
      _appendBytes(literals, litPos, literals.length);
    }
  }

  int _resolveOffset(int offsetValue, int litLength) {
    final rep = _repeatOffsets;
    int offset;
    if (offsetValue > 3) {
      offset = offsetValue - 3;
      rep[2] = rep[1];
      rep[1] = rep[0];
      rep[0] = offset;
    } else {
      var idx = offsetValue;
      if (litLength == 0) idx += 1;
      if (idx == 1) {
        offset = rep[0];
      } else if (idx == 2) {
        offset = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
      } else if (idx == 3) {
        offset = rep[2];
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
      } else {
        // idx == 4: offsetValue 3 with litLength 0 -> rep[0] - 1.
        offset = rep[0] - 1;
        if (offset < 1) {
          throw const FormatException('zstd invalid repeat offset');
        }
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
      }
    }
    return offset;
  }

  void _copyMatch(int offset, int length) {
    final srcStart = _outLen - offset;
    if (srcStart < _frameStart) {
      throw const FormatException('zstd match offset before the frame start');
    }
    _ensureOut(length);
    // Overlapping copies (offset < length) must be byte-by-byte forward.
    if (offset >= length) {
      _out.setRange(_outLen, _outLen + length, _out, srcStart);
      _outLen += length;
    } else {
      var s = srcStart;
      var d = _outLen;
      for (var i = 0; i < length; i++) {
        _out[d++] = _out[s++];
      }
      _outLen += length;
    }
  }

  void _appendBytes(Uint8List src, int start, int end) {
    final n = end - start;
    if (n <= 0) return;
    _ensureOut(n);
    _out.setRange(_outLen, _outLen + n, src, start);
    _outLen += n;
  }

  // ---- Huffman literals decode ----

  void _decodeHuffmanLiterals(
    _HufTable table,
    int start,
    int end,
    int streams,
    Uint8List out,
  ) {
    if (streams == 1) {
      _decodeHuffStream(table, start, end, out, 0, out.length);
      return;
    }
    // 4 streams: a 6-byte jump table (3×2-byte little-endian) sizes streams
    // 1-3; stream 4 is the remainder.
    if (start + 6 > end) {
      throw const FormatException('truncated 4-stream literals jump table');
    }
    final s1 = _input[start] | (_input[start + 1] << 8);
    final s2 = _input[start + 2] | (_input[start + 3] << 8);
    final s3 = _input[start + 4] | (_input[start + 5] << 8);
    final p = start + 6;
    final total = out.length;
    final segment = (total + 3) ~/ 4;
    final bounds = [p, p + s1, p + s1 + s2, p + s1 + s2 + s3, end];
    for (var i = 0; i < 4; i++) {
      final outStart = i * segment;
      final outEnd = i == 3 ? total : (outStart + segment);
      if (bounds[i + 1] > end) {
        throw const FormatException('4-stream literals overrun');
      }
      _decodeHuffStream(table, bounds[i], bounds[i + 1], out, outStart, outEnd);
    }
  }

  void _decodeHuffStream(
    _HufTable table,
    int start,
    int end,
    Uint8List out,
    int outStart,
    int outEnd,
  ) {
    if (end <= start) {
      if (outEnd > outStart) {
        throw const FormatException('empty Huffman stream with output due');
      }
      return;
    }
    final bits = _ReverseBits(_input, start, end);
    for (var o = outStart; o < outEnd; o++) {
      out[o] = table.decode(bits);
    }
  }
}

/// One-shot Zstandard decoder as a [Converter], the `dart:convert` idiom.
final class ZstdDecoder extends Converter<List<int>, List<int>> {
  /// Creates a decoder.
  const ZstdDecoder();

  @override
  Uint8List convert(List<int> input) {
    final decoder =
        RawZstdDecoder()
          ..addInput(input is Uint8List ? input : Uint8List.fromList(input))
          ..close();
    final out = BytesBuilder(copy: false);
    for (Uint8List? block; (block = decoder.nextBlock()) != null;) {
      out.add(block!);
    }
    return out.takeBytes();
  }

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _ZstdSink(sink);
}

class _ZstdSink implements ByteConversionSink {
  _ZstdSink(this._downstream);

  final Sink<List<int>> _downstream;
  final RawZstdDecoder _decoder = RawZstdDecoder();

  @override
  void add(List<int> chunk) {
    _decoder.addInput(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(Uint8List.fromList(chunk.sublist(start, end)));
    if (isLast) close();
  }

  @override
  void close() {
    _decoder.close();
    for (Uint8List? block; (block = _decoder.nextBlock()) != null;) {
      _downstream.add(block!);
    }
    _downstream.close();
  }
}

// ---------------------------------------------------------------------------
// Entropy machinery
// ---------------------------------------------------------------------------

/// True on the web (dart2js / dart2wasm), where `int` is a 53-bit double and
/// 64-bit multiplication used by XXH64 is not exact. `0` and `0.0` are the same
/// value there and distinct on native platforms.
const bool _isWeb = identical(0, 0.0);

/// XXH64 of `data[start..end)` with seed 0, using native 64-bit integer
/// arithmetic (wraps mod 2^64). Only sound where `int` is 64-bit — callers gate
/// with [_isWeb]. Returns a value whose low 32 bits are what zstd stores.
int _xxh64(Uint8List data, int start, int end) {
  // Built from 32-bit halves at runtime: a literal above 2^53 fails to compile
  // under dart2js. Exact on native 64-bit `int` (the only place this runs); the
  // imprecise web values are never used ([_isWeb] gates every call).
  final p1 = 0x9E3779B1 * 0x100000000 + 0x85EBCA87;
  final p2 = 0xC2B2AE3D * 0x100000000 + 0x27D4EB4F;
  final p3 = 0x165667B1 * 0x100000000 + 0x9E3779F9;
  final p4 = 0x85EBCA77 * 0x100000000 + 0xC2B2AE63;
  final p5 = 0x27D4EB2F * 0x100000000 + 0x165667C5;
  int rotl(int x, int r) => (x << r) | (x >>> (64 - r));
  int read64(int i) {
    var v = 0;
    for (var k = 7; k >= 0; k--) {
      v = (v << 8) | data[i + k];
    }
    return v;
  }

  int read32(int i) =>
      data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24);

  final len = end - start;
  var p = start;
  int h;
  if (len >= 32) {
    var v1 = p1 + p2;
    var v2 = p2;
    var v3 = 0;
    var v4 = -p1;
    final limit = end - 32;
    while (p <= limit) {
      v1 = rotl(v1 + read64(p) * p2, 31) * p1;
      p += 8;
      v2 = rotl(v2 + read64(p) * p2, 31) * p1;
      p += 8;
      v3 = rotl(v3 + read64(p) * p2, 31) * p1;
      p += 8;
      v4 = rotl(v4 + read64(p) * p2, 31) * p1;
      p += 8;
    }
    h = rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18);
    v1 = rotl(v1 * p2, 31) * p1;
    h = (h ^ v1) * p1 + p4;
    v2 = rotl(v2 * p2, 31) * p1;
    h = (h ^ v2) * p1 + p4;
    v3 = rotl(v3 * p2, 31) * p1;
    h = (h ^ v3) * p1 + p4;
    v4 = rotl(v4 * p2, 31) * p1;
    h = (h ^ v4) * p1 + p4;
  } else {
    h = p5;
  }
  h += len;
  while (p + 8 <= end) {
    final k = rotl(read64(p) * p2, 31) * p1;
    h = rotl(h ^ k, 27) * p1 + p4;
    p += 8;
  }
  if (p + 4 <= end) {
    h = rotl(h ^ (read32(p) * p1), 23) * p2 + p3;
    p += 4;
  }
  while (p < end) {
    h = rotl(h ^ (data[p] * p5), 11) * p1;
    p++;
  }
  h ^= h >>> 33;
  h *= p2;
  h ^= h >>> 29;
  h *= p3;
  h ^= h >>> 32;
  return h;
}

/// Floor(log2(n)) for n >= 1 (position of the highest set bit).
int _highBit(int n) {
  var v = n;
  var b = 0;
  while (v > 1) {
    v >>= 1;
    b++;
  }
  return b;
}

/// MSB-first reader over a zstd entropy bitstream, which is read **backward**
/// from the last byte. The last byte's highest set bit is a padding marker;
/// real bits begin just below it. Reads are bounded to <= 16 bits so the
/// accumulator stays within the dart2js-exact 32-bit range.
final class _ReverseBits {
  _ReverseBits(this._d, this._start, int end) {
    _pos = end - 1;
    if (_pos < _start) {
      throw const FormatException('empty zstd bitstream');
    }
    final last = _d[_pos];
    if (last == 0) {
      throw const FormatException('zstd bitstream missing end marker');
    }
    _pos--;
    final hb = _highBit(last); // 0..7
    _acc = last & ((1 << hb) - 1);
    _accBits = hb;
  }

  final Uint8List _d;
  final int _start;
  late int _pos;
  int _acc = 0;
  int _accBits = 0;

  /// Set once a read requests more bits than the stream holds (padding with
  /// zeros). zstd's FSE/Huffman streams decode until this over-read, which is
  /// how the final symbols are emitted.
  bool _overread = false;

  void _fill(int n) {
    while (_accBits < n && _pos >= _start) {
      _acc = (_acc << 8) | _d[_pos];
      _pos--;
      _accBits += 8;
    }
  }

  int peekBits(int n) {
    if (n == 0) return 0;
    _fill(n);
    if (_accBits >= n) {
      return (_acc >>> (_accBits - n)) & ((1 << n) - 1);
    }
    // Past the start of the stream: missing low bits read as zero.
    _overread = true;
    return (_acc << (n - _accBits)) & ((1 << n) - 1);
  }

  void consume(int n) {
    if (n <= _accBits) {
      _accBits -= n;
      _acc &= (1 << _accBits) - 1;
    } else {
      _accBits = 0;
      _acc = 0;
    }
  }

  int readBits(int n) {
    final v = peekBits(n);
    consume(n);
    return v;
  }
}

/// An FSE decode table (state -> symbol, and state transition).
final class _FseTable {
  _FseTable(this.tableLog, this._symbol, this._nbBits, this._newState);

  final int tableLog;
  final Uint16List _symbol;
  final Uint8List _nbBits;
  final Uint16List _newState;

  int symbol(int state) => _symbol[state];

  int next(int state, _ReverseBits bits) =>
      _newState[state] + bits.readBits(_nbBits[state]);

  static _FseTable rle(int symbol) => _FseTable(
    0,
    Uint16List.fromList([symbol]),
    Uint8List.fromList([0]),
    Uint16List.fromList([0]),
  );

  static _FseTable build(List<int> counts, int tableLog) {
    final tableSize = 1 << tableLog;
    final symbols = Uint16List(tableSize);
    final nbBits = Uint8List(tableSize);
    final newState = Uint16List(tableSize);
    final symbolNext = List<int>.filled(counts.length, 0);

    var highThreshold = tableSize - 1;
    for (var s = 0; s < counts.length; s++) {
      if (counts[s] == -1) {
        symbols[highThreshold--] = s;
        symbolNext[s] = 1;
      } else {
        symbolNext[s] = counts[s];
      }
    }

    final step = (tableSize >> 1) + (tableSize >> 3) + 3;
    final mask = tableSize - 1;
    var pos = 0;
    for (var s = 0; s < counts.length; s++) {
      final c = counts[s];
      for (var i = 0; i < c; i++) {
        symbols[pos] = s;
        pos = (pos + step) & mask;
        while (pos > highThreshold) {
          pos = (pos + step) & mask;
        }
      }
    }

    for (var u = 0; u < tableSize; u++) {
      final s = symbols[u];
      final ns = symbolNext[s]++;
      final nb = tableLog - _highBit(ns);
      nbBits[u] = nb;
      newState[u] = (ns << nb) - tableSize;
    }
    return _FseTable(tableLog, symbols, nbBits, newState);
  }
}

/// A canonical Huffman decode table for zstd literals (peek maxBits, index).
final class _HufTable {
  _HufTable(this.maxBits, this._symbols, this._lengths);

  final int maxBits;
  final Uint8List _symbols;
  final Uint8List _lengths;

  int decode(_ReverseBits bits) {
    final code = bits.peekBits(maxBits);
    bits.consume(_lengths[code]);
    return _symbols[code];
  }

  /// Reads the Huffman table description at `[start, end)` and returns the
  /// table plus how many header bytes it consumed.
  static ({_HufTable table, int headerBytes}) read(
    Uint8List input,
    int start,
    int end,
  ) {
    final headerByte = input[start];
    final weights = List<int>.filled(256, 0);
    int nbSymbols;
    int headerBytes;

    if (headerByte < 128) {
      // FSE-compressed weights (headerByte is the compressed size).
      final compSize = headerByte;
      nbSymbols = _readFseWeights(
        input,
        start + 1,
        start + 1 + compSize,
        weights,
      );
      headerBytes = 1 + compSize;
    } else {
      // Direct: each weight is 4 bits, count = headerByte - 127.
      final n = headerByte - 127;
      headerBytes = 1 + ((n + 1) ~/ 2);
      final p = start + 1;
      for (var i = 0; i < n; i++) {
        final byte = input[p + (i >> 1)];
        weights[i] = (i & 1) == 0 ? (byte >> 4) : (byte & 0xF);
      }
      nbSymbols = n; // plus the implicit last symbol
    }

    return _buildFromWeights(weights, nbSymbols, headerBytes);
  }

  /// Decodes the FSE-compressed Huffman weight stream into [weights]; returns
  /// the number of explicit weights (the last symbol's weight is implicit).
  static int _readFseWeights(
    Uint8List input,
    int start,
    int end,
    List<int> weights,
  ) {
    final r = _NCountReader(input, start, end, 6);
    final nc = r.read();
    final fse = _FseTable.build(nc.counts, nc.tableLog);
    final bits = _ReverseBits(input, r.bytePos, end);
    var s1 = bits.readBits(fse.tableLog);
    var s2 = bits.readBits(fse.tableLog);
    var n = 0;
    // Two interleaved states emit weights alternately; each emit advances its
    // own state by reading bits. Decoding continues until an advance over-reads
    // the stream, at which point the other state's pending symbol is the last.
    while (true) {
      weights[n++] = fse.symbol(s1);
      s1 = fse._newState[s1] + bits.readBits(fse._nbBits[s1]);
      if (bits._overread) {
        weights[n++] = fse.symbol(s2);
        break;
      }
      weights[n++] = fse.symbol(s2);
      s2 = fse._newState[s2] + bits.readBits(fse._nbBits[s2]);
      if (bits._overread) {
        weights[n++] = fse.symbol(s1);
        break;
      }
      if (n > 255) {
        throw const FormatException('too many zstd Huffman weights');
      }
    }
    return n;
  }

  static ({_HufTable table, int headerBytes}) _buildFromWeights(
    List<int> weights,
    int nbSymbols,
    int headerBytes,
  ) {
    // Total of 2^(w-1); the implicit last symbol fills to a power of two.
    var total = 0;
    for (var i = 0; i < nbSymbols; i++) {
      if (weights[i] > 0) total += 1 << (weights[i] - 1);
    }
    if (total == 0) {
      throw const FormatException('empty zstd Huffman table');
    }
    final maxBits = _highBit(total) + 1;
    final left = (1 << maxBits) - total;
    if (left <= 0 || (left & (left - 1)) != 0) {
      throw const FormatException('corrupt zstd Huffman weights');
    }
    final lastWeight = _highBit(left) + 1;
    weights[nbSymbols] = lastWeight;
    final n = nbSymbols + 1;

    // zstd's rank-based fill (HUF_readDTableX1): weight-1 (longest codes) fill
    // the low table positions first, higher weights (shorter codes) after — the
    // reverse of a length-ascending canonical build. A weight-w symbol occupies
    // 2^(w-1) consecutive entries with nbBits = maxBits + 1 - w.
    final rankCount = List<int>.filled(maxBits + 2, 0);
    for (var s = 0; s < n; s++) {
      if (weights[s] > 0) rankCount[weights[s]]++;
    }
    final rankStart = List<int>.filled(maxBits + 2, 0);
    var next = 0;
    for (var w = 1; w <= maxBits; w++) {
      rankStart[w] = next;
      next += rankCount[w] << (w - 1);
    }

    final tableSize = 1 << maxBits;
    final symbols = Uint8List(tableSize);
    final bitsTable = Uint8List(tableSize);
    for (var s = 0; s < n; s++) {
      final w = weights[s];
      if (w == 0) continue;
      final length = 1 << (w - 1);
      final nbBits = maxBits + 1 - w;
      final u = rankStart[w];
      for (var i = 0; i < length; i++) {
        symbols[u + i] = s;
        bitsTable[u + i] = nbBits;
      }
      rankStart[w] = u + length;
    }
    return (
      table: _HufTable(maxBits, symbols, bitsTable),
      headerBytes: headerBytes,
    );
  }
}

/// Reads a normalized FSE distribution (`FSE_readNCount`) forward, LSB-first.
/// Uses a bit-at-a-time reader — dart2js-safe and simple; table headers are
/// tiny, so speed does not matter here.
final class _NCountReader {
  _NCountReader(this._d, this._start, this._end, this._maxLog);

  final Uint8List _d;
  final int _start;
  final int _end;
  final int _maxLog;

  int _bit = 0; // bit offset from _start
  int bytePos = 0;

  int _readBits(int n) {
    var result = 0;
    for (var i = 0; i < n; i++) {
      final bytePos = _start + (_bit >> 3);
      final bit = bytePos < _end ? (_d[bytePos] >> (_bit & 7)) & 1 : 0;
      result |= bit << i;
      _bit++;
    }
    return result;
  }

  ({List<int> counts, int tableLog}) read() {
    final tableLog = _readBits(4) + 5;
    if (tableLog > _maxLog) {
      throw const FormatException('zstd FSE table log too large');
    }
    var remaining = (1 << tableLog) + 1;
    var threshold = 1 << tableLog;
    var nbBits = tableLog + 1;

    final counts = <int>[];
    var previous0 = false;

    while (remaining > 1 && counts.length < 256) {
      if (previous0) {
        var repeat = 0;
        while (true) {
          final t = _readBits(2);
          if (t == 3) {
            repeat += 3;
          } else {
            repeat += t;
            break;
          }
        }
        for (var i = 0; i < repeat && counts.length < 256; i++) {
          counts.add(0);
        }
        previous0 = false;
        continue;
      }

      final max = (2 * threshold - 1) - remaining;
      final low = _readBits(nbBits - 1);
      int value;
      if (low < max) {
        value = low;
      } else {
        value = low | (_readBits(1) << (nbBits - 1));
        if (value >= threshold) value -= max;
      }
      final count = value - 1; // -1 encodes "less than one"
      remaining -= count < 0 ? -count : count;
      counts.add(count);
      previous0 = count == 0;

      while (remaining < threshold) {
        nbBits--;
        threshold >>= 1;
      }
    }

    bytePos = _start + ((_bit + 7) >> 3);
    return (counts: counts, tableLog: tableLog);
  }
}

// ---- Constant tables (RFC 8878) ----

const List<int> _llBase = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
  8192, 16384, 32768, 65536,
];
const List<int> _llBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
];
const List<int> _mlBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, //
  23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51,
  59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539,
];
const List<int> _mlBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 16,
];

// Predefined FSE distributions (a -1 count means "less than one").
final _llPredef = _FseTable.build(const [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, //
  2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
], 6);
final _ofPredef = _FseTable.build(const [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  -1, -1, -1, -1, -1,
], 5);
final _mlPredef = _FseTable.build(const [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1,
  -1, -1, -1, -1,
], 6);

/// Zstandard compression (RFC 8878), the encode direction of [ZstdDecoder].
///
/// A correctness-first encoder: one frame, single-segment header with the
/// content size, no content checksum, no dictionary. Data is split into blocks
/// of at most 128 KiB. Each block is either stored raw or compressed with LZ
/// sequences over the **predefined** FSE tables (no custom entropy tables) with
/// raw (uncompressed) literals — so the ratio is below `zstd`'s, while the
/// output stays byte-decodable by `zstd` / libzstd and by [ZstdDecoder].
///
/// Match finding is a greedy hash-chain search; offsets are always emitted as
/// new offsets (the repeat-offset codes are never used), which is always valid
/// and keeps the sequence encoder simple.
library;

import 'dart:typed_data';

/// The 4-byte Zstandard frame magic (little-endian on the wire).
const int _zstdMagic = 0xFD2FB528;

/// Largest single block's content size (128 KiB), per the format.
const int _blockSizeMax = 1 << 17;

/// The encoder caps a single-frame window (and therefore match distance and the
/// declared content size) at 128 MiB, matching the decoder's window limit.
const int _maxContent = 128 * 1024 * 1024;

/// One-shot Zstandard compressor.
final class ZstdEncoder {
  /// Creates an encoder.
  ZstdEncoder();

  /// Compresses [data] into a complete single-frame `.zst` stream.
  Uint8List encode(Uint8List data) {
    if (data.length > _maxContent) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'this encoder writes one frame with a window up to $_maxContent bytes',
      );
    }
    // Fresh match-finder state per call, so an encoder instance is reusable.
    _hashHead = Int32List(1 << _hashLog);
    _chain = Int32List(data.length);

    final out = BytesBuilder(copy: false);
    _writeFrameHeader(out, data.length);

    var pos = 0;
    if (data.isEmpty) {
      // A frame needs at least one block; emit an empty last raw block.
      _writeBlockHeader(out, lastBlock: true, type: 0, size: 0);
      return out.takeBytes();
    }
    while (pos < data.length) {
      final end =
          pos + _blockSizeMax < data.length ? pos + _blockSizeMax : data.length;
      final isLast = end == data.length;
      _writeBlock(out, data, pos, end, isLast);
      pos = end;
    }
    return out.takeBytes();
  }

  // --- framing ---------------------------------------------------------------

  void _writeFrameHeader(BytesBuilder out, int contentSize) {
    out
      ..addByte(_zstdMagic & 0xFF)
      ..addByte((_zstdMagic >> 8) & 0xFF)
      ..addByte((_zstdMagic >> 16) & 0xFF)
      ..addByte((_zstdMagic >> 24) & 0xFF);

    // Single-segment (window = content), no checksum, no dictionary. The FCS
    // field size is chosen from the content size; single-segment always writes
    // at least one FCS byte.
    int fcsFlag;
    int fcsBytes;
    if (contentSize < 256) {
      fcsFlag = 0;
      fcsBytes = 1;
    } else if (contentSize < 65536 + 256) {
      fcsFlag = 1;
      fcsBytes = 2;
    } else if (contentSize < 0x100000000) {
      fcsFlag = 2;
      fcsBytes = 4;
    } else {
      fcsFlag = 3;
      fcsBytes = 8;
    }
    final desc = (fcsFlag << 6) | (1 << 5);
    out.addByte(desc);

    // FCS value, little-endian. The 2-byte form stores (size - 256).
    var v = fcsBytes == 2 ? contentSize - 256 : contentSize;
    for (var i = 0; i < fcsBytes; i++) {
      out.addByte(v % 256);
      v = v ~/ 256;
    }
  }

  void _writeBlockHeader(
    BytesBuilder out, {
    required bool lastBlock,
    required int type,
    required int size,
  }) {
    final header = (lastBlock ? 1 : 0) | (type << 1) | (size << 3);
    out
      ..addByte(header & 0xFF)
      ..addByte((header >> 8) & 0xFF)
      ..addByte((header >> 16) & 0xFF);
  }

  void _writeRawBlock(
    BytesBuilder out,
    Uint8List data,
    int start,
    int end,
    bool isLast,
  ) {
    final size = end - start;
    _writeBlockHeader(out, lastBlock: isLast, type: 0, size: size);
    out.add(Uint8List.sublistView(data, start, end));
  }

  // A hash chain over the whole input, so a block's matches can reference data
  // in earlier blocks (within the single-segment window). Lazily initialized.
  Int32List? _hashHead; // hash -> most recent position (+1; 0 = empty)
  Int32List? _chain; // position -> previous position with the same hash (+1)
  static const int _hashLog = 15;
  static const int _minMatch = 3;
  static const int _maxChain = 64; // search depth cap

  int _hash(Uint8List d, int i) {
    // 3-byte Fibonacci hash. The multiply uses low-32-bit split arithmetic:
    // `v * 0x9E3779B1` (v up to 2^24) overflows 2^53 and would lose its low
    // bits as a double on dart2js, changing the bucket and the output.
    final v = d[i] | (d[i + 1] << 8) | (d[i + 2] << 16);
    return (_mul32Low(v, 0x9E3779B1) >>> (32 - _hashLog)) &
        ((1 << _hashLog) - 1);
  }

  void _insert(Uint8List d, int i) {
    if (i + _minMatch > d.length) return;
    final h = _hash(d, i);
    _chain![i] = _hashHead![h];
    _hashHead![h] = i + 1;
  }

  // Try to compress [start,end); returns the compressed block body (literals +
  // sequences sections) or null if it would not be smaller than a raw block.
  Uint8List? _compressBlock(Uint8List data, int start, int end) {
    _hashHead ??= Int32List(1 << _hashLog);
    _chain ??= Int32List(data.length);

    final literals = BytesBuilder();
    // Sequences as flat (litLen, matchLen, offsetValue) triples.
    final seqLL = <int>[];
    final seqML = <int>[];
    final seqOF = <int>[];

    var pos = start;
    var litStart = start;
    final limit = end - _minMatch; // last position with a full hash window
    while (pos < end) {
      if (pos > limit) {
        _insert(data, pos);
        pos++;
        continue;
      }
      // Find the best match for data[pos..].
      var bestLen = 0;
      var bestPos = -1;
      final h = _hash(data, pos);
      var cand = _hashHead![h] - 1;
      var depth = 0;
      while (cand >= 0 && depth < _maxChain) {
        // Extend the match.
        var len = 0;
        while (pos + len < end && data[pos + len] == data[cand + len]) {
          len++;
        }
        if (len > bestLen) {
          bestLen = len;
          bestPos = cand;
        }
        cand = _chain![cand] - 1;
        depth++;
      }

      if (bestLen >= _minMatch) {
        final litLen = pos - litStart;
        literals.add(Uint8List.sublistView(data, litStart, pos));
        final offset = pos - bestPos;
        seqLL.add(litLen);
        seqML.add(bestLen);
        seqOF.add(offset + 3); // always a new offset (offsetValue = offset + 3)
        // Insert positions covered by the match so later matches can find them.
        final matchEnd = pos + bestLen;
        while (pos < matchEnd) {
          _insert(data, pos);
          pos++;
        }
        litStart = pos;
      } else {
        _insert(data, pos);
        pos++;
      }
    }
    // Trailing literals after the last sequence.
    literals.add(Uint8List.sublistView(data, litStart, end));
    final litBytes = literals.takeBytes();
    final nbSeq = seqLL.length;

    final body = BytesBuilder(copy: false);
    _writeLiteralsSection(body, litBytes);
    _writeSequencesSection(body, nbSeq, seqLL, seqML, seqOF);
    final result = body.takeBytes();

    // Fall back to raw when compression does not pay off.
    if (result.length >= end - start) return null;
    return result;
  }

  void _writeLiteralsSection(BytesBuilder out, Uint8List lits) {
    final n = lits.length;
    // Raw literals (litType 0).
    if (n < 32) {
      out.addByte(n << 3); // sizeFormat 0
    } else if (n < 4096) {
      out
        ..addByte((1 << 2) | ((n & 0xF) << 4)) // sizeFormat 1
        ..addByte(n >> 4);
    } else {
      out
        ..addByte((3 << 2) | ((n & 0xF) << 4)) // sizeFormat 3 (20-bit)
        ..addByte((n >> 4) & 0xFF)
        ..addByte((n >> 12) & 0xFF);
    }
    out.add(lits);
  }

  void _writeSequencesSection(
    BytesBuilder out,
    int nbSeq,
    List<int> seqLL,
    List<int> seqML,
    List<int> seqOF,
  ) {
    // nbSeq (1-3 bytes).
    if (nbSeq == 0) {
      out.addByte(0);
      return;
    }
    if (nbSeq < 128) {
      out.addByte(nbSeq);
    } else if (nbSeq < 0x7F00) {
      out
        ..addByte((nbSeq >> 8) + 128)
        ..addByte(nbSeq & 0xFF);
    } else {
      out
        ..addByte(255)
        ..addByte((nbSeq - 0x7F00) & 0xFF)
        ..addByte((nbSeq - 0x7F00) >> 8);
    }
    // Modes byte: all three tables predefined (mode 0).
    out.addByte(0);

    // Compute per-sequence (code, extraValue, extraBits).
    final llCode = List<int>.filled(nbSeq, 0);
    final mlCode = List<int>.filled(nbSeq, 0);
    final ofCode = List<int>.filled(nbSeq, 0);
    for (var i = 0; i < nbSeq; i++) {
      llCode[i] = _llCodeFor(seqLL[i]);
      mlCode[i] = _mlCodeFor(seqML[i]);
      ofCode[i] = _zHighBit(seqOF[i]); // offsetValue >= 4 -> ofCode >= 2
    }

    final llCT = _FseCTable.build(_llPredefCounts, 6);
    final ofCT = _FseCTable.build(_ofPredefCounts, 5);
    final mlCT = _FseCTable.build(_mlPredefCounts, 6);

    final w = _ZstdBitWriter();
    // Initialize states with the last sequence, then its extra bits (LL,ML,OF).
    var llState = llCT.initState(llCode[nbSeq - 1]);
    var ofState = ofCT.initState(ofCode[nbSeq - 1]);
    var mlState = mlCT.initState(mlCode[nbSeq - 1]);
    w.addBits(seqLL[nbSeq - 1] - _llBaseTab[llCode[nbSeq - 1]], _llBitsTab[llCode[nbSeq - 1]]);
    w.addBits(seqML[nbSeq - 1] - _mlBaseTab[mlCode[nbSeq - 1]], _mlBitsTab[mlCode[nbSeq - 1]]);
    w.addBits(seqOF[nbSeq - 1] - (1 << ofCode[nbSeq - 1]), ofCode[nbSeq - 1]);

    for (var i = nbSeq - 2; i >= 0; i--) {
      ofState = ofCT.encode(w, ofState, ofCode[i]);
      mlState = mlCT.encode(w, mlState, mlCode[i]);
      llState = llCT.encode(w, llState, llCode[i]);
      w.addBits(seqLL[i] - _llBaseTab[llCode[i]], _llBitsTab[llCode[i]]);
      w.addBits(seqML[i] - _mlBaseTab[mlCode[i]], _mlBitsTab[mlCode[i]]);
      w.addBits(seqOF[i] - (1 << ofCode[i]), ofCode[i]);
    }

    mlCT.flush(w, mlState);
    ofCT.flush(w, ofState);
    llCT.flush(w, llState);
    out.add(w.finish());
  }

  static int _llCodeFor(int litLen) {
    var c = _llBaseTab.length - 1;
    while (_llBaseTab[c] > litLen) {
      c--;
    }
    return c;
  }

  static int _mlCodeFor(int matchLen) {
    var c = _mlBaseTab.length - 1;
    while (_mlBaseTab[c] > matchLen) {
      c--;
    }
    return c;
  }

  void _writeBlock(
    BytesBuilder out,
    Uint8List data,
    int start,
    int end,
    bool isLast,
  ) {
    final compressed = _compressBlock(data, start, end);
    if (compressed == null) {
      _writeRawBlock(out, data, start, end, isLast);
      return;
    }
    _writeBlockHeader(
      out,
      lastBlock: isLast,
      type: 2,
      size: compressed.length,
    );
    out.add(compressed);
  }
}

/// A forward bit writer producing a stream the decoder's `_ReverseBits` reads
/// from the end: bits are appended LSB-first at increasing positions, whole
/// bytes drained little-endian; [finish] adds the 1-bit end marker.
final class _ZstdBitWriter {
  final BytesBuilder _out = BytesBuilder();
  int _acc = 0;
  int _nbits = 0;

  /// Appends the low [n] bits of [value] (n up to ~28), LSB first. Split into
  /// ≤16-bit chunks so the 32-bit accumulator never overflows on dart2js.
  void addBits(int value, int n) {
    var v = value;
    var remaining = n;
    while (remaining > 0) {
      final take = remaining < 16 ? remaining : 16;
      _acc |= (v & ((1 << take) - 1)) << _nbits;
      _nbits += take;
      v >>= take;
      remaining -= take;
      while (_nbits >= 8) {
        _out.addByte(_acc & 0xFF);
        _acc >>= 8;
        _nbits -= 8;
      }
    }
  }

  /// Adds the end-marker bit and flushes the final partial byte; the marker is
  /// the highest set bit of the last byte.
  Uint8List finish() {
    addBits(1, 1);
    if (_nbits > 0) {
      _out.addByte(_acc & 0xFF);
      _acc = 0;
      _nbits = 0;
    }
    return _out.takeBytes();
  }
}

/// An FSE encoding table: the inverse of the decoder's `_FseTable.build`.
final class _FseCTable {
  _FseCTable(
    this.tableLog,
    this._stateTable,
    this._deltaNbBits,
    this._deltaFindState,
  );

  final int tableLog;
  final Uint16List _stateTable;
  final List<int> _deltaNbBits;
  final List<int> _deltaFindState;

  /// Initial encoder state for the first-encoded (last-decoded... last in
  /// stream) symbol. Appends nothing.
  int initState(int symbol) {
    final dnb = _deltaNbBits[symbol];
    final nbBitsOut = (dnb + (1 << 15)) >> 16;
    final value = (nbBitsOut << 16) - dnb;
    return _stateTable[(value >> nbBitsOut) + _deltaFindState[symbol]];
  }

  /// Encodes [symbol] from encoder [state]: appends the state's low bits and
  /// returns the next state.
  int encode(_ZstdBitWriter w, int state, int symbol) {
    final nbBitsOut = (state + _deltaNbBits[symbol]) >> 16;
    w.addBits(state, nbBitsOut);
    return _stateTable[(state >> nbBitsOut) + _deltaFindState[symbol]];
  }

  /// Flushes the final state (the decoder reads it as the initial state).
  void flush(_ZstdBitWriter w, int state) => w.addBits(state, tableLog);

  static _FseCTable build(List<int> normCounts, int tableLog) {
    final tableSize = 1 << tableLog;
    final tableMask = tableSize - 1;
    final maxSymbol = normCounts.length - 1;

    final tableSymbol = Uint16List(tableSize);
    var highThreshold = tableSize - 1;
    final cumul = List<int>.filled(maxSymbol + 2, 0);
    for (var s = 0; s <= maxSymbol; s++) {
      if (normCounts[s] == -1) {
        cumul[s + 1] = cumul[s] + 1;
        tableSymbol[highThreshold--] = s;
      } else {
        cumul[s + 1] = cumul[s] + normCounts[s];
      }
    }

    final step = (tableSize >> 1) + (tableSize >> 3) + 3;
    var pos = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      final n = normCounts[s];
      for (var i = 0; i < n; i++) {
        tableSymbol[pos] = s;
        pos = (pos + step) & tableMask;
        while (pos > highThreshold) {
          pos = (pos + step) & tableMask;
        }
      }
    }

    // stateTable: fill by symbol in first-occurrence order, matching the
    // decoder's newState assignment.
    final stateTable = Uint16List(tableSize);
    final cumulCopy = List<int>.from(cumul);
    for (var u = 0; u < tableSize; u++) {
      final s = tableSymbol[u];
      stateTable[cumulCopy[s]++] = tableSize + u;
    }

    final deltaNbBits = List<int>.filled(maxSymbol + 1, 0);
    final deltaFindState = List<int>.filled(maxSymbol + 1, 0);
    var total = 0;
    for (var s = 0; s <= maxSymbol; s++) {
      final n = normCounts[s];
      if (n == 0) {
        deltaNbBits[s] = ((tableLog + 1) << 16) - (1 << tableLog);
      } else if (n == -1 || n == 1) {
        deltaNbBits[s] = (tableLog << 16) - (1 << tableLog);
        deltaFindState[s] = total - 1;
        total += 1;
      } else {
        final maxBitsOut = tableLog - _zHighBit(n - 1);
        final minStatePlus = n << maxBitsOut;
        deltaNbBits[s] = (maxBitsOut << 16) - minStatePlus;
        deltaFindState[s] = total - n;
        total += n;
      }
    }
    return _FseCTable(tableLog, stateTable, deltaNbBits, deltaFindState);
  }
}

int _zHighBit(int n) {
  var v = n;
  var b = 0;
  while (v > 1) {
    v >>= 1;
    b++;
  }
  return b;
}

/// The low 32 bits of `a * b` (a, b < 2^32), via 16-bit halves so every
/// intermediate stays under 2^53 and is exact on dart2js.
int _mul32Low(int a, int b) {
  final aLo = a & 0xFFFF;
  final aHi = a >>> 16;
  final bLo = b & 0xFFFF;
  final bHi = b >>> 16;
  final mid = (aHi * bLo + aLo * bHi) & 0xFFFF;
  return (aLo * bLo + (mid << 16)) & 0xFFFFFFFF;
}

// Literal-length and match-length code base/extra-bits tables (mirror the
// decoder's `_llBase`/`_llBits`/`_mlBase`/`_mlBits`).
const List<int> _llBaseTab = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
  8192, 16384, 32768, 65536,
];
const List<int> _llBitsTab = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
];
const List<int> _mlBaseTab = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, //
  23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51,
  59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539,
];
const List<int> _mlBitsTab = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 16,
];

// Predefined FSE distributions (a -1 count means "less than one"), matching the
// decoder's `_llPredef`/`_ofPredef`/`_mlPredef`.
const List<int> _llPredefCounts = [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, //
  2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
];
const List<int> _ofPredefCounts = [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  -1, -1, -1, -1, -1,
];
const List<int> _mlPredefCounts = [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1,
  -1, -1, -1, -1,
];

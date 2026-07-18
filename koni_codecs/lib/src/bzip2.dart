/// bzip2 decompression (Julian Seward's format, versions `BZh1`–`BZh9`).
///
/// Clean-room from the bzip2 format: an MSB-first bit stream of independent
/// blocks, each a Huffman-coded MTF/RLE2 stream that inverts to a
/// Burrows–Wheeler transform, then an inverse BWT and an outer run-length
/// (RLE1) decode. Streams may be concatenated. On malformed input everything
/// here throws [FormatException] (the `dart:convert` idiom); the archive layer
/// translates that into its typed hierarchy.
///
/// [RawBzip2Decoder] is the resumable engine: feed compressed input with
/// [RawBzip2Decoder.addInput], call [RawBzip2Decoder.close], then pull one
/// decoded block at a time with [RawBzip2Decoder.nextBlock] — bounded to one
/// ~900 KiB block of output at a time, so a reader can stream and a size guard
/// can abort between blocks. [Bzip2Decoder] wraps it as a one-shot
/// [Converter].
///
/// Not supported (a typed [FormatException], never a silent mis-decode):
/// **randomized blocks** — a deprecated bzip2 ≤ 0.9.0 feature no modern encoder
/// emits, so it cannot be fixture-tested.
library;

import 'dart:convert';
import 'dart:typed_data';

/// CRC-32/BZIP2: the same polynomial as CRC-32 but **not** reflected — it
/// shifts left, MSB-first, matching bzip2's checksum. Kept local to this codec.
final class _Bz2Crc {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i << 24;
      for (var k = 0; k < 8; k++) {
        c =
            (c & 0x80000000) != 0
                ? ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
                : (c << 1) & 0xFFFFFFFF;
      }
      table[i] = c;
    }
    return table;
  }

  int _crc = 0xFFFFFFFF;

  void add(Uint8List data) {
    var crc = _crc;
    final t = _table;
    for (var i = 0; i < data.length; i++) {
      crc = ((crc << 8) ^ t[((crc >>> 24) ^ data[i]) & 0xFF]) & 0xFFFFFFFF;
    }
    _crc = crc;
  }

  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// MSB-first bit cursor over the (fully buffered) compressed input.
final class _BitReader {
  _BitReader(this._bytes);

  Uint8List _bytes;
  int _bytePos = 0;
  int _bitBuf = 0;
  int _bitCount = 0;

  void replaceBuffer(Uint8List bytes, int bytePos) {
    _bytes = bytes;
    _bytePos = bytePos;
    _bitBuf = 0;
    _bitCount = 0;
  }

  /// Reads [n] bits (1–24), MSB-first.
  int readBits(int n) {
    while (_bitCount < n) {
      if (_bytePos >= _bytes.length) {
        throw const FormatException('truncated bzip2 stream');
      }
      _bitBuf = ((_bitBuf << 8) | _bytes[_bytePos++]) & 0xFFFFFFFF;
      _bitCount += 8;
    }
    _bitCount -= n;
    return (_bitBuf >>> _bitCount) & ((1 << n) - 1);
  }

  int readBit() => readBits(1);

  /// Reads a 32-bit value as two 16-bit halves (a single 32-bit mask would
  /// overflow the dart2js bitwise range).
  int readUint32() => readBits(16) * 0x10000 + readBits(16);

  /// Drops the partial bits of the current byte, realigning to a byte boundary,
  /// then flushes any whole buffered bytes so [bytesRemaining]/[peekMagic] read
  /// straight from the buffer.
  void alignToByte() {
    final partial = _bitCount & 7;
    if (partial != 0) readBits(partial);
    _bytePos -= _bitCount >> 3;
    _bitCount = 0;
    _bitBuf = 0;
  }

  int get bytesRemaining => _bytes.length - _bytePos;

  /// Whether the next four bytes are a `BZh<digit>` stream header (only valid
  /// right after [alignToByte]).
  bool get atStreamHeader {
    if (bytesRemaining < 4) return false;
    return _bytes[_bytePos] == 0x42 &&
        _bytes[_bytePos + 1] == 0x5A &&
        _bytes[_bytePos + 2] == 0x68 &&
        _bytes[_bytePos + 3] >= 0x31 &&
        _bytes[_bytePos + 3] <= 0x39;
  }
}

/// Resumable bzip2 decompressor. See the library docs for the pull model.
final class RawBzip2Decoder {
  /// Creates a decoder; feed it with [addInput].
  RawBzip2Decoder();

  static const int _blockMagicHi = 0x314159;
  static const int _blockMagicLo = 0x265359;
  static const int _eosMagicHi = 0x177245;
  static const int _eosMagicLo = 0x385090;
  static const int _runA = 0;
  static const int _runB = 1;

  final BytesBuilder _input = BytesBuilder(copy: false);
  _BitReader? _bits;
  bool _closed = false;
  bool _streamDone = false;

  int _blockSize100k = 0;
  int _combinedCrc = 0;

  /// Appends compressed input.
  void addInput(Uint8List chunk) {
    if (_closed) {
      throw StateError('addInput after close()');
    }
    _input.add(chunk);
  }

  /// Declares the compressed input complete; blocks may then be pulled.
  void close() {
    if (_closed) return;
    _closed = true;
    _bits = _BitReader(_input.takeBytes());
    _parseStreamHeader();
  }

  void _parseStreamHeader() {
    final bits = _bits!;
    // "BZh" then a block-size digit '1'..'9'.
    if (bits.readBits(8) != 0x42 ||
        bits.readBits(8) != 0x5A ||
        bits.readBits(8) != 0x68) {
      throw const FormatException('not a bzip2 stream (bad magic)');
    }
    final level = bits.readBits(8);
    if (level < 0x31 || level > 0x39) {
      throw const FormatException('invalid bzip2 block-size byte');
    }
    _blockSize100k = level - 0x30;
    _combinedCrc = 0;
  }

  /// Decodes and returns the next block's bytes, or null at end of input.
  Uint8List? nextBlock() {
    if (!_closed) {
      throw StateError('close() the decoder before pulling blocks');
    }
    final bits = _bits!;
    while (true) {
      if (_streamDone) return null;
      final hi = bits.readBits(24);
      final lo = bits.readBits(24);
      if (hi == _blockMagicHi && lo == _blockMagicLo) {
        return _decodeBlock(bits);
      }
      if (hi == _eosMagicHi && lo == _eosMagicLo) {
        final stored = bits.readUint32();
        if (stored != _combinedCrc) {
          throw const FormatException('bzip2 stream CRC mismatch');
        }
        bits.alignToByte();
        if (bits.atStreamHeader) {
          _parseStreamHeader();
          continue;
        }
        _streamDone = true;
        return null;
      }
      throw const FormatException('bad bzip2 block magic');
    }
  }

  Uint8List _decodeBlock(_BitReader bits) {
    final blockCrc = bits.readUint32();
    if (bits.readBit() != 0) {
      throw const FormatException('bzip2 randomized blocks are not supported');
    }
    final origPtr = bits.readBits(24);

    // --- symbol map: which byte values occur ---
    final inUse = List<bool>.filled(256, false);
    final inUse16 = bits.readBits(16);
    for (var i = 0; i < 16; i++) {
      if ((inUse16 & (0x8000 >> i)) != 0) {
        final bits16 = bits.readBits(16);
        for (var j = 0; j < 16; j++) {
          if ((bits16 & (0x8000 >> j)) != 0) inUse[i * 16 + j] = true;
        }
      }
    }
    final seqToUnseq = <int>[];
    for (var i = 0; i < 256; i++) {
      if (inUse[i]) seqToUnseq.add(i);
    }
    final nInUse = seqToUnseq.length;
    if (nInUse == 0) throw const FormatException('bzip2 block uses no symbols');
    final alphaSize = nInUse + 2;
    final eob = nInUse + 1;

    // --- Huffman group selectors ---
    final nGroups = bits.readBits(3);
    if (nGroups < 2 || nGroups > 6) {
      throw const FormatException('bad bzip2 group count');
    }
    final nSelectors = bits.readBits(15);
    if (nSelectors < 1) {
      throw const FormatException('bad bzip2 selector count');
    }
    final selectorMtf = Uint8List(nSelectors);
    for (var i = 0; i < nSelectors; i++) {
      var j = 0;
      while (bits.readBit() != 0) {
        j++;
        if (j >= nGroups) throw const FormatException('bad bzip2 selector');
      }
      selectorMtf[i] = j;
    }
    // MTF-decode the selectors.
    final pos = List<int>.generate(nGroups, (i) => i);
    final selectors = Uint8List(nSelectors);
    for (var i = 0; i < nSelectors; i++) {
      final v = selectorMtf[i];
      final tmp = pos[v];
      for (var k = v; k > 0; k--) {
        pos[k] = pos[k - 1];
      }
      pos[0] = tmp;
      selectors[i] = tmp;
    }

    // --- per-group Huffman tables (delta-coded lengths) ---
    final tables = List.generate(
      nGroups,
      (_) => _HuffmanTable(_readLengths(bits, alphaSize)),
    );

    // --- decode the MTF/RLE2 symbol stream into the BWT last column ---
    final blockMax = _blockSize100k * 100000;
    final bwt = Uint8List(blockMax);
    final unzftab = Uint32List(256);
    var nblock = 0;

    // MTF list over the in-use byte values.
    final mtf = Uint8List.fromList(seqToUnseq);

    var groupNo = -1;
    var groupPos = 0;
    late _HuffmanTable table;
    int nextSym() {
      if (groupPos == 0) {
        groupNo++;
        if (groupNo >= nSelectors) {
          throw const FormatException('bzip2 ran out of Huffman selectors');
        }
        groupPos = 50;
        table = tables[selectors[groupNo]];
      }
      groupPos--;
      return table.decode(bits);
    }

    var runLen = 0;
    var runBit = 0;
    var sym = nextSym();
    while (sym != eob) {
      if (sym == _runA || sym == _runB) {
        runLen += (sym == _runA ? 1 : 2) << runBit;
        runBit++;
        if (runLen > blockMax) {
          throw const FormatException('bzip2 block overflow');
        }
      } else {
        if (runLen > 0) {
          final b = mtf[0];
          if (nblock + runLen > blockMax) {
            throw const FormatException('bzip2 block overflow');
          }
          for (var k = 0; k < runLen; k++) {
            bwt[nblock++] = b;
          }
          unzftab[b] += runLen;
          runLen = 0;
          runBit = 0;
        }
        // sym in 2..eob-1 -> MTF index sym-1.
        final idx = sym - 1;
        final b = mtf[idx];
        for (var k = idx; k > 0; k--) {
          mtf[k] = mtf[k - 1];
        }
        mtf[0] = b;
        if (nblock >= blockMax) {
          throw const FormatException('bzip2 block overflow');
        }
        bwt[nblock++] = b;
        unzftab[b]++;
      }
      sym = nextSym();
    }
    // A trailing zero-run just before EOB.
    if (runLen > 0) {
      final b = mtf[0];
      if (nblock + runLen > blockMax) {
        throw const FormatException('bzip2 block overflow');
      }
      for (var k = 0; k < runLen; k++) {
        bwt[nblock++] = b;
      }
      unzftab[b] += runLen;
    }

    if (origPtr >= nblock) {
      throw const FormatException('bzip2 origin pointer out of range');
    }

    // --- inverse BWT ---
    final cftab = Uint32List(257);
    for (var i = 0; i < 256; i++) {
      cftab[i + 1] = unzftab[i];
    }
    for (var i = 1; i <= 256; i++) {
      cftab[i] += cftab[i - 1];
    }
    final tt = Uint32List(nblock);
    for (var i = 0; i < nblock; i++) {
      final b = bwt[i];
      tt[cftab[b]] = i;
      cftab[b]++;
    }

    // --- walk the transform + inverse RLE1, computing the block CRC ---
    final out = BytesBuilder(copy: false);
    final crc = _Bz2Crc();
    var tPos = tt[origPtr];
    var pending = 0; // bytes decoded from the BWT walk, before RLE1
    // RLE1 state.
    var last = -1;
    var runCount = 0;
    // Emit in chunks to keep CRC/output efficient.
    final scratch = Uint8List(0x8000);
    var sp = 0;
    void emit(int byte) {
      scratch[sp++] = byte;
      if (sp == scratch.length) {
        final chunk = Uint8List.fromList(Uint8List.sublistView(scratch, 0, sp));
        crc.add(chunk);
        out.add(chunk);
        sp = 0;
      }
    }

    while (pending < nblock) {
      final b = bwt[tPos];
      tPos = tt[tPos];
      pending++;
      if (runCount == 4) {
        // b is the repeat length: that many extra copies of `last`.
        for (var k = 0; k < b; k++) {
          emit(last);
        }
        runCount = 0;
        last = -1;
      } else {
        if (b == last) {
          runCount++;
        } else {
          runCount = 1;
          last = b;
        }
        emit(b);
      }
    }
    if (sp > 0) {
      final chunk = Uint8List.fromList(Uint8List.sublistView(scratch, 0, sp));
      crc.add(chunk);
      out.add(chunk);
    }

    if (crc.value != blockCrc) {
      throw const FormatException('bzip2 block CRC mismatch');
    }
    // Rotate-combine into the stream CRC.
    _combinedCrc =
        (((_combinedCrc << 1) | (_combinedCrc >>> 31)) ^ blockCrc) & 0xFFFFFFFF;

    return out.takeBytes();
  }

  /// Reads one group's delta-coded code lengths (1–20).
  static List<int> _readLengths(_BitReader bits, int alphaSize) {
    final lengths = List<int>.filled(alphaSize, 0);
    var curr = bits.readBits(5);
    for (var s = 0; s < alphaSize; s++) {
      while (true) {
        if (curr < 1 || curr > 20) {
          throw const FormatException('bad bzip2 code length');
        }
        if (bits.readBit() == 0) break;
        curr += bits.readBit() == 0 ? 1 : -1;
      }
      lengths[s] = curr;
    }
    return lengths;
  }
}

/// A canonical Huffman decoder for one bzip2 group (limit/base/perm form).
final class _HuffmanTable {
  _HuffmanTable(List<int> lengths) {
    var minLen = 32;
    var maxLen = 0;
    for (final l in lengths) {
      if (l > maxLen) maxLen = l;
      if (l < minLen) minLen = l;
    }
    _minLen = minLen;
    _maxLen = maxLen;
    _perm = Uint32List(lengths.length);

    // Assign symbols to codes in (length, symbol) order.
    var pp = 0;
    for (var len = minLen; len <= maxLen; len++) {
      for (var s = 0; s < lengths.length; s++) {
        if (lengths[s] == len) _perm[pp++] = s;
      }
    }

    final count = List<int>.filled(maxLen + 2, 0);
    for (final l in lengths) {
      count[l + 1]++;
    }
    for (var i = 1; i < count.length; i++) {
      count[i] += count[i - 1];
    }

    // bzip2 code lengths are ≤ 20, so these vectors stay well under 32 bits;
    // plain lists keep them dart2js-safe (an `Int64List` would throw there).
    _base = List<int>.filled(maxLen + 2, 0);
    _limit = List<int>.filled(maxLen + 2, 0);
    var vec = 0;
    for (var len = minLen; len <= maxLen; len++) {
      vec += count[len + 1] - count[len];
      _limit[len] = vec - 1;
      vec <<= 1;
    }
    for (var len = minLen + 1; len <= maxLen; len++) {
      _base[len] = ((_limit[len - 1] + 1) << 1) - count[len];
    }
  }

  late final int _minLen;
  late final int _maxLen;
  late final Uint32List _perm;
  late final List<int> _base;
  late final List<int> _limit;

  int decode(_BitReader bits) {
    var len = _minLen;
    var code = bits.readBits(len);
    while (true) {
      if (len > _maxLen) {
        throw const FormatException('bad bzip2 Huffman code');
      }
      if (code <= _limit[len]) break;
      len++;
      code = (code << 1) | bits.readBit();
    }
    final idx = code - _base[len];
    if (idx < 0 || idx >= _perm.length) {
      throw const FormatException('bad bzip2 Huffman code');
    }
    return _perm[idx];
  }
}

/// One-shot bzip2 decoder as a [Converter], the `dart:convert` idiom.
final class Bzip2Decoder extends Converter<List<int>, List<int>> {
  /// Creates a decoder.
  const Bzip2Decoder();

  @override
  Uint8List convert(List<int> input) {
    final decoder =
        RawBzip2Decoder()
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
      _Bzip2Sink(sink);
}

class _Bzip2Sink implements ByteConversionSink {
  _Bzip2Sink(this._downstream);

  final Sink<List<int>> _downstream;
  final RawBzip2Decoder _decoder = RawBzip2Decoder();

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

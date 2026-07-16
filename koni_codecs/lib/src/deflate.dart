import 'dart:convert';
import 'dart:typed_data';

/// DEFLATE (RFC 1951) compression as a synchronous, chunk-driven converter,
/// the encoding counterpart of `InflateDecoder`.
///
/// Produces valid, universally decodable deflate: greedy LZ77 (hash-chain
/// match finding) with fixed-Huffman blocks. Input is processed in ≤ 32 KiB
/// blocks so match distances stay within the deflate window and memory
/// stays bounded (matches do not cross block boundaries, a valid,
/// conservative choice; dynamic-Huffman blocks, cross-block matching, and a
/// stored-block fallback for incompressible input are future ratio
/// improvements, not correctness ones; callers that store already-
/// compressed data, like CBZ images, sidestep the last one at the ZIP
/// layer).
///
/// One-shot: `const DeflateEncoder().convert(bytes)`. Streaming:
/// `startChunkedConversion(sink)` then `add`/`close`.
final class DeflateEncoder extends Converter<List<int>, List<int>> {
  /// Creates the encoder. Stateless; state lives in each conversion.
  const DeflateEncoder();

  @override
  Uint8List convert(List<int> input) {
    final out = BytesBuilder(copy: false);
    final deflater = RawDeflater(onOutput: out.add);
    deflater.add(input is Uint8List ? input : Uint8List.fromList(input));
    deflater.finish();
    return out.takeBytes();
  }

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      _DeflateSink(sink);
}

final class _DeflateSink implements ByteConversionSink {
  _DeflateSink(this._downstream)
    : _deflater = RawDeflater(onOutput: _downstream.add);

  final Sink<List<int>> _downstream;
  final RawDeflater _deflater;

  @override
  void add(List<int> chunk) =>
      _deflater.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(chunk.sublist(start, end));
    if (isLast) close();
  }

  @override
  void close() {
    _deflater.finish();
    _downstream.close();
  }
}

/// Resumable raw-DEFLATE compressor, the engine under [DeflateEncoder].
final class RawDeflater {
  /// Creates a deflater delivering compressed chunks to [onOutput].
  RawDeflater({required this.onOutput});

  /// Receives each compressed output chunk.
  final void Function(Uint8List chunk) onOutput;

  // A block holds ≤ 32 KiB so every match distance stays < 32768 (the
  // deflate window limit); matches are found only within the current block.
  static const int _blockSize = 0x8000;
  static const int _minMatch = 3;
  static const int _maxMatch = 258;
  static const int _maxChain = 128; // hash-chain search depth (ratio vs speed)

  final Uint8List _block = Uint8List(_blockSize);
  int _fill = 0;
  bool _finished = false;
  final _BitWriter _bits = _BitWriter();

  /// Appends [chunk] to the input.
  void add(Uint8List chunk) {
    if (_finished) throw StateError('add after finish');
    var offset = 0;
    while (offset < chunk.length) {
      final space = _blockSize - _fill;
      final take =
          chunk.length - offset < space ? chunk.length - offset : space;
      _block.setRange(_fill, _fill + take, chunk, offset);
      _fill += take;
      offset += take;
      if (_fill == _blockSize) _emitBlock(isFinal: false);
    }
  }

  /// Declares end of input and flushes the final block.
  void finish() {
    if (_finished) return;
    _finished = true;
    _emitBlock(isFinal: true);
    _bits.finish();
    _bits.drain(onOutput);
  }

  void _emitBlock({required bool isFinal}) {
    final length = _fill;
    _fill = 0;
    _bits.writeBits(isFinal ? 1 : 0, 1); // BFINAL
    _bits.writeBits(1, 2); // BTYPE = 01 (fixed Huffman)
    _encodeFixed(_block, length);
    _bits.writeHuffman(_fixedLitCode[256], _fixedLitLen[256]); // end-of-block
    _bits.drain(onOutput);
  }

  /// Emits fixed-Huffman LZ77 tokens for `data[0..length)` (no block header
  /// or end-of-block symbol).
  void _encodeFixed(Uint8List data, int length) {
    if (length == 0) return;
    final head = Int32List(_hashSize)..fillRange(0, _hashSize, -1);
    final prev = Int32List(length);
    var pos = 0;
    while (pos < length) {
      var matchLen = 0;
      var matchDist = 0;
      if (pos + _minMatch <= length) {
        final h = _hash(data, pos);
        var candidate = head[h];
        var chain = _maxChain;
        while (candidate >= 0 && chain-- > 0) {
          final len = _matchLength(data, candidate, pos, length);
          if (len > matchLen) {
            matchLen = len;
            matchDist = pos - candidate;
            if (len >= _maxMatch) break;
          }
          candidate = prev[candidate];
        }
        prev[pos] = head[h];
        head[h] = pos;
      }

      if (matchLen >= _minMatch) {
        _writeLength(matchLen);
        _writeDistance(matchDist);
        final end = pos + matchLen;
        for (var i = pos + 1; i < end && i + _minMatch <= length; i++) {
          final h = _hash(data, i);
          prev[i] = head[h];
          head[h] = i;
        }
        pos = end;
      } else {
        _bits.writeHuffman(_fixedLitCode[data[pos]], _fixedLitLen[data[pos]]);
        pos++;
      }
    }
  }

  void _writeLength(int length) {
    final sym = _lengthSymbol[length];
    _bits.writeHuffman(_fixedLitCode[sym], _fixedLitLen[sym]);
    final extra = _lengthExtra[sym - 257];
    if (extra > 0) _bits.writeBits(length - _lengthBase[sym - 257], extra);
  }

  void _writeDistance(int distance) {
    final sym = _distanceSymbol(distance);
    _bits.writeHuffman(_reverse(sym, 5), 5);
    final extra = _distExtra[sym];
    if (extra > 0) _bits.writeBits(distance - 1 - _distBase[sym], extra);
  }

  static const int _hashSize = 1 << 15;

  static int _hash(Uint8List data, int i) =>
      ((data[i] << 10) ^ (data[i + 1] << 5) ^ data[i + 2]) & (_hashSize - 1);

  static int _matchLength(Uint8List data, int from, int at, int length) {
    var len = 0;
    final max = length - at < _maxMatch ? length - at : _maxMatch;
    while (len < max && data[from + len] == data[at + len]) {
      len++;
    }
    return len;
  }

  static int _distanceSymbol(int distance) {
    final d = distance - 1;
    for (var s = 0; s < _distBase.length; s++) {
      if (d < _distBase[s] + (1 << _distExtra[s])) return s;
    }
    return _distBase.length - 1;
  }

  static int _reverse(int value, int bits) {
    var r = 0;
    for (var i = 0; i < bits; i++) {
      r = (r << 1) | ((value >> i) & 1);
    }
    return r;
  }

  // RFC 1951 §3.2.5 length/distance tables (shared with the decoder).
  static const List<int> _lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
  ];
  static const List<int> _lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ];
  static const List<int> _distBase = [
    0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, //
    256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, //
    12288, 16384, 24576,
  ];
  static const List<int> _distExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
  ];

  /// length (3-258) → literal/length symbol (257-285).
  static final Uint16List _lengthSymbol = _buildLengthSymbols();

  static Uint16List _buildLengthSymbols() {
    final table = Uint16List(_maxMatch + 1);
    var sym = 257;
    for (var length = _minMatch; length <= _maxMatch; length++) {
      while (sym - 257 < 27 && length >= _lengthBase[sym - 257 + 1]) {
        sym++;
      }
      table[length] = sym;
    }
    table[_maxMatch] = 285; // length 258 is its own symbol
    return table;
  }

  // Fixed literal/length codes (RFC 1951 §3.2.6), reversed for LSB-first
  // emission, with their bit lengths.
  static final (Uint16List, Uint8List) _fixedLit = _buildFixedLit();
  static Uint16List get _fixedLitCode => _fixedLit.$1;
  static Uint8List get _fixedLitLen => _fixedLit.$2;

  static (Uint16List, Uint8List) _buildFixedLit() {
    final codes = Uint16List(288);
    final lengths = Uint8List(288);
    for (var s = 0; s <= 143; s++) {
      codes[s] = _reverse(0x30 + s, 8);
      lengths[s] = 8;
    }
    for (var s = 144; s <= 255; s++) {
      codes[s] = _reverse(0x190 + (s - 144), 9);
      lengths[s] = 9;
    }
    for (var s = 256; s <= 279; s++) {
      codes[s] = _reverse(s - 256, 7);
      lengths[s] = 7;
    }
    for (var s = 280; s <= 287; s++) {
      codes[s] = _reverse(0xC0 + (s - 280), 8);
      lengths[s] = 8;
    }
    return (codes, lengths);
  }
}

/// LSB-first bit writer accumulating into a byte buffer.
final class _BitWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int _pendingByte = 0;
  int _bitCount = 0;

  /// Writes the low [count] bits of [value] (count ≤ 16), LSB-first. The
  /// accumulator stays < 2^24 (bitCount < 8 before each call, value < 2^16),
  /// which dart2js models exactly.
  void writeBits(int value, int count) {
    var buf = _pendingByte | ((value & ((1 << count) - 1)) << _bitCount);
    var bits = _bitCount + count;
    while (bits >= 8) {
      _bytes.addByte(buf & 0xFF);
      buf >>= 8;
      bits -= 8;
    }
    _pendingByte = buf;
    _bitCount = bits;
  }

  /// Writes a Huffman code already reversed into LSB-first order.
  void writeHuffman(int reversedCode, int length) =>
      writeBits(reversedCode, length);

  /// Pads the final partial byte with zero bits.
  void finish() {
    if (_bitCount > 0) {
      _bytes.addByte(_pendingByte & 0xFF);
      _pendingByte = 0;
      _bitCount = 0;
    }
  }

  /// Emits all complete buffered bytes to [onOutput], keeping any partial
  /// byte for the next block.
  void drain(void Function(Uint8List) onOutput) {
    if (_bytes.length > 0) onOutput(_bytes.takeBytes());
  }
}

/// RAR5 decompression (method 1–5): LZ with Huffman-coded literals, a
/// distance cache, and post-decode filters (delta, x86, ARM).
///
/// Clean-room implementation per `koni_rar/doc/rar-provenance.md`. The
/// block/bitstream layout and table encoding follow libarchive's
/// BSD-licensed `archive_read_support_format_rar5.c` (see `doc/references.md`
/// and `NOTICE`); no unrar or GPL source was consulted. Correctness is
/// verified against the `rar`/`unrar` tools' output.
///
/// Malformed input throws [FormatException]; the archive layer translates.
library;

import 'dart:typed_data';

/// The literal-alphabet size (256 bytes + end + rep/len codes).
const int _huffNC = 306;
const int _huffDC = 64;
const int _huffLDC = 16;
const int _huffRC = 44;
const int _huffBC = 20;
const int _huffTableSize = _huffNC + _huffDC + _huffRC + _huffLDC;

/// A canonical Huffman decode table with a quick-lookup cache, matching the
/// RAR5 table representation.
final class _DecodeTable {
  _DecodeTable(this.quickBits);

  final int quickBits;
  int size = 0;
  final Int32List decodeLen = Int32List(16);
  final Int32List decodePos = Int32List(16);
  late Int32List decodeNum;
  late Uint8List quickLen;
  late Int32List quickNum;

  /// Builds the table from per-symbol [bitLengths] (low nibble used).
  void build(Uint8List bitLengths, int count) {
    size = count;
    decodeNum = Int32List(count);
    final quickSize = 1 << quickBits;
    quickLen = Uint8List(quickSize);
    quickNum = Int32List(quickSize);

    final lc = List<int>.filled(16, 0);
    for (var i = 0; i < count; i++) {
      lc[bitLengths[i] & 15]++;
    }
    lc[0] = 0;
    decodePos[0] = 0;
    decodeLen[0] = 0;
    var upperLimit = 0;
    for (var i = 1; i < 16; i++) {
      upperLimit += lc[i];
      decodeLen[i] = upperLimit << (16 - i);
      decodePos[i] = decodePos[i - 1] + lc[i - 1];
      upperLimit <<= 1;
    }
    if (upperLimit > 65536) {
      throw const FormatException('over-subscribed RAR5 Huffman table');
    }

    final posClone = Int32List.fromList(decodePos);
    for (var i = 0; i < count; i++) {
      final clen = bitLengths[i] & 15;
      if (clen > 0) {
        decodeNum[posClone[clen]++] = i;
      }
    }

    var curLen = 1;
    for (var code = 0; code < quickSize; code++) {
      final bitField = code << (16 - quickBits);
      while (curLen < 16 && bitField >= decodeLen[curLen]) {
        curLen++;
      }
      quickLen[code] = curLen;
      final dist = (bitField - decodeLen[curLen - 1]) >> (16 - curLen);
      final pos = decodePos[curLen & 15] + dist;
      quickNum[code] = (curLen < 16 && pos < count) ? decodeNum[pos] : 0;
    }
  }

  /// Decodes one symbol from [bits].
  int decode(_RarBits bits) {
    final bitField = bits.peek(16) & 0xFFFE;
    if (bitField < decodeLen[quickBits]) {
      final code = bitField >> (16 - quickBits);
      bits.skip(quickLen[code]);
      return quickNum[code];
    }
    var length = 15;
    for (var i = quickBits + 1; i < 15; i++) {
      if (bitField < decodeLen[i]) {
        length = i;
        break;
      }
    }
    bits.skip(length);
    var dist = bitField - decodeLen[length - 1];
    dist >>= (16 - length);
    var pos = decodePos[length] + dist;
    if (pos >= size) pos = 0;
    return decodeNum[pos];
  }
}

/// MSB-first bit reader over a byte buffer (RAR5 bit order).
final class _RarBits {
  _RarBits(this._data) : _end = _data.length;

  final Uint8List _data;
  final int _end;

  /// Absolute bit position.
  int position = 0;

  /// Whether [count] more bits are available.
  bool has(int count) => position + count <= _end * 8;

  int _byteAt(int index) => index < _end ? _data[index] : 0;

  /// Peeks [n] bits (1–24) without consuming.
  int peek(int n) {
    final byteIndex = position >> 3;
    final bitOffset = position & 7;
    // 4 bytes cover bitOffset (≤7) + n (≤24) = ≤31 bits. Multiplication
    // keeps the accumulator exact and non-negative on dart2js.
    var acc = _byteAt(byteIndex);
    acc = acc * 256 + _byteAt(byteIndex + 1);
    acc = acc * 256 + _byteAt(byteIndex + 2);
    acc = acc * 256 + _byteAt(byteIndex + 3);
    // acc holds 32 bits; drop the low (32 - bitOffset - n) and mask n.
    final drop = 32 - bitOffset - n;
    return (acc ~/ _pow2[drop]) % _pow2[n];
  }

  /// Consumes [n] bits.
  void skip(int n) => position += n;

  /// Reads [n] bits (1–24), MSB-first.
  int read(int n) {
    final value = peek(n);
    position += n;
    return value;
  }

  /// Reads [n] bits where n may be up to 30 (distance high bits).
  int readWide(int n) {
    if (n <= 24) return read(n);
    final high = read(n - 16);
    final low = read(16);
    return high * 0x10000 + low;
  }
}

/// Powers of two up to 2^32, as exact numbers (dart2js-safe indexing).
final List<int> _pow2 = List<int>.generate(33, (i) => 1 << i > 0 ? 1 << i : 0)
  ..[32] = 4294967296;

/// A pending post-decode filter over a window region.
final class _Rar5Filter {
  _Rar5Filter(this.type, this.blockStart, this.blockLength, this.channels);

  final int type; // 0 delta, 1 e8, 2 e8e9, 3 arm
  final int blockStart; // absolute output position
  final int blockLength;
  final int channels;
}

/// Decodes RAR5 compressed data for one file (or a solid run) into a
/// caller-provided output buffer.
///
/// The buffer is the LZ window: for solid archives, successive files share
/// one decoder so back-references reach into earlier files. Not
/// multi-volume (Phase-1 non-goal).
final class Rar5Decoder {
  /// Creates a decoder writing decoded bytes into [output].
  Rar5Decoder(this.output);

  /// The output buffer / LZ window.
  final Uint8List output;

  /// Write cursor (also the count of decoded bytes).
  int writePtr = 0;

  final _DecodeTable _bd = _DecodeTable(7);
  final _DecodeTable _ld = _DecodeTable(10);
  final _DecodeTable _dd = _DecodeTable(7);
  final _DecodeTable _ldd = _DecodeTable(7);
  final _DecodeTable _rd = _DecodeTable(7);

  final List<int> _distCache = [0, 0, 0, 0];
  int _lastLen = 0;
  bool _tablesReady = false;

  final List<_Rar5Filter> _filters = [];

  /// Decodes all compressed [blocks] of one file up to [unpackedSize]
  /// bytes, appending to [output] from the current [writePtr]. [blocks] is
  /// the file's concatenated data (block headers included).
  void decompressFile(Uint8List blocks, int unpackedSize) {
    final target = writePtr + unpackedSize;
    if (target > output.length) {
      throw const FormatException('RAR5 file exceeds declared output size');
    }
    final bits = _RarBits(blocks);
    var blockStart = writePtr;

    while (writePtr < target) {
      // Block header layout: flags, checksum, then the 1–3-byte block size.
      final headerPos = bits.position;
      if (!bits.has(24)) {
        throw const FormatException('truncated RAR5 block header');
      }
      final flags = bits.read(8);
      final byteCount = (flags >> 3) & 7;
      final bitSize = (flags & 7) + 1;
      final tablePresent = (flags >> 7) & 1;
      final lastBlock = (flags >> 6) & 1;
      if (byteCount > 2) {
        throw const FormatException('unsupported RAR5 block-size width');
      }
      final checksum = bits.read(8);
      var blockSize = 0;
      for (var i = 0; i <= byteCount; i++) {
        blockSize |= bits.read(8) << (8 * i);
      }
      final expected =
          0x5A ^
          flags ^
          (blockSize & 0xFF) ^
          ((blockSize >> 8) & 0xFF) ^
          ((blockSize >> 16) & 0xFF);
      if (checksum != expected) {
        throw const FormatException('RAR5 block header checksum mismatch');
      }

      // The block's bitstream spans blockSize bytes of data plus bitSize
      // trailing bits, starting right after the header.
      final dataStartByte = bits.position >> 3;
      final blockEndBits = dataStartByte * 8 + (blockSize - 1) * 8 + bitSize;

      if (tablePresent != 0) {
        _parseTables(bits);
        _tablesReady = true;
      }
      if (!_tablesReady) {
        throw const FormatException('RAR5 block without Huffman tables');
      }

      _decodeBlock(bits, blockEndBits, target, blockStart);

      if (writePtr >= target) break;
      if (lastBlock != 0) {
        // Last block but output short: only valid if we've hit target.
        if (writePtr < target) {
          throw const FormatException(
            'RAR5 stream ended before the declared output size',
          );
        }
      }
      // Next block starts at the byte after this block's data.
      bits.position = (dataStartByte + blockSize) * 8;
      if (bits.position <= headerPos) {
        throw const FormatException('RAR5 block made no progress');
      }
      blockStart = writePtr;
    }

    _applyFilters();
  }

  void _decodeBlock(_RarBits bits, int endBits, int target, int blockStart) {
    final mask = output.length - 1; // window size is a power of two
    while (bits.position < endBits && writePtr < target) {
      final sym = _ld.decode(bits);
      if (sym < 256) {
        output[writePtr++ & mask] = sym;
        continue;
      }
      if (sym == 256) {
        _parseFilter(bits);
        continue;
      }
      if (sym == 257) {
        if (_lastLen != 0) {
          _copy(_lastLen, _distCache[0], mask, target);
        }
        continue;
      }
      if (sym < 262) {
        final idx = sym - 258;
        final dist = _distCacheTouch(idx);
        final lenSlot = _rd.decode(bits);
        final len = _decodeLength(bits, lenSlot);
        _lastLen = len;
        _copy(len, dist, mask, target);
        continue;
      }
      // sym >= 262: new match.
      final len = _decodeLength(bits, sym - 262);
      final distSlot = _dd.decode(bits);
      var dist = 1;
      int dbits;
      if (distSlot < 4) {
        dbits = 0;
        dist += distSlot;
      } else {
        dbits = distSlot ~/ 2 - 1;
        dist += (2 | (distSlot & 1)) << dbits;
      }
      if (dbits > 0) {
        if (dbits >= 4) {
          if (dbits > 4) {
            final add = bits.readWide(dbits - 4) << 4;
            dist += add;
          }
          final lowDist = _ldd.decode(bits);
          dist += lowDist;
        } else {
          dist += bits.read(dbits);
        }
      }
      var effectiveLen = len;
      if (dist > 0x100) {
        effectiveLen++;
        if (dist > 0x2000) {
          effectiveLen++;
          if (dist > 0x40000) effectiveLen++;
        }
      }
      _distCachePush(dist);
      _lastLen = effectiveLen;
      _copy(effectiveLen, dist, mask, target);
    }
  }

  void _copy(int len, int dist, int mask, int target) {
    if (dist <= 0) {
      throw const FormatException('RAR5 zero/negative match distance');
    }
    if (writePtr + len > target) {
      throw const FormatException('RAR5 match exceeds declared output size');
    }
    if (dist > writePtr) {
      throw const FormatException('RAR5 match distance before output start');
    }
    for (var i = 0; i < len; i++) {
      output[(writePtr) & mask] = output[(writePtr - dist) & mask];
      writePtr++;
    }
  }

  int _decodeLength(_RarBits bits, int lenSlot) {
    var length = 2;
    if (lenSlot < 8) {
      length += lenSlot;
    } else {
      final lbits = lenSlot ~/ 4 - 1;
      length += (4 | (lenSlot & 3)) << lbits;
      length += bits.read(lbits);
    }
    return length;
  }

  void _distCachePush(int dist) {
    _distCache
      ..removeLast()
      ..insert(0, dist);
  }

  int _distCacheTouch(int idx) {
    final dist = _distCache[idx];
    for (var i = idx; i > 0; i--) {
      _distCache[i] = _distCache[i - 1];
    }
    _distCache[0] = dist;
    return dist;
  }

  void _parseFilter(_RarBits bits) {
    final blockStart = _filterData(bits);
    final blockLength = _filterData(bits);
    final type = bits.read(3);
    if (blockLength < 4 || blockLength > 0x400000) {
      throw const FormatException('invalid RAR5 filter block length');
    }
    var channels = 0;
    if (type == 0) {
      channels = bits.read(5) + 1;
    }
    _filters.add(
      _Rar5Filter(type, writePtr + blockStart, blockLength, channels),
    );
  }

  int _filterData(_RarBits bits) {
    final bytes = bits.read(2) + 1;
    var data = 0;
    for (var i = 0; i < bytes; i++) {
      data += bits.read(8) << (i * 8);
    }
    return data;
  }

  void _parseTables(_RarBits bits) {
    final bitLength = Uint8List(_huffBC);
    for (var i = 0; i < _huffBC;) {
      final len = bits.read(4);
      if (len == 15) {
        final count = bits.read(4);
        if (count == 0) {
          bitLength[i++] = 15;
        } else {
          for (var k = 0; k < count + 2 && i < _huffBC; k++) {
            bitLength[i++] = 0;
          }
        }
      } else {
        bitLength[i++] = len;
      }
    }
    _bd.build(bitLength, _huffBC);

    final table = Uint8List(_huffTableSize);
    for (var i = 0; i < _huffTableSize;) {
      final num = _bd.decode(bits);
      if (num < 16) {
        table[i++] = num;
      } else if (num < 18) {
        var n = num == 16 ? bits.read(3) + 3 : bits.read(7) + 11;
        if (i == 0) {
          throw const FormatException('RAR5 table repeat with no previous');
        }
        while (n-- > 0 && i < _huffTableSize) {
          table[i] = table[i - 1];
          i++;
        }
      } else {
        var n = num == 18 ? bits.read(3) + 3 : bits.read(7) + 11;
        while (n-- > 0 && i < _huffTableSize) {
          table[i++] = 0;
        }
      }
    }

    // Table order (libarchive rar5.c): NC, DC, LDC, RC.
    var idx = 0;
    _ld.build(Uint8List.sublistView(table, idx, idx + _huffNC), _huffNC);
    idx += _huffNC;
    _dd.build(Uint8List.sublistView(table, idx, idx + _huffDC), _huffDC);
    idx += _huffDC;
    _ldd.build(Uint8List.sublistView(table, idx, idx + _huffLDC), _huffLDC);
    idx += _huffLDC;
    _rd.build(Uint8List.sublistView(table, idx, idx + _huffRC), _huffRC);
  }

  /// Applies pending filters in order, in place over [output]. Filters
  /// operate within a single file's output; solid runs reset via
  /// [beginFileFilters].
  void _applyFilters() {
    for (final filter in _filters) {
      _runFilter(filter);
    }
    _filters.clear();
  }

  /// Marks a fresh filter scope for the next file in a solid run.
  void beginFileFilters() => _filters.clear();

  void _runFilter(_Rar5Filter filter) {
    final start = filter.blockStart;
    final length = filter.blockLength;
    if (start < 0 || start + length > output.length) {
      throw const FormatException('RAR5 filter region out of range');
    }
    final region = Uint8List.sublistView(output, start, start + length);
    switch (filter.type) {
      case 0:
        _delta(region, filter.channels);
      case 1:
        _e8e9(region, start, false);
      case 2:
        _e8e9(region, start, true);
      case 3:
        _arm(region, start);
      default:
        throw FormatException('unsupported RAR5 filter type ${filter.type}');
    }
  }

  static void _delta(Uint8List data, int channels) {
    final out = Uint8List(data.length);
    var srcPos = 0;
    for (var ch = 0; ch < channels; ch++) {
      var prev = 0;
      for (var destPos = ch; destPos < data.length; destPos += channels) {
        prev = (prev - data[srcPos++]) & 0xFF;
        out[destPos] = prev;
      }
    }
    data.setAll(0, out);
  }

  static void _e8e9(Uint8List data, int fileOffset, bool e9) {
    const fileSize = 0x1000000;
    for (var i = 0; i + 4 < data.length;) {
      final b = data[i++];
      if (b == 0xE8 || (e9 && b == 0xE9)) {
        final offset = (i + fileOffset) % fileSize;
        var addr =
            data[i] |
            (data[i + 1] << 8) |
            (data[i + 2] << 16) |
            (data[i + 3] << 24);
        addr &= 0xFFFFFFFF;
        if (addr & 0x80000000 != 0) {
          if (((addr + offset) & 0x80000000) == 0) {
            _writeLe32(data, i, addr + fileSize);
          }
        } else {
          if ((addr - fileSize) & 0x80000000 != 0) {
            _writeLe32(data, i, (addr - offset) & 0xFFFFFFFF);
          }
        }
        i += 4;
      }
    }
  }

  static void _arm(Uint8List data, int fileOffset) {
    for (var i = 0; i + 4 <= data.length; i += 4) {
      if (data[i + 3] == 0xEB) {
        var offset = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16);
        offset = (offset - ((i + fileOffset) ~/ 4)) & 0xFFFFFF;
        data[i] = offset & 0xFF;
        data[i + 1] = (offset >> 8) & 0xFF;
        data[i + 2] = (offset >> 16) & 0xFF;
      }
    }
  }

  static void _writeLe32(Uint8List data, int at, int value) {
    data[at] = value & 0xFF;
    data[at + 1] = (value >> 8) & 0xFF;
    data[at + 2] = (value >> 16) & 0xFF;
    data[at + 3] = (value >> 24) & 0xFF;
  }
}

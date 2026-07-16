/// RAR4 (v1.5 container) method-29 decompression: LZSS with canonical
/// Huffman codes and a repeated-offset cache.
///
/// Clean-room per `doc/rar-provenance.md`; layout and the length/offset
/// base tables follow libarchive's BSD `archive_read_support_format_rar.c`
/// (Tim Kientzle, Andres Mejia — see `doc/references.md` and `NOTICE`); no
/// unrar or GPL source was consulted. The RarVM standard filters (delta,
/// x86, RGB, audio) are handled by [Rar4Filters]; PPMd (variant H) and
/// custom VM programs are **not** implemented — a stream that uses them
/// throws a [FormatException] the reader maps to a typed error.
///
/// Malformed input throws [FormatException].
library;

import 'dart:typed_data';

import 'rar4_filters.dart';

const int _mainCodeSize = 299;
const int _offsetCodeSize = 60;
const int _lowOffsetCodeSize = 17;
const int _lengthCodeSize = 28;
const int _tableSize =
    _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize + _lengthCodeSize;
const int _precodeSymbols = 20;

/// MSB-first bit reader over a byte buffer (RAR bit order).
final class _Bits {
  _Bits(this._data);

  final Uint8List _data;
  int _pos = 0; // absolute bit position

  bool has(int n) => _pos + n <= _data.length * 8;

  int _byteAt(int i) => i < _data.length ? _data[i] : 0;

  /// Peeks [n] bits (1–16) MSB-first.
  int peek(int n) {
    final byteIndex = _pos >> 3;
    final bitOffset = _pos & 7;
    var acc = _byteAt(byteIndex);
    acc = acc * 256 + _byteAt(byteIndex + 1);
    acc = acc * 256 + _byteAt(byteIndex + 2);
    // 3 bytes cover bitOffset (≤7) + n (≤16) = ≤23 bits.
    final drop = 24 - bitOffset - n;
    return (acc ~/ _pow2[drop]) % _pow2[n];
  }

  int read(int n) {
    final v = peek(n);
    _pos += n;
    return v;
  }

  void consume(int n) => _pos += n;

  /// Discards bits up to the next byte boundary.
  void alignToByte() => _pos = (_pos + 7) & ~7;
}

final List<int> _pow2 = List<int>.generate(25, (i) => 1 << i);

/// Canonical Huffman decoder (RAR's `create_code` order): codes assigned in
/// increasing length, then symbol order, MSB-first. Decodes via a flat
/// lookup table indexed by the next `maxLength` bits.
final class _Huffman {
  _Huffman(Uint8List lengths, int count) {
    var maxLen = 0;
    for (var i = 0; i < count; i++) {
      final l = lengths[i] & 0xF;
      if (l > maxLen) maxLen = l;
    }
    if (maxLen == 0) {
      // Empty code: decode always fails (a valid stream won't use it).
      _maxLength = 1;
      _table = Int32List(2)..fillRange(0, 2, -1);
      return;
    }
    _maxLength = maxLen;
    _table = Int32List(1 << maxLen)..fillRange(0, 1 << maxLen, -1);

    var code = 0;
    for (var len = 1; len <= maxLen; len++) {
      for (var sym = 0; sym < count; sym++) {
        if ((lengths[sym] & 0xF) != len) continue;
        // Fill every table slot whose top `len` bits equal this code. A
        // code beyond 2^len means the lengths over-subscribe the tree —
        // impossible for a valid table, reachable via mutated input (§7).
        if (code >= (1 << len)) {
          throw const FormatException('over-subscribed RAR4 Huffman table');
        }
        final shift = maxLen - len;
        final base = code << shift;
        final entry = (len << 16) | sym;
        for (var i = 0; i < (1 << shift); i++) {
          _table[base + i] = entry;
        }
        code++;
      }
      code <<= 1;
    }
  }

  late final int _maxLength;
  late final Int32List _table;

  int decode(_Bits bits) {
    final entry = _table[bits.peek(_maxLength)];
    if (entry < 0) {
      throw const FormatException('invalid RAR4 Huffman code');
    }
    bits.consume(entry >> 16);
    return entry & 0xFFFF;
  }
}

/// RAR4 method-29 decoder. Reuses [output] as a power-of-two LZ window
/// (index with `& mask`); the reader slices the decoded region out.
final class Rar4Decoder {
  /// Creates a decoder writing decoded bytes into [output] (a power of two).
  Rar4Decoder(this.output);

  /// Output buffer / LZ window.
  final Uint8List output;

  /// Write cursor (also the total decoded byte count).
  int writePtr = 0;

  /// Whether a *complete* Huffman table set has been parsed. In a solid run
  /// only the first compressed file carries a table block; later files reuse
  /// it, so they are decoded with `parseTable: false` on the same decoder
  /// instance. All four codes are checked so a `_parseCodes` that threw
  /// part-way (mutated table) is not mistaken for a usable table set.
  bool get hasTables =>
      _mainCode != null &&
      _offsetCode != null &&
      _lowOffsetCode != null &&
      _lengthCode != null;

  _Huffman? _mainCode;
  _Huffman? _offsetCode;
  _Huffman? _lowOffsetCode;
  _Huffman? _lengthCode;
  final Uint8List _lengthTable = Uint8List(_tableSize);

  final List<int> _oldOffset = [0, 0, 0, 0];
  int _lastOffset = 0;
  int _lastLength = 0;
  int _lastLowOffset = 0;
  int _lowOffsetRepeats = 0;

  final Rar4Filters _filters = Rar4Filters();

  static const List<int> _lengthBases = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, //
    24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224,
  ];
  static const List<int> _lengthBits = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, //
    2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
  ];
  static const List<int> _offsetBases = [
    0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, //
    64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, //
    4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304, //
    131072, 196608, 262144, 327680, 393216, 458752, 524288, 589824, //
    655360, 720896, 786432, 851968, 917504, 983040, 1048576, 1310720, //
    1572864, 1835008, 2097152, 2359296, 2621440, 2883584, 3145728, //
    3407872, 3670016, 3932160,
  ];
  static const List<int> _offsetBits = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, //
    10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 16, 16, 16, //
    16, 16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, //
    18, 18, 18, 18,
  ];
  static const List<int> _shortBases = [0, 4, 8, 16, 32, 64, 128, 192];
  static const List<int> _shortBits = [2, 2, 3, 4, 5, 6, 6, 6];

  /// Decodes the file's [packed] data to [unpackedSize] bytes appended from
  /// the current [writePtr].
  ///
  /// A non-solid file (or a solid run's first file) begins with its own
  /// Huffman table block ([parseTable] true). A solid *continuation* file
  /// carries no table block — it reuses the tables, repeated-offset cache,
  /// and window left by the previous file in the run, so pass [parseTable]
  /// false and reuse the same decoder instance.
  void decompressFile(
    Uint8List packed,
    int unpackedSize, {
    bool parseTable = true,
  }) {
    final fileBase = writePtr;
    final target = writePtr + unpackedSize;
    if (target > output.length) {
      throw const FormatException('RAR4 file exceeds declared output size');
    }
    _filters.reset();
    final bits = _Bits(packed);
    if (parseTable) {
      _parseCodes(bits); // run start / non-solid: read the table block
    } else if (!hasTables) {
      throw const FormatException(
        'RAR4 solid continuation without a preceding table',
      );
    }
    final mask = output.length - 1;

    while (writePtr < target) {
      if (!bits.has(1)) {
        throw const FormatException('truncated RAR4 stream');
      }
      final symbol = _mainCode!.decode(bits);
      if (symbol < 256) {
        output[writePtr++ & mask] = symbol;
        continue;
      }
      if (symbol == 256) {
        final newFile = bits.read(1) == 0;
        if (newFile) {
          final startNewTable = bits.read(1) != 0;
          if (startNewTable) _parseCodes(bits);
        } else {
          _parseCodes(bits);
        }
        continue;
      }
      if (symbol == 257) {
        // A RarVM filter definition inline in the stream (`read_filter`): a
        // flags byte, a length, then that many filter-code bytes. Parsing
        // schedules the filter; it is applied over the output after decode.
        final flags = bits.read(8);
        var codeLength = (flags & 0x07) + 1;
        if (codeLength == 7) {
          codeLength = bits.read(8) + 7;
        } else if (codeLength == 8) {
          final hi = bits.read(8);
          codeLength = (hi << 8) | bits.read(8);
        }
        final code = Uint8List(codeLength);
        for (var i = 0; i < codeLength; i++) {
          code[i] = bits.read(8);
        }
        _filters.parse(code, flags, writePtr);
        continue;
      }

      int offs;
      int len;
      if (symbol == 258) {
        if (_lastLength == 0) continue;
        offs = _lastOffset;
        len = _lastLength;
      } else if (symbol <= 262) {
        final offsIndex = symbol - 259;
        offs = _oldOffset[offsIndex];
        final lenSymbol = _lengthCode!.decode(bits);
        if (lenSymbol >= _lengthBases.length) {
          throw const FormatException('invalid RAR4 length symbol');
        }
        len = _lengthBases[lenSymbol] + 2;
        if (_lengthBits[lenSymbol] > 0) {
          len += bits.read(_lengthBits[lenSymbol]);
        }
        for (var i = offsIndex; i > 0; i--) {
          _oldOffset[i] = _oldOffset[i - 1];
        }
        _oldOffset[0] = offs;
      } else if (symbol <= 270) {
        offs = _shortBases[symbol - 263] + 1;
        if (_shortBits[symbol - 263] > 0) {
          offs += bits.read(_shortBits[symbol - 263]);
        }
        len = 2;
        for (var i = 3; i > 0; i--) {
          _oldOffset[i] = _oldOffset[i - 1];
        }
        _oldOffset[0] = offs;
      } else {
        final s = symbol - 271;
        if (s >= _lengthBases.length) {
          throw const FormatException('invalid RAR4 match symbol');
        }
        len = _lengthBases[s] + 3;
        if (_lengthBits[s] > 0) {
          len += bits.read(_lengthBits[s]);
        }
        final offsSymbol = _offsetCode!.decode(bits);
        if (offsSymbol >= _offsetBases.length) {
          throw const FormatException('invalid RAR4 offset symbol');
        }
        offs = _offsetBases[offsSymbol] + 1;
        final ob = _offsetBits[offsSymbol];
        if (ob > 0) {
          if (offsSymbol > 9) {
            if (ob > 4) {
              offs += bits.read(ob - 4) << 4;
            }
            if (_lowOffsetRepeats > 0) {
              _lowOffsetRepeats--;
              offs += _lastLowOffset;
            } else {
              final low = _lowOffsetCode!.decode(bits);
              if (low == 16) {
                _lowOffsetRepeats = 15;
                offs += _lastLowOffset;
              } else {
                offs += low;
                _lastLowOffset = low;
              }
            }
          } else {
            offs += bits.read(ob);
          }
        }
        if (offs >= 0x40000) len++;
        if (offs >= 0x2000) len++;
        for (var i = 3; i > 0; i--) {
          _oldOffset[i] = _oldOffset[i - 1];
        }
        _oldOffset[0] = offs;
      }

      _lastOffset = offs;
      _lastLength = len;
      _copy(len, offs, mask, target);
    }

    // Apply any RarVM filters over the freshly decoded region. The window
    // holds raw LZ output (matches copy raw→raw during decode), so filtering
    // is a correct post-pass over the file's disjoint, forward regions.
    if (_filters.isNotEmpty) {
      _filters.apply(output, fileBase, target);
    }
  }

  void _copy(int len, int dist, int mask, int target) {
    if (dist <= 0 || dist > writePtr) {
      throw const FormatException('RAR4 match distance out of range');
    }
    if (writePtr + len > target) {
      throw const FormatException('RAR4 match exceeds declared output size');
    }
    for (var i = 0; i < len; i++) {
      output[writePtr & mask] = output[(writePtr - dist) & mask];
      writePtr++;
    }
  }

  void _parseCodes(_Bits bits) {
    bits.alignToByte();
    final isPpmd = bits.read(1) != 0;
    if (isPpmd) {
      throw const FormatException('RAR4 PPMd blocks are not supported');
    }
    // "Keep table" bit: 0 resets the length table to zero.
    if (bits.read(1) == 0) {
      _lengthTable.fillRange(0, _tableSize, 0);
    }

    // 20 precode bit-lengths (4 bits each; 0xF escapes a zero run).
    final precodeLengths = Uint8List(_precodeSymbols);
    for (var i = 0; i < _precodeSymbols;) {
      final len = bits.read(4);
      precodeLengths[i++] = len;
      if (len == 0xF) {
        final zeros = bits.read(4);
        if (zeros != 0) {
          i--;
          for (var j = 0; j < zeros + 2 && i < _precodeSymbols; j++) {
            precodeLengths[i++] = 0;
          }
        }
      }
    }
    final precode = _Huffman(precodeLengths, _precodeSymbols);

    // The main length table: precode symbols delta-encode it (mod 16),
    // with 16/17 = repeat-previous runs and 18/19 = zero runs.
    for (var i = 0; i < _tableSize;) {
      final val = precode.decode(bits);
      if (val < 16) {
        _lengthTable[i] = (_lengthTable[i] + val) & 0xF;
        i++;
      } else if (val < 18) {
        final n = val == 16 ? bits.read(3) + 3 : bits.read(7) + 11;
        if (i == 0) {
          throw const FormatException('RAR4 table repeat with no previous');
        }
        for (var j = 0; j < n && i < _tableSize; j++) {
          _lengthTable[i] = _lengthTable[i - 1];
          i++;
        }
      } else {
        final n = val == 18 ? bits.read(3) + 3 : bits.read(7) + 11;
        for (var j = 0; j < n && i < _tableSize; j++) {
          _lengthTable[i++] = 0;
        }
      }
    }

    _mainCode = _Huffman(
      Uint8List.sublistView(_lengthTable, 0, _mainCodeSize),
      _mainCodeSize,
    );
    _offsetCode = _Huffman(
      Uint8List.sublistView(
        _lengthTable,
        _mainCodeSize,
        _mainCodeSize + _offsetCodeSize,
      ),
      _offsetCodeSize,
    );
    _lowOffsetCode = _Huffman(
      Uint8List.sublistView(
        _lengthTable,
        _mainCodeSize + _offsetCodeSize,
        _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize,
      ),
      _lowOffsetCodeSize,
    );
    _lengthCode = _Huffman(
      Uint8List.sublistView(
        _lengthTable,
        _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize,
      ),
      _lengthCodeSize,
    );

    _lastLowOffset = 0;
    _lowOffsetRepeats = 0;
  }
}

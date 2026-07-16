/// RAR 2.0 / 2.6 decompression (unpack versions 20 and 26): LZSS with canonical
/// Huffman codes, selected per block. Distinct from method-29 (v29): different
/// Huffman table sizes and block header.
///
/// Clean-room per `doc/rar-provenance.md`. Structure and symbol dispatch are
/// adapted from the BSD Go `rardecode` reader (`decode20.go`, `decode20_lz.go`;
/// Nicholas Waples, BSD-2-Clause; notice in `NOTICE`, attribution in
/// `doc/references.md`). No unrar or GPL source was consulted. The LZ
/// length/offset base tables are the standard RAR tables (shared with v29). All
/// arithmetic stays within 32 bits so dart2js matches the VM.
///
/// The RAR 2.x **multimedia/audio** block mode is a typed error: `rardecode`'s
/// audio decoder mis-decodes it (verified byte-for-byte against `unrar`), so no
/// permissive clean-room reference covers it; only the GPL unrar does. LZ
/// blocks (what every non-multimedia RAR 2.x archive uses) decode.
///
/// Malformed input throws [FormatException].
library;

import 'dart:typed_data';

import 'rar_bits.dart';

const int _mainSize = 298;
const int _offsetSize = 48;
const int _lengthSize = 28;
const int _tableSize = _mainSize + _offsetSize + _lengthSize;

/// RAR 2.0/2.6 decoder writing into [output] (a power-of-two LZ window); the
/// reader slices the decoded region out.
final class Rar20Decoder {
  /// Creates a decoder writing decoded bytes into [output] (a power of two).
  Rar20Decoder(this.output);

  /// Output buffer / LZ window.
  final Uint8List output;

  /// Write cursor (also the total decoded byte count).
  int writePtr = 0;

  final Uint8List _codeLength = Uint8List(_tableSize);
  bool _hdrRead = false;

  int _lastLength = 0;
  final List<int> _oldOffset = [0, 0, 0, 0];
  Huffman? _mainDecoder;
  Huffman? _offsetDecoder;
  Huffman? _lengthDecoder;

  // Standard RAR length/offset base tables (shared with v29); v20 uses the
  // first 48 offset slots.
  static const List<int> _lengthBase = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, //
    24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224,
  ];
  static const List<int> _lengthBits = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, //
    2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
  ];
  static const List<int> _offsetBase = [
    0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, //
    64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, //
    4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304, //
    131072, 196608, 262144, 327680, 393216, 458752, 524288, 589824, //
    655360, 720896, 786432, 851968, 917504, 983040,
  ];
  static const List<int> _offsetBits = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, //
    10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 16, 16, 16, //
    16, 16, 16, 16, 16, 16, 16, 16, 16,
  ];
  static const List<int> _shortOffsetBase = [0, 4, 8, 16, 32, 64, 128, 192];
  static const List<int> _shortOffsetBits = [2, 2, 3, 4, 5, 6, 6, 6];

  /// Decodes the file's [packed] data to [unpackedSize] bytes appended from the
  /// current [writePtr]. RAR 2.x v20 files are independently framed; each call
  /// resets the per-file block state.
  void decompressFile(Uint8List packed, int unpackedSize) {
    final target = writePtr + unpackedSize;
    if (target > output.length) {
      throw const FormatException('RAR2 file exceeds declared output size');
    }
    final bits = Bits(packed);
    final mask = output.length - 1;

    _hdrRead = false;
    _lastLength = 0;
    _oldOffset
      ..[0] = 0
      ..[1] = 0
      ..[2] = 0
      ..[3] = 0;
    _codeLength.fillRange(0, _tableSize, 0);

    while (writePtr < target) {
      if (!_hdrRead) _readBlockHeader(bits);
      if (_lzFill(bits, mask, target)) _hdrRead = false; // end of block
    }
  }

  void _readBlockHeader(Bits bits) {
    final isAudio = bits.read(1) != 0;
    if (isAudio) {
      // The multimedia/audio predictor has no correct permissive reference, so
      // the reader maps this to a typed UnsupportedFeatureException.
      throw const FormatException(
        'RAR2 multimedia/audio blocks are not supported',
      );
    }
    // "Keep table" bit: 0 resets the code-length table to zero.
    if (bits.read(1) == 0) {
      _codeLength.fillRange(0, _tableSize, 0);
    }
    _readCodeLengthTable20(bits);
    _mainDecoder = Huffman(
      Uint8List.sublistView(_codeLength, 0, _mainSize),
      _mainSize,
    );
    _offsetDecoder = Huffman(
      Uint8List.sublistView(_codeLength, _mainSize, _mainSize + _offsetSize),
      _offsetSize,
    );
    _lengthDecoder = Huffman(
      Uint8List.sublistView(_codeLength, _mainSize + _offsetSize, _tableSize),
      _lengthSize,
    );
    _hdrRead = true;
  }

  // The v20 code-length table: 19 4-bit pre-code lengths build a Huffman that
  // delta-decodes the table (mod 16), with 16 = repeat-previous and 17/18 =
  // zero runs. (Unlike v29 there is no 0xF escape in the pre-code and the run
  // codes are 16/17/18, not 16/17/18/19.)
  void _readCodeLengthTable20(Bits bits) {
    final bitlength = Uint8List(19);
    for (var i = 0; i < 19; i++) {
      bitlength[i] = bits.read(4);
    }
    final bl = Huffman(bitlength, 19);
    for (var i = 0; i < _tableSize;) {
      final l = bl.decode(bits);
      if (l < 16) {
        _codeLength[i] = (_codeLength[i] + l) & 0xF;
        i++;
      } else if (l == 16) {
        if (i == 0) {
          throw const FormatException('RAR2 table repeat with no previous');
        }
        final n = _min(i + bits.read(2) + 3, _tableSize);
        final v = _codeLength[i - 1];
        while (i < n) {
          _codeLength[i++] = v;
        }
      } else {
        final n =
            l == 17
                ? _min(i + bits.read(3) + 3, _tableSize)
                : _min(i + bits.read(7) + 11, _tableSize);
        while (i < n) {
          _codeLength[i++] = 0;
        }
      }
    }
  }

  /// Decodes LZ symbols into the window until an end-of-block marker (returns
  /// true) or [target] is reached (returns false).
  bool _lzFill(Bits bits, int mask, int target) {
    final main = _mainDecoder!;
    while (writePtr < target) {
      final sym = main.decode(bits);
      if (sym < 256) {
        output[writePtr++ & mask] = sym;
        continue;
      }
      if (sym > 269) {
        _decodeOffset(bits, sym - 270);
      } else if (sym == 269) {
        return true; // end of block
      } else if (sym == 256) {
        // Reuse the previous offset and length.
        _oldOffset
          ..[3] = _oldOffset[2]
          ..[2] = _oldOffset[1]
          ..[1] = _oldOffset[0];
      } else if (sym < 261) {
        _decodeLength(bits, sym - 257);
      } else {
        _decodeShortOffset(bits, sym - 261);
      }
      _copy(_lastLength, _oldOffset[0], mask, target);
    }
    return false;
  }

  void _decodeOffset(Bits bits, int i) {
    _lastLength = _lengthBase[i] + 3;
    if (_lengthBits[i] > 0) _lastLength += bits.read(_lengthBits[i]);

    final oi = _offsetDecoder!.decode(bits);
    if (oi >= _offsetBase.length) {
      throw const FormatException('invalid RAR2 offset symbol');
    }
    var offset = _offsetBase[oi] + 1;
    if (_offsetBits[oi] > 0) offset += bits.read(_offsetBits[oi]);
    if (offset >= 0x2000) {
      _lastLength++;
      if (offset >= 0x40000) _lastLength++;
    }
    _oldOffset
      ..[3] = _oldOffset[2]
      ..[2] = _oldOffset[1]
      ..[1] = _oldOffset[0]
      ..[0] = offset;
  }

  void _decodeLength(Bits bits, int i) {
    final offset = _oldOffset[i];
    _oldOffset
      ..[3] = _oldOffset[2]
      ..[2] = _oldOffset[1]
      ..[1] = _oldOffset[0]
      ..[0] = offset;

    final li = _lengthDecoder!.decode(bits);
    if (li >= _lengthBase.length) {
      throw const FormatException('invalid RAR2 length symbol');
    }
    _lastLength = _lengthBase[li] + 2;
    if (_lengthBits[li] > 0) _lastLength += bits.read(_lengthBits[li]);
    if (offset >= 0x101) {
      _lastLength++;
      if (offset >= 0x2000) {
        _lastLength++;
        if (offset >= 0x40000) _lastLength++;
      }
    }
  }

  void _decodeShortOffset(Bits bits, int i) {
    var offset = _shortOffsetBase[i] + 1;
    if (_shortOffsetBits[i] > 0) offset += bits.read(_shortOffsetBits[i]);
    _oldOffset
      ..[3] = _oldOffset[2]
      ..[2] = _oldOffset[1]
      ..[1] = _oldOffset[0]
      ..[0] = offset;
    _lastLength = 2;
  }

  void _copy(int len, int dist, int mask, int target) {
    if (dist <= 0 || dist > writePtr) {
      throw const FormatException('RAR2 match distance out of range');
    }
    if (writePtr + len > target) {
      throw const FormatException('RAR2 match exceeds declared output size');
    }
    for (var i = 0; i < len; i++) {
      output[writePtr & mask] = output[(writePtr - dist) & mask];
      writePtr++;
    }
  }

  static int _min(int a, int b) => a < b ? a : b;
}

/// RAR4 (v1.5 container) method-29 decompression: LZSS with canonical
/// Huffman codes and a repeated-offset cache.
///
/// Clean-room per `doc/rar-provenance.md`; layout and the length/offset
/// base tables follow libarchive's BSD `archive_read_support_format_rar.c`
/// (Tim Kientzle, Andres Mejia — see `doc/references.md` and `NOTICE`); no
/// unrar or GPL source was consulted. RarVM filters are handled by
/// [Rar4Filters] (the standard delta/x86/RGB/audio programs natively, any other
/// program on the generic interpreter in `rar4_vm.dart`); **PPMd (variant H)**
/// blocks are decoded by [Ppmd7Model] (see `rar4_ppmd.dart`), including a
/// mid-file PPMd→method-29 (LZSS) block switch — the block boundary is read the
/// same way for either method (`_parseCodes`). A filter reached *through* a PPMd
/// escape, and a mid-file switch inside a *solid* PPMd run, stay a
/// [FormatException] the reader maps to a typed error.
///
/// Malformed input throws [FormatException].
library;

import 'dart:typed_data';

import 'rar4_filters.dart';
import 'rar4_ppmd.dart';
import 'rar_bits.dart';

const int _mainCodeSize = 299;
const int _offsetCodeSize = 60;
const int _lowOffsetCodeSize = 17;
const int _lengthCodeSize = 28;
const int _tableSize =
    _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize + _lengthCodeSize;
const int _precodeSymbols = 20;

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

  Huffman? _mainCode;
  Huffman? _offsetCode;
  Huffman? _lowOffsetCode;
  Huffman? _lengthCode;
  final Uint8List _lengthTable = Uint8List(_tableSize);

  final List<int> _oldOffset = [0, 0, 0, 0];
  int _lastOffset = 0;
  int _lastLength = 0;
  int _lastLowOffset = 0;
  int _lowOffsetRepeats = 0;

  // PPMd variant H state. `_ppmdActive` tracks whether the current block is a
  // PPMd block (set by `_parseCodes` from the block-type bit). The model and
  // its memory size persist across blocks/files (a solid run or a mid-file
  // block switch reuses them); the range decoder is re-initialised per block.
  Ppmd7Model? _ppmd;
  PpmdRarRangeDecoder? _ppmdRange;
  bool _ppmdActive = false;
  int _ppmdEscape = 2;
  int _ppmdMemSize = 0;

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
    final bits = Bits(packed);
    if (parseTable) {
      _parseCodes(bits); // run start / non-solid: read the table block
    } else if (!hasTables) {
      throw const FormatException(
        'RAR4 solid continuation without a preceding table',
      );
    }
    final mask = output.length - 1;

    while (writePtr < target) {
      if (_ppmdActive) {
        if (_decodePpmdStep(bits, mask, target)) break; // PPMd end-of-data
        continue;
      }
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

  /// Decodes one file of a solid RAR4 **PPMd** run from its own [packed] block
  /// into the shared window, appending from the current [writePtr]. Reuse the
  /// same decoder across the run's files: the PPMd model and the escape symbol
  /// persist (the RAR-block escape char is only reset by flag 0x40, so a
  /// continuation inherits it), while the range decoder re-initialises per
  /// block. Unlike method-29, a solid PPMd file is *not* decoded to a byte
  /// count — it runs to its end-of-data marker (escape code 2), whose symbols
  /// update the shared model, so skipping them would desync it for the next
  /// file. A stored/empty member in the run does not call this — its raw bytes
  /// are appended to the window directly, between PPMd files.
  ///
  /// [unpackedSize] is the file's declared output size; a valid block reaches
  /// its escape-code-2 marker exactly there, so it bounds the decode loop
  /// against corrupt input that never emits the marker (which would otherwise
  /// spin filling the window forever).
  ///
  /// Structure adapted from the BSD Go `rardecode` reader (see
  /// `doc/references.md`); the model is the same public-domain Ppmd7. Returns
  /// the file's `[start, end)` window bounds.
  ({int start, int end}) decompressSolidPpmdFile(
    Uint8List packed,
    int unpackedSize,
  ) {
    final bits = Bits(packed);
    _parseCodes(bits); // this file's block header
    if (!_ppmdActive) {
      throw const FormatException('RAR4 solid PPMd run is not PPMd');
    }
    final start = writePtr;
    final end = start + unpackedSize;
    if (end > output.length) {
      throw const FormatException('RAR4 solid PPMd run exceeds window');
    }
    final mask = output.length - 1;
    while (!_decodePpmdStep(bits, mask, output.length)) {
      if (!_ppmdActive) {
        // A mid-file PPMd→method-29 (LZSS) switch inside a *solid* PPMd run:
        // the shared PPMd loop here has no LZSS path, and continuing would
        // decode LZSS bytes as PPMd symbols. Reject cleanly (doubly rare: solid
        // + `-mct` auto-switch). The non-solid path handles the switch.
        throw const FormatException(
          'RAR4 solid PPMd-to-LZSS mid-file block switch is not supported',
        );
      }
      if (writePtr > end) {
        throw const FormatException('RAR4 solid PPMd file overran its size');
      }
    }
    return (start: start, end: writePtr);
  }

  /// Parses a PPMd (variant H) block header and sets up the model + range
  /// decoder. Follows libarchive `parse_codes`' PPMd branch: a 7-bit flags
  /// field, an optional memory byte (flag 0x20 → MB), an optional escape byte
  /// (flag 0x40), and, when 0x20 is set, a fresh model of the given max order.
  /// Flag 0x20 clear reuses the model left by an earlier block, re-initialising
  /// only the range decoder over the new byte stream.
  void _parsePpmdBlock(Bits bits) {
    final flags = bits.read(7);
    if (flags & 0x20 != 0) {
      _ppmdMemSize = (bits.read(8) + 1) << 20;
    }
    // The escape symbol persists across blocks: flag 0x40 sets a new one,
    // otherwise the previous value carries over (it defaults to 2). This matters
    // for solid runs — a continuation block clears 0x40 and inherits the first
    // block's escape (libarchive resets it to 2 here, but libarchive never
    // decodes a solid RAR, so it never exercises the carry-over; the Go
    // `rardecode` reader, which does handle solid, persists it).
    if (flags & 0x40 != 0) {
      _ppmdEscape = bits.read(8);
    }

    final range = PpmdRarRangeDecoder(() => bits.read(8));

    if (flags & 0x20 != 0) {
      var maxOrder = (flags & 0x1F) + 1;
      if (maxOrder > 16) maxOrder = 16 + (maxOrder - 16) * 3;
      if (maxOrder == 1) {
        throw const FormatException('invalid RAR4 PPMd max order');
      }
      if (_ppmdMemSize == 0) {
        throw const FormatException('invalid RAR4 PPMd memory size');
      }
      final model = Ppmd7Model();
      if (!model.alloc(_ppmdMemSize)) {
        throw const FormatException('RAR4 PPMd allocation failed');
      }
      if (!range.init()) {
        throw const FormatException('RAR4 PPMd range decoder init failed');
      }
      model.init(maxOrder);
      if (flags & 0x40 != 0) model.initEsc = _ppmdEscape;
      _ppmd = model;
    } else {
      if (_ppmd == null) {
        throw const FormatException('RAR4 PPMd continuation without a model');
      }
      if (!range.init()) {
        throw const FormatException('RAR4 PPMd range decoder init failed');
      }
    }
    _ppmdRange = range;
  }

  /// Decodes one PPMd symbol/action into the window. Follows libarchive's
  /// escape-char dispatch (`read_data_compressed`): a non-escape symbol is a
  /// literal; an escape introduces a control code — 0 starts a new table
  /// block, 2 ends the PPMd data, 4/5 are LZ matches, and anything else emits
  /// the escape symbol itself. Returns true on end-of-data (code 2).
  bool _decodePpmdStep(Bits bits, int mask, int target) {
    final sym = _ppmdSymbol();
    if (sym != _ppmdEscape) {
      output[writePtr++ & mask] = sym;
      return false;
    }
    switch (_ppmdSymbol()) {
      case 0:
        // End of this PPMd block; a new block header follows in the stream
        // (`rardecode`'s endOfBlock → readBlockHeader). Read it the same way any
        // block boundary is read — [_parseCodes] aligns to a byte, reads the
        // block-type bit, and sets up either another PPMd block (model carried
        // over) or a method-29 (LZSS) table block, flipping [_ppmdActive]. The
        // range decoder read whole bytes through the shared [bits], so the LZSS
        // decoder resumes from the aligned position with no look-ahead to undo
        // (mirroring `rardecode`'s unified `fill()`/`readBlockHeader()` loop).
        // The caller's decode loop then dispatches on [_ppmdActive].
        _parseCodes(bits);
        return false;
      case 2:
        return true; // end of PPMd data
      case 3:
        // A RarVM filter reached through PPMd: the filter bytes arrive via the
        // PPMd symbol stream rather than the LZ bitstream, and wiring that hand-
        // off into [Rar4Filters] is unimplemented (libarchive does not parse it
        // either). The generic VM (R6) can now *run* any program, so this is an
        // implementation gap, not a license one; still a typed error, and rare.
        throw const FormatException(
          'RAR4 PPMd embedded filters are not supported',
        );
      case 4:
        var offset = 0;
        for (var i = 2; i >= 0; i--) {
          offset |= _ppmdSymbol() << (i * 8);
        }
        _copy(_ppmdSymbol() + 32, offset + 2, mask, target);
        return false;
      case 5:
        _copy(_ppmdSymbol() + 4, 1, mask, target);
        return false;
      default:
        output[writePtr++ & mask] = sym;
        return false;
    }
  }

  /// Decodes one PPMd model symbol, mapping the model's own [PpmdError] and any
  /// out-of-range access on corrupt model state to a typed [FormatException]
  /// (the reader turns it into a `CorruptArchiveException`) — never an untyped
  /// crash.
  int _ppmdSymbol() {
    try {
      return _ppmd!.decodeSymbol(_ppmdRange!);
    } on PpmdError catch (e) {
      throw FormatException('RAR4 PPMd: ${e.message}');
    } on RangeError {
      throw const FormatException('RAR4 PPMd: corrupt model state');
    }
  }

  void _parseCodes(Bits bits) {
    bits.alignToByte();
    final isPpmd = bits.read(1) != 0;
    _ppmdActive = isPpmd;
    if (isPpmd) {
      _parsePpmdBlock(bits);
      return;
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
    final precode = Huffman(precodeLengths, _precodeSymbols);

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

    _mainCode = Huffman(
      Uint8List.sublistView(_lengthTable, 0, _mainCodeSize),
      _mainCodeSize,
    );
    _offsetCode = Huffman(
      Uint8List.sublistView(
        _lengthTable,
        _mainCodeSize,
        _mainCodeSize + _offsetCodeSize,
      ),
      _offsetCodeSize,
    );
    _lowOffsetCode = Huffman(
      Uint8List.sublistView(
        _lengthTable,
        _mainCodeSize + _offsetCodeSize,
        _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize,
      ),
      _lowOffsetCodeSize,
    );
    _lengthCode = Huffman(
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

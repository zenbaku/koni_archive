/// PPMd variant H (Dmitry Shkarin's PPMII, as used by RAR4 "text compression")
/// decoder: a range/arithmetic decoder plus an order-N context model with SEE
/// (secondary escape estimation), a suffix-linked context tree, and a unit
/// sub-allocator.
///
/// Clean-room per `doc/rar-provenance.md`. The model
/// ([Ppmd7Model.alloc]/[Ppmd7Model.init]/[Ppmd7Model.decodeSymbol] and the
/// sub-allocator) is a port of the **public-domain** Ppmd7 var.H codec (Igor
/// Pavlov, 2010; based on PPMd var.H 2001 by Dmitry Shkarin) as vendored by
/// libarchive (`archive_ppmd7.c` / `archive_ppmd7_private.h`). The RAR-specific
/// range decoder ([PpmdRarRangeDecoder]) follows libarchive's
/// `PpmdRAR_RangeDec_*`. See `doc/references.md` and `NOTICE`. No unrar or GPL
/// source was consulted.
///
/// The C code addresses model nodes by casting a byte pool (`Base`) with 32-bit
/// offset refs; this port keeps that representation exactly — [_base] is the
/// pool and every context/state/node is an `int` byte offset into it, read and
/// written through a little-endian [ByteData] view. That faithfulness is
/// deliberate: the sub-allocator's free-list and glue logic depend on precise
/// unit addressing, and the `CPpmd7_Context`/`CPpmd_State` structs alias (a
/// one-symbol context stores its single state overlapping `SummFreq`+`Stats`).
///
/// All range-coder arithmetic is masked to 32 bits so dart2js (doubles, exact
/// only to 2^53) matches the VM and native C byte-for-byte.
library;

import 'dart:typed_data';

/// A byte source for the range decoder: returns the next byte (0 at EOF).
typedef PpmdByteReader = int Function();

const int _kTopValue = 1 << 24;
const int _kBot = 0x8000;
const int _mask32 = 0xFFFFFFFF;

/// RAR's PPMd range decoder (libarchive `PpmdRAR_RangeDec_*`). Distinct from
/// the 7-Zip variant: no leading zero byte on init, `Bottom = 0x8000`, and
/// `Decode`/`DecodeBit` work in `Low`/`Range` space rather than subtracting
/// from `Code`.
final class PpmdRarRangeDecoder {
  /// Creates a range decoder pulling bytes from [_readByte] (0 at EOF).
  PpmdRarRangeDecoder(this._readByte);

  final PpmdByteReader _readByte;

  int _range = 0;
  int _code = 0;
  int _low = 0;
  int _bottom = 0;

  /// Reads the initial 4 code bytes. Returns false if the stream declares an
  /// invalid (all-ones) initial code, matching `Ppmd_RangeDec_Init`.
  bool init() {
    _low = 0;
    _bottom = 0;
    _range = _mask32;
    _code = 0;
    for (var i = 0; i < 4; i++) {
      _code = ((_code << 8) | _readByte()) & _mask32;
    }
    _bottom = _kBot;
    return _code < _mask32;
  }

  void _normalize() {
    while (true) {
      if (((_low ^ ((_low + _range) & _mask32)) & _mask32) >= _kTopValue) {
        if (_range >= _bottom) break;
        _range = ((-_low) & _mask32) & (_bottom - 1);
      }
      _code = ((_code << 8) | _readByte()) & _mask32;
      _range = (_range << 8) & _mask32;
      _low = (_low << 8) & _mask32;
    }
  }

  /// `Range_GetThreshold`: divides `Range` by [total] (mutating it) and returns
  /// the current threshold `(Code - Low) / Range`.
  int getThreshold(int total) {
    _range = _range ~/ total;
    return ((_code - _low) & _mask32) ~/ _range;
  }

  /// `Range_Decode_RAR`: narrows to the sub-range `[start, start+size)`.
  void decode(int start, int size) {
    _low = (_low + start * _range) & _mask32;
    _range = (_range * size) & _mask32;
    _normalize();
  }

  /// `Range_DecodeBit_RAR`: decodes a single binary decision with probability
  /// [size0] out of `PPMD_BIN_SCALE`.
  int decodeBit(int size0) {
    final value = getThreshold(_ppmdBinScale);
    if (value < size0) {
      decode(0, size0);
      return 0;
    }
    decode(size0, _ppmdBinScale - size0);
    return 1;
  }
}

// ---------------------------------------------------------------------------
// Model constants (archive_ppmd_private.h / archive_ppmd7.c).
// ---------------------------------------------------------------------------

const int _ppmdIntBits = 7;
const int _ppmdPeriodBits = 7;
const int _ppmdBinScale = 1 << (_ppmdIntBits + _ppmdPeriodBits); // 16384

const int _n1 = 4, _n2 = 4, _n3 = 4;
const int _n4 = (128 + 3 - 1 * _n1 - 2 * _n2 - 3 * _n3) ~/ 4;
const int _numIndexes = _n1 + _n2 + _n3 + _n4; // 38

const int _unitSize = 12;
const int _maxFreq = 124;

const List<int> _kInitBinEsc = [
  0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051, //
];
const List<int> _kExpEscape = [
  25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2, //
];

int _getMean(int summ) =>
    (summ + (1 << (_ppmdPeriodBits - 2))) >> _ppmdPeriodBits;

/// Thrown internally when the model reaches an inconsistent state (corrupt
/// input). The RAR decoder maps this to a `FormatException`.
class PpmdError implements Exception {
  /// Creates a model-state error with a short [message].
  const PpmdError(this.message);

  /// A short description of the inconsistency (mapped to a `FormatException`).
  final String message;
  @override
  String toString() => 'PpmdError: $message';
}

/// PPMd variant H model + decoder over a [PpmdRarRangeDecoder].
final class Ppmd7Model {
  /// Creates an uninitialised model; call [alloc] then [init] before decoding.
  Ppmd7Model() {
    _construct();
  }

  // ---- Byte pool (Base) and field accessors --------------------------------
  late Uint8List _base;
  late ByteData _bd;
  int _size = 0;
  int _alignOffset = 0;

  int _u8(int off) => _base[off];
  void _setU8(int off, int v) => _base[off] = v & 0xFF;
  int _u16(int off) => _bd.getUint16(off, Endian.little);
  void _setU16(int off, int v) => _bd.setUint16(off, v & 0xFFFF, Endian.little);
  int _u32(int off) => _bd.getUint32(off, Endian.little);
  void _setU32(int off, int v) =>
      _bd.setUint32(off, v & _mask32, Endian.little);

  // Context (12 bytes): NumStats u16@0, SummFreq u16@2, Stats ref u32@4,
  // Suffix ref u32@8. A one-symbol context's single state overlays @2.
  int _numStats(int c) => _u16(c);
  void _setNumStats(int c, int v) => _setU16(c, v);
  int _summFreq(int c) => _u16(c + 2);
  void _setSummFreq(int c, int v) => _setU16(c + 2, v);
  int _stats(int c) => _u32(c + 4);
  void _setStats(int c, int v) => _setU32(c + 4, v);
  int _suffix(int c) => _u32(c + 8);
  void _setSuffix(int c, int v) => _setU32(c + 8, v);
  int _oneState(int c) => c + 2;

  // State (6 bytes): Symbol u8@0, Freq u8@1, SuccessorLow u16@2,
  // SuccessorHigh u16@4.
  int _symbol(int s) => _u8(s);
  void _setSymbol(int s, int v) => _setU8(s, v);
  int _freq(int s) => _u8(s + 1);
  void _setFreq(int s, int v) => _setU8(s + 1, v);
  int _successor(int s) => _u16(s + 2) | (_u16(s + 4) << 16);
  void _setSuccessor(int s, int v) {
    _setU16(s + 2, v & 0xFFFF);
    _setU16(s + 4, (v >> 16) & 0xFFFF);
  }

  // Node (free-block, for glue): Stamp u16@0, NU u16@2, Next ref u32@4,
  // Prev ref u32@8. A free block's next-ref is a u32 @0.
  int _nodeStamp(int n) => _u16(n);
  void _setNodeStamp(int n, int v) => _setU16(n, v);
  int _nodeNU(int n) => _u16(n + 2);
  void _setNodeNU(int n, int v) => _setU16(n + 2, v);
  int _nodeNext(int n) => _u32(n + 4);
  void _setNodeNext(int n, int v) => _setU32(n + 4, v);
  int _nodePrev(int n) => _u32(n + 8);
  void _setNodePrev(int n, int v) => _setU32(n + 8, v);
  int _nodeNextRef(int n) => _u32(n); // single-linked free-list next
  void _setNodeNextRef(int n, int v) => _setU32(n, v);

  // Copy [nu] units (12 bytes each) between offsets in the pool.
  void _copyUnits(int dst, int src, int nu) {
    final n = nu * _unitSize;
    _base.setRange(dst, dst + n, _base, src);
  }

  // ---- Static tables (built once in construct) -----------------------------
  final Uint8List _indx2Units = Uint8List(_numIndexes);
  final Uint8List _units2Indx = Uint8List(128);
  final Uint8List _ns2BsIndx = Uint8List(256);
  final Uint8List _ns2Indx = Uint8List(256);
  final Uint8List _hb2Flag = Uint8List(256);

  int _i2u(int indx) => _indx2Units[indx];
  int _u2i(int nu) => _units2Indx[nu - 1];
  int _u2b(int nu) => nu * _unitSize;

  // ---- Model state ---------------------------------------------------------
  final Int32List _freeList = Int32List(_numIndexes);
  int _text = 0, _unitsStart = 0, _loUnit = 0, _hiUnit = 0;
  int _glueCount = 0;

  int _minContext = 0, _maxContext = 0, _foundState = 0;
  int _orderFall = 0, _prevSuccess = 0, _maxOrder = 0;

  /// The escape symbol seeded by the RAR block header (`InitEsc`); the RAR block
  /// parser sets it when flag 0x40 is present, and the model updates it during
  /// binary escapes.
  int initEsc = 0;
  int _hiBitsFlag = 0;
  int _runLength = 0, _initRL = 0;

  // BinSumm[128][64] and See[25][16] (Summ u16, Shift u8, Count u8). The C
  // model's DummySee (used when NumStats == 256) is never read — MakeEscFreq
  // returns escFreq = 1 there and its Summ update is a no-op (Shift ==
  // PERIOD_BITS) — so it is represented by the -1 sentinel from _makeEscFreq.
  final Uint16List _binSumm = Uint16List(128 * 64);
  final Uint16List _seeSumm = Uint16List(25 * 16);
  final Uint8List _seeShift = Uint8List(25 * 16);
  final Uint8List _seeCount = Uint8List(25 * 16);

  // Scratch reused across decodeSymbol calls (avoids per-symbol allocation).
  final Int8List _charMask = Int8List(256);
  final Int32List _ps = Int32List(256);

  void _construct() {
    var k = 0;
    for (var i = 0; i < _numIndexes; i++) {
      var step = i >= 12 ? 4 : (i >> 2) + 1;
      do {
        _units2Indx[k++] = i;
      } while (--step != 0);
      _indx2Units[i] = k;
    }

    _ns2BsIndx[0] = 0;
    _ns2BsIndx[1] = 2;
    for (var i = 2; i < 11; i++) {
      _ns2BsIndx[i] = 4;
    }
    for (var i = 11; i < 256; i++) {
      _ns2BsIndx[i] = 6;
    }

    for (var i = 0; i < 3; i++) {
      _ns2Indx[i] = i;
    }
    var m = 3;
    k = 1;
    for (var i = 3; i < 256; i++) {
      _ns2Indx[i] = m;
      if (--k == 0) {
        m++;
        k = m - 2;
      }
    }

    for (var i = 0; i < 0x40; i++) {
      _hb2Flag[i] = 0;
    }
    for (var i = 0x40; i < 256; i++) {
      _hb2Flag[i] = 8;
    }
  }

  /// Allocates the [size]-byte sub-allocator pool. Mirrors `Ppmd7_Alloc`:
  /// pool = alignOffset + size + one extra unit (the glue list head).
  bool alloc(int size) {
    if (size < _unitSize) return false;
    _alignOffset = 4 - (size & 3);
    _base = Uint8List(_alignOffset + size + _unitSize);
    _bd = ByteData.view(_base.buffer, _base.offsetInBytes);
    _size = size;
    return true;
  }

  /// `Ppmd7_Init`: resets the model to order [maxOrder].
  void init(int maxOrder) {
    _maxOrder = maxOrder;
    _restartModel();
  }

  // ---- Sub-allocator -------------------------------------------------------
  void _insertNode(int node, int indx) {
    _setNodeNextRef(node, _freeList[indx]);
    _freeList[indx] = node;
  }

  int _removeNode(int indx) {
    final node = _freeList[indx];
    _freeList[indx] = _nodeNextRef(node);
    return node;
  }

  void _splitBlock(int ptr, int oldIndx, int newIndx) {
    final nu = _i2u(oldIndx) - _i2u(newIndx);
    ptr = ptr + _u2b(_i2u(newIndx));
    var i = _u2i(nu);
    if (_i2u(i) != nu) {
      final k = _i2u(--i);
      _insertNode(ptr + _u2b(k), nu - k - 1);
    }
    _insertNode(ptr, i);
  }

  void _glueFreeBlocks() {
    final head = _alignOffset + _size;
    var n = head;

    _glueCount = 255;

    for (var i = 0; i < _numIndexes; i++) {
      final nu = _i2u(i);
      var next = _freeList[i];
      _freeList[i] = 0;
      while (next != 0) {
        final node = next;
        _setNodeNext(node, n);
        // n = NODE(n)->Prev = next
        _setNodePrev(n, next);
        n = next;
        next = _nodeNextRef(node);
        _setNodeStamp(node, 0);
        _setNodeNU(node, nu);
      }
    }
    _setNodeStamp(head, 1);
    _setNodeNext(head, n);
    _setNodePrev(n, head);
    if (_loUnit != _hiUnit) {
      _setNodeStamp(_loUnit, 1);
    }

    // Glue adjacent free blocks.
    while (n != head) {
      final node = n;
      var nu = _nodeNU(node);
      while (true) {
        final node2 = node + nu * _unitSize;
        nu += _nodeNU(node2);
        if (_nodeStamp(node2) != 0 || nu >= 0x10000) break;
        _setNodeNext(_nodePrev(node2), _nodeNext(node2));
        _setNodePrev(_nodeNext(node2), _nodePrev(node2));
        _setNodeNU(node, nu);
      }
      n = _nodeNext(node);
    }

    // Fill the free lists.
    n = _nodeNext(head);
    while (n != head) {
      var node = n;
      final next = _nodeNext(node);
      var nu = _nodeNU(node);
      while (nu > 128) {
        _insertNode(node, _numIndexes - 1);
        nu -= 128;
        node += 128 * _unitSize;
      }
      var i = _u2i(nu);
      if (_i2u(i) != nu) {
        final k = _i2u(--i);
        _insertNode(node + k * _unitSize, nu - k - 1);
      }
      _insertNode(node, i);
      n = next;
    }
  }

  int _allocUnitsRare(int indx) {
    if (_glueCount == 0) {
      _glueFreeBlocks();
      if (_freeList[indx] != 0) return _removeNode(indx);
    }
    var i = indx;
    do {
      if (++i == _numIndexes) {
        final numBytes = _u2b(_i2u(indx));
        _glueCount--;
        if ((_unitsStart - _text) > numBytes) {
          _unitsStart -= numBytes;
          return _unitsStart;
        }
        return 0;
      }
    } while (_freeList[i] == 0);
    final retVal = _removeNode(i);
    _splitBlock(retVal, i, indx);
    return retVal;
  }

  int _allocUnits(int indx) {
    if (_freeList[indx] != 0) return _removeNode(indx);
    final numBytes = _u2b(_i2u(indx));
    if (numBytes <= _hiUnit - _loUnit) {
      final retVal = _loUnit;
      _loUnit += numBytes;
      return retVal;
    }
    return _allocUnitsRare(indx);
  }

  int _shrinkUnits(int oldPtr, int oldNU, int newNU) {
    final i0 = _u2i(oldNU);
    final i1 = _u2i(newNU);
    if (i0 == i1) return oldPtr;
    if (_freeList[i1] != 0) {
      final ptr = _removeNode(i1);
      _copyUnits(ptr, oldPtr, newNU);
      _insertNode(oldPtr, i0);
      return ptr;
    }
    _splitBlock(oldPtr, i0, i1);
    return oldPtr;
  }

  void _restartModel() {
    for (var i = 0; i < _numIndexes; i++) {
      _freeList[i] = 0;
    }
    _text = _alignOffset;
    _hiUnit = _text + _size;
    _loUnit = _unitsStart = _hiUnit - (_size ~/ 8 ~/ _unitSize * 7 * _unitSize);
    _glueCount = 0;

    _orderFall = _maxOrder;
    _runLength = _initRL = -((_maxOrder < 12 ? _maxOrder : 12)) - 1;
    _prevSuccess = 0;

    _hiUnit -= _unitSize;
    _minContext = _maxContext = _hiUnit;
    _setSuffix(_minContext, 0);
    _setNumStats(_minContext, 256);
    _setSummFreq(_minContext, 256 + 1);
    _foundState = _loUnit;
    _loUnit += _u2b(256 ~/ 2);
    _setStats(_minContext, _foundState);
    for (var i = 0; i < 256; i++) {
      final s = _foundState + i * 6;
      _setSymbol(s, i);
      _setFreq(s, 1);
      _setSuccessor(s, 0);
    }

    for (var i = 0; i < 128; i++) {
      for (var k = 0; k < 8; k++) {
        final val = _ppmdBinScale - _kInitBinEsc[k] ~/ (i + 2);
        for (var m = 0; m < 64; m += 8) {
          _binSumm[i * 64 + k + m] = val;
        }
      }
    }

    for (var i = 0; i < 25; i++) {
      for (var k = 0; k < 16; k++) {
        final idx = i * 16 + k;
        _seeShift[idx] = _ppmdPeriodBits - 4;
        _seeSumm[idx] = (5 * i + 10) << (_ppmdPeriodBits - 4);
        _seeCount[idx] = 4;
      }
    }
  }

  // ---- Model update --------------------------------------------------------
  int _createSuccessors(bool skip) {
    var c = _minContext;
    final upBranch = _successor(_foundState);
    final ps = <int>[];

    if (!skip) ps.add(_foundState);

    while (_suffix(c) != 0) {
      c = _suffix(c);
      int s;
      if (_numStats(c) != 1) {
        s = _stats(c);
        while (_symbol(s) != _symbol(_foundState)) {
          s += 6;
        }
      } else {
        s = _oneState(c);
      }
      final successor = _successor(s);
      if (successor != upBranch) {
        c = successor;
        if (ps.isEmpty) return c;
        break;
      }
      ps.add(s);
    }

    // upState is a transient state built on the stack in C.
    final upSymbol = _u8(upBranch);
    final upSuccessor = upBranch + 1;
    int upFreq;
    if (_numStats(c) == 1) {
      upFreq = _freq(_oneState(c));
    } else {
      var s = _stats(c);
      while (_symbol(s) != upSymbol) {
        s += 6;
      }
      final cf = _freq(s) - 1;
      final s0 = _summFreq(c) - _numStats(c) - cf;
      upFreq =
          1 +
          ((2 * cf <= s0)
              ? (5 * cf > s0 ? 1 : 0)
              : ((2 * cf + 3 * s0 - 1) ~/ (2 * s0)));
    }

    while (ps.isNotEmpty) {
      int c1;
      if (_hiUnit != _loUnit) {
        _hiUnit -= _unitSize;
        c1 = _hiUnit;
      } else if (_freeList[0] != 0) {
        c1 = _removeNode(0);
      } else {
        c1 = _allocUnitsRare(0);
        if (c1 == 0) return 0;
      }
      _setNumStats(c1, 1);
      final os = _oneState(c1);
      _setSymbol(os, upSymbol);
      _setFreq(os, upFreq);
      _setSuccessor(os, upSuccessor);
      _setSuffix(c1, c);
      _setSuccessor(ps.removeLast(), c1);
      c = c1;
    }
    return c;
  }

  void _swapStates(int a, int b) {
    for (var i = 0; i < 6; i++) {
      final t = _base[a + i];
      _base[a + i] = _base[b + i];
      _base[b + i] = t;
    }
  }

  void _updateModel() {
    var fSuccessor = _successor(_foundState);
    int successor;
    int c;

    if (_freq(_foundState) < _maxFreq ~/ 4 && _suffix(_minContext) != 0) {
      c = _suffix(_minContext);
      if (_numStats(c) == 1) {
        final s = _oneState(c);
        if (_freq(s) < 32) _setFreq(s, _freq(s) + 1);
      } else {
        var s = _stats(c);
        if (_symbol(s) != _symbol(_foundState)) {
          do {
            s += 6;
          } while (_symbol(s) != _symbol(_foundState));
          if (_freq(s) >= _freq(s - 6)) {
            _swapStates(s, s - 6);
            s -= 6;
          }
        }
        if (_freq(s) < _maxFreq - 9) {
          _setFreq(s, _freq(s) + 2);
          _setSummFreq(c, _summFreq(c) + 2);
        }
      }
    }

    if (_orderFall == 0) {
      final cs = _createSuccessors(true);
      if (cs == 0) {
        _restartModel();
        return;
      }
      _minContext = _maxContext = cs;
      _setSuccessor(_foundState, cs);
      return;
    }

    _setU8(_text, _symbol(_foundState));
    _text++;
    successor = _text;
    if (_text >= _unitsStart) {
      _restartModel();
      return;
    }

    if (fSuccessor != 0) {
      if (fSuccessor <= successor) {
        final cs = _createSuccessors(false);
        if (cs == 0) {
          _restartModel();
          return;
        }
        fSuccessor = cs;
      }
      if (--_orderFall == 0) {
        successor = fSuccessor;
        if (_maxContext != _minContext) _text--;
      }
    } else {
      _setSuccessor(_foundState, successor);
      fSuccessor = _minContext;
    }

    final ns = _numStats(_minContext);
    final s0 = _summFreq(_minContext) - ns - (_freq(_foundState) - 1);

    for (c = _maxContext; c != _minContext; c = _suffix(c)) {
      final ns1 = _numStats(c);
      if (ns1 != 1) {
        if ((ns1 & 1) == 0) {
          final oldNU = ns1 >> 1;
          final i = _u2i(oldNU);
          if (i != _u2i(oldNU + 1)) {
            final ptr = _allocUnits(i + 1);
            if (ptr == 0) {
              _restartModel();
              return;
            }
            final oldPtr = _stats(c);
            _copyUnits(ptr, oldPtr, oldNU);
            _insertNode(oldPtr, i);
            _setStats(c, ptr);
          }
        }
        _setSummFreq(
          c,
          _summFreq(c) +
              (2 * ns1 < ns ? 1 : 0) +
              2 *
                  (((4 * ns1 <= ns ? 1 : 0) &
                      (_summFreq(c) <= 8 * ns1 ? 1 : 0))),
        );
      } else {
        final s = _allocUnits(0);
        if (s == 0) {
          _restartModel();
          return;
        }
        _copyState(s, _oneState(c));
        _setStats(c, s);
        var f = _freq(s);
        if (f < _maxFreq ~/ 4 - 1) {
          f <<= 1;
        } else {
          f = _maxFreq - 4;
        }
        _setFreq(s, f);
        _setSummFreq(c, f + initEsc + (ns > 3 ? 1 : 0));
      }
      var cf = 2 * _freq(_foundState) * (_summFreq(c) + 6);
      final sf = s0 + _summFreq(c);
      if (cf < 6 * sf) {
        cf = 1 + (cf > sf ? 1 : 0) + (cf >= 4 * sf ? 1 : 0);
        _setSummFreq(c, _summFreq(c) + 3);
      } else {
        cf =
            4 +
            (cf >= 9 * sf ? 1 : 0) +
            (cf >= 12 * sf ? 1 : 0) +
            (cf >= 15 * sf ? 1 : 0);
        _setSummFreq(c, _summFreq(c) + cf);
      }
      final s = _stats(c) + ns1 * 6;
      _setSuccessor(s, successor);
      _setSymbol(s, _symbol(_foundState));
      _setFreq(s, cf);
      _setNumStats(c, ns1 + 1);
    }
    _maxContext = _minContext = fSuccessor;
  }

  void _copyState(int dst, int src) {
    _base.setRange(dst, dst + 6, _base, src);
  }

  void _rescale() {
    final stats = _stats(_minContext);
    var s = _foundState;
    // Move FoundState to the front.
    {
      final tmp = Uint8List(6)..setRange(0, 6, _base, s);
      while (s != stats) {
        _copyState(s, s - 6);
        s -= 6;
      }
      _base.setRange(s, s + 6, tmp);
    }
    var escFreq = _summFreq(_minContext) - _freq(s);
    _setFreq(s, _freq(s) + 4);
    final adder = _orderFall != 0 ? 1 : 0;
    _setFreq(s, (_freq(s) + adder) >> 1);
    var sumFreq = _freq(s);

    var i = _numStats(_minContext) - 1;
    do {
      s += 6;
      escFreq -= _freq(s);
      _setFreq(s, (_freq(s) + adder) >> 1);
      sumFreq += _freq(s);
      if (_freq(s) > _freq(s - 6)) {
        var s1 = s;
        final tmp = Uint8List(6)..setRange(0, 6, _base, s1);
        do {
          _copyState(s1, s1 - 6);
          s1 -= 6;
        } while (s1 != stats && (tmp[1] & 0xFF) > _freq(s1 - 6));
        _base.setRange(s1, s1 + 6, tmp);
      }
    } while (--i != 0);

    if (_freq(s) == 0) {
      final numStats = _numStats(_minContext);
      var cnt = 0;
      do {
        cnt++;
        s -= 6;
      } while (_freq(s) == 0);
      escFreq += cnt;
      final newNumStats = _numStats(_minContext) - cnt;
      _setNumStats(_minContext, newNumStats);
      if (newNumStats == 1) {
        final tmp = Uint8List(6)..setRange(0, 6, _base, stats);
        var tmpFreq = tmp[1] & 0xFF;
        do {
          tmpFreq -= tmpFreq >> 1;
          escFreq >>= 1;
        } while (escFreq > 1);
        tmp[1] = tmpFreq & 0xFF;
        _insertNode(stats, _u2i((numStats + 1) >> 1));
        _foundState = _oneState(_minContext);
        _base.setRange(_foundState, _foundState + 6, tmp);
        return;
      }
      final n0 = (numStats + 1) >> 1;
      final n1 = (newNumStats + 1) >> 1;
      if (n0 != n1) {
        _setStats(_minContext, _shrinkUnits(stats, n0, n1));
      }
    }
    _setSummFreq(_minContext, sumFreq + escFreq - (escFreq >> 1));
    _foundState = _stats(_minContext);
  }

  // Returns the flat See index (or -1 for DummySee) and writes escFreq via the
  // single-element out list. Mirrors Ppmd7_MakeEscFreq.
  int _makeEscFreq(int numMasked, List<int> escFreqOut) {
    final nonMasked = _numStats(_minContext) - numMasked;
    if (_numStats(_minContext) != 256) {
      final idx =
          _ns2Indx[nonMasked - 1] * 16 +
          ((nonMasked < _numStats(_suffix(_minContext)) - _numStats(_minContext)
                  ? 1
                  : 0) +
              2 *
                  (_summFreq(_minContext) < 11 * _numStats(_minContext)
                      ? 1
                      : 0) +
              4 * (numMasked > nonMasked ? 1 : 0) +
              _hiBitsFlag);
      final r = _seeSumm[idx] >> _seeShift[idx];
      _seeSumm[idx] = (_seeSumm[idx] - r) & 0xFFFF;
      escFreqOut[0] = r + (r == 0 ? 1 : 0);
      return idx;
    }
    escFreqOut[0] = 1;
    return -1;
  }

  void _seeUpdate(int idx) {
    if (idx < 0) return; // DummySee: never updated
    if (_seeShift[idx] < _ppmdPeriodBits) {
      _seeCount[idx]--;
      if (_seeCount[idx] == 0) {
        _seeSumm[idx] = (_seeSumm[idx] << 1) & 0xFFFF;
        _seeCount[idx] = 3 << _seeShift[idx];
        _seeShift[idx]++;
      }
    }
  }

  void _nextContext() {
    final c = _successor(_foundState);
    if (_orderFall == 0 && c > _text) {
      _minContext = _maxContext = c;
    } else {
      _updateModel();
    }
  }

  void _update1(int s) {
    _foundState = s;
    _setFreq(s, _freq(s) + 4);
    _setSummFreq(_minContext, _summFreq(_minContext) + 4);
    if (_freq(s) > _freq(s - 6)) {
      _swapStates(s, s - 6);
      _foundState = s - 6;
      if (_freq(s - 6) > _maxFreq) _rescale();
    }
    _nextContext();
  }

  void _update1_0(int s) {
    _foundState = s;
    _prevSuccess = (2 * _freq(s) > _summFreq(_minContext)) ? 1 : 0;
    _runLength += _prevSuccess;
    _setSummFreq(_minContext, _summFreq(_minContext) + 4);
    _setFreq(s, _freq(s) + 4);
    if (_freq(s) > _maxFreq) _rescale();
    _nextContext();
  }

  void _updateBin(int s) {
    _foundState = s;
    _setFreq(s, _freq(s) + (_freq(s) < 128 ? 1 : 0));
    _prevSuccess = 1;
    _runLength++;
    _nextContext();
  }

  void _update2(int s) {
    _foundState = s;
    _setSummFreq(_minContext, _summFreq(_minContext) + 4);
    _setFreq(s, _freq(s) + 4);
    if (_freq(s) > _maxFreq) _rescale();
    _runLength = _initRL;
    _updateModel();
  }

  int _getBinSummIndex() {
    final os = _oneState(_minContext);
    _hiBitsFlag = _hb2Flag[_symbol(_foundState)];
    final row = _freq(os) - 1;
    final col =
        _prevSuccess +
        _ns2BsIndx[_numStats(_suffix(_minContext)) - 1] +
        _hiBitsFlag +
        2 * _hb2Flag[_symbol(os)] +
        ((_runLength >> 26) & 0x20);
    return row * 64 + col;
  }

  /// Decodes one symbol (0–255) from [rc], or throws [PpmdError] on a corrupt
  /// stream (the C `-1`/`-2` returns).
  int decodeSymbol(PpmdRarRangeDecoder rc) {
    if (_numStats(_minContext) != 1) {
      var s = _stats(_minContext);
      final count = rc.getThreshold(_summFreq(_minContext));
      var hiCnt = _freq(s);
      if (count < hiCnt) {
        rc.decode(0, _freq(s));
        final symbol = _symbol(s);
        _update1_0(s);
        return symbol;
      }
      _prevSuccess = 0;
      var i = _numStats(_minContext) - 1;
      do {
        s += 6;
        hiCnt += _freq(s);
        if (hiCnt > count) {
          rc.decode(hiCnt - _freq(s), _freq(s));
          final symbol = _symbol(s);
          _update1(s);
          return symbol;
        }
      } while (--i != 0);
      if (count >= _summFreq(_minContext)) throw const PpmdError('range');
      _hiBitsFlag = _hb2Flag[_symbol(_foundState)];
      rc.decode(hiCnt, _summFreq(_minContext) - hiCnt);
      for (var j = 0; j < 256; j++) {
        _charMask[j] = -1;
      }
      _charMask[_symbol(s)] = 0;
      i = _numStats(_minContext) - 1;
      do {
        s -= 6;
        _charMask[_symbol(s)] = 0;
      } while (--i != 0);
    } else {
      final probIdx = _getBinSummIndex();
      final prob = _binSumm[probIdx];
      if (rc.decodeBit(prob) == 0) {
        _binSumm[probIdx] =
            (prob + (1 << _ppmdIntBits) - _getMean(prob)) & 0xFFFF;
        final os = _oneState(_minContext);
        final symbol = _symbol(os);
        _updateBin(os);
        return symbol;
      }
      final np = (prob - _getMean(prob)) & 0xFFFF;
      _binSumm[probIdx] = np;
      initEsc = _kExpEscape[np >> 10];
      for (var j = 0; j < 256; j++) {
        _charMask[j] = -1;
      }
      _charMask[_symbol(_oneState(_minContext))] = 0;
      _prevSuccess = 0;
    }

    for (;;) {
      final numMasked = _numStats(_minContext);
      do {
        _orderFall++;
        if (_suffix(_minContext) == 0) throw const PpmdError('no suffix');
        _minContext = _suffix(_minContext);
      } while (_numStats(_minContext) == numMasked);

      var hiCnt = 0;
      var s = _stats(_minContext);
      var i = 0;
      final num = _numStats(_minContext) - numMasked;
      do {
        final k = _charMask[_symbol(s)];
        hiCnt += _freq(s) & k;
        _ps[i] = s;
        s += 6;
        i -= k;
      } while (i != num);

      final escOut = _escScratch;
      final see = _makeEscFreq(numMasked, escOut);
      final freqSum = escOut[0] + hiCnt;
      final count = rc.getThreshold(freqSum);

      if (count < hiCnt) {
        var ppsIdx = 0;
        var acc = 0;
        while (true) {
          acc += _freq(_ps[ppsIdx]);
          if (acc > count) break;
          ppsIdx++;
        }
        s = _ps[ppsIdx];
        rc.decode(acc - _freq(s), _freq(s));
        _seeUpdate(see);
        final symbol = _symbol(s);
        _update2(s);
        return symbol;
      }
      if (count >= freqSum) throw const PpmdError('range');
      rc.decode(hiCnt, freqSum - hiCnt);
      if (see >= 0) _seeSumm[see] = (_seeSumm[see] + freqSum) & 0xFFFF;
      do {
        _charMask[_symbol(_ps[--i])] = 0;
      } while (i != 0);
    }
  }

  final List<int> _escScratch = [0];
}

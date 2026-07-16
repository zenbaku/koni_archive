/// Generic RarVM bytecode interpreter for RAR4 (v2.9/v3+) filter programs.
///
/// RAR's method-29 stream can carry a small compiled bytecode program (a
/// `read_filter` record) that the decoder runs over each filtered output
/// region. The four *standard* programs (delta, x86 E8/E8E9, RGB, audio) are
/// recognized by fingerprint and run by hand-written filters in
/// `rar4_filters.dart` for speed; this interpreter runs *any* program,
/// including non-standard ones from other tools; the case that was a typed
/// error before.
///
/// The VM is a little pseudo-x86: 8 registers, a 256 KiB byte address space,
/// carry/zero/sign flags, and ~40 opcodes with immediate / register /
/// register-indirect / base+index / direct operands. Clean-room per
/// `doc/rar-provenance.md`: structure and opcode/flag semantics are adapted
/// from the BSD-2-Clause Go `rardecode` `vm.go` (and the filter glue in its
/// `filters.go`); see `doc/references.md` and `NOTICE`. No unrar or GPL
/// source was consulted.
///
/// All arithmetic is masked to 32 bits so the result is byte-identical on the
/// VM, dart2js, and dart2wasm; the one multiply that could exceed 2^53 uses a
/// split-halves [_mul32].
library;

import 'dart:typed_data';

/// VM address space: 256 KiB plus a 4-byte slack so a little-endian 32-bit
/// read/write at the top mask address stays in bounds.
const int vmSize = 0x40000;

/// Address mask ([vmSize] − 1); every indirect access is `& vmMask`.
const int vmMask = vmSize - 1;

/// Start of the 8 KiB global-data block (matches `filters.go`).
const int vmGlobalAddr = 0x3C000;

/// Size of the global-data block.
const int vmGlobalSize = 0x2000;

/// Size of the fixed (system) part of the global block; user/static data
/// follows it.
const int vmFixedGlobalSize = 0x40;

const int _flagC = 1;
const int _flagZ = 2;
const int _flagS = 0x80000000;

/// Runaway guard: a program may run at most this many instructions.
const int _maxCommands = 25000000;

// Operand addressing modes.
const int _mImm = 0; // immediate constant
const int _mReg = 1; // register
const int _mRegInd = 2; // [register]
const int _mBaseIdx = 3; // [register + index]
const int _mDirect = 4; // [address]

// Powers of two 2^0..2^31, so shifts never use a >=32-bit native shift
// (unsafe on dart2js) and multiply-by-power stays exact. A plain List (not a
// 64-bit typed list, which dart2js cannot represent); every value is < 2^32,
// so it is exact on the web too.
final List<int> _pow2 = () {
  final t = List<int>.filled(32, 0);
  var v = 1;
  for (var i = 0; i < 32; i++) {
    t[i] = v;
    v *= 2;
  }
  return t;
}();

int _u32(int n) => n & 0xFFFFFFFF;

/// 32-bit multiply with wraparound, split into 16-bit halves so no
/// intermediate exceeds 2^53 (dart2js precision); `mul` is the only VM op
/// whose product can overflow.
int _mul32(int a, int b) {
  final aLo = a & 0xFFFF;
  final aHi = (a >>> 16) & 0xFFFF;
  final bLo = b & 0xFFFF;
  final bHi = (b >>> 16) & 0xFFFF;
  final lo = aLo * bLo; // < 2^32
  final mid =
      (aLo * bHi + aHi * bLo) % 0x10000; // low 16 bits of the cross term
  return (mid * 0x10000 + lo) % 0x100000000;
}

/// One decoded operand (immediate, register, or a memory reference).
class _Arg {
  _Arg(this.mode, this.value, [this.index = 0]);

  final int mode;
  int value; // immediate / register index / direct address / base register
  final int index; // base+index offset (mode [_mBaseIdx] only)
}

/// One decoded instruction.
class _Cmd {
  _Cmd(this.op, this.byteMode, this.a, this.b);

  final int op; // index into the opcode table
  final bool byteMode;
  final _Arg? a;
  final _Arg? b;
}

/// A compiled RarVM program: its instruction list plus any embedded static
/// data (appended after the global block in memory before each run).
class RarVmProgram {
  RarVmProgram._(this._commands, this.staticData);

  final List<_Cmd> _commands;

  /// Static data embedded in the program, copied into memory after the global
  /// block before each run (empty when the program carries none).
  final Uint8List staticData;

  /// Compiles a filter program. [code] is the full program buffer whose first
  /// byte is the XOR check (already verified by the caller); parsing starts at
  /// the next byte, mirroring `getV3Filter`.
  factory RarVmProgram.compile(Uint8List code) {
    final br = _VmBits(code, 8); // skip the XOR check byte
    Uint8List staticData = Uint8List(0);
    if (br.bits(1) != 0) {
      final n = br.rarUint32();
      if (n > 0x10000) {
        throw const FormatException('RAR4 VM static data too large');
      }
      staticData = Uint8List(n + 1); // note: n+1 bytes
      for (var i = 0; i < staticData.length; i++) {
        staticData[i] = br.byte();
      }
    }
    final commands = _readCommands(br);
    if (commands.isEmpty) {
      throw const FormatException('RAR4 VM program has no instructions');
    }
    return RarVmProgram._(commands, staticData);
  }
}

/// The generic RarVM. Runs a compiled [RarVmProgram] over the memory passed
/// to the constructor; the filter glue in `rar4_filters.dart` sets up the
/// registers, global block, and input region, and reads the output back.
class RarVm {
  /// Creates a VM over memory [m] (at least [vmSize] + 4 bytes) and the 8
  /// initial registers [r].
  RarVm(this.m, this.r)
    : assert(m.length >= vmSize + 4, 'VM memory too small'),
      assert(r.length == 8, 'VM has 8 registers');

  /// The VM's byte-addressable memory.
  final Uint8List m;

  /// The 8 general-purpose registers.
  final List<int> r;
  int _fl = 0;
  int _ip = 0;
  bool _ipMod = false;

  int _readLe32(int i) =>
      m[i] | (m[i + 1] << 8) | (m[i + 2] << 16) | (m[i + 3] << 24);

  void _writeLe32(int i, int v) {
    m[i] = v & 0xFF;
    m[i + 1] = (v >>> 8) & 0xFF;
    m[i + 2] = (v >>> 16) & 0xFF;
    m[i + 3] = (v >>> 24) & 0xFF;
  }

  int _get(_Arg op, bool bm) {
    switch (op.mode) {
      case _mImm:
        return op.value;
      case _mReg:
        return bm ? r[op.value] & 0xFF : r[op.value];
      case _mRegInd:
        final i = r[op.value] & vmMask;
        return bm ? m[i] : _readLe32(i);
      case _mBaseIdx:
        final i = _u32(r[op.value] + op.index) & vmMask;
        return bm ? m[i] : _readLe32(i);
      default: // _mDirect
        final i = op.value; // already masked at decode time
        return bm ? m[i] : _readLe32(i);
    }
  }

  void _set(_Arg op, bool bm, int n) {
    switch (op.mode) {
      case _mImm:
        return; // writing an immediate is a no-op (matches the reference)
      case _mReg:
        if (bm) {
          r[op.value] = (r[op.value] & 0xFFFFFF00) | (n & 0xFF);
        } else {
          r[op.value] = _u32(n);
        }
        return;
      case _mRegInd:
        final i = r[op.value] & vmMask;
        if (bm) {
          m[i] = n & 0xFF;
        } else {
          _writeLe32(i, n);
        }
        return;
      case _mBaseIdx:
        final i = _u32(r[op.value] + op.index) & vmMask;
        if (bm) {
          m[i] = n & 0xFF;
        } else {
          _writeLe32(i, n);
        }
        return;
      default: // _mDirect
        final i = op.value;
        if (bm) {
          m[i] = n & 0xFF;
        } else {
          _writeLe32(i, n);
        }
        return;
    }
  }

  void _setIp(int ip) {
    _ip = ip;
    _ipMod = true;
  }

  /// Runs [program] to completion (or the instruction-count guard).
  void execute(RarVmProgram program) {
    final commands = program._commands;
    _ip = 0;
    final n = commands.length;
    for (var count = 0; count < _maxCommands; count++) {
      final ip = _ip;
      if (ip >= n) return;
      _step(commands[ip]);
      if (_ipMod) {
        _ipMod = false;
      } else {
        _ip = ip + 1;
      }
    }
  }

  void _step(_Cmd c) {
    final bm = c.byteMode;
    final a = c.a;
    final b = c.b;
    switch (c.op) {
      case 0: // mov
        _set(a!, bm, _get(b!, bm));
      case 1: // cmp
        final v1 = _get(a!, bm);
        final rr = _u32(v1 - _get(b!, bm));
        _fl = rr == 0 ? _flagZ : (rr > v1 ? _flagC : 0) | (rr & _flagS);
      case 2: // add
        _add(a!, b!, bm);
      case 3: // sub
        _sub(a!, b!, bm);
      case 4: // jz
        if (_fl & _flagZ != 0) _setIp(_get(a!, false));
      case 5: // jnz
        if (_fl & _flagZ == 0) _setIp(_get(a!, false));
      case 6: // inc
        var rr = _get(a!, bm) + 1;
        if (bm) rr &= 0xFF;
        rr = _u32(rr);
        _set(a, bm, rr);
        _fl = rr == 0 ? _flagZ : rr & _flagS;
      case 7: // dec
        final rr = _u32(_get(a!, bm) - 1);
        _set(a, bm, rr);
        _fl = rr == 0 ? _flagZ : rr & _flagS;
      case 8: // jmp
        _setIp(_get(a!, false));
      case 9: // xor
        final rr = _get(a!, bm) ^ _get(b!, bm);
        _set(a, bm, rr);
        _fl = rr == 0 ? _flagZ : rr & _flagS;
      case 10: // and
        final rr = _get(a!, bm) & _get(b!, bm);
        _set(a, bm, rr);
        _fl = rr == 0 ? _flagZ : rr & _flagS;
      case 11: // or
        final rr = _get(a!, bm) | _get(b!, bm);
        _set(a, bm, rr);
        _fl = rr == 0 ? _flagZ : rr & _flagS;
      case 12: // test
        final rr = _get(a!, bm) & _get(b!, bm);
        _fl = rr == 0 ? _flagZ : rr & _flagS;
      case 13: // js
        if (_fl & _flagS != 0) _setIp(_get(a!, false));
      case 14: // jns
        if (_fl & _flagS == 0) _setIp(_get(a!, false));
      case 15: // jb
        if (_fl & _flagC != 0) _setIp(_get(a!, false));
      case 16: // jbe
        if (_fl & (_flagC | _flagZ) != 0) _setIp(_get(a!, false));
      case 17: // ja
        if (_fl & (_flagC | _flagZ) == 0) _setIp(_get(a!, false));
      case 18: // jae
        if (_fl & _flagC == 0) _setIp(_get(a!, false));
      case 19: // push
        r[7] = _u32(r[7] - 4);
        _writeLe32(r[7] & vmMask, _get(a!, false));
      case 20: // pop
        _set(a!, false, _readLe32(r[7] & vmMask));
        r[7] = _u32(r[7] + 4);
      case 21: // call
        r[7] = _u32(r[7] - 4);
        _writeLe32(r[7] & vmMask, _ip + 1);
        _setIp(_get(a!, false));
      case 22: // ret
        if (r[7] >= vmSize) {
          _setIp(0xFFFFFFFF);
        } else {
          _setIp(_readLe32(r[7] & vmMask));
          r[7] = _u32(r[7] + 4);
        }
      case 23: // not
        _set(a!, bm, _u32(~_get(a, bm)));
      case 24: // shl
        _shl(a!, b!, bm);
      case 25: // shr
        _shr(a!, b!, bm);
      case 26: // sar
        _sar(a!, b!, bm);
      case 27: // neg
        final rr = _u32(0 - _get(a!, bm));
        _set(a, bm, rr);
        _fl = rr == 0 ? _flagZ : (rr & _flagS) | _flagC;
      case 28: // pusha
        _pusha();
      case 29: // popa
        _popa();
      case 30: // pushf
        r[7] = _u32(r[7] - 4);
        _writeLe32(r[7] & vmMask, _fl);
      case 31: // popf
        _fl = _readLe32(r[7] & vmMask);
        r[7] = _u32(r[7] + 4);
      case 32: // movzx
        _set(a!, false, _get(b!, true));
      case 33: // movsx
        final byte = _get(b!, true);
        _set(a!, false, _u32((byte & 0x80) != 0 ? byte - 0x100 : byte));
      case 34: // xchg
        final v1 = _get(a!, bm);
        _set(a, bm, _get(b!, bm));
        _set(b, bm, v1);
      case 35: // mul
        _set(a!, bm, _mul32(_get(a, bm), _get(b!, bm)));
      case 36: // div
        final d = _get(b!, bm);
        if (d != 0) _set(a!, bm, _get(a, bm) ~/ d);
      case 37: // adc
        _adc(a!, b!, bm);
      case 38: // sbb
        _sbb(a!, b!, bm);
      case 39: // print
        break; // no-op (reference ignores it)
    }
  }

  void _add(_Arg a, _Arg b, bool bm) {
    final v1 = _get(a, bm);
    var rr = _u32(v1 + _get(b, bm));
    var signBit = _flagS;
    if (bm) {
      rr &= 0xFF;
      signBit = 0x80;
    }
    _fl = 0;
    if (rr < v1) _fl |= _flagC;
    if (rr == 0) {
      _fl |= _flagZ;
    } else if (rr & signBit != 0) {
      _fl |= _flagS;
    }
    _set(a, bm, rr);
  }

  void _sub(_Arg a, _Arg b, bool bm) {
    final v1 = _get(a, bm);
    final rr = _u32(v1 - _get(b, bm));
    _fl = rr == 0 ? _flagZ : (rr > v1 ? _flagC : 0) | (rr & _flagS);
    _set(a, bm, rr);
  }

  void _shl(_Arg a, _Arg b, bool bm) {
    final v1 = _get(a, bm);
    final v2 = _get(b, bm);
    int rr;
    var carry = 0;
    if (v2 == 0) {
      rr = v1;
    } else if (v2 >= 32) {
      rr = 0;
      // (v1 << (v2-1)) is 0 for v2-1 >= 32 too.
      if (v2 == 32) carry = (v1 & 1) != 0 ? _flagC : 0;
    } else {
      rr = _mul32(v1, _pow2[v2]);
      carry = (_mul32(v1, _pow2[v2 - 1]) & 0x80000000) != 0 ? _flagC : 0;
    }
    _set(a, bm, rr);
    _fl = (rr == 0 ? _flagZ : rr & _flagS) | carry;
  }

  void _shr(_Arg a, _Arg b, bool bm) {
    final v1 = _get(a, bm);
    final v2 = _get(b, bm);
    int rr;
    var carry = 0;
    if (v2 == 0) {
      rr = v1;
    } else if (v2 >= 32) {
      rr = 0;
      if (v2 == 32) carry = (v1 & 0x80000000) != 0 ? _flagC : 0;
    } else {
      rr = v1 >>> v2;
      carry = ((v1 >>> (v2 - 1)) & 1) != 0 ? _flagC : 0;
    }
    _set(a, bm, rr);
    _fl = (rr == 0 ? _flagZ : rr & _flagS) | carry;
  }

  void _sar(_Arg a, _Arg b, bool bm) {
    final v1 = _get(a, bm);
    final v2 = _get(b, bm);
    final neg = (v1 & 0x80000000) != 0;
    int rr;
    var carry = 0;
    if (v2 == 0) {
      rr = v1;
    } else if (v2 >= 32) {
      rr = neg ? 0xFFFFFFFF : 0;
      if (v2 == 32) carry = (v1 & 0x80000000) != 0 ? _flagC : 0;
    } else {
      rr = v1 >>> v2;
      if (neg) rr = _u32(rr | _u32(-_pow2[32 - v2]));
      carry = ((v1 >>> (v2 - 1)) & 1) != 0 ? _flagC : 0;
    }
    _set(a, bm, rr);
    _fl = (rr == 0 ? _flagZ : rr & _flagS) | carry;
  }

  void _adc(_Arg a, _Arg b, bool bm) {
    final v1 = _get(a, bm);
    final fc = _fl & _flagC;
    var rr = _u32(v1 + _get(b, bm) + fc);
    if (bm) rr &= 0xFF;
    _set(a, bm, rr);
    _fl = rr == 0 ? _flagZ : rr & _flagS;
    if (rr < v1 || (rr == v1 && fc != 0)) _fl |= _flagC;
  }

  void _sbb(_Arg a, _Arg b, bool bm) {
    final v1 = _get(a, bm);
    final fc = _fl & _flagC;
    var rr = _u32(v1 - _get(b, bm) - fc);
    if (bm) rr &= 0xFF;
    _set(a, bm, rr);
    _fl = rr == 0 ? _flagZ : rr & _flagS;
    if (rr > v1 || (rr == v1 && fc != 0)) _fl |= _flagC;
  }

  void _pusha() {
    var sp = r[7];
    for (var i = 0; i < 8; i++) {
      sp = _u32(sp - 4) & vmMask;
      _writeLe32(sp, r[i]);
    }
    r[7] = sp;
  }

  void _popa() {
    var sp = r[7];
    for (var i = 7; i >= 0; i--) {
      r[i] = _readLe32(sp & vmMask);
      sp = _u32(sp + 4);
    }
    r[7] = sp;
  }
}

// --- Bytecode decoding (readCommands / decodeArg / fixJumpOp). ---

/// The opcode table: (supports byte mode, operand count, is a jump). The order
/// is load-bearing; it is the opcode numbering the bytestream encodes.
const List<(bool, int, bool)> _ops = [
  (true, 2, false), // 0 mov
  (true, 2, false), // 1 cmp
  (true, 2, false), // 2 add
  (true, 2, false), // 3 sub
  (false, 1, true), // 4 jz
  (false, 1, true), // 5 jnz
  (true, 1, false), // 6 inc
  (true, 1, false), // 7 dec
  (false, 1, true), // 8 jmp
  (true, 2, false), // 9 xor
  (true, 2, false), // 10 and
  (true, 2, false), // 11 or
  (true, 2, false), // 12 test
  (false, 1, true), // 13 js
  (false, 1, true), // 14 jns
  (false, 1, true), // 15 jb
  (false, 1, true), // 16 jbe
  (false, 1, true), // 17 ja
  (false, 1, true), // 18 jae
  (false, 1, false), // 19 push
  (false, 1, false), // 20 pop
  (false, 1, true), // 21 call
  (false, 0, false), // 22 ret
  (true, 1, false), // 23 not
  (true, 2, false), // 24 shl
  (true, 2, false), // 25 shr
  (true, 2, false), // 26 sar
  (true, 1, false), // 27 neg
  (false, 0, false), // 28 pusha
  (false, 0, false), // 29 popa
  (false, 0, false), // 30 pushf
  (false, 0, false), // 31 popf
  (false, 2, false), // 32 movzx
  (false, 2, false), // 33 movsx
  (true, 2, false), // 34 xchg
  (true, 2, false), // 35 mul
  (true, 2, false), // 36 div
  (true, 2, false), // 37 adc
  (true, 2, false), // 38 sbb
  (false, 0, false), // 39 print
];

List<_Cmd> _readCommands(_VmBits br) {
  final cmds = <_Cmd>[];
  while (!br.eof) {
    var code = br.bits(4);
    if (br.eof) break;
    if (code & 0x08 != 0) {
      final n = br.bits(2);
      code = (code << 2 | n) - 24;
    }
    if (code < 0 || code >= _ops.length) {
      throw const FormatException('RAR4 VM invalid instruction');
    }
    final info = _ops[code];
    final supportsByte = info.$1;
    final nops = info.$2;
    final isJump = info.$3;

    var byteMode = false;
    if (supportsByte) {
      byteMode = br.bits(1) != 0;
    }
    if (br.eof) break;

    _Arg? a;
    _Arg? b;
    if (nops > 0) {
      a = _decodeArg(br, byteMode);
      if (nops == 2) {
        b = _decodeArg(br, byteMode);
      } else if (isJump) {
        a = _fixJumpOp(a, cmds.length);
      }
    }
    if (br.eof) break; // partial trailing instruction: drop it (EOF == done)
    cmds.add(_Cmd(code, byteMode, a, b));
  }
  return cmds;
}

_Arg _decodeArg(_VmBits br, bool byteMode) {
  if (br.bits(1) != 0) {
    return _Arg(_mReg, br.bits(3)); // register
  }
  if (br.bits(1) == 0) {
    // immediate
    if (byteMode) return _Arg(_mImm, br.bits(8));
    return _Arg(_mImm, br.rarUint32());
  }
  if (br.bits(1) == 0) {
    return _Arg(_mRegInd, br.bits(3)); // [register]
  }
  if (br.bits(1) == 0) {
    final reg = br.bits(3); // [register + index]
    return _Arg(_mBaseIdx, reg, br.rarUint32());
  }
  return _Arg(_mDirect, br.rarUint32() & vmMask); // [address]
}

/// Remaps a jump instruction's immediate target to an absolute command index
/// (the reference's `fixJumpOp`). Non-immediate targets pass through.
_Arg _fixJumpOp(_Arg op, int here) {
  if (op.mode != _mImm) return op;
  var n = op.value;
  if (n >= 256) return _Arg(_mImm, _u32(n - 256));
  if (n >= 136) {
    n -= 264;
  } else if (n >= 16) {
    n -= 8;
  } else if (n >= 8) {
    n -= 16;
  }
  return _Arg(_mImm, _u32(n + here));
}

/// MSB-first bit reader over a program buffer, with RAR's variable-length
/// number encoding (`readUint32`). A read past the end sets [eof] and yields
/// 0; the reference's EOF-terminates-the-program behavior.
class _VmBits {
  _VmBits(this._b, this._pos);

  final Uint8List _b;
  int _pos; // absolute bit position
  bool eof = false;

  int bits(int n) {
    if (_pos + n > _b.length * 8) {
      eof = true;
      return 0;
    }
    var value = 0;
    for (var k = 0; k < n; k++) {
      final byte = _b[_pos >> 3];
      final bit = (byte >> (7 - (_pos & 7))) & 1;
      value = value * 2 + bit; // MSB-first; avoids >=32-bit shifts (dart2js)
      _pos++;
    }
    return value;
  }

  int byte() => bits(8);

  /// RAR V3 variable-length number (`readUint32` / `membr_next_rarvm_number`).
  int rarUint32() {
    switch (bits(2)) {
      case 0:
        return bits(4);
      case 1:
        final v = bits(8);
        if (v >= 16) return v;
        return _u32(0xFFFFFF00 | (v << 4) | bits(4));
      case 2:
        return bits(16);
      default:
        return bits(32);
    }
  }
}

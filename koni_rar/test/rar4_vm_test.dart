// RarVM opcode coverage. The four standard filter programs (verified byte-exact
// through the VM in rar4_filters_test.dart) exercise most opcodes — including
// the precision-sensitive `mul`, `shl`, `shr`, `neg` — but not `sar`, `adc`,
// `sbb`, `div`, `xor`, `and`, `or`. This assembles a small straight-line
// program that does, and checks the results on dart2js/dart2wasm too (the VM's
// 32-bit arithmetic is where a web-int trap would hide). The remaining
// uncovered opcodes (`not`, `call`, `pushf`, `popf`, `print`) are structurally
// trivial or built from covered ones (push/pop/jmp).
library;

import 'dart:typed_data';

import 'package:koni_rar/src/rar4_vm.dart';
import 'package:test/test.dart';

// Opcode numbers (the bytestream's own numbering; see rar4_vm.dart `_ops`).
const _mov = 0;
const _add = 2;
const _jmp = 8;
const _xor = 9;
const _and = 10;
const _or = 11;
const _call = 21;
const _ret = 22;
const _sar = 26;
const _div = 36;
const _adc = 37;
const _sbb = 38;

/// Minimal MSB-first bit assembler for RarVM bytecode. Emits only the
/// `op reg, imm` form (all ops used here are 2-operand and byte-mode-capable,
/// so each carries a mode bit, set to 0 for full 32-bit ops).
class _Asm {
  final List<int> _bits = [];

  void _bit(int b) => _bits.add(b & 1);
  void _emit(int v, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _bit(v >> i);
    }
  }

  // RAR variable number as the always-valid 2-bit tag 3 + 32-bit value
  // (emitted as two 16-bit halves to avoid a 32-bit shift on the web).
  void _number(int v) {
    _emit(3, 2);
    _emit((v >>> 16) & 0xFFFF, 16);
    _emit(v & 0xFFFF, 16);
  }

  void _opcode(int op) {
    if (op < 8) {
      _emit(op, 4);
    } else {
      final e = op + 24;
      _emit(e >> 2, 4);
      _emit(e & 3, 2);
    }
  }

  /// `op reg, imm` (full 32-bit mode).
  void rri(int op, int reg, int imm) {
    _opcode(op);
    _bit(0); // byte-mode bit: full 32-bit
    _bit(1); // operand 0: register
    _emit(reg, 3);
    _bit(0); // operand 1: not register
    _bit(0); // ...immediate
    _number(imm);
  }

  /// 1-operand jump/call to an absolute command index. Jumps carry no
  /// byte-mode bit; the target is encoded as `index + 256` so `fixJumpOp`'s
  /// `>= 256` branch maps it straight through to the index.
  void jump(int op, int targetIndex) {
    _opcode(op);
    _bit(0); // operand: not register
    _bit(0); // ...immediate
    _number(targetIndex + 256);
  }

  /// 0-operand op (e.g. ret).
  void nullary(int op) => _opcode(op);

  Uint8List build() {
    // The program bitstream starts with a static-data-present flag (0 here);
    // byte 0 is the XOR check byte, which compile() skips.
    final all = <int>[0, ..._bits];
    final out = Uint8List(1 + ((all.length + 7) ~/ 8));
    for (var i = 0; i < all.length; i++) {
      if (all[i] != 0) out[1 + (i >> 3)] |= 1 << (7 - (i & 7));
    }
    return out;
  }
}

void main() {
  test('RarVM sar/adc/sbb/div/xor/and/or are correct on this platform', () {
    final asm =
        _Asm()
          // sar: arithmetic shift of a negative value keeps the sign bits.
          ..rri(_mov, 0, 0x87654321)
          ..rri(_sar, 0, 4) // -> 0xF8765432
          // adc: add-with-carry; the preceding add overflows to set carry,
          // and mov preserves flags.
          ..rri(_mov, 1, 0xFFFFFFFF)
          ..rri(_add, 1, 1) // r1 = 0, carry = 1
          ..rri(_mov, 1, 0x10) // flags preserved
          ..rri(_adc, 1, 0x20) // -> 0x31
          // div: unsigned integer division.
          ..rri(_mov, 2, 100)
          ..rri(_div, 2, 7) // -> 14
          // xor.
          ..rri(_mov, 3, 0xF0F0F0F0)
          ..rri(_xor, 3, 0x0FF00FF0) // -> 0xFF00FF00
          // sbb: subtract-with-borrow; add sets carry, mov preserves it.
          ..rri(_mov, 4, 0xFFFFFFFF)
          ..rri(_add, 4, 1) // r4 = 0, carry = 1
          ..rri(_mov, 4, 0x50)
          ..rri(_sbb, 4, 0x10) // -> 0x50 - 0x10 - 1 = 0x3F
          // and / or.
          ..rri(_mov, 5, 0xFF00FF00)
          ..rri(_and, 5, 0x0F0F0F0F) // -> 0x0F000F00
          ..rri(_mov, 6, 0xF0000000)
          ..rri(_or, 6, 0x0000000F); // -> 0xF000000F

    final program = RarVmProgram.compile(asm.build());
    final r = List<int>.filled(8, 0);
    RarVm(Uint8List(vmSize + 4), r).execute(program);

    expect(r[0], 0xF8765432, reason: 'sar');
    expect(r[1], 0x31, reason: 'adc');
    expect(r[2], 14, reason: 'div');
    expect(r[3], 0xFF00FF00, reason: 'xor');
    expect(r[4], 0x3F, reason: 'sbb');
    expect(r[5], 0x0F000F00, reason: 'and');
    expect(r[6], 0xF000000F, reason: 'or');
  });

  test('RarVM call/ret round-trip on this platform', () {
    // The standard programs exercise `ret`'s terminate branch but never a
    // `call`→`ret` round-trip (push the return address, ret pops it). Real
    // hand-written filters use calls, so verify it directly.
    //   0: call 3     (push 1, jump to the subroutine)
    //   1: mov r0, A  (runs after ret returns here)
    //   2: jmp 5      (skip the subroutine)
    //   3: mov r1, B  (subroutine body)
    //   4: ret        (pop 1, jump back to 1)
    //   5: mov r2, C
    final asm =
        _Asm()
          ..jump(_call, 3)
          ..rri(_mov, 0, 0xAAAA)
          ..jump(_jmp, 5)
          ..rri(_mov, 1, 0xBBBB)
          ..nullary(_ret)
          ..rri(_mov, 2, 0xCCCC);

    final program = RarVmProgram.compile(asm.build());
    // r7 is the stack pointer; it must start at the top of memory (as the
    // filter setup does) or `ret` would take its terminate branch.
    final r = List<int>.filled(8, 0)..[7] = vmSize;
    RarVm(Uint8List(vmSize + 4), r).execute(program);

    // r0 and r2 both being set proves control returned from the call (if ret
    // had terminated instead, neither would run); r1 proves the body ran.
    expect(r[0], 0xAAAA, reason: 'code after the call ran (ret returned)');
    expect(r[1], 0xBBBB, reason: 'subroutine body ran');
    expect(r[2], 0xCCCC, reason: 'reached the end');
  });
}

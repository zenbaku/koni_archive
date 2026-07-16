/// RAR4 (v2.9/v3+) RarVM filter support.
///
/// RAR's compressor auto-applies a handful of *standard* filters (delta, x86
/// E8/E8E9, RGB, audio) whose bytecode is a fixed program the decoder
/// recognizes by fingerprint (program length + CRC-32) and runs natively,
/// exactly as libarchive does, for speed. *Any other* program is run by the
/// generic [RarVm] interpreter (`rar4_vm.dart`), so a non-standard filter from
/// another tool decodes too (it used to be a typed error).
///
/// Clean-room per `doc/rar-provenance.md`. The filter-record layout and the
/// native filter algorithms are adapted from libarchive's BSD
/// `archive_read_support_format_rar.c` (`read_filter` / `parse_filter` /
/// `compile_program` / `execute_filter_*`; Tim Kientzle, Andres Mejia; see
/// `doc/references.md` and `NOTICE`); the generic VM + its global-block wiring
/// from the BSD Go `rardecode` (`vm.go` / `filters.go`). No unrar or GPL source
/// was consulted. The delta and E8/E8E9 arithmetic mirrors the RAR5 filters
/// already in this package (`rar5_decoder.dart`), which are byte-verified
/// across VM/dart2js/dart2wasm.
///
/// Malformed input throws [FormatException]; the reader maps a message
/// containing "not supported" to `UnsupportedFeatureException` and anything
/// else to `CorruptArchiveException`.
library;

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' show Crc32;

import 'rar4_vm.dart';

/// Test seam: when true, even a *standard* filter program is run through the
/// generic [RarVm] instead of its native fast path, so the VM is verified
/// byte-exact against the existing standard-filter fixtures (which are already
/// CRC-checked against `unrar`). Never set outside tests.
bool debugForceRar4Vm = false;

// VM address space constants (libarchive names).
const int _vmMemorySize = 0x40000; // VM_MEMORY_SIZE
const int _programWorkSize = 0x3C000; // PROGRAM_WORK_SIZE
const int _programGlobalSize = 0x2000; // PROGRAM_GLOBAL_SIZE
const int _programSystemGlobalSize = 0x40; // PROGRAM_SYSTEM_GLOBAL_SIZE
const int _programUserGlobalSize =
    _programGlobalSize - _programSystemGlobalSize;
const int _programSystemGlobalAddress = _programWorkSize;

// Standard-filter kinds.
const int _fltDelta = 0;
const int _fltE8 = 1;
const int _fltE8E9 = 2;
const int _fltRgb = 3;
const int _fltAudio = 4;
const int _fltVm = 5; // a generic (non-standard) VM program

/// A registered VM program, keyed by its fingerprint and resolved to a
/// standard-filter kind at compile time, or (kind [_fltVm]) a compiled generic
/// program plus its cross-invocation persistent global data.
class _Rar4Program {
  _Rar4Program(this.kind, [this.vm]);

  final int kind;
  final RarVmProgram? vm;
  int oldFilterLength = 0;
  int usageCount = 0;

  /// Global data a generic program asked to carry into its next invocation
  /// (via the global block's saved-size slot); null until it does.
  Uint8List? persistentGlobal;
}

/// One scheduled filter invocation over an output region.
class _Rar4Filter {
  _Rar4Filter(
    this.prog,
    this.registers,
    this.blockStart,
    this.blockLength,
    this.globalData,
  );

  final _Rar4Program prog;
  final List<int> registers; // 8 VM registers at invocation time
  final int blockStart; // absolute position in the LZ output
  final int blockLength;

  /// The record's user global data (filter flag `0x08`), fed to a generic VM
  /// program; null for the standard filters, which ignore it.
  final Uint8List? globalData;

  int get kind => prog.kind;
}

/// MSB-first bit reader over a filter-code byte buffer (libarchive's
/// `memory_bit_reader`). A read past the end sets [atEof] and yields 0; the
/// same failure mode the reference relies on.
class _MemBits {
  _MemBits(this._bytes);

  final Uint8List _bytes;
  int _pos = 0; // absolute bit position
  bool atEof = false;

  int read(int n) {
    if (_pos + n > _bytes.length * 8) {
      atEof = true;
      return 0;
    }
    var value = 0;
    for (var k = 0; k < n; k++) {
      final byte = _bytes[_pos >> 3];
      final bit = (byte >> (7 - (_pos & 7))) & 1;
      value = value * 2 + bit; // MSB-first; avoids >=32-bit shifts (dart2js)
      _pos++;
    }
    return value;
  }

  /// RAR VM variable-length number (`membr_next_rarvm_number`).
  int nextNumber() {
    switch (read(2)) {
      case 0:
        return read(4);
      case 1:
        final v = read(8);
        if (v >= 16) return v;
        return (0xFFFFFF00 | (v << 4) | read(4)) & 0xFFFFFFFF;
      case 2:
        return read(16);
      default:
        return read(32);
    }
  }
}

/// Collects the RAR4 filters read from a file's bitstream and applies them,
/// in place, over the decoded output. Reused across files by [reset].
class Rar4Filters {
  final List<_Rar4Program> _progs = [];
  final List<_Rar4Filter> _stack = [];
  int _lastFilterNum = 0;

  /// Whether any filter has been scheduled for the current file.
  bool get isNotEmpty => _stack.isNotEmpty;

  /// Clears all state for a fresh file.
  void reset() {
    _progs.clear();
    _stack.clear();
    _lastFilterNum = 0;
  }

  /// Parses one filter record (`parse_filter`). [code] is the already-read
  /// filter-code buffer; [lzssPosition] is the current absolute output
  /// position, so the block start lands at the right place.
  void parse(Uint8List code, int flags, int lzssPosition) {
    final br = _MemBits(code);
    final numprogs = _progs.length;

    int num;
    if ((flags & 0x80) != 0) {
      num = br.nextNumber();
      if (num == 0) {
        // A new program set. Reset the program dictionary but keep any
        // filters already scheduled for earlier regions (we apply the whole
        // file's filters at the end, unlike libarchive's streaming model).
        _progs.clear();
      } else {
        num--;
      }
      if (num > numprogs) {
        throw const FormatException('RAR4 filter references unknown program');
      }
      _lastFilterNum = num;
    } else {
      num = _lastFilterNum;
    }

    _Rar4Program? prog = num < _progs.length ? _progs[num] : null;
    if (prog != null) prog.usageCount++;

    var blockStart = br.nextNumber() + lzssPosition;
    if ((flags & 0x40) != 0) blockStart += 258;

    final int blockLength;
    if ((flags & 0x20) != 0) {
      blockLength = br.nextNumber();
    } else {
      blockLength = prog?.oldFilterLength ?? 0;
    }

    final registers = List<int>.filled(8, 0);
    registers[3] = _programSystemGlobalAddress;
    registers[4] = blockLength;
    registers[5] = prog?.usageCount ?? 0;
    registers[7] = _vmMemorySize;

    if ((flags & 0x10) != 0) {
      final mask = br.read(7);
      for (var i = 0; i < 7; i++) {
        if ((mask & (1 << i)) != 0) registers[i] = br.nextNumber();
      }
    }

    if (prog == null) {
      final len = br.nextNumber();
      if (len == 0 || len > 0x10000) {
        throw const FormatException('RAR4 filter program length out of range');
      }
      final bytecode = Uint8List(len);
      for (var i = 0; i < len; i++) {
        bytecode[i] = br.read(8);
      }
      prog = _compile(bytecode);
      _progs.add(prog);
    }
    prog.oldFilterLength = blockLength;

    // User global data (flag 0x08) feeds an interpreted VM program; the
    // standard filters ignore it. Read exactly the declared bytes either way
    // so a chained record that reuses this program still lines up.
    Uint8List? globalData;
    if ((flags & 0x08) != 0) {
      final globalLen = br.nextNumber();
      if (globalLen > _programUserGlobalSize) {
        throw const FormatException('RAR4 filter global data too large');
      }
      globalData = Uint8List(globalLen);
      for (var i = 0; i < globalLen; i++) {
        globalData[i] = br.read(8);
      }
    }

    if (br.atEof) {
      throw const FormatException('truncated RAR4 filter record');
    }

    _stack.add(
      _Rar4Filter(prog, registers, blockStart, blockLength, globalData),
    );
  }

  /// Compiles a program buffer: verifies its XOR check byte, then resolves the
  /// fingerprint (length + CRC-32) to a standard filter's native fast path, or
  /// (any other program) compiles it for the generic [RarVm].
  _Rar4Program _compile(Uint8List code) {
    var xor = 0;
    for (var i = 1; i < code.length; i++) {
      xor ^= code[i];
    }
    if (code.isEmpty || xor != code[0]) {
      throw const FormatException('corrupt RAR4 filter program');
    }
    final kind = _standardKind(Crc32.compute(code), code.length);
    if (kind >= 0 && !debugForceRar4Vm) {
      return _Rar4Program(kind); // native fast path
    }
    // A non-standard program (or the forced-VM test path): run it on the VM.
    return _Rar4Program(_fltVm, RarVmProgram.compile(code));
  }

  /// Standard-filter fingerprints (`length`, `crc32`) as recognized by
  /// libarchive's `execute_filter`. Split into two comparisons to stay
  /// dart2js/dart2wasm-safe (no 64-bit fingerprint literal).
  static int _standardKind(int crc, int len) {
    if (len == 29 && crc == 0x0E06077D) return _fltDelta;
    if (len == 53 && crc == 0xAD576887) return _fltE8;
    if (len == 57 && crc == 0x3CD7E57E) return _fltE8E9;
    if (len == 149 && crc == 0x1C2C5DC8) return _fltRgb;
    if (len == 216 && crc == 0xBC85E701) return _fltAudio;
    return -1;
  }

  /// Applies every scheduled filter in place over [output]. The file occupies
  /// `[fileBase, fileEnd)`; filter positions are absolute in that space.
  void apply(Uint8List output, int fileBase, int fileEnd) {
    if (_stack.isEmpty) return;
    final mem = Uint8List(_vmMemorySize + 4); // VM scratch: src‖dst
    var i = 0;
    while (i < _stack.length) {
      final primary = _stack[i];
      final start = primary.blockStart;
      final blockLength = primary.blockLength;
      if (start < fileBase ||
          blockLength < 0 ||
          start + blockLength > fileEnd ||
          blockLength > _vmMemorySize) {
        throw const FormatException('RAR4 filter region out of range');
      }
      final pos = start - fileBase; // file-relative offset for E8/E8E9

      _loadRegion(mem, output, start, blockLength);
      var result = _execute(primary, mem, pos);
      var lastAddress = result.$1;
      var lastLength = result.$2;
      i++;

      // Chain: a following filter over the exact same region consumes the
      // previous filter's output rather than the raw window.
      while (i < _stack.length &&
          _stack[i].blockStart == start &&
          _stack[i].blockLength == lastLength) {
        mem.setRange(0, lastLength, mem, lastAddress);
        result = _execute(_stack[i], mem, pos);
        lastAddress = result.$1;
        lastLength = result.$2;
        i++;
      }

      if (start + lastLength > fileEnd) {
        throw const FormatException('RAR4 filter output out of range');
      }
      output.setRange(start, start + lastLength, mem, lastAddress);
    }
    _stack.clear();
  }

  /// Zero-fills the working range (calloc semantics) and copies the raw
  /// region into the VM's source window `mem[0..length)`.
  void _loadRegion(Uint8List mem, Uint8List output, int start, int length) {
    final clearEnd = 2 * length + 4;
    mem.fillRange(0, clearEnd < mem.length ? clearEnd : mem.length, 0);
    mem.setRange(0, length, output, start);
  }

  /// Runs one filter, returning `(address, length)` of the result inside
  /// [mem]. Standard kinds use their native implementation; a generic program
  /// runs on the [RarVm].
  (int, int) _execute(_Rar4Filter f, Uint8List mem, int pos) {
    switch (f.kind) {
      case _fltDelta:
        return _delta(f, mem);
      case _fltE8:
        return _e8(f, mem, pos, false);
      case _fltE8E9:
        return _e8(f, mem, pos, true);
      case _fltRgb:
        return _rgb(f, mem);
      case _fltAudio:
        return _audio(f, mem);
      case _fltVm:
        return _executeVm(f, mem, pos);
      default:
        throw const FormatException('RAR4 filter is not supported');
    }
  }

  /// Runs a generic VM program. Input is `mem[0..blockLength)` (what [apply]
  /// loaded or chained there); the program runs in a *fresh* zeroed VM memory
  /// (so its globals and stack never see a previous filter's leftovers), and
  /// its output region (reported through the global block) is copied back to
  /// `mem[0..length)`, so chaining sees it at address 0.
  (int, int) _executeVm(_Rar4Filter f, Uint8List mem, int pos) {
    final program = f.prog.vm!;
    final blockLength = f.blockLength;
    if (blockLength < 0 || blockLength > vmGlobalAddr) {
      throw const FormatException('RAR4 VM filter block length out of range');
    }
    final vmMem = Uint8List(vmSize + 4);
    vmMem.setRange(0, blockLength, mem);

    // Registers: the record's parsed set (r3=global addr, r4=len, r5=usage,
    // r7=vmSize, plus any overrides). r6 becomes the block's file offset, but
    // only *after* the fixed global block is written, matching filters.go,
    // where global slot 6 holds the pre-offset r6 (override or 0), not the
    // offset (which lives only in the register and at vg+0x24).
    final regs = List<int>.of(f.registers);

    final vg = vmGlobalAddr;
    for (var i = 0; i < 7; i++) {
      _writeLe32Vm(vmMem, vg + i * 4, regs[i]);
    }
    _writeLe32Vm(vmMem, vg + 0x1C, blockLength);
    _writeLe32Vm(vmMem, vg + 0x24, pos & 0xFFFFFFFF); // offset as u64, hi = 0
    _writeLe32Vm(vmMem, vg + 0x2C, f.registers[5]); // usage count

    regs[6] = pos & 0xFFFFFFFF; // r6 = file offset, register-only

    // User global data (persistent from a prior run if present, else the
    // record's), then the program's embedded static data.
    final userGlobal = f.prog.persistentGlobal ?? f.globalData;
    var n = 0;
    if (userGlobal != null && userGlobal.isNotEmpty) {
      n = userGlobal.length;
      if (n > _programUserGlobalSize) n = _programUserGlobalSize;
      vmMem.setRange(
        vg + vmFixedGlobalSize,
        vg + vmFixedGlobalSize + n,
        userGlobal,
      );
    }
    final stat = program.staticData;
    if (stat.isNotEmpty) {
      var sn = stat.length;
      if (vmFixedGlobalSize + n + sn > vmGlobalSize) {
        sn = vmGlobalSize - vmFixedGlobalSize - n;
      }
      if (sn > 0) {
        vmMem.setRange(
          vg + vmFixedGlobalSize + n,
          vg + vmFixedGlobalSize + n + sn,
          stat,
        );
      }
    }

    // registers[5]/vg[0x2c] already hold this invocation's usage count (set at
    // parse time, matching the reference's per-execute counter).
    RarVm(vmMem, regs).execute(program);

    // Persist global data the program asked to keep for its next invocation.
    var globalSize = _readLe32Vm(vmMem, vg + 0x30) & 0xFFFFFFFF;
    if (globalSize > 0) {
      if (globalSize > vmGlobalSize - vmFixedGlobalSize) {
        globalSize = vmGlobalSize - vmFixedGlobalSize;
      }
      f.prog.persistentGlobal = Uint8List.sublistView(
        vmMem,
        vg + vmFixedGlobalSize,
        vg + vmFixedGlobalSize + globalSize,
      );
    }

    // Output region reported by the program.
    final length = _readLe32Vm(vmMem, vg + 0x1C) & vmMask;
    final start = _readLe32Vm(vmMem, vg + 0x20) & vmMask;
    if (start + length > vmSize) {
      throw const FormatException('RAR4 VM filter output out of range');
    }
    mem.setRange(0, length, vmMem, start);
    return (0, length);
  }

  static int _readLe32Vm(Uint8List m, int i) =>
      m[i] | (m[i + 1] << 8) | (m[i + 2] << 16) | (m[i + 3] << 24);

  static void _writeLe32Vm(Uint8List m, int i, int v) {
    m[i] = v & 0xFF;
    m[i + 1] = (v >>> 8) & 0xFF;
    m[i + 2] = (v >>> 16) & 0xFF;
    m[i + 3] = (v >>> 24) & 0xFF;
  }

  // --- Standard filters (adapted from libarchive execute_filter_*). ---

  /// Byte-wise delta over `numchannels` interleaved channels. Reads
  /// `mem[0..length)`, writes de-delta'd bytes to `mem[length..2*length)`.
  static (int, int) _delta(_Rar4Filter f, Uint8List mem) {
    final length = f.registers[4];
    final numchannels = f.registers[0];
    if (length > _programWorkSize ~/ 2) {
      throw const FormatException('RAR4 delta filter length out of range');
    }
    if (numchannels < 1 || numchannels > length) {
      throw const FormatException('RAR4 delta filter channel count invalid');
    }
    final dst = length;
    var src = 0;
    for (var ch = 0; ch < numchannels; ch++) {
      var lastByte = 0;
      for (var idx = ch; idx < length; idx += numchannels) {
        if (src >= length) {
          throw const FormatException('RAR4 delta filter overrun');
        }
        lastByte = (lastByte - mem[src]) & 0xFF;
        src++;
        mem[dst + idx] = lastByte;
      }
    }
    return (length, length);
  }

  /// x86 relative→absolute CALL/JMP rewrite (mirrors RAR5 `_e8e9`). Works in
  /// place at `mem[0..length)`.
  static (int, int) _e8(_Rar4Filter f, Uint8List mem, int pos, bool e9also) {
    final length = f.registers[4];
    const fileSize = 0x1000000;
    if (length > _programWorkSize || length <= 4) {
      throw const FormatException('RAR4 e8 filter length out of range');
    }
    for (var i = 0; i + 4 < length;) {
      final b = mem[i++];
      if (b == 0xE8 || (e9also && b == 0xE9)) {
        final offset = (i + pos) % fileSize;
        var addr =
            mem[i] |
            (mem[i + 1] << 8) |
            (mem[i + 2] << 16) |
            (mem[i + 3] << 24);
        addr &= 0xFFFFFFFF;
        if ((addr & 0x80000000) != 0) {
          if (((addr + offset) & 0x80000000) == 0) {
            _writeLe32(mem, i, addr + fileSize);
          }
        } else {
          if (((addr - fileSize) & 0x80000000) != 0) {
            _writeLe32(mem, i, (addr - offset) & 0xFFFFFFFF);
          }
        }
        i += 4;
      }
    }
    return (0, length);
  }

  /// 24-bit RGB delta with channel prediction. Reads `mem[0..length)`, writes
  /// to `mem[length..2*length)`.
  static (int, int) _rgb(_Rar4Filter f, Uint8List mem) {
    final length = f.registers[4];
    final stride = f.registers[0];
    final byteOffset = f.registers[1];
    if (length > _programWorkSize ~/ 2 ||
        stride < 1 ||
        stride > length ||
        length < 3 ||
        byteOffset > 2) {
      throw const FormatException('RAR4 rgb filter parameters invalid');
    }
    final dst = length;
    var src = 0;
    for (var i = 0; i < 3; i++) {
      var byte = 0;
      var prev = dst + i - stride;
      for (var j = i; j < length; j += 3) {
        if (src >= length) {
          throw const FormatException('RAR4 rgb filter overrun');
        }
        if (prev >= dst) {
          final p0 = mem[prev];
          final p3 = mem[prev + 3];
          final delta1 = (p3 - p0).abs();
          final delta2 = (byte - p0).abs();
          final delta3 = (p3 - p0 + byte - p0).abs();
          if (delta1 > delta2 || delta1 > delta3) {
            byte = delta2 <= delta3 ? p3 : p0;
          }
        }
        byte = (byte - mem[src]) & 0xFF;
        src++;
        mem[dst + j] = byte;
        prev += 3;
      }
    }
    for (var i = byteOffset; i + 2 < length; i += 3) {
      mem[dst + i] = (mem[dst + i] + mem[dst + i + 1]) & 0xFF;
      mem[dst + i + 2] = (mem[dst + i + 2] + mem[dst + i + 1]) & 0xFF;
    }
    return (length, length);
  }

  /// Adaptive audio predictor. Reads `mem[0..length)`, writes to
  /// `mem[length..2*length)`.
  static (int, int) _audio(_Rar4Filter f, Uint8List mem) {
    final length = f.registers[4];
    final numchannels = f.registers[0];
    if (length > _programWorkSize ~/ 2) {
      throw const FormatException('RAR4 audio filter length out of range');
    }
    if (numchannels < 1 || numchannels > length) {
      throw const FormatException('RAR4 audio filter channel count invalid');
    }
    final dst = length;
    var src = 0;
    for (var ch = 0; ch < numchannels; ch++) {
      final weight = List<int>.filled(3, 0);
      final delta = List<int>.filled(3, 0);
      final error = List<int>.filled(7, 0);
      var lastDelta = 0;
      var lastByte = 0;
      var count = 0;
      for (var j = ch; j < length; j += numchannels) {
        if (src >= length) {
          throw const FormatException('RAR4 audio filter overrun');
        }
        final d = _toInt8(mem[src]);
        src++;
        delta[2] = delta[1];
        delta[1] = lastDelta - delta[0];
        delta[0] = lastDelta;
        final predicted =
            ((8 * lastByte +
                    weight[0] * delta[0] +
                    weight[1] * delta[1] +
                    weight[2] * delta[2]) >>
                3) &
            0xFF;
        final byte = (predicted - d) & 0xFF;
        final predError = d * 8;
        error[0] += predError.abs();
        error[1] += (predError - delta[0]).abs();
        error[2] += (predError + delta[0]).abs();
        error[3] += (predError - delta[1]).abs();
        error[4] += (predError + delta[1]).abs();
        error[5] += (predError - delta[2]).abs();
        error[6] += (predError + delta[2]).abs();
        lastDelta = _toInt8((byte - lastByte) & 0xFF);
        lastByte = byte;
        mem[dst + j] = byte;
        if ((count++ & 0x1F) == 0) {
          var idx = 0;
          for (var k = 1; k < 7; k++) {
            if (error[k] < error[idx]) idx = k;
          }
          error.fillRange(0, 7, 0);
          switch (idx) {
            case 1:
              if (weight[0] >= -16) weight[0]--;
            case 2:
              if (weight[0] < 16) weight[0]++;
            case 3:
              if (weight[1] >= -16) weight[1]--;
            case 4:
              if (weight[1] < 16) weight[1]++;
            case 5:
              if (weight[2] >= -16) weight[2]--;
            case 6:
              if (weight[2] < 16) weight[2]++;
          }
        }
      }
    }
    return (length, length);
  }

  static int _toInt8(int b) => (b & 0x80) != 0 ? b - 0x100 : b;

  static void _writeLe32(Uint8List data, int at, int value) {
    data[at] = value & 0xFF;
    data[at + 1] = (value >> 8) & 0xFF;
    data[at + 2] = (value >> 16) & 0xFF;
    data[at + 3] = (value >> 24) & 0xFF;
  }
}

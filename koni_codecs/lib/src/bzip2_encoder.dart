/// bzip2 compression (Julian Seward's format). The encode direction of
/// `Bzip2Decoder`: RLE1 → forward Burrows–Wheeler transform → move-to-front →
/// RLE2 → Huffman → MSB-first bitstream, wrapped in the `BZh` stream framing.
///
/// This is a correctness-first encoder: it uses a single Huffman table per
/// block (pointed to by the two required groups) rather than bzip2's 2–6-table
/// iterative optimization, so the ratio is a little below `bzip2`'s while the
/// output stays fully `bzip2 -d`-decodable. The forward BWT is a
/// prefix-doubling suffix sort over the block's cyclic rotations.
library;

import 'dart:typed_data';

/// One-shot bzip2 compressor.
final class Bzip2Encoder {
  /// Creates an encoder. [blockSize100k] (1–9) sets the block size in units of
  /// 100 000 bytes, matching `bzip2 -1`..`-9`; 9 is `bzip2`'s default.
  Bzip2Encoder({this.blockSize100k = 9}) {
    if (blockSize100k < 1 || blockSize100k > 9) {
      throw ArgumentError.value(blockSize100k, 'blockSize100k', 'must be 1..9');
    }
  }

  /// Block size in 100 KiB units (1–9).
  final int blockSize100k;

  /// Compresses [data] into a complete `.bz2` stream.
  Uint8List encode(Uint8List data) {
    final w = _BitWriter();
    // Stream header: "BZh" + level digit.
    w.writeBits(0x42, 8);
    w.writeBits(0x5A, 8);
    w.writeBits(0x68, 8);
    w.writeBits(0x30 + blockSize100k, 8);

    // Each block's BWT input (post-RLE1) must fit blockSize100k*100000; RLE1
    // expands by at most 5/4 (runs of exactly 4), so cap the original chunk at
    // 4/5 of the limit.
    final limit = blockSize100k * 100000;
    final origChunk = (limit * 4) ~/ 5;

    var combinedCrc = 0;
    var pos = 0;
    if (data.isEmpty) {
      // Still a valid stream: no blocks, just the end marker + CRC 0.
      _writeStreamEnd(w, 0);
      return w.takeBytes();
    }
    while (pos < data.length) {
      final end = pos + origChunk < data.length ? pos + origChunk : data.length;
      final block = Uint8List.sublistView(data, pos, end);
      final crc = _bzCrc(block);
      combinedCrc = (((combinedCrc << 1) | (combinedCrc >>> 31)) ^ crc) &
          0xFFFFFFFF;
      _writeBlock(w, block, crc);
      pos = end;
    }
    _writeStreamEnd(w, combinedCrc);
    return w.takeBytes();
  }

  void _writeStreamEnd(_BitWriter w, int combinedCrc) {
    // End-of-stream magic 0x177245385090, combined CRC, byte-align.
    w.writeBits(0x177245, 24);
    w.writeBits(0x385090, 24);
    w.writeBits(combinedCrc, 32);
    w.finish();
  }

  void _writeBlock(_BitWriter w, Uint8List block, int crc) {
    final rle1 = _rle1(block);
    final bwt = _bwt(rle1);
    final last = bwt.last;
    final origPtr = bwt.origPtr;

    // --- symbol map ---
    final inUse = List<bool>.filled(256, false);
    for (final b in last) {
      inUse[b] = true;
    }
    final seqToUnseq = <int>[];
    for (var i = 0; i < 256; i++) {
      if (inUse[i]) seqToUnseq.add(i);
    }
    final nInUse = seqToUnseq.length;
    final eob = nInUse + 1;
    final alphaSize = nInUse + 2;

    // --- MTF + RLE2 ---
    final symbols = _mtfRle2(last, seqToUnseq, eob);

    // --- Huffman table (single, shared by the two required groups) ---
    final freqs = Uint32List(alphaSize);
    for (final s in symbols) {
      freqs[s]++;
    }
    final lengths = _makeCodeLengths(freqs, alphaSize, 20);
    final codes = _assignCodes(lengths, alphaSize);

    // --- block header ---
    w.writeBits(0x314159, 24);
    w.writeBits(0x265359, 24);
    w.writeBits(crc, 32);
    w.writeBits(0, 1); // not randomized
    w.writeBits(origPtr, 24);

    // symbol map: 16-bit range mask, then a 16-bit mask per used range.
    var inUse16 = 0;
    for (var i = 0; i < 16; i++) {
      var any = false;
      for (var j = 0; j < 16; j++) {
        if (inUse[i * 16 + j]) any = true;
      }
      if (any) inUse16 |= 0x8000 >> i;
    }
    w.writeBits(inUse16, 16);
    for (var i = 0; i < 16; i++) {
      if ((inUse16 & (0x8000 >> i)) != 0) {
        var mask = 0;
        for (var j = 0; j < 16; j++) {
          if (inUse[i * 16 + j]) mask |= 0x8000 >> j;
        }
        w.writeBits(mask, 16);
      }
    }

    // groups + selectors: two identical tables, selector 0 for every group.
    const nGroups = 2;
    final nSelectors = (symbols.length + 49) ~/ 50;
    w.writeBits(nGroups, 3);
    w.writeBits(nSelectors, 15);
    for (var i = 0; i < nSelectors; i++) {
      w.writeBits(0, 1); // MTF value 0 -> unary "0"
    }

    // per-group code lengths (delta-coded), identical for both groups.
    for (var g = 0; g < nGroups; g++) {
      var curr = lengths[0];
      w.writeBits(curr, 5);
      for (var s = 0; s < alphaSize; s++) {
        final target = lengths[s];
        while (curr < target) {
          w.writeBits(2, 2); // "10": increment
          curr++;
        }
        while (curr > target) {
          w.writeBits(3, 2); // "11": decrement
          curr--;
        }
        w.writeBits(0, 1); // stop
      }
    }

    // --- the symbol stream ---
    for (final s in symbols) {
      w.writeBits(codes[s], lengths[s]);
    }
  }

  // ---- RLE1 ----

  static Uint8List _rle1(Uint8List data) {
    // `copy: true`: `buf` is a reused scratch buffer, so the builder must copy
    // each flushed slice rather than alias the buffer we overwrite next.
    final out = BytesBuilder();
    final buf = Uint8List(260);
    var bp = 0;
    var i = 0;
    while (i < data.length) {
      final b = data[i];
      var run = 1;
      while (i + run < data.length && data[i + run] == b && run < 255) {
        run++;
      }
      i += run;
      if (bp + 5 > buf.length) {
        out.add(Uint8List.sublistView(buf, 0, bp));
        bp = 0;
      }
      if (run >= 4) {
        buf[bp++] = b;
        buf[bp++] = b;
        buf[bp++] = b;
        buf[bp++] = b;
        buf[bp++] = run - 4;
      } else {
        for (var k = 0; k < run; k++) {
          buf[bp++] = b;
        }
      }
    }
    out.add(Uint8List.sublistView(buf, 0, bp));
    return out.takeBytes();
  }

  // ---- forward BWT via a prefix-doubling suffix sort over cyclic rotations ----

  static ({Uint8List last, int origPtr}) _bwt(Uint8List s) {
    final n = s.length;
    if (n == 0) {
      return (last: Uint8List(0), origPtr: 0);
    }
    final rank = List<int>.generate(n, (i) => s[i]);
    final sa = List<int>.generate(n, (i) => i);
    final tmp = List<int>.filled(n, 0);
    var k = 1;
    while (true) {
      int cmp(int a, int b) {
        if (rank[a] != rank[b]) return rank[a] - rank[b];
        final ra = rank[(a + k) % n];
        final rb = rank[(b + k) % n];
        return ra - rb;
      }

      sa.sort(cmp);
      tmp[sa[0]] = 0;
      for (var j = 1; j < n; j++) {
        tmp[sa[j]] = tmp[sa[j - 1]] + (cmp(sa[j - 1], sa[j]) < 0 ? 1 : 0);
      }
      for (var j = 0; j < n; j++) {
        rank[j] = tmp[j];
      }
      if (rank[sa[n - 1]] == n - 1) break;
      k *= 2;
      if (k >= n) break;
    }

    // Periodic input has identical rotations (equal rank forever), and Dart's
    // `sort` is not stable — their relative order would otherwise vary by input
    // size and platform. Break rank ties by start index for a canonical, fully
    // deterministic transform. (Identical rotations are interchangeable, so any
    // order inverts correctly; this just pins one.)
    sa.sort((a, b) {
      final d = rank[a] - rank[b];
      return d != 0 ? d : a - b;
    });

    final last = Uint8List(n);
    var origPtr = 0;
    for (var i = 0; i < n; i++) {
      last[i] = s[(sa[i] + n - 1) % n];
      if (sa[i] == 0) origPtr = i;
    }
    return (last: last, origPtr: origPtr);
  }

  // ---- MTF + RLE2 ----

  static List<int> _mtfRle2(Uint8List bwt, List<int> seqToUnseq, int eob) {
    final mtf = Uint8List.fromList(seqToUnseq);
    final n = mtf.length;
    final out = <int>[];
    var zeroRun = 0;
    void flushZeros() {
      while (zeroRun > 0) {
        zeroRun--;
        out.add(zeroRun & 1 == 0 ? 0 : 1); // RUNA / RUNB, bijective base 2
        zeroRun >>= 1;
      }
    }

    for (final b in bwt) {
      // find b in mtf
      var pos = 0;
      while (mtf[pos] != b) {
        pos++;
      }
      if (pos == 0) {
        zeroRun++;
      } else {
        flushZeros();
        out.add(pos + 1); // MTF index -> symbol (2..eob-1)
        for (var j = pos; j > 0; j--) {
          mtf[j] = mtf[j - 1];
        }
        mtf[0] = b;
      }
    }
    flushZeros();
    out.add(eob);
    // `n` is only used for clarity; the mtf list length equals the alphabet.
    assert(n == seqToUnseq.length, 'mtf list size');
    return out;
  }

  // ---- length-limited Huffman (bzip2 hbMakeCodeLengths) ----

  static List<int> _makeCodeLengths(
    Uint32List freqs,
    int alphaSize,
    int maxLen,
  ) {
    // 1-indexed arrays as in the reference.
    final weight = List<int>.filled(alphaSize * 2 + 2, 0);
    final parent = List<int>.filled(alphaSize * 2 + 2, 0);
    final heap = List<int>.filled(alphaSize + 2, 0);
    final lengths = List<int>.filled(alphaSize, 0);

    for (var i = 0; i < alphaSize; i++) {
      weight[i + 1] = (freqs[i] == 0 ? 1 : freqs[i]) << 8;
    }

    while (true) {
      var nHeap = 0;
      var nNodes = alphaSize;
      // build heap
      heap[0] = 0;
      weight[0] = 0;
      parent[0] = -2;
      for (var i = 1; i <= alphaSize; i++) {
        parent[i] = -1;
        nHeap++;
        heap[nHeap] = i;
        // up-heapify
        var zz = nHeap;
        final tmp = heap[zz];
        while (weight[tmp] < weight[heap[zz >> 1]]) {
          heap[zz] = heap[zz >> 1];
          zz >>= 1;
        }
        heap[zz] = tmp;
      }

      while (nHeap > 1) {
        final n1 = heap[1];
        heap[1] = heap[nHeap];
        nHeap--;
        // down-heapify
        var zz = 1;
        var tmp = heap[zz];
        while (true) {
          var yy = zz << 1;
          if (yy > nHeap) break;
          if (yy < nHeap && weight[heap[yy + 1]] < weight[heap[yy]]) yy++;
          if (weight[tmp] < weight[heap[yy]]) break;
          heap[zz] = heap[yy];
          zz = yy;
        }
        heap[zz] = tmp;

        final n2 = heap[1];
        heap[1] = heap[nHeap];
        nHeap--;
        zz = 1;
        tmp = heap[zz];
        while (true) {
          var yy = zz << 1;
          if (yy > nHeap) break;
          if (yy < nHeap && weight[heap[yy + 1]] < weight[heap[yy]]) yy++;
          if (weight[tmp] < weight[heap[yy]]) break;
          heap[zz] = heap[yy];
          zz = yy;
        }
        heap[zz] = tmp;

        nNodes++;
        parent[n1] = nNodes;
        parent[n2] = nNodes;
        weight[nNodes] = _addWeights(weight[n1], weight[n2]);
        parent[nNodes] = -1;
        nHeap++;
        heap[nHeap] = nNodes;
        zz = nHeap;
        tmp = heap[zz];
        while (weight[tmp] < weight[heap[zz >> 1]]) {
          heap[zz] = heap[zz >> 1];
          zz >>= 1;
        }
        heap[zz] = tmp;
      }

      var tooLong = false;
      for (var i = 1; i <= alphaSize; i++) {
        var j = 0;
        var kk = i;
        while (parent[kk] >= 0) {
          kk = parent[kk];
          j++;
        }
        lengths[i - 1] = j;
        if (j > maxLen) tooLong = true;
      }
      if (!tooLong) break;

      // Scale frequencies down and retry.
      for (var i = 1; i <= alphaSize; i++) {
        var j = weight[i] >> 8;
        j = 1 + (j ~/ 2);
        weight[i] = j << 8;
      }
    }
    return lengths;
  }

  static int _addWeights(int w1, int w2) {
    final freq = (w1 & 0xFFFFFF00) + (w2 & 0xFFFFFF00);
    final depth = 1 + ((w1 & 0xFF) > (w2 & 0xFF) ? (w1 & 0xFF) : (w2 & 0xFF));
    return freq | depth;
  }

  static List<int> _assignCodes(List<int> lengths, int alphaSize) {
    var minLen = 32;
    var maxLen = 0;
    for (final l in lengths) {
      if (l > maxLen) maxLen = l;
      if (l < minLen) minLen = l;
    }
    final codes = List<int>.filled(alphaSize, 0);
    var vec = 0;
    for (var n = minLen; n <= maxLen; n++) {
      for (var i = 0; i < alphaSize; i++) {
        if (lengths[i] == n) codes[i] = vec++;
      }
      vec <<= 1;
    }
    return codes;
  }

  // ---- CRC-32/BZIP2 (non-reflected) ----

  static final Uint32List _crcTable = _buildCrcTable();
  static Uint32List _buildCrcTable() {
    final t = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i << 24;
      for (var k = 0; k < 8; k++) {
        c = (c & 0x80000000) != 0
            ? ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            : (c << 1) & 0xFFFFFFFF;
      }
      t[i] = c;
    }
    return t;
  }

  static int _bzCrc(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < data.length; i++) {
      crc = ((crc << 8) ^ _crcTable[((crc >>> 24) ^ data[i]) & 0xFF]) &
          0xFFFFFFFF;
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// MSB-first bit writer (bzip2 bit order).
final class _BitWriter {
  final BytesBuilder _out = BytesBuilder();
  int _acc = 0;
  int _nbits = 0;

  /// Writes the low [n] bits of [value] (n ≤ 24), most-significant first.
  void writeBits(int value, int n) {
    if (n == 32) {
      writeBits((value >>> 16) & 0xFFFF, 16);
      writeBits(value & 0xFFFF, 16);
      return;
    }
    _acc = (_acc << n) | (value & ((1 << n) - 1));
    _nbits += n;
    while (_nbits >= 8) {
      _nbits -= 8;
      _out.addByte((_acc >>> _nbits) & 0xFF);
    }
    _acc &= (1 << _nbits) - 1;
  }

  /// Flushes the final partial byte (zero-padded, MSB-aligned).
  void finish() {
    if (_nbits > 0) {
      _out.addByte((_acc << (8 - _nbits)) & 0xFF);
      _acc = 0;
      _nbits = 0;
    }
  }

  Uint8List takeBytes() {
    finish();
    return _out.takeBytes();
  }
}

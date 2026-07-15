/// Branch/call filters used by 7z and xz (§8). These are byte-level
/// transforms applied to already-decompressed data; decode direction only
/// (this project reads archives).
///
/// The x86 BCJ algorithm follows the public-domain reference (LZMA SDK's
/// `Bra86.c` / xz-embedded's `xz_dec_bcj.c`, both public domain);
/// correctness is verified against liblzma via CPython's `lzma` module in
/// the test suite.
library;

import 'dart:typed_data';

/// Reverses a delta filter in place: `data[i] += data[i - distance]`.
///
/// [distance] must be 1–256 (the format encodes distance − 1 in the coder
/// properties).
void deltaDecode(Uint8List data, int distance) {
  if (distance < 1 || distance > 256) {
    throw FormatException('invalid delta filter distance $distance');
  }
  for (var i = distance; i < data.length; i++) {
    data[i] = (data[i] + data[i - distance]) & 0xFF;
  }
}

const List<bool> _maskToAllowed = [
  true, true, true, false, true, false, false, false, //
];
const List<int> _maskToBitNumber = [0, 1, 2, 2, 3, 3, 3, 3];

bool _testMsByte(int b) => b == 0x00 || b == 0xFF;

/// Reverses the x86 BCJ filter in place (whole-buffer, start address 0):
/// converts absolute CALL/JMP (0xE8/0xE9) targets back to relative.
void bcjX86Decode(Uint8List data) {
  if (data.length < 5) return;
  final size = data.length - 4;
  var prevMask = 0;
  var prevPos = -1;

  var i = 0;
  while (i < size) {
    if ((data[i] & 0xFE) != 0xE8) {
      i++;
      continue;
    }
    final d = i - prevPos;
    prevPos = i;
    if (d > 3) {
      prevMask = 0;
    } else {
      prevMask = (prevMask << (d - 1)) & 7;
      if (prevMask != 0) {
        final b = data[i + 4 - _maskToBitNumber[prevMask]];
        if (!_maskToAllowed[prevMask] || _testMsByte(b)) {
          prevMask = ((prevMask << 1) | 1) & 7;
          i++;
          continue;
        }
      }
    }

    if (_testMsByte(data[i + 4])) {
      var src =
          data[i + 1] |
          (data[i + 2] << 8) |
          (data[i + 3] << 16) |
          (data[i + 4] << 24);
      var dest = 0;
      for (;;) {
        // Decode: absolute -> relative (ip is the address of the next
        // instruction: buffer start 0 + i + 5).
        dest = (src - (i + 5)) & 0xFFFFFFFF;
        if (prevMask == 0) break;
        final shift = _maskToBitNumber[prevMask] * 8;
        final b = (dest >>> (24 - shift)) & 0xFF;
        if (!_testMsByte(b)) break;
        src = dest ^ (((1 << (32 - shift)) - 1) & 0xFFFFFFFF);
      }
      dest &= 0x01FFFFFF;
      if (dest & 0x01000000 != 0) dest |= 0xFE000000;
      data[i + 1] = dest & 0xFF;
      data[i + 2] = (dest >>> 8) & 0xFF;
      data[i + 3] = (dest >>> 16) & 0xFF;
      data[i + 4] = (dest >>> 24) & 0xFF;
      i += 5;
      prevMask = 0;
    } else {
      prevMask = ((prevMask << 1) | 1) & 7;
      i++;
    }
  }
}

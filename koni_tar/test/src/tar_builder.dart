// Test-only builder for hand-crafted tar bytes: exercises paths reference
// tools cannot produce on demand (base-256 sizes, device nodes, sparse
// entries, deliberate corruption).

import 'dart:convert';
import 'dart:typed_data';

/// Builds one 512-byte header block.
Uint8List tarHeader({
  required String name,
  int mode = 420, // 0644
  int size = 0,
  int mtime = 1577934245, // 2020-01-02T03:04:05Z
  String typeFlag = '0',
  String linkName = '',
  String magic =
      'ustar\x00'
          '00',
  String prefix = '',
  void Function(Uint8List block)? mutate,
  bool corruptChecksum = false,
}) {
  final block = Uint8List(512);

  void putString(int at, int len, String value) {
    final bytes = utf8.encode(value);
    block.setRange(at, at + (bytes.length > len ? len : bytes.length), bytes);
  }

  void putOctal(int at, int len, int value) {
    final digits = value.toRadixString(8).padLeft(len - 1, '0');
    putString(at, len - 1, digits);
    block[at + len - 1] = 0;
  }

  putString(0, 100, name);
  putOctal(100, 8, mode);
  putOctal(108, 8, 501);
  putOctal(116, 8, 20);
  putOctal(124, 12, size);
  putOctal(136, 12, mtime);
  block[156] = typeFlag.codeUnitAt(0);
  putString(157, 100, linkName);
  putString(257, 8, magic);
  putString(265, 32, 'user');
  putString(297, 32, 'group');
  putOctal(329, 8, 0);
  putOctal(337, 8, 0);
  putString(345, 155, prefix);

  mutate?.call(block);

  // Checksum: sum of the block with the chksum field as spaces.
  for (var i = 148; i < 156; i++) {
    block[i] = 0x20;
  }
  var sum = 0;
  for (final byte in block) {
    sum += byte;
  }
  if (corruptChecksum) sum += 1;
  final chk = sum.toRadixString(8).padLeft(6, '0');
  block.setRange(148, 154, utf8.encode(chk));
  block[154] = 0;
  block[155] = 0x20;
  return block;
}

/// Writes [value] into a numeric field as GNU base-256 (big-endian two's
/// complement, marker bit set). Pure arithmetic; bitwise shifts on
/// negative/large ints are not portable to dart2js.
void putBase256(Uint8List block, int at, int len, int value) {
  var v = value;
  for (var i = at + len - 1; i > at; i--) {
    final byte = v % 256; // Dart % is Euclidean: correct low byte, any sign
    block[i] = byte;
    v = (v - byte) ~/ 256; // arithmetic shift; stays -1 for negatives
  }
  block[at] = 0x80 | (v % 64) | (value < 0 ? 0x40 : 0);
}

/// Builds one well-formed PAX record (`"<len> <key>=<value>\n"` where len
/// counts the whole record including its own digits).
String paxRecord(String key, String value) {
  final payloadLength = utf8.encode(' $key=$value\n').length;
  var length = payloadLength + 1;
  while ('$length'.length + payloadLength != length) {
    length = '$length'.length + payloadLength;
  }
  return '$length $key=$value\n';
}

/// Pads [data] to a whole number of 512-byte blocks.
Uint8List tarData(List<int> data) {
  final blocks = (data.length + 511) ~/ 512;
  final padded = Uint8List(blocks * 512);
  padded.setRange(0, data.length, data);
  return padded;
}

/// Concatenates parts and appends the two zero end-of-archive blocks.
Uint8List tarArchive(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  builder.add(Uint8List(1024));
  return builder.takeBytes();
}

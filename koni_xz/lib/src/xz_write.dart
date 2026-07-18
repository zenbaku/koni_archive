/// Building the `.xz` container on the write side: LZMA2-compress the payload,
/// then frame it as a single-block, single-stream `.xz` file (stream header →
/// block → CRC-64 check → index → footer). The inverse of `xz_container.dart` /
/// `xz_block.dart`.
library;

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

import 'xz_container.dart' show roundUp4, xzFooterMagic, xzMagic;

/// Builds a complete single-stream `.xz` file compressing [data] with LZMA2 and
/// a CRC-64 integrity check.
///
/// The whole payload is one block (default single-threaded `xz`'s layout): the
/// `Lzma2Encoder` is one-shot and its output buffer doubles as the match
/// window, so [data] is held in memory while encoding — the same caveat as the
/// 7z LZMA path. Empty input yields a valid zero-block stream (see
/// [buildEmptyXzStream]).
Uint8List buildXzStream(Uint8List data) {
  if (data.isEmpty) return buildEmptyXzStream();

  const checkType = 0x04; // CRC-64, xz's default
  const checkSize = 8;

  final encoder = Lzma2Encoder();
  final props = encoder.dictSizeProp;
  final compressed = encoder.encode(data);

  final blockHeader = _buildBlockHeader(props);
  final packSize = compressed.length;
  final blockPadding = roundUp4(packSize) - packSize;
  final check = Crc64.computeBytes(data); // 8 little-endian bytes
  final unpaddedSize = blockHeader.length + packSize + checkSize;

  final index = _buildIndex([_Record(unpaddedSize, data.length)]);
  final footer = _buildFooter(index.length, checkType);
  final header = _buildStreamHeader(checkType);

  final out =
      BytesBuilder(copy: false)
        ..add(header)
        ..add(blockHeader)
        ..add(compressed)
        ..add(Uint8List(blockPadding))
        ..add(check)
        ..add(index)
        ..add(footer);
  return out.takeBytes();
}

/// Builds a valid empty `.xz` stream (zero blocks), what `xz` emits for empty
/// input: a 32-byte stream header + zero-record index + footer.
Uint8List buildEmptyXzStream() {
  const checkType = 0x04;
  final index = _buildIndex(const []);
  final footer = _buildFooter(index.length, checkType);
  final header = _buildStreamHeader(checkType);
  final out =
      BytesBuilder(copy: false)
        ..add(header)
        ..add(index)
        ..add(footer);
  return out.takeBytes();
}

// --- sections --------------------------------------------------------------

Uint8List _buildStreamHeader(int checkType) {
  final h = Uint8List(12);
  h.setRange(0, 6, xzMagic);
  h[6] = 0x00; // reserved
  h[7] = checkType; // stream flags: check id in the low nibble
  _putU32le(h, 8, Crc32.compute(Uint8List.sublistView(h, 6, 8)));
  return h;
}

Uint8List _buildBlockHeader(int lzma2Props) {
  // Body after the size byte: block flags, then the LZMA2 filter flags.
  final body =
      BytesBuilder(copy: false)
        ..addByte(0x00) // 1 filter (count-1=0); no compressed/uncompressed size
        ..add(_vli(xzFilterLzma2Id)) // filter id 0x21
        ..add(_vli(1)) // property size
        ..addByte(lzma2Props); // the dictionary-size property byte
  final bodyBytes = body.takeBytes();

  // Total header = size byte + body + padding + 4-byte CRC, a multiple of 4.
  final contentLen = 1 + bodyBytes.length;
  final headerSize = roundUp4(contentLen + 4);
  final header = Uint8List(headerSize);
  header[0] = headerSize ~/ 4 - 1;
  header.setRange(1, 1 + bodyBytes.length, bodyBytes);
  // padding bytes are already zero
  _putU32le(
    header,
    headerSize - 4,
    Crc32.compute(Uint8List.sublistView(header, 0, headerSize - 4)),
  );
  return header;
}

Uint8List _buildIndex(List<_Record> records) {
  final body =
      BytesBuilder(copy: false)
        ..addByte(0x00) // index indicator
        ..add(_vli(records.length));
  for (final r in records) {
    body
      ..add(_vli(r.unpaddedSize))
      ..add(_vli(r.uncompressedSize));
  }
  final bodyBytes = body.takeBytes();
  final indexSize = roundUp4(bodyBytes.length + 4);
  final index = Uint8List(indexSize);
  index.setRange(0, bodyBytes.length, bodyBytes);
  // padding bytes are already zero
  _putU32le(
    index,
    indexSize - 4,
    Crc32.compute(Uint8List.sublistView(index, 0, indexSize - 4)),
  );
  return index;
}

Uint8List _buildFooter(int indexSize, int checkType) {
  final footer = Uint8List(12);
  _putU32le(footer, 4, indexSize ~/ 4 - 1); // backward size
  footer[8] = 0x00;
  footer[9] = checkType;
  footer[10] = xzFooterMagic[0];
  footer[11] = xzFooterMagic[1];
  _putU32le(footer, 0, Crc32.compute(Uint8List.sublistView(footer, 4, 10)));
  return footer;
}

// --- primitives ------------------------------------------------------------

/// LZMA2 filter id, local to avoid importing more than needed.
const int xzFilterLzma2Id = 0x21;

/// Encodes [value] (>= 0) as a little-endian base-128 multibyte integer. Uses
/// only `%`/`~/` so it is exact and correct for the >32-bit sizes an index can
/// carry under dart2js (a bitwise `& 0x7F` would truncate to 32 bits).
Uint8List _vli(int value) {
  assert(value >= 0, 'multibyte integers are non-negative');
  final out = BytesBuilder(copy: false);
  var v = value;
  while (v >= 0x80) {
    out.addByte((v % 128) | 0x80);
    v = v ~/ 128;
  }
  out.addByte(v);
  return out.takeBytes();
}

/// Writes [value] as four little-endian bytes at [offset], via arithmetic so it
/// is dart2js-safe for values that a 32-bit shift would mangle.
void _putU32le(Uint8List buf, int offset, int value) {
  var v = value;
  buf[offset] = v % 256;
  v = v ~/ 256;
  buf[offset + 1] = v % 256;
  v = v ~/ 256;
  buf[offset + 2] = v % 256;
  v = v ~/ 256;
  buf[offset + 3] = v % 256;
}

class _Record {
  const _Record(this.unpaddedSize, this.uncompressedSize);
  final int unpaddedSize;
  final int uncompressedSize;
}

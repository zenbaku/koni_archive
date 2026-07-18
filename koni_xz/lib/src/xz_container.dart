/// Parsing of the `.xz` container framing (RFC-less; the format is defined by
/// <https://tukaani.org/xz/xz-file-format.txt>). This layer walks the stream
/// header, footer, and index to build an ordered block table; the per-block
/// header (filter chain) is parsed lazily at decode time by the reader.
///
/// Everything here operates on a seekable [ByteSource], so sizes come from the
/// stream **index** at the end (each record is `(unpaddedSize,
/// uncompressedSize)`) rather than from a forward scan — the same
/// read-from-the-end strategy as ZIP's central directory and 7z's end header.
/// Malformed framing throws a typed [ArchiveException]; the LZMA2 payload's own
/// corruption is the reader's concern.
library;

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

/// The six-byte `.xz` stream-header magic (`\xFD 7 z X Z \0`).
const List<int> xzMagic = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00];

/// The two-byte stream-footer magic (`Y Z`).
const List<int> xzFooterMagic = [0x59, 0x5A];

/// The delta filter ID (`0x03`); properties are one byte, `distance - 1`.
const int xzFilterDelta = 0x03;

/// The BCJ x86 filter ID (`0x04`).
const int xzFilterBcjX86 = 0x04;

/// The LZMA2 filter ID (`0x21`), the only legal final (compression) filter.
const int xzFilterLzma2 = 0x21;

/// Ceiling on any single multibyte integer this reader will decode, chosen so
/// all VLI arithmetic stays well under 2^53 and is therefore exact under
/// dart2js (2^48 = 256 TiB — far past any real archive; larger is a typed
/// error, not a silent wrap). Written as a decimal literal, not `1 << 48`: a
/// shift of 32 or more is undefined under dart2js's 32-bit bitwise ops.
const int _maxVli = 281474976710656; // 2^48

/// One block located within a (possibly multi-stream) `.xz` file.
///
/// [start] is the absolute offset of the block header's first byte; the block
/// header, compressed data, block padding, and [checkSize]-byte check together
/// occupy `roundUp4(unpaddedSize)` bytes. The check algorithm ([checkType]) is
/// carried per block because concatenated streams may each declare a different
/// one.
final class XzBlockInfo {
  /// Creates a block-table entry.
  const XzBlockInfo({
    required this.start,
    required this.unpaddedSize,
    required this.uncompressedSize,
    required this.checkType,
    required this.checkSize,
  });

  /// Absolute offset of the block header's first byte.
  final int start;

  /// `blockHeaderSize + compressedDataSize + checkSize` (index record; the
  /// trailing block padding is *not* counted).
  final int unpaddedSize;

  /// Decoded size of this block, in bytes (index record).
  final int uncompressedSize;

  /// The stream's check id: 0 none, 1 CRC32, 4 CRC64, 0x0A SHA-256.
  final int checkType;

  /// Check length in bytes (0, 4, 8, or 32).
  final int checkSize;
}

/// The parsed framing of an `.xz` file: its ordered block table and totals.
final class XzContainer {
  /// Creates a parsed-container descriptor.
  const XzContainer({
    required this.blocks,
    required this.totalUncompressed,
    required this.streamCount,
  });

  /// Blocks in decode order (first stream first).
  final List<XzBlockInfo> blocks;

  /// Sum of every block's [XzBlockInfo.uncompressedSize].
  final int totalUncompressed;

  /// Number of concatenated streams (usually 1).
  final int streamCount;
}

/// A parsed block header: filter chain plus the header's own byte length.
final class XzBlockHeader {
  /// Creates a parsed block header.
  const XzBlockHeader({
    required this.headerSize,
    required this.filters,
    required this.compressedSize,
    required this.uncompressedSize,
  });

  /// Length of the block header in bytes (`(sizeByte + 1) * 4`).
  final int headerSize;

  /// Filters in encode order; the last is always the LZMA2 compressor and the
  /// earlier ones (delta / BCJ) are reverse-applied after decompression.
  final List<XzFilter> filters;

  /// Compressed size recorded in the header, or null when absent.
  final int? compressedSize;

  /// Uncompressed size recorded in the header, or null when absent.
  final int? uncompressedSize;
}

/// One filter-flags entry from a block header.
final class XzFilter {
  /// Creates a filter-flags entry.
  const XzFilter(this.id, this.props);

  /// Filter ID (e.g. [xzFilterLzma2]).
  final int id;

  /// Raw filter properties (length was VLI-encoded in the header).
  final Uint8List props;
}

/// Rounds [x] up to the next multiple of four using only arithmetic, so it
/// stays correct for the >32-bit sizes an index can carry (a bitwise
/// `& ~3` would truncate to 32 bits under dart2js).
int roundUp4(int x) {
  final r = x % 4;
  return r == 0 ? x : x + (4 - r);
}

/// Check length in bytes for a **supported** check algorithm, or null for a
/// reserved / unsupported id. Only the four algorithms real `.xz` ever writes
/// are recognized (None, CRC32, CRC64, SHA-256); every other 4-bit value is
/// reserved by the spec and rejected rather than silently skipped.
int? xzCheckSize(int checkType) => switch (checkType) {
  0x00 => 0, // None
  0x01 => 4, // CRC32
  0x04 => 8, // CRC64
  0x0A => 32, // SHA-256
  _ => null, // reserved / unsupported
};

/// Parses the whole `.xz` framing of [source] from the end backward, spanning
/// any number of concatenated streams (with optional inter-stream padding).
///
/// Reconciles the walk against the file length: leftover bytes, a stream whose
/// header does not line up with its index, or a footer that disagrees with its
/// header all raise a typed error rather than a silent mis-read.
Future<XzContainer> parseXzContainer(ByteSource source) async {
  if (source.length < 24) {
    // Minimum: 12-byte header + empty index (8) ... in practice a stream is at
    // least header(12) + index(>=8) + footer(12); reject anything too small.
    throw UnexpectedEofException(
      'too short to be a complete .xz file (${source.length} bytes)',
      format: 'xz',
    );
  }

  final blocks = <XzBlockInfo>[];
  var total = 0;
  var streamCount = 0;
  var end = source.length;

  while (end > 0) {
    // Skip inter-stream / trailing padding (multiples of four zero bytes). A
    // real footer ends in `Y Z`, so a footer's last four bytes are never all
    // zero: the first non-zero group is the footer's tail.
    end = await _skipZeroPadding(source, end);
    if (end == 0) break;

    if (end < 12) {
      throw InvalidHeaderException(
        'trailing bytes before offset $end are not a valid .xz stream',
        format: 'xz',
        offset: 0,
      );
    }

    final footer = await source.read(end - 12, 12);
    _verifyFooter(footer, end - 12);
    final checkType = footer[9] & 0x0F;
    if (footer[8] != 0 || (footer[9] & 0xF0) != 0) {
      throw InvalidHeaderException(
        'reserved stream-flag bits are set',
        format: 'xz',
        offset: end - 4,
      );
    }
    final checkSize = xzCheckSize(checkType);
    if (checkSize == null) {
      throw InvalidHeaderException(
        'unsupported .xz check id 0x${checkType.toRadixString(16)} '
        '(only none/CRC32/CRC64/SHA-256 are supported)',
        format: 'xz',
        offset: end - 3,
      );
    }
    final backwardSize = footer[4] | (footer[5] << 8) | (footer[6] << 16);
    // footer[7] is the high byte; combine without a >32-bit shift risk.
    final indexSize = (backwardSize + (footer[7] * 0x1000000) + 1) * 4;

    final indexEnd = end - 12;
    final indexStart = indexEnd - indexSize;
    if (indexStart < 12) {
      throw InvalidHeaderException(
        'stream index size $indexSize does not fit before its footer',
        format: 'xz',
        offset: indexEnd,
      );
    }
    final indexBytes = await source.read(indexStart, indexSize);
    final records = _parseIndex(indexBytes, indexStart);

    // Locate the stream header from the blocks region: it precedes the index
    // by exactly the padded block sizes plus the 12-byte header.
    var blocksTotal = 0;
    for (final r in records) {
      blocksTotal += roundUp4(r.unpaddedSize);
      if (blocksTotal < 0 || blocksTotal > _maxVli) {
        throw _tooLarge();
      }
    }
    final streamStart = indexStart - blocksTotal - 12;
    if (streamStart < 0) {
      throw InvalidHeaderException(
        'stream index describes more block bytes than the file holds',
        format: 'xz',
        offset: indexStart,
      );
    }

    final header = await source.read(streamStart, 12);
    _verifyStreamHeader(header, streamStart);
    // Header stream flags (bytes 6-7) must match the footer's (bytes 8-9).
    if (header[6] != footer[8] || header[7] != footer[9]) {
      throw InvalidHeaderException(
        'stream header and footer flags disagree',
        format: 'xz',
        offset: streamStart + 6,
      );
    }

    // Materialize this stream's blocks (forward order within the stream) and
    // prepend so the global list stays in whole-file decode order.
    final streamBlocks = <XzBlockInfo>[];
    var blockPos = streamStart + 12;
    for (final r in records) {
      streamBlocks.add(
        XzBlockInfo(
          start: blockPos,
          unpaddedSize: r.unpaddedSize,
          uncompressedSize: r.uncompressedSize,
          checkType: checkType,
          checkSize: checkSize,
        ),
      );
      blockPos += roundUp4(r.unpaddedSize);
      total += r.uncompressedSize;
      if (total < 0 || total > _maxVli) throw _tooLarge();
    }
    if (blockPos != indexStart) {
      throw InvalidHeaderException(
        'stream blocks do not end where the index begins',
        format: 'xz',
        offset: blockPos,
      );
    }
    blocks.insertAll(0, streamBlocks);
    streamCount++;
    end = streamStart;
  }

  if (streamCount == 0) {
    throw InvalidHeaderException(
      'no .xz stream found',
      format: 'xz',
      offset: 0,
    );
  }
  return XzContainer(
    blocks: blocks,
    totalUncompressed: total,
    streamCount: streamCount,
  );
}

/// Parses a block header (already read into [headerBytes], whose length is the
/// full `(sizeByte+1)*4`) at absolute [offset], validating flags, filter chain,
/// padding, and the trailing CRC-32.
XzBlockHeader parseXzBlockHeader(Uint8List headerBytes, int offset) {
  final headerSize = headerBytes.length;
  // Verify the header CRC-32 (last four bytes, over everything before them).
  final crcStored =
      headerBytes[headerSize - 4] |
      (headerBytes[headerSize - 3] << 8) |
      (headerBytes[headerSize - 2] << 16) |
      (headerBytes[headerSize - 1] << 24);
  final crcActual = Crc32.compute(
    Uint8List.sublistView(headerBytes, 0, headerSize - 4),
  );
  if ((crcStored & 0xFFFFFFFF) != crcActual) {
    throw InvalidHeaderException(
      'block header CRC-32 mismatch',
      format: 'xz',
      offset: offset,
    );
  }

  final flags = headerBytes[1];
  if ((flags & 0x3C) != 0) {
    throw InvalidHeaderException(
      'reserved block-flag bits are set',
      format: 'xz',
      offset: offset + 1,
    );
  }
  final filterCount = (flags & 0x03) + 1;
  final hasCompressed = (flags & 0x40) != 0;
  final hasUncompressed = (flags & 0x80) != 0;

  var pos = 2;
  int? compressedSize;
  int? uncompressedSize;
  if (hasCompressed) {
    final v = _readVli(headerBytes, pos, headerSize - 4, offset);
    compressedSize = v.value;
    pos = v.next;
  }
  if (hasUncompressed) {
    final v = _readVli(headerBytes, pos, headerSize - 4, offset);
    uncompressedSize = v.value;
    pos = v.next;
  }

  final filters = <XzFilter>[];
  for (var i = 0; i < filterCount; i++) {
    final idV = _readVli(headerBytes, pos, headerSize - 4, offset);
    pos = idV.next;
    final sizeV = _readVli(headerBytes, pos, headerSize - 4, offset);
    pos = sizeV.next;
    final propSize = sizeV.value;
    if (pos + propSize > headerSize - 4) {
      throw InvalidHeaderException(
        'filter properties overrun the block header',
        format: 'xz',
        offset: offset,
      );
    }
    final props = Uint8List.sublistView(headerBytes, pos, pos + propSize);
    pos += propSize;
    filters.add(XzFilter(idV.value, props));
  }

  // Header padding: remaining bytes before the CRC must be zero.
  for (; pos < headerSize - 4; pos++) {
    if (headerBytes[pos] != 0) {
      throw InvalidHeaderException(
        'non-zero block-header padding',
        format: 'xz',
        offset: offset + pos,
      );
    }
  }

  return XzBlockHeader(
    headerSize: headerSize,
    filters: filters,
    compressedSize: compressedSize,
    uncompressedSize: uncompressedSize,
  );
}

// --- internals -------------------------------------------------------------

class _IndexRecord {
  const _IndexRecord(this.unpaddedSize, this.uncompressedSize);
  final int unpaddedSize;
  final int uncompressedSize;
}

class _Vli {
  const _Vli(this.value, this.next);
  final int value;
  final int next;
}

/// A count or size field past [_maxVli], as a typed error.
UnsupportedFeatureException _tooLarge() => UnsupportedFeatureException(
  'an .xz size field exceeds the supported range',
  format: 'xz',
);

/// Reads a little-endian base-128 multibyte integer from [buf] at [pos],
/// bounded by [end]. Uses only exact arithmetic (each term is a small integer
/// times a power of two, always exact as a double), so it is dart2js-safe;
/// values past [_maxVli] raise [UnsupportedFeatureException].
_Vli _readVli(Uint8List buf, int pos, int end, int offset) {
  if (pos >= end) {
    throw UnexpectedEofException(
      'truncated multibyte integer',
      format: 'xz',
      offset: offset + pos,
    );
  }
  var b = buf[pos];
  var value = b & 0x7F;
  var i = 1;
  var factor = 128;
  while ((b & 0x80) != 0) {
    if (i >= 9 || pos + i >= end) {
      throw UnexpectedEofException(
        'malformed multibyte integer',
        format: 'xz',
        offset: offset + pos,
      );
    }
    b = buf[pos + i];
    value += (b & 0x7F) * factor;
    if (value > _maxVli) {
      throw UnsupportedFeatureException(
        'a size field exceeds the supported range (max ${_maxVli}B)',
        format: 'xz',
      );
    }
    factor *= 128;
    i++;
  }
  // The final byte (high bit clear) must be non-zero unless the value is a
  // single byte: a trailing zero continuation is a non-minimal encoding.
  if (i > 1 && (buf[pos + i - 1] & 0x7F) == 0) {
    throw InvalidHeaderException(
      'non-minimal multibyte integer',
      format: 'xz',
      offset: offset + pos,
    );
  }
  return _Vli(value, pos + i);
}

List<_IndexRecord> _parseIndex(Uint8List index, int offset) {
  // index[0] must be 0x00 (Index Indicator).
  if (index.isEmpty || index[0] != 0x00) {
    throw InvalidHeaderException(
      'bad index indicator',
      format: 'xz',
      offset: offset,
    );
  }
  // CRC-32 over everything but the trailing four CRC bytes.
  final crcRegionEnd = index.length - 4;
  if (crcRegionEnd < 1) {
    throw InvalidHeaderException(
      'index too short',
      format: 'xz',
      offset: offset,
    );
  }
  final crcStored =
      index[index.length - 4] |
      (index[index.length - 3] << 8) |
      (index[index.length - 2] << 16) |
      (index[index.length - 1] << 24);
  final crcActual = Crc32.compute(
    Uint8List.sublistView(index, 0, crcRegionEnd),
  );
  if ((crcStored & 0xFFFFFFFF) != crcActual) {
    throw InvalidHeaderException(
      'index CRC-32 mismatch',
      format: 'xz',
      offset: offset,
    );
  }

  var pos = 1;
  final countV = _readVli(index, pos, crcRegionEnd, offset);
  pos = countV.next;
  final count = countV.value;
  if (count < 0 || count > _maxVli) {
    throw _tooLarge();
  }

  final records = <_IndexRecord>[];
  for (var i = 0; i < count; i++) {
    final unpaddedV = _readVli(index, pos, crcRegionEnd, offset);
    pos = unpaddedV.next;
    final uncompressedV = _readVli(index, pos, crcRegionEnd, offset);
    pos = uncompressedV.next;
    if (unpaddedV.value == 0) {
      throw InvalidHeaderException(
        'index record with zero unpadded size',
        format: 'xz',
        offset: offset + pos,
      );
    }
    records.add(_IndexRecord(unpaddedV.value, uncompressedV.value));
  }

  // Index padding: zeros up to the CRC region end.
  for (; pos < crcRegionEnd; pos++) {
    if (index[pos] != 0) {
      throw InvalidHeaderException(
        'non-zero index padding',
        format: 'xz',
        offset: offset + pos,
      );
    }
  }
  return records;
}

void _verifyStreamHeader(Uint8List header, int offset) {
  for (var i = 0; i < 6; i++) {
    if (header[i] != xzMagic[i]) {
      throw InvalidHeaderException(
        'bad .xz stream-header magic',
        format: 'xz',
        offset: offset,
      );
    }
  }
  final crcStored =
      header[8] | (header[9] << 8) | (header[10] << 16) | (header[11] << 24);
  final crcActual = Crc32.compute(Uint8List.sublistView(header, 6, 8));
  if ((crcStored & 0xFFFFFFFF) != crcActual) {
    throw InvalidHeaderException(
      'stream-header flags CRC-32 mismatch',
      format: 'xz',
      offset: offset + 8,
    );
  }
}

void _verifyFooter(Uint8List footer, int offset) {
  if (footer[10] != xzFooterMagic[0] || footer[11] != xzFooterMagic[1]) {
    throw InvalidHeaderException(
      'bad .xz stream-footer magic',
      format: 'xz',
      offset: offset + 10,
    );
  }
  final crcStored =
      footer[0] | (footer[1] << 8) | (footer[2] << 16) | (footer[3] << 24);
  final crcActual = Crc32.compute(Uint8List.sublistView(footer, 4, 10));
  if ((crcStored & 0xFFFFFFFF) != crcActual) {
    throw InvalidHeaderException(
      'stream-footer CRC-32 mismatch',
      format: 'xz',
      offset: offset,
    );
  }
}

/// Steps [end] backward over whole four-byte groups of zeros, returning the
/// offset just past the last non-padding byte.
Future<int> _skipZeroPadding(ByteSource source, int end) async {
  var e = end;
  while (e >= 4) {
    final four = await source.read(e - 4, 4);
    if ((four[0] | four[1] | four[2] | four[3]) != 0) break;
    e -= 4;
  }
  return e;
}

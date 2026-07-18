/// Decoding of a single `.xz` block: LZMA2 into a preallocated buffer, then the
/// non-final filters (delta / BCJ x86) reverse-applied, then the integrity
/// check. Shared by the single-entry reader and the layered decompressed
/// source.
library;

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/crypto.dart' show Sha256;
import 'package:koni_codecs/koni_codecs.dart';

import 'xz_container.dart';

/// Source-read chunk size while feeding one block's compressed data.
const int _feedChunkSize = 64 * 1024;

/// Decodes [block] out of [source] and returns its full decoded bytes.
///
/// The block's uncompressed size is known from the index, so the LZMA2 output
/// buffer (which doubles as the dictionary window) is sized exactly. The block
/// header is read here to obtain the filter chain; an unsupported filter, a
/// size mismatch, or (when [verifyChecksums]) a failed check all raise a typed
/// [ArchiveException]. LZMA2-payload corruption surfaces as a [FormatException]
/// from the codec and is left for the caller to translate.
Future<Uint8List> decodeXzBlock(
  ByteSource source,
  XzBlockInfo block, {
  required bool verifyChecksums,
}) async {
  // Block-header size byte -> full header.
  final sizeByte = (await source.read(block.start, 1))[0];
  if (sizeByte == 0) {
    // 0x00 here is the index indicator, not a block: the index lied.
    throw InvalidHeaderException(
      'expected a block header, found the index indicator',
      format: 'xz',
      offset: block.start,
    );
  }
  final headerSize = (sizeByte + 1) * 4;
  final headerBytes = await source.read(block.start, headerSize);
  final header = parseXzBlockHeader(headerBytes, block.start);

  final filters = header.filters;
  // The final filter must be the LZMA2 compressor; the rest are transforms.
  if (filters.last.id != xzFilterLzma2) {
    throw UnsupportedCompressionException(
      'unsupported .xz final filter 0x${filters.last.id.toRadixString(16)} '
      '(only LZMA2 is supported)',
      methodName: 'xz-filter',
      methodId: filters.last.id,
      format: 'xz',
      entryPath: source.name,
    );
  }
  // Validate the transform filters up front, before allocating or decoding.
  for (var i = 0; i < filters.length - 1; i++) {
    _validateTransformFilter(filters[i], source.name);
  }

  // Compressed data size from the index; the header's optional copies, when
  // present, must agree.
  final compressedSize = block.unpaddedSize - headerSize - block.checkSize;
  if (compressedSize <= 0) {
    throw InvalidHeaderException(
      'block has non-positive compressed size',
      format: 'xz',
      offset: block.start,
    );
  }
  if (header.compressedSize != null &&
      header.compressedSize != compressedSize) {
    throw InvalidHeaderException(
      'block header compressed size disagrees with the index',
      format: 'xz',
      offset: block.start,
    );
  }
  if (header.uncompressedSize != null &&
      header.uncompressedSize != block.uncompressedSize) {
    throw InvalidHeaderException(
      'block header uncompressed size disagrees with the index',
      format: 'xz',
      offset: block.start,
    );
  }

  final out = Uint8List(block.uncompressedSize);
  if (block.uncompressedSize > 0) {
    final lzma2 = filters.last;
    final decoder = Lzma2Decoder(
      output: out,
      dictSizeProp: lzma2.props.isEmpty ? null : lzma2.props[0],
    );
    var pos = 0;
    final dataStart = block.start + headerSize;
    while (pos < compressedSize) {
      final take =
          compressedSize - pos < _feedChunkSize
              ? compressedSize - pos
              : _feedChunkSize;
      decoder.addInput(await source.read(dataStart + pos, take));
      pos += take;
    }
    if (!decoder.isFinished) {
      throw const FormatException(
        'LZMA2 stream ended before the block output was complete',
      );
    }
  }

  // Reverse-apply the transform filters, innermost last (encode order was
  // filter[0] first, so decode runs them last-to-first after decompression).
  for (var i = filters.length - 2; i >= 0; i--) {
    final f = filters[i];
    switch (f.id) {
      case xzFilterDelta:
        deltaDecode(out, f.props[0] + 1);
      case xzFilterBcjX86:
        bcjX86Decode(out);
    }
  }

  if (verifyChecksums && block.checkSize > 0) {
    final blockPadding = roundUp4(compressedSize) - compressedSize;
    final checkOffset =
        block.start + headerSize + compressedSize + blockPadding;
    final stored = await source.read(checkOffset, block.checkSize);
    _verifyCheck(block.checkType, stored, out, source.name);
  }

  return out;
}

/// Rejects a transform (non-final) filter this reader cannot reverse, and the
/// one BCJ variant (a non-zero start offset) its whole-buffer implementation
/// does not model.
void _validateTransformFilter(XzFilter f, String? name) {
  switch (f.id) {
    case xzFilterDelta:
      if (f.props.length != 1) {
        throw InvalidHeaderException(
          'delta filter needs a 1-byte distance property',
          format: 'xz',
          entryPath: name,
        );
      }
    case xzFilterBcjX86:
      // Properties are absent (start offset 0) or a 4-byte start offset. This
      // whole-buffer BCJ assumes start 0, so a non-zero offset is unsupported.
      if (f.props.isNotEmpty) {
        if (f.props.length != 4) {
          throw InvalidHeaderException(
            'BCJ filter start-offset property must be 4 bytes',
            format: 'xz',
            entryPath: name,
          );
        }
        final startOffset =
            f.props[0] |
            (f.props[1] << 8) |
            (f.props[2] << 16) |
            (f.props[3] << 24);
        if (startOffset != 0) {
          throw UnsupportedFeatureException(
            'BCJ x86 filter with a non-zero start offset is not supported',
            format: 'xz',
            entryPath: name,
          );
        }
      }
    default:
      throw UnsupportedCompressionException(
        'unsupported .xz filter 0x${f.id.toRadixString(16)}',
        methodName: 'xz-filter',
        methodId: f.id,
        format: 'xz',
        entryPath: name,
      );
  }
}

void _verifyCheck(
  int checkType,
  Uint8List stored,
  Uint8List data,
  String? name,
) {
  switch (checkType) {
    case 0x01: // CRC32
      final actual = Crc32.compute(data);
      final expected =
          stored[0] | (stored[1] << 8) | (stored[2] << 16) | (stored[3] << 24);
      if ((expected & 0xFFFFFFFF) != actual) {
        throw ChecksumMismatchException(
          'block CRC-32 mismatch',
          format: 'xz',
          entryPath: name,
        );
      }
    case 0x04: // CRC64
      final crc = Crc64()..add(data);
      final low =
          stored[0] | (stored[1] << 8) | (stored[2] << 16) | (stored[3] << 24);
      final high =
          stored[4] | (stored[5] << 8) | (stored[6] << 16) | (stored[7] << 24);
      if ((low & 0xFFFFFFFF) != crc.low || (high & 0xFFFFFFFF) != crc.high) {
        throw ChecksumMismatchException(
          'block CRC-64 mismatch',
          format: 'xz',
          entryPath: name,
        );
      }
    case 0x0A: // SHA-256
      final actual = Sha256.compute(data);
      var equal = actual.length == stored.length;
      for (var i = 0; equal && i < actual.length; i++) {
        equal = actual[i] == stored[i];
      }
      if (!equal) {
        throw ChecksumMismatchException(
          'block SHA-256 mismatch',
          format: 'xz',
          entryPath: name,
        );
      }
    // checkType 0x00 (None) has no bytes; unsupported ids were rejected during
    // container parsing.
  }
}

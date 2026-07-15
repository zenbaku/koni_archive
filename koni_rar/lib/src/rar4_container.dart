/// RAR4 (v1.5 container) header parsing.
///
/// Clean-room per `doc/rar-provenance.md`; block/header layout follows
/// libarchive's BSD `archive_read_support_format_rar.c` (see
/// `doc/references.md`, `NOTICE`), verified against `unrar` output.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'rar5_container.dart' show Rar5FileHeader, Rar5Toc;

/// RAR4 block types.
abstract final class Rar4BlockType {
  /// Archive marker (`Rar!\x1A\x07\x00`).
  static const int marker = 0x72;

  /// Main archive header.
  static const int main = 0x73;

  /// File header.
  static const int file = 0x74;

  /// End-of-archive header.
  static const int endArc = 0x7B;
}

const int _hdAddSizePresent = 0x8000;
const int _fhdSplitAfter = 0x0002;
const int _fhdPassword = 0x0004;
const int _fhdSolid = 0x0010;
const int _fhdLarge = 0x0100;
const int _fhdUnicode = 0x0200;
const int _fileIsDirectory = 0xE0;
const int _mhdPassword = 0x0080;
const int _dictionaryMax = 0x400000;

/// Parses a RAR4 archive's headers into the shared [Rar5FileHeader] model
/// (method 0x30 = store → 0, 0x31–0x35 → 1–5; version 29).
Future<Rar5Toc> parseRar4(ByteSource source, int signatureEnd) async {
  final files = <Rar5FileHeader>[];
  var offset = signatureEnd;

  while (offset + 7 <= source.length) {
    final head = await source.read(offset, 7);
    final flags = head[3] | (head[4] << 8);
    final headerSize = head[5] | (head[6] << 8);
    final type = head[2];
    if (headerSize < 7) {
      throw InvalidHeaderException(
        'RAR4 block header too small',
        format: 'rar',
        offset: offset,
      );
    }

    // Extra data size (packed data for FILE headers, or add-size blocks).
    var addSize = 0;
    if (flags & _hdAddSizePresent != 0) {
      if (offset + 11 > source.length) {
        throw UnexpectedEofException(
          'RAR4 add-size field past end of archive',
          format: 'rar',
          offset: offset,
        );
      }
      final ext = await source.read(offset + 7, 4);
      addSize = ext[0] | (ext[1] << 8) | (ext[2] << 16) | (ext[3] << 24);
    }

    if (type == Rar4BlockType.endArc) break;
    if (type == Rar4BlockType.main) {
      if (flags & _mhdPassword != 0) {
        return Rar5Toc(const [], true); // encrypted headers
      }
      offset += headerSize + addSize;
      continue;
    }
    if (type == Rar4BlockType.file) {
      if (offset + headerSize > source.length) {
        throw UnexpectedEofException(
          'RAR4 file header past end of archive',
          format: 'rar',
          offset: offset,
        );
      }
      final headerBytes = await source.read(offset, headerSize);
      // The packed data follows the header; its size is the header's own
      // pack_size field (the same bytes the HD_ADD_SIZE_PRESENT flag
      // points at), so the walk advances by headerSize + dataSize.
      final header = _parseFileHeader(
        headerBytes,
        flags,
        offset + headerSize, // data starts after the header
        offset,
      );
      files.add(header);
      offset += headerSize + header.dataSize;
      continue;
    }
    // Any other block: skip by header + add size.
    offset += headerSize + addSize;
  }
  return Rar5Toc(files, false);
}

Rar5FileHeader _parseFileHeader(
  Uint8List headerBytes,
  int flags,
  int dataOffset,
  int baseOffset,
) {
  // Body starts after the 7-byte common header. Field layout:
  // pack_size[4], unp_size[4], host_os[1], file_crc[4], file_time[4],
  // unp_ver[1], method[1], name_size[2], file_attr[4].
  final r = ByteReader(headerBytes)..position = 7;
  final packLow = r.readUint32le();
  final unpLow = r.readUint32le();
  final hostOs = r.readUint8();
  final crc = r.readUint32le();
  final dosTime = r.readUint32le();
  r.readUint8(); // unpack version
  final method = r.readUint8();
  final nameSize = r.readUint16le();
  final attributes = r.readUint32le();

  var packedTotal = packLow;
  var unpackedTotal = unpLow;
  if (flags & _fhdLarge != 0) {
    // High 32 bits of pack/unpack sizes.
    final packHigh = r.readUint32le();
    final unpHigh = r.readUint32le();
    packedTotal = packLow + packHigh * 0x100000000;
    unpackedTotal = unpLow + unpHigh * 0x100000000;
    if (unpackedTotal > 0x1FFFFFFFFFFFFF || packedTotal > 0x1FFFFFFFFFFFFF) {
      throw UnsupportedFeatureException(
        'RAR4 entry exceeds the supported integer range',
        format: 'rar',
        offset: baseOffset,
      );
    }
  }

  final nameBytes = r.readBytes(nameSize);
  final isUnicode = flags & _fhdUnicode != 0;
  final name = _decodeName(nameBytes, isUnicode);

  final isDirectory = (flags & _fileIsDirectory) == _fileIsDirectory;
  // Dictionary size from flag bits 5-7 (unless directory); the LZ window is
  // a power of two ≥ unpacked size, capped at 4 MiB — the reader allocates
  // the actual window.
  final windowSize =
      isDirectory
          ? 0
          : (unpackedTotal >= _dictionaryMax
              ? _dictionaryMax
              : _nextPow2(unpackedTotal));
  final unixMode = hostOs == 3 ? attributes & 0xFFFF : null;

  return Rar5FileHeader(
    name: name,
    isDirectory: isDirectory,
    isService: false,
    unpackedSize: unpackedTotal,
    dataOffset: dataOffset,
    dataSize: packedTotal,
    // 0x30 store → 0; 0x31–0x35 → 1–5.
    method: method == 0x30 ? 0 : method - 0x30,
    version: 29, // RAR4 method-29 family (distinct from RAR5's 50)
    solid: flags & _fhdSolid != 0,
    windowSize: windowSize,
    crc32: crc,
    modified: _dosTime(dosTime),
    unixMode: unixMode,
    isEncrypted: flags & _fhdPassword != 0,
    // RAR4 uses a different (non-AES-256) encryption scheme handled in
    // P3-5, not the RAR5 encryption record.
    encryption: null,
    redirectTarget: null,
    hostOs: hostOs,
    splitAfter: flags & _fhdSplitAfter != 0,
  );
}

String _decodeName(Uint8List bytes, bool unicode) {
  // RAR4 Unicode names use a custom compression scheme after a NUL
  // separator; the common (ASCII/UTF-8) case is the bytes up to any NUL.
  // For non-ASCII Unicode names we fall back to the (lossy) ASCII prefix
  // rather than mis-decode — documented in doc/notes.md.
  var end = bytes.length;
  if (unicode) {
    final nul = bytes.indexOf(0);
    if (nul >= 0) end = nul;
  }
  return utf8.decode(
    Uint8List.sublistView(bytes, 0, end),
    allowMalformed: true,
  );
}

/// DOS timestamp (local time, 2 s resolution) → UTC (documented lossiness).
DateTime? _dosTime(int dosTime) {
  if (dosTime == 0) return null;
  final date = dosTime >> 16;
  final time = dosTime & 0xFFFF;
  if (date == 0) return null;
  return DateTime.utc(
    1980 + ((date >> 9) & 0x7F),
    (date >> 5) & 0xF,
    date & 0x1F,
    (time >> 11) & 0x1F,
    (time >> 5) & 0x3F,
    (time & 0x1F) * 2,
  );
}

int _nextPow2(int value) {
  var pow = 0x10000; // 64 KiB minimum window
  while (pow < value) {
    pow <<= 1;
  }
  return pow;
}

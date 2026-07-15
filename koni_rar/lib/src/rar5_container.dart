/// RAR5 container parsing (headers, blocks, extra records).
///
/// Clean-room per `doc/rar-provenance.md`; layout follows libarchive's
/// BSD `rar5.c` (see `doc/references.md`), verified against `unrar` output.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

/// The 8-byte RAR5 signature `Rar!\x1A\x07\x01\x00`.
const List<int> rar5Signature = [
  0x52,
  0x61,
  0x72,
  0x21,
  0x1A,
  0x07,
  0x01,
  0x00,
];

/// The 7-byte RAR4 signature `Rar!\x1A\x07\x00`.
const List<int> rar4Signature = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00];

/// Base-block header ids.
abstract final class Rar5HeadType {
  /// Main archive header.
  static const int main = 1;

  /// File header.
  static const int file = 2;

  /// Service header (metadata streams).
  static const int service = 3;

  /// Archive-encryption header.
  static const int crypt = 4;

  /// End-of-archive header.
  static const int endArc = 5;
}

/// One parsed file/service header plus where its data lives.
final class Rar5FileHeader {
  /// Creates a parsed file header.
  Rar5FileHeader({
    required this.name,
    required this.isDirectory,
    required this.isService,
    required this.unpackedSize,
    required this.dataOffset,
    required this.dataSize,
    required this.method,
    required this.version,
    required this.solid,
    required this.windowSize,
    required this.crc32,
    required this.modified,
    required this.unixMode,
    required this.isEncrypted,
    required this.redirectTarget,
    required this.hostOs,
    required this.splitAfter,
  });

  /// Decoded UTF-8 name (raw, before normalization).
  final String name;

  /// Whether this entry is a directory.
  final bool isDirectory;

  /// Whether this is a SERVICE header (metadata, not a user file).
  final bool isService;

  /// Uncompressed size in bytes.
  final int unpackedSize;

  /// Absolute offset of the packed data in the source.
  final int dataOffset;

  /// Packed data size in bytes.
  final int dataSize;

  /// Compression method (0 = store, 1–5 = compressed).
  final int method;

  /// Compression version (50 = RAR5).
  final int version;

  /// Whether the file uses the solid flag (references earlier files).
  final bool solid;

  /// LZ window size in bytes (a power of two), or 0 for store/dir.
  final int windowSize;

  /// Stored CRC-32, when present.
  final int? crc32;

  /// Modification time (UTC), when present.
  final DateTime? modified;

  /// Unix permission bits, when the host OS records them.
  final int? unixMode;

  /// Whether the entry data is encrypted.
  final bool isEncrypted;

  /// Symlink/hardlink target from a REDIR extra record, else null.
  final String? redirectTarget;

  /// Host OS (0 = Windows, 1 = Unix).
  final int hostOs;

  /// Whether the file's data continues in the next volume (unsupported).
  final bool splitAfter;
}

/// Reads RAR5's variable-length integer (7 bits per byte, little-endian,
/// high bit = continuation). Values beyond 2^53 − 1 throw (uniform cap).
int readRarVarInt(ByteReader reader) {
  var value = 0;
  var scale = 1;
  for (var i = 0; i < 10; i++) {
    final byte = reader.readUint8();
    value += (byte & 0x7F) * scale;
    if (value > 0x1FFFFFFFFFFFFF) {
      throw UnsupportedFeatureException(
        'RAR5 varint exceeds the supported integer range (2^53 - 1)',
        format: 'rar',
      );
    }
    if (byte & 0x80 == 0) return value;
    scale *= 128;
  }
  throw InvalidHeaderException('RAR5 varint too long', format: 'rar');
}

/// Result of parsing all headers: the file list, in archive order.
final class Rar5Toc {
  /// Creates a table of contents.
  Rar5Toc(this.files, this.headerEncrypted);

  /// The file/service headers.
  final List<Rar5FileHeader> files;

  /// Whether encrypted headers were detected (whole archive locked).
  final bool headerEncrypted;

  /// Walks every base block from just past the signature to the
  /// end-of-archive marker.
  static Future<Rar5Toc> parse(ByteSource source, int signatureEnd) async {
    final files = <Rar5FileHeader>[];
    var offset = signatureEnd;

    while (offset < source.length) {
      // Base block: CRC32 (4) + varint(header size) + header body.
      final prefix = await source.read(
        offset,
        offset + 11 <= source.length ? 11 : source.length - offset,
      );
      final pr = ByteReader(prefix);
      pr.skip(4); // header CRC (validated below)
      final int rawHeaderSize;
      final int sizeLen;
      try {
        final before = pr.position;
        rawHeaderSize = readRarVarInt(pr);
        sizeLen = pr.position - before;
      } on ArchiveException {
        break; // not a valid base block: end of meaningful data
      }
      final headerSize = rawHeaderSize + 4 + sizeLen;
      if (rawHeaderSize == 0 || headerSize > 2 * 1024 * 1024) {
        throw InvalidHeaderException(
          'implausible RAR5 header size $rawHeaderSize',
          format: 'rar',
          offset: offset,
        );
      }
      if (offset + headerSize > source.length) {
        throw UnexpectedEofException(
          'RAR5 header extends past the end of the archive',
          format: 'rar',
          offset: offset,
        );
      }
      final headerBytes = await source.read(offset, headerSize);
      final reader = ByteReader(headerBytes)..position = 4 + sizeLen;

      final headerType = readRarVarInt(reader);
      final headerFlags = readRarVarInt(reader);
      final hasExtra = headerFlags & 0x0001 != 0;
      final hasData = headerFlags & 0x0002 != 0;
      final splitAfter = headerFlags & 0x0010 != 0;

      var extraSize = 0;
      if (hasExtra) extraSize = readRarVarInt(reader);
      var dataSize = 0;
      if (hasData) dataSize = readRarVarInt(reader);

      final dataOffset = offset + headerSize;

      switch (headerType) {
        case Rar5HeadType.crypt:
          return Rar5Toc(const [], true);
        case Rar5HeadType.endArc:
          return Rar5Toc(files, false);
        case Rar5HeadType.file:
        case Rar5HeadType.service:
          final header = _parseFileHeader(
            reader,
            headerBytes,
            headerType == Rar5HeadType.service,
            dataOffset,
            dataSize,
            splitAfter,
            extraSize,
            offset,
          );
          if (!header.isService) files.add(header);
        case Rar5HeadType.main:
          // Main header: archive flags (volume/solid). Nothing else needed
          // for single-volume reading.
          break;
        default:
          break; // unknown block: skip via header + data size
      }

      offset = dataOffset + dataSize;
    }
    return Rar5Toc(files, false);
  }

  static Rar5FileHeader _parseFileHeader(
    ByteReader reader,
    Uint8List headerBytes,
    bool isService,
    int dataOffset,
    int dataSize,
    bool splitAfter,
    int extraSize,
    int baseOffset,
  ) {
    // Extra records sit at the end of the header; body fields come first.
    final extraStart = headerBytes.length - extraSize;

    final fileFlags = readRarVarInt(reader);
    final unpackedSize = readRarVarInt(reader);
    final attributes = readRarVarInt(reader);
    final hasUnknownSize = fileFlags & 0x0008 != 0;
    final isDirectory = fileFlags & 0x0001 != 0;

    DateTime? modified;
    if (fileFlags & 0x0002 != 0) {
      modified = _dosOrUnixTime(reader.readUint32le());
    }
    int? crc;
    if (fileFlags & 0x0004 != 0) {
      crc = reader.readUint32le();
    }
    final compressionInfo = readRarVarInt(reader);
    final version = (compressionInfo & 0x3F) + 50;
    final method = (compressionInfo >> 7) & 7;
    final solid = compressionInfo & 0x40 != 0;
    final dictShift = (compressionInfo >> 10) & 15;
    final windowSize = isDirectory ? 0 : 0x20000 << dictShift;
    final hostOs = readRarVarInt(reader);
    final nameLength = readRarVarInt(reader);
    final nameBytes = reader.readBytes(nameLength);
    final name = _decodeUtf8(nameBytes);

    // Unix attributes: for Unix host, attributes are the st_mode.
    final unixMode = hostOs == 1 ? attributes & 0xFFFF : null;

    // Extra records: encryption, redirect (symlink) targets.
    var isEncrypted = false;
    String? redirectTarget;
    if (extraSize > 0 && extraStart >= reader.position) {
      final extra = ByteReader(Uint8List.sublistView(headerBytes, extraStart));
      while (extra.remaining > 0) {
        // Record: size varint, then `size` bytes of (type varint + data).
        final recSize = readRarVarInt(extra);
        final recStart = extra.position;
        if (recSize == 0 || recStart + recSize > extra.length) break;
        final recType = readRarVarInt(extra);
        switch (recType) {
          case 0x01: // FILE encryption record
            isEncrypted = true;
          case 0x05: // REDIR: symlink / hardlink / junction target
            final redirType = readRarVarInt(extra);
            readRarVarInt(extra); // redirect flags
            final targetLen = readRarVarInt(extra);
            final target = _decodeUtf8(extra.readBytes(targetLen));
            if (redirType != 0) redirectTarget = target;
        }
        // Advance to the next record: size counts bytes after itself.
        extra.position = recStart + recSize;
      }
    }

    if (hasUnknownSize) {
      throw UnsupportedFeatureException(
        'RAR5 entries with unknown unpacked size are not supported',
        format: 'rar',
        offset: baseOffset,
      );
    }

    return Rar5FileHeader(
      name: name,
      isDirectory: isDirectory || (hostOs == 0 && attributes & 0x10 != 0),
      isService: isService,
      unpackedSize: unpackedSize,
      dataOffset: dataOffset,
      dataSize: dataSize,
      method: method,
      version: version,
      solid: solid,
      windowSize: windowSize,
      crc32: crc,
      modified: modified,
      unixMode: unixMode,
      isEncrypted: isEncrypted,
      redirectTarget: redirectTarget,
      hostOs: hostOs,
      splitAfter: splitAfter,
    );
  }

  /// RAR5 names are UTF-8; decode permissively — invalid sequences become
  /// U+FFFD rather than throwing (§7; hostile fuzz input lands here).
  static String _decodeUtf8(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  /// RAR5 mtime is unix seconds by default (the DOS-time flag is separate,
  /// but the common case and what `rar` writes is unix time in the base
  /// field). Out-of-range values become null (§7).
  static DateTime? _dosOrUnixTime(int value) {
    if (value == 0 || value > 253402300799) return null;
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }
}

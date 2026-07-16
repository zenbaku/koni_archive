/// RAR4 (v1.5 container) header parsing.
///
/// Clean-room per `doc/rar-provenance.md`; block/header layout follows
/// libarchive's BSD `archive_read_support_format_rar.c` (see
/// `doc/references.md`, `NOTICE`), verified against `unrar` output.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/crypto.dart';

import 'rar5_container.dart' show Rar5FileHeader, Rar5Toc;
import 'rar_crypto.dart';

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
const int _fhdSplitBefore = 0x0001;
const int _fhdSplitAfter = 0x0002;
const int _fhdPassword = 0x0004;
const int _fhdSolid = 0x0010;
const int _fhdLarge = 0x0100;
const int _fhdUnicode = 0x0200;
const int _fhdSalt = 0x0400;
const int _fileIsDirectory = 0xE0;
const int _mhdVolume = 0x0001;
const int _mhdPassword = 0x0080;
const int _dictionaryMax = 0x400000;

/// Parses a RAR4 archive's headers into the shared [Rar5FileHeader] model
/// (method 0x30 = store → 0, 0x31–0x35 → 1–5; version 29).
///
/// When the main header sets the `-hp` (encrypted-headers) flag and a
/// [password] is supplied, every following block header is decrypted before
/// parsing (see [_parseRar4EncryptedHeaders]); without a password the returned
/// TOC is flagged [Rar5Toc.headerEncrypted] with no files, and the caller
/// reports the locked archive.
Future<Rar5Toc> parseRar4(
  ByteSource source,
  int signatureEnd, {
  String? password,
}) async {
  final files = <Rar5FileHeader>[];
  var offset = signatureEnd;
  var isVolume = false;

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
      isVolume = flags & _mhdVolume != 0;
      if (flags & _mhdPassword != 0) {
        // `-hp`: the main header is plaintext (it carries this flag), but
        // every block after it is AES-encrypted. Without a password we can
        // only report that the archive is locked.
        if (password == null) return Rar5Toc(const [], true);
        return _parseRar4EncryptedHeaders(
          source,
          offset + headerSize + addSize,
          password,
          isVolume: isVolume,
        );
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
  return Rar5Toc(files, false, isVolume: isVolume);
}

/// Walks the AES-encrypted block headers of a `-hp` RAR4 archive, starting at
/// [startOffset] (just past the plaintext main header). Each block is stored
/// as `salt[8] · AES-128-CBC(header padded to 16)`; the salt is the same value
/// repeated before every block, and each block's cipher is (re)initialised with
/// the salt-derived IV — CBC chains only *within* a block, not across them
/// (matching the BSD `rardecode`'s per-block decrypt reader, `doc/references.md`).
///
/// File *data* between headers stays encrypted under each file's own salt
/// (the SALT flag in its now-decrypted header) and is decrypted later by the
/// reader's `-p` path — nothing extra to do here.
///
/// RAR4 has no password-check value, so a wrong password is detected by the
/// header CRC: the first block failing to decrypt to a valid header
/// ([InvalidPasswordException]) is almost always a bad password (a 16-bit CRC
/// cannot fully separate that from corruption). A later block failing after
/// the first decoded cleanly is corruption ([InvalidHeaderException]).
Future<Rar5Toc> _parseRar4EncryptedHeaders(
  ByteSource source,
  int startOffset,
  String password, {
  required bool isVolume,
}) async {
  final files = <Rar5FileHeader>[];
  // The salt is repeated verbatim before every block, so memoize the (costly,
  // 0x40000-round SHA-1) key derivation by salt.
  final keyCache = <String, Rar4Keys>{};
  var offset = startOffset;
  var isFirstBlock = true;

  while (offset + 8 <= source.length) {
    final saltStart = offset;
    final salt = Uint8List.fromList(await source.read(saltStart, 8));
    final keys = keyCache[_hex(salt)] ??= Rar4Keys.derive(password, salt);
    final encStart = saltStart + 8;

    // A block needs at least one 16-byte AES block for its (padded) header.
    if (encStart + 16 > source.length) {
      if (isFirstBlock) {
        throw InvalidPasswordException(
          'RAR4 encrypted headers: wrong password or corrupt archive',
          format: 'rar',
          offset: saltStart,
        );
      }
      break; // truncated tail after a clean run of headers
    }

    // Decrypt the first block to learn the header size, then continue the same
    // CBC chain for the rest of the (padded) header.
    final cbc = AesCbcDecryptor(Aes(keys.aesKey), keys.iv);
    final first = Uint8List.fromList(await source.read(encStart, 16));
    cbc.decryptInPlace(first);
    final storedCrc = first[0] | (first[1] << 8);
    final type = first[2];
    final blockFlags = first[3] | (first[4] << 8);
    final headerSize = first[5] | (first[6] << 8);
    final padded = (headerSize + 15) & ~15;

    if (headerSize < 7 || encStart + padded > source.length) {
      if (isFirstBlock) {
        throw InvalidPasswordException(
          'RAR4 encrypted headers: wrong password or corrupt archive',
          format: 'rar',
          offset: saltStart,
        );
      }
      throw InvalidHeaderException(
        'RAR4 encrypted block header size $headerSize is invalid',
        format: 'rar',
        offset: saltStart,
      );
    }

    final headerBytes = Uint8List(padded)..setRange(0, 16, first);
    if (padded > 16) {
      final rest = Uint8List.fromList(
        await source.read(encStart + 16, padded - 16),
      );
      cbc.decryptInPlace(rest);
      headerBytes.setRange(16, padded, rest);
    }

    // The stored CRC covers the unpadded header body (bytes 2..headerSize).
    final calcCrc =
        Crc32.compute(Uint8List.sublistView(headerBytes, 2, headerSize)) &
        0xFFFF;
    if (calcCrc != storedCrc) {
      if (isFirstBlock) {
        throw InvalidPasswordException(
          'RAR4 encrypted headers: wrong password or corrupt archive',
          format: 'rar',
          offset: saltStart,
        );
      }
      throw InvalidHeaderException(
        'RAR4 encrypted block header CRC mismatch',
        format: 'rar',
        offset: saltStart,
      );
    }
    isFirstBlock = false;

    if (type == Rar4BlockType.endArc) break;

    // Data (if any) follows the padded header, at a real source offset.
    final dataOffset = encStart + padded;
    if (type == Rar4BlockType.file) {
      final header = _parseFileHeader(
        Uint8List.sublistView(headerBytes, 0, headerSize),
        blockFlags,
        dataOffset,
        saltStart,
      );
      files.add(header);
      offset = dataOffset + header.dataSize;
      continue;
    }

    // Any other block: skip its header and, when present, its add-size data.
    var addSize = 0;
    if (blockFlags & _hdAddSizePresent != 0 && headerSize >= 11) {
      addSize =
          headerBytes[7] |
          (headerBytes[8] << 8) |
          (headerBytes[9] << 16) |
          (headerBytes[10] << 24);
    }
    offset = dataOffset + addSize;
  }

  // headerEncrypted stays true (the archive *had* encrypted headers); the
  // populated file list signals a successful decrypt, mirroring RAR5.
  return Rar5Toc(files, true, isVolume: isVolume);
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

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
  final unpackVersion = r.readUint8();
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

  // The 8-byte encryption salt follows the name when the SALT flag is set.
  Uint8List? rar4Salt;
  if (flags & _fhdSalt != 0) {
    rar4Salt = Uint8List.fromList(r.readBytes(8));
  }

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
    version:
        29, // RAR4 family marker (decoder dispatch; distinct from RAR5's 50)
    unpackVersion: unpackVersion, // raw byte: 15/20/26/29/36

    solid: flags & _fhdSolid != 0,
    windowSize: windowSize,
    crc32: crc,
    modified: _dosTime(dosTime),
    unixMode: unixMode,
    isEncrypted: flags & _fhdPassword != 0,
    // RAR4 uses its own SHA-1-KDF + AES-128 scheme (rar_crypto.dart), keyed
    // by the header salt below — not the RAR5 encryption record.
    encryption: null,
    rar4Salt: rar4Salt,
    redirectTarget: null,
    hostOs: hostOs,
    splitAfter: flags & _fhdSplitAfter != 0,
    splitBefore: flags & _fhdSplitBefore != 0,
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

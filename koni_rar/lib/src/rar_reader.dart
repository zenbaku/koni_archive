import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'rar4_container.dart';
import 'rar4_decoder.dart';
import 'rar5_container.dart';
import 'rar5_decoder.dart';

/// Chunk size for slicing decoded output.
const int _readChunkSize = 64 * 1024;

/// Cap on a single decoded file / solid run (§7).
const int _maxFileSize = 1024 * 1024 * 1024;

/// Reader for RAR5 and RAR4 archives (and CBR comics). Created via
/// `RarFormat.openReader`. RAR5 handles store + methods 1–5 (solid and
/// non-solid); RAR4 handles store + method-29 (non-solid). PPMd, RarVM
/// filters, and solid RAR4 surface as typed errors (see `doc/features.md`).
final class RarReader extends ArchiveReader {
  RarReader._(this.format, this._source, this._options, this._headers)
    : entries = List.unmodifiable([for (final h in _headers) _toEntry(h)]) {
    for (var i = 0; i < entries.length; i++) {
      _indexOf[entries[i]] = i;
    }
  }

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final ByteSource _source;
  final ArchiveReadOptions _options;
  final List<Rar5FileHeader> _headers;
  final Expando<int> _indexOf = Expando<int>();

  // Decoded solid run: the shared window decoder plus which file indices it
  // already covers. A jump backwards rebuilds from the run start.
  Rar5Decoder? _solidDecoder;
  int _solidNextIndex = 0;
  bool _closed = false;

  /// Parses the container (RAR5 or RAR4, per [isRar4]). Headers are
  /// plaintext unless whole-archive encryption is used; O(entry count), no
  /// content decode (§4).
  static Future<RarReader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options, {
    required bool isRar4,
  }) async {
    final toc =
        isRar4
            ? await parseRar4(source, 7) // RAR4 signature is 7 bytes
            : await Rar5Toc.parse(source, 8);
    if (toc.headerEncrypted) {
      throw EncryptedArchiveException(
        'the archive uses encrypted headers; not supported (§15)',
        format: 'rar',
      );
    }
    return RarReader._(format, source, options, toc.files);
  }

  static ArchiveEntry _toEntry(Rar5FileHeader h) {
    final normalized = normalizeEntryPath(h.name);
    final isSymlink = h.redirectTarget != null;
    return ArchiveEntry(
      path: normalized.path,
      pathEscapedRoot: normalized.escapedRoot,
      type:
          h.isDirectory
              ? ArchiveEntryType.directory
              : isSymlink
              ? ArchiveEntryType.symlink
              : ArchiveEntryType.file,
      uncompressedSize: h.unpackedSize,
      compressedSize: h.dataSize,
      compression:
          h.method == 0
              ? ArchiveCompression.stored
              : const ArchiveCompression.unknown(0x50), // RAR5 LZ ("rar5")
      modified: h.modified,
      posixMode: h.unixMode == null ? null : h.unixMode! & 0xFFF,
      crc32: h.crc32,
      isEncrypted: h.isEncrypted,
      linkTarget: h.redirectTarget,
    );
  }

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    final index = _indexOf[entry];
    if (index == null) {
      throw ArgumentError.value(entry, 'entry', 'not an entry of this archive');
    }
    final header = _headers[index];

    if (header.isEncrypted) {
      throw EncryptedArchiveException(
        'entry is encrypted (-p); decryption is not supported (§15)',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    if (header.splitAfter) {
      throw UnsupportedFeatureException(
        'multi-volume archives are not supported',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    if (header.version != 50 && header.version != 29) {
      throw UnsupportedFeatureException(
        'unsupported RAR compression version ${header.version}',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    if (header.isDirectory) {
      return const Stream<Uint8List>.empty();
    }
    if (header.unpackedSize > _maxFileSize) {
      throw CorruptArchiveException(
        'file claims implausible size ${header.unpackedSize}',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    return _streamEntry(index, header, entry);
  }

  Stream<Uint8List> _streamEntry(
    int index,
    Rar5FileHeader header,
    ArchiveEntry entry,
  ) async* {
    final Uint8List decoded;
    try {
      decoded = await _decodeToBytes(index, header, entry.path);
    } on FormatException catch (e) {
      // A decoder feature we deliberately defer (RarVM filters, PPMd)
      // surfaces as an unsupported-feature error, not corruption (§8/§9),
      // so one such entry never implies the archive is damaged.
      if (e.message.contains('not supported')) {
        throw UnsupportedFeatureException(
          e.message,
          format: 'rar',
          entryPath: entry.path,
        );
      }
      throw CorruptArchiveException(
        'bad compressed data: ${e.message}',
        format: 'rar',
        entryPath: entry.path,
      );
    }
    if (_options.verifyChecksums && header.crc32 != null) {
      final actual = Crc32.compute(decoded);
      if (actual != header.crc32) {
        throw ChecksumMismatchException(
          'CRC-32 mismatch: archive records '
          '0x${header.crc32!.toRadixString(16)}, content is '
          '0x${actual.toRadixString(16)}',
          expected: header.crc32,
          actual: actual,
          format: 'rar',
          entryPath: entry.path,
        );
      }
    }
    var position = 0;
    while (position < decoded.length) {
      if (_closed) {
        throw ArchiveClosedException(
          'archive was closed while streaming entry',
          format: 'rar',
          entryPath: entry.path,
        );
      }
      final end =
          position + _readChunkSize < decoded.length
              ? position + _readChunkSize
              : decoded.length;
      yield Uint8List.sublistView(decoded, position, end);
      position = end;
    }
  }

  /// Returns the decoded content of file [index].
  Future<Uint8List> _decodeToBytes(
    int index,
    Rar5FileHeader header,
    String entryPath,
  ) async {
    final data = await _readData(header);
    if (header.method == 0) {
      // Stored: data is the content (solid store still just concatenates).
      if (data.length != header.unpackedSize) {
        throw const FormatException('stored RAR5 entry size mismatch');
      }
      return data;
    }

    if (!header.solid) {
      // The LZ window must be a power of two (indices use `& mask`), and
      // big enough that the whole file fits without wrapping — so no byte
      // is overwritten before it is read out.
      final windowLen = _pow2Ceil(
        header.unpackedSize > header.windowSize
            ? header.unpackedSize
            : header.windowSize,
      );
      final output = Uint8List(windowLen);
      if (header.version == 29) {
        Rar4Decoder(output).decompressFile(data, header.unpackedSize);
      } else {
        Rar5Decoder(output).decompressFile(data, header.unpackedSize);
      }
      return Uint8List.sublistView(output, 0, header.unpackedSize);
    }

    // Solid RAR4 uses persistent cross-file table state that differs from
    // RAR5; it is a documented deferral (§8) — real-world CBRs are
    // non-solid. Solid RAR5 is fully supported below.
    if (header.version == 29) {
      throw UnsupportedFeatureException(
        'solid RAR4 archives are not supported yet',
        format: 'rar',
        entryPath: entryPath,
      );
    }
    // Solid RAR5: decode from the run start into a shared window, keeping
    // every file's output so a later (or repeat) read is a slice.
    return _decodeSolid(index, header, entryPath);
  }

  // Cache of decoded solid-file outputs by index (within the current run).
  final Map<int, Uint8List> _solidOutputs = {};

  Future<Uint8List> _decodeSolid(
    int index,
    Rar5FileHeader header,
    String entryPath,
  ) async {
    if (_solidOutputs.containsKey(index)) return _solidOutputs[index]!;

    // Find the start of this solid run (first file at/after the previous
    // non-solid boundary).
    var runStart = index;
    while (runStart > 0 && _headers[runStart].solid) {
      runStart--;
    }

    // (Re)build the run if our decoder is not positioned to continue.
    if (_solidDecoder == null || _solidNextIndex != runStart) {
      final windowSize = _runWindowSize(runStart);
      _solidDecoder = Rar5Decoder(Uint8List(windowSize));
      _solidNextIndex = runStart;
      _solidOutputs.clear();
    }
    final decoder = _solidDecoder!;
    final mask = decoder.output.length - 1;

    for (var i = _solidNextIndex; i <= index; i++) {
      final h = _headers[i];
      if (h.method == 0 || h.isDirectory) {
        // A stored or empty member inside a solid run: append raw.
        final raw = await _readData(h);
        final start = decoder.writePtr;
        for (var j = 0; j < raw.length; j++) {
          decoder.output[(start + j) & mask] = raw[j];
        }
        decoder.writePtr += raw.length;
        _solidOutputs[i] = _extractWindow(decoder, start, raw.length, mask);
      } else {
        final start = decoder.writePtr;
        decoder.beginFileFilters();
        decoder.decompressFile(await _readData(h), h.unpackedSize);
        _solidOutputs[i] = _extractWindow(decoder, start, h.unpackedSize, mask);
      }
    }
    _solidNextIndex = index + 1;
    return _solidOutputs[index]!;
  }

  Uint8List _extractWindow(
    Rar5Decoder decoder,
    int start,
    int length,
    int mask,
  ) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = decoder.output[(start + i) & mask];
    }
    return out;
  }

  int _runWindowSize(int runStart) {
    var size = _headers[runStart].windowSize;
    for (var i = runStart + 1; i < _headers.length && _headers[i].solid; i++) {
      if (_headers[i].windowSize > size) size = _headers[i].windowSize;
    }
    return _pow2Ceil(size < 0x20000 ? 0x20000 : size);
  }

  static int _pow2Ceil(int value) {
    var pow = 0x20000;
    while (pow < value) {
      pow <<= 1;
    }
    return pow;
  }

  Future<Uint8List> _readData(Rar5FileHeader header) async {
    if (header.dataSize == 0) return Uint8List(0);
    if (header.dataOffset + header.dataSize > _source.length) {
      throw UnexpectedEofException(
        'entry data extends past the end of the archive',
        format: 'rar',
        offset: header.dataOffset,
      );
    }
    return _source.read(header.dataOffset, header.dataSize);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _solidDecoder = null;
    _solidOutputs.clear();
  }
}

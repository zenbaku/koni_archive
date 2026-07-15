import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

import 'structures.dart';

/// Chunk size for streaming entry content out of the source.
const int _readChunkSize = 64 * 1024;

/// Reader for ZIP archives (and CBZ comics). Created via
/// `ZipFormat.openReader`.
final class ZipReader extends ArchiveReader {
  ZipReader._(this.format, this._source, this._options, this._central)
    : entries = List.unmodifiable([for (final c in _central) c.entry]) {
    for (var i = 0; i < _central.length; i++) {
      _indexOf[_central[i].entry] = i;
    }
  }

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final ByteSource _source;
  final ArchiveReadOptions _options;
  final List<CentralEntry> _central;
  final Expando<int> _indexOf = Expando<int>();
  bool _closed = false;

  /// Locates the end-of-central-directory record (backward scan, §5) and
  /// parses the central directory eagerly — O(entry count), no content
  /// reads (§4). Local headers are validated lazily at [openRead].
  static Future<ZipReader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    final eocd = await Eocd.find(source);
    final central = await CentralEntry.parseDirectory(source, eocd, options);
    return ZipReader._(format, source, options, central);
  }

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    final index = _indexOf[entry];
    if (index == null) {
      throw ArgumentError.value(entry, 'entry', 'not an entry of this archive');
    }
    final central = _central[index];

    // Entry-scoped failures surface here, never at open (§9): one exotic
    // entry must not brick the archive.
    if (entry.isEncrypted) {
      throw EncryptedArchiveException(
        central.methodId == 99
            ? 'entry is AES-encrypted (method 99)'
            : 'entry is encrypted (traditional PKWARE encryption)',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    switch (central.methodId) {
      case 0:
        if (entry.uncompressedSize != central.compressedSize) {
          throw CorruptArchiveException(
            'stored entry sizes disagree '
            '(compressed ${central.compressedSize}, '
            'uncompressed ${entry.uncompressedSize})',
            format: 'zip',
            entryPath: entry.path,
          );
        }
        return _streamStored(central, entry);
      case 8:
        return _streamDeflated(central, entry);
      default:
        throw UnsupportedCompressionException(
          'compression method "${entry.compression.name}" '
          '(id ${central.methodId}) is not supported',
          methodName: entry.compression.name,
          methodId: central.methodId,
          format: 'zip',
          entryPath: entry.path,
        );
    }
  }

  Stream<Uint8List> _streamStored(
    CentralEntry central,
    ArchiveEntry entry,
  ) async* {
    final dataOffset = await _dataOffset(central, entry);
    if (dataOffset + central.compressedSize > _source.length) {
      throw UnexpectedEofException(
        'entry data extends past the end of the archive',
        format: 'zip',
        offset: dataOffset,
        entryPath: entry.path,
      );
    }
    final crc =
        _options.verifyChecksums && entry.crc32 != null ? Crc32() : null;
    var remaining = central.compressedSize;
    var offset = dataOffset;
    while (remaining > 0) {
      if (_closed) {
        throw ArchiveClosedException(
          'archive was closed while streaming entry',
          format: 'zip',
          entryPath: entry.path,
        );
      }
      final chunkSize = remaining < _readChunkSize ? remaining : _readChunkSize;
      final chunk = await _source.read(offset, chunkSize);
      crc?.add(chunk);
      offset += chunkSize;
      remaining -= chunkSize;
      yield chunk;
    }
    if (crc != null && crc.value != entry.crc32) {
      throw ChecksumMismatchException(
        'CRC-32 mismatch: archive records '
        '0x${entry.crc32!.toRadixString(16)}, content is '
        '0x${crc.value.toRadixString(16)}',
        expected: entry.crc32,
        actual: crc.value,
        format: 'zip',
        entryPath: entry.path,
      );
    }
  }

  Stream<Uint8List> _streamDeflated(
    CentralEntry central,
    ArchiveEntry entry,
  ) async* {
    final dataOffset = await _dataOffset(central, entry);
    if (dataOffset + central.compressedSize > _source.length) {
      throw UnexpectedEofException(
        'entry data extends past the end of the archive',
        format: 'zip',
        offset: dataOffset,
        entryPath: entry.path,
      );
    }
    final crc =
        _options.verifyChecksums && entry.crc32 != null ? Crc32() : null;
    final pending = <Uint8List>[];
    var producedTotal = 0;
    final inflater = RawInflater(
      onOutput: (chunk) {
        producedTotal += chunk.length;
        crc?.add(chunk);
        pending.add(chunk);
      },
    );

    var remaining = central.compressedSize;
    var offset = dataOffset;
    try {
      while (remaining > 0 && !inflater.isFinished) {
        if (_closed) {
          throw ArchiveClosedException(
            'archive was closed while streaming entry',
            format: 'zip',
            entryPath: entry.path,
          );
        }
        final chunkSize =
            remaining < _readChunkSize ? remaining : _readChunkSize;
        final chunk = await _source.read(offset, chunkSize);
        offset += chunkSize;
        remaining -= chunkSize;
        inflater.addInput(chunk);
        // Decompression-bomb guard (§7): decoded output beyond the claimed
        // uncompressed size is a typed error, detected before buffering
        // grows further.
        if (producedTotal > entry.uncompressedSize) {
          throw SizeLimitExceededException(
            'decoded output exceeds the claimed uncompressed size '
            '(${entry.uncompressedSize} bytes)',
            limit: entry.uncompressedSize,
            format: 'zip',
            entryPath: entry.path,
          );
        }
        for (final decoded in pending) {
          yield decoded;
        }
        pending.clear();
      }
      inflater.finish(); // throws FormatException when truncated
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad deflate stream: ${e.message}',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    for (final decoded in pending) {
      yield decoded;
    }
    if (producedTotal != entry.uncompressedSize) {
      throw CorruptArchiveException(
        'decoded $producedTotal byte(s), central directory claims '
        '${entry.uncompressedSize}',
        format: 'zip',
        entryPath: entry.path,
      );
    }
    if (crc != null && crc.value != entry.crc32) {
      throw ChecksumMismatchException(
        'CRC-32 mismatch: archive records '
        '0x${entry.crc32!.toRadixString(16)}, content is '
        '0x${crc.value.toRadixString(16)}',
        expected: entry.crc32,
        actual: crc.value,
        format: 'zip',
        entryPath: entry.path,
      );
    }
  }

  /// Reads and validates the local file header; the content starts after
  /// its (independently sized) name and extra fields.
  Future<int> _dataOffset(CentralEntry central, ArchiveEntry entry) async {
    final header = await _source.read(central.localHeaderOffset, 30);
    final reader = ByteReader(header, baseOffset: central.localHeaderOffset);
    if (reader.readUint32le() != localHeaderSignature) {
      throw CorruptArchiveException(
        'central directory points at offset ${central.localHeaderOffset}, '
        'but there is no local file header there',
        format: 'zip',
        offset: central.localHeaderOffset,
        entryPath: entry.path,
      );
    }
    reader.position = 26;
    final nameLength = reader.readUint16le();
    final extraLength = reader.readUint16le();
    return central.localHeaderOffset + 30 + nameLength + extraLength;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

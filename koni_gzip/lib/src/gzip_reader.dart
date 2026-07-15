import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

/// Source-read chunk size. Kept moderate: one compressed chunk can expand
/// up to ~1000x, and expansion is buffered until yielded.
const int _readChunkSize = 16 * 1024;

/// Reader presenting a gzip file as a single-entry archive (§8). Created
/// via `GzipFormat.openReader`.
final class GzipReader extends ArchiveReader {
  GzipReader._(this.format, this._source, this._options, this.entries);

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final ByteSource _source;
  final ArchiveReadOptions _options;
  bool _closed = false;

  /// Parses the member header (start) and trailer (last 8 bytes) — no
  /// content decode (§4).
  static Future<GzipReader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    final headBytes = await source.read(
      0,
      source.length < 64 * 1024 ? source.length : 64 * 1024,
    );
    final GzipMemberHeader header;
    try {
      final parsed = tryParseGzipHeader(
        headBytes,
        verifyHeaderCrc: options.verifyChecksums,
      );
      if (parsed == null) {
        throw UnexpectedEofException(
          'gzip member header extends past the end of the file',
          format: 'gzip',
          offset: headBytes.length,
        );
      }
      header = parsed.$1;
    } on FormatException catch (e) {
      throw InvalidHeaderException(e.message, format: 'gzip', offset: 0);
    }

    if (source.length < 20) {
      throw UnexpectedEofException(
        'too short to be a complete gzip file (${source.length} bytes)',
        format: 'gzip',
      );
    }
    // Trailer of the *last* member: CRC-32 and ISIZE (mod 2^32). For
    // multi-member files this reflects only the last member — see
    // doc/notes.md; per-member integrity is still verified while reading.
    final trailer = await source.read(source.length - 8, 8);
    final crc32 =
        trailer[0] |
        (trailer[1] << 8) |
        (trailer[2] << 16) |
        (trailer[3] << 24);
    final isize =
        trailer[4] |
        (trailer[5] << 8) |
        (trailer[6] << 16) |
        (trailer[7] << 24);

    final normalized = normalizeEntryPath(
      header.fileName ?? _nameFromSource(source.name),
    );
    final entry = ArchiveEntry(
      path: normalized.path.isEmpty ? 'data' : normalized.path,
      pathEscapedRoot: normalized.escapedRoot,
      type: ArchiveEntryType.file,
      uncompressedSize: isize,
      compressedSize: source.length,
      compression: ArchiveCompression.deflate,
      modified: header.modified,
      crc32: crc32,
    );
    return GzipReader._(format, source, options, List.unmodifiable([entry]));
  }

  /// Derives the entry name from the container name (§8): basename with a
  /// trailing `.gz` dropped (`comics.gz` → `comics`); `data` as the last
  /// resort.
  static String _nameFromSource(String? sourceName) {
    if (sourceName == null || sourceName.isEmpty) return 'data';
    var base = sourceName.replaceAll(r'\', '/');
    final slash = base.lastIndexOf('/');
    if (slash >= 0) base = base.substring(slash + 1);
    if (base.toLowerCase().endsWith('.gz')) {
      base = base.substring(0, base.length - 3);
    }
    return base.isEmpty ? 'data' : base;
  }

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    if (entry != entries.single) {
      throw ArgumentError.value(entry, 'entry', 'not an entry of this archive');
    }
    return _decode(entry);
  }

  Stream<Uint8List> _decode(ArchiveEntry entry) async* {
    final pending = <Uint8List>[];
    final decoder = RawGzipDecoder(
      onOutput: pending.add,
      verifyChecksums: _options.verifyChecksums,
    );
    var offset = 0;
    try {
      while (offset < _source.length) {
        if (_closed) {
          throw ArchiveClosedException(
            'archive was closed while streaming entry',
            format: 'gzip',
            entryPath: entry.path,
          );
        }
        final chunkSize =
            _source.length - offset < _readChunkSize
                ? _source.length - offset
                : _readChunkSize;
        decoder.addInput(await _source.read(offset, chunkSize));
        offset += chunkSize;
        for (final chunk in pending) {
          yield chunk;
        }
        pending.clear();
      }
      decoder.finish();
      for (final chunk in pending) {
        yield chunk;
      }
    } on FormatException catch (e) {
      throw _translate(e, entry.path);
    }
  }

  /// Codec errors are [FormatException] (§6.4); the archive layer owns the
  /// typed hierarchy.
  ArchiveException _translate(FormatException e, String entryPath) {
    final message = e.message;
    if (message.contains('mismatch')) {
      return ChecksumMismatchException(
        message,
        format: 'gzip',
        entryPath: entryPath,
      );
    }
    if (message.contains('truncated')) {
      return UnexpectedEofException(
        message,
        format: 'gzip',
        entryPath: entryPath,
      );
    }
    return CorruptArchiveException(
      message,
      format: 'gzip',
      entryPath: entryPath,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

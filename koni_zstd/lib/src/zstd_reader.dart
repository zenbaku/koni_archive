import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

/// Source-read chunk size while feeding the decoder.
const int _readChunkSize = 64 * 1024;

/// Reader presenting a `.zst` file as a single-entry archive. Created via
/// `ZstdFormat.createReader`.
///
/// `.zst` stores no filename or timestamp, so the entry name is derived from
/// the container (`logs.zst` → `logs`, `data` as a last resort). Zstandard may
/// record a frame content size, but a stream can omit it (and a file may hold
/// several frames), so [ArchiveEntry.uncompressedSize] is reported as `-1`
/// (unknown) — reading the entry still yields the full content. Decoding is
/// streamed one block (≤ 128 KiB) at a time.
final class ZstdReader extends ArchiveReader {
  ZstdReader._(this.format, this._source, this.entries);

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final ByteSource _source;
  bool _closed = false;

  /// Builds the single entry from the container name; reads no content.
  static Future<ZstdReader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    if (source.length < 4) {
      throw UnexpectedEofException(
        'too short to be a zstd file (${source.length} bytes)',
        format: 'zstd',
      );
    }
    final head = await source.read(0, 4);
    // Frame magic FD2FB528 (LE) or a skippable-frame magic 184D2A5x.
    final magic = head[0] | (head[1] << 8) | (head[2] << 16) | (head[3] << 24);
    final skippable = (magic & 0xFFFFFFF0) == 0x184D2A50;
    if (magic != 0xFD2FB528 && !skippable) {
      throw InvalidHeaderException('bad zstd magic', format: 'zstd', offset: 0);
    }

    final entry = ArchiveEntry(
      path: _nameFromSource(source.name),
      type: ArchiveEntryType.file,
      uncompressedSize: -1, // zstd may omit the frame content size
      compressedSize: source.length,
      compression: ArchiveCompression.zstd,
    );
    return ZstdReader._(format, source, List.unmodifiable([entry]));
  }

  /// `foo.zst` → `foo`; `foo.tzst` → `foo.tar`; `data` last resort.
  static String _nameFromSource(String? sourceName) {
    if (sourceName == null || sourceName.isEmpty) return 'data';
    var base = sourceName.replaceAll(r'\', '/');
    final slash = base.lastIndexOf('/');
    if (slash >= 0) base = base.substring(slash + 1);
    final lower = base.toLowerCase();
    if (lower.endsWith('.zst')) {
      base = base.substring(0, base.length - 4);
    } else if (lower.endsWith('.tzst')) {
      base = '${base.substring(0, base.length - 5)}.tar';
    }
    final normalized = normalizeEntryPath(base);
    return normalized.path.isEmpty ? 'data' : normalized.path;
  }

  @override
  Stream<Uint8List> openRead(ArchiveEntry entry) {
    if (entry != entries.single) {
      throw ArgumentError.value(entry, 'entry', 'not an entry of this archive');
    }
    return _decode(entry);
  }

  Stream<Uint8List> _decode(ArchiveEntry entry) async* {
    final decoder = RawZstdDecoder();
    try {
      var offset = 0;
      while (offset < _source.length) {
        if (_closed) {
          throw ArchiveClosedException(
            'archive was closed while streaming entry',
            format: 'zstd',
            entryPath: entry.path,
          );
        }
        final take =
            _source.length - offset < _readChunkSize
                ? _source.length - offset
                : _readChunkSize;
        decoder.addInput(await _source.read(offset, take));
        offset += take;
      }
      decoder.close();
      for (Uint8List? block; (block = decoder.nextBlock()) != null;) {
        if (_closed) {
          throw ArchiveClosedException(
            'archive was closed while streaming entry',
            format: 'zstd',
            entryPath: entry.path,
          );
        }
        yield block!;
      }
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad zstd stream: ${e.message}',
        format: 'zstd',
        entryPath: entry.path,
      );
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

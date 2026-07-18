import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

/// Source-read chunk size while feeding the decoder.
const int _readChunkSize = 64 * 1024;

/// Reader presenting a `.bz2` file as a single-entry archive. Created via
/// `Bzip2Format.createReader`.
///
/// `.bz2` stores no filename, timestamp, or decompressed size, so the entry
/// name is derived from the container (`logs.bz2` → `logs`, `data` as a last
/// resort) and [ArchiveEntry.uncompressedSize] is `-1` (unknown) — reading the
/// entry still yields the full content. Decoding is streamed one bzip2 block
/// (≤ 900 KiB) at a time, so memory stays bounded regardless of entry size.
final class Bzip2Reader extends ArchiveReader {
  Bzip2Reader._(this.format, this._source, this.entries);

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final ByteSource _source;
  bool _closed = false;

  /// Builds the single entry from the container name; reads no content.
  /// bzip2 has no optional integrity toggles — its block and stream CRCs are
  /// integral to the codec and always verified — so [options] is unused.
  static Future<Bzip2Reader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    if (source.length < 4) {
      throw UnexpectedEofException(
        'too short to be a bzip2 file (${source.length} bytes)',
        format: 'bzip2',
      );
    }
    final head = await source.read(0, 4);
    if (head[0] != 0x42 || head[1] != 0x5A || head[2] != 0x68) {
      throw InvalidHeaderException(
        'bad bzip2 magic',
        format: 'bzip2',
        offset: 0,
      );
    }

    final entry = ArchiveEntry(
      path: _nameFromSource(source.name),
      type: ArchiveEntryType.file,
      uncompressedSize: -1, // bzip2 records no size
      compressedSize: source.length,
      compression: ArchiveCompression.bzip2,
    );
    return Bzip2Reader._(format, source, List.unmodifiable([entry]));
  }

  /// `foo.bz2` → `foo`; `foo.tbz2`/`foo.tbz` → `foo.tar`; `data` last resort.
  static String _nameFromSource(String? sourceName) {
    if (sourceName == null || sourceName.isEmpty) return 'data';
    var base = sourceName.replaceAll(r'\', '/');
    final slash = base.lastIndexOf('/');
    if (slash >= 0) base = base.substring(slash + 1);
    final lower = base.toLowerCase();
    if (lower.endsWith('.bz2')) {
      base = base.substring(0, base.length - 4);
    } else if (lower.endsWith('.tbz2')) {
      base = '${base.substring(0, base.length - 5)}.tar';
    } else if (lower.endsWith('.tbz')) {
      base = '${base.substring(0, base.length - 4)}.tar';
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
    final decoder = RawBzip2Decoder();
    try {
      // Feed all compressed bytes (blocks are bit-aligned; the source is
      // random-access, so buffering the compressed input is cheap).
      var offset = 0;
      while (offset < _source.length) {
        if (_closed) {
          throw ArchiveClosedException(
            'archive was closed while streaming entry',
            format: 'bzip2',
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
      // Yield one decoded block at a time (bounded output; a size guard can
      // abort between blocks).
      for (Uint8List? block; (block = decoder.nextBlock()) != null;) {
        if (_closed) {
          throw ArchiveClosedException(
            'archive was closed while streaming entry',
            format: 'bzip2',
            entryPath: entry.path,
          );
        }
        yield block!;
      }
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad bzip2 stream: ${e.message}',
        format: 'bzip2',
        entryPath: entry.path,
      );
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

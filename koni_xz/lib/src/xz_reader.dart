import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'xz_block.dart';
import 'xz_container.dart';

/// Reader presenting an `.xz` file as a single-entry archive. Created via
/// `XzFormat.createReader`.
///
/// `.xz` carries no stored name or timestamp, so the entry name is derived from
/// the container name (`comics.xz` → `comics`, `data` as a last resort). The
/// content is decoded block by block: each block's LZMA2 payload is decompressed
/// into a buffer sized from the stream index, its transform filters (delta /
/// BCJ x86) are reverse-applied, and its integrity check is verified. Peak
/// memory is therefore one block; note that default (single-threaded) `xz`
/// writes the whole file as **one** block, so a large `.xz` decodes one large
/// buffer (multithreaded `xz -T0` splits into bounded blocks).
final class XzReader extends ArchiveReader {
  XzReader._(
    this.format,
    this._source,
    this._options,
    this._container,
    this.entries,
  );

  @override
  final ArchiveFormat format;

  @override
  final List<ArchiveEntry> entries;

  final ByteSource _source;
  final ArchiveReadOptions _options;
  final XzContainer _container;
  bool _closed = false;

  /// Parses the container framing (stream header/footer/index across any
  /// concatenated streams) and builds the single file entry. No content is
  /// decoded here.
  static Future<XzReader> parse(
    ArchiveFormat format,
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    final container = await parseXzContainer(source);

    final name = _nameFromSource(source.name);
    final entry = ArchiveEntry(
      path: name,
      type: ArchiveEntryType.file,
      uncompressedSize: container.totalUncompressed,
      compressedSize: source.length,
      compression: ArchiveCompression.lzma2,
    );
    return XzReader._(
      format,
      source,
      options,
      container,
      List.unmodifiable([entry]),
    );
  }

  /// `foo.xz` → `foo`; `foo.txz` → `foo.tar`; `data` as the last resort.
  static String _nameFromSource(String? sourceName) {
    if (sourceName == null || sourceName.isEmpty) return 'data';
    var base = sourceName.replaceAll(r'\', '/');
    final slash = base.lastIndexOf('/');
    if (slash >= 0) base = base.substring(slash + 1);
    final lower = base.toLowerCase();
    if (lower.endsWith('.xz')) {
      base = base.substring(0, base.length - 3);
    } else if (lower.endsWith('.txz')) {
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
    final maxEntrySize = _options.maxEntrySize;
    try {
      for (final block in _container.blocks) {
        if (_closed) {
          throw ArchiveClosedException(
            'archive was closed while streaming entry',
            format: 'xz',
            entryPath: entry.path,
          );
        }
        // Proactive guard: the bounded-reader seam only counts yielded bytes,
        // but the whole block is allocated before the first yield. A single
        // block already over the per-entry limit is rejected before the
        // allocation, not after an OOM.
        if (maxEntrySize != null && block.uncompressedSize > maxEntrySize) {
          throw SizeLimitExceededException(
            'entry "${entry.path}" contains a block of '
            '${block.uncompressedSize} byte(s), over the maxEntrySize limit '
            'of $maxEntrySize',
            limit: maxEntrySize,
            format: 'xz',
            entryPath: entry.path,
          );
        }
        final decoded = await decodeXzBlock(
          _source,
          block,
          verifyChecksums: _options.verifyChecksums,
        );
        if (decoded.isNotEmpty) yield decoded;
      }
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad LZMA2 stream: ${e.message}',
        format: 'xz',
        entryPath: entry.path,
      );
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

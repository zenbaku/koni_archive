import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'xz_write.dart';

/// Writer for `.xz` files. Created via `XzWriteFormat.openWriter`.
///
/// `.xz` is a **single-member** container: it compresses exactly one byte
/// stream. So this writer accepts one file entry — a second `add*` call, or a
/// directory/symlink/other entry, is rejected. The entry is LZMA2-compressed as
/// one block with a CRC-64 check; adding nothing and closing writes a valid
/// empty stream (what `xz < /dev/null` produces).
///
/// ## Buffering caveat
///
/// The `Lzma2Encoder` is one-shot (its buffer doubles as the match window), so
/// the entry's uncompressed bytes are held in memory while it is encoded — the
/// same caveat as the 7z LZMA path. Splitting large input into multiple blocks
/// to bound memory is a possible future enhancement, not done here.
///
/// ## Name asymmetry
///
/// `.xz` stores no filename, so [ArchiveEntrySpec.path] is not written; reading
/// the result back derives the entry name from the source name instead. A
/// write-then-read round trip therefore preserves the *content*, not the name.
final class XzWriter extends ArchiveWriter {
  /// Creates a writer appending to [_sink] under [_options].
  XzWriter(this.format, this._sink, this._options);

  @override
  final ArchiveWriteFormat format;

  final ByteSink _sink;
  final ArchiveWriteOptions _options;

  Uint8List? _container;
  bool _entryAdded = false;
  bool _closed = false;

  @override
  Future<ArchiveEntry> addStream(
    ArchiveEntrySpec spec,
    Stream<Uint8List> content, {
    required int size,
  }) async {
    _checkOpen();
    if (spec.type != ArchiveEntryType.file) {
      throw ArgumentError.value(
        spec.type,
        'spec.type',
        'addStream is for files; xz has no directory or link entries',
      );
    }
    if (_entryAdded) {
      throw StateError(
        'an .xz file holds a single member; only one entry may be added',
      );
    }
    _rejectUnsupportedCompression(spec.compression);
    _entryAdded = true;

    // Buffer and size-check the content (the encoder needs the whole payload).
    final data = Uint8List(size);
    var offset = 0;
    await for (final chunk in content) {
      if (offset + chunk.length > size) {
        throw SizeLimitExceededException(
          'entry "${spec.path}" streamed more than the declared $size byte(s)',
          limit: size,
          format: 'xz',
          entryPath: spec.path,
        );
      }
      data.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (offset != size) {
      throw CorruptArchiveException(
        'entry "${spec.path}" streamed $offset byte(s), declared $size',
        format: 'xz',
        entryPath: spec.path,
      );
    }

    _container = buildXzStream(data);
    return ArchiveEntry(
      path: spec.path,
      type: ArchiveEntryType.file,
      uncompressedSize: size,
      compressedSize: _container!.length,
      compression: ArchiveCompression.lzma2,
      modified: spec.modified,
    );
  }

  @override
  Future<ArchiveEntry> addEntry(ArchiveEntrySpec spec) async {
    _checkOpen();
    throw ArgumentError.value(
      spec.type,
      'spec.type',
      'xz has no directory, link, or other entry types; it compresses one '
          'byte stream (use addBytes/addStream)',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // No entry: emit a valid empty stream (matches `xz < /dev/null`).
    await _sink.add(_container ?? buildEmptyXzStream());
  }

  void _rejectUnsupportedCompression(ArchiveCompression? perEntry) {
    final requested = perEntry ?? _options.compression;
    if (requested != null && requested != ArchiveCompression.lzma2) {
      throw UnsupportedCompressionException(
        'xz compresses with LZMA2 only, not ${requested.name}',
        methodName: requested.name,
        format: 'xz',
      );
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw ArchiveClosedException('writer is closed', format: 'xz');
    }
  }
}

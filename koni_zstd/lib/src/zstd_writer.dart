import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

/// Writer for `.zst` files. Created via `ZstdWriteFormat.openWriter`.
///
/// `.zst` is a **single-member** container: it compresses exactly one byte
/// stream. So this writer accepts one file entry — a second `add*` call, or a
/// directory/symlink/other entry, is rejected. The entry is Zstandard-compressed
/// as a single frame (single-segment header with the content size, no content
/// checksum, no dictionary); adding nothing and closing writes a valid empty
/// frame.
///
/// ## Ratio
///
/// This is a correctness-first encoder: LZ sequences over the **predefined** FSE
/// tables with **raw** (uncompressed) literals, so its ratio is below `zstd`'s
/// on literal-heavy data (compressing literals with Huffman is a planned
/// improvement). The output is byte-decodable by `zstd` / libzstd.
///
/// ## Buffering caveat
///
/// The `ZstdEncoder` is one-shot and the frame uses a single-segment window over
/// the whole content, so the entry's uncompressed bytes are held in memory while
/// it is encoded. The window (and therefore the input) is capped at 128 MiB.
///
/// ## Name asymmetry
///
/// `.zst` stores no filename, so [ArchiveEntrySpec.path] is not written; reading
/// the result back derives the entry name from the source name instead. A
/// write-then-read round trip therefore preserves the *content*, not the name.
final class ZstdWriter extends ArchiveWriter {
  /// Creates a writer appending to [_sink] under [_options].
  ZstdWriter(this.format, this._sink, this._options);

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
        'addStream is for files; zstd has no directory or link entries',
      );
    }
    if (_entryAdded) {
      throw StateError(
        'a .zst file holds a single member; only one entry may be added',
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
          format: 'zstd',
          entryPath: spec.path,
        );
      }
      data.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (offset != size) {
      throw CorruptArchiveException(
        'entry "${spec.path}" streamed $offset byte(s), declared $size',
        format: 'zstd',
        entryPath: spec.path,
      );
    }

    _container = ZstdEncoder().encode(data);
    return ArchiveEntry(
      path: spec.path,
      type: ArchiveEntryType.file,
      uncompressedSize: size,
      compressedSize: _container!.length,
      compression: ArchiveCompression.zstd,
      modified: spec.modified,
    );
  }

  @override
  Future<ArchiveEntry> addEntry(ArchiveEntrySpec spec) async {
    _checkOpen();
    throw ArgumentError.value(
      spec.type,
      'spec.type',
      'zstd has no directory, link, or other entry types; it compresses one '
          'byte stream (use addBytes/addStream)',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // No entry: emit a valid empty frame.
    await _sink.add(_container ?? ZstdEncoder().encode(Uint8List(0)));
  }

  void _rejectUnsupportedCompression(ArchiveCompression? perEntry) {
    final requested = perEntry ?? _options.compression;
    if (requested != null && requested != ArchiveCompression.zstd) {
      throw UnsupportedCompressionException(
        'zstd compresses with Zstandard only, not ${requested.name}',
        methodName: requested.name,
        format: 'zstd',
      );
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw ArchiveClosedException('writer is closed', format: 'zstd');
    }
  }
}

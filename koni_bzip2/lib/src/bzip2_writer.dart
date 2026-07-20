import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

/// Writer for `.bz2` files. Created via `Bzip2WriteFormat.openWriter`.
///
/// `.bz2` is a **single-member** container: it compresses exactly one byte
/// stream. So this writer accepts one file entry — a second `add*` call, or a
/// directory/symlink/other entry, is rejected. Adding nothing and closing
/// writes a valid empty stream (an end-of-stream marker with a zero combined
/// CRC, what `bzip2 < /dev/null` produces).
///
/// ## Buffering caveat
///
/// The `Bzip2Encoder` is one-shot — the whole payload is transformed together
/// (the Burrows–Wheeler transform sorts the block's rotations), so the entry's
/// uncompressed bytes are held in memory while it is encoded. Input larger than
/// one block (`blockSize100k` × 100 000 bytes) is split into independent blocks
/// by the encoder, but the input buffer itself is not streamed.
///
/// ## Name asymmetry
///
/// `.bz2` stores no filename, so [ArchiveEntrySpec.path] is not written; reading
/// the result back derives the entry name from the source name instead. A
/// write-then-read round trip therefore preserves the *content*, not the name.
final class Bzip2Writer extends ArchiveWriter {
  /// Creates a writer appending to [_sink] under [_options].
  Bzip2Writer(this.format, this._sink, this._options, {this.blockSize100k = 9});

  @override
  final ArchiveWriteFormat format;

  final ByteSink _sink;
  final ArchiveWriteOptions _options;

  /// Block size in 100 KiB units (1–9), like `bzip2 -1`..`-9`.
  final int blockSize100k;

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
        'addStream is for files; bzip2 has no directory or link entries',
      );
    }
    if (_entryAdded) {
      throw StateError(
        'a .bz2 file holds a single member; only one entry may be added',
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
          format: 'bzip2',
          entryPath: spec.path,
        );
      }
      data.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (offset != size) {
      throw CorruptArchiveException(
        'entry "${spec.path}" streamed $offset byte(s), declared $size',
        format: 'bzip2',
        entryPath: spec.path,
      );
    }

    _container = Bzip2Encoder(blockSize100k: blockSize100k).encode(data);
    return ArchiveEntry(
      path: spec.path,
      type: ArchiveEntryType.file,
      uncompressedSize: size,
      compressedSize: _container!.length,
      compression: ArchiveCompression.bzip2,
      modified: spec.modified,
    );
  }

  @override
  Future<ArchiveEntry> addEntry(ArchiveEntrySpec spec) async {
    _checkOpen();
    throw ArgumentError.value(
      spec.type,
      'spec.type',
      'bzip2 has no directory, link, or other entry types; it compresses one '
          'byte stream (use addBytes/addStream)',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // No entry: emit a valid empty stream (matches `bzip2 < /dev/null`).
    await _sink.add(
      _container ??
          Bzip2Encoder(blockSize100k: blockSize100k).encode(Uint8List(0)),
    );
  }

  void _rejectUnsupportedCompression(ArchiveCompression? perEntry) {
    final requested = perEntry ?? _options.compression;
    if (requested != null && requested != ArchiveCompression.bzip2) {
      throw UnsupportedCompressionException(
        'bzip2 compresses with bzip2 only, not ${requested.name}',
        methodName: requested.name,
        format: 'bzip2',
      );
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw ArchiveClosedException('writer is closed', format: 'bzip2');
    }
  }
}

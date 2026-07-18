import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';

import 'xz_block.dart';
import 'xz_container.dart';

/// A [ByteSource] presenting the *decompressed* content of an `.xz` container,
/// what makes layered formats (`.tar.xz`) possible.
///
/// ## Cost model
///
/// `.xz` has no random access below the block granularity: a block is the unit
/// of decode (its LZMA2 output buffer is the dictionary window). A [read]
/// decodes every block up to the one covering the requested offset and
/// **caches all decoded blocks in memory**. Peak memory is therefore up to the
/// decompressed size of the blocks touched so far. For the intended use
/// (reading a `.tar.xz` whose TAR reader walks forward) each block is decoded
/// once. Note that default single-threaded `xz` emits the whole payload as one
/// block, so sniffing the inner TAR header decodes the entire container;
/// multithreaded `xz -T0` splits it into bounded blocks.
///
/// [length] is the exact decompressed size from the stream index.
final class XzDecompressedByteSource implements ByteSource {
  XzDecompressedByteSource._(
    this._source,
    this._verifyChecksums,
    this._container,
    this.name,
  ) : length = _container.totalUncompressed {
    _blockOutStart = List<int>.filled(_container.blocks.length + 1, 0);
    for (var i = 0; i < _container.blocks.length; i++) {
      _blockOutStart[i + 1] =
          _blockOutStart[i] + _container.blocks[i].uncompressedSize;
    }
    _decoded = List<Uint8List?>.filled(_container.blocks.length, null);
  }

  /// Opens [source] (a complete `.xz` container). Parses only the framing (no
  /// content decode yet) to learn the decompressed [length].
  ///
  /// [maxDecodedSize] (the caller's effective container cap —
  /// `maxContainerDecodeSize`, falling back to `maxEntrySize`) caps the
  /// decompressed size: a container declaring more is rejected here with
  /// [SizeLimitExceededException], before any content is decoded. The index
  /// gives the exact total, so this is a hard bound, not a heuristic.
  static Future<XzDecompressedByteSource> open(
    ByteSource source, {
    bool verifyChecksums = true,
    int? maxDecodedSize,
  }) async {
    final container = await parseXzContainer(source);
    if (maxDecodedSize != null &&
        container.totalUncompressed > maxDecodedSize) {
      throw SizeLimitExceededException(
        'xz container decompresses to ${container.totalUncompressed} byte(s), '
        'over the maxContainerDecodeSize limit of $maxDecodedSize',
        limit: maxDecodedSize,
        format: 'xz',
      );
    }
    return XzDecompressedByteSource._(
      source,
      verifyChecksums,
      container,
      _innerName(source.name),
    );
  }

  /// `foo.tar.xz` → `foo.tar`, `foo.txz` → `foo.tar`, `foo.xz` → `foo`.
  static String? _innerName(String? outer) {
    if (outer == null) return null;
    final lower = outer.toLowerCase();
    if (lower.endsWith('.txz')) {
      return '${outer.substring(0, outer.length - 4)}.tar';
    }
    if (lower.endsWith('.xz')) return outer.substring(0, outer.length - 3);
    return outer;
  }

  final ByteSource _source;
  final bool _verifyChecksums;
  final XzContainer _container;

  @override
  final int length;

  @override
  final String? name;

  late final List<int> _blockOutStart;
  late final List<Uint8List?> _decoded;
  bool _closed = false;

  // Serialize block decode so concurrent reads don't interleave.
  Future<void> _lock = Future.value();

  @override
  Future<Uint8List> read(int offset, int length) {
    checkByteSourceRange(this, offset, length);
    final result = _lock.then((_) async {
      if (_closed) {
        throw ArchiveClosedException('read($offset, $length) after close()');
      }
      if (length == 0) return Uint8List(0);
      await _ensureDecoded(offset, offset + length);
      return _readFromCache(offset, length);
    });
    _lock = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _ensureDecoded(int start, int end) async {
    // Blocks covering [start, end): first block with outStart <= start, up to
    // the block whose range reaches end.
    var i = _blockIndexFor(start);
    while (i < _container.blocks.length && _blockOutStart[i] < end) {
      if (_decoded[i] == null) {
        try {
          _decoded[i] = await decodeXzBlock(
            _source,
            _container.blocks[i],
            verifyChecksums: _verifyChecksums,
          );
        } on FormatException catch (e) {
          throw CorruptArchiveException(
            'bad xz container: ${e.message}',
            format: 'xz',
          );
        }
      }
      i++;
    }
  }

  int _blockIndexFor(int offset) {
    // Largest i with _blockOutStart[i] <= offset.
    var low = 0;
    var high = _container.blocks.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_blockOutStart[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  Uint8List _readFromCache(int offset, int length) {
    final result = Uint8List(length);
    var written = 0;
    var index = _blockIndexFor(offset);
    var position = offset;
    while (written < length) {
      final block = _decoded[index]!;
      final blockStart = _blockOutStart[index];
      final from = position - blockStart;
      final available = block.length - from;
      final take = length - written < available ? length - written : available;
      result.setRange(written, written + take, block, from);
      written += take;
      position += take;
      index++;
    }
    return result;
  }

  @override
  Future<void> close() {
    _closed = true;
    for (var i = 0; i < _decoded.length; i++) {
      _decoded[i] = null;
    }
    return Future.value();
  }
}

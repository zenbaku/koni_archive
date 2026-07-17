import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

/// A [ByteSource] presenting the *decompressed* content of a gzip container,
/// what makes layered formats (`.tar.gz`) possible.
///
/// ## Cost model
///
/// gzip has no random access: a read at offset N sequentially decodes
/// everything up to N **and caches all decoded bytes in memory** for later
/// reads. Peak memory is therefore up to the decompressed size of the
/// region touched so far. This is the Phase-1 strategy; a zran-style seek
/// index is deferred. For the intended use (reading a `.tar.gz`
/// whose TAR reader walks forward) decode work is effectively sequential
/// and each byte is decoded once.
///
/// [length] comes from the trailing ISIZE field: exact for single-member
/// containers under 4 GiB. A container whose actual decoded size differs
/// (multi-member, ≥ 4 GiB) fails with a typed error when the lie is
/// discovered.
final class GzipDecompressedByteSource implements ByteSource {
  GzipDecompressedByteSource._(
    this._source,
    this._verifyChecksums,
    this.length,
    this.name,
  ) {
    _decoder = RawGzipDecoder(
      onOutput: (chunk) {
        _chunkStarts.add(_decodedBytes);
        _chunks.add(chunk);
        _decodedBytes += chunk.length;
      },
      verifyChecksums: _verifyChecksums,
    );
  }

  /// Opens [source] (a complete gzip container). Reads only the trailer to
  /// learn the decompressed [length]; no content is decoded yet.
  ///
  /// [maxDecodedSize] (the caller's effective container cap —
  /// `maxContainerDecodeSize`, falling back to `maxEntrySize`) caps the
  /// decompressed size: a container declaring more is rejected here with
  /// [SizeLimitExceededException], before any content is decoded. This is a
  /// hard bound, not just a fast path: every [read] is range-checked against
  /// [length], so the decoder is never driven past [length] bytes of output —
  /// bounding the trailer's ISIZE bounds the whole decode. ISIZE is the size
  /// mod 2^32, so it only ever under-reports; a value over the cap therefore
  /// means the true size is over it too (no false rejections).
  static Future<GzipDecompressedByteSource> open(
    ByteSource source, {
    bool verifyChecksums = true,
    int? maxDecodedSize,
  }) async {
    if (source.length < 20) {
      throw UnexpectedEofException(
        'too short to be a complete gzip file (${source.length} bytes)',
        format: 'gzip',
      );
    }
    final trailer = await source.read(source.length - 8, 8);
    final isize =
        trailer[4] |
        (trailer[5] << 8) |
        (trailer[6] << 16) |
        (trailer[7] << 24);
    if (maxDecodedSize != null && isize > maxDecodedSize) {
      throw SizeLimitExceededException(
        'gzip container decompresses to $isize byte(s), over the '
        'maxContainerDecodeSize limit of $maxDecodedSize',
        limit: maxDecodedSize,
        format: 'gzip',
      );
    }
    return GzipDecompressedByteSource._(
      source,
      verifyChecksums,
      isize,
      _innerName(source.name),
    );
  }

  /// `foo.tar.gz` → `foo.tar`, `foo.tgz` → `foo.tar`, `foo.gz` → `foo`.
  static String? _innerName(String? outer) {
    if (outer == null) return null;
    final lower = outer.toLowerCase();
    if (lower.endsWith('.tgz')) {
      return '${outer.substring(0, outer.length - 4)}.tar';
    }
    if (lower.endsWith('.gz')) return outer.substring(0, outer.length - 3);
    return outer;
  }

  final ByteSource _source;
  final bool _verifyChecksums;

  @override
  final int length;

  @override
  final String? name;

  static const int _readChunkSize = 16 * 1024;

  late final RawGzipDecoder _decoder;
  final List<Uint8List> _chunks = [];
  final List<int> _chunkStarts = [];
  int _decodedBytes = 0;
  int _compressedPos = 0;
  bool _closed = false;

  // Sequential decode must not interleave (pread semantics for callers).
  Future<void> _lock = Future.value();

  @override
  Future<Uint8List> read(int offset, int length) {
    checkByteSourceRange(this, offset, length);
    final result = _lock.then((_) async {
      if (_closed) {
        throw ArchiveClosedException('read($offset, $length) after close()');
      }
      await _ensureDecoded(offset + length);
      return _readFromCache(offset, length);
    });
    _lock = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _ensureDecoded(int target) async {
    try {
      while (_decodedBytes < target && _compressedPos < _source.length) {
        final chunkSize =
            _source.length - _compressedPos < _readChunkSize
                ? _source.length - _compressedPos
                : _readChunkSize;
        _decoder.addInput(await _source.read(_compressedPos, chunkSize));
        _compressedPos += chunkSize;
      }
      if (_decodedBytes < target) {
        _decoder.finish();
        // Stream is complete but shorter than ISIZE promised.
        throw CorruptArchiveException(
          'gzip container decoded to $_decodedBytes byte(s), '
          'trailer promised $length',
          format: 'gzip',
        );
      }
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad gzip container: ${e.message}',
        format: 'gzip',
      );
    }
  }

  Uint8List _readFromCache(int offset, int length) {
    final result = Uint8List(length);
    var written = 0;
    // Binary search for the chunk containing `offset`.
    var low = 0;
    var high = _chunks.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_chunkStarts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    var index = low;
    var position = offset;
    while (written < length) {
      final chunk = _chunks[index];
      final chunkStart = _chunkStarts[index];
      final from = position - chunkStart;
      final available = chunk.length - from;
      final take = length - written < available ? length - written : available;
      result.setRange(written, written + take, chunk, from);
      written += take;
      position += take;
      index++;
    }
    return result;
  }

  @override
  Future<void> close() {
    _closed = true;
    _chunks.clear();
    _chunkStarts.clear();
    return Future.value();
  }
}

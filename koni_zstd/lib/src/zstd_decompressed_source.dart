import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

/// A [ByteSource] presenting the *decompressed* content of a `.zst` container,
/// what makes layered formats (`.tar.zst`) possible.
///
/// ## Cost model
///
/// zstd may omit the frame content size and a container may hold several
/// frames, so this source decompresses the **whole** container at [open] to
/// learn its [length] (capped by [open]'s `maxDecodedSize`) and serves every
/// [read] from the decoded bytes — the gzip-style "decode and cache" shape. A
/// mandatory window-size cap in the codec bounds pathological headers.
final class ZstdDecompressedByteSource implements ByteSource {
  ZstdDecompressedByteSource._(this._bytes, this.name);

  /// Opens [source] (a complete `.zst` container), decompressing it fully.
  ///
  /// [maxDecodedSize] (the caller's effective container cap —
  /// `maxContainerDecodeSize`, falling back to `maxEntrySize`) bounds the
  /// decode: a container that decompresses past it is rejected with
  /// [SizeLimitExceededException] as soon as the running total crosses it.
  static Future<ZstdDecompressedByteSource> open(
    ByteSource source, {
    int? maxDecodedSize,
  }) async {
    const chunk = 64 * 1024;
    final decoder = RawZstdDecoder();
    var offset = 0;
    try {
      while (offset < source.length) {
        final take =
            source.length - offset < chunk ? source.length - offset : chunk;
        decoder.addInput(await source.read(offset, take));
        offset += take;
      }
      decoder.close();
      final builder = BytesBuilder(copy: false);
      for (Uint8List? block; (block = decoder.nextBlock()) != null;) {
        builder.add(block!);
        if (maxDecodedSize != null && builder.length > maxDecodedSize) {
          throw SizeLimitExceededException(
            'zstd container decompresses past the maxContainerDecodeSize '
            'limit of $maxDecodedSize',
            limit: maxDecodedSize,
            format: 'zstd',
          );
        }
      }
      return ZstdDecompressedByteSource._(
        builder.takeBytes(),
        _innerName(source.name),
      );
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad zstd container: ${e.message}',
        format: 'zstd',
      );
    }
  }

  /// `foo.tar.zst` → `foo.tar`, `foo.tzst` → `foo.tar`, `foo.zst` → `foo`.
  static String? _innerName(String? outer) {
    if (outer == null) return null;
    final lower = outer.toLowerCase();
    if (lower.endsWith('.tzst')) {
      return '${outer.substring(0, outer.length - 5)}.tar';
    }
    if (lower.endsWith('.zst')) return outer.substring(0, outer.length - 4);
    return outer;
  }

  Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  final String? name;

  bool _closed = false;

  @override
  Future<Uint8List> read(int offset, int length) {
    checkByteSourceRange(this, offset, length);
    if (_closed) {
      throw ArchiveClosedException('read($offset, $length) after close()');
    }
    return Future.value(Uint8List.sublistView(_bytes, offset, offset + length));
  }

  @override
  Future<void> close() {
    _closed = true;
    _bytes = Uint8List(0);
    return Future.value();
  }
}

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_codecs/koni_codecs.dart';

/// A [ByteSource] presenting the *decompressed* content of a `.bz2` container,
/// what makes layered formats (`.tar.bz2`) possible.
///
/// ## Cost model
///
/// Unlike gzip (which records the decompressed size in its trailer) or xz
/// (which records it in the stream index), **bzip2 stores no size**. So this
/// source must decompress the **whole** container at [open] to learn its
/// [length] — a one-time cost, capped by [open]'s `maxDecodedSize`. The decoded
/// bytes are then held in memory and every [read] is served from them. This is
/// the gzip-style "decode and cache" shape, just without the cheap size probe.
final class Bzip2DecompressedByteSource implements ByteSource {
  Bzip2DecompressedByteSource._(this._bytes, this.name);

  /// Opens [source] (a complete `.bz2` container), decompressing it fully.
  ///
  /// [maxDecodedSize] (the caller's effective container cap —
  /// `maxContainerDecodeSize`, falling back to `maxEntrySize`) bounds the
  /// decode: a container that decompresses past it is rejected with
  /// [SizeLimitExceededException] as soon as the running total crosses the
  /// limit, so a bomb never fully materializes.
  static Future<Bzip2DecompressedByteSource> open(
    ByteSource source, {
    int? maxDecodedSize,
  }) async {
    const chunk = 64 * 1024;
    final decoder = RawBzip2Decoder();
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
            'bzip2 container decompresses past the maxContainerDecodeSize '
            'limit of $maxDecodedSize',
            limit: maxDecodedSize,
            format: 'bzip2',
          );
        }
      }
      return Bzip2DecompressedByteSource._(
        builder.takeBytes(),
        _innerName(source.name),
      );
    } on FormatException catch (e) {
      throw CorruptArchiveException(
        'bad bzip2 container: ${e.message}',
        format: 'bzip2',
      );
    }
  }

  /// `foo.tar.bz2` → `foo.tar`, `foo.tbz2`/`foo.tbz` → `foo.tar`,
  /// `foo.bz2` → `foo`.
  static String? _innerName(String? outer) {
    if (outer == null) return null;
    final lower = outer.toLowerCase();
    if (lower.endsWith('.tbz2')) {
      return '${outer.substring(0, outer.length - 5)}.tar';
    }
    if (lower.endsWith('.tbz')) {
      return '${outer.substring(0, outer.length - 4)}.tar';
    }
    if (lower.endsWith('.bz2')) return outer.substring(0, outer.length - 4);
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

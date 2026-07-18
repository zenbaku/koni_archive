import 'package:koni_archive_core/koni_archive_core.dart';

import 'bzip2_writer.dart';

/// The bzip2 write format. Pass to `Archive.create`:
///
/// ```dart
/// final writer = Archive.create(sink, format: const Bzip2WriteFormat());
/// await writer.addBytes(ArchiveEntrySpec(path: 'data'), bytes);
/// await writer.close();
/// ```
///
/// Writes a single-member `.bz2` file: the one added entry is bzip2-compressed
/// (`BZh<level>` framing, RLE1 → BWT → MTF/RLE2 → Huffman). `.bz2` has no
/// encryption, so a password is rejected (as TAR does); `.bz2` stores no
/// filename, so the entry path is not preserved on a round trip (see
/// [Bzip2Writer]).
final class Bzip2WriteFormat extends ArchiveWriteFormat {
  /// Creates the descriptor. [blockSize100k] (1–9) sets the block size in units
  /// of 100 000 bytes, matching `bzip2 -1`..`-9`; 9 is `bzip2`'s default and the
  /// best ratio. Stateless and const.
  const Bzip2WriteFormat({this.blockSize100k = 9});

  /// Block size in 100 KiB units (1–9), like `bzip2 -1`..`-9`.
  final int blockSize100k;

  @override
  String get name => 'bzip2';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) {
    if (options.password != null) {
      throw UnsupportedCompressionException(
        'bzip2 has no encryption; ArchiveWriteOptions.password is not supported',
        methodName: 'encryption',
        format: 'bzip2',
      );
    }
    return Bzip2Writer(this, sink, options, blockSize100k: blockSize100k);
  }
}

import 'package:koni_archive_core/koni_archive_core.dart';

import 'xz_writer.dart';

/// The xz write format. Pass to `Archive.create`:
///
/// ```dart
/// final writer = Archive.create(sink, format: const XzWriteFormat());
/// await writer.addBytes(ArchiveEntrySpec(path: 'data'), bytes);
/// await writer.close();
/// ```
///
/// Writes a single-member `.xz` file: the one added entry is LZMA2-compressed
/// as a single block with a CRC-64 check. `.xz` has no encryption, so a
/// password is rejected (as TAR does); `.xz` stores no filename, so the entry
/// path is not preserved on a round trip (see [XzWriter]).
final class XzWriteFormat extends ArchiveWriteFormat {
  /// Creates the descriptor. Stateless and const.
  const XzWriteFormat();

  @override
  String get name => 'xz';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) {
    if (options.password != null) {
      throw UnsupportedCompressionException(
        'xz has no encryption; ArchiveWriteOptions.password is not supported',
        methodName: 'encryption',
        format: 'xz',
      );
    }
    return XzWriter(this, sink, options);
  }
}

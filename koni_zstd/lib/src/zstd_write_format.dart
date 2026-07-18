import 'package:koni_archive_core/koni_archive_core.dart';

import 'zstd_writer.dart';

/// The Zstandard write format. Pass to `Archive.create`:
///
/// ```dart
/// final writer = Archive.create(sink, format: const ZstdWriteFormat());
/// await writer.addBytes(ArchiveEntrySpec(path: 'data'), bytes);
/// await writer.close();
/// ```
///
/// Writes a single-member `.zst` file: the one added entry is Zstandard-
/// compressed (LZ sequences over the predefined FSE tables with raw literals).
/// `.zst` has no encryption, so a password is rejected (as TAR does); `.zst`
/// stores no filename, so the entry path is not preserved on a round trip (see
/// [ZstdWriter]).
final class ZstdWriteFormat extends ArchiveWriteFormat {
  /// Creates the descriptor. Stateless and const.
  const ZstdWriteFormat();

  @override
  String get name => 'zstd';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) {
    if (options.password != null) {
      throw UnsupportedCompressionException(
        'zstd has no encryption; ArchiveWriteOptions.password is not supported',
        methodName: 'encryption',
        format: 'zstd',
      );
    }
    return ZstdWriter(this, sink, options);
  }
}

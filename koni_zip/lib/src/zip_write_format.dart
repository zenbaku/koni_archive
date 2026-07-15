import 'package:koni_archive_core/koni_archive_core.dart';

import 'zip_writer.dart';

/// The ZIP write format (including CBZ comic archives). Pass to
/// `Archive.create`:
///
/// ```dart
/// final writer = Archive.create(sink, format: const ZipWriteFormat());
/// ```
///
/// Entries default to deflate; pass `ArchiveWriteOptions(compression:
/// ArchiveCompression.stored)` or a per-entry `ArchiveEntrySpec.compression`
/// to store instead (what CBZ tools do for already-compressed images).
final class ZipWriteFormat extends ArchiveWriteFormat {
  /// Creates the descriptor. Stateless and const.
  const ZipWriteFormat();

  @override
  String get name => 'zip';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) =>
      ZipWriter(this, sink, options);
}

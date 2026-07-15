import 'package:koni_archive_core/koni_archive_core.dart';

import 'sevenz_writer.dart';

/// The 7z write format. Pass to `Archive.create`:
///
/// ```dart
/// final writer = Archive.create(sink, format: const SevenZWriteFormat());
/// ```
///
/// Writes Copy and Deflate (default) folders, one per non-empty file
/// (P2-4a). LZMA/LZMA2 folders arrive in P2-4b — see `doc/writing-scope.md`.
final class SevenZWriteFormat extends ArchiveWriteFormat {
  /// Creates the descriptor. Stateless and const.
  const SevenZWriteFormat();

  @override
  String get name => '7z';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) =>
      SevenZWriter(this, sink, options);
}

import 'package:koni_archive_core/koni_archive_core.dart';

import 'tar_writer.dart';

/// The TAR write format (POSIX ustar + PAX). Pass to `Archive.create`:
///
/// ```dart
/// final writer = Archive.create(sink, format: const TarWriteFormat());
/// ```
final class TarWriteFormat extends ArchiveWriteFormat {
  /// Creates the descriptor. Stateless and const.
  const TarWriteFormat();

  @override
  String get name => 'tar';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) {
    if (options.password != null) {
      // TAR has no standard encryption; a password can only mislead. Reject
      // it rather than silently write plaintext (see ArchiveWriteOptions).
      throw UnsupportedCompressionException(
        'TAR has no encryption; ArchiveWriteOptions.password is only honored '
        'by the ZIP and 7z writers',
        methodName: 'encryption',
        format: 'tar',
      );
    }
    return TarWriter(this, sink);
  }
}

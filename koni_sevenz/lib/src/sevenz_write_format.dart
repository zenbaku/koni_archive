import 'package:koni_archive_core/koni_archive_core.dart';

import 'sevenz_writer.dart';

/// The 7z write format. Pass to `Archive.create`:
///
/// ```dart
/// final writer = Archive.create(sink, format: const SevenZWriteFormat());
/// ```
///
/// Writes LZMA2 (default), LZMA, Deflate, and Copy folders, one per
/// non-empty file. With `ArchiveWriteOptions.password` set, file data is
/// AES-256 encrypted (P4-2); adding `encryptHeader` also encrypts the header
/// (`-mhe`). See `doc/writing-scope.md`.
final class SevenZWriteFormat extends ArchiveWriteFormat {
  /// Creates the descriptor. Stateless and const.
  const SevenZWriteFormat();

  @override
  String get name => '7z';

  @override
  ArchiveWriter openWriter(ByteSink sink, ArchiveWriteOptions options) {
    if (options.encryptHeader && options.password == null) {
      throw UnsupportedCompressionException(
        'ArchiveWriteOptions.encryptHeader needs a password to encrypt the '
        'header with',
        methodName: 'encryption',
        format: '7z',
      );
    }
    return SevenZWriter(this, sink, options);
  }
}

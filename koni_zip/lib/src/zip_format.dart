import 'package:koni_archive_core/koni_archive_core.dart';

import 'structures.dart';
import 'zip_reader.dart';

/// The ZIP archive format (including CBZ comic archives). Register into an
/// `ArchiveFormatRegistry` (the koni_archive facade does this for you).
final class ZipFormat extends ArchiveFormat {
  /// Creates the format descriptor. Stateless and const.
  const ZipFormat();

  @override
  String get name => 'zip';

  /// ZIP detection facts (§5): `PK\x03\x04` at offset 0 is common but not
  /// sufficient — self-extracting/prefixed archives require scanning
  /// backwards from EOF for the end-of-central-directory record (a comment
  /// can push it ~64 KiB from the end). Empty archives start `PK\x05\x06`.
  @override
  Future<bool> matches(ByteSource source) async {
    if (source.length < 22) return false;
    final head = await source.read(0, 4);
    if (head[0] == 0x50 && head[1] == 0x4B) {
      if ((head[2] == 0x03 && head[3] == 0x04) ||
          (head[2] == 0x05 && head[3] == 0x06)) {
        return true;
      }
    }
    // Prefixed (SFX) archives: no PK at the head; look for the EOCD.
    try {
      await Eocd.find(source);
      return true;
    } on UnsupportedFeatureException {
      // ZIP64/multi-volume: it *is* a ZIP — let openReader report why it
      // cannot be read instead of falling through to other formats.
      return true;
    } on ArchiveException {
      return false;
    }
  }

  @override
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) => ZipReader.parse(this, source, options);
}

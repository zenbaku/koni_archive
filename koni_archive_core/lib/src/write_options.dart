import 'entry.dart';

/// Options honored by archive writers, passed through `Archive.create` /
/// `ArchiveWriteFormat.openWriter`.
final class ArchiveWriteOptions {
  /// Creates options; the defaults are what applications normally want.
  const ArchiveWriteOptions({this.compression});

  /// Default compression method for entries whose [ArchiveEntrySpec] does
  /// not specify one. `null` means "the format's own default" (stored for
  /// TAR, deflate for ZIP). A format that cannot honor the requested method
  /// throws [UnsupportedCompressionException] at write time.
  final ArchiveCompression? compression;
}

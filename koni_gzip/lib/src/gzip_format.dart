import 'package:koni_archive_core/koni_archive_core.dart';

import 'decompressed_source.dart';
import 'gzip_reader.dart';

/// The gzip format: a bare `.gz` opens as a **single-entry archive**
/// (name from the FNAME field, else derived from the source name), and,
/// when [layeredFormats] are given, a compressed container whose
/// decompressed head sniffs as one of them (`.tar.gz`) presents as the
/// *inner* archive. Register into an `ArchiveFormatRegistry` (the
/// koni_archive facade does this for you, with TAR layered).
final class GzipFormat extends ArchiveFormat {
  /// Creates the format descriptor.
  ///
  /// [layeredFormats] are probed (in order) against the *decompressed*
  /// content; the first match reads the inner archive through a
  /// [GzipDecompressedByteSource] (sequential decode + in-memory cache,
  /// see its docs for the cost model). Only head-sniffing formats such as
  /// TAR belong here: a probe that reads near EOF would decode the whole
  /// container during detection.
  const GzipFormat({this.layeredFormats = const []});

  /// Formats to probe against the decompressed content (layering).
  final List<ArchiveFormat> layeredFormats;

  @override
  String get name => 'gzip';

  /// Detection: `1F 8B` magic plus the deflate method byte. The
  /// smallest complete gzip file is 20 bytes.
  @override
  Future<bool> matches(ByteSource source) async {
    if (source.length < 20) return false;
    final head = await source.read(0, 3);
    return head[0] == 0x1F && head[1] == 0x8B && head[2] == 8;
  }

  @override
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    if (layeredFormats.isNotEmpty) {
      final decompressed = await GzipDecompressedByteSource.open(
        source,
        verifyChecksums: options.verifyChecksums,
      );
      for (final inner in layeredFormats) {
        try {
          if (await inner.matches(decompressed)) {
            return inner.openReader(decompressed, options);
          }
        } on ArchiveException {
          continue; // probe over-read or similar: not this format
        }
      }
      // Nothing matched: fall through to the single-entry adapter (the
      // few decoded KiB in the probe cache are discarded with it).
      await decompressed.close();
    }
    return GzipReader.parse(this, source, options);
  }
}

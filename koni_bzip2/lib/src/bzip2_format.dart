import 'package:koni_archive_core/koni_archive_core.dart';

import 'bzip2_decompressed_source.dart';
import 'bzip2_reader.dart';

/// The bzip2 format: a bare `.bz2` opens as a **single-entry archive** (name
/// derived from the source name — `.bz2` stores none), and, when
/// [layeredFormats] are given, a compressed container whose decompressed head
/// sniffs as one of them (`.tar.bz2`) presents as the *inner* archive. Register
/// into an `ArchiveFormatRegistry` (the koni_archive facade does this for you,
/// with TAR layered).
final class Bzip2Format extends ArchiveFormat {
  /// Creates the format descriptor.
  ///
  /// [layeredFormats] are probed (in order) against the *decompressed* content
  /// through a [Bzip2DecompressedByteSource]; the first match reads the inner
  /// archive. Because bzip2 records no size, the decompressed source decodes the
  /// whole container at open (see its docs for the cost model), so only
  /// head-sniffing formats such as TAR belong here.
  const Bzip2Format({this.layeredFormats = const []});

  /// Formats to probe against the decompressed content (layering).
  final List<ArchiveFormat> layeredFormats;

  @override
  String get name => 'bzip2';

  /// Detection: the four-byte `BZh<digit>` magic (`42 5A 68` + `'1'..'9'`).
  @override
  Future<bool> matches(ByteSource source) async {
    if (source.length < 4) return false;
    final head = await source.read(0, 4);
    return head[0] == 0x42 &&
        head[1] == 0x5A &&
        head[2] == 0x68 &&
        head[3] >= 0x31 &&
        head[3] <= 0x39;
  }

  @override
  Future<ArchiveReader> createReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    if (layeredFormats.isNotEmpty) {
      final decompressed = await Bzip2DecompressedByteSource.open(
        source,
        // The container decode is a one-time open cost, so a caller who set
        // only `maxEntrySize` is still protected; an explicit
        // `maxContainerDecodeSize` overrides.
        maxDecodedSize: options.maxContainerDecodeSize ?? options.maxEntrySize,
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
      // Nothing matched: fall through to the single-entry adapter.
      await decompressed.close();
    }
    return Bzip2Reader.parse(this, source, options);
  }
}

import 'package:koni_archive_core/koni_archive_core.dart';

import 'sevenz_reader.dart';

/// The 7z archive format (including CB7 comic archives). Register into an
/// `ArchiveFormatRegistry` (the koni_archive facade does this for you).
final class SevenZFormat extends ArchiveFormat {
  /// Creates the format descriptor. Stateless and const.
  const SevenZFormat();

  @override
  String get name => '7z';

  /// Detection (§5): `37 7A BC AF 27 1C` at offset 0.
  @override
  Future<bool> matches(ByteSource source) async {
    if (source.length < 32) return false;
    final head = await source.read(0, 6);
    return head[0] == 0x37 &&
        head[1] == 0x7A &&
        head[2] == 0xBC &&
        head[3] == 0xAF &&
        head[4] == 0x27 &&
        head[5] == 0x1C;
  }

  @override
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) => SevenZReader.parse(this, source, options);
}

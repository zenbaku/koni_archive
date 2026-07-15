import 'package:koni_archive_core/koni_archive_core.dart';

import 'rar5_container.dart';
import 'rar_reader.dart';

/// The RAR archive format (including CBR comic archives). RAR5 is read;
/// RAR4 is detected and reported as a typed error (M10 scope). Register
/// into an `ArchiveFormatRegistry` (the koni_archive facade does this).
final class RarFormat extends ArchiveFormat {
  /// Creates the format descriptor. Stateless and const.
  const RarFormat();

  @override
  String get name => 'rar';

  /// Detection (§5): `52 61 72 21 1A 07 01 00` (v5) or
  /// `52 61 72 21 1A 07 00` (v4) at offset 0.
  @override
  Future<bool> matches(ByteSource source) async {
    if (source.length < 8) return false;
    final head = await source.read(0, 8);
    // The shared prefix is 6 bytes ('Rar!\x1A\x07'); byte 6 then reads
    // 0x00 (RAR1–4) or 0x01 (RAR5).
    for (var i = 0; i < 6; i++) {
      if (head[i] != rar4Signature[i]) return false;
    }
    return head[6] == 0x00 || head[6] == 0x01;
  }

  @override
  Future<ArchiveReader> openReader(
    ByteSource source,
    ArchiveReadOptions options,
  ) async {
    final head = await source.read(0, 8);
    final isV5 = head[6] == 0x01 && head[7] == 0x00;
    return RarReader.parse(this, source, options, isRar4: !isV5);
  }
}

import 'dart:typed_data';

import 'entry.dart';
import 'format.dart';

/// Format-reader SPI: what a format package implements to expose one opened
/// archive (§5). Application code uses the `Archive` facade in
/// `package:koni_archive` instead; this interface is for format implementers.
///
/// ## Contract
///
/// - Construction (via [ArchiveFormat.openReader]) parses container metadata
///   exactly once, eagerly — O(entry count), no content decompression (§4).
/// - [entries] is immutable, in archive index order, and includes duplicate
///   paths where the format allows them; paths are normalized (§7).
/// - [openRead] returns a fresh single-subscription stream with bounded
///   memory use regardless of entry size. Multiple entry streams may be
///   open simultaneously. Entry-scoped failures (unsupported compression,
///   encryption) throw here — never at open time (§9); mid-decode failures
///   are emitted as typed errors through the stream. Cancelling a
///   subscription releases all resources it holds.
/// - The reader does not own the [ByteSource]; the facade closes the source
///   after [close].
abstract class ArchiveReader {
  /// The format this reader was opened by.
  ArchiveFormat get format;

  /// All entries, in archive index order (§4). Unmodifiable.
  List<ArchiveEntry> get entries;

  /// Streams the decoded content of [entry].
  ///
  /// [entry] must be one of [entries] (readers may rely on identity, not
  /// path lookup).
  Stream<Uint8List> openRead(ArchiveEntry entry);

  /// Releases reader-held resources (caches, in-flight decodes). Idempotent.
  /// Does not close the underlying [ByteSource].
  Future<void> close();
}

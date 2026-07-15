/// `dart:io` sugar for the koni_archive facade — explicit opt-in import for
/// VM and Flutter-native platforms (§2). Re-exports the platform-neutral
/// facade, so a VM program needs only this one import.
library;

import 'package:koni_archive_core/io.dart';

import 'koni_archive.dart';

export 'package:koni_archive_core/io.dart' show FileByteSource;

export 'koni_archive.dart';

/// Opens the archive file at [path], auto-detecting its format.
///
/// Sugar for [Archive.open] over a [FileByteSource]. (A static
/// `Archive.openFile` is impossible without pulling `dart:io` into the
/// platform-neutral main library, hence a top-level function — see
/// `doc/notes.md`.) The file is closed if opening fails.
Future<Archive> openArchiveFile(
  String path, {
  ArchiveFormatRegistry? registry,
  ArchiveFormat? format,
  ArchiveReadOptions options = const ArchiveReadOptions(),
}) async {
  final source = await FileByteSource.open(path);
  try {
    return await Archive.open(
      source,
      registry: registry,
      format: format,
      options: options,
    );
  } catch (_) {
    await source.close();
    rethrow;
  }
}

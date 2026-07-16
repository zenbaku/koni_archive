/// Browser sugar for the koni_archive facade: explicit opt-in import for
/// the web, compiling under both dart2js and dart2wasm. Re-exports the
/// platform-neutral facade, so a web program needs only this one import.
library;

import 'package:koni_archive_core/web.dart';
import 'package:web/web.dart' as web;

import 'koni_archive.dart';

export 'package:koni_archive_core/web.dart' show BlobByteSource;

export 'koni_archive.dart';

/// Opens [blob] (a browser `Blob`, including `File` from an
/// `<input type=file>` or drag-and-drop) as an archive, auto-detecting its
/// format.
///
/// Sugar for [Archive.open] over a [BlobByteSource].
Future<Archive> openArchiveBlob(
  web.Blob blob, {
  ArchiveFormatRegistry? registry,
  ArchiveFormat? format,
  ArchiveReadOptions options = const ArchiveReadOptions(),
}) => Archive.open(
  BlobByteSource(blob),
  registry: registry,
  format: format,
  options: options,
);

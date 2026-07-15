/// ZIP reader for the koni_archive ecosystem, including CBZ comic archives.
///
/// Most applications use the `koni_archive` facade, which registers
/// [ZipFormat] automatically. Depend on this package directly only to
/// build a custom format registry.
///
/// Supported: end-of-central-directory scan (comments, self-extracting
/// prefixes), stored entries with CRC-32 verification, data-descriptor
/// archives, UTF-8 and CP437 filenames, DOS + extended (`UT`) timestamps.
/// Detected with typed errors: deflate and other compression methods
/// (until the codec milestones land), encrypted entries, ZIP64,
/// multi-volume archives. See `doc/` for the feature matrix.
library;

export 'src/zip_format.dart';
export 'src/zip_reader.dart' show ZipReader;
export 'src/zip_write_format.dart';
export 'src/zip_writer.dart' show ZipWriter;

/// `dart:io` byte sources for koni_archive: explicit opt-in import for
/// VM and Flutter-native platforms.
///
/// Also re-exports the platform-neutral core, so a VM program needs only
/// this one import.
library;

export 'koni_archive_core.dart';
export 'src/io/file_byte_sink.dart';
export 'src/io/file_byte_source.dart';

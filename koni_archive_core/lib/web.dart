/// Browser byte sources for koni_archive — explicit opt-in import for the
/// web (§2). Compiles under both dart2js and dart2wasm.
///
/// Also re-exports the platform-neutral core, so a web program needs only
/// this one import.
library;

export 'koni_archive_core.dart';
export 'src/web/blob_byte_source.dart';

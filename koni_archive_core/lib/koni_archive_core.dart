/// Core abstractions for the koni_archive ecosystem: byte sources, the
/// entry model, typed exceptions, checksums, and the format-detection
/// registry.
///
/// This library is platform-neutral (no `dart:io`, no JS interop) and
/// compiles everywhere Dart runs, including dart2wasm. Platform-specific
/// byte sources are explicit opt-in imports:
///
/// - `package:koni_archive_core/io.dart`: `FileByteSource` (VM,
///   Flutter-native);
/// - `package:koni_archive_core/web.dart`: `BlobByteSource` (browser).
///
/// Application authors normally depend on `package:koni_archive` (the
/// facade) instead; this package is the SPI for format implementers.
library;

export 'src/byte_reader.dart';
export 'src/byte_sink.dart';
export 'src/byte_source.dart';
export 'src/checksums.dart';
export 'src/entry.dart';
export 'src/exceptions.dart';
export 'src/format.dart';
export 'src/path_normalization.dart';
export 'src/read_options.dart';
export 'src/reader.dart';
export 'src/write_options.dart';
export 'src/writer.dart';

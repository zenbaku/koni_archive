/// HTTP-range [ByteSource] for the koni_archive ecosystem: read entries out
/// of a remote archive over HTTP `Range` requests without downloading the
/// whole file.
///
/// ```dart
/// import 'package:koni_archive/koni_archive.dart';
/// import 'package:koni_http_source/koni_http_source.dart';
///
/// final source = await HttpRangeByteSource.open(
///   Uri.parse('https://example.com/volume01.cbz'),
/// );
/// final archive = await Archive.open(source); // pass format: to skip probing
/// final page = archive.glob('*.png').first;
/// final bytes = await archive.readBytes(page);
/// await archive.close(); // closes the source, and its HTTP client
/// ```
///
/// [ByteSource]: package:koni_archive_core/koni_archive_core.dart
library;

export 'src/http_range_byte_source.dart'
    show HttpRangeByteSource, HttpRangeFetcher, HttpRangeResponse;
export 'src/http_range_exception.dart' show HttpRangeException;

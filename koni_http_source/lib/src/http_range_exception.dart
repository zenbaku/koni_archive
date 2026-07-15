/// Thrown when the HTTP transport or the server's range support fails —
/// distinct from an `ArchiveException`, which signals a malformed *archive*.
///
/// Catching `ArchiveException` does **not** catch this: a network error or a
/// server that ignores `Range` is a transport-layer problem, not archive
/// corruption. A read whose range simply extends past the end of the source
/// still throws the core `UnexpectedEofException` (no request is made).
final class HttpRangeException implements Exception {
  /// Creates an exception describing a transport or range-support failure.
  HttpRangeException(this.message, {this.uri, this.statusCode});

  /// Human-readable description of what went wrong.
  final String message;

  /// The URL involved, when known.
  final Uri? uri;

  /// The HTTP status code, when the failure was an unexpected response.
  final int? statusCode;

  @override
  String toString() {
    final where = uri == null ? '' : ' ($uri)';
    final code = statusCode == null ? '' : ' [HTTP $statusCode]';
    return 'HttpRangeException: $message$where$code';
  }
}

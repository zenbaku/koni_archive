import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:koni_archive_core/koni_archive_core.dart';

import 'http_range_exception.dart';

/// A raw HTTP response to a single range request, handed to
/// [HttpRangeByteSource] by its [HttpRangeFetcher].
///
/// The source parses [headers] itself (Content-Range, ETag), so a fetcher
/// (including a test fake) only has to surface the wire response verbatim.
/// Header keys are lower-cased on construction for case-insensitive lookup.
final class HttpRangeResponse {
  /// Wraps a response; [headers] keys are lower-cased.
  HttpRangeResponse({
    required this.statusCode,
    required Map<String, String> headers,
    required this.body,
  }) : headers = {
         for (final e in headers.entries) e.key.toLowerCase(): e.value,
       };

  /// HTTP status code (206 for a satisfied range, 200 if the server ignored
  /// `Range` or the `If-Range` validator no longer matches).
  final int statusCode;

  /// Response headers, keyed by lower-cased name.
  final Map<String, String> headers;

  /// The response body bytes.
  final Uint8List body;
}

/// Performs one HTTP GET with the given request [headers] (the source adds
/// `Range` and, after the first request, `If-Range`) and returns the raw
/// response. Injected so [HttpRangeByteSource] is transport-agnostic:
/// [HttpRangeByteSource.open] supplies a `package:http` implementation, and
/// tests supply an in-memory fake.
typedef HttpRangeFetcher =
    Future<HttpRangeResponse> Function(Map<String, String> headers);

/// A [ByteSource] backed by HTTP `Range` requests: it reads entries out of a
/// remote archive without downloading the whole file, so a comic/ebook reader
/// can fetch one page from a remote CBZ/CB7 with a handful of requests.
///
/// ## How it works
///
/// - [open] (or [withFetcher]) probes the resource once with `Range:
///   bytes=0-0`. A `206 Partial Content` confirms range support; the total
///   size is read from the `Content-Range` header (never `Content-Length`,
///   which is `1` for that probe). A `200` means the server ignored the
///   range: [HttpRangeException].
/// - Each [read] issues one ranged GET and returns exactly the requested
///   bytes. Requests are independent, so overlapping reads satisfy the pread
///   contract with no locking.
/// - The probe captures the resource's `ETag`/`Last-Modified` and every read
///   sends it back as `If-Range`. If the remote file changes mid-read the
///   server answers `200` (full body) instead of `206`, which surfaces as a
///   typed [HttpRangeException] rather than silently-wrong bytes.
///
/// ## Notes
///
/// - `Archive.open` probes formats, costing a few extra requests; a caller
///   who knows the format should pass `format:` to skip detection.
/// - Reading past the end of the source throws the core
///   `UnexpectedEofException` without making a request; transport and
///   range-support failures throw [HttpRangeException].
final class HttpRangeByteSource implements ByteSource {
  HttpRangeByteSource._(
    this._fetch,
    this.length,
    this.name,
    this._ifRange,
    this._onClose,
  );

  final HttpRangeFetcher _fetch;

  /// The `If-Range` validator (ETag or Last-Modified) captured at [open], or
  /// null when the server offered neither.
  final String? _ifRange;

  /// Closes the transport this source created (null when the caller owns it).
  final Future<void> Function()? _onClose;

  bool _closed = false;

  @override
  final String? name;

  @override
  final int length;

  /// Opens a source over [url] using `package:http`.
  ///
  /// Pass a [client] to reuse a connection pool or add auth/retry (a wrapped
  /// `http.Client`); when omitted, an internal client is created and closed
  /// by [close]. [headers] are sent on every request (e.g. `Authorization`).
  /// [name] overrides the display name, which otherwise defaults to the URL's
  /// last path segment (matters for a bare `.gz` with no FNAME).
  static Future<HttpRangeByteSource> open(
    Uri url, {
    http.Client? client,
    Map<String, String>? headers,
    String? name,
  }) async {
    final ownsClient = client == null;
    final c = client ?? http.Client();
    Future<HttpRangeResponse> fetch(Map<String, String> requestHeaders) async {
      final merged = <String, String>{...?headers, ...requestHeaders};
      final http.Response response;
      try {
        response = await c.get(url, headers: merged);
      } on Object catch (e) {
        throw HttpRangeException('request failed: $e', uri: url);
      }
      return HttpRangeResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.bodyBytes,
      );
    }

    try {
      return await withFetcher(
        fetch,
        name: name ?? _nameFromUri(url),
        uri: url,
        onClose: ownsClient ? () async => c.close() : null,
      );
    } catch (_) {
      // The probe failed, so `withFetcher` never took ownership of the client
      // it would close in `close()`; close the one we created here.
      if (ownsClient) c.close();
      rethrow;
    }
  }

  /// Opens a source over a caller-supplied [fetch], the transport-agnostic
  /// entry point (a browser `Client`, a custom stack, or a test fake).
  ///
  /// [onClose] is invoked by [close] to release a transport the caller wants
  /// this source to own; [uri] and [name] are cosmetic.
  static Future<HttpRangeByteSource> withFetcher(
    HttpRangeFetcher fetch, {
    String? name,
    Uri? uri,
    Future<void> Function()? onClose,
  }) async {
    final probe = await fetch({'range': 'bytes=0-0'});
    if (probe.statusCode == 200) {
      throw HttpRangeException(
        'server does not support range requests (answered 200, not 206)',
        uri: uri,
        statusCode: 200,
      );
    }
    if (probe.statusCode != 206) {
      throw HttpRangeException(
        'range probe was not satisfied',
        uri: uri,
        statusCode: probe.statusCode,
      );
    }
    final total = _parseContentRangeTotal(probe.headers['content-range']);
    if (total == null) {
      throw HttpRangeException(
        'server did not report the total size '
        '(Content-Range: ${probe.headers['content-range']})',
        uri: uri,
      );
    }
    // Pick an `If-Range` validator. A *weak* ETag (`W/"..."`) must never be
    // used: RFC 9110 says a weak validator can't validate a range, so a
    // compliant server answers such a request with `200` (the whole body),
    // which would make every read fail. Prefer a strong ETag, else fall back
    // to Last-Modified (date-based, coarser but usable), else send none.
    final etag = probe.headers['etag'];
    final ifRange =
        (etag != null && !etag.startsWith('W/'))
            ? etag
            : probe.headers['last-modified'];
    return HttpRangeByteSource._(fetch, total, name, ifRange, onClose);
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    // Past-EOF and negative arguments are archive/programmer errors, caught
    // before any request goes out.
    checkByteSourceRange(this, offset, length);
    if (_closed) {
      throw ArchiveClosedException('read($offset, $length) after close()');
    }
    // A zero-length read would form the malformed range `bytes=o-(o-1)`.
    if (length == 0) return Uint8List(0);

    final end = offset + length - 1;
    final response = await _fetch({
      'range': 'bytes=$offset-$end',
      if (_ifRange != null) 'if-range': _ifRange,
    });

    if (response.statusCode != 206) {
      // A 200 here means the resource changed under the If-Range validator
      // (or the server stopped honoring ranges): fail loudly, never return
      // bytes from a different version of the file.
      throw HttpRangeException(
        'range $offset-$end was not satisfied '
        '(the remote resource may have changed)',
        statusCode: response.statusCode,
      );
    }
    if (response.body.length != length) {
      throw HttpRangeException(
        'range $offset-$end returned ${response.body.length} byte(s), '
        'expected $length',
        statusCode: response.statusCode,
      );
    }
    return response.body;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose?.call();
  }

  /// Parses the total size from a `Content-Range: bytes <start>-<end>/<total>`
  /// header. Returns null when the header is absent, malformed, or reports an
  /// unknown total (`/*`).
  static int? _parseContentRangeTotal(String? header) {
    if (header == null) return null;
    final slash = header.lastIndexOf('/');
    if (slash < 0) return null;
    final total = header.substring(slash + 1).trim();
    if (total == '*') return null;
    return int.tryParse(total);
  }

  static String? _nameFromUri(Uri url) {
    if (url.pathSegments.isEmpty) return null;
    final last = url.pathSegments.last;
    return last.isEmpty ? null : last;
  }
}

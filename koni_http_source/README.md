# koni_http_source

HTTP-range `ByteSource` for the
[koni_archive](https://github.com/koni-archive) ecosystem — read entries out
of a **remote** archive over HTTP `Range` requests, without downloading the
whole file. A comic/ebook reader can fetch a single page from a remote
CBZ/CB7 with a handful of requests. Pure Dart; runs on the VM, Flutter, and
the web.

```dart
import 'package:koni_archive/koni_archive.dart'; // Archive.open
import 'package:koni_http_source/koni_http_source.dart';

final source = await HttpRangeByteSource.open(
  Uri.parse('https://example.com/volume01.cbz'),
);
final archive = await Archive.open(source);

final page = archive.glob('*.png').first;
await for (final chunk in archive.openRead(page)) {
  // streamed straight from the network, CRC-verified
}
await archive.close(); // closes the source, and the HTTP client it created
```

`Archive.open` auto-detects the format, which costs a few extra requests
over the wire; a caller who knows the format can import its package (e.g.
`package:koni_zip/koni_zip.dart`) and pass `format: const ZipFormat()` to
skip detection.

## How it works

- `open()` probes the resource once with `Range: bytes=0-0`. A `206 Partial
  Content` confirms range support; the total size comes from the
  `Content-Range` header (not `Content-Length`, which is `1` for that probe).
  A `200` means the server ignored the range — a typed `HttpRangeException`.
- Each `read` is one ranged GET returning exactly the requested bytes.
  Requests are independent, so overlapping reads satisfy the `ByteSource`
  pread contract with no locking.
- The probe captures the resource's `ETag`/`Last-Modified`, and every read
  sends it back as `If-Range`. If the remote file changes mid-read the server
  answers `200` instead of `206`, which surfaces as an `HttpRangeException`
  rather than silently-wrong bytes. (Entry-data corruption is also caught by
  the reader's default CRC verification; `If-Range` additionally protects the
  header and central-directory reads, which CRC does not cover.)

## Errors

- Reading past the end of the source throws the core `UnexpectedEofException`
  **without making a request**.
- Transport failures and unsupported range servers throw `HttpRangeException`
  — a category distinct from `ArchiveException`, so catching the latter does
  **not** catch network errors.

## Custom transports

`open()` uses `package:http`; pass a `client:` to reuse a connection pool or
add auth/retry (a wrapped `http.Client`), or supply `headers:` sent on every
request. For a browser `Client`, a bespoke stack, or tests, use
`HttpRangeByteSource.withFetcher(...)` with your own range fetcher — the
package parses `Content-Range`/`If-Range` itself, so a fetcher only surfaces
the raw response.

## Testing note

The range/EOF/`If-Range`/`Content-Range` **logic** is covered on the VM,
dart2js, and dart2wasm via an in-memory fake fetcher; the real transport is
covered on the VM against a `dart:io` `HttpServer` with genuine `Range`
support. The `package:http` **`BrowserClient`** path — and its CORS
requirements (the server must permit the `Range` request header and expose
`Content-Range`) — is not exercised in CI.

> **Status: pre-release** (0.x, git-only). The API stays 0.x with lockstep
> minor bumps until it stabilizes — see the repository's `ROADMAP.md`.

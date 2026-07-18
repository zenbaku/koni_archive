# Changelog

## 0.10.0 (2026-07-18)

- Lockstep release; no changes to this package since 0.9.0.

## 0.9.0 (2026-07-17)

- Lockstep release; no changes to this package since 0.8.0.

## 0.8.0 (2026-07-16)

- Lockstep release; no changes to this package since 0.7.0.

## 0.7.0 (2026-07-16)

- Lockstep release; no changes to this package since 0.6.0.

## 0.6.0 (2026-07-15)

- Initial release (joins the ecosystem at its 0.6.0 lockstep version):
  `HttpRangeByteSource`, an HTTP-range `ByteSource` that
  reads entries out of a remote archive without downloading the whole file.
  - `open(Uri)` over `package:http` (or a caller-supplied `http.Client`);
    `withFetcher(...)` for a transport-agnostic fetcher (browser client,
    custom stack, tests).
  - Probes the total size from `Content-Range` (never `Content-Length`);
    sends the resource's `ETag`/`Last-Modified` back as `If-Range` so a
    mid-read change surfaces as a typed `HttpRangeException` instead of
    silently-wrong bytes.
  - Past-EOF reads throw the core `UnexpectedEofException` without a request;
    zero-length reads short-circuit; concurrent reads are pread-safe.
  - Verified on VM + dart2js + dart2wasm (in-memory fake fetcher) and on the
    VM against a real `dart:io` `HttpServer` with genuine `Range` support.

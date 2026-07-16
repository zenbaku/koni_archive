import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_http_source/koni_http_source.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

/// A range-capable HTTP server simulated over an in-memory buffer. It returns
/// raw status + headers + body so the package's own Content-Range / If-Range
/// handling is what gets exercised. Runs on every platform (no `dart:io`), so
/// the source logic is covered under dart2js and dart2wasm too; the real
/// `package:http` transport is covered by the VM `HttpServer` test.
final class FakeRangeServer {
  FakeRangeServer(this.bytes, {this.etag = '"v1"', this.supportsRange = true});

  Uint8List bytes;
  String? etag;
  bool supportsRange;
  int requests = 0;

  Future<HttpRangeResponse> fetch(Map<String, String> headers) async {
    requests++;
    final range = headers['range'];
    if (!supportsRange || range == null) {
      return HttpRangeResponse(
        statusCode: 200,
        headers: {if (etag != null) 'etag': etag!},
        body: bytes,
      );
    }
    // If-Range: a weak validator (`W/"..."`) can't validate a range, and a
    // validator that no longer matches means the resource changed; either
    // way the server sends the whole (new) resource with 200, not a 206 slice.
    final ifRange = headers['if-range'];
    if (ifRange != null && (ifRange.startsWith('W/') || ifRange != etag)) {
      return HttpRangeResponse(
        statusCode: 200,
        headers: {if (etag != null) 'etag': etag!},
        body: bytes,
      );
    }
    final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
    if (match == null) {
      return HttpRangeResponse(
        statusCode: 400,
        headers: {},
        body: Uint8List(0),
      );
    }
    final start = int.parse(match.group(1)!);
    final requestedEnd = int.parse(match.group(2)!);
    if (start >= bytes.length || start > requestedEnd) {
      return HttpRangeResponse(
        statusCode: 416,
        headers: {'content-range': 'bytes */${bytes.length}'},
        body: Uint8List(0),
      );
    }
    final end = requestedEnd < bytes.length ? requestedEnd : bytes.length - 1;
    return HttpRangeResponse(
      statusCode: 206,
      headers: {
        'content-range': 'bytes $start-$end/${bytes.length}',
        if (etag != null) 'etag': etag!,
      },
      body: Uint8List.fromList(Uint8List.sublistView(bytes, start, end + 1)),
    );
  }
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// Builds a CBZ-shaped ZIP with the given entries (deflate + one stored).
Future<Uint8List> buildZip(Map<String, Uint8List> entries) async {
  final sink = BytesBuilderSink();
  final writer = const ZipWriteFormat().openWriter(
    sink,
    const ArchiveWriteOptions(),
  );
  for (final e in entries.entries) {
    await writer.addBytes(ArchiveEntrySpec(path: e.key), e.value);
  }
  await writer.close();
  await sink.close();
  return sink.takeBytes();
}

Future<Uint8List> readEntry(ByteSource source, String path) async {
  final reader = await const ZipFormat().openReader(
    source,
    const ArchiveReadOptions(),
  );
  final entry = reader.entries.firstWhere((e) => e.path == path);
  final chunks = await reader.openRead(entry).toList();
  return Uint8List.fromList(chunks.expand<int>((c) => c).toList());
}

void main() {
  // A ZIP big enough that reading one page must NOT pull the whole file.
  late Map<String, Uint8List> entries;
  late Uint8List zip;

  setUp(() async {
    entries = {
      'page001.txt': _bytes('the quick brown fox ' * 500),
      'page002.txt': _bytes('a totally different page ' * 500),
      'cover.bin': Uint8List.fromList(
        List.generate(20000, (i) => (i * 7) & 0xFF),
      ),
    };
    zip = await buildZip(entries);
  });

  group('reads a remote archive over ranges', () {
    test('an entry decodes byte-for-byte through the source', () async {
      final server = FakeRangeServer(zip);
      final source = await HttpRangeByteSource.withFetcher(
        server.fetch,
        name: 'volume.cbz',
      );
      expect(source.length, zip.length);
      expect(source.name, 'volume.cbz');

      expect(await readEntry(source, 'page002.txt'), entries['page002.txt']);
      expect(await readEntry(source, 'cover.bin'), entries['cover.bin']);
    });

    test('reading one page needs only a handful of requests', () async {
      final server = FakeRangeServer(zip);
      final source = await HttpRangeByteSource.withFetcher(server.fetch);
      await readEntry(source, 'page001.txt');
      // Open probe + EOCD tail + central directory + local header + data:
      // a small, size-independent number, never a whole-file download.
      expect(server.requests, lessThanOrEqualTo(10));
    });
  });

  group('range/EOF semantics', () {
    test('reading past the end throws without a request', () async {
      final server = FakeRangeServer(zip);
      final source = await HttpRangeByteSource.withFetcher(server.fetch);
      final before = server.requests;
      await expectLater(
        source.read(zip.length, 1),
        throwsA(isA<UnexpectedEofException>()),
      );
      expect(server.requests, before, reason: 'no request for a past-EOF read');
    });

    test('a zero-length read returns empty without a request', () async {
      final server = FakeRangeServer(zip);
      final source = await HttpRangeByteSource.withFetcher(server.fetch);
      final before = server.requests;
      expect(await source.read(10, 0), isEmpty);
      expect(server.requests, before);
    });

    test('read after close throws ArchiveClosedException', () async {
      final server = FakeRangeServer(zip);
      final source = await HttpRangeByteSource.withFetcher(server.fetch);
      await source.close();
      await expectLater(
        source.read(0, 4),
        throwsA(isA<ArchiveClosedException>()),
      );
    });
  });

  group('server-support failures are typed', () {
    test('a server that ignores Range is rejected at open', () async {
      final server = FakeRangeServer(zip, supportsRange: false);
      await expectLater(
        HttpRangeByteSource.withFetcher(server.fetch),
        throwsA(isA<HttpRangeException>()),
      );
    });

    test(
      'a 206 without Content-Range (no total) is rejected at open',
      () async {
        Future<HttpRangeResponse> fetch(Map<String, String> h) async =>
            HttpRangeResponse(
              statusCode: 206,
              headers: const {}, // no content-range
              body: Uint8List(1),
            );
        await expectLater(
          HttpRangeByteSource.withFetcher(fetch),
          throwsA(isA<HttpRangeException>()),
        );
      },
    );

    test('a weak ETag is not used as If-Range, so reads still work', () async {
      // Servers behind proxies/gzip/CDNs often emit weak ETags. A compliant
      // server rejects `If-Range: W/"..."` with 200, so the source must not
      // send a weak validator; otherwise every read would fail.
      final server = FakeRangeServer(zip, etag: 'W/"weak-v1"');
      final source = await HttpRangeByteSource.withFetcher(server.fetch);
      expect(await readEntry(source, 'page002.txt'), entries['page002.txt']);
    });

    test(
      'a resource that changes mid-read fails loudly, not silently',
      () async {
        final server = FakeRangeServer(zip, etag: '"v1"');
        final source = await HttpRangeByteSource.withFetcher(server.fetch);
        // The file is replaced under us: the If-Range validator no longer
        // matches, so the server answers 200 (full body), which must surface
        // as a typed error, never as bytes from a different version.
        server.etag = '"v2"';
        await expectLater(
          source.read(0, 16),
          throwsA(isA<HttpRangeException>()),
        );
      },
    );
  });

  test('Content-Range total is parsed, not Content-Length', () async {
    // The 0-0 probe body is 1 byte; a naive Content-Length reading would make
    // the source think the whole resource is 1 byte long.
    final server = FakeRangeServer(zip);
    final source = await HttpRangeByteSource.withFetcher(server.fetch);
    expect(source.length, zip.length);
    expect(source.length, greaterThan(1));
  });
}

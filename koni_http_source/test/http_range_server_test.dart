@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_http_source/koni_http_source.dart';
import 'package:koni_zip/koni_zip.dart';
import 'package:test/test.dart';

/// End-to-end over a real `dart:io` [HttpServer] with genuine `Range`
/// support, driven through the `package:http` transport — the real-transport
/// gate for [HttpRangeByteSource.open] (the fake-fetcher test covers the
/// range/EOF logic cross-platform).

const _etag = '"koni-range-test"';

/// Serves [data] with byte-range support. `/no-range/...` ignores `Range` (to
/// exercise the unsupported-server path). Returns the number of requests.
Future<HttpServer> serve(Uint8List data) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    final rangeEnabled = !req.uri.path.startsWith('/no-range/');
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (!rangeEnabled || range == null) {
      res.statusCode = HttpStatus.ok;
      res.headers.set(HttpHeaders.etagHeader, _etag);
      res.add(data);
      await res.close();
      return;
    }
    final ifRange = req.headers.value('if-range');
    if (ifRange != null && ifRange != _etag) {
      res.statusCode = HttpStatus.ok;
      res.headers.set(HttpHeaders.etagHeader, _etag);
      res.add(data);
      await res.close();
      return;
    }
    final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
    if (match == null) {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final requestedEnd = int.parse(match.group(2)!);
    if (start >= data.length || start > requestedEnd) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set('content-range', 'bytes */${data.length}');
      await res.close();
      return;
    }
    final end = requestedEnd < data.length ? requestedEnd : data.length - 1;
    res.statusCode = HttpStatus.partialContent;
    res.headers.set('content-range', 'bytes $start-$end/${data.length}');
    res.headers.set(HttpHeaders.etagHeader, _etag);
    res.add(Uint8List.sublistView(data, start, end + 1));
    await res.close();
  });
  return server;
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

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

void main() {
  final entries = {
    'page001.txt': _bytes('the quick brown fox ' * 500),
    'page002.txt': _bytes('a wholly different page ' * 500),
    'cover.bin': Uint8List.fromList(
      List.generate(20000, (i) => (i * 11) & 0xFF),
    ),
  };
  late Uint8List zip;
  late HttpServer server;
  late Uri base;

  setUp(() async {
    zip = await buildZip(entries);
    server = await serve(zip);
    base = Uri.parse('http://${server.address.host}:${server.port}');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('open() reports length and a name derived from the URL', () async {
    final source = await HttpRangeByteSource.open(
      base.replace(path: '/comics/volume01.cbz'),
    );
    expect(source.length, zip.length);
    expect(source.name, 'volume01.cbz');
    await source.close();
  });

  test('reads a page from the remote ZIP byte-for-byte', () async {
    final source = await HttpRangeByteSource.open(
      base.replace(path: '/volume01.cbz'),
    );
    final reader = await const ZipFormat().openReader(
      source,
      const ArchiveReadOptions(),
    );
    for (final path in ['page002.txt', 'cover.bin']) {
      final entry = reader.entries.firstWhere((e) => e.path == path);
      final chunks = await reader.openRead(entry).toList();
      final got = Uint8List.fromList(chunks.expand<int>((c) => c).toList());
      expect(got, entries[path], reason: path);
    }
    await source.close();
  });

  test('a server without range support is rejected at open', () async {
    await expectLater(
      HttpRangeByteSource.open(base.replace(path: '/no-range/volume01.cbz')),
      throwsA(isA<HttpRangeException>()),
    );
  });

  test('a connection failure surfaces as HttpRangeException', () async {
    // Nothing is listening on this port after the server is torn down; use a
    // fresh bind to grab a free port, then close it immediately.
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadUri = Uri.parse('http://${dead.address.host}:${dead.port}/x.zip');
    await dead.close(force: true);
    await expectLater(
      HttpRangeByteSource.open(deadUri),
      throwsA(isA<HttpRangeException>()),
    );
  });
}

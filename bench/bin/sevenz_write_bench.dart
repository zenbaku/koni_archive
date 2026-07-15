// 7z-write benchmarks (P2-4a, PROMPT_V1.md §10): end-to-end archive
// creation through SevenZWriter. package:archive has no 7z support, so times
// are absolute, not ratios.
//
//   dart run --no-enable-asserts bench/bin/sevenz_write_bench.dart
//
// Two shapes: a CB7 of already-compressed pages stored with Copy (the
// page-flip target), and many small deflated files (the container-overhead
// case). Note the memory line: 7z writing buffers the compressed streams
// until close() by construction (the leading signature header references the
// trailing header) — reported here, not asserted.

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';

const int warmupRuns = 2;
const int measuredRuns = 5;

Future<void> main() async {
  // A CB7's pages are already-compressed images: stored with Copy.
  const pageCount = 120;
  const pageSize = 512 * 1024;
  final pages = <Uint8List>[];
  for (var i = 0; i < pageCount; i++) {
    final page = Uint8List(pageSize);
    for (var j = 0; j < pageSize; j++) {
      page[j] = (j * 31 + i * 7) & 0xFF; // incompressible-ish
    }
    pages.add(page);
  }

  // Many small text-ish files: the deflate + container-overhead case.
  const smallCount = 5000;
  final small = <Uint8List>[];
  for (var i = 0; i < smallCount; i++) {
    small.add(Uint8List.fromList('entry $i: ${'payload ' * 8}'.codeUnits));
  }

  stdout.writeln('# 7z-write benchmarks (P2-4a)');
  stdout.writeln('');
  stdout.writeln('- date: ${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('- dart: ${Platform.version}');
  stdout.writeln('- os: ${Platform.operatingSystemVersion}');
  stdout.writeln('- runs: best of $measuredRuns (after $warmupRuns warmup)');
  stdout.writeln('');
  stdout.writeln('| scenario | time | throughput (input) | archive |');
  stdout.writeln('| --- | --- | --- | --- |');

  final cb7Bytes = pageCount * pageSize;
  await _row('CB7: $pageCount stored pages (512 KiB)', cb7Bytes, () async {
    return _write(pages, ArchiveCompression.stored, 'page');
  });

  final smallBytes = small.fold<int>(0, (a, b) => a + b.length);
  await _row('$smallCount deflated small files', smallBytes, () async {
    return _write(small, ArchiveCompression.deflate, 'e');
  });
}

Future<int> _write(
  List<Uint8List> contents,
  ArchiveCompression compression,
  String prefix,
) async {
  final sink = BytesBuilderSink();
  final writer = const SevenZWriteFormat().openWriter(
    sink,
    ArchiveWriteOptions(compression: compression),
  );
  for (var i = 0; i < contents.length; i++) {
    await writer.addBytes(ArchiveEntrySpec(path: '$prefix$i'), contents[i]);
  }
  await writer.close();
  await sink.close();
  return sink.takeBytes().length;
}

Future<void> _row(
  String name,
  int inputBytes,
  Future<int> Function() run,
) async {
  var archiveSize = 0;
  for (var i = 0; i < warmupRuns; i++) {
    archiveSize = await run();
  }
  var best = const Duration(days: 1);
  for (var i = 0; i < measuredRuns; i++) {
    final watch = Stopwatch()..start();
    await run();
    watch.stop();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  final mbps = inputBytes / (1024 * 1024) / (best.inMicroseconds / 1e6);
  stdout.writeln(
    '| $name | ${(best.inMicroseconds / 1000).toStringAsFixed(1)} ms | '
    '${mbps.toStringAsFixed(0)} MiB/s | ${_mb(archiveSize)} MiB |',
  );
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

// TAR benchmarks (M2): koni_archive vs package:archive.
//
//   dart run --no-enable-asserts bench/bin/tar_bench.dart
//
// Scenarios:
//   1. list: index a 20k-entry archive (no content decode)
//   2. extract: full sequential extract of all content
//
// Results are printed as a markdown table; commit them under
// bench/results/. Performance is measured, not asserted.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as pkg_archive;
import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_tar/koni_tar.dart';

const int warmupRuns = 2;
const int measuredRuns = 5;

Future<void> main() async {
  final listArchive = _buildTar(entryCount: 20000, entrySize: 512);
  final extractArchive = _buildTar(entryCount: 256, entrySize: 256 * 1024);

  stdout.writeln('# TAR benchmarks (M2)');
  stdout.writeln('');
  stdout.writeln('- date: ${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('- dart: ${Platform.version}');
  stdout.writeln('- os: ${Platform.operatingSystemVersion}');
  stdout.writeln(
    '- inputs: list = 20k entries x 512 B '
    '(${_mb(listArchive.length)} MiB); '
    'extract = 256 entries x 256 KiB (${_mb(extractArchive.length)} MiB)',
  );
  stdout.writeln('- runs: best of $measuredRuns (after $warmupRuns warmup)');
  stdout.writeln('');
  stdout.writeln('| scenario | koni_archive | package:archive | ratio |');
  stdout.writeln('| --- | --- | --- | --- |');

  await _scenario(
    'list 20k entries',
    ours: () async {
      final reader = await const TarFormat().openReader(
        MemoryByteSource(listArchive),
        const ArchiveReadOptions(),
      );
      _use(reader.entries.length);
    },
    theirs: () async {
      final archive = pkg_archive.TarDecoder().decodeBytes(listArchive);
      _use(archive.files.length);
    },
  );

  await _scenario(
    'sequential extract 64 MiB',
    ours: () async {
      final reader = await const TarFormat().openReader(
        MemoryByteSource(extractArchive),
        const ArchiveReadOptions(),
      );
      var total = 0;
      for (final entry in reader.entries) {
        await for (final chunk in reader.openRead(entry)) {
          total += chunk.length;
        }
      }
      _use(total);
    },
    theirs: () async {
      final archive = pkg_archive.TarDecoder().decodeBytes(extractArchive);
      var total = 0;
      for (final file in archive.files) {
        if (file.isFile) total += (file.content as List<int>).length;
      }
      _use(total);
    },
  );
}

Future<void> _scenario(
  String name, {
  required Future<void> Function() ours,
  required Future<void> Function() theirs,
}) async {
  final ourBest = await _best(ours);
  final theirBest = await _best(theirs);
  final ratio = theirBest.inMicroseconds / ourBest.inMicroseconds;
  stdout.writeln(
    '| $name | ${_ms(ourBest)} ms | ${_ms(theirBest)} ms | '
    '${ratio.toStringAsFixed(2)}x |',
  );
}

Future<Duration> _best(Future<void> Function() run) async {
  for (var i = 0; i < warmupRuns; i++) {
    await run();
  }
  var best = const Duration(days: 1);
  for (var i = 0; i < measuredRuns; i++) {
    final watch = Stopwatch()..start();
    await run();
    watch.stop();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  return best;
}

String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

int _sink = 0;
void _use(int value) => _sink ^= value; // defeat dead-code elimination

/// Minimal in-memory ustar emitter, bench-only code, not shipped.
Uint8List _buildTar({required int entryCount, required int entrySize}) {
  final builder = BytesBuilder(copy: false);
  final content = Uint8List(entrySize);
  for (var i = 0; i < entrySize; i++) {
    content[i] = (i * 31 + 7) & 0xFF;
  }
  final paddedContent = Uint8List(((entrySize + 511) ~/ 512) * 512)
    ..setRange(0, entrySize, content);

  for (var i = 0; i < entryCount; i++) {
    final block = Uint8List(512);
    void putString(int at, String value) =>
        block.setRange(at, at + value.length, ascii.encode(value));
    void putOctal(int at, int len, int value) {
      putString(at, value.toRadixString(8).padLeft(len - 1, '0'));
    }

    putString(0, 'dir${i ~/ 1000}/file$i.bin');
    putOctal(100, 8, 420);
    putOctal(108, 8, 501);
    putOctal(116, 8, 20);
    putOctal(124, 12, entrySize);
    putOctal(136, 12, 1577934245);
    block[156] = 0x30;
    putString(257, 'ustar');
    putString(263, '00');

    for (var j = 148; j < 156; j++) {
      block[j] = 0x20;
    }
    var sum = 0;
    for (final byte in block) {
      sum += byte;
    }
    putString(148, sum.toRadixString(8).padLeft(6, '0'));
    block[154] = 0;
    block[155] = 0x20;

    builder.add(block);
    builder.add(paddedContent);
  }
  builder.add(Uint8List(1024));
  return builder.takeBytes();
}

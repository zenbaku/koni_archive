// Inflate benchmarks (M4, PROMPT_V1.md §10): koni_codecs vs
// package:archive, with the platform zlib (dart:io) as an extra reference.
//
//   dart run --no-enable-asserts bench/bin/inflate_bench.dart
//
// Results are printed as a markdown table; commit them under
// bench/results/. Performance is measured, not asserted.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as pkg_archive;
import 'package:koni_codecs/koni_codecs.dart';

const int warmupRuns = 2;
const int measuredRuns = 5;

Future<void> main() async {
  // ~64 MiB of mixed compressibility (text-ish + binary-ish).
  final payload = Uint8List(64 * 1024 * 1024);
  for (var i = 0; i < payload.length; i++) {
    payload[i] = i % 4 == 0 ? (i ~/ 4096) & 0x3F : (i * 31) & 0xFF;
  }
  final compressed = Uint8List.fromList(
    ZLibCodec(level: 6, raw: true).encode(payload),
  );

  stdout.writeln('# Inflate benchmarks (M4)');
  stdout.writeln('');
  stdout.writeln('- date: ${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('- dart: ${Platform.version}');
  stdout.writeln('- os: ${Platform.operatingSystemVersion}');
  stdout.writeln(
    '- input: ${_mb(payload.length)} MiB payload, deflate level 6 '
    '(${_mb(compressed.length)} MiB compressed)',
  );
  stdout.writeln('- runs: best of $measuredRuns (after $warmupRuns warmup)');
  stdout.writeln('');
  stdout.writeln('| decoder | time | throughput (decoded) |');
  stdout.writeln('| --- | --- | --- |');

  _row('koni_codecs InflateDecoder', payload.length, () {
    _use(const InflateDecoder().convert(compressed).length);
  });
  _row('package:archive Inflate', payload.length, () {
    _use(pkg_archive.Inflate(compressed).getBytes().length);
  });
  _row('dart:io ZLibCodec (native)', payload.length, () {
    _use(ZLibCodec(raw: true).decode(compressed).length);
  });
}

void _row(String name, int decodedSize, void Function() run) {
  for (var i = 0; i < warmupRuns; i++) {
    run();
  }
  var best = const Duration(days: 1);
  for (var i = 0; i < measuredRuns; i++) {
    final watch = Stopwatch()..start();
    run();
    watch.stop();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  final mbps = decodedSize / (1024 * 1024) / (best.inMicroseconds / 1e6);
  stdout.writeln(
    '| $name | ${(best.inMicroseconds / 1000).toStringAsFixed(1)} ms | '
    '${mbps.toStringAsFixed(0)} MiB/s |',
  );
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

int _sink = 0;
void _use(int value) => _sink ^= value; // defeat dead-code elimination

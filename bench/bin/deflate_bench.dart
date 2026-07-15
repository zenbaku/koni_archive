// Deflate-encode benchmarks (P2-3, PROMPT_V1.md §10): koni_codecs
// DeflateEncoder vs package:archive, with the platform zlib (dart:io) as an
// extra reference. Encoding is the ZIP-writer hot path.
//
//   dart run --no-enable-asserts bench/bin/deflate_bench.dart
//
// Results are printed as a markdown table; commit them under
// bench/results/. Both time and compression ratio are reported (a fast
// encoder that barely compresses is not a fair comparison) — performance is
// measured, not asserted.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as pkg_archive;
import 'package:koni_codecs/koni_codecs.dart';

const int warmupRuns = 2;
const int measuredRuns = 5;

Future<void> main() async {
  // ~32 MiB of mixed compressibility (text-ish + binary-ish), the same shape
  // the inflate bench decodes — representative of real archive payloads.
  final payload = Uint8List(32 * 1024 * 1024);
  for (var i = 0; i < payload.length; i++) {
    payload[i] = i % 4 == 0 ? (i ~/ 4096) & 0x3F : (i * 31) & 0xFF;
  }

  stdout.writeln('# Deflate-encode benchmarks (P2-3)');
  stdout.writeln('');
  stdout.writeln('- date: ${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('- dart: ${Platform.version}');
  stdout.writeln('- os: ${Platform.operatingSystemVersion}');
  stdout.writeln('- input: ${_mb(payload.length)} MiB mixed payload');
  stdout.writeln('- runs: best of $measuredRuns (after $warmupRuns warmup)');
  stdout.writeln('');
  stdout.writeln('| encoder | time | throughput (input) | ratio |');
  stdout.writeln('| --- | --- | --- | --- |');

  _row('koni_codecs DeflateEncoder', payload, () {
    return const DeflateEncoder().convert(payload).length;
  });
  _row('package:archive Deflate', payload, () {
    return pkg_archive.Deflate(payload).getBytes().length;
  });
  _row('dart:io ZLibCodec level 6 (native)', payload, () {
    return ZLibCodec(level: 6, raw: true).encode(payload).length;
  });
}

void _row(String name, Uint8List input, int Function() run) {
  var compressed = 0;
  for (var i = 0; i < warmupRuns; i++) {
    compressed = run();
  }
  var best = const Duration(days: 1);
  for (var i = 0; i < measuredRuns; i++) {
    final watch = Stopwatch()..start();
    compressed = run();
    watch.stop();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  _use(compressed);
  final mbps = input.length / (1024 * 1024) / (best.inMicroseconds / 1e6);
  final ratio = input.length / compressed;
  stdout.writeln(
    '| $name | ${(best.inMicroseconds / 1000).toStringAsFixed(1)} ms | '
    '${mbps.toStringAsFixed(0)} MiB/s | ${ratio.toStringAsFixed(2)}x |',
  );
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

int _sink = 0;
void _use(int value) => _sink ^= value; // defeat dead-code elimination

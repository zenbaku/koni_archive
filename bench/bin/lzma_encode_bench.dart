// LZMA-encode benchmarks (P2-4b, PROMPT_V1.md §10): koni_codecs LzmaEncoder
// / Lzma2Encoder — the 7z-writer hot path. package:archive has no LZMA
// encoder, so times are absolute, not ratios; DeflateEncoder runs on the
// same payload as an in-repo reference point.
//
//   dart run --no-enable-asserts bench/bin/lzma_encode_bench.dart
//
// Results are printed as a markdown table; commit them under
// bench/results/. Both time and compression ratio are reported (a fast
// encoder that barely compresses is not a fair comparison) — performance is
// measured, not asserted.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:koni_codecs/koni_codecs.dart';

const int warmupRuns = 2;
const int measuredRuns = 5;

void main() {
  // 8 MiB of seeded pseudo-prose (Zipf-ish word draws — real match
  // structure, unlike periodic synthetic patterns that LZMA's window folds
  // to almost nothing), and 8 MiB of incompressible noise (the encoder's
  // worst case: every match probe fails, LZMA2 falls back to copy chunks).
  final random = Random(20260715);
  final words = List.generate(
    512,
    (i) => List.generate(3 + (i % 9), (j) => 0x61 + ((i * 7 + j * 13) % 26)),
  );
  final textBuilder = BytesBuilder(copy: false);
  while (textBuilder.length < 8 * 1024 * 1024) {
    // Skewed toward low indices, like word frequency in prose.
    final w = (random.nextDouble() * random.nextDouble() * 512).floor();
    textBuilder.add(words[w]);
    textBuilder.addByte(0x20);
  }
  final text = textBuilder.takeBytes();
  final noise = Uint8List.fromList(
    List.generate(8 * 1024 * 1024, (_) => random.nextInt(256)),
  );

  stdout.writeln('# LZMA-encode benchmarks (P2-4b)');
  stdout.writeln('');
  stdout.writeln('- date: ${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('- dart: ${Platform.version}');
  stdout.writeln('- os: ${Platform.operatingSystemVersion}');
  stdout.writeln('- runs: best of $measuredRuns (after $warmupRuns warmup)');
  stdout.writeln(
    '- payloads: 8 MiB seeded pseudo-prose; 8 MiB incompressible noise',
  );
  stdout.writeln(
    '- baseline: none — package:archive has no LZMA encoder; '
    'DeflateEncoder shown as an in-repo reference',
  );
  stdout.writeln('');
  stdout.writeln('| encoder / payload | time | throughput | output | ratio |');
  stdout.writeln('| --- | --- | --- | --- | --- |');

  _row('LzmaEncoder, prose', text, (data) => LzmaEncoder().encode(data));
  _row('Lzma2Encoder, prose', text, (data) => Lzma2Encoder().encode(data));
  _row(
    'DeflateEncoder, prose (reference)',
    text,
    (data) => const DeflateEncoder().convert(data),
  );
  _row('LzmaEncoder, noise', noise, (data) => LzmaEncoder().encode(data));
  _row('Lzma2Encoder, noise', noise, (data) => Lzma2Encoder().encode(data));
  _row(
    'DeflateEncoder, noise (reference)',
    noise,
    (data) => const DeflateEncoder().convert(data),
  );
}

void _row(
  String name,
  Uint8List payload,
  Uint8List Function(Uint8List) encode,
) {
  var outputSize = 0;
  for (var i = 0; i < warmupRuns; i++) {
    outputSize = encode(payload).length;
  }
  var best = const Duration(days: 1);
  for (var i = 0; i < measuredRuns; i++) {
    final watch = Stopwatch()..start();
    encode(payload);
    watch.stop();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  final mbps =
      payload.length / (1024 * 1024) / (best.inMicroseconds / 1e6);
  final ratio = (100 * outputSize / payload.length).toStringAsFixed(1);
  stdout.writeln(
    '| $name | ${(best.inMicroseconds / 1000).toStringAsFixed(1)} ms | '
    '${mbps.toStringAsFixed(1)} MiB/s | '
    '${(outputSize / (1024 * 1024)).toStringAsFixed(2)} MiB | $ratio% |',
  );
}

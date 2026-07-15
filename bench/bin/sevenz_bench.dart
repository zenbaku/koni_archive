// 7z benchmarks (M8, PROMPT_V1.md §8/§10): CB7 page-flip.
//
//   dart run --no-enable-asserts bench/bin/sevenz_bench.dart
//
// Requires 7zz on PATH (runs on the owner's machine, like the fixture
// generator): a realistic solid CB7 is built on the fly, then measured.
// package:archive has no 7z support, so times are absolute, not ratios.

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_sevenz/koni_sevenz.dart';

const int pageCount = 120;
const int pageSize = 512 * 1024;

Future<void> main() async {
  final staging = Directory.systemTemp.createTempSync('koni_archive_bench');
  final Uint8List cb7;
  try {
    for (var i = 0; i < pageCount; i++) {
      final page = Uint8List(pageSize);
      for (var j = 0; j < pageSize; j++) {
        page[j] = j % 4 == 0 ? ((j ~/ 512) + i) & 0x3F : (j * 31 + i) & 0xFF;
      }
      File(
        '${staging.path}/page${'$i'.padLeft(3, '0')}.png',
      ).writeAsBytesSync(page);
    }
    final result = await Process.run('7zz', [
      'a',
      '-y',
      '-m0=LZMA2',
      '-ms=on',
      '${staging.path}/comic.cb7',
      '.',
    ], workingDirectory: staging.path);
    if (result.exitCode != 0) {
      stderr.writeln('7zz failed: ${result.stderr}');
      exitCode = 1;
      return;
    }
    cb7 = File('${staging.path}/comic.cb7').readAsBytesSync();
  } finally {
    staging.deleteSync(recursive: true);
  }

  stdout.writeln('# 7z benchmarks (M8): CB7 page-flip');
  stdout.writeln('');
  stdout.writeln('- date: ${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('- dart: ${Platform.version}');
  stdout.writeln('- os: ${Platform.operatingSystemVersion}');
  stdout.writeln(
    '- input: $pageCount pages x ${pageSize ~/ 1024} KiB, solid LZMA2 '
    '(${(cb7.length / (1024 * 1024)).toStringAsFixed(0)} MiB compressed, '
    '${pageCount * pageSize ~/ (1024 * 1024)} MiB decoded)',
  );
  stdout.writeln('');
  stdout.writeln('| step | time |');
  stdout.writeln('| --- | --- |');

  final watch = Stopwatch()..start();
  final reader = await const SevenZFormat().openReader(
    MemoryByteSource(cb7),
    const ArchiveReadOptions(),
  );
  _row('open (header decode)', watch);

  final pages = reader.entries.where((e) => e.isFile).toList();
  var total = 0;
  await for (final chunk in reader.openRead(pages[57])) {
    total += chunk.length;
  }
  _row('first page read (solid block decode + CRC)', watch);

  await for (final chunk in reader.openRead(pages[58])) {
    total += chunk.length;
  }
  _row('next page read (LRU cache hit + CRC)', watch);

  await for (final chunk in reader.openRead(pages[2])) {
    total += chunk.length;
  }
  _row('backwards page read (LRU cache hit + CRC)', watch);
  _use(total);
  await reader.close();
}

void _row(String name, Stopwatch watch) {
  stdout.writeln(
    '| $name | ${(watch.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms |',
  );
  watch.reset();
}

int _sink = 0;
void _use(int value) => _sink ^= value; // defeat dead-code elimination

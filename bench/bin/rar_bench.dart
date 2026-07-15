// RAR benchmarks (M9, §8/§10): CBR page-flip.
//
//   dart run --no-enable-asserts bench/bin/rar_bench.dart
//
// Requires `rar` on PATH (owner's machine). package:archive has no RAR
// support, so times are absolute, not ratios.

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:koni_rar/koni_rar.dart';

const int pageCount = 120;
const int pageSize = 512 * 1024;

Future<void> main() async {
  final staging = Directory.systemTemp.createTempSync('koni_archive_bench');
  final Uint8List cbr;
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
    final result = await Process.run('rar', [
      'a',
      '-y',
      '-m3',
      '-ep1',
      '${staging.path}/comic.cbr',
      '${staging.path}/',
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('rar failed: ${result.stderr}');
      exitCode = 1;
      return;
    }
    cbr = File('${staging.path}/comic.cbr').readAsBytesSync();
  } finally {
    staging.deleteSync(recursive: true);
  }

  stdout.writeln('# RAR benchmarks (M9): CBR page-flip');
  stdout.writeln('');
  stdout.writeln('- date: ${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('- dart: ${Platform.version}');
  stdout.writeln('- os: ${Platform.operatingSystemVersion}');
  stdout.writeln(
    '- input: $pageCount pages x ${pageSize ~/ 1024} KiB, RAR5 -m3 '
    '(${(cbr.length / (1024 * 1024)).toStringAsFixed(0)} MiB compressed)',
  );
  stdout.writeln('');
  stdout.writeln('| step | time |');
  stdout.writeln('| --- | --- |');

  final watch = Stopwatch()..start();
  final reader = await const RarFormat().openReader(
    MemoryByteSource(cbr),
    const ArchiveReadOptions(),
  );
  _row('open (header walk)', watch);

  final pages = reader.entries.where((e) => e.isFile).toList();
  var total = 0;
  for (final idx in [57, 58, 2]) {
    watch.reset();
    await for (final chunk in reader.openRead(pages[idx])) {
      total += chunk.length;
    }
    _row('read page $idx (decode + CRC)', watch);
  }
  _use(total);
  await reader.close();
}

void _row(String name, Stopwatch watch) {
  stdout.writeln(
    '| $name | ${(watch.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms |',
  );
}

int _sink = 0;
void _use(int value) => _sink ^= value;

// Runs `dart test` in every workspace package that has a test/ directory,
// forwarding all arguments (e.g. --platform chrome --compiler dart2wasm).
//
// Used by CI (.github/workflows/ci.yaml) and for local runs:
//
//   dart run tool/run_tests.dart --platform vm

import 'dart:io';

Future<void> main(List<String> args) async {
  final members = _workspaceMembers(File('pubspec.yaml'));
  if (members.isEmpty) {
    stderr.writeln('No workspace members found in pubspec.yaml.');
    exitCode = 1;
    return;
  }

  final failed = <String>[];
  var ran = 0;
  for (final member in members) {
    if (!Directory('$member/test').existsSync()) {
      stdout.writeln('--- $member: no test/ directory, skipping');
      continue;
    }
    stdout.writeln('--- $member: dart test ${args.join(' ')}');
    final process = await Process.start(
      'dart',
      ['test', ...args],
      workingDirectory: member,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
    ran++;
    if (await process.exitCode != 0) failed.add(member);
  }

  stdout.writeln('');
  if (failed.isNotEmpty) {
    stdout.writeln('FAILED (${failed.length}/$ran): ${failed.join(', ')}');
    exitCode = 1;
  } else {
    stdout.writeln('All $ran package test suites passed.');
  }
}

/// Parses the `workspace:` list out of the root pubspec without a YAML
/// dependency (this script must run before `dart pub get` dependencies are
/// guaranteed to exist).
List<String> _workspaceMembers(File rootPubspec) {
  final members = <String>[];
  var inWorkspace = false;
  for (final line in rootPubspec.readAsLinesSync()) {
    if (line.trimRight() == 'workspace:') {
      inWorkspace = true;
      continue;
    }
    if (!inWorkspace) continue;
    if (line.trim().isEmpty) continue;
    final item = RegExp(r'^\s+-\s+(\S+)\s*$').firstMatch(line);
    if (item != null) {
      members.add(item.group(1)!);
    } else {
      break; // end of the workspace: block
    }
  }
  return members;
}

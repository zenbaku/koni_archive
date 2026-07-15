import 'package:koni_archive_core/koni_archive_core.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeEntryPath', () {
    void check(String raw, String path, {bool escaped = false}) {
      final result = normalizeEntryPath(raw);
      expect(result.path, path, reason: 'path of "$raw"');
      expect(result.escapedRoot, escaped, reason: 'escapedRoot of "$raw"');
    }

    test('passes clean paths through', () {
      check('a/b/c.txt', 'a/b/c.txt');
      check('page001.webp', 'page001.webp');
    });

    test('converts backslash separators', () {
      check(r'a\b\c.txt', 'a/b/c.txt');
      check(r'mixed/style\path', 'mixed/style/path');
    });

    test('strips leading slashes (absolute paths), unflagged', () {
      check('/etc/passwd', 'etc/passwd');
      check('//double', 'double');
      check(r'\windows\system32', 'windows/system32');
    });

    test('strips drive letters', () {
      check(r'C:\evil.exe', 'evil.exe');
      check('C:/dir/f.txt', 'dir/f.txt');
      check('c:relative.txt', 'relative.txt');
      check('C:', '');
      // Not a drive letter: digit or multi-char scheme-ish prefixes.
      check('1:notdrive', '1:notdrive');
    });

    test('drops empty and dot segments (incl. trailing slash)', () {
      check('a/./b//c/', 'a/b/c');
      check('./x', 'x');
      check('.', '');
      check('/', '');
      check('', '');
    });

    test('resolves .. inside the tree without flagging', () {
      check('a/b/../c', 'a/c');
      check('a/b/..', 'a');
      check('a/..', '');
    });

    test('flags .. escaping the root and sanitizes', () {
      check('../../x', 'x', escaped: true);
      check('..', '', escaped: true);
      check('a/../../x', 'x', escaped: true);
      check(r'..\..\evil', 'evil', escaped: true);
      // Escapes even once are flagged, wherever they occur.
      check('../a/b', 'a/b', escaped: true);
    });

    test('preserves unicode and unusual-but-safe names', () {
      check('日本語/ページ 001.png', '日本語/ページ 001.png');
      check('dots..in..name/file', 'dots..in..name/file');
      check('...', '...');
    });
  });
}

// Checks the fresh build of `build/dictionaries/` against the published
// `public/dictionaries/` and, when every check passes, publishes what
// changed (see src/publication.dart) with the page at the root of the
// publication (src/page.dart). Run after the three build scripts:
//
//   dart run dictionaries/publish.dart
//
// A failed check publishes nothing — the previous files stay — writes the
// problems into `build/errors.txt` (sent to Telegram by the workflow) and
// ends with an error.
import 'dart:io';

import 'src/package_writer.dart';
import 'src/page.dart';
import 'src/publication.dart';

Future<void> main() async {
  final DictionaryFolder built = DictionaryFolder(buildDir);
  final DictionaryFolder published = DictionaryFolder(publicDir);
  final List<String> problems = check(
    built,
    published.exists ? published : null,
  );
  if (problems.isNotEmpty) {
    for (final String problem in problems) {
      stderr.writeln('::error::$problem');
    }
    final File errors = File('build/errors.txt');
    await errors.parent.create(recursive: true);
    await errors.writeAsString('${problems.join('\n')}\n');
    exitCode = 1;
    return;
  }
  final bool changed = publish(built, published, DateTime.now());
  if (changed) {
    writePage(Directory(publicDir).parent.path);
  }
  stdout.writeln(
    changed
        ? 'Dictionaries: published into $publicDir'
        : 'Dictionaries: nothing changed',
  );
}

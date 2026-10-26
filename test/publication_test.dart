import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../dictionaries/src/publication.dart';

void main() {
  late Directory root;
  late DictionaryFolder built;
  late DictionaryFolder published;

  setUp(() {
    root = Directory.systemTemp.createTempSync('publication_test');
    built = DictionaryFolder('${root.path}/build');
    published = DictionaryFolder('${root.path}/public');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, Object?> manifest() =>
      jsonDecode(published.file(manifestName).readAsStringSync())
          as Map<String, Object?>;

  test('the first publication writes every file and its manifest', () {
    writeBuild(built, symptoms: entries(10));

    expect(check(built, null), isEmpty);
    expect(publish(built, published, DateTime.utc(2026, 10, 26, 12)), isTrue);

    final Map<String, Object?> m = manifest();
    expect(m['format'], manifestFormat);
    expect(m['built'], '2026-10-26T12:00:00Z');
    expect(
      (m['dictionaries']! as Map<String, Object?>)['symptoms'],
      <String, Object?>{'type': 'sx', 'version': 'v1', 'count': 10},
    );
    final Map<String, Object?> files = m['files']! as Map<String, Object?>;
    expect(files.keys, <String>[
      'dosage.json',
      'symptoms.groups.json',
      'symptoms.json.gz',
      'vaccine_diseases.json',
    ]);
    final Map<String, Object?> gz =
        files['symptoms.json.gz']! as Map<String, Object?>;
    expect(gz['size'], published.file('symptoms.json.gz').lengthSync());
    expect(gz['sha256'], hasLength(64));
  });

  test('a build with the same data publishes nothing', () {
    writeBuild(built, symptoms: entries(10));
    publish(built, published, DateTime.utc(2026, 10, 1));
    final String before = published.file(manifestName).readAsStringSync();

    writeBuild(built, symptoms: entries(10));
    expect(publish(built, published, DateTime.utc(2026, 11, 1)), isFalse);
    expect(published.file(manifestName).readAsStringSync(), before);
  });

  test('a new version replaces the file and the date', () {
    writeBuild(built, symptoms: entries(10));
    publish(built, published, DateTime.utc(2026, 10, 1));

    writeBuild(built, symptoms: entries(11), version: 'v2');
    expect(check(built, published), isEmpty);
    expect(publish(built, published, DateTime.utc(2026, 11, 1)), isTrue);
    expect(manifest()['built'], '2026-11-01T00:00:00Z');
    expect(
      (manifest()['dictionaries']! as Map<String, Object?>)['symptoms'],
      containsPair('version', 'v2'),
    );
  });

  test('a dictionary that lost over 10 % of its entries is refused', () {
    writeBuild(built, symptoms: entries(100));
    publish(built, published, DateTime.utc(2026, 10, 1));

    writeBuild(built, symptoms: entries(89), version: 'v2');
    expect(
      check(built, published),
      contains('symptoms: 89 entries, published 100'),
    );
    writeBuild(built, symptoms: entries(90), version: 'v2');
    expect(check(built, published), isEmpty);
  });

  test('a dictionary that lost its translations is refused', () {
    writeBuild(built, symptoms: entries(100));
    publish(built, published, DateTime.utc(2026, 10, 1));

    writeBuild(
      built,
      symptoms: entries(100, withRussianUpTo: 50),
      version: 'v2',
    );
    expect(check(built, published), <String>[
      'symptoms: 50 names in "ru", published 100',
    ]);
  });

  test('a dictionary the build lost is refused', () {
    writeBuild(built, symptoms: entries(10), vaccines: entries(5));
    publish(built, published, DateTime.utc(2026, 10, 1));

    writeBuild(built, symptoms: entries(10));
    expect(check(built, published), <String>['vaccines: not built']);
  });

  test('a file in another format is refused', () {
    writeBuild(built, symptoms: entries(10));
    built
        .file('symptoms.json.gz')
        .writeAsBytesSync(gzip.encode(utf8.encode('{"type":"sx","items":[]}')));
    expect(check(built, null).single, startsWith('symptoms: unreadable'));

    writeBuild(built, symptoms: entries(10));
    built.file('dosage.json').writeAsStringSync('[]');
    expect(check(built, null).single, startsWith('labels: unreadable'));
  });

  test('a word mixing Cyrillic and Latin look-alikes is refused', () {
    writeBuild(
      built,
      symptoms: <Map<String, Object?>>[
        <String, Object?>{
          'key': 'epilepsy',
          'names': <String, Object?>{'uk': 'Епiлепсiя'},
        },
      ],
    );
    expect(check(built, null), <String>[
      'symptoms: a word mixes Cyrillic and Latin look-alikes',
    ]);
  });

  test('nothing built is refused', () {
    expect(check(built, null).single, startsWith('nothing was built'));
  });

  test('a file no dictionary names any more leaves the publication', () {
    writeBuild(built, symptoms: entries(10), vaccines: entries(5));
    publish(built, published, DateTime.utc(2026, 10, 1));

    writeBuild(built, symptoms: entries(10));
    expect(publish(built, published, DateTime.utc(2026, 11, 1)), isTrue);
    expect(published.file('vaccines.json.gz').existsSync(), isFalse);
    expect(
      (manifest()['files']! as Map<String, Object?>).keys,
      isNot(contains('vaccines.json.gz')),
    );
  });
}

List<Map<String, Object?>> entries(int count, {int? withRussianUpTo}) =>
    <Map<String, Object?>>[
      for (int i = 0; i < count; i++)
        <String, Object?>{
          'key': 'k$i',
          'names': <String, Object?>{
            'uk': 'Назва $i',
            if (i < (withRussianUpTo ?? count)) 'ru': 'Название $i',
            'en': 'Name $i',
          },
        },
    ];

/// Writes a build folder as the build scripts do: one manifest line and two
/// files per dictionary, and the two files of labels.
void writeBuild(
  DictionaryFolder folder, {
  required List<Map<String, Object?>> symptoms,
  List<Map<String, Object?>>? vaccines,
  String version = 'v1',
}) {
  final Directory dir = Directory(folder.path);
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
  dir.createSync(recursive: true);
  final Map<String, Object?> lines = <String, Object?>{};
  void write(String name, String type, List<Map<String, Object?>> list) {
    folder
        .file('$name.json.gz')
        .writeAsBytesSync(
          gzip.encode(
            utf8.encode(
              jsonEncode(<String, Object?>{'type': type, 'entries': list}),
            ),
          ),
        );
    folder.file('$name.groups.json').writeAsStringSync('[]');
    lines[name] = <String, Object?>{
      'type': type,
      'version': version,
      'count': list.length,
    };
  }

  write('symptoms', 'sx', symptoms);
  if (vaccines != null) {
    write('vaccines', 'vx', vaccines);
  }
  folder.file(manifestName).writeAsStringSync(jsonEncode(lines));
  folder.file('dosage.json').writeAsStringSync('{"forms":[],"units":[]}');
  folder.file('vaccine_diseases.json').writeAsStringSync('[]');
}

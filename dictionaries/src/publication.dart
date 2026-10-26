// The checks between a fresh build and the published dictionaries, and the
// publication itself (`dart run dictionaries/publish.dart`).
//
// `public/dictionaries/` is what the application downloads (and what the
// release of the application copies into its built-in dictionaries):
//   <name>.json.gz, <name>.groups.json  — every dictionary
//   dosage.json, vaccine_diseases.json  — names of forms, units, diseases
//   manifest.json — `format`, `built` and, for every dictionary, type,
//                   version and count; for every file, size and SHA-256.
// A change of the layout is a new `format`: the application does not take
// a manifest of a format it does not know.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'mixed_script.dart';

const String publicDir = 'public/dictionaries';
const String manifestName = 'manifest.json';

/// The layout of the published files the application understands.
const int manifestFormat = 1;

/// A count of entries, or of names in one language, falling by more than
/// this share means a broken source rather than a smaller dictionary.
const double maxDrop = 0.10;

const List<String> languages = <String>['uk', 'ru', 'en'];
const List<String> labelFiles = <String>[
  'dosage.json',
  'vaccine_diseases.json',
];

/// One dictionary of a folder, as its manifest names it.
class FolderDictionary {
  const FolderDictionary({
    required this.name,
    required this.type,
    required this.version,
    required this.count,
  });

  final String name;
  final String type;
  final String version;
  final int count;

  String get entriesFile => '$name.json.gz';
  String get groupsFile => '$name.groups.json';
}

/// A folder of dictionary files: what the build wrote, or what is published.
/// Reads both manifests: the build's `{<name>: {type, version, count}}` and
/// the published one, which keeps the same lines under `dictionaries`.
class DictionaryFolder {
  DictionaryFolder(this.path);

  final String path;

  File file(String name) => File('$path/$name');

  bool get exists => file(manifestName).existsSync();

  Map<String, FolderDictionary> dictionaries() {
    final Map<String, Object?> manifest = jsonDecode(
      file(manifestName).readAsStringSync(),
    ) as Map<String, Object?>;
    final Map<String, Object?> lines =
        (manifest['dictionaries'] ?? manifest) as Map<String, Object?>;
    return <String, FolderDictionary>{
      for (final MapEntry<String, Object?> e in lines.entries)
        e.key: FolderDictionary(
          name: e.key,
          type: (e.value! as Map<String, Object?>)['type']! as String,
          version: (e.value! as Map<String, Object?>)['version']! as String,
          count: (e.value! as Map<String, Object?>)['count']! as int,
        ),
    };
  }

  /// Every file of the dictionaries of this folder, the manifest aside.
  List<String> fileNames() => <String>[
    for (final FolderDictionary d in dictionaries().values) ...<String>[
      d.entriesFile,
      d.groupsFile,
    ],
    ...labelFiles,
  ];

  /// The entries of [dictionary]: the decoded `<name>.json.gz`.
  Map<String, Object?> entries(FolderDictionary dictionary) => jsonDecode(
    utf8.decode(gzip.decode(file(dictionary.entriesFile).readAsBytesSync())),
  ) as Map<String, Object?>;
}

/// What stands in the way of publishing [built] over [published]; empty
/// when it may go out. [published] is `null` before the first publication.
List<String> check(DictionaryFolder built, DictionaryFolder? published) {
  if (!built.exists) {
    return <String>['nothing was built: no ${built.path}/$manifestName'];
  }
  final List<String> problems = <String>[];
  final Map<String, FolderDictionary> fresh = built.dictionaries();
  final Map<String, FolderDictionary> old =
      published?.dictionaries() ?? const <String, FolderDictionary>{};
  for (final String name in old.keys) {
    if (!fresh.containsKey(name)) {
      problems.add('$name: not built');
    }
  }
  for (final FolderDictionary d in fresh.values) {
    try {
      final Map<String, int> names = _checkEntries(built, d, problems);
      _decodeJson(built, d.groupsFile) as List<Object?>;
      final FolderDictionary? before = old[d.name];
      if (before == null) {
        continue;
      }
      if (d.count < before.count * (1 - maxDrop)) {
        problems.add(
          '${d.name}: ${d.count} entries, published ${before.count}',
        );
      }
      final Map<String, int> namesBefore = _names(published!.entries(before));
      for (final String lang in languages) {
        final int now = names[lang] ?? 0;
        final int was = namesBefore[lang] ?? 0;
        if (now < was * (1 - maxDrop)) {
          problems.add('${d.name}: $now names in "$lang", published $was');
        }
      }
    } on Object catch (error) {
      problems.add('${d.name}: unreadable ($error)');
    }
  }
  try {
    final Map<String, Object?> dosage =
        _decodeJson(built, 'dosage.json') as Map<String, Object?>;
    dosage['forms']! as List<Object?>;
    dosage['units']! as List<Object?>;
    _decodeJson(built, 'vaccine_diseases.json') as List<Object?>;
  } on Object catch (error) {
    problems.add('labels: unreadable ($error)');
  }
  return problems;
}

/// Checks the entries file of [d] and returns how many entries have a name
/// in each language.
Map<String, int> _checkEntries(
  DictionaryFolder folder,
  FolderDictionary d,
  List<String> problems,
) {
  final Map<String, Object?> json = folder.entries(d);
  final List<Object?> entries = json['entries']! as List<Object?>;
  if (json['type'] != d.type || entries.length != d.count) {
    problems.add('${d.name}: the file does not match its manifest line');
  }
  for (final Object? e in entries) {
    final Map<String, Object?> entry = e! as Map<String, Object?>;
    entry['key']! as String;
    final Map<String, Object?> names = entry['names']! as Map<String, Object?>;
    if (names.isEmpty || names.values.any((Object? n) => n is! String)) {
      problems.add('${d.name}: ${entry['key']} has no proper names');
      break;
    }
  }
  // «Епiлепсiя» with a Latin «i» is never found by a search typed on the
  // phone: the build fixes such words, a source must not bring them back.
  if (jsonEncode(fixMixedScriptDeep(entries)) != jsonEncode(entries)) {
    problems.add('${d.name}: a word mixes Cyrillic and Latin look-alikes');
  }
  return _names(json);
}

Map<String, int> _names(Map<String, Object?> json) {
  final Map<String, int> counts = <String, int>{};
  for (final Object? e in json['entries']! as List<Object?>) {
    final Map<String, Object?> names =
        (e! as Map<String, Object?>)['names']! as Map<String, Object?>;
    for (final MapEntry<String, Object?> n in names.entries) {
      if ((n.value as String?)?.trim().isNotEmpty ?? false) {
        counts[n.key] = (counts[n.key] ?? 0) + 1;
      }
    }
  }
  return counts;
}

Object? _decodeJson(DictionaryFolder folder, String name) =>
    jsonDecode(folder.file(name).readAsStringSync());

/// Puts the files of [built] that differ from the published ones into
/// [published] and writes its manifest; returns whether anything changed.
///
/// An entries file counts as the same when its version is (the version is
/// a hash of the entries, while the gzip bytes may differ between runs), any
/// other file when its bytes are. Nothing changed — nothing is written, so
/// the run commits nothing.
bool publish(DictionaryFolder built, DictionaryFolder published, DateTime now) {
  final Map<String, FolderDictionary> fresh = built.dictionaries();
  final Map<String, FolderDictionary> old = published.exists
      ? published.dictionaries()
      : const <String, FolderDictionary>{};
  final Set<String> sameEntries = <String>{
    for (final FolderDictionary d in fresh.values)
      if (old[d.name]?.version == d.version) d.entriesFile,
  };
  final List<String> names = built.fileNames();
  bool changed = false;
  Directory(published.path).createSync(recursive: true);
  for (final String name in names) {
    final File target = published.file(name);
    final List<int> bytes = built.file(name).readAsBytesSync();
    final bool same =
        target.existsSync() &&
        (sameEntries.contains(name) ||
            _sha256(target.readAsBytesSync()) == _sha256(bytes));
    if (!same) {
      target.writeAsBytesSync(bytes, flush: true);
      changed = true;
    }
  }
  for (final File stale in Directory(
    published.path,
  ).listSync().whereType<File>()) {
    final String name = stale.uri.pathSegments.last;
    if (name != manifestName && !names.contains(name)) {
      stale.deleteSync();
      changed = true;
    }
  }
  if (!changed && published.exists) {
    return false;
  }
  final Map<String, Object?> manifest = <String, Object?>{
    'format': manifestFormat,
    // To the second: `2026-10-26T14:47:13Z`.
    'built': '${now.toUtc().toIso8601String().split('.').first}Z',
    'dictionaries': <String, Object?>{
      for (final String name in fresh.keys.toList()..sort())
        name: <String, Object?>{
          'type': fresh[name]!.type,
          'version': fresh[name]!.version,
          'count': fresh[name]!.count,
        },
    },
    'files': <String, Object?>{
      for (final String name in names.toList()..sort())
        name: <String, Object?>{
          'size': published.file(name).lengthSync(),
          'sha256': _sha256(published.file(name).readAsBytesSync()),
        },
    },
  };
  published
      .file(manifestName)
      .writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
        flush: true,
      );
  return true;
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

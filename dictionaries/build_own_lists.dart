// Builds the dictionaries we write ourselves, from dictionaries/data/:
// symptoms, specialties, vaccines (with the diseases they protect from) and
// allergens (spec 7.1). Every entry must have a name in all three languages,
// no two entries of a list may share a key or a name, and a diagnosis code
// must exist among the diagnoses — so run build_diagnoses.dart first.
//
//   dart run dictionaries/build_own_lists.dart
import 'dart:convert';
import 'dart:io';

import 'src/package_writer.dart';

const List<String> _languages = <String>['uk', 'ru', 'en'];

Future<void> main() async {
  final Set<String> codes =
      ((jsonDecode(
                utf8.decode(
                  gzip.decode(
                    await File('$buildDir/diagnoses.json.gz').readAsBytes(),
                  ),
                ),
              ) as Map<String, Object?>)['entries']!
              as List<Object?>)
          .map((Object? e) => (e! as Map<String, Object?>)['code']! as String)
          .toSet();

  await _build('symptoms', 'sx', codes);
  await _build('specialties', 'sp', codes);
  await _build('allergens', 'al', codes);
  final Map<String, Object?> vaccines = await _build('vaccines', 'vx', codes);

  // The names of the diseases a vaccine protects from, for its card.
  final List<Map<String, Object?>> diseases =
      (vaccines['diseases']! as List<Object?>).cast<Map<String, Object?>>();
  final Set<String> known = <String>{};
  for (final Map<String, Object?> d in diseases) {
    _checkNames('vaccines', d['key']! as String, d['names']);
    if (!known.add(d['key']! as String)) {
      throw StateError('vaccines: disease ${d['key']} twice');
    }
  }
  for (final Map<String, Object?> v
      in (vaccines['entries']! as List<Object?>).cast<Map<String, Object?>>()) {
    for (final Object? a in v['antigens']! as List<Object?>) {
      if (!known.contains(a)) {
        throw StateError('vaccines: ${v['key']} protects from unknown $a');
      }
    }
  }
  await File('$buildDir/vaccine_diseases.json').writeAsString(
    '${const JsonEncoder.withIndent(' ').convert(<Map<String, Object?>>[
      for (final Map<String, Object?> d in diseases) <String, Object?>{'key': d['key'], 'names': d['names']},
    ])}\n',
  );
}

/// Reads `data/<name>.json`, checks it and writes the dictionary; returns
/// the data for what is built next to it.
Future<Map<String, Object?>> _build(
  String name,
  String type,
  Set<String> codes,
) async {
  final Map<String, Object?> data =
      (await readData('$name.json'))! as Map<String, Object?>;
  final List<Map<String, Object?>> groups =
      ((data['groups'] ?? <Object?>[]) as List<Object?>)
          .cast<Map<String, Object?>>();
  final Set<String> groupKeys = <String>{
    for (final Map<String, Object?> g in groups) g['key']! as String,
  };
  final Map<String, String> seenNames = <String, String>{};
  final List<PackageEntry> entries = <PackageEntry>[];
  for (final Map<String, Object?> e
      in (data['entries']! as List<Object?>).cast<Map<String, Object?>>()) {
    final String key = e['key']! as String;
    final Map<String, String> names = _checkNames(name, key, e['names']);
    for (final String language in _languages) {
      final String normalized = names[language]!.toLowerCase();
      final String? other = seenNames['$language:$normalized'];
      if (other != null) {
        throw StateError('$name: $key and $other share «$normalized»');
      }
      seenNames['$language:$normalized'] = key;
    }
    final String? code = e['code'] as String?;
    if (code != null && !codes.contains(code)) {
      throw StateError('$name: $key has unknown code $code');
    }
    final String? group = e['group'] as String?;
    if (groupKeys.isNotEmpty && !groupKeys.contains(group)) {
      throw StateError('$name: $key has unknown group $group');
    }
    final List<String> synonyms = <String>[
      for (final String language in _languages)
        ...(((e['syn'] as Map<String, Object?>?)?[language]
                    as List<Object?>?) ??
                const <Object?>[])
            .cast<String>()
            .where((String s) => s.trim().isNotEmpty),
    ];
    entries.add(
      PackageEntry(
        key: key,
        code: code,
        names: names,
        group: group,
        synonyms: synonyms.toSet().toList(),
        extra: <String, Object?>{
          if (e['antigens'] != null) 'antigens': e['antigens'],
        },
      ),
    );
  }
  await writePackage(
    name: name,
    type: type,
    entries: entries,
    groups: <PackageGroup>[
      for (final Map<String, Object?> g in groups)
        PackageGroup(
          key: g['key']! as String,
          names: _checkNames(name, g['key']! as String, g['names']),
        ),
    ],
  );
  return data;
}

/// A name in each of the three languages, none of them empty.
Map<String, String> _checkNames(String list, String key, Object? names) {
  final Map<String, String> map = (names! as Map<String, Object?>)
      .cast<String, String>();
  for (final String language in _languages) {
    if ((map[language] ?? '').trim().isEmpty) {
      throw StateError('$list: $key has no $language name');
    }
  }
  return map;
}

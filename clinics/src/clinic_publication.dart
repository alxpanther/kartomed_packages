// The checks of the built clinic networks and their publication into
// `public/packages/` (`dart run clinics/publish_clinics.dart`), the folder
// the application downloads from:
//   <id>.json        — one network (see clinic_network.dart)
//   logos/<id>.png   — its icon, when its site has one
//   index.json       — `format`, `built`, the cities by country with their
//                      names, every network (name, kind, country, site,
//                      version, branches per city, logo) and, for every
//                      file, size and SHA-256.
// The application reads index.json first and only the networks the user
// chose. A change of the layout is a new `format`.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const String clinicsBuildDir = 'build/packages';
const String clinicsPublicDir = 'public/packages';
const String indexName = 'index.json';

/// The layout of the published files the application understands.
const int indexFormat = 1;

/// A network losing more than this share of its branches since the last
/// publication means a page that was not read well, not closed branches:
/// its previous file is kept.
const double maxBranchDrop = 0.30;

/// The network files of a folder, by id.
Map<String, Map<String, Object?>> networksIn(String dir) {
  final Directory folder = Directory(dir);
  if (!folder.existsSync()) {
    return <String, Map<String, Object?>>{};
  }
  return <String, Map<String, Object?>>{
    for (final File f in folder.listSync().whereType<File>())
      if (f.path.endsWith('.json') && !f.path.endsWith('/$indexName'))
        f.uri.pathSegments.last.replaceAll('.json', ''):
            jsonDecode(f.readAsStringSync()) as Map<String, Object?>,
  };
}

/// Why the networks of [dir] may not go out; empty when they may.
List<String> checkNetworks(String dir) {
  final Map<String, Map<String, Object?>> networks = networksIn(dir);
  if (networks.isEmpty) {
    return <String>['nothing was built: no networks in $dir'];
  }
  final List<String> problems = <String>[];
  for (final MapEntry<String, Map<String, Object?>> n in networks.entries) {
    try {
      final Map<String, Object?> json = n.value;
      final Map<String, Object?> cities =
          json['cities']! as Map<String, Object?>;
      final List<Object?> branches = json['branches']! as List<Object?>;
      if (json['id'] != n.key) {
        problems.add('${n.key}: the file names another id');
      }
      if (branches.isEmpty) {
        problems.add('${n.key}: no branches');
      }
      final Set<String> refs = <String>{};
      for (final Object? b in branches) {
        final Map<String, Object?> branch = b! as Map<String, Object?>;
        if (!refs.add(branch['ref']! as String)) {
          problems.add('${n.key}: branch ${branch['ref']} twice');
        }
        if (!cities.containsKey(branch['city'])) {
          problems.add('${n.key}: city ${branch['city']} has no names');
        }
        if ((branch['address']! as String).trim().isEmpty) {
          problems.add('${n.key}: a branch without an address');
        }
      }
    } on Object catch (error) {
      problems.add('${n.key}: unreadable ($error)');
    }
  }
  return problems;
}

/// Puts the files of [built] that differ from those of [published] there,
/// removes the networks no longer built and writes the index; returns
/// whether anything changed.
bool publishNetworks(String built, String published, DateTime now) {
  final Map<String, Map<String, Object?>> networks = networksIn(built);
  final List<String> names = <String>[
    for (final String id in networks.keys) '$id.json',
    for (final String id in networks.keys)
      if (File('$built/logos/$id.png').existsSync()) 'logos/$id.png',
  ]..sort();
  bool changed = false;
  Directory('$published/logos').createSync(recursive: true);
  for (final String name in names) {
    final File target = File('$published/$name');
    final List<int> bytes = File('$built/$name').readAsBytesSync();
    if (!target.existsSync() ||
        _sha256(target.readAsBytesSync()) != _sha256(bytes)) {
      target.writeAsBytesSync(bytes, flush: true);
      changed = true;
    }
  }
  for (final File stale in Directory(
    published,
  ).listSync(recursive: true).whereType<File>()) {
    final String name = stale.path.substring(published.length + 1);
    if (name != indexName && !names.contains(name)) {
      stale.deleteSync();
      changed = true;
    }
  }
  if (!changed && File('$published/$indexName').existsSync()) {
    return false;
  }
  final Map<String, Map<String, Object?>> cities =
      <String, Map<String, Object?>>{};
  for (final Map<String, Object?> n in networks.values) {
    final Map<String, Object?> ofCountry = cities.putIfAbsent(
      n['country']! as String,
      () => <String, Object?>{},
    );
    for (final MapEntry<String, Object?> c
        in (n['cities']! as Map<String, Object?>).entries) {
      // The names given in more languages win.
      final Map<String, Object?>? had =
          ofCountry[c.key] as Map<String, Object?>?;
      if (had == null ||
          (c.value! as Map<String, Object?>).length > had.length) {
        ofCountry[c.key] = c.value;
      }
    }
  }
  final Map<String, Object?> index = <String, Object?>{
    'format': indexFormat,
    'built': '${now.toUtc().toIso8601String().split('.').first}Z',
    'cities': <String, Object?>{
      for (final String country in cities.keys.toList()..sort())
        country: <String, Object?>{
          for (final String key in cities[country]!.keys.toList()..sort())
            key: cities[country]![key],
        },
    },
    'networks': <String, Object?>{
      for (final String id in networks.keys.toList()..sort())
        id: _line(id, networks[id]!, built),
    },
    'files': <String, Object?>{
      for (final String name in names)
        name: <String, Object?>{
          'size': File('$published/$name').lengthSync(),
          'sha256': _sha256(File('$published/$name').readAsBytesSync()),
        },
    },
  };
  File('$published/$indexName').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(index)}\n',
    flush: true,
  );
  return true;
}

Map<String, Object?> _line(String id, Map<String, Object?> n, String built) {
  final Map<String, int> perCity = <String, int>{};
  for (final Object? b in n['branches']! as List<Object?>) {
    final String city = (b! as Map<String, Object?>)['city']! as String;
    perCity[city] = (perCity[city] ?? 0) + 1;
  }
  return <String, Object?>{
    'name': n['name'],
    'kind': n['kind'],
    'country': n['country'],
    'site': n['site'],
    'version': _sha256(File('$built/$id.json').readAsBytesSync())
        .substring(0, 16),
    'cities': <String, Object?>{
      for (final String c in perCity.keys.toList()..sort()) c: perCity[c],
    },
    if (File('$built/logos/$id.png').existsSync()) 'logo': 'logos/$id.png',
  };
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

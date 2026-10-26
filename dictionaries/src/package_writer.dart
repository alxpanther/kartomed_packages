// Shared part of the dictionary build scripts: downloads into the project
// `tmp/` folder, the output files of a dictionary and the list of what was
// built, which `publish.dart` checks and turns into the published manifest.
//
// Output of one dictionary `<name>`:
//   build/dictionaries/<name>.json.gz     — the entries (gzip, JSON)
//   build/dictionaries/<name>.groups.json — the catalog tree (small, plain)
//   build/dictionaries/manifest.json      — `<name>`: type, version, count
// The version is a hash of the entries, so any change of the data is a new
// version and the application re-imports it.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'mixed_script.dart';

const String buildDir = 'build/dictionaries';
const String sourcesDir = 'tmp/dictionaries';
const String dataDir = 'dictionaries/data';

/// What the build wants the owner to know without failing: one line each,
/// sent to Telegram by the workflow.
const String warningsFile = 'build/warnings.txt';

/// One entry of an output file. `names` and every localized value are
/// `{uk, ru, en}` maps with the missing languages left out.
class PackageEntry {
  PackageEntry({
    required this.key,
    required this.names,
    this.code,
    this.group,
    List<String>? synonyms,
    Map<String, Object?>? extra,
  }) : synonyms = synonyms ?? <String>[],
       extra = extra ?? <String, Object?>{};

  /// Stable key: the identity of the entry across versions.
  final String key;
  final String? code;
  final Map<String, String> names;
  final String? group;
  final List<String> synonyms;
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    if (code != null) 'code': code,
    'names': names,
    if (group != null) 'group': group,
    if (synonyms.isNotEmpty) 'synonyms': synonyms,
    if (extra.isNotEmpty) 'extra': extra,
  };
}

/// A node of the catalog: a chapter, a block, a group.
class PackageGroup {
  PackageGroup({
    required this.key,
    required this.names,
    this.code,
    List<PackageGroup>? children,
  }) : children = children ?? <PackageGroup>[];

  final String key;

  /// Shown before the name in mono: «A00–B99».
  final String? code;
  final Map<String, String> names;
  final List<PackageGroup> children;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    if (code != null) 'code': code,
    'names': names,
    if (children.isNotEmpty)
      'children': children.map((PackageGroup g) => g.toJson()).toList(),
  };
}

/// Writes the files of one dictionary and its line of the manifest.
Future<void> writePackage({
  required String name,
  required String type,
  required List<PackageEntry> entries,
  required List<PackageGroup> groups,
}) async {
  final Set<String> keys = <String>{};
  for (final PackageEntry e in entries) {
    if (!keys.add(e.key)) {
      throw StateError('$name: duplicate key ${e.key}');
    }
    if (e.names.values.every((String n) => n.trim().isEmpty)) {
      throw StateError('$name: ${e.key} has no name');
    }
  }
  // Look-alike letters of the other alphabet inside a word («Епiлепсiя»,
  // «Flоrеs») are fixed here, for every dictionary at once.
  final String body = jsonEncode(<String, Object?>{
    'type': type,
    'entries': fixMixedScriptDeep(
      entries.map((PackageEntry e) => e.toJson()).toList(),
    ),
  });
  final List<int> raw = utf8.encode(body);
  final String version = sha256.convert(raw).toString().substring(0, 16);
  await Directory(buildDir).create(recursive: true);
  await File('$buildDir/$name.json.gz')
      .writeAsBytes(GZipCodec(level: 9).encode(raw));
  await File('$buildDir/$name.groups.json').writeAsString(
    const JsonEncoder.withIndent(' ').convert(
      fixMixedScriptDeep(groups.map((PackageGroup g) => g.toJson()).toList()),
    ),
  );

  final File manifestFile = File('$buildDir/manifest.json');
  final Map<String, Object?> manifest = manifestFile.existsSync()
      ? jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>
      : <String, Object?>{};
  manifest[name] = <String, Object?>{
    'type': type,
    'version': version,
    'count': entries.length,
  };
  final Map<String, Object?> sorted = <String, Object?>{
    for (final String k in manifest.keys.toList()..sort()) k: manifest[k],
  };
  await manifestFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(sorted)}\n',
  );
  stdout.writeln('$name: ${entries.length} entries, version $version');
}

/// Downloads [url] into `tmp/dictionaries/<fileName>` unless it is already
/// there; a failed download stops the build instead of producing a
/// dictionary without one of its sources.
Future<File> download(String url, String fileName) async {
  final File file = File('$sourcesDir/$fileName');
  if (file.existsSync() && file.lengthSync() > 0) {
    return file;
  }
  await file.parent.create(recursive: true);
  stdout.writeln('Downloading $url');
  final HttpClient http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 60)
    ..userAgent = 'Mozilla/5.0';
  try {
    final HttpClientRequest request = await http.getUrl(Uri.parse(url));
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'HTTP ${response.statusCode}: the source is not available. '
        'Tell the user; do not build the dictionary without it.',
        uri: Uri.parse(url),
      );
    }
    await response.pipe(file.openWrite());
  } finally {
    http.close();
  }
  return file;
}

/// Whether [url] answers 200 to a `HEAD` request.
Future<bool> exists(String url) async {
  final HttpClient http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 60)
    ..userAgent = 'Mozilla/5.0';
  try {
    final HttpClientResponse response = await (await http.headUrl(
      Uri.parse(url),
    )).close();
    await response.drain<void>();
    return response.statusCode == HttpStatus.ok;
  } on IOException {
    return false;
  } finally {
    http.close();
  }
}

/// Reports [message] in the log of the run and in [warningsFile].
Future<void> warn(String message) async {
  stdout.writeln('::warning::$message');
  final File file = File(warningsFile);
  await file.parent.create(recursive: true);
  await file.writeAsString('$message\n', mode: FileMode.append);
}

/// Runs a command-line tool and returns its output; stops the build when
/// the tool fails or is missing.
Future<String> runTool(String executable, List<String> arguments) async {
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    stdoutEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout as String;
}

/// Reads a JSON file of `dictionaries/data/`.
Future<Object?> readData(String fileName) async =>
    jsonDecode(await File('$dataDir/$fileName').readAsString());

/// Rows of a `;`-separated file with `"`-quoted fields (the format of the
/// official exports); the first row holds the column names.
List<Map<String, String>> parseCsv(String text, {String separator = ';'}) {
  final List<List<String>> rows = <List<String>>[];
  List<String> row = <String>[];
  final StringBuffer field = StringBuffer();
  bool quoted = false;
  for (int i = 0; i < text.length; i++) {
    final String c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == separator) {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n') {
      row.add(field.toString().replaceAll('\r', ''));
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  final List<String> header = rows.first
      .map((String h) => h.trim().replaceFirst('﻿', ''))
      .toList();
  return <Map<String, String>>[
    for (final List<String> r in rows.skip(1))
      if (r.length >= header.length)
        <String, String>{
          for (int i = 0; i < header.length; i++) header[i]: r[i].trim(),
        },
  ];
}

/// «ХОЛЕРА» → «Холера»; leaves a name that already has lower-case letters.
String sentenceCase(String text) {
  final String t = text.trim();
  if (t.isEmpty || t != t.toUpperCase()) {
    return t;
  }
  final String lower = t.toLowerCase();
  return lower[0].toUpperCase() + lower.substring(1);
}

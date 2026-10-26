// Builds build/dictionaries/medicines.*: the medicines registered in
// Ukraine (spec 7.1.1) — trade name, active substance, dosage form,
// strengths, manufacturer and group.
//
// Source: the State register of medicines of Ukraine, open data of
// data.gov.ua (the law requires naming it: one line in «About → Legal
// information», nowhere else). The newest CSV of the dataset is taken.
//
// One registration certificate is one row of the register; the packs of one
// medicine (same trade name, substance and form) fold into one entry with
// all its strengths. Bulk substances and withdrawn registrations are left
// out; expired ones stay — such packs are still in home medicine chests.
//
//   dart run dictionaries/build_drugs.dart
import 'dart:convert';
import 'dart:io';

import 'src/package_writer.dart';
import 'src/transliteration.dart';

const String _dataset =
    'https://data.gov.ua/api/3/action/package_show?'
    'id=fded13b8-4e2c-4c48-bf14-65d0e3106463';

Future<void> main() async {
  final String url = await _newestCsv();
  final File file = await download(url, 'medicines_uk.csv');
  final List<Map<String, String>> rows = parseCsv(
    _decodeWindows1251(await file.readAsBytes()),
  );
  stdout.writeln('${rows.length} rows in the register');

  final List<_Form> forms =
      (((await readData('dosage_forms.json'))!
                  as Map<String, Object?>)['forms']!
              as List<Object?>)
          .map((Object? f) => _Form.fromJson(f! as Map<String, Object?>))
          .toList();
  final List<_Unit> units =
      (((await readData('units.json'))! as Map<String, Object?>)['units']!
              as List<Object?>)
          .map((Object? u) => _Unit.fromJson(u! as Map<String, Object?>))
          .where((_Unit u) => u.match != null)
          .toList();
  final Map<String, Object?> groupsData =
      (await readData('atc_groups.json'))! as Map<String, Object?>;
  final Map<String, Map<String, String>> substanceNames =
      ((await readData('drug_substances.json'))! as Map<String, Object?>).map(
        (String inn, Object? names) => MapEntry(
          inn.toLowerCase(),
          (names! as Map<String, Object?>).cast<String, String>(),
        ),
      );

  final List<Map<String, String>> medicines = rows.where(_isMedicine).toList();
  final Map<String, String> ukrainianSubstances = _substancesFromTradeNames(
    medicines,
  );

  final Map<String, _Medicine> byKey = <String, _Medicine>{};
  for (final Map<String, String> r in medicines) {
    final String name = brandCase(r['Торгівельне найменування']!);
    final String formText = r['Форма випуску']!;
    final _Form form = forms.firstWhere((_Form f) => f.matches(formText));
    final String? inn = _inn(r['Міжнародне непатентоване найменування']!);
    final String key = <String>[
      _slug(name),
      form.key,
      if (inn != null) _slug(inn),
    ].join('|');
    final _Medicine medicine = byKey.putIfAbsent(
      key,
      () => _Medicine(key: key, name: name, form: form.key, inn: inn),
    );
    medicine.strengths.addAll(_strengths(formText, r['Склад (діючі)']!, units));
    medicine.atc ??= _atc(r['Код АТС 1']!);
    medicine.manufacturer ??= _manufacturer(
      r['Виробник 1: назва українською']!,
    );
    medicine.country ??= _nonEmpty(r['Виробник 1: країна ']);
    final String? composition = _nonEmpty(
      r['Склад (діючі)']?.replaceAll(RegExp(r'\s+'), ' '),
    );
    if (composition != null) {
      medicine.composition.add(composition);
    }
  }

  final List<PackageEntry> entries = <PackageEntry>[];
  final Set<String> unnamed = <String>{};
  for (final _Medicine m
      in byKey.values.toList()
        ..sort((_Medicine a, _Medicine b) => a.key.compareTo(b.key))) {
    final Map<String, String>? substance = m.inn == null
        ? null
        : _substance(m.inn!, substanceNames, ukrainianSubstances, unnamed);
    final String ru = ukrainianToRussian(m.name);
    entries.add(
      PackageEntry(
        key: m.key,
        code: m.atc,
        names: <String, String>{
          'uk': m.name,
          if (ru != m.name) 'ru': ru,
          'en': ukrainianToLatin(m.name),
        },
        group: m.atc?.substring(0, 1) ?? 'other',
        extra: <String, Object?>{
          'substance': ?substance,
          'form': m.form,
          if (m.strengths.isNotEmpty) 'strengths': _sortStrengths(m.strengths),
          'manufacturer': ?m.manufacturer,
          'country': ?m.country,
          // Composition of each strength, in Ukrainian as the register
          // writes it.
          if (m.composition.isNotEmpty) 'composition': m.composition.toList(),
        },
      ),
    );
  }

  final List<PackageGroup> groups = <PackageGroup>[
    for (final Map<String, Object?> g
        in (groupsData['groups']! as List<Object?>)
            .cast<Map<String, Object?>>())
      PackageGroup(
        key: g['key']! as String,
        code: g['key'] == 'other' ? null : g['key']! as String,
        names: (g['names']! as Map<String, Object?>).cast<String, String>(),
      ),
  ];
  final Set<String> groupKeys = groups.map((PackageGroup g) => g.key).toSet();
  for (final PackageEntry e in entries) {
    if (!groupKeys.contains(e.group)) {
      throw StateError('Unknown group ${e.group} of ${e.key}');
    }
  }

  await writePackage(
    name: 'medicines',
    type: 'rx',
    entries: entries,
    groups: groups,
  );
  await _writeDosageCatalog(forms);
  stdout.writeln(
    '${unnamed.length} substances spelled by the rules; check them in '
    'tmp/dictionaries/substances_by_rule.txt',
  );
  await File('$sourcesDir/substances_by_rule.txt')
      .writeAsString((unnamed.toList()..sort()).join('\n'));
}

/// The URL of the newest CSV of the dataset.
Future<String> _newestCsv() async {
  final HttpClient http = HttpClient();
  try {
    final HttpClientRequest request = await http.getUrl(Uri.parse(_dataset));
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'HTTP ${response.statusCode}: the register is not available. '
        'Tell the user; do not build the dictionary without it.',
        uri: Uri.parse(_dataset),
      );
    }
    final Map<String, Object?> body = jsonDecode(
      await response.transform(utf8.decoder).join(),
    ) as Map<String, Object?>;
    final List<Map<String, Object?>> resources =
        ((body['result']! as Map<String, Object?>)['resources']!
                as List<Object?>)
            .cast<Map<String, Object?>>()
            .where(
              (Map<String, Object?> r) =>
                  '${r['format']}'.toUpperCase() == 'CSV' &&
                  '${r['url']}'.startsWith('https://data.gov.ua/'),
            )
            .toList()
          ..sort(
            (Map<String, Object?> a, Map<String, Object?> b) =>
                '${b['last_modified'] ?? b['created']}'.compareTo(
                  '${a['last_modified'] ?? a['created']}',
                ),
          );
    stdout.writeln(
      'Register of ${resources.first['last_modified'] ?? resources.first['created']}',
    );
    return resources.first['url']! as String;
  } finally {
    http.close();
  }
}

bool _isMedicine(Map<String, String> r) {
  final String form = r['Форма випуску']!.toLowerCase();
  return r['Фармакотерапевтична група']!.trim() != 'Субстанції.' &&
      !form.contains('субстанц') &&
      !form.contains('in bulk') &&
      r['Дострокове припинення'] != 'Так' &&
      r['Торгівельне найменування']!.trim().isNotEmpty;
}

class _Form {
  _Form.fromJson(Map<String, Object?> json)
    : key = json['key']! as String,
      names = (json['names']! as Map<String, Object?>).cast<String, String>(),
      _patterns = (json['match']! as List<Object?>)
          .map((Object? p) => RegExp(p! as String, caseSensitive: false))
          .toList();

  final String key;
  final Map<String, String> names;
  final List<RegExp> _patterns;

  /// The first part of the form text names the form; the packs follow.
  bool matches(String text) {
    final String head = text.split(';').first.toLowerCase();
    return _patterns.every((RegExp p) => p.hasMatch(head));
  }
}

class _Unit {
  _Unit.fromJson(Map<String, Object?> json)
    : key = json['key']! as String,
      match = json['match'] as String?;

  final String key;
  final String? match;
}

class _Medicine {
  _Medicine({
    required this.key,
    required this.name,
    required this.form,
    required this.inn,
  });

  final String key;
  final String name;
  final String form;
  final String? inn;
  final Set<String> strengths = <String>{};
  final Set<String> composition = <String>{};
  String? atc;
  String? manufacturer;
  String? country;
}

/// «200 mg», «2 mg/ml», «50 mcg/dose»: amounts with unit keys of
/// `units.json`, read from the form text, or from the composition when the
/// form gives none. A volume alone («по 50 мл») and an amount packed «у
/// флаконі» are sizes of a pack, not strengths.
Set<String> _strengths(String form, String composition, List<_Unit> units) {
  final String alternatives = units.map((_Unit u) => u.match).join('|');
  final RegExp amount = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*(' +
        alternatives +
        r')(?:\s*/\s*(\d+(?:[.,]\d+)?\s*)?(' +
        alternatives +
        r'))?(?![\p{L}])(\s+(?:у|в|in)\s)?',
    unicode: true,
  );
  String keyOf(String text) => units
      .firstWhere((_Unit u) => RegExp('^(${u.match})\$').hasMatch(text))
      .key;
  String number(String text) => text.trim().replaceAll(',', '.');
  Set<String> read(String text, {required Set<String> allowed}) => <String>{
    for (final Match m in amount.allMatches(text))
      if (m[5] == null && (m[4] != null || allowed.contains(keyOf(m[2]!))))
        <String>[
          '${number(m[1]!)} ${keyOf(m[2]!)}',
          if (m[4] != null)
            '/${m[3] == null ? '' : '${number(m[3]!)} '}${keyOf(m[4]!)}',
        ].join(),
  };
  const Set<String> mass = <String>{'mg', 'mcg', 'g', 'iu', 'unit', 'mmol'};
  final Set<String> fromForm = read(
    form.split(';').first,
    allowed: <String>{...mass, 'percent', 'dose'},
  );
  return fromForm.isNotEmpty
      ? fromForm
      : read(composition, allowed: mass).take(1).toSet();
}

List<String> _sortStrengths(Set<String> strengths) =>
    strengths.toList()..sort((String a, String b) {
      final double x = double.tryParse(a.split(' ').first) ?? 0;
      final double y = double.tryParse(b.split(' ').first) ?? 0;
      return x != y ? x.compareTo(y) : a.compareTo(b);
    });

/// The international name, without the «*» of the register and the
/// placeholders it uses for combinations.
String? _inn(String raw) {
  final String inn = raw.replaceAll('*', '').trim();
  if (inn.isEmpty ||
      const <String>{
        'comb drug',
        'mono',
        'various',
      }.contains(inn.toLowerCase())) {
    return null;
  }
  return inn;
}

String? _atc(String raw) {
  final String code = raw.trim().toUpperCase();
  return RegExp(r'^[A-Z]\d\d').hasMatch(code) ? code : null;
}

/// «Х. Лундбек А/С ( виробництво … )» → «Х. Лундбек А/С».
String? _manufacturer(String raw) =>
    _nonEmpty(raw.replaceAll(RegExp(r'\s*\(.*$'), '').trim());

String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

/// The substance in three languages: our list first, then the Ukrainian
/// name the register itself uses as a trade name (and its Russian
/// spelling), then the spelling rules. A descriptive name («vitamin B1 in
/// combination with …») stays English only: the rules would garble it.
Map<String, String> _substance(
  String inn,
  Map<String, Map<String, String>> fixed,
  Map<String, String> ukrainian,
  Set<String> byRule,
) {
  final String lower = inn.toLowerCase();
  final Map<String, String>? known = fixed[lower];
  final String base = lower
      .replaceAll(RegExp(r',\s*combinations.*$'), '')
      .trim();
  final bool combination = base != lower;
  final String baseEn = base[0].toUpperCase() + base.substring(1);
  final String en =
      known?['en'] ?? (combination ? '$baseEn, combinations' : baseEn);
  if (known != null) {
    return <String, String>{...known, 'en': en};
  }
  final bool descriptive = RegExp(
    r'\b(in|with|or|and/or|excl|other|plain|various|derivatives|preparations)\b|[/(0-9]',
  ).hasMatch(base);
  if (descriptive || _isPlant(base)) {
    return <String, String>{'en': en};
  }
  final String? uk = ukrainian[base];
  if (uk == null) {
    byRule.add(inn);
  }
  String withTail(String name, String tail) =>
      combination ? '$name, $tail' : name;
  return <String, String>{
    'uk': withTail(
      uk ?? substanceToCyrillic(base, russian: false),
      'комбінації',
    ),
    'ru': withTail(
      uk == null
          ? substanceToCyrillic(base, russian: true)
          : _russianOf(uk, base),
      'комбинации',
    ),
    'en': en,
  };
}

/// A Latin plant name («Valerianae radix», «Echinacea purpurea»): several
/// words with the endings of Latin, none of them a salt or an acid.
bool _isPlant(String inn) {
  final List<String> words = inn.split(RegExp(r'[\s-]+'));
  return words.length > 1 &&
      words.every(
        (String w) => RegExp(r'(ae|us|um|is|ii|a|ix|ex|i|ia)$').hasMatch(w),
      );
}

/// The Russian spelling of a Ukrainian substance name: the letters of
/// Russian, «э» at the start where Latin has «e», and the double consonant
/// that Ukrainian writes once («амоксицилін» → «амоксициллин»).
String _russianOf(String ukrainian, String latin) {
  String ru = ukrainianToRussian(ukrainian);
  if (latin.startsWith('e') && ru.startsWith('е')) {
    ru = 'э${ru.substring(1)}';
  }
  const Map<String, String> letters = <String, String>{
    'l': 'л',
    'm': 'м',
    'n': 'н',
    'p': 'п',
    'r': 'р',
    's': 'с',
    't': 'т',
    'f': 'ф',
  };
  for (final Match m in RegExp(r'([lmnprstf])\1').allMatches(latin)) {
    final String c = letters[m[1]]!;
    if (!ru.contains('$c$c') && c.allMatches(ru).length == 1) {
      ru = ru.replaceFirst(c, '$c$c');
    }
  }
  return ru;
}

/// International name → the Ukrainian word the register uses for a medicine
/// sold under the name of its substance («Ibuprofen» → «ібупрофен»).
Map<String, String> _substancesFromTradeNames(List<Map<String, String>> rows) {
  final Map<String, Map<String, int>> votes = <String, Map<String, int>>{};
  for (final Map<String, String> r in rows) {
    final String? inn = _inn(r['Міжнародне непатентоване найменування']!);
    if (inn == null || inn.contains(' ') || inn.contains(',')) {
      continue;
    }
    final String first = r['Торгівельне найменування']!
        .replaceAll(RegExp('[®™]'), '')
        .trim()
        .split(RegExp(r'[\s-]'))
        .first
        .toLowerCase();
    final String expected = substanceToCyrillic(inn, russian: false);
    // «Бупренорфіну гідрохлорид» names the salt in the genitive case.
    final bool inflected =
        RegExp(r'[уюи]$').hasMatch(first) &&
        !RegExp(r'[уюи]$').hasMatch(expected);
    if (first.length > 3 && !inflected && _similar(first, expected)) {
      final Map<String, int> v = votes.putIfAbsent(
        inn.toLowerCase(),
        () => <String, int>{},
      );
      v[first] = (v[first] ?? 0) + 1;
    }
  }
  return votes.map(
    (String inn, Map<String, int> v) => MapEntry(
      inn,
      (v.entries.toList()..sort(
            (MapEntry<String, int> a, MapEntry<String, int> b) =>
                b.value.compareTo(a.value),
          ))
          .first
          .key,
    ),
  );
}

/// Close enough to be the same word spelled a little differently: a letter
/// or two («ацетилцистеїн» / «ацетилцистеін»), never a brand that only
/// starts the same («Ламотрин»), nor another ending («Топірамін»).
bool _similar(String a, String b) =>
    (a.length - b.length).abs() <= 1 &&
    a.substring(a.length - 2) == b.substring(b.length - 2) &&
    _levenshtein(a, b) <= (b.length / 8).ceil();

int _levenshtein(String a, String b) {
  List<int> row = List<int>.generate(b.length + 1, (int i) => i);
  for (int i = 1; i <= a.length; i++) {
    final List<int> next = <int>[i, ...List<int>.filled(b.length, 0)];
    for (int j = 1; j <= b.length; j++) {
      next[j] = <int>[
        row[j] + 1,
        next[j - 1] + 1,
        row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
      ].reduce((int x, int y) => x < y ? x : y);
    }
    row = next;
  }
  return row[b.length];
}

/// «НУРОФЕН® ФОРТЕ» → «Нурофен Форте», «ІБУПРОФЕН-ДАРНИЦЯ» →
/// «Ібупрофен-Дарниця», «НО-ШПА» → «Но-шпа»; short capital tokens and
/// tokens with digits («АФ», «SR», «ПД4») keep their case.
String brandCase(String raw) {
  final List<String> tokens = raw
      .replaceAll(RegExp('[®™]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .split(' ');
  const Set<String> small = <String>{
    'та',
    'і',
    'й',
    'з',
    'зі',
    'із',
    'для',
    'в',
    'у',
    'на',
    'по',
    'від',
    'with',
    'and',
    'for',
  };
  final List<String> out = <String>[];
  for (int t = 0; t < tokens.length; t++) {
    final String token = tokens[t];
    final bool upper = token == token.toUpperCase();
    final int letters = token
        .replaceAll(RegExp(r'[^\p{L}]', unicode: true), '')
        .length;
    if (!upper ||
        RegExp(r'\d').hasMatch(token) ||
        (letters <= 2 && !small.contains(token.toLowerCase()))) {
      out.add(token);
      continue;
    }
    final List<String> parts = token.toLowerCase().split('-');
    for (int p = 0; p < parts.length; p++) {
      final String part = parts[p];
      final bool capital =
          (t == 0 && p == 0) ||
          (p > 0 && part.length >= 4) ||
          (t > 0 &&
              !small.contains(part) &&
              p == 0 &&
              parts.length == 1 &&
              RegExp(r'^[a-z]').hasMatch(part));
      if (capital && part.isNotEmpty) {
        parts[p] = part[0].toUpperCase() + part.substring(1);
      }
    }
    out.add(parts.join('-'));
  }
  return out.join(' ');
}

String _slug(String text) =>
    ukrainianToLatin(text.toLowerCase())
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');

/// The dosage forms and units the application shows, from the data files.
Future<void> _writeDosageCatalog(List<_Form> forms) async {
  final Map<String, Object?> units =
      (await readData('units.json'))! as Map<String, Object?>;
  await File('$buildDir/dosage.json').writeAsString(
    '${const JsonEncoder.withIndent(' ').convert(<String, Object?>{
      'forms': <Map<String, Object?>>[
        for (final _Form f in forms) <String, Object?>{'key': f.key, 'names': f.names},
      ],
      'units': <Map<String, Object?>>[
        for (final Map<String, Object?> u in (units['units']! as List<Object?>).cast<Map<String, Object?>>()) <String, Object?>{'key': u['key'], 'kinds': u['kinds'], 'names': u['names']},
      ],
    })}\n',
  );
}

/// The register is published in the Windows Cyrillic code page.
String _decodeWindows1251(List<int> bytes) {
  const String high =
      'ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏђ‘’“”•–—�™љ›њќћџ ЎўЈ¤Ґ¦§Ё©Є«¬­®Ї°±Ііґµ¶·ё№є»јЅѕї'
      'АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдежзийклмнопрстуфхцчшщъыьэюя';
  final StringBuffer out = StringBuffer();
  for (final int b in bytes) {
    out.write(b < 128 ? String.fromCharCode(b) : high[b - 128]);
  }
  return out.toString();
}

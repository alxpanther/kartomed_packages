// Builds build/dictionaries/diagnoses.*: the codes of diseases with their
// names in Ukrainian, Russian and English, the chapters and blocks of the
// catalog, and our own colloquial synonyms (spec 7.1).
//
// Sources (internal, never named in the application — see
// docs/reference_data_sources_ru.md):
//   ru — the export of the official Russian edition (OID
//        1.2.643.5.1.13.13.11.1005). The portal of the ministry does not
//        answer from outside Russia (nor from GitHub), so the export is the
//        file the owner puts into `dictionaries/sources/diagnoses_ru.csv`;
//        without it, the unchanged export of version 2.27 from a public
//        mirror. `--ru=<file>` takes another file. An export older than a
//        year adds a line to `build/warnings.txt` (sent to Telegram).
//   uk — the official PDF of the Ukrainian national classifier НК 025:2021;
//        read with `pdftotext` (poppler-utils) by the word coordinates of its
//        table.
//   en — the US edition (public domain): code descriptions and the tabular
//        list for the names of chapters and blocks; unpacked with `unzip`.
//        The newest year the CDC has published is taken.
//
// Every code of the two national editions is kept, the five-character ones
// of the Ukrainian edition too («A41.51»): a Ukrainian user gets the codes of
// Ukrainian documents, a Russian user those of Russian ones. The US edition
// only adds English names to codes of up to four characters — its longer
// codes are its own and mean other things.
//
//   dart run dictionaries/build_diagnoses.dart [--ru=<csv>]
import 'dart:io';

import 'package:collection/collection.dart';

import 'src/package_writer.dart';

const String _ruUrl =
    'https://raw.githubusercontent.com/ak4nv/mkb10/master/resources/'
    '1.2.643.5.1.13.13.11.1005_2.27.csv';

/// When the mirror got the export above (its commit on GitHub).
final DateTime _ruMirrorDate = DateTime.utc(2025, 11, 24);

/// The fresh export the owner puts in by hand.
const String _ruOwnFile = 'dictionaries/sources/diagnoses_ru.csv';

/// An export older than this is reported: the ministry may have a new one.
const Duration _ruMaxAge = Duration(days: 365);
const String _ukUrl =
    'https://www.dec.gov.ua/wp-content/uploads/2021/11/'
    'naczionalnyj-klasyfikator-nk-025.pdf';
const String _enBase =
    'https://ftp.cdc.gov/pub/Health_Statistics/NCHS/Publications/ICD10CM';

/// The first year this script was written for; newer ones are looked for.
const int _enFirstYear = 2027;

final RegExp _code = RegExp(r'^[A-Z]\d\d(\.\d{1,2})?$');
final RegExp _range = RegExp(r'([A-Z]\d\d)\s*[-–]\s*([A-Z]\d\d)');

Future<void> main(List<String> args) async {
  final String? ruPath = args
      .where((String a) => a.startsWith('--ru='))
      .map((String a) => a.substring(5))
      .firstOrNull;
  final File ruFile;
  if (ruPath != null) {
    ruFile = File(ruPath);
  } else if (File(_ruOwnFile).existsSync()) {
    ruFile = File(_ruOwnFile);
    await _warnIfOld(await _committed(_ruOwnFile));
  } else {
    ruFile = await download(_ruUrl, 'diagnoses_ru.csv');
    await _warnIfOld(_ruMirrorDate);
  }
  final File ukFile = await download(_ukUrl, 'diagnoses_uk.pdf');
  final int year = await _newestUsYear();
  final String codesZip = 'icd10cm-code-descriptions-$year.zip';
  final String tabularZip = 'icd10cm-table-and-index-$year.zip';
  final File enCodes = await download('$_enBase/$year/$codesZip', codesZip);
  final File enTabular = await download(
    '$_enBase/$year/$tabularZip',
    tabularZip,
  );

  final _Edition ru = _readRussian(await ruFile.readAsString());
  final _Edition uk = await _readUkrainian(ukFile);
  _joinBrokenWords(uk.names);
  final _Edition en = await _readEnglish(enCodes, enTabular, year);
  stdout.writeln(
    'ru ${ru.names.length}, uk ${uk.names.length}, en ${en.names.length} codes',
  );

  final Map<String, Map<String, List<String>>> synonyms =
      ((await readData('diagnosis_synonyms.json'))! as Map<String, Object?>)
          .map(
            (String code, Object? byLanguage) => MapEntry(
              code,
              (byLanguage! as Map<String, Object?>).map(
                (String lang, Object? list) =>
                    MapEntry(lang, (list! as List<Object?>).cast<String>()),
              ),
            ),
          );

  // The codes of the two national editions; the US one only names them.
  final Set<String> codes = <String>{...ru.names.keys, ...uk.names.keys};
  final List<String> sorted = codes.toList()..sort();
  final Map<String, String> blockOf = <String, String>{};
  final Map<String, int> chapterOfBlock = <String, int>{};
  final List<PackageEntry> entries = <PackageEntry>[];
  for (final String code in sorted) {
    final String head = code.substring(0, 3);
    // A code of one edition whose heading the other lacks takes the
    // narrowest block around it.
    final String? block =
        ru.blockOf[head] ??
        uk.blockOf[head] ??
        _narrowest(head, ru.ranges) ??
        _narrowest(head, uk.ranges);
    if (block == null) {
      throw StateError('No block for $code');
    }
    blockOf[code] = block;
    final int? chapter = ru.chapterOf[head] ?? uk.chapterOf[head];
    if (chapter != null) {
      chapterOfBlock.putIfAbsent(block, () => chapter);
    }
    final Map<String, List<String>>? own = synonyms.remove(code);
    entries.add(
      PackageEntry(
        key: code,
        code: code,
        names: <String, String>{
          if (uk.names[code] != null) 'uk': uk.names[code]!,
          if (ru.names[code] != null) 'ru': ru.names[code]!,
          if (en.names[code] != null) 'en': en.names[code]!,
        },
        group: block,
        synonyms: <String>[
          for (final List<String> list in own?.values ?? const <List<String>>[])
            ...list,
        ],
      ),
    );
  }
  if (synonyms.isNotEmpty) {
    throw StateError('Synonyms of unknown codes: ${synonyms.keys}');
  }

  await writePackage(
    name: 'diagnoses',
    type: 'dx',
    entries: entries,
    groups: _catalog(<_Edition>[uk, ru, en], chapterOfBlock),
  );
}

/// The CDC publishes a new year in summer, for October: the newest year
/// whose files are there, from next year back to [_enFirstYear].
Future<int> _newestUsYear() async {
  for (int year = DateTime.now().year + 1; year > _enFirstYear; year--) {
    if (await exists('$_enBase/$year/icd10cm-code-descriptions-$year.zip')) {
      return year;
    }
  }
  return _enFirstYear;
}

/// When the owner last committed [path]; a file not committed yet is new.
Future<DateTime> _committed(String path) async {
  final String date = (await runTool('git', <String>[
    'log',
    '-1',
    '--format=%cI',
    '--',
    path,
  ])).trim();
  return date.isEmpty ? DateTime.now() : DateTime.parse(date);
}

Future<void> _warnIfOld(DateTime exported) async {
  final int days = DateTime.now().difference(exported).inDays;
  if (days > _ruMaxAge.inDays) {
    await warn(
      'The Russian edition of the diagnoses is $days days old: download a '
      'fresh export of 1.2.643.5.1.13.13.11.1005 from nsi.rosminzdrav.ru and '
      'commit it as $_ruOwnFile.',
    );
  }
}

/// What one edition gives: names of codes, the leaf block of every
/// three-character code, chapters and blocks with their names.
class _Edition {
  final Map<String, String> names = <String, String>{};
  final Map<String, String> blockOf = <String, String>{};

  /// Chapter number of every three-character code.
  final Map<String, int> chapterOf = <String, int>{};

  /// Chapter number (1–22) → name; block range → name.
  final Map<int, String> chapters = <int, String>{};
  final Map<String, String> blocks = <String, String>{};

  /// Every block range, nested ones included.
  final List<String> ranges = <String>[];
  late final String language;
}

/// The chapters with their leaf blocks, in the order of the codes.
List<PackageGroup> _catalog(
  List<_Edition> editions,
  Map<String, int> chapterOfBlock,
) {
  final List<PackageGroup> chapters = <PackageGroup>[];
  final List<int> numbers = chapterOfBlock.values.toSet().toList()..sort();
  for (final int number in numbers) {
    final List<String> blocks =
        chapterOfBlock.keys
            .where((String b) => chapterOfBlock[b] == number)
            .toList()
          ..sort();
    final String range =
        '${blocks.first.substring(0, 3)}–${blocks.last.substring(4)}';
    chapters.add(
      PackageGroup(
        key: _roman(number),
        code: range,
        names: <String, String>{
          for (final _Edition e in editions)
            if (e.chapters[number] != null) e.language: e.chapters[number]!,
        },
        children: <PackageGroup>[
          for (final String block in blocks)
            PackageGroup(
              key: block,
              code: block.substring(0, 3) == block.substring(4)
                  ? block.substring(0, 3)
                  : block.replaceAll('-', '–'),
              names: <String, String>{
                for (final _Edition e in editions)
                  if (_blockName(e, block) != null)
                    e.language: _blockName(e, block)!,
              },
            ),
        ],
      ),
    );
  }
  return chapters;
}

/// The name of [block] in [edition]; the editions draw some ranges a little
/// differently («F60-F68» and «F60-F69»), so a block with the same first or
/// last code stands in.
String? _blockName(_Edition edition, String block) =>
    edition.blocks[block] ??
    edition.blocks.entries
        .where(
          (MapEntry<String, String> b) =>
              b.key.substring(0, 3) == block.substring(0, 3),
        )
        .firstOrNull
        ?.value ??
    edition.blocks.entries
        .where(
          (MapEntry<String, String> b) =>
              b.key.substring(4) == block.substring(4),
        )
        .firstOrNull
        ?.value;

// ---------------------------------------------------------------- Russian

_Edition _readRussian(String csv) {
  final _Edition edition = _Edition()..language = 'ru';
  final List<Map<String, String>> rows = parseCsv(csv)
      .where((Map<String, String> r) => r['ACTUAL'] == '1')
      .toList();
  final Map<String, Map<String, String>> byId = <String, Map<String, String>>{
    for (final Map<String, String> r in rows) r['ID']!: r,
  };
  int chapter = 0;
  for (final Map<String, String> r in rows) {
    final String code = r['MKB_CODE']!;
    final String name = _clean(r['MKB_NAME']!);
    if (r['ID_PARENT']!.isEmpty) {
      chapter++;
      edition.chapters[chapter] = sentenceCase(name);
      continue;
    }
    final Match? range = _range.firstMatch(code);
    if (range != null && code.contains('-')) {
      final String key = '${range[1]}-${range[2]}';
      edition.blocks[key] = sentenceCase(name);
      edition.ranges.add(key);
      continue;
    }
    if (!_code.hasMatch(code)) {
      continue;
    }
    edition.names[code] = name;
    if (code.length == 3) {
      edition.chapterOf[code] = chapter;
      // The nearest range above the code is its leaf block.
      Map<String, String>? parent = byId[r['ID_PARENT']];
      while (parent != null && !parent['MKB_CODE']!.contains('-')) {
        parent = byId[parent['ID_PARENT']];
      }
      if (parent != null) {
        final Match m = _range.firstMatch(parent['MKB_CODE']!)!;
        edition.blockOf[code] = '${m[1]}-${m[2]}';
      }
    }
  }
  return edition;
}

// -------------------------------------------------------------- Ukrainian

Future<_Edition> _readUkrainian(File pdf) async {
  final _Edition edition = _Edition()..language = 'uk';
  final String layout = await runTool('pdftotext', <String>[
    '-layout',
    '-l',
    '70',
    pdf.path,
    '-',
  ]);
  _readUkrainianList(edition, layout);
  final String bbox = await runTool('pdftotext', <String>[
    '-bbox',
    '-f',
    '60',
    pdf.path,
    '-',
  ]);
  _readUkrainianTable(edition, bbox);
  return edition;
}

/// Section 5 «Перелік тризначних рубрик»: chapters («КЛАС n» and a title
/// ending with its range), blocks (a title ending with a range) and the
/// three-character codes; long titles wrap onto indented lines.
void _readUkrainianList(_Edition edition, String layout) {
  final List<String> lines = layout.split('\n');
  final int start = lines.indexWhere(
    (String l) => l.contains('ПЕРЕЛІК ТРИЗНАЧНИХ РУБРИК'),
  );
  final int end = lines.indexWhere(
    (String l) => l.contains('ТАБЛИЧНИЙ ПЕРЕЛІК ХВОРОБ'),
  );
  final RegExp chapterLine = RegExp(r'^КЛАС\s+(\d+)\s*$');
  final RegExp codeLine = RegExp(r'^([A-Z]\d\d)[*+†]?\s+(.+)$');
  final RegExp pageNumber = RegExp(r'^\s*\d+\s*$');
  int chapter = 0;
  bool chapterTitle = false;
  final StringBuffer title = StringBuffer();
  String? lastCode;

  for (final String raw in lines.sublist(start + 1, end)) {
    // A page starts with a form feed; some codes are typed with Cyrillic
    // look-alike letters («Н00», «А50»).
    final String line = raw
        .replaceAll('\f', '')
        .replaceAllMapped(
          RegExp(r'([АВСЕНКМОРТХ])(?=\d\d)'),
          (Match m) => _latin[m[1]]!,
        )
        .trimRight();
    if (line.trim().isEmpty || pageNumber.hasMatch(line)) {
      continue;
    }
    final Match? ch = chapterLine.firstMatch(line.trim());
    if (ch != null) {
      chapter = int.parse(ch[1]!);
      chapterTitle = true;
      title.clear();
      lastCode = null;
      continue;
    }
    final Match? code = codeLine.firstMatch(line);
    if (code != null && title.isEmpty) {
      lastCode = code[1];
      edition.names[lastCode!] = _clean(code[2]!);
      edition.chapterOf[lastCode] = chapter;
      continue;
    }
    // A long name wraps onto an indented line, or onto one that starts in
    // the first column with a small letter («період»).
    if (lastCode != null &&
        title.isEmpty &&
        (line.startsWith(' ') ||
            RegExp(r'^\p{Ll}', unicode: true).hasMatch(line))) {
      edition.names[lastCode] = _join(edition.names[lastCode]!, line.trim());
      continue;
    }
    // A title line of a chapter or a block, possibly one of several.
    lastCode = null;
    title.write(title.isEmpty ? line.trim() : ' ${line.trim()}');
    // «(A00-A09)», a range wrapped as «(O00-» + «O99)», one code «(O09)»,
    // or two ranges «(U00-U49, U78–U88)»: the key spans them all.
    final Match? range = RegExp(r'^(.*?)\s*\(([A-Z]\d\d)([^()]*)\)$')
        .firstMatch(title.toString());
    if (range == null) {
      continue;
    }
    final String last =
        RegExp(r'[A-Z]\d\d').allMatches(range[3]!).lastOrNull?[0] ?? range[2]!;
    final String name = sentenceCase(_clean(range[1]!));
    final String key = '${range[2]}-$last';
    if (chapterTitle) {
      edition.chapters[chapter] = name;
      chapterTitle = false;
    } else {
      edition.blocks[key] = name;
      edition.ranges.add(key);
    }
    title.clear();
  }
  _assignLeafBlocks(edition);
}

/// The table of section 6: columns «code 3 | name 3 | code 4 | name 4 |
/// code 5 | name 5». A row starts at its three-character code; the words of
/// a cell may wrap below it until the next row, even onto the next page.
/// Every level is taken: the five-character codes of the Ukrainian edition
/// («A41.51») are what Ukrainian documents write. A fourth level with an
/// empty name («X85.0») is named after its heading; a heading missing from
/// the list of section 5 («U08») takes its name from the table.
void _readUkrainianTable(_Edition edition, String bbox) {
  final RegExp word = RegExp(
    r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="[\d.]+" yMax="[\d.]+">'
    r'([^<]*)</word>',
  );
  // Left edges of the columns, in points.
  const List<double> starts = <double>[0, 125, 245, 290, 420, 465];
  int columnOf(double x) {
    int column = 0;
    while (column + 1 < starts.length && x >= starts[column + 1]) {
      column++;
    }
    return column;
  }

  final List<_Row> rows = <_Row>[];
  bool inTable = false;
  for (final String page in bbox.split('<page ')) {
    if (!inTable) {
      inTable = page.contains('>ТАБЛИЧНИЙ<');
      if (!inTable) {
        continue;
      }
    }
    final List<(double, double, String)> words = <(double, double, String)>[
      for (final Match m in word.allMatches(page))
        if (!(double.parse(m[2]!) > 770 && RegExp(r'^\d+$').hasMatch(m[3]!)))
          (double.parse(m[1]!), double.parse(m[2]!), _unescape(m[3]!)),
    ];
    // Row anchors: the three-character codes of the first column. A row
    // spans from a little above its anchor (the name font sits higher) to
    // the next anchor.
    final List<double> anchors = <double>[
      for (final (double x, double y, String t) in words)
        if (x < starts[1] && RegExp(r'^[A-Z]\d\d$').hasMatch(t)) y,
    ]..sort();
    final int first = rows.length;
    rows.addAll(<_Row>[for (final double _ in anchors) _Row()]);
    int order((double, double, String) a, (double, double, String) b) =>
        (a.$2 - b.$2).abs() > 3 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1);
    for (final (double x, double y, String text) in words.sorted(order)) {
      int row = -1;
      for (int i = 0; i < anchors.length && anchors[i] - 4 <= y; i++) {
        row = i;
      }
      // Words above the first row finish the last row of the page before;
      // the header of the table on its first page has no row before it.
      final int index = row < 0 ? first - 1 : first + row;
      if (index < 0) {
        continue;
      }
      final int column = columnOf(x);
      final bool onAnchor = row >= 0 && (anchors[row] - y).abs() < 1;
      if (column.isEven) {
        if (onAnchor) {
          rows[index].codes[column ~/ 2] = text;
        }
      } else {
        rows[index].names[column ~/ 2].add(text);
      }
    }
  }

  final Map<String, String> headings = <String, String>{};
  for (final _Row row in rows) {
    final List<String> names = <String>[
      for (final List<String> words in row.names) _clean(words.join(' ')),
    ];
    final String? code3 = row.codes[0];
    if (code3 != null && names[0].isNotEmpty) {
      headings.putIfAbsent(code3, () => names[0]);
    }
    for (final int level in <int>[1, 2]) {
      final String? code = row.codes[level];
      if (code != null && _code.hasMatch(code) && names[level].isNotEmpty) {
        edition.names.putIfAbsent(code, () => names[level]);
      }
    }
  }
  for (final _Row row in rows) {
    final String? code4 = row.codes[1];
    final String? code3 = row.codes[0];
    if (code4 != null && _code.hasMatch(code4) && code3 != null) {
      final String? heading = edition.names[code3] ?? headings[code3];
      if (heading != null) {
        edition.names.putIfAbsent(code4, () => heading);
      }
    }
  }
  for (final MapEntry<String, String> h in headings.entries) {
    if (edition.names.putIfAbsent(h.key, () => h.value) == h.value) {
      edition.chapterOf.putIfAbsent(
        h.key,
        () => edition.chapterOf.entries
            .lastWhere(
              (MapEntry<String, int> c) => c.key.compareTo(h.key) < 0,
              orElse: () => const MapEntry<String, int>('', 0),
            )
            .value,
      );
    }
  }
}

/// One row of the Ukrainian table: the codes and the name words of its
/// three levels.
class _Row {
  final List<String?> codes = List<String?>.filled(3, null);
  final List<List<String>> names = <List<String>>[
    <String>[],
    <String>[],
    <String>[],
  ];
}

/// Each three-character code belongs to the narrowest range around it.
void _assignLeafBlocks(_Edition edition) {
  for (final String code in edition.names.keys.where(
    (String c) => c.length == 3,
  )) {
    final String? best = _narrowest(code, edition.ranges);
    if (best != null) {
      edition.blockOf[code] = best;
    }
  }
}

String? _narrowest(String code, List<String> ranges) {
  String? best;
  for (final String r in ranges) {
    if (code.compareTo(r.substring(0, 3)) >= 0 &&
        code.compareTo(r.substring(4)) <= 0 &&
        (best == null || _width(r) < _width(best))) {
      best = r;
    }
  }
  return best;
}

int _width(String range) =>
    _ordinal(range.substring(4)) - _ordinal(range.substring(0, 3));

int _ordinal(String code) =>
    (code.codeUnitAt(0) - 65) * 100 + int.parse(code.substring(1, 3));

// ---------------------------------------------------------------- English

Future<_Edition> _readEnglish(File codesZip, File tabularZip, int year) async {
  final _Edition edition = _Edition()..language = 'en';
  final String order = await runTool('unzip', <String>[
    '-p',
    codesZip.path,
    '*icd10cm-order-$year.txt',
  ]);
  for (final String line in order.split('\n')) {
    if (line.length < 78) {
      continue;
    }
    final String raw = line.substring(6, 14).trim();
    if (raw.length > 4) {
      continue;
    }
    final String code = raw.length == 4
        ? '${raw.substring(0, 3)}.${raw.substring(3)}'
        : raw;
    edition.names[code] = line.substring(77).trim();
  }

  final String xml = await runTool('unzip', <String>[
    '-p',
    tabularZip.path,
    '*icd10cm-tabular*-$year.xml',
  ]);
  final RegExp chapter = RegExp(
    r'<chapter>\s*<name>(\d+)</name>\s*<desc>([^<]*)</desc>',
  );
  for (final Match m in chapter.allMatches(xml)) {
    edition.chapters[int.parse(m[1]!)] = _clean(
      m[2]!.replaceAll(RegExp(r'\s*\([A-Z]\d\d-[A-Z]\d\d\)\s*$'), ''),
    );
  }
  final RegExp section = RegExp(
    r'<section id="([A-Z]\d\d)-([A-Z]\d\d)">\s*<desc>([^<]*)</desc>',
  );
  for (final Match m in section.allMatches(xml)) {
    final String key = '${m[1]}-${m[2]}';
    edition.blocks[key] = _clean(
      _unescape(m[3]!)
          .replaceAll(RegExp(r'\s*\([A-Z]\d\d-[A-Z]\d\d\)\s*$'), ''),
    );
    edition.ranges.add(key);
  }
  _assignLeafBlocks(edition);
  return edition;
}

/// The narrow columns of the Ukrainian table break long words without a
/// hyphen («Макроглобулінемі я»). A long fragment that is (almost) never a
/// word on its own, followed by a short one, is joined when together they
/// make a word the classifier writes elsewhere.
void _joinBrokenWords(Map<String, String> names) {
  final RegExp letters = RegExp(r"[\p{L}'’]+", unicode: true);
  final Map<String, int> vocabulary = <String, int>{};
  for (final String name in names.values) {
    for (final Match m in letters.allMatches(name.toLowerCase())) {
      vocabulary[m[0]!] = (vocabulary[m[0]!] ?? 0) + 1;
    }
  }
  final RegExp broken = RegExp(
    r'(\p{L}{10,}) (\p{Ll}{1,4})(?![\p{L}])',
    unicode: true,
  );
  for (final String code in names.keys.toList()) {
    names[code] = names[code]!.replaceAllMapped(broken, (Match m) {
      final String head = m[1]!.toLowerCase();
      final bool joins =
          (vocabulary[head + m[2]!] ?? 0) > 0 && (vocabulary[head] ?? 0) <= 2;
      return joins ? '${m[1]}${m[2]}' : m[0]!;
    });
  }
}

// ----------------------------------------------------------------- Common

/// Joins the wrapped parts of a name: after a hyphen without a space
/// («медико-» + «соціальні»), otherwise with one.
String _join(String head, String tail) =>
    head.endsWith('-') ? '$head$tail' : '$head $tail';

/// Collapses spaces, joins a word wrapped after its hyphen («серцево-
/// судинної»), lowers the site written after «новоутворення» in the
/// Ukrainian table («новоутворення Губи» → «новоутворення губи») and drops
/// the cross-references of the classifier («(G07*)», «(I60-I67 †)», a
/// trailing «*»).
String _clean(String name) => name
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(
      RegExp(r'(\p{L})- (\p{L})', unicode: true),
      (Match m) => '${m[1]}-${m[2]}',
    )
    .replaceAllMapped(
      RegExp(r'(новоутворення|характеру) (\p{Lu})(\p{Ll})', unicode: true),
      (Match m) => '${m[1]} ${m[2]!.toLowerCase()}${m[3]}',
    )
    .replaceAll(RegExp(r'\s*\([^()]*[A-Z]\d\d[^()]*[*†+][^()]*\)'), '')
    .replaceAll(RegExp(r'[*†]$'), '')
    .replaceAll(' ,', ',')
    .trim();

const Map<String, String> _latin = <String, String>{
  'А': 'A',
  'В': 'B',
  'С': 'C',
  'Е': 'E',
  'Н': 'H',
  'К': 'K',
  'М': 'M',
  'О': 'O',
  'Р': 'P',
  'Т': 'T',
  'Х': 'X',
};

String _unescape(String text) => text
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'");

String _roman(int n) {
  const List<(int, String)> parts = <(int, String)>[
    (10, 'X'),
    (9, 'IX'),
    (5, 'V'),
    (4, 'IV'),
    (1, 'I'),
  ];
  final StringBuffer out = StringBuffer();
  int rest = n;
  for (final (int value, String letter) in parts) {
    while (rest >= value) {
      out.write(letter);
      rest -= value;
    }
  }
  return out.toString();
}

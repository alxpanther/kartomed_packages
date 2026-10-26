// Spelling of medicine names across alphabets, for the build scripts:
// international names of substances (Latin) in Russian and Ukrainian, and
// Ukrainian trade names in Russian and Latin letters. The rules follow the
// usual pharmaceutical spelling; the exceptions live in
// `data/drug_substances.json`.

/// Ukrainian trade name → Russian letters: «Ібупрофен» → «Ибупрофен».
String ukrainianToRussian(String text) {
  const Map<String, String> map = <String, String>{
    'і': 'и',
    'І': 'И',
    'ї': 'и',
    'Ї': 'И',
    'є': 'е',
    'Є': 'Е',
    'ґ': 'г',
    'Ґ': 'Г',
    "'": '',
    '’': '',
    '`': '',
  };
  return text.split('').map((String c) => map[c] ?? c).join();
}

/// Ukrainian → Latin by the national standard of 2010: «Дарниця» →
/// «Darnytsia».
String ukrainianToLatin(String text) {
  const Map<String, String> map = <String, String>{
    'а': 'a',
    'б': 'b',
    'в': 'v',
    'г': 'h',
    'ґ': 'g',
    'д': 'd',
    'е': 'e',
    'є': 'ie',
    'ж': 'zh',
    'з': 'z',
    'и': 'y',
    'і': 'i',
    'ї': 'i',
    'й': 'i',
    'к': 'k',
    'л': 'l',
    'м': 'm',
    'н': 'n',
    'о': 'o',
    'п': 'p',
    'р': 'r',
    'с': 's',
    'т': 't',
    'у': 'u',
    'ф': 'f',
    'х': 'kh',
    'ц': 'ts',
    'ч': 'ch',
    'ш': 'sh',
    'щ': 'shch',
    'ь': '',
    'ю': 'iu',
    'я': 'ia',
    "'": '',
    '’': '',
    '`': '',
    'ё': 'e',
    'ы': 'y',
    'э': 'e',
    'ъ': '',
  };
  // At the start of a word «є, ї, й, ю, я» are written «ye, yi, y, yu, ya».
  const Map<String, String> initial = <String, String>{
    'є': 'ye',
    'ї': 'yi',
    'й': 'y',
    'ю': 'yu',
    'я': 'ya',
  };
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < text.length; i++) {
    final String c = text[i];
    final String lower = c.toLowerCase();
    final bool wordStart =
        i == 0 || !RegExp(r'\p{L}', unicode: true).hasMatch(text[i - 1]);
    String? latin = (wordStart ? initial[lower] : null) ?? map[lower];
    if (latin == null) {
      out.write(c);
      continue;
    }
    if (lower == 'г' && i > 0 && text[i - 1].toLowerCase() == 'з') {
      latin = 'gh'; // «зг» → «zgh», not «zh»
    }
    if (c != lower && latin.isNotEmpty) {
      final bool allCaps =
          i + 1 < text.length && text[i + 1] != text[i + 1].toLowerCase();
      latin = allCaps
          ? latin.toUpperCase()
          : latin[0].toUpperCase() + latin.substring(1);
    }
    out.write(latin);
  }
  return out.toString();
}

/// International name of a substance → Russian ([russian] true) or
/// Ukrainian spelling: «Amoxicillin» → «амоксициллин» / «амоксицилін»,
/// «Sodium chloride» → «натрия хлорид» / «натрію хлорид».
String substanceToCyrillic(String inn, {required bool russian}) {
  String text = inn.toLowerCase();
  for (final MapEntry<String, (String, String)> p in _phrases.entries) {
    text = text.replaceAll(p.key, russian ? p.value.$1 : p.value.$2);
  }
  // «Perindopril, amlodipine and indapamide»: a list of substances.
  if (text.contains(' and ')) {
    text = text.replaceAll(', ', ' and ');
  }
  final List<String> words = text.split(RegExp(r'\s+'));
  final List<String> out = <String>[];
  for (int i = 0; i < words.length; i++) {
    final String word = words[i];
    final String? next = i + 1 < words.length ? words[i + 1] : null;
    final String? fixed = (russian ? _wordsRu : _wordsUk)[word];
    if (fixed != null) {
      out.add(fixed);
      continue;
    }
    if (RegExp(r'^[ivx]+$').hasMatch(word)) {
      out.add(word.toUpperCase()); // «factor VIII»
      continue;
    }
    if (RegExp(r'[а-яіїєґ]').hasMatch(word)) {
      out.add(word); // already spelled by a phrase
      continue;
    }
    if (word == 'acid') {
      out.add('кислота');
      continue;
    }
    if (next == 'acid' && word.endsWith('ic')) {
      out.add(_acidAdjective(word, russian: russian));
      continue;
    }
    out.add(
      word
          .split('-')
          .map((String part) => _letters(part, russian: russian))
          .join('-'),
    );
  }
  return out.join(' ');
}

/// «salicylic» → «салициловая» / «саліцилова»: the adjective of an acid.
String _acidAdjective(String word, {required bool russian}) {
  final String stem = _letters(
    word.substring(0, word.length - 2),
    russian: russian,
  );
  final bool afterVowel = RegExp(r'[аеиоуіо]$').hasMatch(stem);
  final String ending = russian
      ? (afterVowel ? 'евая' : 'овая')
      : (afterVowel ? 'єва' : 'ова');
  return stem + ending;
}

const String _vowels = 'aeiouy';

bool _isVowel(String? c) => c != null && _vowels.contains(c);

/// Letter-by-letter spelling of one Latin word.
String _letters(String word, {required bool russian}) {
  final String w = word.replaceAll(RegExp(r'[^a-z]'), '');
  if (w.isEmpty) {
    return word;
  }
  final StringBuffer out = StringBuffer();
  int i = 0;
  String? at(int k) => k >= 0 && k < w.length ? w[k] : null;
  bool starts(String s) => w.startsWith(s, i);

  while (i < w.length) {
    final String c = w[i];
    final String? prev = at(i - 1);
    final String? next = at(i + 1);
    final bool last = i == w.length - 1;

    // Endings.
    if (w.length - i == 3 && starts('ium')) {
      out.write(russian ? 'ий' : 'ій');
      break;
    }
    if (w.length - i == 3 && starts('ase')) {
      out.write('аза');
      break;
    }
    if (last && c == 'e' && i > 0 && !_isVowel(prev)) {
      break; // a silent final «e»: -ine, -ide, -ate, -one, -ole
    }

    // Letter groups.
    const Map<String, String> groups = <String, String>{
      'sulf': 'сульф',
      'sch': 'ш',
      'ch': 'х',
      'ph': 'ф',
      'th': 'т',
      'rh': 'р',
      'sh': 'ш',
      'kh': 'х',
      'zh': 'ж',
      'ck': 'к',
      'qu': 'кв',
      'ou': 'у',
    };
    final String? group = groups.keys.where(starts).firstOrNull;
    if (group != null) {
      out.write(groups[group]);
      i += group.length;
      continue;
    }
    if ((starts('ae') || starts('oe')) && i + 1 < w.length) {
      out.write(i == 0 && russian ? 'э' : 'е');
      i += 2;
      continue;
    }

    switch (c) {
      case 'a':
        out.write('а');
      case 'b':
        out.write('б');
      case 'c':
        out.write('eiy'.contains(next ?? '_') ? 'ц' : 'к');
      case 'd':
        out.write('д');
      case 'e':
        out.write(i == 0 && russian ? 'э' : 'е');
      case 'f':
        out.write('ф');
      case 'g':
        out.write('г');
      case 'h':
        out.write('г');
      case 'i' || 'y':
        out.write(_i(w, i, out.toString(), russian: russian));
      case 'j':
        out.write('й');
      case 'k':
        out.write('к');
      case 'l':
        out.write('л');
      case 'm':
        out.write('м');
      case 'n':
        out.write('н');
      case 'o':
        out.write('о');
      case 'p':
        out.write('п');
      case 'r':
        out.write('р');
      case 's':
        // Mostly «с» (бисопролол, фуросемид); «з» in «iso-» and in the
        // steroid endings «-isolone», «-isone» (изониазид, преднизолон).
        out.write(
          (i == 1 && prev == 'i' && next == 'o') ||
                  (prev == 'i' &&
                      (w.startsWith('olon', i + 1) ||
                          w.startsWith('on', i + 1) && i + 3 >= w.length - 1))
              ? 'з'
              : 'с',
        );
      case 't':
        out.write('т');
      case 'u':
        out.write('у');
      case 'v' || 'w':
        out.write('в');
      case 'x':
        out.write('кс');
      case 'z':
        out.write('з');
    }
    i++;
  }
  String result = out.toString();
  if (!russian) {
    // Ukrainian writes one letter for a double consonant of a borrowed
    // word: «амоксицилін», «метронідазол».
    result = result.replaceAllMapped(
      RegExp(r'([бвгдзклмнпрстфхц])\1'),
      (Match m) => m[1]!,
    );
  }
  return result;
}

/// «i» and «y»: Russian «и»; Ukrainian «ї» after a vowel, «и» after
/// «д т з с ц ж ч ш р» before a consonant (the rule of nine), otherwise
/// «і». [written] is the Cyrillic spelled so far.
String _i(String w, int i, String written, {required bool russian}) {
  if (russian) {
    return 'и';
  }
  final String? next = i + 1 < w.length ? w[i + 1] : null;
  final String? prev = written.isEmpty ? null : written[written.length - 1];
  if (prev != null && 'аеиоуії'.contains(prev)) {
    return 'ї';
  }
  final bool afterNine = prev != null && 'дтзсцжчшр'.contains(prev);
  final bool beforeConsonant = next != null && !_isVowel(next);
  return afterNine && beforeConsonant ? 'и' : 'і';
}

/// Phrases spelled as a whole (Russian, Ukrainian).
const Map<String, (String, String)> _phrases = <String, (String, String)>{
  'beta-lactamase inhibitor': (
    'ингибитор бета-лактамаз',
    'інгібітор бета-лактамаз',
  ),
  'decarboxylase inhibitor': (
    'ингибитор декарбоксилазы',
    'інгібітор декарбоксилази',
  ),
  'coagulation factor': ('фактор свертывания крови', 'фактор згортання крові'),
};

const Map<String, String> _wordsRu = <String, String>{
  'and': '+',
  'diuretics': 'диуретики',
  'antibiotics': 'антибиотики',
  'antiseptics': 'антисептики',
  'analgesics': 'анальгетики',
  'antiinfectives': 'противомикробные',
  'sulfonylureas': 'производные сульфонилмочевины',
  'corticosteroids': 'кортикостероиды',
  'sodium': 'натрия',
  'potassium': 'калия',
  'calcium': 'кальция',
  'magnesium': 'магния',
  'zinc': 'цинка',
  'iron': 'железа',
  'lithium': 'лития',
  'aluminium': 'алюминия',
  'silver': 'серебра',
  'iodine': 'йод',
  'chloride': 'хлорид',
  'oxide': 'оксид',
  'sulfate': 'сульфат',
  'carbonate': 'карбонат',
  'citrate': 'цитрат',
  'gluconate': 'глюконат',
  'phosphate': 'фосфат',
  'lactate': 'лактат',
  'acetate': 'ацетат',
  'hydroxide': 'гидроксид',
  'inhibitor': 'ингибитор',
  'combinations': 'комбинации',
  'vitamin': 'витамин',
  'factor': 'фактор',
  'coagulation': 'коагуляции',
  'human': 'человеческий',
  'insulin': 'инсулин',
  'alfa': 'альфа',
  'beta': 'бета',
  'gamma': 'гамма',
  'various': 'разные',
};

const Map<String, String> _wordsUk = <String, String>{
  'and': '+',
  'diuretics': 'діуретики',
  'antibiotics': 'антибіотики',
  'antiseptics': 'антисептики',
  'analgesics': 'анальгетики',
  'antiinfectives': 'протимікробні',
  'sulfonylureas': 'похідні сульфонілсечовини',
  'corticosteroids': 'кортикостероїди',
  'sodium': 'натрію',
  'potassium': 'калію',
  'calcium': 'кальцію',
  'magnesium': 'магнію',
  'zinc': 'цинку',
  'iron': 'заліза',
  'lithium': 'літію',
  'aluminium': 'алюмінію',
  'silver': 'срібла',
  'iodine': 'йод',
  'chloride': 'хлорид',
  'oxide': 'оксид',
  'sulfate': 'сульфат',
  'carbonate': 'карбонат',
  'citrate': 'цитрат',
  'gluconate': 'глюконат',
  'phosphate': 'фосфат',
  'lactate': 'лактат',
  'acetate': 'ацетат',
  'hydroxide': 'гідроксид',
  'inhibitor': 'інгібітор',
  'combinations': 'комбінації',
  'vitamin': 'вітамін',
  'factor': 'фактор',
  'coagulation': 'згортання крові',
  'human': 'людини',
  'insulin': 'інсулін',
  'alfa': 'альфа',
  'beta': 'бета',
  'gamma': 'гамма',
  'various': 'різні',
};

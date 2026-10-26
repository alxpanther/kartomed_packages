// Mixed Cyrillic and Latin letters inside one word.
//
// The official sources type look-alike letters of the other alphabet: the
// Ukrainian classifier writes «Епiлепсiя» with a Latin «i» and «ВIЛ» with a
// Latin «I», the register of medicines writes «Flоrеs» with Cyrillic «о» and
// «е». Such a word looks right but is never found by a search typed on a
// phone keyboard. Every word that has letters of both alphabets is brought
// to one of them; look-alikes only, nothing else of the text changes.

/// Cyrillic letter → the Latin letter that looks the same.
const Map<String, String> _cyrillicToLatin = <String, String>{
  'А': 'A', 'В': 'B', 'С': 'C', 'Е': 'E', 'Н': 'H', 'І': 'I', 'К': 'K', //
  'М': 'M', 'О': 'O', 'Р': 'P', 'Т': 'T', 'Х': 'X', 'а': 'a', 'с': 'c', //
  'е': 'e', 'і': 'i', 'о': 'o', 'р': 'p', 'х': 'x', 'у': 'y',
};

final Map<String, String> _latinToCyrillic = <String, String>{
  for (final MapEntry<String, String> e in _cyrillicToLatin.entries)
    e.value: e.key,
};

final RegExp _word = RegExp(
  r'[\p{Script=Latin}\p{Script=Cyrillic}]+',
  unicode: true,
);
final RegExp _cyrillic = RegExp(r'\p{Script=Cyrillic}', unicode: true);
final RegExp _latin = RegExp(r'\p{Script=Latin}', unicode: true);
final RegExp _roman = RegExp(r'^[IVX]+$');

/// [text] with every mixed word written in one alphabet:
/// - a Roman numeral («ІI», «ІV») — in Latin;
/// - a word with letters that exist only in Cyrillic («Епiлепсiя») — in
///   Cyrillic, and with letters only in Latin («Flоrеs», «GМ2») — in Latin;
/// - a word of look-alikes only («AТ», «MВ130») follows the alphabet most
///   of its letters are in, and on a tie the alphabet of the rest of [text]
///   («Санека Фармасьютікалз AТ» → «АТ»).
///
/// A word with letters that exist only in Cyrillic and others only in Latin
/// («Foenиgraeci») is a typo of the source that cannot be fixed without a
/// guess, and stays as it is.
String fixMixedScript(String text) {
  final ({int cyrillic, int latin}) all = _count(text);
  return text.replaceAllMapped(_word, (Match m) {
    final String word = m[0]!;
    if (!_cyrillic.hasMatch(word) || !_latin.hasMatch(word)) {
      return word;
    }
    final String asLatin = _map(word, _cyrillicToLatin);
    if (_roman.hasMatch(asLatin)) {
      return asLatin;
    }
    final String asCyrillic = _map(word, _latinToCyrillic);
    final bool onlyCyrillic = word
        .split('')
        .any(
          (String c) =>
              _cyrillic.hasMatch(c) && !_cyrillicToLatin.containsKey(c),
        );
    final bool onlyLatin = word
        .split('')
        .any(
          (String c) => _latin.hasMatch(c) && !_latinToCyrillic.containsKey(c),
        );
    if (onlyCyrillic || onlyLatin) {
      return onlyCyrillic && onlyLatin
          ? word
          : (onlyCyrillic ? asCyrillic : asLatin);
    }
    final ({int cyrillic, int latin}) own = _count(word);
    if (own.cyrillic != own.latin) {
      return own.cyrillic > own.latin ? asCyrillic : asLatin;
    }
    final int contextCyrillic = all.cyrillic - own.cyrillic;
    final int contextLatin = all.latin - own.latin;
    if (contextCyrillic == contextLatin) {
      return word;
    }
    return contextCyrillic > contextLatin ? asCyrillic : asLatin;
  });
}

({int cyrillic, int latin}) _count(String text) => (
  cyrillic: _cyrillic.allMatches(text).length,
  latin: _latin.allMatches(text).length,
);

String _map(String word, Map<String, String> table) =>
    word.split('').map((String c) => table[c] ?? c).join();

/// [fixMixedScript] over every string of a decoded JSON tree, except the
/// values of `key`: a stable key never changes, or the entry would lose its
/// identity in the database.
Object? fixMixedScriptDeep(Object? value) => switch (value) {
  final String s => fixMixedScript(s),
  final List<Object?> list => list.map(fixMixedScriptDeep).toList(),
  final Map<String, Object?> map => <String, Object?>{
    for (final MapEntry<String, Object?> e in map.entries)
      e.key: e.key == 'key' ? e.value : fixMixedScriptDeep(e.value),
  },
  _ => value,
};

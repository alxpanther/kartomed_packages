// One clinic network as the application downloads it: the file
// `packages/<id>.json`, built from what the model read on its site.
//
//   {id, name, kind, country, site, cities: {<key>: {uk, ru, en, local}},
//    phones, emails, branches: [
//     {ref, city, address, postcode?, phones, emails, schedule?, hoursNote?}]}
//
// `phones` / `emails` are `[{value, label?}]`, as the application keeps them;
// `schedule` is `{"1": ["08:00-20:00"], …}` (1 Monday … 7 Sunday, days off
// left out), the application's `WeeklyHours`. `city` is the key of a city
// of `index.json`. `ref` names a branch across months: the application finds
// the same branch by it.
import 'package:crypto/crypto.dart';

import 'dart:convert';

/// A network of `sources.json`.
class NetworkSource {
  const NetworkSource({
    required this.id,
    required this.name,
    required this.kind,
    required this.country,
    required this.site,
    required this.pages,
    this.render = false,
    this.saved,
  });

  factory NetworkSource.fromJson(Map<String, Object?> json) => NetworkSource(
    id: json['id']! as String,
    name: json['name']! as String,
    kind: json['kind']! as String,
    country: json['country']! as String,
    site: json['site']! as String,
    pages: (json['pages']! as List<Object?>).cast<String>(),
    render: json['render'] as bool? ?? false,
    saved: json['saved'] == null
        ? null
        : SavedPage.fromJson(json['saved']! as Map<String, Object?>),
  );

  final String id;
  final String name;

  /// `clinic` or `lab`.
  final String kind;

  /// ISO 3166-1 alpha-2.
  final String country;
  final String site;
  final List<String> pages;
  final bool render;

  /// A site closed to programs (a bot check): its page saved by a person
  /// is read instead of the site.
  final SavedPage? saved;
}

/// The text of a site's page saved by a person, with the site's icon, in
/// `clinics/saved/`: `{"text": "clinics/saved/adonis.txt", "icon":
/// "clinics/saved/adonis.png", "date": "2026-10-27"}`. Read instead of the
/// site; saved again by hand when the build warns that it is old.
class SavedPage {
  const SavedPage({required this.text, required this.date, this.icon});

  factory SavedPage.fromJson(Map<String, Object?> json) => SavedPage(
    text: json['text']! as String,
    icon: json['icon'] as String?,
    date: DateTime.parse(json['date']! as String),
  );

  final String text;
  final String? icon;
  final DateTime date;
}

/// A city of the index: its key and its names.
class City {
  const City(this.key, this.names);

  /// `kyiv`, `warszawa`: the English name in plain Latin letters.
  final String key;

  /// `{uk, ru, en, local}`, the empty ones left out.
  final Map<String, String> names;
}

class Contact {
  const Contact(this.value, [this.label]);

  final String value;
  final String? label;

  Map<String, Object?> toJson() => <String, Object?>{
    'value': value,
    if (label != null) 'label': label,
  };
}

class Branch {
  Branch({
    required this.city,
    required this.address,
    this.postcode,
    List<Contact>? phones,
    List<Contact>? emails,
    Map<String, List<String>>? schedule,
    this.hoursNote,
  }) : phones = phones ?? <Contact>[],
       emails = emails ?? <Contact>[],
       schedule = schedule ?? <String, List<String>>{};

  final City city;
  final String address;
  final String? postcode;
  final List<Contact> phones;
  final List<Contact> emails;
  final Map<String, List<String>> schedule;
  final String? hoursNote;

  String get ref => branchRef(city.key, address);

  Map<String, Object?> toJson() => <String, Object?>{
    'ref': ref,
    'city': city.key,
    'address': address,
    if (postcode != null) 'postcode': postcode,
    'phones': phones.map((Contact c) => c.toJson()).toList(),
    'emails': emails.map((Contact c) => c.toJson()).toList(),
    if (schedule.isNotEmpty) 'schedule': schedule,
    if (hoursNote != null) 'hoursNote': hoursNote,
  };
}

class Network {
  Network({
    required this.source,
    required this.branches,
    List<Contact>? phones,
    List<Contact>? emails,
  }) : phones = phones ?? <Contact>[],
       emails = emails ?? <Contact>[];

  final NetworkSource source;
  final List<Branch> branches;
  final List<Contact> phones;
  final List<Contact> emails;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': source.id,
    'name': source.name,
    'kind': source.kind,
    'country': source.country,
    'site': source.site,
    'cities': <String, Object?>{
      for (final Branch b in branches) b.city.key: b.city.names,
    },
    'phones': phones.map((Contact c) => c.toJson()).toList(),
    'emails': emails.map((Contact c) => c.toJson()).toList(),
    'branches': branches.map((Branch b) => b.toJson()).toList(),
  };
}

/// The stable name of a branch: the same street of the same city gives the
/// same ref whatever the punctuation, case or «вул.» / «ул.» / «ul.».
String branchRef(String city, String address) {
  final String key = '$city|${normalizeAddress(address)}';
  return sha256.convert(utf8.encode(key)).toString().substring(0, 12);
}

const Set<String> _streetWords = <String>{
  'вул',
  'вулиця',
  'ул',
  'улица',
  'ul',
  'ulica',
  'просп',
  'проспект',
  'пр',
  'пр-т',
  'бульв',
  'бульвар',
  'бул',
  'пл',
  'площа',
  'площадь',
  'al',
  'aleja',
  'aleje',
  'pl',
  'plac',
  'ulice',
  'str',
  'street',
  'м',
  'г',
  'місто',
  'город',
};

String normalizeAddress(String address) => address
    .toLowerCase()
    .replaceAll('’', "'")
    .replaceAll(RegExp(r"[^\p{L}\p{N}/']+", unicode: true), ' ')
    .split(' ')
    .where((String w) => w.isNotEmpty && !_streetWords.contains(w))
    .join(' ');

/// The key of a city from its local name in plain Latin letters: `kyiv`
/// from «Київ», `warszawa` from «Warszawa», `bialystok` from «Białystok».
/// The local name, not the English one: the model writes Warsaw on one page
/// and Warszawa on another, while the local name stays the same.
String cityKey(String local) {
  const Map<String, String> plain = <String, String>{
    // Ukrainian (the national transliteration), and the Russian letters.
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'h', 'ґ': 'g', 'д': 'd', 'е': 'e',
    'є': 'ie', 'ж': 'zh', 'з': 'z', 'и': 'y', 'і': 'i', 'ї': 'i', 'й': 'i',
    'к': 'k', 'л': 'l', 'м': 'm', 'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r',
    'с': 's', 'т': 't', 'у': 'u', 'ф': 'f', 'х': 'kh', 'ц': 'ts', 'ч': 'ch',
    'ш': 'sh', 'щ': 'shch', 'ь': '', "'": '', '’': '', 'ю': 'iu', 'я': 'ia',
    'ы': 'y', 'э': 'e', 'ё': 'e', 'ъ': '',
    'ą': 'a',
    'ć': 'c',
    'ę': 'e',
    'ł': 'l',
    'ń': 'n',
    'ó': 'o',
    'ś': 's',
    'ź': 'z',
    'ż': 'z',
    'á': 'a',
    'č': 'c',
    'ď': 'd',
    'é': 'e',
    'ě': 'e',
    'í': 'i',
    'ň': 'n',
    'ř': 'r',
    'š': 's',
    'ť': 't',
    'ú': 'u',
    'ů': 'u',
    'ý': 'y',
    'ž': 'z',
    'đ': 'd',
    'ü': 'u',
    'ö': 'o',
    'ä': 'a',
  };
  return local
      .toLowerCase()
      .split('')
      .map((String c) => plain[c] ?? c)
      .join()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

const Map<String, String> _dialCodes = <String, String>{
  'UA': '380',
  'PL': '48',
  'CZ': '420',
  'ME': '382',
};

/// [raw] in the international form `+380441234567`, or null when it is not
/// a phone number. A national number gets the code of [country].
String? normalizePhone(String raw, String country) {
  final String digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 6) {
    return null;
  }
  final String code = _dialCodes[country] ?? '';
  final String full;
  if (code == '380' && digits.startsWith('30') && !digits.startsWith('380')) {
    // «0 800 …» written by the model as «+3 0800 …»: a national number with
    // half of the code; a Greek number is not expected at a Ukrainian clinic.
    full = '38${digits.substring(1)}';
  } else if (raw.trim().startsWith('+') || raw.trim().startsWith('00')) {
    full = digits.startsWith('00') ? digits.substring(2) : digits;
  } else if (code == '380' && digits.startsWith('380')) {
    full = digits;
  } else if (code == '380' && digits.startsWith('0')) {
    full = '38$digits';
  } else if (code.isNotEmpty &&
      digits.startsWith(code) &&
      digits.length > code.length + 7) {
    full = digits;
  } else {
    full = '$code${digits.replaceFirst(RegExp('^0+'), '')}';
  }
  return full.length >= 9 && full.length <= 15 ? '+$full' : null;
}

final RegExp _span = RegExp(
  r'^([01]\d|2[0-4]):[0-5]\d-([01]\d|2[0-4]):[0-5]\d$',
);

/// The spans of [days] the application can read (`08:00-20:00`, start before
/// end, 24:00 at most), keyed `1`…`7`; a day with none is left out.
Map<String, List<String>> normalizeSchedule(Map<String, List<String>> days) {
  int minutes(String clock) =>
      int.parse(clock.substring(0, 2)) * 60 + int.parse(clock.substring(3));
  return <String, List<String>>{
    for (final MapEntry<String, List<String>> d in days.entries)
      if (<String>[
            for (final String s in d.value)
              if (_span.hasMatch(s.replaceAll(' ', '')) &&
                  minutes(s.replaceAll(' ', '').substring(0, 5)) <
                      minutes(s.replaceAll(' ', '').substring(6)) &&
                  minutes(s.replaceAll(' ', '').substring(6)) <= 24 * 60)
                s.replaceAll(' ', ''),
          ]
          case final List<String> spans when spans.isNotEmpty)
        d.key: spans,
  };
}

// Reads the branches of a network out of the text of its pages with Claude
// (Messages API, structured output: the answer always fits [_schema]). The
// key is the secret ANTHROPIC_API_KEY of the repository.
import 'dart:convert';
import 'dart:io';

import 'clinic_network.dart';

const String model = 'claude-haiku-5-5';
const String _endpoint = 'https://api.anthropic.com/v1/messages';
const String _apiVersion = '2026-10-21';

/// The model could not read a page: no key, an error of the service, or an
/// answer cut short.
class ExtractionFailed implements Exception {
  ExtractionFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the model read on one part of the pages, before normalization.
class Extracted {
  Extracted(this.branches, this.phones, this.emails);

  final List<Branch> branches;
  final List<Contact> phones;
  final List<Contact> emails;
}

/// Sends one request and returns the decoded JSON answer. Replaced in tests.
typedef ClaudeCall = Future<Map<String, Object?>> Function(
  Map<String, Object?> body,
);

class ClaudeExtractor {
  ClaudeExtractor({ClaudeCall? call}) : _call = call ?? _post;

  final ClaudeCall _call;

  Future<Extracted> extract(NetworkSource network, String text) async {
    final Map<String, Object?> response = await _call(<String, Object?>{
      'model': model,
      'max_tokens': 32000,
      'output_config': <String, Object?>{
        'effort': 'low',
        'format': <String, Object?>{'type': 'json_schema', 'schema': _schema},
      },
      'system': _system,
      'messages': <Object?>[
        <String, Object?>{
          'role': 'user',
          'content':
              'Network: ${network.name} (${network.kind}), country '
              '${network.country}, site ${network.site}.\n'
              'Page text:\n$text',
        },
      ],
    });
    if (response['stop_reason'] != 'end_turn') {
      throw ExtractionFailed('the answer stopped: ${response['stop_reason']}');
    }
    final String answer = <String>[
      for (final Object? block in response['content']! as List<Object?>)
        if (block case {'type': 'text', 'text': final String text}) text,
    ].join();
    return parseAnswer(jsonDecode(answer) as Map<String, Object?>);
  }

  static Future<Map<String, Object?>> _post(Map<String, Object?> body) async {
    final String? key = Platform.environment['ANTHROPIC_API_KEY'];
    if (key == null || key.isEmpty) {
      throw ExtractionFailed('ANTHROPIC_API_KEY is not set');
    }
    for (int attempt = 1; ; attempt++) {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.postUrl(
          Uri.parse(_endpoint),
        );
        request.headers
          ..contentType = ContentType.json
          ..set('x-api-key', key)
          ..set('anthropic-version', _apiVersion);
        request.add(utf8.encode(jsonEncode(body)));
        final HttpClientResponse response = await request.close().timeout(
          const Duration(minutes: 10),
        );
        final String text = await response.transform(utf8.decoder).join();
        // Busy or overloaded: wait and try again.
        final bool retry =
            response.statusCode == 429 || response.statusCode >= 500;
        if (retry && attempt < 4) {
          await Future<void>.delayed(Duration(seconds: 20 * attempt));
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          throw ExtractionFailed('Claude ${response.statusCode}: $text');
        }
        return jsonDecode(text) as Map<String, Object?>;
      } finally {
        client.close(force: true);
      }
    }
  }
}

/// The answer of the model as branches, empty strings read as «none».
Extracted parseAnswer(Map<String, Object?> json) {
  String? text(Object? v) {
    final String s = ((v as String?) ?? '').trim();
    return s.isEmpty ? null : s;
  }

  List<Contact> contacts(Object? list) => <Contact>[
    for (final Object? c in list! as List<Object?>)
      if (c case {'value': final Object? v, 'label': final Object? label})
        if (text(v) case final String value) Contact(value, text(label)),
  ];

  return Extracted(
    <Branch>[
      for (final Object? b in json['branches']! as List<Object?>)
        if (b! as Map<String, Object?> case final Map<String, Object?> branch
            when text(branch['address']) != null &&
                text(branch['cityEn']) != null)
          Branch(
            city: City(
              cityKey(text(branch['cityLocal']) ?? text(branch['cityEn'])!),
              <String, String>{
                for (final String lang in <String>['uk', 'ru', 'en', 'local'])
                  if (text(
                        branch['city${lang[0].toUpperCase()}${lang.substring(1)}'],
                      )
                      case final String name)
                    lang: name,
              },
            ),
            address: text(branch['address'])!,
            postcode: text(branch['postcode']),
            phones: contacts(branch['phones']),
            emails: contacts(branch['emails']),
            schedule: <String, List<String>>{
              for (final MapEntry<String, Object?> d
                  in (branch['schedule']! as Map<String, Object?>).entries)
                d.key: (d.value! as List<Object?>).cast<String>(),
            },
            hoursNote: text(branch['hoursNote']),
          ),
    ],
    contacts(json['networkPhones']),
    contacts(json['networkEmails']),
  );
}

const String _system = '''
You read the contact pages of a medical clinic or laboratory network and write
out every branch (address) of this network that the text names. Use only what
the text says; never invent or guess an address, phone or hours. Leave a field
empty ("" or []) when the text does not give it.

For each branch:
- cityEn, cityUk, cityRu, cityLocal: the city of the branch in English
  (common English spelling: Kyiv, Warsaw, Prague, Podgorica), Ukrainian,
  Russian and the local language of the country. The city is the settlement
  the branch is in: a village or town next to a big city is a city of its
  own, not the big one.
- address: street and house number as the site writes them, in the site's
  local language, without the city, postcode or country. A building, floor or
  office goes after the house number.
- postcode: the postal code, if given.
- phones: the phones of this branch only, each in full international form
  (+380 44 123 45 67), with a short label in the site's language when the
  site gives one (reception, laboratory, mobile). Phones shared by the whole
  network go to networkPhones instead.
- emails: the e-mail addresses of this branch.
- schedule: the opening hours by weekday, "1" Monday … "7" Sunday, each a
  list of spans "HH:MM-HH:MM" in 24-hour time (two spans when there is a
  break). A day off is an empty list. Round the clock is "00:00-24:00".
  Hours written for the whole network apply to each branch that has none of
  its own. Use the hours of the branch itself, not of the call centre or of
  sample collection, unless those are the only ones given; then mention it in
  hoursNote.
- hoursNote: a short note on hours the schedule cannot hold (holidays,
  sample collection hours), in the site's language; empty if none.

networkPhones and networkEmails: contacts of the whole network (call centre,
hotline). Skip branches that the text marks as closed. Do not list the same
branch twice.''';

Map<String, Object?> _obj(Map<String, Object?> properties) => <String, Object?>{
  'type': 'object',
  'additionalProperties': false,
  'required': properties.keys.toList(),
  'properties': properties,
};

const Map<String, Object?> _string = <String, Object?>{'type': 'string'};

final Map<String, Object?> _contacts = <String, Object?>{
  'type': 'array',
  'items': _obj(<String, Object?>{'value': _string, 'label': _string}),
};

final Map<String, Object?> _schema = _obj(<String, Object?>{
  'branches': <String, Object?>{
    'type': 'array',
    'items': _obj(<String, Object?>{
      'cityEn': _string,
      'cityUk': _string,
      'cityRu': _string,
      'cityLocal': _string,
      'address': _string,
      'postcode': _string,
      'phones': _contacts,
      'emails': _contacts,
      'schedule': _obj(<String, Object?>{
        for (int day = 1; day <= 7; day++)
          '$day': <String, Object?>{'type': 'array', 'items': _string},
      }),
      'hoursNote': _string,
    }),
  },
  'networkPhones': _contacts,
  'networkEmails': _contacts,
});

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../clinics/src/claude_extractor.dart';
import '../clinics/src/clinic_network.dart';
import '../clinics/src/clinic_publication.dart';
import '../clinics/src/page_text.dart';

void main() {
  group('normalizePhone', () {
    test('national numbers get the country code', () {
      expect(normalizePhone('(044) 495-2-888', 'UA'), '+380444952888');
      expect(normalizePhone('0 800 60 55 00', 'UA'), '+380800605500');
      expect(normalizePhone('22 123 45 67', 'PL'), '+48221234567');
    });

    test('international numbers stay as they are', () {
      expect(normalizePhone('+420 253 253 252', 'CZ'), '+420253253252');
      expect(normalizePhone('00382 20 231822', 'ME'), '+38220231822');
      expect(normalizePhone('380441234567', 'UA'), '+380441234567');
    });

    test('short codes are not phone numbers', () {
      expect(normalizePhone('7550', 'UA'), isNull);
      expect(normalizePhone('', 'UA'), isNull);
    });
  });

  test('normalizeSchedule keeps only spans the application reads', () {
    expect(
      normalizeSchedule(<String, List<String>>{
        '1': <String>['08:00-20:00'],
        '2': <String>['08:00 - 13:00', '14:00-18:00'],
        '3': <String>['20:00-08:00', 'по записи'],
        '6': <String>['00:00-24:00'],
        '7': <String>[],
      }),
      <String, List<String>>{
        '1': <String>['08:00-20:00'],
        '2': <String>['08:00-13:00', '14:00-18:00'],
        '6': <String>['00:00-24:00'],
      },
    );
  });

  test('branchRef does not depend on how the street is written', () {
    expect(
      branchRef('kyiv', 'вул. Хрещатик, 1'),
      branchRef('kyiv', 'вулиця  Хрещатик 1'),
    );
    expect(
      branchRef('kyiv', 'вул. Хрещатик, 1'),
      isNot(branchRef('kyiv', 'вул. Хрещатик, 10')),
    );
    expect(
      branchRef('kyiv', 'вул. Хрещатик, 1'),
      isNot(branchRef('lviv', 'вул. Хрещатик, 1')),
    );
  });

  test('cityKey writes the English name in plain Latin letters', () {
    expect(cityKey('Kyiv'), 'kyiv');
    expect(cityKey('Białystok'), 'bialystok');
    expect(cityKey('Karlovy Vary'), 'karlovy-vary');
  });

  test('pageText writes out phone links and leaves scripts out', () {
    final String text = pageText('''
<html><head><title>x</title></head><body>
<script>var a = 1;</script>
<div>Київ, вул. Хрещатик, 1</div>
<p><a href="tel:+380441234567">044 123 45 67</a></p>
<script type="application/ld+json">{"@type":"MedicalClinic"}</script>
</body></html>''');
    expect(text, contains('Київ, вул. Хрещатик, 1'));
    expect(text, contains('[tel:+380441234567]'));
    expect(text, contains('MedicalClinic'));
    expect(text, isNot(contains('var a')));
  });

  test('chunks cut a long text at line ends', () {
    final String text = List<String>.generate(
      10,
      (int i) => 'line $i',
    ).join('\n');
    final List<String> parts = chunks(text, size: 20);
    expect(parts.length, greaterThan(1));
    expect(parts.join().split('\n').where((String l) => l.isNotEmpty), <String>[
      for (int i = 0; i < 10; i++) 'line $i',
    ]);
  });

  group('ClaudeExtractor', () {
    const NetworkSource source = NetworkSource(
      id: 'test',
      name: 'Test',
      kind: 'lab',
      country: 'UA',
      site: 'https://test.ua/',
      pages: <String>['https://test.ua/contacts'],
    );

    Map<String, Object?> answer(String stop) => <String, Object?>{
      'stop_reason': stop,
      'content': <Object?>[
        <String, Object?>{'type': 'thinking', 'thinking': ''},
        <String, Object?>{
          'type': 'text',
          'text': jsonEncode(<String, Object?>{
            'branches': <Object?>[
              <String, Object?>{
                'cityEn': 'Kyiv',
                'cityUk': 'Київ',
                'cityRu': 'Киев',
                'cityLocal': 'Київ',
                'address': 'вул. Хрещатик, 1',
                'postcode': '',
                'phones': <Object?>[
                  <String, Object?>{'value': '044 123 45 67', 'label': ''},
                ],
                'emails': <Object?>[],
                'schedule': <String, Object?>{
                  for (int d = 1; d <= 7; d++)
                    '$d': d < 6 ? <String>['08:00-20:00'] : <String>[],
                },
                'hoursNote': '',
              },
              <String, Object?>{
                'cityEn': '',
                'cityUk': '',
                'cityRu': '',
                'cityLocal': '',
                'address': 'no city',
                'postcode': '',
                'phones': <Object?>[],
                'emails': <Object?>[],
                'schedule': <String, Object?>{
                  for (int d = 1; d <= 7; d++) '$d': <String>[],
                },
                'hoursNote': '',
              },
            ],
            'networkPhones': <Object?>[],
            'networkEmails': <Object?>[],
          }),
        },
      ],
    };

    test(
      'reads the branches of the answer, a branch without a city skipped',
      () async {
        late Map<String, Object?> sent;
        final ClaudeExtractor extractor = ClaudeExtractor(
          call: (Map<String, Object?> body) async {
            sent = body;
            return answer('end_turn');
          },
        );
        final Extracted read = await extractor.extract(source, 'page text');
        expect(sent['model'], model);
        expect(
          ((sent['output_config']! as Map<String, Object?>)['format']!
              as Map<String, Object?>)['type'],
          'json_schema',
        );
        expect(read.branches, hasLength(1));
        final Branch b = read.branches.single;
        expect(b.city.key, 'kyiv');
        expect(b.city.names, <String, String>{
          'uk': 'Київ',
          'ru': 'Киев',
          'en': 'Kyiv',
          'local': 'Київ',
        });
        expect(b.postcode, isNull);
        expect(b.phones.single.label, isNull);
        expect(b.schedule['1'], <String>['08:00-20:00']);
      },
    );

    test('an answer cut short is a failure', () async {
      final ClaudeExtractor extractor = ClaudeExtractor(
        call: (_) async => answer('max_tokens'),
      );
      expect(
        extractor.extract(source, 'page text'),
        throwsA(isA<ExtractionFailed>()),
      );
    });
  });

  group('publication', () {
    late Directory root;
    late String built;
    late String published;

    setUp(() {
      root = Directory.systemTemp.createTempSync('clinics_test');
      built = '${root.path}/build';
      published = '${root.path}/public';
      Directory('$built/logos').createSync(recursive: true);
    });
    tearDown(() => root.deleteSync(recursive: true));

    void writeNetwork(String id, List<String> addresses, {String? city}) {
      final NetworkSource source = NetworkSource(
        id: id,
        name: id,
        kind: 'clinic',
        country: 'UA',
        site: 'https://$id.ua/',
        pages: const <String>[],
      );
      final Network network = Network(
        source: source,
        branches: <Branch>[
          for (final String a in addresses)
            Branch(
              city: City(city ?? 'kyiv', const <String, String>{'en': 'Kyiv'}),
              address: a,
            ),
        ],
      );
      File('$built/$id.json').writeAsStringSync(jsonEncode(network.toJson()));
    }

    Map<String, Object?> index() =>
        jsonDecode(File('$published/$indexName').readAsStringSync())
            as Map<String, Object?>;

    test('writes the networks, their logos and the index', () {
      writeNetwork('a', <String>['вул. Хрещатик, 1', 'вул. Саксаганського, 2']);
      writeNetwork('b', <String>['ul. Puławska 12'], city: 'warsaw');
      File('$built/logos/a.png').writeAsBytesSync(<int>[1, 2, 3]);

      expect(checkNetworks(built), isEmpty);
      expect(
        publishNetworks(built, published, DateTime.utc(2026, 10, 27, 6)),
        isTrue,
      );

      final Map<String, Object?> i = index();
      expect(i['format'], indexFormat);
      expect(i['built'], '2026-10-27T06:00:00Z');
      final Map<String, Object?> a =
          (i['networks']! as Map<String, Object?>)['a']!
              as Map<String, Object?>;
      expect(a['cities'], <String, Object?>{'kyiv': 2});
      expect(a['logo'], 'logos/a.png');
      expect((a['version']! as String).length, 16);
      expect(
        ((i['cities']! as Map<String, Object?>)['UA']! as Map<String, Object?>)
            .keys,
        <String>['kyiv', 'warsaw'],
      );
      expect((i['files']! as Map<String, Object?>).keys, <String>[
        'a.json',
        'b.json',
        'logos/a.png',
      ]);
    });

    test('nothing changed — nothing is written', () {
      writeNetwork('a', <String>['вул. Хрещатик, 1']);
      publishNetworks(built, published, DateTime.utc(2026, 10, 27));
      expect(
        publishNetworks(built, published, DateTime.utc(2026, 11, 27)),
        isFalse,
      );
      expect(index()['built'], '2026-10-27T00:00:00Z');
    });

    test('a network no longer built is removed with its logo', () {
      writeNetwork('a', <String>['вул. Хрещатик, 1']);
      writeNetwork('b', <String>['вул. Хрещатик, 2']);
      File('$built/logos/b.png').writeAsBytesSync(<int>[1]);
      publishNetworks(built, published, DateTime.utc(2026, 10, 27));

      File('$built/b.json').deleteSync();
      File('$built/logos/b.png').deleteSync();
      expect(
        publishNetworks(built, published, DateTime.utc(2026, 11, 27)),
        isTrue,
      );
      expect(File('$published/b.json').existsSync(), isFalse);
      expect(File('$published/logos/b.png').existsSync(), isFalse);
      expect((index()['networks']! as Map<String, Object?>).keys, <String>[
        'a',
      ]);
    });

    test('a branch named twice or a network without branches stops it', () {
      writeNetwork('a', <String>['вул. Хрещатик, 1', 'вулиця Хрещатик 1']);
      writeNetwork('b', <String>[]);
      expect(checkNetworks(built), hasLength(2));
    });

    test('nothing built stops the publication', () {
      expect(checkNetworks('${root.path}/none'), hasLength(1));
    });
  });
}

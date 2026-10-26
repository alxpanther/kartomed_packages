import 'package:test/test.dart';

import '../dictionaries/src/mixed_script.dart';

void main() {
  test('a Cyrillic word loses its Latin look-alikes', () {
    expect(fixMixedScript('Епiлепсiя'), 'Епілепсія');
    expect(
      fixMixedScript('Захворювання, спричинене ВIЛ'),
      'Захворювання, спричинене ВІЛ',
    );
    expect(
      fixMixedScript('Mенінгококовий менінгіт'),
      'Менінгококовий менінгіт',
    );
    expect(fixMixedScript('Лабораторіc'), 'Лабораторіс');
  });

  test('a Latin word loses its Cyrillic look-alikes', () {
    expect(fixMixedScript('Flоrеs Сrataegi'), 'Flores Crataegi');
    expect(fixMixedScript('Гангліозидоз-GМ2'), 'Гангліозидоз-GM2');
    expect(fixMixedScript('НD'), 'HD');
  });

  test('look-alikes only: the word, then the text around it decides', () {
    expect(
      fixMixedScript('Санека Фармасьютікалз AТ'),
      'Санека Фармасьютікалз АТ',
    );
    expect(fixMixedScript('амілолітичних MО'), 'амілолітичних МО');
    expect(
      fixMixedScript('Deoxyribonucleic acid 8-10\u0421H'),
      'Deoxyribonucleic acid 8-10CH',
    );
  });

  test('a typo with letters of both alphabets is not guessed', () {
    expect(fixMixedScript('Trigonella Foenиgraeci'), 'Trigonella Foenиgraeci');
    expect(fixMixedScript('Інсувіт нnp'), 'Інсувіт нnp');
  });

  test('Roman numerals are Latin', () {
    expect(fixMixedScript('Пролежень, стадія ІV'), 'Пролежень, стадія IV');
    expect(fixMixedScript('ІI'), 'II');
  });

  test('clean text and codes stay as they are', () {
    for (final String clean in <String>[
      'Холера, спричинена холерним вібріоном 01, biovar cholera',
      'Вітамін B12',
      'B-клітинна лімфома',
      'A00.0',
      'Type 2 diabetes mellitus',
      'Сахарный диабет 2 типа',
    ]) {
      expect(fixMixedScript(clean), clean);
    }
  });

  test('every string of a JSON tree but the stable keys', () {
    expect(
      fixMixedScriptDeep(<String, Object?>{
        'key': 'Сrataegi',
        'names': <String, Object?>{'uk': 'Iншi'},
        'extra': <String, Object?>{
          'list': <Object?>['Rаdіх', 3],
        },
      }),
      <String, Object?>{
        'key': 'Сrataegi',
        'names': <String, Object?>{'uk': 'Інші'},
        'extra': <String, Object?>{
          'list': <Object?>['Radix', 3],
        },
      },
    );
  });
}

// The page at the root of the publication (`public/index.html`).
//
// The Google Play listing names both hosts of the publication and its
// reviewers open what the listing names, so each host answers with a
// readable page instead of a 404: what the publication is, the dictionaries
// with their counts and the official sources they are built from — the same
// sources as «About → Legal information» of the application. The styles are
// a file of their own: the security policy of foleks.com
// (`style-src 'self'`) drops a <style> written inside the page.
import 'dart:io';

import 'publication.dart';

const Map<String, String> _titles = <String, String>{
  'diagnoses': 'Diagnoses',
  'medicines': 'Medicines',
  'symptoms': 'Symptoms',
  'specialties': 'Doctor specialties',
  'vaccines': 'Vaccines',
  'allergens': 'Allergens',
};

const String _sources = '''
<li>Diagnoses, Ukraine — national classification of diseases NK 025:2021,
  State Expert Center of the Ministry of Health of Ukraine
  (<a href="https://www.dec.gov.ua/">dec.gov.ua</a>)</li>
<li>Diagnoses, Russia — ICD-10 classification of diseases, reference data of
  the Russian Ministry of Health, OID 1.2.643.5.1.13.13.11.1005
  (<a href="https://nsi.rosminzdrav.ru/">nsi.rosminzdrav.ru</a>)</li>
<li>Diagnoses, USA — English names of diagnoses, ICD-10-CM classification
  (<a href="https://www.cdc.gov/nchs/icd/icd-10-cm/">cdc.gov</a>)</li>
<li>Medicines — State Register of Medicinal Products of Ukraine, open data
  (<a href="https://data.gov.ua/dataset/fded13b8-4e2c-4c48-bf14-65d0e3106463">data.gov.ua</a>)</li>
<li>Symptoms, doctor specialties, vaccines and allergens — the developer's
  own lists.</li>
''';

const String _styles = '''
body { margin: 0; font: 16px/1.5 system-ui, sans-serif; color: #1c2321;
  background: #f7f8f7; }
main { max-width: 720px; margin: 0 auto; padding: 32px 16px; }
h1 { font-size: 28px; margin: 0 0 16px; color: #1f8a78; }
h2 { font-size: 20px; margin: 32px 0 8px; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #dde3e1; }
td.n { text-align: right; font-variant-numeric: tabular-nums; }
code { font-size: 14px; }
a { color: #1f8a78; }
.note { color: #5b6764; font-size: 14px; }
@media (prefers-color-scheme: dark) {
  body { color: #e6ebe9; background: #141917; }
  th, td { border-color: #2d3633; }
  h1, a { color: #4cc2ad; }
  .note { color: #9aa7a3; }
}
''';

/// Writes `index.html` and `index.css` into [root], the folder above
/// [publicDir], from the published [dictionaries] and the date [built].
void writePage(
  String root,
  Map<String, FolderDictionary> dictionaries,
  String built,
) {
  final StringBuffer rows = StringBuffer();
  for (final String name in _titles.keys) {
    final FolderDictionary? d = dictionaries[name];
    if (d != null) {
      rows.writeln(
        '<tr><td>${_titles[name]}</td><td class="n">${d.count}</td>'
        '<td><code>${d.version}</code></td></tr>',
      );
    }
  }
  File('$root/index.html').writeAsStringSync('''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Kartomed dictionaries</title>
<link rel="stylesheet" href="index.css">
</head>
<body>
<main>
<h1>Kartomed dictionaries</h1>
<p>The reference dictionaries the Kartomed app
(<a href="https://foleks.com/kartomed">foleks.com/kartomed</a>) downloads
to keep them current between its releases. The app only downloads these
files, without an account and without sending anything about its user.</p>
<p>Kartomed is an unofficial app: it does not represent any government body
and is not affiliated with one.</p>
<h2>Dictionaries</h2>
<table>
<tr><th>Dictionary</th><th>Entries</th><th>Version</th></tr>
$rows</table>
<p class="note">Built $built ·
<a href="dictionaries/manifest.json">manifest.json</a></p>
<h2>Sources</h2>
<ul>
$_sources</ul>
<p class="note">The same files: <a href="https://kartomed.foleks.com/">kartomed.foleks.com</a>
and the copy <a href="https://alxpanther.github.io/kartomed_packages/">alxpanther.github.io/kartomed_packages</a>.</p>
</main>
</body>
</html>
''');
  File('$root/index.css').writeAsStringSync(_styles);
}

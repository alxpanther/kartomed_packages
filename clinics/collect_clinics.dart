// Collects the clinic networks of clinics/sources.json from their sites
// into build/packages/, checks them and publishes what changed into
// public/packages/ (see src/clinic_publication.dart).
//
//   dart run clinics/collect_clinics.dart [--only=id,id] [--dry-run]
//
// --only     collects only these networks; the others keep their
//            published files.
// --dry-run  only downloads the pages and writes their text into
//            tmp/clinics/<id>.txt: no model, no publication. For checking
//            what a page gives before adding it.
//
// A network that cannot be read (site down, the model failed, far fewer
// branches than last month) keeps its published files and becomes a line
// of build/warnings.txt; one network never stops the others.
import 'dart:convert';
import 'dart:io';

import '../dictionaries/src/page.dart';
import 'src/claude_extractor.dart';
import 'src/clinic_network.dart';
import 'src/clinic_publication.dart';
import 'src/favicon.dart';
import 'src/page_text.dart';

const String _warningsFile = 'build/warnings.txt';
const String _errorsFile = 'build/errors.txt';

/// A saved page older than this is reported: its network may have changed.
const Duration _savedAge = Duration(days: 90);

List<int>? _savedIcon(SavedPage saved) {
  final File file = File(saved.icon ?? '');
  return saved.icon == null || !file.existsSync()
      ? null
      : prepareIcon(file.readAsBytesSync())?.png;
}

/// Less text than this is a page whose list a script draws: Chrome renders
/// it.
const int _thinPage = 1500;

Future<void> main(List<String> args) async {
  final bool dryRun = args.contains('--dry-run');
  final Set<String>? only = args
      .where((String a) => a.startsWith('--only='))
      .map((String a) => a.substring(7).split(',').toSet())
      .firstOrNull;
  final List<NetworkSource> sources = <NetworkSource>[
    for (final Object? s in jsonDecode(
      File('clinics/sources.json').readAsStringSync(),
    ) as List<Object?>)
      NetworkSource.fromJson(s! as Map<String, Object?>),
  ];
  Directory('$clinicsBuildDir/logos').createSync(recursive: true);
  final List<String> warnings = <String>[];
  final ClaudeExtractor extractor = ClaudeExtractor();

  for (final NetworkSource source in sources) {
    if (only != null && !only.contains(source.id)) {
      _keepPublished(source.id);
      continue;
    }
    stdout.writeln('Clinics: ${source.id}');
    try {
      final String text = await _textOf(source);
      if (dryRun) {
        Directory('tmp/clinics').createSync(recursive: true);
        File('tmp/clinics/${source.id}.txt').writeAsStringSync(text);
        stdout.writeln('  ${text.length} characters of text');
        continue;
      }
      final Network network = await _read(source, text, extractor);
      final int before = _publishedBranches(source.id);
      if (network.branches.length < before * (1 - maxBranchDrop)) {
        throw ExtractionFailed(
          '${network.branches.length} branches, published $before',
        );
      }
      File('$clinicsBuildDir/${source.id}.json').writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert(network.toJson()),
      );
      final List<int>? icon = source.saved == null
          ? await fetchIcon(source.site)
          : _savedIcon(source.saved!);
      if (source.saved case final SavedPage saved
          when DateTime.now().difference(saved.date) > _savedAge) {
        warnings.add(
          '${source.id}: the saved page is of ${saved.date.toIso8601String().split('T').first} '
          '— open ${source.pages.first} and save it again',
        );
      }
      if (icon != null) {
        File('$clinicsBuildDir/logos/${source.id}.png').writeAsBytesSync(icon);
      } else {
        _keepPublishedLogo(source.id);
      }
      stdout.writeln(
        '  ${network.branches.length} branches'
        '${icon == null ? ', no icon' : ''}',
      );
    } on Object catch (error) {
      warnings.add('${source.id}: $error — the previous data is kept');
      stdout.writeln('  failed: $error');
      _keepPublished(source.id);
    }
  }
  if (dryRun) {
    return;
  }
  if (warnings.isNotEmpty) {
    File(_warningsFile).writeAsStringSync('${warnings.join('\n')}\n');
  }
  final List<String> problems = checkNetworks(clinicsBuildDir);
  if (problems.isNotEmpty) {
    File(_errorsFile).writeAsStringSync('${problems.join('\n')}\n');
    stderr.writeln('Clinics: not published\n${problems.join('\n')}');
    exit(1);
  }
  final bool changed = publishNetworks(
    clinicsBuildDir,
    clinicsPublicDir,
    DateTime.now(),
  );
  if (changed) {
    writePage(Directory(clinicsPublicDir).parent.path);
  }
  stdout.writeln(changed ? 'Clinics: published' : 'Clinics: nothing changed');
}

/// The text of every page of [source], one after another; the saved page
/// for a site closed to programs.
Future<String> _textOf(NetworkSource source) async {
  if (source.saved != null) {
    // «Save page as → Web page, complete» of a browser, or plain text.
    final String saved = File(source.saved!.text).readAsStringSync();
    return source.saved!.text.endsWith('.html') ? pageText(saved) : saved;
  }
  final List<String> parts = <String>[];
  for (final String page in source.pages) {
    final Uri url = Uri.parse(page);
    String? text;
    if (!source.render) {
      final String? body = await downloadPage(url);
      text = body == null ? null : pageText(body);
    }
    if (text == null || text.length < _thinPage) {
      final String? rendered = await renderPage(url);
      if (rendered != null) {
        text = pageText(rendered);
      }
    }
    if (text == null || text.isEmpty) {
      throw ExtractionFailed('$page gave no page');
    }
    parts.add(text);
  }
  return parts.join('\n\n');
}

Future<Network> _read(
  NetworkSource source,
  String text,
  ClaudeExtractor extractor,
) async {
  final Map<String, Branch> branches = <String, Branch>{};
  final List<Contact> phones = <Contact>[];
  final List<Contact> emails = <Contact>[];
  for (final String part in chunks(text)) {
    final Extracted read = await extractor.extract(source, part);
    phones.addAll(read.phones);
    emails.addAll(read.emails);
    for (final Branch b in read.branches) {
      final Branch clean = _clean(b, source.country);
      // A branch cut in two by the chunks, or named twice on the page.
      final Branch? had = branches[clean.ref];
      branches[clean.ref] = had == null ? clean : _join(had, clean);
    }
  }
  if (branches.isEmpty) {
    throw ExtractionFailed('no branches found');
  }
  return Network(
    source: source,
    branches: branches.values.toList(),
    phones: _phones(phones, source.country),
    emails: _emails(emails),
  );
}

Branch _clean(Branch b, String country) => Branch(
  city: b.city,
  address: b.address,
  postcode: b.postcode,
  phones: _phones(b.phones, country),
  emails: _emails(b.emails),
  schedule: normalizeSchedule(b.schedule),
  hoursNote: b.hoursNote,
);

Branch _join(Branch a, Branch b) => Branch(
  city: a.city,
  address: a.address,
  postcode: a.postcode ?? b.postcode,
  phones: _phones(<Contact>[...a.phones, ...b.phones], ''),
  emails: _emails(<Contact>[...a.emails, ...b.emails]),
  schedule: a.schedule.isNotEmpty ? a.schedule : b.schedule,
  hoursNote: a.hoursNote ?? b.hoursNote,
);

/// Phones in the international form, each number once.
List<Contact> _phones(List<Contact> list, String country) {
  final Map<String, Contact> out = <String, Contact>{};
  for (final Contact c in list) {
    final String? phone = normalizePhone(c.value, country);
    if (phone != null && !out.containsKey(phone)) {
      out[phone] = Contact(phone, c.label);
    }
  }
  return out.values.toList();
}

List<Contact> _emails(List<Contact> list) {
  final Map<String, Contact> out = <String, Contact>{};
  for (final Contact c in list) {
    final String email = c.value.trim().toLowerCase();
    if (RegExp(r'^[^@\s]+@[^@\s]+\.[a-z]{2,}$').hasMatch(email)) {
      out.putIfAbsent(email, () => Contact(email, c.label));
    }
  }
  return out.values.toList();
}

int _publishedBranches(String id) {
  final File file = File('$clinicsPublicDir/$id.json');
  if (!file.existsSync()) {
    return 0;
  }
  final Map<String, Object?> json =
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  return (json['branches']! as List<Object?>).length;
}

/// Copies the published files of [id] into the build, so a network that
/// was not collected this time stays published as it was.
void _keepPublished(String id) {
  final File published = File('$clinicsPublicDir/$id.json');
  if (published.existsSync()) {
    published.copySync('$clinicsBuildDir/$id.json');
  }
  _keepPublishedLogo(id);
}

void _keepPublishedLogo(String id) {
  final File logo = File('$clinicsPublicDir/logos/$id.png');
  if (logo.existsSync()) {
    logo.copySync('$clinicsBuildDir/logos/$id.png');
  }
}

// The pages of a clinic network as plain text for the model: downloaded as
// they are, or rendered by Chrome without a window when the addresses are
// drawn by a script of the page («render» in sources.json).
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

const String userAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0 Safari/537.36';

/// The HTML of [url]; null when the site does not answer with a page.
Future<String?> downloadPage(Uri url) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..userAgent = userAgent;
  try {
    final HttpClientRequest request = await client.getUrl(url);
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'uk,ru;q=0.8,en;q=0.6',
    );
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 60),
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    return await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// The HTML of [url] after its scripts ran, from Chrome without a window.
/// The ubuntu runners of GitHub Actions have `google-chrome` installed.
Future<String?> renderPage(Uri url) async {
  final String chrome = Platform.environment['CHROME'] ?? 'google-chrome';
  try {
    final ProcessResult result = await Process.run(chrome, <String>[
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--user-agent=$userAgent',
      // Lets the scripts load the list before the page is taken.
      '--virtual-time-budget=20000',
      '--dump-dom',
      url.toString(),
    ], stdoutEncoding: utf8).timeout(const Duration(minutes: 2));
    final String out = result.stdout as String;
    return result.exitCode == 0 && out.isNotEmpty ? out : null;
  } on Object {
    return null;
  }
}

const Set<String> _dropped = <String>{
  'script',
  'style',
  'noscript',
  'svg',
  'template',
  'iframe',
  'head',
};

const Set<String> _blocks = <String>{
  'p',
  'div',
  'li',
  'tr',
  'br',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'section',
  'article',
  'address',
  'table',
  'ul',
  'ol',
  'dt',
  'dd',
  'header',
  'footer',
  'option',
};

/// The readable text of [page]: one line per block, phone and mail links
/// written out (`[tel:+380…]`), the structured data of the page (JSON-LD)
/// kept, scripts and styles left out.
String pageText(String page) {
  final Document document = html.parse(page);
  final StringBuffer out = StringBuffer();
  for (final Element ld in document.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    out.writeln(ld.text.trim());
  }
  for (final Element a in document.querySelectorAll('a[href]')) {
    final String href = a.attributes['href']!.trim();
    if (href.startsWith('tel:') || href.startsWith('mailto:')) {
      a.append(Text(' [$href] '));
    }
  }
  void walk(Node node) {
    if (node is Text) {
      out.write(node.data.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    if (node is Element && _dropped.contains(node.localName)) {
      return;
    }
    final bool block = node is Element && _blocks.contains(node.localName);
    if (block) {
      out.write('\n');
    }
    node.nodes.forEach(walk);
    if (block) {
      out.write('\n');
    }
  }

  if (document.body != null) {
    walk(document.body!);
  }
  return out
      .toString()
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .join('\n');
}

/// [text] cut at line ends into parts of at most [size] characters, so a
/// long list of addresses goes to the model in several requests.
List<String> chunks(String text, {int size = 60000}) {
  final List<String> out = <String>[];
  final StringBuffer part = StringBuffer();
  for (final String line in text.split('\n')) {
    if (part.length + line.length + 1 > size && part.isNotEmpty) {
      out.add(part.toString());
      part.clear();
    }
    part.writeln(line);
  }
  if (part.isNotEmpty) {
    out.add(part.toString());
  }
  return out;
}

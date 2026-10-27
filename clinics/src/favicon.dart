// The icon of a network's site, as the application's FaviconFetcher takes
// it: the icons the home page links to (`icon`, `apple-touch-icon`, the web
// app manifest), `/favicon.ico` as the fallback; the largest raster icon of
// at least 32 px wins and is scaled down to 256 px, saved as PNG.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:image/image.dart' as img;

import 'page_text.dart';

const int minIconSize = 32;
const int maxIconSize = 256;

/// PNG bytes of the icon of [site], or null when it has none.
Future<Uint8List?> fetchIcon(String site) async {
  final Uri home = Uri.parse(site);
  final List<({Uri uri, int size})> candidates = <({Uri uri, int size})>[];
  final ({Uri uri, Uint8List body})? page = await _get(home);
  if (page != null) {
    final Document document = html.parse(
      utf8.decode(page.body, allowMalformed: true),
    );
    for (final Element link in document.querySelectorAll('link[href]')) {
      final String rel = (link.attributes['rel'] ?? '').toLowerCase();
      final String href = link.attributes['href']!;
      final Uri? uri = Uri.tryParse(href.trim());
      if (uri == null) {
        continue;
      }
      if (rel.split(RegExp(r'\s+')).contains('manifest')) {
        candidates.addAll(await _manifestIcons(page.uri.resolveUri(uri)));
      } else if (rel.contains('icon') &&
          !rel.contains('mask-icon') &&
          !_isSvg(href, link.attributes['type'])) {
        int size = _largestSize(link.attributes['sizes']);
        if (size == 0 && rel.contains('apple-touch-icon')) {
          size = 180;
        }
        candidates.add((uri: page.uri.resolveUri(uri), size: size));
      }
    }
  }
  candidates.add((uri: (page?.uri ?? home).resolve('/favicon.ico'), size: 0));

  final Set<Uri> seen = <Uri>{};
  final List<({Uri uri, int size})> ordered =
      candidates.where((c) => seen.add(c.uri)).toList()
        ..sort((a, b) => b.size - a.size);
  Uint8List? best;
  int bestSize = 0;
  for (final ({Uri uri, int size}) c in ordered.take(6)) {
    final ({Uri uri, Uint8List body})? file = await _get(c.uri);
    final ({Uint8List png, int size})? icon = file == null
        ? null
        : prepareIcon(file.body);
    if (icon != null && icon.size > bestSize) {
      best = icon.png;
      bestSize = icon.size;
      if (bestSize >= maxIconSize) {
        break;
      }
    }
  }
  return bestSize >= minIconSize ? best : null;
}

Future<List<({Uri uri, int size})>> _manifestIcons(Uri manifest) async {
  final ({Uri uri, Uint8List body})? file = await _get(manifest);
  try {
    final Object? data = file == null
        ? null
        : jsonDecode(utf8.decode(file.body, allowMalformed: true));
    if (data is! Map<String, Object?> || data['icons'] is! List<Object?>) {
      return const <({Uri uri, int size})>[];
    }
    return <({Uri uri, int size})>[
      for (final Object? icon in data['icons']! as List<Object?>)
        if (icon is Map<String, Object?> &&
            icon['src'] is String &&
            !_isSvg(icon['src']! as String, icon['type'] as String?))
          (
            uri: file!.uri.resolve(icon['src']! as String),
            size: _largestSize(icon['sizes'] as String?),
          ),
    ];
  } on FormatException {
    return const <({Uri uri, int size})>[];
  }
}

bool _isSvg(String href, String? type) =>
    (type ?? '').toLowerCase().contains('svg') ||
    Uri.tryParse(href)?.path.toLowerCase().endsWith('.svg') == true;

/// «16x16 32x32» → 32; «any» or nothing → 0.
int _largestSize(String? sizes) {
  int largest = 0;
  for (final Match m in RegExp(
    r'(\d+)\s*[xX×]\s*(\d+)',
  ).allMatches(sizes ?? '')) {
    final int side = int.parse(m[1]!);
    if (side > largest) {
      largest = side;
    }
  }
  return largest;
}

/// The body of [uri] and the address it ended at; null on any failure or
/// a body over 2 MB.
Future<({Uri uri, Uint8List body})?> _get(Uri uri) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = userAgent;
  try {
    final HttpClientRequest request = await client.getUrl(uri);
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 30),
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final BytesBuilder body = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      body.add(chunk);
      if (body.length > 2 * 1024 * 1024) {
        return null;
      }
    }
    final Uri end = response.redirects.isEmpty
        ? uri
        : uri.resolveUri(response.redirects.last.location);
    return (uri: end, body: body.takeBytes());
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Decodes an icon (PNG, ICO — its largest picture —, JPEG, WebP, GIF, BMP)
/// and scales it down to [maxIconSize]; null for anything else.
({Uint8List png, int size})? prepareIcon(Uint8List bytes) {
  img.Image? image;
  try {
    final img.Decoder? decoder = img.findDecoderForData(bytes);
    image = decoder is img.IcoDecoder
        ? decoder.decodeImageLargest(bytes)
        : decoder?.decode(bytes, frame: 0);
  } on Object {
    return null;
  }
  if (image == null) {
    return null;
  }
  final int shorter = image.width < image.height ? image.width : image.height;
  if (image.width > maxIconSize || image.height > maxIconSize) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: maxIconSize,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: maxIconSize,
            interpolation: img.Interpolation.average,
          );
  }
  return (png: img.encodePng(image), size: shorter);
}

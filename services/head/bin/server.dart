import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:soundstage_head/head.dart';

// Cloud Run service behind the Hosting rewrite `/@**` (firebase.json,
// infra/terraform/head.tf). For each request it serves the app shell from
// Hosting with the story's head; anything that fails serves the plain
// shell, so the player always loads. Responses are cached by the Hosting
// CDN (s-maxage), which keeps invocations, and cost, low.

final String _site =
    Platform.environment['SITE_ORIGIN'] ?? 'https://project-soundstage.web.app';
final String _project =
    Platform.environment['PROJECT_ID'] ?? 'project-soundstage';

final HttpClient _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 5);

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('soundstage-head on :$port');
  await for (final request in server) {
    unawaited(_handle(request));
  }
}

Future<void> _handle(HttpRequest request) async {
  final res = request.response;
  try {
    if (request.method != 'GET' && request.method != 'HEAD') {
      res.statusCode = HttpStatus.methodNotAllowed;
      return;
    }
    if (request.uri.path == '/sitemap.xml') {
      final body = sitemapXml(_site, [
        for (final c in ['drafts', 'publications', 'issues'])
          ...await _published(c),
      ]);
      res
        ..headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        )
        ..headers.set('cache-control', 'public, max-age=3600, s-maxage=3600');
      if (request.method == 'GET') res.write(body);
      return;
    }
    final shell = await _shell();
    final route = HeadRoute.parse(request.uri.path);
    final doc = route == null ? null : await _document(route.docPath);
    res
      ..statusCode = doc == null ? HttpStatus.notFound : HttpStatus.ok
      ..headers.contentType = ContentType.html
      // A missing page may be published soon: cache it briefly.
      ..headers.set(
        'cache-control',
        'public, max-age=60, s-maxage=${doc == null ? 60 : 600}',
      )
      ..headers.set('cross-origin-opener-policy', 'same-origin')
      ..headers.set('cross-origin-embedder-policy', 'credentialless');
    if (request.method == 'GET') {
      res.write(
        route == null || doc == null
            ? shell
            : injectHead(shell, headFor(route, doc, '$_site${route.path}')),
      );
    }
  } on Object catch (e) {
    stderr.writeln('soundstage-head: ${request.uri.path}: $e');
    // The plain shell when we have it; the app shows its own errors.
    final shell = _shellCache;
    res
      ..statusCode = shell == null ? HttpStatus.badGateway : HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set('cache-control', 'no-store');
    if (shell != null && request.method == 'GET') res.write(shell);
  } finally {
    await res.close();
  }
}

String? _shellCache;
DateTime _shellAt = DateTime(0);

/// The app's index.html from Hosting, refreshed every 5 minutes (a Hosting
/// deploy changes it).
Future<String> _shell() async {
  final cached = _shellCache;
  if (cached != null &&
      DateTime.now().difference(_shellAt) < const Duration(minutes: 5)) {
    return cached;
  }
  final (status, body) = await _send('GET', Uri.parse('$_site/index.html'));
  if (status != HttpStatus.ok) throw HttpException('index.html: $status');
  _shellAt = DateTime.now();
  return _shellCache = body;
}

String get _documents =>
    'https://firestore.googleapis.com/v1/projects/$_project/databases/'
    '(default)/documents';

/// The Firestore document at [path] (REST), or null.
Future<Map<String, Object?>?> _document(String path) async {
  final (status, body) = await _send(
    'GET',
    Uri.parse('$_documents/$path'),
    bearer: await _token(),
  );
  if (status == HttpStatus.notFound) return null;
  if (status != HttpStatus.ok) throw HttpException('firestore: $status');
  return jsonDecode(body) as Map<String, Object?>;
}

/// Every published page in collection group [collectionId] (`drafts`,
/// `publications` or `issues`; at most 5,000).
Future<List<SitemapEntry>> _published(String collectionId) async {
  final (status, body) = await _send(
    'POST',
    Uri.parse('$_documents:runQuery'),
    bearer: await _token(),
    body: jsonEncode({
      'structuredQuery': {
        'from': [
          {'collectionId': collectionId, 'allDescendants': true},
        ],
        'select': {
          'fields': [
            {'fieldPath': 'updatedAt'},
          ],
        },
        'limit': 5000,
      },
    }),
  );
  if (status != HttpStatus.ok) throw HttpException('firestore: $status');
  return sitemapEntries(jsonDecode(body));
}

String? _tokenValue;
DateTime _tokenExpiry = DateTime(0);

/// An access token for the service's account, from the metadata server.
Future<String> _token() async {
  final cached = _tokenValue;
  if (cached != null && DateTime.now().isBefore(_tokenExpiry)) return cached;
  final (status, body) = await _send(
    'GET',
    Uri.parse(
      'http://metadata.google.internal/computeMetadata/v1/instance/'
      'service-accounts/default/token',
    ),
    headers: {'metadata-flavor': 'Google'},
  );
  if (status != HttpStatus.ok) throw HttpException('token: $status');
  final json = jsonDecode(body) as Map<String, Object?>;
  final expiresIn = (json['expires_in']! as num).toInt();
  _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
  return _tokenValue = json['access_token']! as String;
}

Future<(int, String)> _send(
  String method,
  Uri uri, {
  String? bearer,
  String? body,
  Map<String, String> headers = const {},
}) async {
  final req = await _http
      .openUrl(method, uri)
      .timeout(const Duration(seconds: 5));
  if (bearer != null) req.headers.set('authorization', 'Bearer $bearer');
  headers.forEach(req.headers.set);
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(body));
  }
  final res = await req.close().timeout(const Duration(seconds: 5));
  return (res.statusCode, await res.transform(utf8.decoder).join());
}

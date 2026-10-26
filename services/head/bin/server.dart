import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:soundstage_head/head.dart';

// Cloud Run service behind the Hosting rewrite `/s/**` (firebase.json,
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
    final shell = await _shell();
    final slug = slugFromPath(request.uri.path);
    var status = HttpStatus.ok;
    var body = shell;
    var maxAge = 60;
    var sMaxAge = 600;
    if (slug == null) {
      status = HttpStatus.notFound;
    } else {
      final doc = await _published(slug);
      if (doc == null) {
        status = HttpStatus.notFound;
        sMaxAge = 60; // a story may be published here soon
      } else {
        body = injectHead(
          shell,
          StoryHead.fromFirestore(doc, '$_site/s/$slug'),
        );
      }
    }
    res
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.set(
        'cache-control',
        'public, max-age=$maxAge, s-maxage=$sMaxAge',
      )
      ..headers.set('cross-origin-opener-policy', 'same-origin')
      ..headers.set('cross-origin-embedder-policy', 'credentialless');
    if (request.method == 'GET') res.write(body);
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
  final (status, body) = await _get(Uri.parse('$_site/index.html'));
  if (status != HttpStatus.ok) throw HttpException('index.html: $status');
  _shellAt = DateTime.now();
  return _shellCache = body;
}

/// The Firestore document `published/{slug}` (REST), or null.
Future<Map<String, Object?>?> _published(String slug) async {
  final (status, body) = await _get(
    Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$_project/databases/'
      '(default)/documents/published/$slug',
    ),
    bearer: await _token(),
  );
  if (status == HttpStatus.notFound) return null;
  if (status != HttpStatus.ok) throw HttpException('firestore: $status');
  return jsonDecode(body) as Map<String, Object?>;
}

String? _tokenValue;
DateTime _tokenExpiry = DateTime(0);

/// An access token for the service's account, from the metadata server.
Future<String> _token() async {
  final cached = _tokenValue;
  if (cached != null && DateTime.now().isBefore(_tokenExpiry)) return cached;
  final (status, body) = await _get(
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

Future<(int, String)> _get(
  Uri uri, {
  String? bearer,
  Map<String, String> headers = const {},
}) async {
  final req = await _http.getUrl(uri).timeout(const Duration(seconds: 5));
  if (bearer != null) req.headers.set('authorization', 'Bearer $bearer');
  headers.forEach(req.headers.set);
  final res = await req.close().timeout(const Duration(seconds: 5));
  final body = await res.transform(utf8.decoder).join();
  return (res.statusCode, body);
}

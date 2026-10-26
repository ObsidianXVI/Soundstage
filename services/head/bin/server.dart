import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:soundstage_head/gate.dart';
import 'package:soundstage_head/head.dart';

// Cloud Run service behind the Hosting rewrite `/@**` (firebase.json,
// infra/terraform/head.tf). For each request it serves the app shell from
// Hosting with the story's head; anything that fails serves the plain
// shell, so the player always loads. Responses are cached by the Hosting
// CDN (s-maxage), which keeps invocations, and cost, low.
//
// It is also the reader's gate (m7.md T7.4), called directly by the app
// with CORS: `/gate/open`, `/gate/secret` and `/gate/file/<path>`.

final String _site =
    Platform.environment['SITE_ORIGIN'] ?? 'https://project-soundstage.web.app';
final String _project =
    Platform.environment['PROJECT_ID'] ?? 'project-soundstage';

final Map<String, String> _env = Platform.environment;
final String _webApiKey = _env['FIREBASE_API_KEY'] ?? '';
final String _bucket = _env['MEDIA_BUCKET'] ?? 'project-soundstage-media';
final List<int> _gateKey = utf8.encode(_env['GATE_KEY'] ?? '');
final List<String> _origins =
    (_env['ALLOWED_ORIGINS'] ?? 'https://project-soundstage.web.app').split(
      ',',
    );

// Local runs against the Firebase emulators (never set on Cloud Run).
final String? _firestoreEmulator = _env['FIRESTORE_EMULATOR_HOST'];
final String? _authEmulator = _env['FIREBASE_AUTH_EMULATOR_HOST'];
final String? _storageEmulator = _env['STORAGE_EMULATOR_HOST'];

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
  if (request.uri.path.startsWith('/gate/')) return _gate(request);
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
    '${_firestoreEmulator == null ? 'https://firestore.googleapis.com' : 'http://$_firestoreEmulator'}'
    '/v1/projects/$_project/databases/(default)/documents';

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
            {'fieldPath': 'audience'},
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
  if (_firestoreEmulator != null) return 'owner'; // the emulators' admin
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

// ---- The gate (m7.md T7.4) ---------------------------------------------

Future<void> _gate(HttpRequest req) async {
  final res = req.response;
  final path = req.uri.path;
  final origin = req.headers.value('origin');
  final isFile = path.startsWith('/gate/file/');
  if (isFile) {
    // The pass in the URL is the credential; any page may embed the file.
    res.headers.set('access-control-allow-origin', '*');
  } else if (_originAllowed(origin)) {
    res.headers
      ..set('access-control-allow-origin', origin!)
      ..set('vary', 'Origin')
      ..set('access-control-allow-headers', 'authorization, content-type')
      ..set('access-control-allow-methods', 'GET, POST, PUT')
      ..set('access-control-max-age', '3600');
  }
  try {
    if (req.method == 'OPTIONS') {
      res.statusCode = HttpStatus.noContent;
      return;
    }
    if (_gateKey.length < 32) throw StateError('GATE_KEY is not set');
    if (isFile && (req.method == 'GET' || req.method == 'HEAD')) {
      return await _gateFile(req, path.substring('/gate/file/'.length));
    }
    if (path == '/gate/open' && req.method == 'POST') return await _open(req);
    if (path == '/gate/secret' && req.method == 'PUT') {
      return await _secret(req);
    }
    _gateError(res, HttpStatus.notFound, 'Not found.');
  } on Object catch (e) {
    stderr.writeln('soundstage-head gate: ${req.method} $path: $e');
    try {
      _gateError(res, HttpStatus.badGateway, 'The gate failed.');
    } on Object {
      // headers already sent (a stream broke midway)
    }
  } finally {
    await res.close();
  }
}

bool _originAllowed(String? origin) {
  if (origin == null) return false;
  if (_origins.contains(origin)) return true;
  final uri = Uri.tryParse(origin);
  return uri != null &&
      (uri.host == 'localhost' || uri.host == '127.0.0.1') &&
      (uri.scheme == 'http' || uri.scheme == 'https');
}

void _gateJson(HttpResponse res, int status, Object body) {
  res
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..headers.set('cache-control', 'no-store')
    ..write(jsonEncode(body));
}

void _gateError(
  HttpResponse res,
  int status,
  String message, {
  String? audience,
}) => _gateJson(res, status, {
  'error': {'message': message},
  'audience': ?audience,
});

Future<Map<String, Object?>?> _jsonBody(HttpRequest req) async {
  final bytes = <int>[];
  await for (final chunk in req) {
    bytes.addAll(chunk);
    if (bytes.length > 256 * 1024) return null;
  }
  if (bytes.isEmpty) return const {};
  try {
    final v = jsonDecode(utf8.decode(bytes));
    return v is Map ? v.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

typedef _Account = ({String uid, String? email, bool verified});

/// The account of the request's `Bearer <Firebase ID token>`, or null.
Future<_Account?> _accountOf(HttpRequest req) async {
  final auth = req.headers.value('authorization');
  if (auth == null || !auth.startsWith('Bearer ')) return null;
  final (status, body) = await _send(
    'POST',
    Uri.parse(
      '${_authEmulator == null ? 'https://' : 'http://$_authEmulator/'}'
      'identitytoolkit.googleapis.com/v1/accounts:lookup?key=$_webApiKey',
    ),
    body: jsonEncode({'idToken': auth.substring(7)}),
  );
  if (status != HttpStatus.ok) return null;
  final users = (jsonDecode(body) as Map<String, Object?>)['users'];
  if (users is! List || users.isEmpty) return null;
  final user = users.first as Map;
  final uid = user['localId'];
  if (uid is! String) return null;
  return (
    uid: uid,
    email: (user['email'] as String?)?.toLowerCase(),
    verified: user['emailVerified'] == true,
  );
}

/// Recent password attempts per client and record (a minute's window).
final Map<String, List<DateTime>> _attempts = {};

bool _tooMany(HttpRequest req, String doc) {
  final ip =
      req.headers.value('x-forwarded-for')?.split(',').first.trim() ??
      req.connectionInfo?.remoteAddress.address ??
      '';
  final now = DateTime.now();
  if (_attempts.length > 5000) _attempts.clear();
  final list = _attempts.putIfAbsent('$ip $doc', () => [])
    ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1))
    ..add(now);
  return list.length > 10;
}

/// `POST /gate/open` {doc, password?}: the record and a pass when the
/// reader may open it (the owner always may).
Future<void> _open(HttpRequest req) async {
  final res = req.response;
  final body = await _jsonBody(req);
  final doc = body?['doc'];
  if (doc is! String || routeOfDocPath(doc) == null) {
    return _gateError(res, HttpStatus.badRequest, 'Unknown page.');
  }
  final typed = await _document(doc);
  if (typed == null) return _gateError(res, HttpStatus.notFound, 'Not found.');
  final record = plainFields(typed);
  final audience = (record['audience'] as String?) ?? 'public';
  Future<void> pass({bool owner = false}) async {
    final folder = gatedFolderOf(record);
    _gateJson(res, HttpStatus.ok, {
      // Readers get the live version only.
      'record': owner ? record : ({...record}..remove('versions')),
      'token': folder == null
          ? ''
          : signPass(_gateKey, folder, DateTime.now().add(kPassLifetime)),
    });
  }

  if (!isGatedAudience(audience)) return pass();
  final account = await _accountOf(req);
  if (account != null && account.uid == record['ownerId']) {
    return pass(owner: true);
  }
  final secret = await _document('gates/${gateIdFor(doc)}');
  final fields = secret == null
      ? const <String, Object?>{}
      : plainFields(secret);
  if (audience == 'password') {
    final password = body?['password'];
    if (password is! String || password.isEmpty) {
      return _gateError(
        res,
        HttpStatus.unauthorized,
        'Enter the password.',
        audience: audience,
      );
    }
    if (_tooMany(req, doc)) {
      return _gateError(
        res,
        HttpStatus.tooManyRequests,
        'Too many tries. Wait a minute.',
        audience: audience,
      );
    }
    if (passwordMatches(password, fields)) return pass();
    return _gateError(
      res,
      HttpStatus.forbidden,
      'That password is not right.',
      audience: audience,
    );
  }
  // readers
  if (account == null) {
    return _gateError(
      res,
      HttpStatus.unauthorized,
      'Sign in to read this.',
      audience: audience,
    );
  }
  final readers = (fields['readers'] as List?)?.whereType<String>() ?? const [];
  if (account.verified && readers.contains(account.email)) return pass();
  return _gateError(
    res,
    HttpStatus.forbidden,
    account.verified
        ? '${account.email} is not on the readers list.'
        : 'Verify your email first.',
    audience: audience,
  );
}

/// `PUT /gate/secret` {doc, password? | readers?}: the owner of the
/// record's handle sets who may read it.
Future<void> _secret(HttpRequest req) async {
  final res = req.response;
  final account = await _accountOf(req);
  if (account == null) {
    return _gateError(res, HttpStatus.unauthorized, 'Sign in again.');
  }
  final body = await _jsonBody(req);
  final doc = body?['doc'];
  final route = doc is String ? routeOfDocPath(doc) : null;
  if (route == null) {
    return _gateError(res, HttpStatus.badRequest, 'Unknown page.');
  }
  final handle = await _document('handles/${route.handle}');
  if (handle == null || plainFields(handle)['ownerId'] != account.uid) {
    return _gateError(res, HttpStatus.forbidden, 'This is not your page.');
  }
  final Map<String, Object?> secret;
  if (body!.containsKey('password')) {
    final password = body['password'];
    if (password is! String || password.length < 4 || password.length > 200) {
      return _gateError(
        res,
        HttpStatus.badRequest,
        'Use a password of 4 to 200 characters.',
      );
    }
    secret = passwordSecret(password);
  } else {
    final readers = readersFrom(body['readers']);
    if (readers == null) {
      return _gateError(
        res,
        HttpStatus.badRequest,
        'List up to 500 email addresses.',
      );
    }
    secret = {'readers': readers};
  }
  final (status, _) = await _send(
    'PATCH',
    Uri.parse('$_documents/gates/${gateIdFor(doc! as String)}'),
    bearer: await _token(),
    body: jsonEncode({
      'fields': {
        for (final MapEntry(:key, :value) in {
          ...secret,
          'ownerId': account.uid,
        }.entries)
          key: typedValue(value),
      },
    }),
  );
  if (status != HttpStatus.ok) throw HttpException('gate secret: $status');
  _gateJson(res, HttpStatus.ok, {'ok': true});
}

/// `GET /gate/file/<path>?t=<pass>`: streams a gated Storage object
/// (ranges pass through, for video).
Future<void> _gateFile(HttpRequest req, String encodedPath) async {
  final res = req.response;
  final path = Uri.decodeComponent(encodedPath);
  final token = req.uri.queryParameters['t'] ?? '';
  if (!passCovers(_gateKey, token, path, DateTime.now())) {
    return _gateError(res, HttpStatus.forbidden, 'This link has expired.');
  }
  final out = await _http
      .openUrl(
        req.method,
        Uri.parse(
          '${_storageEmulator ?? 'https://storage.googleapis.com'}'
          '/storage/v1/b/$_bucket/o/${Uri.encodeComponent(path)}?alt=media',
        ),
      )
      .timeout(const Duration(seconds: 10));
  out.headers.set('authorization', 'Bearer ${await _token()}');
  final range = req.headers.value('range');
  if (range != null) out.headers.set('range', range);
  final reply = await out.close();
  res.statusCode = reply.statusCode;
  for (final h in [
    'content-type',
    'content-length',
    'content-range',
    'accept-ranges',
  ]) {
    final v = reply.headers.value(h);
    if (v != null) res.headers.set(h, v);
  }
  res.headers
    ..set('cache-control', 'private, max-age=3600')
    ..set('cross-origin-resource-policy', 'cross-origin');
  res.bufferOutput = false;
  await res.addStream(reply);
}

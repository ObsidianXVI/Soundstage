import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:soundstage_agent/agent.dart';

// Cloud Run service (infra/terraform/agent.tf, m6.md "Architecture"): the
// author's model keys live in Secret Manager and are only ever used here,
// to forward that author's agent requests. Every request carries the
// author's Firebase ID token.

final Map<String, String> _env = Platform.environment;
final String _project = _env['PROJECT_ID'] ?? 'project-soundstage';
final String _webApiKey = _env['FIREBASE_API_KEY'] ?? '';
final String _pagesSite = _env['PAGES_SITE'] ?? '';
final List<String> _origins =
    (_env['ALLOWED_ORIGINS'] ?? 'https://project-soundstage.web.app').split(
      ',',
    );

final HttpClient _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 10);

Future<void> main() async {
  final port = int.tryParse(_env['PORT'] ?? '') ?? 8080;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('soundstage-agent on :$port');
  await for (final request in server) {
    unawaited(_handle(request));
  }
}

Future<void> _handle(HttpRequest req) async {
  final res = req.response;
  final origin = req.headers.value('origin');
  if (originAllowed(origin, _origins)) {
    res.headers
      ..set('access-control-allow-origin', origin!)
      ..set('vary', 'Origin')
      ..set('access-control-allow-headers', 'authorization, content-type')
      ..set('access-control-allow-methods', 'GET, PUT, POST, DELETE')
      ..set('access-control-max-age', '3600');
  }
  try {
    if (req.method == 'OPTIONS') {
      res.statusCode = HttpStatus.noContent;
      return;
    }
    final route = Route.parse(req.method, req.uri.path);
    if (route == null) return _error(res, HttpStatus.notFound, 'Not found.');
    final account = await _accountOf(req.headers.value('authorization'));
    if (account == null) {
      return _error(res, HttpStatus.unauthorized, 'Sign in again.');
    }
    if (!isInvited(
      email: account.email,
      verified: account.verified,
      invites: await _invites(),
    )) {
      return _error(
        res,
        HttpStatus.forbidden,
        'Soundstage is invite-only for now.',
      );
    }
    final uid = account.uid;
    switch (route) {
      case ListDomains():
        return _json(res, await _listDomains(account));
      case AddDomain():
        final body = await _body(req);
        final host = body is Map ? body['host'] : null;
        if (host is! String || !isValidDomain(host.trim().toLowerCase())) {
          return _error(res, HttpStatus.badRequest, 'Enter a domain name.');
        }
        return await _addDomain(res, account, host.trim().toLowerCase());
      case RemoveDomain(:final host):
        return await _removeDomain(res, account, host);
      case KeyStatus(:final provider):
        final key = await _readKey(uid, provider);
        return _json(res, {'set': key != null});
      case PutKey(:final provider):
        final body = await _body(req);
        final key = body is Map ? body['key'] : null;
        if (key is! String || key.trim().isEmpty || key.length > maxKeyLength) {
          return _error(res, HttpStatus.badRequest, 'Enter a key.');
        }
        await _writeKey(uid, provider, key.trim());
        return _json(res, {'set': true});
      case DeleteKey(:final provider):
        await _deleteKey(uid, provider);
        return _json(res, {'set': false});
      case Forward(:final provider):
        final body = await _body(req);
        final problem = checkBody(provider, body);
        if (problem != null) {
          return _error(res, HttpStatus.badRequest, problem);
        }
        final key = await _readKey(uid, provider);
        if (key == null) {
          return _error(
            res,
            HttpStatus.preconditionFailed,
            'Add your ${provider.name} key in Agent settings.',
          );
        }
        return _forward(res, provider, key, body);
    }
  } on _TooLarge {
    _error(res, HttpStatus.requestEntityTooLarge, 'The request is too big.');
  } on Object catch (e) {
    stderr.writeln('soundstage-agent: ${req.method} ${req.uri.path}: $e');
    try {
      _error(res, HttpStatus.badGateway, 'The agent service failed.');
    } on Object {
      // headers already sent (a stream broke midway)
    }
  } finally {
    await res.close();
  }
}

void _json(HttpResponse res, Object body) {
  res
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
}

void _error(HttpResponse res, int status, String message) {
  res.statusCode = status;
  _json(res, {
    'error': {'message': message},
  });
}

class _TooLarge implements Exception {}

Future<Object?> _body(HttpRequest req) async {
  final bytes = <int>[];
  await for (final chunk in req) {
    bytes.addAll(chunk);
    if (bytes.length > maxBodyBytes) throw _TooLarge();
  }
  if (bytes.isEmpty) return null;
  return jsonDecode(utf8.decode(bytes));
}

// ---- Auth ---------------------------------------------------------------

typedef _Account = ({String uid, String? email, bool verified});

final Map<String, (_Account, DateTime)> _accounts = {};

/// The account of a `Bearer <Firebase ID token>`, checked with Identity
/// Toolkit (`accounts:lookup`), cached for five minutes.
Future<_Account?> _accountOf(String? authorization) async {
  if (authorization == null || !authorization.startsWith('Bearer ')) {
    return null;
  }
  final token = authorization.substring(7);
  final cached = _accounts[token];
  if (cached != null && DateTime.now().isBefore(cached.$2)) return cached.$1;
  final (status, body) = await _send(
    'POST',
    Uri.parse(
      'https://identitytoolkit.googleapis.com/v1/accounts:lookup'
      '?key=$_webApiKey',
    ),
    body: jsonEncode({'idToken': token}),
  );
  if (status != HttpStatus.ok) return null;
  final users = (jsonDecode(body) as Map<String, Object?>)['users'];
  if (users is! List || users.isEmpty) return null;
  final user = users.first as Map;
  final uid = user['localId'];
  if (uid is! String) return null;
  final account = (
    uid: uid,
    email: user['email'] as String?,
    verified: user['emailVerified'] == true,
  );
  if (_accounts.length > 1000) _accounts.clear();
  _accounts[token] = (account, DateTime.now().add(const Duration(minutes: 5)));
  return account;
}

Set<String> _inviteList = const {};
DateTime _invitesExpiry = DateTime(0);

/// The admin's invite list (Firestore `config/invites`), read at most once
/// a minute.
Future<Set<String>> _invites() async {
  if (DateTime.now().isBefore(_invitesExpiry)) return _inviteList;
  final (status, body) = await _send(
    'GET',
    Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$_project/databases/'
      '(default)/documents/config/invites',
    ),
    bearer: await _token(),
  );
  if (status == HttpStatus.notFound) {
    _inviteList = const {};
  } else if (status != HttpStatus.ok) {
    throw HttpException('invites read: $status');
  } else {
    _inviteList = inviteEmails(jsonDecode(body));
  }
  _invitesExpiry = DateTime.now().add(const Duration(minutes: 1));
  return _inviteList;
}

// ---- Custom domains (m7.md T7.5) ----------------------------------------

String get _documents =>
    'https://firestore.googleapis.com/v1/projects/$_project/databases/'
    '(default)/documents';

String get _customDomains =>
    'https://firebasehosting.googleapis.com/v1beta1/projects/$_project/'
    'sites/$_pagesSite/customDomains';

/// The Firestore document at [path] (REST JSON), or null.
Future<Map<String, Object?>?> _doc(String path) async {
  final (status, body) = await _send(
    'GET',
    Uri.parse('$_documents/$path'),
    bearer: await _token(),
  );
  if (status == HttpStatus.notFound) return null;
  if (status != HttpStatus.ok) throw HttpException('firestore: $status');
  return jsonDecode(body) as Map<String, Object?>;
}

String? _stringField(Map<String, Object?>? doc, String name) {
  final value = (doc?['fields'] as Map?)?[name];
  return value is Map && value['stringValue'] is String
      ? value['stringValue'] as String
      : null;
}

/// Whether the admin enabled custom domains for [account]
/// (`config/premium`, request-only).
Future<bool> _premium(_Account account) async {
  final list = inviteEmails(await _doc('config/premium'));
  return account.email != null &&
      list.contains(account.email!.trim().toLowerCase());
}

/// The Hosting custom domain [host] (REST JSON), or null.
Future<Map<String, Object?>?> _customDomain(String host) async {
  final (status, body) = await _send(
    'GET',
    Uri.parse('$_customDomains/$host'),
    bearer: await _token(),
  );
  if (status == HttpStatus.notFound) return null;
  if (status != HttpStatus.ok) throw HttpException('hosting: $status');
  return jsonDecode(body) as Map<String, Object?>;
}

Future<Map<String, Object?>> _listDomains(_Account account) async {
  final premium = await _premium(account);
  final (status, body) = await _send(
    'POST',
    Uri.parse('$_documents:runQuery'),
    bearer: await _token(),
    body: jsonEncode({
      'structuredQuery': {
        'from': [
          {'collectionId': 'domains'},
        ],
        'where': {
          'fieldFilter': {
            'field': {'fieldPath': 'ownerId'},
            'op': 'EQUAL',
            'value': {'stringValue': account.uid},
          },
        },
      },
    }),
  );
  if (status != HttpStatus.ok) throw HttpException('firestore: $status');
  final domains = <Map<String, Object?>>[];
  for (final row in (jsonDecode(body) as List).whereType<Map>()) {
    final name = (row['document'] as Map?)?['name'];
    if (name is! String) continue;
    final host = name.split('/').last;
    domains.add(domainSummary(host, await _customDomain(host)));
  }
  return {'premium': premium, 'domains': domains};
}

Future<void> _addDomain(HttpResponse res, _Account account, String host) async {
  if (!await _premium(account)) {
    return _error(
      res,
      HttpStatus.forbidden,
      'Custom domains are by request. Ask to have them enabled.',
    );
  }
  final handle = _stringField(await _doc('profiles/${account.uid}'), 'handle');
  if (handle == null) {
    return _error(res, HttpStatus.preconditionFailed, 'Choose a handle first.');
  }
  final existing = await _doc('domains/$host');
  if (existing != null && _stringField(existing, 'ownerId') != account.uid) {
    return _error(res, HttpStatus.conflict, '$host is connected elsewhere.');
  }
  if (await _customDomain(host) == null) {
    final (status, body) = await _send(
      'POST',
      Uri.parse('$_customDomains?customDomainId=$host'),
      bearer: await _token(),
      body: '{}',
    );
    if (status != HttpStatus.ok) {
      stderr.writeln('soundstage-agent: create $host: $status $body');
      return _error(
        res,
        HttpStatus.badGateway,
        'Hosting refused $host. Check the name and try again.',
      );
    }
  }
  final (status, _) = await _send(
    'PATCH',
    Uri.parse('$_documents/domains/$host'),
    bearer: await _token(),
    body: jsonEncode({
      'fields': {
        'handle': {'stringValue': handle},
        'ownerId': {'stringValue': account.uid},
      },
    }),
  );
  if (status != HttpStatus.ok) throw HttpException('domain record: $status');
  return _json(res, domainSummary(host, await _customDomain(host)));
}

Future<void> _removeDomain(
  HttpResponse res,
  _Account account,
  String host,
) async {
  final existing = await _doc('domains/$host');
  if (existing == null || _stringField(existing, 'ownerId') != account.uid) {
    return _error(res, HttpStatus.notFound, 'Not one of your domains.');
  }
  final (status, _) = await _send(
    'DELETE',
    Uri.parse('$_customDomains/$host?allowMissing=true'),
    bearer: await _token(),
  );
  if (status != HttpStatus.ok) throw HttpException('hosting delete: $status');
  final (s2, _) = await _send(
    'DELETE',
    Uri.parse('$_documents/domains/$host'),
    bearer: await _token(),
  );
  if (s2 != HttpStatus.ok) throw HttpException('domain record delete: $s2');
  return _json(res, {'removed': host});
}

// ---- Secret Manager -----------------------------------------------------

String get _secrets =>
    'https://secretmanager.googleapis.com/v1/projects/$_project/secrets';

Future<String?> _readKey(String uid, Provider p) async {
  final (status, body) = await _send(
    'GET',
    Uri.parse('$_secrets/${secretIdFor(uid, p)}/versions/latest:access'),
    bearer: await _token(),
  );
  if (status == HttpStatus.notFound) return null;
  if (status != HttpStatus.ok) throw HttpException('secret read: $status');
  final data =
      ((jsonDecode(body) as Map<String, Object?>)['payload']! as Map)['data']!
          as String;
  return utf8.decode(base64.decode(data));
}

/// Replaces the key: the secret is recreated so only one version (the
/// billed unit) exists.
Future<void> _writeKey(String uid, Provider p, String key) async {
  await _deleteKey(uid, p);
  final id = secretIdFor(uid, p);
  final token = await _token();
  var (status, _) = await _send(
    'POST',
    Uri.parse('$_secrets?secretId=$id'),
    bearer: token,
    body: jsonEncode({
      'replication': {'automatic': <String, Object?>{}},
      'labels': {'owner': 'soundstage-agent'},
    }),
  );
  if (status != HttpStatus.ok) throw HttpException('secret create: $status');
  (status, _) = await _send(
    'POST',
    Uri.parse('$_secrets/$id:addVersion'),
    bearer: token,
    body: jsonEncode({
      'payload': {'data': base64.encode(utf8.encode(key))},
    }),
  );
  if (status != HttpStatus.ok) throw HttpException('secret version: $status');
}

Future<void> _deleteKey(String uid, Provider p) async {
  final (status, _) = await _send(
    'DELETE',
    Uri.parse('$_secrets/${secretIdFor(uid, p)}'),
    bearer: await _token(),
  );
  if (status != HttpStatus.ok && status != HttpStatus.notFound) {
    throw HttpException('secret delete: $status');
  }
}

String? _tokenValue;
DateTime _tokenExpiry = DateTime(0);

/// An access token for the service's account (metadata server).
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
  _tokenExpiry = DateTime.now().add(
    Duration(seconds: (json['expires_in']! as num).toInt() - 60),
  );
  return _tokenValue = json['access_token']! as String;
}

// ---- Forwarding ---------------------------------------------------------

/// Sends [body] to [provider] with the author's [key] and streams the reply
/// (status, content type and bytes) back unchanged.
Future<void> _forward(
  HttpResponse res,
  Provider provider,
  String key,
  Object? body,
) async {
  final out = await _http.postUrl(Uri.parse(provider.endpoint));
  providerHeaders(provider, key).forEach(out.headers.set);
  out.add(utf8.encode(jsonEncode(body)));
  final reply = await out.close();
  res.statusCode = reply.statusCode;
  final type = reply.headers.contentType;
  if (type != null) res.headers.contentType = type;
  for (final h in ['request-id', 'x-request-id', 'retry-after']) {
    final v = reply.headers.value(h);
    if (v != null) res.headers.set(h, v);
  }
  res.bufferOutput = false;
  await res.addStream(reply);
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
      .timeout(const Duration(seconds: 10));
  if (bearer != null) req.headers.set('authorization', 'Bearer $bearer');
  headers.forEach(req.headers.set);
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(body));
  }
  final res = await req.close().timeout(const Duration(seconds: 15));
  return (res.statusCode, await res.transform(utf8.decoder).join());
}

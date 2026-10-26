import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'head.dart';

// The reader's gate for password and readers-only work (m7.md T7.4,
// DECISIONS 26/10/26 "Audiences"): the rules, kept free of I/O so they
// are tested directly. Gated files live under Storage `gated/…` and are
// never public; a pass is a short-lived token naming the one folder it
// opens, signed with the service's key.

/// How long a pass lasts.
const Duration kPassLifetime = Duration(hours: 6);

/// PBKDF2 iterations for stored passwords.
const int kPasswordIterations = 60000;

/// The Firestore id of the secret of record [docPath] (`gates/<id>`).
String gateIdFor(String docPath) => docPath.replaceAll('/', '~');

/// The route of a record path (`sites/<h>/drafts/<slug>` and the like), or
/// null for anything else.
HeadRoute? routeOfDocPath(String docPath) {
  final route = HeadRoute.fromDocumentName('/documents/$docPath');
  return route != null && route.docPath == docPath ? route : null;
}

/// Firestore REST typed values as plain JSON (strings, numbers, booleans,
/// lists, maps; timestamps as strings).
Object? plainValue(Object? v) => switch (v) {
  {'stringValue': final String s} => s,
  {'integerValue': final String s} => int.parse(s),
  {'integerValue': final int i} => i,
  {'doubleValue': final num d} => d,
  {'booleanValue': final bool b} => b,
  {'timestampValue': final String t} => t,
  {'nullValue': _} => null,
  {'arrayValue': final Map a} => [
    for (final x in (a['values'] as List?) ?? const []) plainValue(x),
  ],
  {'mapValue': final Map m} => plainFields(m),
  _ => null,
};

/// The plain fields of a Firestore REST document (or map value).
Map<String, Object?> plainFields(Map doc) => {
  for (final MapEntry(:key, :value)
      in ((doc['fields'] as Map?) ?? const {}).entries)
    key as String: plainValue(value),
};

/// [v] as a Firestore REST typed value.
Object? typedValue(Object? v) => switch (v) {
  null => {'nullValue': null},
  final String s => {'stringValue': s},
  final bool b => {'booleanValue': b},
  final int i => {'integerValue': '$i'},
  final num d => {'doubleValue': d},
  final List l => {
    'arrayValue': {'values': l.map(typedValue).toList()},
  },
  final Map m => {
    'mapValue': {
      'fields': {
        for (final e in m.entries) e.key as String: typedValue(e.value),
      },
    },
  },
  _ => throw ArgumentError.value(v, 'v', 'not a Firestore value'),
};

/// The Storage folder a gated story's files live in: its live document's
/// folder (`gated/<uid>/<handle>/…`), or null when it is not gated there.
String? gatedFolderOf(Map<String, Object?> record) {
  final path = record['path'];
  if (path is! String || !path.startsWith('gated/')) return null;
  final i = path.lastIndexOf('/');
  return i <= 'gated/'.length ? null : path.substring(0, i);
}

/// PBKDF2-HMAC-SHA256 of [password] (32 bytes).
Uint8List pbkdf2(String password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, utf8.encode(password));
  var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

/// The stored form of a new password: salt, iterations and hash (base64).
Map<String, Object?> passwordSecret(String password, {Random? random}) {
  final r = random ?? Random.secure();
  final salt = List<int>.generate(16, (_) => r.nextInt(256));
  return {
    'salt': base64.encode(salt),
    'iterations': kPasswordIterations,
    'hash': base64.encode(pbkdf2(password, salt, kPasswordIterations)),
  };
}

/// Whether [password] matches the stored [secret].
bool passwordMatches(String password, Map<String, Object?> secret) {
  final salt = secret['salt'];
  final hash = secret['hash'];
  final iterations = secret['iterations'];
  if (salt is! String || hash is! String || iterations is! int) return false;
  return _same(
    pbkdf2(password, base64.decode(salt), iterations),
    base64.decode(hash),
  );
}

/// The readers list from a request body: trimmed, lowercased, distinct.
/// Null when it is not a list of at most 500 email-like strings.
List<String>? readersFrom(Object? v) {
  if (v is! List || v.length > 500) return null;
  final out = <String>{};
  for (final e in v) {
    if (e is! String) return null;
    final s = e.trim().toLowerCase();
    if (s.isEmpty) continue;
    if (!RegExp(r'^[^@\s]+@[^@\s]+$').hasMatch(s)) return null;
    out.add(s);
  }
  return out.toList();
}

/// A pass for the files under [folder] until [expires].
String signPass(List<int> key, String folder, DateTime expires) {
  final payload = base64Url.encode(
    utf8.encode(
      jsonEncode({'f': folder, 'e': expires.millisecondsSinceEpoch ~/ 1000}),
    ),
  );
  final sig = base64Url.encode(
    Hmac(sha256, key).convert(utf8.encode(payload)).bytes,
  );
  return '$payload.$sig';
}

/// Whether [token] is a valid, unexpired pass covering Storage object
/// [path].
bool passCovers(List<int> key, String token, String path, DateTime now) {
  final dot = token.indexOf('.');
  if (dot <= 0) return false;
  final payload = token.substring(0, dot);
  final List<int> sig;
  try {
    sig = base64Url.decode(token.substring(dot + 1));
  } on FormatException {
    return false;
  }
  final want = Hmac(sha256, key).convert(utf8.encode(payload)).bytes;
  if (!_same(sig, want)) return false;
  final Object? claims;
  try {
    claims = jsonDecode(utf8.decode(base64Url.decode(payload)));
  } on FormatException {
    return false;
  }
  if (claims is! Map) return false;
  final folder = claims['f'];
  final exp = claims['e'];
  if (folder is! String || exp is! int) return false;
  if (now.millisecondsSinceEpoch ~/ 1000 >= exp) return false;
  if (path.split('/').contains('..')) return false;
  return path.startsWith('$folder/');
}

/// Constant-time comparison.
bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

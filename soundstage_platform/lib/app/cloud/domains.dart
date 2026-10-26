import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud.dart';

// Custom domains (DECISIONS 26/10/26 "Custom domains", m7.md T7.5): a
// premium author's domain (Firestore `domains/{host}`) shows their handle's
// published work at clean paths: `/` is `/@<handle>`, `/s/<slug>` a
// one-off story, `/<pub>[/<issue>]` a publication.

/// Whether [host] serves the whole app (editor, story list) rather than
/// an author's domain.
bool isAppHost(String host) =>
    host == 'localhost' ||
    host == '127.0.0.1' ||
    host.endsWith('.web.app') ||
    host.endsWith('.firebaseapp.com');

/// The handle custom domain [host] shows, or null (an app host, an unknown
/// domain, or the lookup failed).
Future<String?> domainHandle(Cloud? cloud, String host) async {
  if (cloud == null || isAppHost(host)) return null;
  try {
    final data =
        (await cloud.firestore.doc('domains/${host.toLowerCase()}').get())
            .data();
    return data?['handle'] as String?;
  } on FirebaseException {
    return null;
  }
}

/// The handle this custom domain shows; null on the app's own hosts. Set
/// in `main`.
final siteHandleProvider = Provider<String?>((ref) => null);

/// [route] (an `/@<handle>/…` path) as a link on this host: on the
/// handle's own domain the `/@<handle>` prefix is dropped.
String localRoute(String? siteHandle, String route) {
  if (siteHandle == null) return route;
  final prefix = '/@$siteHandle';
  if (route == prefix) return '/';
  return route.startsWith('$prefix/') ? route.substring(prefix.length) : route;
}

/// A DNS record the author adds (or removes) at their DNS provider.
class DnsChange {
  const DnsChange({
    required this.add,
    required this.name,
    required this.type,
    required this.value,
  });

  factory DnsChange.fromMap(Map<String, Object?> m) => DnsChange(
    add: m['action'] != 'REMOVE',
    name: (m['name'] as String?) ?? '',
    type: (m['type'] as String?) ?? '',
    value: (m['value'] as String?) ?? '',
  );

  final bool add;
  final String name;
  final String type;
  final String value;
}

/// One of the author's custom domains and how far Hosting has got.
class CustomDomain {
  const CustomDomain({
    required this.host,
    required this.state,
    this.records = const [],
    this.issues = const [],
  });

  factory CustomDomain.fromMap(Map<String, Object?> m) => CustomDomain(
    host: m['host']! as String,
    state: (m['state'] as String?) ?? 'pending',
    records: [
      for (final r in (m['records'] as List?) ?? const [])
        if (r is Map) DnsChange.fromMap(r.cast<String, Object?>()),
    ],
    issues: [
      for (final i in (m['issues'] as List?) ?? const [])
        if (i is String) i,
    ],
  );

  final String host;

  /// `pending` (just added), `dns` (records to change), `checking`
  /// (records found, certificate on its way) or `live`.
  final String state;
  final List<DnsChange> records;
  final List<String> issues;

  String get stateLabel => switch (state) {
    'live' => 'Live',
    'dns' => 'Waiting for DNS',
    'checking' => 'Checking DNS and preparing HTTPS',
    _ => 'Setting up',
  };
}

/// The author's domains (through the agent service, m7.md T7.5).
class DomainsClient {
  DomainsClient({
    required this.baseUrl,
    required this.send,
    required this.idToken,
  });

  final String baseUrl;
  final Future<(int, String)> Function(
    String method,
    String url, {
    Map<String, String> headers,
    String? body,
  })
  send;
  final Future<String?> Function() idToken;

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    Object? body,
  }) async {
    final token = await idToken();
    if (token == null) throw const DomainException('Sign in again.');
    final (status, text) = await send(
      method,
      '$baseUrl$path',
      headers: {'authorization': 'Bearer $token'},
      body: body == null ? null : jsonEncode(body),
    );
    Map<String, Object?> json;
    try {
      json = (jsonDecode(text) as Map).cast<String, Object?>();
    } on Object {
      json = const {};
    }
    if (status != 200) {
      throw DomainException(switch (json['error']) {
        {'message': final String m} => m,
        _ => 'The request failed ($status).',
      });
    }
    return json;
  }

  /// Whether domains are enabled for the author, and their domains.
  Future<(bool premium, List<CustomDomain>)> list() async {
    final json = await _call('GET', '/domains');
    return (
      json['premium'] == true,
      [
        for (final d in (json['domains'] as List?) ?? const [])
          if (d is Map) CustomDomain.fromMap(d.cast<String, Object?>()),
      ],
    );
  }

  Future<CustomDomain> add(String host) async => CustomDomain.fromMap(
    await _call('POST', '/domains', body: {'host': host}),
  );

  Future<void> remove(String host) => _call('DELETE', '/domains/$host');
}

class DomainException implements Exception {
  const DomainException(this.message);

  final String message;

  @override
  String toString() => message;
}

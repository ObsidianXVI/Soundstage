// The agent service's rules (m6.md "Architecture"), kept free of I/O so
// they are tested directly: which providers exist and where their requests
// go, how secrets are named, which origins may call, and how request
// bodies are checked before they are forwarded with the author's key.

/// A model provider the agent can call.
enum Provider {
  /// Claude Messages API (raw HTTP; see m6.md "Grounding").
  anthropic('https://api.anthropic.com/v1/messages'),

  /// Quiver AI text-to-SVG.
  quiver('https://api.quiver.ai/v1/svgs/generations');

  const Provider(this.endpoint);

  final String endpoint;

  static Provider? named(String name) =>
      values.where((p) => p.name == name).firstOrNull;
}

/// The Anthropic API version the service sends.
const String anthropicVersion = '2026-10-21';

/// The largest request body forwarded (bytes).
const int maxBodyBytes = 8 * 1024 * 1024;

/// The longest key accepted (bytes).
const int maxKeyLength = 512;

/// The Secret Manager secret id holding [uid]'s key for [provider].
/// Firebase uids are letters and digits (28 chars), within the secret id
/// alphabet `[A-Za-z0-9_-]`; anything else is replaced.
String secretIdFor(String uid, Provider provider) {
  final safe = uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return 'agent-$safe-${provider.name}';
}

/// Whether a browser at [origin] may call the service.
bool originAllowed(String? origin, List<String> allowed) {
  if (origin == null) return false;
  if (allowed.contains(origin)) return true;
  final uri = Uri.tryParse(origin);
  return uri != null &&
      (uri.host == 'localhost' || uri.host == '127.0.0.1') &&
      (uri.scheme == 'http' || uri.scheme == 'https');
}

/// The route of a request path, or null for anything unknown.
sealed class Route {
  const Route();

  static Route? parse(String method, String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length == 2 && parts[0] == 'keys') {
      final p = Provider.named(parts[1]);
      if (p == null) return null;
      return switch (method) {
        'GET' => KeyStatus(p),
        'PUT' => PutKey(p),
        'DELETE' => DeleteKey(p),
        _ => null,
      };
    }
    if (method == 'POST' && parts.length >= 2) {
      final p = Provider.named(parts[0]);
      final rest = parts.skip(1).join('/');
      if (p == Provider.anthropic && rest == 'messages') {
        return const Forward(Provider.anthropic);
      }
      if (p == Provider.quiver && rest == 'svgs/generations') {
        return const Forward(Provider.quiver);
      }
    }
    return null;
  }
}

class KeyStatus extends Route {
  const KeyStatus(this.provider);
  final Provider provider;
}

class PutKey extends Route {
  const PutKey(this.provider);
  final Provider provider;
}

class DeleteKey extends Route {
  const DeleteKey(this.provider);
  final Provider provider;
}

class Forward extends Route {
  const Forward(this.provider);
  final Provider provider;
}

/// Why a forwarded body is refused, or null when it may go.
String? checkBody(Provider provider, Object? body) {
  if (body is! Map) return 'The request body must be a JSON object.';
  final model = body['model'];
  if (model is! String || model.isEmpty) return 'A model is required.';
  switch (provider) {
    case Provider.anthropic:
      if (body['messages'] is! List) return 'messages must be a list.';
    case Provider.quiver:
      final prompt = body['prompt'];
      if (prompt is! String || prompt.isEmpty) return 'A prompt is required.';
  }
  return null;
}

/// The headers that carry [key] to [provider].
Map<String, String> providerHeaders(Provider provider, String key) =>
    switch (provider) {
      Provider.anthropic => {
        'x-api-key': key,
        'anthropic-version': anthropicVersion,
        'content-type': 'application/json',
      },
      Provider.quiver => {
        'authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
    };

/// The approved emails in the Firestore REST form of `config/invites`
/// (`fields.emails.arrayValue.values[].stringValue`), lowercased. Anything
/// malformed reads as no invites.
Set<String> inviteEmails(Object? document) {
  if (document is! Map) return const {};
  final fields = document['fields'];
  final emails = fields is Map ? fields['emails'] : null;
  final array = emails is Map ? emails['arrayValue'] : null;
  final values = array is Map ? array['values'] : null;
  if (values is! List) return const {};
  return {
    for (final v in values)
      if (v is Map && v['stringValue'] is String)
        (v['stringValue'] as String).trim().toLowerCase(),
  };
}

/// Whether an account may use the service (DECISIONS 26/10/26 "Invites"): a
/// verified email on the invite list.
bool isInvited({
  required String? email,
  required bool verified,
  required Set<String> invites,
}) => email != null && verified && invites.contains(email.trim().toLowerCase());

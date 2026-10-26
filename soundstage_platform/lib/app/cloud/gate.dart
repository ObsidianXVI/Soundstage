import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/agent_client.dart' show JsonSender;
import '../agent/agent_platform.dart' as platform;
import 'publish.dart';

// The reader's gate for password and readers-only work (m7.md T7.4): the
// head service checks a password or a signed-in reader and hands back the
// record with a short-lived pass for its files.

/// The gate service's URL (Terraform output GATE_URL), or empty.
const String kGateUrl = String.fromEnvironment('GATE_URL');

/// What opening the gate gave.
sealed class GateResult {
  const GateResult();
}

class GateOpened extends GateResult {
  const GateOpened(this.pass);

  final GatePass pass;
}

/// Not opened: [audience] says what the reader needs; [message] says why.
class GateClosed extends GateResult {
  const GateClosed(this.audience, this.message);

  final Audience audience;
  final String message;
}

class GateMissing extends GateResult {
  const GateMissing();
}

class GateClient {
  GateClient({required this.baseUrl, required this.send});

  final String baseUrl;
  final JsonSender send;

  /// Asks to read record [docPath], with a [password] or as the reader
  /// whose [idToken] is given (the owner always passes).
  Future<GateResult> open(
    String docPath, {
    String? password,
    String? idToken,
  }) async {
    final (status, body) = await send(
      'POST',
      '$baseUrl/gate/open',
      headers: {'authorization': ?(idToken == null ? null : 'Bearer $idToken')},
      body: jsonEncode({'doc': docPath, 'password': ?password}),
    );
    final json = _decode(body);
    if (status == 200) {
      return GateOpened(
        GatePass(
          record: (json['record']! as Map).cast<String, Object?>(),
          token: (json['token'] as String?) ?? '',
          baseUrl: baseUrl,
        ),
      );
    }
    if (status == 404) return const GateMissing();
    return GateClosed(
      Audience.parse(json['audience']),
      _message(json) ?? 'The page could not be opened ($status).',
    );
  }

  /// Sets who may read record [docPath]: a [password], or a list of
  /// [readers]' emails. Throws [PublishException] when refused.
  Future<void> setSecret(
    String docPath, {
    required String idToken,
    String? password,
    List<String>? readers,
  }) async {
    final (status, body) = await send(
      'PUT',
      '$baseUrl/gate/secret',
      headers: {'authorization': 'Bearer $idToken'},
      body: jsonEncode({
        'doc': docPath,
        'password': ?password,
        if (password == null) 'readers': readers ?? const <String>[],
      }),
    );
    if (status != 200) {
      throw PublishException(
        _message(_decode(body)) ?? 'The gate refused ($status).',
      );
    }
  }

  static Map<String, Object?> _decode(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map ? v.cast<String, Object?>() : const {};
    } on FormatException {
      return const {};
    }
  }

  static String? _message(Map<String, Object?> json) => switch (json['error']) {
    {'message': final String m} => m,
    _ => null,
  };
}

/// The gate client, or null when the build has no gate service.
final gateClientProvider = Provider<GateClient?>(
  (ref) => kGateUrl.isEmpty
      ? null
      : GateClient(baseUrl: kGateUrl, send: platform.sendJson),
);

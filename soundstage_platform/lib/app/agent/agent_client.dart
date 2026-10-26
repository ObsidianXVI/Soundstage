import 'dart:convert';
import 'dart:typed_data';

import 'package:soundstage_platform/editor/agent/agent_transport.dart';

/// Sends an HTTP request with a JSON body: (status, body text).
typedef JsonSender =
    Future<(int, String)> Function(
      String method,
      String url, {
      Map<String, String> headers,
      String? body,
    });

/// Draws an SVG into a PNG of the given pixel size.
typedef SvgRasterizer =
    Future<Uint8List> Function(String svg, int width, int height);

/// The agent's model access over the Soundstage agent service (m6.md
/// "Architecture"): the author's keys stay in the service; every request
/// carries the author's Firebase ID token.
class AgentServiceClient implements AgentTransport {
  AgentServiceClient({
    required this.baseUrl,
    required this.idToken,
    required this.send,
    required this.rasterize,
    required this.readConfig,
  });

  final String baseUrl;
  final Future<String?> Function() idToken;
  final JsonSender send;
  final SvgRasterizer rasterize;

  /// The author's current settings (read on every request, so a change
  /// does not need a new client).
  final AgentConfig Function() readConfig;

  @override
  AgentConfig get config => readConfig();

  /// The providers whose keys the service can hold.
  static const List<String> providers = ['anthropic', 'quiver'];

  Future<Map<String, Object?>> _call(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final token = await idToken();
    if (token == null) throw const AgentException('Sign in to use the agent.');
    final (status, text) = await send(
      method,
      '$baseUrl$path',
      headers: {'authorization': 'Bearer $token'},
      body: body == null ? null : jsonEncode(body),
    );
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (status >= 200 && status < 300 && json is Map<String, Object?>) {
      return json;
    }
    final message = switch (json) {
      {'error': {'message': final String m}} => m,
      _ => 'The agent service answered $status.',
    };
    throw AgentException(message, needsKey: status == 412);
  }

  @override
  Future<Map<String, Object?>> claude(Map<String, Object?> body) => _call(
    'POST',
    '/anthropic/messages',
    {...body, 'model': config.claudeModel},
  );

  @override
  Future<Uint8List> illustrate(
    String prompt, {
    double width = 512,
    double height = 512,
  }) async {
    final reply = await _call('POST', '/quiver/svgs/generations', {
      'model': config.quiverModel,
      'prompt': prompt,
      'n': 1,
      'attributes': {
        'viewBox': {'minX': 0, 'minY': 0, 'width': width, 'height': height},
      },
    });
    final data = reply['data'];
    final svg = data is List && data.isNotEmpty
        ? (data.first as Map)['svg']
        : null;
    if (svg is! String || svg.isEmpty) {
      throw const AgentException('Quiver returned no drawing.');
    }
    // Twice the layer size (sharp on high-density screens), at most 2048.
    final scale = (2048 / (width > height ? width : height)).clamp(0.0, 2.0);
    return rasterize(
      svg,
      (width * scale).round().clamp(1, 2048),
      (height * scale).round().clamp(1, 2048),
    );
  }

  /// Whether the author has a key for [provider] in the service.
  Future<bool> hasKey(String provider) async =>
      (await _call('GET', '/keys/$provider'))['set'] == true;

  Future<void> setKey(String provider, String key) =>
      _call('PUT', '/keys/$provider', {'key': key});

  Future<void> removeKey(String provider) => _call('DELETE', '/keys/$provider');
}

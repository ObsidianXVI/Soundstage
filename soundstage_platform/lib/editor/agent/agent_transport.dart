import 'dart:typed_data';

// What the agent needs from outside the editor (m6.md "Architecture"): the
// app supplies it over the agent service, which holds the author's keys.

/// The author's model settings (stored by the app, per browser).
class AgentConfig {
  const AgentConfig({
    this.claudeModel = 'claude-opus-5-5',
    this.effort = 'medium',
    this.quiverModel = 'arrow-2',
  });

  factory AgentConfig.fromJson(Map<String, Object?> m) => AgentConfig(
    claudeModel: (m['claudeModel'] as String?) ?? 'claude-opus-5-5',
    effort: (m['effort'] as String?) ?? 'medium',
    quiverModel: (m['quiverModel'] as String?) ?? 'arrow-2',
  );

  /// A Claude model id (default: the current Opus).
  final String claudeModel;

  /// `output_config.effort`: low, medium, high, xhigh or max.
  final String effort;

  /// A Quiver model id for illustrations.
  final String quiverModel;

  static const List<String> efforts = ['low', 'medium', 'high', 'xhigh', 'max'];

  AgentConfig copyWith({
    String? claudeModel,
    String? effort,
    String? quiverModel,
  }) => AgentConfig(
    claudeModel: claudeModel ?? this.claudeModel,
    effort: effort ?? this.effort,
    quiverModel: quiverModel ?? this.quiverModel,
  );

  Map<String, String> toJson() => {
    'claudeModel': claudeModel,
    'effort': effort,
    'quiverModel': quiverModel,
  };
}

/// A request the provider or the service refused, in words for the author.
class AgentException implements Exception {
  const AgentException(this.message, {this.needsKey = false});

  final String message;

  /// The author has not added a key for this provider yet.
  final bool needsKey;

  @override
  String toString() => message;
}

/// Calls the models for the agent.
abstract interface class AgentTransport {
  AgentConfig get config;

  /// One Claude Messages API call; [body] without `model` (added from
  /// [config]). Returns the response JSON.
  Future<Map<String, Object?>> claude(Map<String, Object?> body);

  /// An illustration for [prompt] from Quiver, as PNG bytes at about
  /// [width] × [height] logical pixels (rasterised from the SVG).
  Future<Uint8List> illustrate(String prompt, {double width, double height});
}

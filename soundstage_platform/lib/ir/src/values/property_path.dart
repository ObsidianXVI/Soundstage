/// A dotted address of a property on a node (architecture §11.1), e.g.
/// `opacity`, `motion.translateY`, `fills.<paintId>.color`,
/// `content.0.spans.2.style.fontWeight`.
///
/// This is a zero-cost view over the path string. The IR stores paths as plain
/// strings (they are map keys in patches and bindings); resolving a path to a
/// property is the registry's job (T0.3).
extension type const PropertyPath(String value) {
  /// Builds a path from its segments.
  factory PropertyPath.fromSegments(Iterable<String> segments) =>
      PropertyPath(segments.join(separator));

  /// The segment separator.
  static const String separator = '.';

  /// The path split into its segments.
  List<String> get segments =>
      value.isEmpty ? const <String>[] : value.split(separator);

  /// The first segment, or an empty string for an empty path.
  String get head => value.isEmpty ? '' : segments.first;

  /// The last segment, or an empty string for an empty path.
  String get last => value.isEmpty ? '' : segments.last;

  /// The path without its last segment (empty for a single-segment path).
  PropertyPath get parent {
    final s = segments;
    return s.length <= 1
        ? const PropertyPath('')
        : PropertyPath.fromSegments(s.sublist(0, s.length - 1));
  }

  /// This path extended by [segment].
  PropertyPath child(String segment) => value.isEmpty
      ? PropertyPath(segment)
      : PropertyPath('$value$separator$segment');

  /// Whether [other] equals this path or starts with it at a segment boundary.
  bool isPrefixOf(PropertyPath other) =>
      other.value == value ||
      value.isEmpty ||
      other.value.startsWith('$value$separator');
}

/// A path to a node inside a tree: ids joined by `/` (architecture §9), e.g.
/// the inner path of an instance override, or a track's `target`.
extension type const NodePath(String value) {
  factory NodePath.fromIds(Iterable<String> ids) =>
      NodePath(ids.join(separator));

  static const String separator = '/';

  List<String> get ids =>
      value.isEmpty ? const <String>[] : value.split(separator);
}

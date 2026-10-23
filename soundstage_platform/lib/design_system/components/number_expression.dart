import 'dart:math' as math;

/// Evaluates a number-field entry: plain numbers, `+ - * /`, parentheses,
/// unary signs, and trailing units (`12px`, `50%`, `90deg`) which are ignored.
///
/// A leading `+`, `*` or `/` is relative to [current] (`+8` adds 8 to it, `*2`
/// doubles it, `/2` halves it). A leading `-` is a negative number
/// (`-8` is minus eight), as in Figma. Returns null for anything invalid, or a
/// non-finite result (division by zero).
double? evaluateNumberExpression(String input, {double? current}) {
  final tokens = _tokenize(input);
  if (tokens == null || tokens.isEmpty) return null;
  final first = tokens.first;
  if (first is String && (first == '+' || first == '*' || first == '/')) {
    if (current == null) {
      // "+8" with nothing to be relative to: treat + as a sign.
      if (first == '+') tokens.removeAt(0);
    } else {
      tokens.insert(0, current);
    }
  }
  final p = _Parser(tokens);
  final v = p.parse();
  if (v == null || !v.isFinite) return null;
  return v;
}

/// Formats [v] with at most [fractionDigits] decimals, no trailing zeros.
String formatNumber(double v, {int fractionDigits = 2}) {
  var s = v.toStringAsFixed(fractionDigits);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  if (s == '-0') s = '0';
  return s;
}

/// Rounds [v] to [fractionDigits] decimals.
double roundToDigits(double v, int fractionDigits) {
  final f = math.pow(10, fractionDigits).toDouble();
  final r = (v * f).roundToDouble() / f;
  return r == 0 ? 0 : r; // normalise -0
}

List<Object>? _tokenize(String input) {
  final out = <Object>[];
  var i = 0;
  final s = input.trim();
  final num = RegExp(r'(\d+\.?\d*|\.\d+)');
  while (i < s.length) {
    final ch = s[i];
    if (ch == ' ') {
      i++;
    } else if ('+-*/()'.contains(ch)) {
      out.add(ch);
      i++;
    } else if (ch == 'x' || ch == '×') {
      out.add('*');
      i++;
    } else if (ch == '÷') {
      out.add('/');
      i++;
    } else {
      final m = num.matchAsPrefix(s, i);
      if (m == null) return null;
      out.add(double.parse(m.group(0)!));
      i = m.end;
      // A unit directly after a number is ignored.
      while (i < s.length && RegExp(r'[a-zA-Z%°]').hasMatch(s[i])) {
        i++;
      }
    }
  }
  return out;
}

class _Parser {
  _Parser(this.t);

  final List<Object> t;
  int i = 0;
  bool bad = false;

  double? parse() {
    final v = _expr();
    if (bad || i != t.length) return null;
    return v;
  }

  bool _peek(String op) => i < t.length && t[i] == op;

  double _expr() {
    var v = _term();
    while (!bad && (_peek('+') || _peek('-'))) {
      final op = t[i++];
      final r = _term();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double _term() {
    var v = _unary();
    while (!bad && (_peek('*') || _peek('/'))) {
      final op = t[i++];
      final r = _unary();
      v = op == '*' ? v * r : v / r;
    }
    return v;
  }

  double _unary() {
    if (_peek('-')) {
      i++;
      return -_unary();
    }
    if (_peek('+')) {
      i++;
      return _unary();
    }
    return _primary();
  }

  double _primary() {
    if (i >= t.length) {
      bad = true;
      return 0;
    }
    final tok = t[i];
    if (tok is double) {
      i++;
      return tok;
    }
    if (tok == '(') {
      i++;
      final v = _expr();
      if (_peek(')')) {
        i++;
      } else {
        bad = true;
      }
      return v;
    }
    bad = true;
    return 0;
  }
}

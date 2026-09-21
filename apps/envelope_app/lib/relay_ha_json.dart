import 'dart:convert';

/// Dart's JSON decoder silently accepts duplicate object keys. Signed protocol
/// data must not depend on which duplicate a platform happens to retain.
Object? decodeRelayJson(String input) {
  final scanner = _UniqueKeysScanner(input);
  scanner.value(0);
  scanner.whitespace();
  if (scanner.position != input.length) {
    throw const FormatException('Trailing JSON input');
  }
  return jsonDecode(input);
}

class _UniqueKeysScanner {
  _UniqueKeysScanner(this.input);
  final String input;
  int position = 0;

  void whitespace() {
    while (position < input.length &&
        const [0x20, 0x09, 0x0a, 0x0d].contains(input.codeUnitAt(position))) {
      position++;
    }
  }

  bool consume(String character) {
    whitespace();
    if (position < input.length && input[position] == character) {
      position++;
      return true;
    }
    return false;
  }

  void require(String character) {
    if (!consume(character)) throw FormatException('Expected $character');
  }

  String string({bool key = false}) {
    whitespace();
    final start = position;
    require('"');
    while (position < input.length) {
      final character = input[position++];
      if (character == '\\') {
        position++;
      } else if (character == '"') {
        return key
            ? jsonDecode(input.substring(start, position)) as String
            : '';
      }
    }
    throw const FormatException('Unterminated JSON string');
  }

  void value(int depth) {
    if (depth > 64) throw const FormatException('JSON nesting exceeds limit');
    whitespace();
    if (position >= input.length) {
      throw const FormatException('Missing JSON value');
    }
    if (input[position] == '"') {
      string();
      return;
    }
    if (consume('{')) {
      final keys = <String>{};
      if (consume('}')) return;
      do {
        final name = string(key: true);
        if (!keys.add(name)) throw FormatException('Duplicate JSON key: $name');
        require(':');
        value(depth + 1);
      } while (consume(','));
      require('}');
      return;
    }
    if (consume('[')) {
      if (consume(']')) return;
      do {
        value(depth + 1);
      } while (consume(','));
      require(']');
      return;
    }
    final start = position;
    while (position < input.length && !' \t\r\n,]}'.contains(input[position])) {
      position++;
    }
    if (start == position) throw const FormatException('Missing JSON scalar');
    // The final JSON decoder validates scalar grammar, numbers and escapes.
  }
}

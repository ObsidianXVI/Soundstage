import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'harness.dart';

void main() {
  testWidgets('Enter and Space in a text field inside an interactive go to '
      'the field, not the activation', (tester) async {
    var taps = 0;
    await pumpChrome(
      tester,
      SizedBox(
        width: 300,
        child: SsInteractive(
          onTap: () => taps++,
          builder: (context, states) => const SizedBox(
            width: 200,
            child: SsTextField(semanticLabel: 'Inner'),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    final enter = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final space = await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 0);
    // Unhandled by the framework: the browser's input gets the key.
    expect(enter, isFalse);
    expect(space, isFalse);
  });
}

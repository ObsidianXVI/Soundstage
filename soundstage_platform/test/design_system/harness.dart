import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

/// Pumps [child] inside the chrome scope at [size].
Future<void> pumpChrome(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(800, 600),
  SsThemeData? theme,
  Alignment alignment = Alignment.topLeft,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, c) =>
          SsScope(theme: theme ?? SsThemeData.dark(), child: c!),
      home: Scaffold(
        body: Align(
          alignment: alignment,
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
}

Finder textFieldIn(Type widget) =>
    find.descendant(of: find.byType(widget), matching: find.byType(TextField));

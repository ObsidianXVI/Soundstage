import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/app.dart';
import 'package:soundstage_platform/app/demo_harness.dart';

void main() {
  testWidgets('app boots into the demo harness', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SoundstageApp()));
    expect(find.byType(DemoHarness), findsOneWidget);
  });
}

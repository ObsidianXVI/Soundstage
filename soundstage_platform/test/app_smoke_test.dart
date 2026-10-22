import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/app.dart';
import 'package:soundstage_platform/app/sound_demo.dart';

void main() {
  testWidgets('app boots into the spike demo by default', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SoundstageApp()));
    expect(find.byType(SoundDemoHarness), findsOneWidget);
  });
}

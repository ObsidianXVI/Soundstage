import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/app.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';

void main() {
  testWidgets('app boots into the story list', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyRepositoryProvider.overrideWithValue(
            InMemoryStoryRepository(loadAsset: (_) async => '{}'),
          ),
        ],
        child: const SoundstageApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stories'), findsOneWidget);
    expect(find.text('New draft'), findsOneWidget);
  });
}

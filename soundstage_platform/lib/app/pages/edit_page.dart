import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';

import 'not_found_page.dart';

/// `/edit/:id`: the editor for one story.
class EditPage extends ConsumerWidget {
  const EditPage({required this.storyId, super.key});

  final String storyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(storyDocumentProvider(storyId))) {
      AsyncData(:final value) when value != null => Scaffold(
        backgroundColor: context.ss.colors.surface0,
        body: EditorShell(
          document: value,
          onBack: () => context.go('/'),
          onPreview: () => context.go('/play/$storyId'),
        ),
      ),
      AsyncData() => const NotFoundPage(message: 'Story not found'),
      AsyncError(:final error) => NotFoundPage(
        message: 'Could not open the story: $error',
      ),
      _ => Scaffold(backgroundColor: context.ss.colors.surface0),
    };
  }
}

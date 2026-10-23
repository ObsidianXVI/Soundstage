/// Editor core (architecture §15): state, commands, history, selection
/// rules and shortcut intents. No widgets; the shell, canvas, panels and
/// inspector build on this.
library;

export 'command.dart';
export 'commands/gesture_commands.dart';
export 'commands/node_commands.dart';
export 'commands/property_commands.dart';
export 'commands/scene_commands.dart';
export 'editor_controller.dart';
export 'editor_events.dart';
export 'editor_state.dart';
export 'history.dart';
export 'selection.dart';
export 'shortcuts.dart';

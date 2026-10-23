import 'dart:ui';

/// Whether the browser's EyeDropper API exists (never, off the web).
bool get eyeDropperSupported => false;

/// Opens the screen eyedropper; null when unsupported or cancelled.
Future<Color?> pickScreenColor() async => null;

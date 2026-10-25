import 'dart:typed_data';

import 'package:soundstage_platform/editor/audio/waveform_peaks.dart';

import 'records.dart';

/// True where the browser services exist.
const bool kHasBrowser = false;

String createObjectUrl(Uint8List bytes, String mime) =>
    throw UnsupportedError('Object URLs need a browser.');

void revokeObjectUrl(String url) {}

/// Decodes [bytes] in the browser for size, duration and dominant colour.
Future<AssetAnalysis> analyzeInBrowser(Uint8List bytes, String mime) async =>
    const AssetAnalysis();

/// Starts a download of [bytes] named [filename].
void downloadFile(String filename, Uint8List bytes, String mime) =>
    throw UnsupportedError('Downloads need a browser.');

/// Opens the file picker. Must be called from a user gesture handler.
Future<List<PickedFile>> pickFiles({
  String accept = '',
  bool multiple = false,
}) => throw UnsupportedError('A file picker needs a browser.');

/// Calls [callback] when the page is hidden or being unloaded
/// (`visibilitychange` to hidden, `pagehide`). Returns a function that
/// stops listening.
void Function() onPageHide(void Function() callback) => () {};

/// Decodes audio [bytes] with Web Audio and reduces them to waveform peaks;
/// null when they cannot be decoded. Without a browser there is nothing to
/// decode with.
Future<WaveformPeaks?> decodePeaksInBrowser(Uint8List bytes) async => null;

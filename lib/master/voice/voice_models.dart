import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The offline voice models, copied once from the app's assets to files, because
/// the native runtime opens them by path. tool/fetch_voice_models.py puts them
/// in assets/models before the build.
class VoiceModels {
  VoiceModels._(this.dir);

  static const _version = 'v1';
  static const _assets = [
    'kws/encoder.int8.onnx',
    'kws/decoder.onnx',
    'kws/joiner.int8.onnx',
    'kws/tokens.txt',
    'vad/silero_vad.onnx',
    'whisper/tiny-encoder.int8.onnx',
    'whisper/tiny-decoder.int8.onnx',
    'whisper/tiny-tokens.txt',
  ];

  // "JARVIS" in the spotter's word pieces, also as Brazilians often say it.
  static const keywords = '▁JA R VI S @JARVIS\n▁JA R VE S @JARVIS\n';

  final String dir;

  String path(String name) => '$dir/$name';
  String get keywordsFile => path('kws/keywords.txt');

  /// Copies missing models (about 110 MB, the first time only).
  static Future<VoiceModels> prepare() async {
    final base = await getApplicationSupportDirectory();
    final models = VoiceModels._('${base.path}/models');
    final stamp = File(models.path('.copied-$_version'));
    if (!await stamp.exists()) {
      for (final name in _assets) {
        final ByteData data;
        try {
          data = await rootBundle.load('assets/models/$name');
        } on FlutterError {
          throw VoiceModelsMissing(name);
        }
        final file = File(models.path(name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      await stamp.writeAsString(DateTime.now().toIso8601String());
    }
    await File(models.keywordsFile).writeAsString(keywords);
    return models;
  }
}

class VoiceModelsMissing implements Exception {
  VoiceModelsMissing(this.name);
  final String name;

  @override
  String toString() => 'Voice model $name is missing: run tool/fetch_voice_models.py before building.';
}
